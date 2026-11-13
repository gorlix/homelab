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
