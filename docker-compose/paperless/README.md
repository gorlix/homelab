# Paperless-ngx su Paperless-119

Stack Docker Compose di Paperless-ngx sulla LXC `Paperless-119` (`192.168.10.119`), pubblico come `paperless.alessandrogorla.it` con login OIDC Authentik. Decisioni e limiti generali: ADR-014. Questa nota copre i servizi accessori dello stack: paperless-gpt (HOME-48) e il server MCP (HOME-52).

## paperless-gpt su Paperless-119 (HOME-48)

paperless-gpt suggerisce titolo, tag, corrispondente e tipo di documento con un
LLM. Qui usa l'API Anthropic (`claude-haiku-5-5`). Contesto generale in
ADR-014 (PR #59); questa nota va poi riassunta lì.

### Come funziona

- Il servizio guarda solo i documenti con il tag **`ai-process`** (`AUTO_TAG`).
  Un documento senza quel tag non lascia mai la LXC.
- A fine elaborazione toglie `ai-process` e mette `paperless-gpt-auto-complete`;
  se Paperless rifiuta la modifica mette `paperless-gpt-failed`.
- Non crea tag nuovi (`CREATE_NEW_TAGS=false`): usa solo quelli già esistenti.
- Nessuna porta pubblicata. La UI di paperless-gpt non ha autenticazione e non
  serve in modalità automatica.

### Cosa esce verso Anthropic

Il testo già estratto da Paperless (OCR di Paperless, non di paperless-gpt) dei
soli documenti con il tag, più i nomi di tag e corrispondenti esistenti. Niente
immagini: OCR LLM e vision non sono configurati.

### Limiti da tenere presente

- È un provider esterno: il tag è l'unico filtro. Un tag messo per errore su un
  documento sensibile lo manda ad Anthropic. Non c'è un controllo ulteriore.
- Modalità automatica: i suggerimenti vengono applicati senza approvazione. Per
  rivedere prima serve la UI (`MANUAL_TAG`), che andrebbe esposta solo su LAN o
  Tailscale, mai pubblica.
- Immagine pre-1.0 (0.x): Renovate non fa automerge (`renovate.json`).
- La qualità sui documenti italiani non è ancora misurata: va provata su un
  documento di test.
- Il costo è a carico dei crediti API dell'account Anthropic.

### Segreti

Su Infisical `homelab-env`, `prod`, cartella `/paperless`, oltre a quelli di
Paperless: `ANTHROPIC_API_KEY` e `PAPERLESS_API_TOKEN` (token dell'utente
`gorlix`, con i permessi di quell'utente sui documenti).

### Dati

`/mnt/persistent-data/paperless-gpt/{prompts,config,db}`, proprietario `10001`
(utente del container). `db` contiene lo storico per l'annullamento.

### Provare

1. Aggiungere un documento di prova e mettergli il tag `ai-process`.
2. `docker compose logs -f paperless-gpt` nella cartella `/opt/paperless`.
3. Controllare titolo e tag, poi cancellare il documento di prova.

## Server MCP

Il servizio `mcp` dello stack espone Paperless a due client: i bot di Rakazo e Claude Code nel repo homelab. Software: `paperless-mcp` di tb1337 (MIT), installato da PyPI in un'immagine locale (`mcp.Dockerfile`).

```
client (Rakazo, Claude Code)
   |  HTTPS + Bearer (chiave A)
   v
Cloudflare Tunnel "Gorla" -> Traefik-110 (mcp-paperless.alessandrogorla.it)
   |  HTTP
   v
192.168.10.119:8010  servizio mcp  --(token API di gorlix, chiave B)-->  webserver:8000
```

- **Esposizione.** Route `mcp-paperless` in `traefik/dynamic/dynamic.yml`, senza forward-auth Authentik (romperebbe i client MCP) e con `flushInterval -1` (streaming). L'hostname sta sul tunnel Gorla come gli altri.
- **Due chiavi, due compiti.** La chiave A (`PAPERLESS_MCP_AUTH_TOKEN`) è un valore casuale che i client mandano come Bearer: tiene fuori chi non è autorizzato. La chiave B (`PAPERLESS_MCP_TOKEN`) è il token API di Paperless dell'utente `gorlix`: è quello che il server usa verso Paperless. Il server non inoltra la chiave del client a Paperless: tutti i client condividono la stessa identità.
- **Segreti.** Entrambe su Infisical `prod/paperless` (ADR-007), il `.env` lo genera il ruolo Ansible `infisical_secrets` + `docker_service`. Il compose le interpola direttamente, così il container non riceve gli altri segreti del `.env`.
- **Deploy.** `infrastructure/ansible/run.sh --limit "Paperless-119:localhost" -e '{"services":["paperless"]}'`. Alla prima volta il compose costruisce l'immagine, e serve l'accesso a PyPI dalla LXC.

### Cosa può fare il bot

Il bot agisce come `gorlix`: vede tutti i documenti dell'utente e, con la scrittura attiva, può caricare, modificare, taggare, unire e dividere documenti. Per scelta di Ale è lo stesso utente, non uno dedicato, perché un utente separato non vedrebbe i documenti di cui `gorlix` è proprietario senza assegnare permessi uno per uno.

Per regolare i poteri (variabili in Infisical, poi nuovo deploy):

| Variabile | Default | Effetto |
|---|---|---|
| `PAPERLESS_MCP_READONLY` | `false` | `true` nasconde tutti i tool di scrittura e cancellazione |
| `PAPERLESS_MCP_ENABLE_DELETE` | `false` | `true` espone i tool di cancellazione (documenti, tag, cestino) |

### Da tenere presente

- **Identità condivisa.** Nei log di Paperless le azioni del bot risultano fatte da `gorlix`. Il token è lo stesso dell'app mobile (Paperless ne ammette uno per utente): ruotarlo vuol dire riconfigurare tutti.
- **Un solo Bearer per tutti i client.** Rakazo e Claude Code usano la stessa chiave A: per revocarne uno bisogna ruotarla e aggiornarli entrambi.
- **Software giovane.** `paperless-mcp` 0.1.0 si dichiara "highly experimental": nomi e parametri dei tool cambiano tra le release. Il pin è in `mcp.Dockerfile` (ARG) e nel tag dell'immagine nel compose; Renovate lo propone senza automerge.
- **Cancellazione spenta finché non c'è un backup verificato** (HOME-49). Un modello che agisce da solo su documenti personali non va lasciato libero di cancellare senza rete di sicurezza.
- **Scrittura attiva.** Un'istruzione sbagliata (o iniettata da un documento: l'OCR di un PDF è testo che il modello legge) può modificare tag e metadati in blocco. Prima di un'azione di massa conviene chiedere al bot cosa farà.

### Client

- **Rakazo.** Voce MCP aggiunta via DB (come per Karakeep): URL `https://mcp-paperless.alessandrogorla.it/mcp`, autenticazione "Bearer token" con la chiave A.
- **Claude Code (repo homelab).** Server `paperless` a scope local, con URL e chiave A in `.env.mcp` (fuori da git). Vedi la skill `MCP-homelab`.

## Cartella consume in LAN (lan-upload)

Permette a un client della rete locale di caricare file nella cartella `consume` di Paperless, che li acquisisce da sola. Oggi l'unico client è `Rakazo-118`: i suoi bot devono solo **caricare** file (leggere e cercare lo fanno già col server MCP).

Requisiti decisi con l'autore (14/11/2026): solo rete locale `192.168.10.0/24`, niente Internet né Cloudflare Tunnel; un solo punto di gestione degli accessi, `Traefik-110`; un client alla volta, aggiungerne altri deve essere una modifica piccola.

### Perché WebDAV dietro Traefik

- **Traefik autorizza solo HTTP.** SMB, SFTP o NFS passerebbero fuori dal punto di controllo.
- **Le LXC sono unprivileged.** `Rakazo-118` e `Paperless-119` non possono montare SMB o NFS col kernel.
- **Un bind mount diretto** della cartella dentro `Rakazo-118` passerebbe fuori da Traefik e non sarebbe revocabile da lì.

### Flusso

```
Rakazo-118 (192.168.10.118)
   |  HTTPS, PUT /rakazo/<file>, basicAuth
   v
Traefik-110  192.168.10.110:8099   entrypoint "lan-upload", un router per client
   |  HTTP (solo se IP + password + percorso + metodo sono giusti)
   v
Paperless-119  rclone serve webdav :8020   (servizio "webdav" dello stack)
   |  tiene il file nella cache (vfs-cache-mode writes), lo scrive solo completo
   v
/mnt/persistent-data/consume/rakazo/<file>
   |  Paperless (CONSUMER_RECURSIVE + SUBDIRS_AS_TAGS)
   v
documento acquisito con il tag "rakazo"
```

### I tre controlli per client

Il router di ogni client (`traefik/dynamic/lan-upload.yml`) li applica tutti e tre; ne basta uno sbagliato per essere rifiutati.

| Controllo | Come | Cosa ferma |
|---|---|---|
| IP | `ipAllowList` col solo IP del client (`/32`). Sull'entrypoint non ci sono `forwardedHeaders` fidati: conta l'IP reale della connessione | Qualsiasi altro host della LAN |
| Credenziale | `basicAuth`, un utente per client. L'hash `apr1` sta su Infisical `prod/traefik` come `LAN_UPLOAD_<CLIENT>_HTPASSWD`, la password è casuale da 40 caratteri | Un host con l'IP giusto ma senza la password |
| Cartella e metodo | `PathPrefix(/<client>/)` e solo `PUT` | Lettura (`GET`), elenco (`PROPFIND`), cancellazione (`DELETE`), scrittura nelle cartelle di altri |

La sottocartella `consume/<client>/` diventa un tag in Paperless (per Rakazo il tag `rakazo`). Serve per sapere da dove arriva un documento, utile perché i bot maneggiano contenuti non fidati.

### Come carica Rakazo

La password in chiaro è su Infisical `prod/rakazo` come `PAPERLESS_UPLOAD_PASSWORD`. Il certificato è self-signed: i client lo verificano con quello pubblico del repo (`docker-compose/traefik/certs/lan-upload.crt`).

```bash
curl --cacert lan-upload.crt \
     -u rakazo:"$PAPERLESS_UPLOAD_PASSWORD" \
     -T fattura.pdf \
     https://192.168.10.110:8099/rakazo/fattura.pdf
```

Risposta attesa `201`.

Per l'agente di Rakazo (Andrea) c'è una skill dedicata con tutto il flusso (consegna, ricerca del documento via MCP, errori, regole di sicurezza): `skill-andrea-paperless-upload.md` in questa cartella. Contiene il certificato pubblico, quindi va aggiornata quando il certificato viene ruotato. Presuppone che il computer del bot abbia `PAPERLESS_UPLOAD_PASSWORD` nell'ambiente e raggiunga `192.168.10.110:8099`: entrambe le cose sono da verificare (HOME-54).

### Dettagli da sapere

- **La sottocartella va creata a mano, una volta.** rclone risponde `409` se manca la cartella padre. Sulla LXC 119: `mkdir /mnt/persistent-data/consume/<client>` e `chown 1000:1000`. Paperless non la elimina dopo l'acquisizione (verificato il 15/11/2026).
- **File a metà.** Senza cache, `rclone serve webdav` scrive l'upload direttamente col nome finale (verificato il 15/11/2026 con un upload rallentato): a proteggere ci sarebbero solo i 5 secondi di stabilità di Paperless, e un upload bloccato più a lungo verrebbe acquisito a metà. Per questo il servizio gira con `--vfs-cache-mode=writes`: il file resta nella cache del container e arriva in `consume` solo completo, circa 5 secondi dopo la fine del PUT. `PAPERLESS_CONSUMER_IGNORE_PATTERNS` (regex sui file `.partial`) resta come rete di sicurezza. Limite: la cache sta nel container, quindi se il webdav riparte proprio in quei secondi l'upload si perde anche se il client ha già ricevuto `201`.
- **inotify.** Funziona sul bind mount del LV (verificato il 14/11/2026): non serve `PAPERLESS_CONSUMER_POLLING`.
- **Il webdav non ha autenticazione propria.** La sicurezza dipende dal firewall Proxmox di `Paperless-119` (`firewall.tf`): ingresso solo da `Traefik-110` su 8000, 8010 e 8020, e SSH da `192.168.10.200`. Richiede il firewall datacenter attivo (vedi ADR-012). **Ordine di deploy: prima il firewall (`tofu apply`), poi lo stack paperless.**
- **Egress di Rakazo-118.** Il firewall di `Rakazo-118` blocca le reti private: è stata aggiunta una sola eccezione, in uscita verso `192.168.10.110:8099`. La `:80` di Traefik resta chiusa ai bot.

### TLS

Certificato self-signed EC P-256, validità 5 anni (scade il **15/11/2031**), SAN `IP:192.168.10.110`, fingerprint SHA-256 `D0:9C:37:A6:FE:FE:53:A9:DC:DC:23:55:92:A8:86:41:E9:55:64:BB:7F:46:3A:C0:2C:F6:DB:E1:3A:7F:17:A5`. Viene servito come certificato di default perché i client si collegano per IP, quindi senza SNI. La parte pubblica è in `traefik/certs/lan-upload.crt`; la chiave sta su Infisical `prod/traefik` come `LAN_UPLOAD_TLS_KEY_B64` (PEM in base64) e `lan-upload.yml` la decodifica con i template Go di Traefik (`b64dec` e `indent`).

Perché non Let's Encrypt con DNS-01: richiederebbe una chiamata esterna e un token Cloudflare con permessi DNS dentro Traefik, e il nome finirebbe nei log di Certificate Transparency. Il prezzo: rinnovo manuale e un avviso nei browser e nei telefoni. Quando arriveranno client con un browser si passa a DNS-01: cambia solo il certificato, i router restano uguali.

### Aggiungere un client

Esempio per un client `<client>` con IP `<ip>`. Password e hash non vanno mai stampati a terminale o in chat.

1. **Password e hash**, senza mostrarli: generare la password casuale da 40 caratteri e l'hash `apr1` (`openssl passwd -apr1 -stdin`) su tmpfs e caricarli con `infisical secrets set --file=<file>.yaml`, un file YAML con i valori tra apici singoli (così `$` e `/` dell'hash restano letterali), poi distruggerlo con `shred`. Attenzione: la CLI di Infisical 0.44.6 non supporta la forma `KEY=@file`, e salva come valore il percorso del file (successo il 15/11/2026, Traefik ha rifiutato chiave e utente). Dopo il caricamento, verificare rileggendo da Infisical che la chiave corrisponda al certificato e l'hash alla password, senza stampare i valori.
2. **Infisical.** In `prod/traefik`: `LAN_UPLOAD_<CLIENT>_HTPASSWD` col valore `<client>:<hash apr1>`. Sul progetto del client: la password in chiaro (per Rakazo, `PAPERLESS_UPLOAD_PASSWORD` in `prod/rakazo`).
3. **Compose di Traefik.** Aggiungere `LAN_UPLOAD_<CLIENT>_HTPASSWD: ${LAN_UPLOAD_<CLIENT>_HTPASSWD:?manca su Infisical prod/traefik}` sotto `environment` in `docker-compose/traefik/docker-compose.yml`.
4. **Router e middleware.** In `traefik/dynamic/lan-upload.yml` copiare il router `lan-upload-rakazo` e i suoi due middleware (`-ip`, `-auth`), cambiando nome, IP in `sourceRange`, prefisso `PathPrefix` e variabile. Niente doppie graffe nei commenti del file: passano dal template.
5. **Cartella.** Sulla LXC 119: `mkdir /mnt/persistent-data/consume/<client>` e `chown 1000:1000` sulla stessa.
6. **Firewall, se il client è una LXC isolata** (come Rakazo-118): una regola `out` verso `192.168.10.110:8099` in `firewall.tf`, poi `tofu apply`. Prima, cercare `forces replacement` nel plan (ADR-010).
7. **Test locale:** `scripts/lan-upload-test.sh` dalla radice del repo (servono solo Docker e openssl). Deve passare prima di ogni deploy che tocca `lan-upload.yml`.
8. **Deploy.** Traefik va **ricreata** quando cambiano le variabili `LAN_UPLOAD_*`: pochi secondi di interruzione di tutte le route pubbliche. Poi i test qui sotto.

