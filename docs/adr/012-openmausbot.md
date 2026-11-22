---
aliases:
  - ADR-012
  - Maus-117
  - OpenMausBot
tags:
  - adr
  - docker
  - security
  - networking
  - region/ditta
  - service/openmausbot
status: proposto
date: 2026-10-15
related:
  - "[[002-cloudflare-tunnel]]"
  - "[[005-topologia-multi-sito]]"
  - "[[009-paca]]"
  - "[[010-persistenza-dati-fuori-dalla-lxc]]"
  - "[[011-minder-130-runner-staging]]"
---

# ADR-012: OpenMausBot su LXC dedicata `Maus-117` chiusa dal firewall Proxmox

| | |
|---|---|
| **Stato** | Proposto — configurazione scritta, `tofu plan`/`apply` e deploy non ancora eseguiti |
| **Data** | 2026-10-15 |
| **Nodi coinvolti** | `dell-emc` (nuova LXC `Maus-117`, vmid 117, `192.168.10.117`; Traefik-110 per l'esposizione) |

## Contesto

[OpenMausBot](https://github.com/milind-soni/OpenMausBot) è un harness self-hosted che fa girare agenti AI (le CLI `claude` e `codex`) come "bot" dentro un'interfaccia di chat, accessibile da browser e da app mobile. Lo voglio sempre acceso, non legato al portatile.

Tre caratteristiche del progetto guidano tutte le scelte sotto:

- **I bot hanno una shell reale** con i privilegi dell'utente del server, più un browser (Chrome headless) che possono pilotare. Un permission broker chiede approvazione per le azioni rischiose, ma `SECURITY.md` documenta un gap ancora aperto: la shell di un bot può far eseguire lavoro "Full access" in un thread esistente senza passare dall'approvazione.
- **Il modello di autenticazione è la fiducia nel loopback.** Chi raggiunge `127.0.0.1:8799` è owner. Da fuori si entra solo con una sessione ottenuta tramite pairing (codice monouso, 5 minuti), e il cookie di sessione è `Secure`, quindi serve HTTPS.
- **È pre-1.0 e si muove in fretta**: più release al giorno (v0.1.109 → v0.1.111 in circa 16 ore al momento della scrittura).

Il punto da risolvere non è "dove far girare un container", ma quanto lontano può arrivare una shell che non controllo direttamente. Una LXC dedicata, come per PACA ([ADR-009](009-paca.md)) e `Minder-130` ([ADR-011](011-minder-130-runner-staging.md)), isola i dati degli altri servizi; non isola la rete. ADR-011 lo lasciava esplicitamente aperto: da qualunque LXC la `192.168.10.0/24` è raggiungibile.

## Decisione

### 1. LXC dedicata `Maus-117`

Rocky Linux 9, unprivileged con `nesting`, 2 vCPU, 4 GB di RAM, 30 GB (il sizing consigliato upstream è 2 CPU / 4 GB). Portata a 4 vCPU e 12 GB il 22/11/2026, quando è diventata anche l'host dei desktop dei bot (sezione 7). Una voce nella mappa `containers` di `variables.tf`; Docker e Hawser arrivano dai ruoli Ansible esistenti. Nessun altro servizio, nessun segreto infrastrutturale: niente 1Password, e nemmeno una cartella Infisical per il servizio, perché le variabili di OpenMausBot non sono segreti.

Ho scelto una LXC e non una VM per restare sullo stesso tooling di tutte le altre unità. Il limite di questa scelta è nella sezione "Da tenere presente".

### 2. Firewall Proxmox sulla LXC, primo nel repo

`infrastructure/opentofu/nodes/dell-emc/firewall.tf` chiude la LXC a livello di bridge, cioè fuori dal controllo di chi è root dentro il container:

- **Ingresso** (policy `DROP`): solo Traefik-110 sulla 8080 e SSH da pve-management (Ansible).
- **Uscita** (policy `ACCEPT`): DNS verso il gateway, poi `DROP` su tutte le reti private (`10/8`, `172.16/12`, `192.168/16`, `100.64/10` di Tailscale/Netbird, link-local). Il resto esce verso Internet, che è ciò che serve ai bot: API degli engine, npm, siti per il browser.
- `ipfilter` attivo: la LXC può usare solo il proprio IP, altrimenti root nel container potrebbe impersonare `.110` o `.200` e passare le regole in ingresso.

Il blocco verso `192.168.0.0/16` copre anche la rete aziendale dietro il Cisco ([ADR-005](005-topologia-multi-sito.md)): una shell di un bot non deve poterla esplorare.

Hawser viene installato come su ogni host (il ruolo gira su `all`), ma la 2376 non è aperta a nessuno: Dockhand non gestisce questa LXC. È voluto.

Il nuovo attributo `firewall` di `var.containers` ha default `false`: le LXC esistenti non cambiano.

### 3. Prerequisito manuale: firewall datacenter attivo

Le regole di un guest valgono solo se il firewall è attivo anche a livello datacenter. Su `pve` oggi è spento (`pve-firewall status`: `disabled/running`, nessun `cluster.fw`), quindi le regole verrebbero salvate ma non applicate, in silenzio.

L'attivazione la faccio a mano, fuori da Tofu, per non dare al token `opentofu@pve` permessi sull'intero cluster:

```
# /etc/pve/firewall/cluster.fw
[OPTIONS]
enable: 1
policy_in: ACCEPT
policy_out: ACCEPT
```

Con `policy_in: ACCEPT` l'host `pve` resta raggiungibile come oggi (8006, SSH) anche al di là delle sue regole in `host.fw`. Gli altri guest non cambiano: dieci hanno già `firewall=1` sull'interfaccia (creati da GUI), ma nessuno ha `enable: 1` nelle proprie opzioni (l'unico file di regole, `104.fw`, non ha una sezione `[OPTIONS]`), quindi per loro il firewall resta spento. Va ricontrollato al momento dell'attivazione, non dato per scontato.

### 4. Docker Compose: immagine locale, Caddy sidecar, backup

`docker-compose/openmausbot/`:

- **`Dockerfile`**: l'immagine pubblicata upstream non contiene nessun engine. La ricostruisco in locale su `ghcr.io/milind-soni/openmausbot:<tag>` aggiungendo a versioni fissate `@anthropic-ai/claude-code`, `@openai/codex`, `opencode-ai` (npm, aggiornati da Renovate) e la Cursor CLI (`cursor-agent`, pacchetto scaricato in `/opt` invece dello script `curl | bash`, che installerebbe nel volume e sempre all'ultima versione; non essendo su npm si aggiorna a mano). Grok escluso, non lo uso. Antigravity non sta nell'immagine: è OpenMausBot stesso a scaricare il runtime ufficiale Google dalla UI (circa 1.9 GB, SHA-256 verificato) in `/data/.openmausbot/tools/`, escluso dal backup perché riscaricabile. `pull_policy: build` nel compose fa sì che il `docker compose up -d` del ruolo `docker_service` ricostruisca dopo un bump.
- **`Caddyfile` proprio**: quello upstream imposta `X-Forwarded-Proto http` a meno di legare la porta a `127.0.0.1`, il che è incompatibile con Traefik su un altro host. Il risultato sarebbe niente cookie `Secure` e controllo same-origin fallito. Qui `X-Forwarded-Proto` è sempre `https`, ed è vero perché l'unica strada per arrivare alla 8080 è Cloudflare → Traefik. Caddy aggiunge sempre `X-Forwarded-For`, ed è questo che fa trattare ogni richiesta come remota: Traefik punta a Caddy, mai alla 8799.
- **Container `omb` irrigidito**: utente non-root (`maus`, dall'immagine), `cap_drop: ALL`, `no-new-privileges`, limiti di memoria e PID, nessun `docker.sock`, nessun mount dell'host. Dal 22/11/2026 però `omb` arriva al daemon Docker dell'LXC via SSH (sezione 7): l'assenza del socket non è più un confine.
- **Backup** come Karakeep ([ADR-010](010-persistenza-dati-fuori-dalla-lxc.md)): ogni notte `.backup` di SQLite per ogni database sotto `~/.openmausbot`, verificato con `quick_check`, più il resto della HOME in tar, verso `/var/lib/pve-persistent/openmausbot-backups` su `pve`.

### 5. Esposizione: Cloudflare Tunnel + Traefik, senza Authentik

`maus.alessandrogorla.it`: tunnel `Gorla` → Traefik-110 → `192.168.10.117:8080`, come Karakeep. **Niente forward-auth Authentik**: romperebbe il pairing, lo stream SSE della chat, l'app iOS e i webhook. L'autenticazione è il pairing del server. Traefik ha `flushInterval: -1` per non bufferizzare lo stream.

### 6. Aggiornamenti: nessun automerge

Con versioni `0.1.x` ogni release conterebbe come patch e finirebbe nell'automerge di default. Una regola dedicata in `renovate.json` richiede approvazione esplicita dalla Dependency Dashboard e 7 giorni di età, sia per l'immagine sia per le CLI degli engine (tramite un `customManagers` regex sul Dockerfile).

### 7. Desktop dei bot: Maus-117 fa anche da host Docker (22/11/2026, HOME-61)

OpenMausBot può dare a un bot un "computer": un desktop XFCE con browser in un container Docker (immagine base `trycua/xfce-cua`, circa 0,5 GB compressa, ricostruita sull'host con il driver Cua), che il bot pilota e che io vedo dalla UI in un viewer noVNC. La modalità "Self-hosted VPS computers" lo crea su un host Docker raggiungibile via SSH. Come host ho scelto la stessa `Maus-117`, non un'altra unità.

Come funziona, letto nel codice di v0.1.176 (`server/vps-computer.ts`, `server/vps-ssh.ts`):

- `omb` lancia `docker -H ssh://<alias> ...`: la CLI Docker apre SSH ed esegue in remoto `docker system dial-stdio`. Prima apre una connessione master condivisa con `ssh <alias> true`.
- Il viewer del desktop è un tunnel `ssh -N -L 127.0.0.1:<porta>:<IP del desktop>:6901`: il browser parla con `omb`, che inoltra verso il noVNC del container sul bridge Docker. Nessuna porta pubblicata sull'host.
- Ogni desktop: 4 GB di RAM, 2 CPU, `cap_drop ALL` più poche capability, rete `bridge`, nessun volume. Il limite lo decide upstream, non questo repo.

Cosa ho aggiunto:

- **Immagine**: `docker-ce-cli` (repo apt di Docker, versione fissata) e `openssh-client` nel `Dockerfile`. Solo la CLI: il daemon resta quello dell'LXC.
- **Utente `omb-docker`** sull'LXC, nel gruppo `docker`, creato dal ruolo Ansible `omb_vps_host` dopo il compose up. La chiave ed25519 nasce dentro il volume di `omb` (`/data/.ssh/`), e Ansible ne legge solo la pubblica: la privata non esce dal container, se non nei backup notturni del volume.
- **sshd vincolato per quell'utente** (drop-in `90-omb-docker.conf`, `Match User`): `ForceCommand` verso uno script che accetta solo `docker system dial-stdio` e `true` e registra il resto; niente pty, agent, X11 né password; forward solo locali e solo verso la porta 6901. La porta e non l'IP, perché l'IP del desktop cambia a ogni ricreazione. In `authorized_keys`: `restrict,port-forwarding,from="172.16.0.0/12"`, cioè la chiave vale solo dalle reti Docker dell'LXC e non dalla LAN. Management continua a entrare come prima: il blocco vale solo per `omb-docker` (verificato con `sshd -T -C`).
- **Alias** `maus-docker` in `/data/.ssh/config`, verso `host.docker.internal` (`extra_hosts: host-gateway` nel compose, cioè `docker0` dell'LXC), con la chiave host di sshd scritta in `known_hosts` da Ansible invece di un `accept-new`. L'alias va inserito una volta a mano in OpenMausBot (Settings > API keys > VPS SSH alias).
- **Risorse**: 4 vCPU e 12 GB (omb 3 GB più due desktop da 4). Disco fermo a 30 GB: il thin pool `local-lvm` era all'89%, e la build cache Docker (12 GB) si può svuotare con `docker builder prune` più `fstrim` su `pve`.

Il firewall Proxmox non cambia: il traffico tra `omb`, sshd e i desktop resta dentro l'LXC e non passa dal bridge `vmbr0`.

## Alternative considerate

| Alternativa | Perché scartata |
|---|---|
| **Su `Docker-100` insieme agli altri servizi** | Una shell di un bot sarebbe sullo stesso host di Karakeep, Linkwarden e monitoring. È la stessa ragione di ADR-009 e ADR-011, qui ancora più forte perché la shell è il prodotto, non un effetto collaterale. |
| **VM QEMU invece di LXC** | Isolamento migliore (kernel separato), ed era la mia prima idea. Ma nel repo non esiste nessuna VM gestita da Tofu: servirebbero un template cloud-init e una resource nuova solo per questo. Con il firewall Proxmox la differenza pratica si riduce all'isolamento del kernel. Resta l'opzione se una LXC risultasse insufficiente. |
| **Solo rete privata (`serve --tailscale`)** | La superficie d'attacco più piccola: nessun hostname pubblico. Scartata perché voglio usarlo da dispositivi senza client VPN e ricevere webhook pubblici. |
| **Tunnel del vendor (`serve --tunnel`)** | Il modo più rapido, ma lega l'hostname a un account openmausbot.com e a un tunnel Cloudflare che non gestisco io, accanto a quello che già ho ([ADR-002](002-cloudflare-tunnel.md)). |
| **Forward-auth Authentik davanti** | Incompatibile con pairing, SSE, app iOS e webhook. Cloudflare Access sarebbe possibile per un uso solo da browser; non attivato per ora. |
| **Desktop su un host separato (VM o LXC dedicata)** | Il confine giusto: un bot compromesso arriverebbe a root su quell'host, non su quello che contiene stato, login e backup di OpenMausBot. Scartata per ora per non aggiungere un'unità in più; resta la strada se i desktop diventano un uso abituale. |
| **`docker.sock` montato in `omb`** | Stesso privilegio della soluzione scelta, ma senza nemmeno il filtro di sshd e con il socket visibile a ogni processo del container. OpenMausBot comunque si aspetta un alias SSH. |
| **Chiave con solo `docker system dial-stdio` e `no-port-forwarding`** | Era il piano iniziale. Rompe il viewer del desktop, che passa da un forward SSH verso la 6901. |
| **npm + systemd come nella guida VPS ufficiale** | Fuori dallo schema del repo: niente Renovate, niente deploy Ansible, un ruolo nuovo da scrivere. |

## Conseguenze

> [!TIP] Positive
> - Primo uso del firewall Proxmox nel repo, dichiarativo e versionato: lo stesso schema si può estendere a `Paca-120`, `Minder-130` e `GitlabRunner-114`, che hanno lo stesso problema di rete lasciato aperto da ADR-011.
> - Nessuna porta in ingresso nuova: stessa catena Cloudflare → Traefik → backend di tutti gli altri servizi.
> - Le LXC esistenti non cambiano: il nuovo attributo ha default `false`, e nessuna delle LXC gestite da Tofu ha oggi `firewall=1` (verificato su `/etc/pve/lxc/*.conf` il 15/10/2026). Da confermare comunque nel `plan`.

> [!WARNING] Da tenere presente
> - **Il firewall dipende da un flag manuale.** Se il firewall datacenter viene spento (o non è mai stato acceso), le regole restano in Proxmox ma non filtrano nulla, senza errori. Va controllato con `pve-firewall status`.
> - **Una LXC non è una VM.** Kernel condiviso con `pve`: un exploit del kernel da dentro il container non è fermato da nulla di quanto sopra. Il firewall limita la rete, non questo.
> - **Chrome gira con `--no-sandbox`.** Lo decide agent-browser quando rileva un container: l'unica sandbox del browser dei bot è il container stesso.
> - **Il backup è best-effort.** Upstream consiglia di fermare il server prima, ma farlo dal container di backup richiederebbe il socket Docker. I database sono copiati in modo coerente, i file di configurazione e i login possono finire a metà scrittura. È una sola copia sul nodo, non 3-2-1, come per PACA e Karakeep.
> - **Gli archivi di backup contengono credenziali**: token OAuth degli engine (abbonamenti Claude/ChatGPT) e chiavi API. La directory su `pve` va creata a mano con `chmod 700` prima del primo `apply`: il provisioner fa solo `chown`, non imposta i permessi.
> - **Lockout del pairing condiviso.** Tutte le richieste arrivano da cloudflared/Traefik: il limite ai tentativi di pairing falliti conta un solo indirizzo, quindi chiunque può causare un blocco temporaneo per tutti. Più restrittivo, non meno sicuro.
> - **Il gap "Full access" di `SECURITY.md` resta aperto upstream.** Mitigazione mia: niente Full access condiviso e niente `OMB_SIGNIN_EMAILS`, un solo utente.
> - **Pre-1.0.** Un bump può cambiare struttura dei dati, variabili o comportamento senza preavviso: per questo niente automerge, e prima di ogni aggiornamento conviene un backup manuale.
> - **Monitoring e Dockhand non vedono `Maus-117`.** Il firewall blocca ogni connessione dalla LAN tranne Traefik e Ansible: nessun health check da Docker-100, nessuna gestione da Dockhand. Lo stato del servizio si vede solo dall'esterno (l'hostname pubblico) o con `pct exec` da `pve`.
> - **Ogni engine in più è una CLI in più con la shell dei bot.** Claude, Codex, opencode, Cursor e Antigravity girano tutti con gli stessi privilegi dentro `omb`; i loro login stanno nel volume e quindi nei backup. La Cursor CLI va aggiornata a mano.
> - **Antigravity pesa.** Circa 1.9 GB nel volume più il download temporaneo, su un disco da 30 GB, e un uso di memoria non misurato dentro il `mem_limit` di 3 GB.
> - **`cap_drop: ALL` non è verificato contro ogni funzionalità.** Se qualcosa smette di funzionare dopo un aggiornamento, è il primo sospettato.
> - **Con i desktop, una shell di un bot arriva a root sull'LXC.** È il cambiamento più importante del 22/11/2026, ed è una scelta consapevole. La chiave di `omb-docker` sta nel volume di `omb`, quindi chiunque abbia la shell di un bot la legge e parla con il daemon Docker, che è root: `docker run -v /:/host` e l'LXC è sua, con stato, login degli engine e backup di OpenMausBot. I vincoli di sshd tolgono la shell interattiva e i forward arbitrari, non questo privilegio. Restano fuori portata quello che sta fuori dall'LXC: il firewall Proxmox (gestito da `pve`), la LAN, le altre unità. L'LXC è unprivileged, quindi root dentro non è root su `pve`, a meno di un exploit del kernel (punto sopra).
> - **`PermitOpen *:6901` non è legato a un IP.** Il forward è permesso verso la 6901 di qualunque indirizzo. Fuori dall'LXC le reti private le blocca comunque il firewall; verso Internet resta possibile un forward sulla 6901, poco utile ma non impossibile.
> - **I desktop non hanno persistenza vera né backup.** Nessun volume: i dati stanno nel layer del container e sopravvivono a stop e riavvii, non a una ricreazione. Non sono nel backup notturno, che copre solo il volume di `omb`.
> - **Disco e thin pool.** Immagine base più layer dei desktop crescono sui 30 GB della LXC, che stanno sul thin pool `local-lvm` di `pve`, già all'89%. Spostare `/var/lib/docker` su un volume del VG `Storage` è la mossa successiva se lo spazio diventa un problema.
> - **La CLI Docker nell'immagine si aggiorna a mano.** Renovate non legge il repo apt di Docker.

## Riferimenti

- Configurazione: [`infrastructure/opentofu/nodes/dell-emc/variables.tf`](../../infrastructure/opentofu/nodes/dell-emc/variables.tf), [`firewall.tf`](../../infrastructure/opentofu/nodes/dell-emc/firewall.tf), [`docker-compose/openmausbot/`](../../docker-compose/openmausbot/), [`docker-compose/traefik/dynamic/dynamic.yml`](../../docker-compose/traefik/dynamic/dynamic.yml), [`renovate.json`](../../renovate.json)
- Desktop dei bot (sezione 7): [`infrastructure/ansible/roles/omb_vps_host/`](../../infrastructure/ansible/roles/omb_vps_host/), upstream [`docs/byo-vps.md`](https://github.com/milind-soni/OpenMausBot/blob/main/docs/byo-vps.md)
- Upstream: [`docs/self-hosting.md`](https://github.com/milind-soni/OpenMausBot/blob/main/docs/self-hosting.md), [`docs/deploy-vps.md`](https://github.com/milind-soni/OpenMausBot/blob/main/docs/deploy-vps.md), [`SECURITY.md`](https://github.com/milind-soni/OpenMausBot/blob/main/SECURITY.md)
- [Proxmox VE Firewall](https://pve.proxmox.com/wiki/Firewall)
- [ADR-002](002-cloudflare-tunnel.md), [ADR-005](005-topologia-multi-sito.md), [ADR-009](009-paca.md), [ADR-010](010-persistenza-dati-fuori-dalla-lxc.md), [ADR-011](011-minder-130-runner-staging.md)