### Revocare un client

Togliere router e middleware dal `lan-upload.yml` (il file provider ricarica da solo), poi rimuovere la variabile `LAN_UPLOAD_<CLIENT>_HTPASSWD` da Infisical e dal compose di Traefik, e la regola firewall se c'era. I documenti già caricati restano in Paperless con il loro tag.

### Ruotare password e certificato

- **Password.** Nuovi password e hash come al punto 1, aggiornare i due valori su Infisical, ricreare Traefik e aggiornare il client. La rotazione la fa l'autore: la password è una sola per client.
- **Certificato (scadenza 15/11/2031).** Generare una nuova coppia EC P-256 con SAN `IP:192.168.10.110`, sostituire `traefik/certs/lan-upload.crt`, aggiornare `LAN_UPLOAD_TLS_KEY_B64` su Infisical, ricreare Traefik, distribuire il nuovo `.crt` ai client, aggiornare il blocco del certificato in `skill-andrea-paperless-upload.md` (e rimandarla ad Andrea) e il fingerprint in questa pagina.

### Test dopo il deploy

Da `Rakazo-118`:

1. `PUT` di un PDF di prova su `/rakazo/prova.pdf`: atteso `201`, il file in `consume/rakazo/` per pochi secondi, poi il documento in Paperless con il tag `rakazo`. Verificare nello stesso passaggio che la cartella `consume/rakazo/` resti dopo l'acquisizione (verificato il 15/11/2026).
2. Cancellare il documento di prova da Paperless.

Prove negative, da rifare ogni volta (devono essere tutte rifiutate):

| Prova | Atteso |
|---|---|
| `PUT` con password sbagliata | `401` |
| `PUT` da un altro host della LAN (stesse credenziali) | `403` |
| `GET` o `PROPFIND` su `/rakazo/` | rifiutato (`404`: nessun router li accetta) |
| `DELETE` su un file | rifiutato (`404`) |
| `PUT` su `/altro/file.pdf` | rifiutato (`404`) |
| Connessione a `192.168.10.119:8020` da `Rakazo-118` | timeout (firewall) |
| `192.168.10.110:80` da `Rakazo-118` | timeout (firewall) |

Da verificare: l'egress `restricted` dei computer dei bot potrebbe bloccare gli IP privati anche a livello dell'app Rakazo, non solo del firewall Proxmox.

### Estensione futura: Tailscale (non implementata)

Lo stesso schema funziona per un client sulla tailnet, con un punto da decidere. Se il nodo Tailscale della Region B fa da subnet router con SNAT (il default), Traefik vede l'IP LAN del router per tutti i dispositivi della tailnet e l'`ipAllowList` non li distingue. Due strade:

- mettere in allowlist l'IP del router e delegare il controllo per dispositivo alle ACL di Tailscale (due punti di controllo invece di uno);
- disattivare lo SNAT, oppure mettere Tailscale direttamente su `Traefik-110`. In entrambi i casi serve una rotta per `100.64.0.0/10` su `Traefik-110`, e il gateway Cisco non è modificabile dall'autore.

Il certificato andrebbe riemesso con il nuovo IP (o un nome) nel SAN.

### Da tenere presente

- **L'`ipAllowList` si fida dell'IP.** `ipfilter` di Proxmox protegge le LXC con firewall, non gli altri host della LAN, che è gestita da terzi: chi si prende l'IP di un client e ne conosce la password può caricare file.
- **`basicAuth` è una password condivisa per client**, in chiaro nel client e ruotata a mano.
- **Il webdav dipende dal firewall.** Senza il firewall datacenter attivo e la regola sulla 8020, chiunque in LAN scrive in `consume` senza autenticazione.
- **Un errore in `lan-upload.yml` fa cadere anche `dynamic.yml`.** Il file usa i template Go: un errore (anche in un commento con le doppie graffe) fa fallire tutto il file provider all'avvio, quindi anche le route pubbliche. È successo durante lo sviluppo; per questo esiste `scripts/lan-upload-test.sh`.
- **Un file in attesa di acquisizione resta nella cartella per pochi secondi.**
- **Aggiungere un client ricrea Traefik**, con una breve interruzione delle route pubbliche.
- **Certificato a rinnovo manuale** (15/11/2031) e avviso nei browser.
