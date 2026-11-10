---
aliases:
  - ADR-013
  - Rakazo-118
  - Rakazo
tags:
  - adr
  - docker
  - security
  - networking
  - region/ditta
  - service/rakazo
status: proposto
date: 2026-11-10
related:
  - "[[002-cloudflare-tunnel]]"
  - "[[007-infisical-env-management]]"
  - "[[010-persistenza-dati-fuori-dalla-lxc]]"
  - "[[012-openmausbot]]"
---

# ADR-013: Rakazo su LXC dedicata `Rakazo-118`, disco fuori dal thin pool

| | |
|---|---|
| **Stato** | Proposto: configurazione scritta, `tofu plan`/`apply` e deploy non ancora eseguiti |
| **Data** | 2026-11-10 |
| **Nodi coinvolti** | `dell-emc` (nuova LXC `Rakazo-118`, vmid 118, `192.168.10.118`, disco su `Storage`; Traefik-110 per l'esposizione) |

## Contesto

[Rakazo](https://github.com/elie222/rakazo) è un'alternativa open source a Grok Bot: bot che rispondono in chat usando il modello che scelgo io, ognuno con un proprio "computer", cioè un container con desktop Linux, Chromium e una shell, guidato dall'agente. In self-host i computer sono container Docker avviati da un `supervisor` che ha in mano `docker.sock`.

Il problema è lo stesso di OpenMausBot ([ADR-012](012-openmausbot.md)), con una differenza: qui non c'è solo una shell, c'è un servizio con accesso completo al Docker dell'host. Chi controlla il supervisor controlla l'host Docker, e un bot che esce dal proprio computer arriva lì.

Il 10/11/2026 il thin pool `local-lvm` di `pve` era all'80% (42 GB liberi su 216). L'immagine dei computer è pesante e le home dei bot crescono con l'uso: Rakazo è il servizio sbagliato da aggiungere a quel pool.

## Decisione

### 1. LXC dedicata `Rakazo-118`, schema di Maus-117

Rocky Linux 9, unprivileged con `nesting`, 4 vCPU, 8 GB, 40 GB. Il dimensionamento viene dai `mem_limit` del compose upstream (circa 6,5 GB tra Postgres, API, worker, web e supervisor, più 2 GB per ogni computer acceso): 8 GB bastano per uno o due computer accesi insieme, non di più.

### 2. Disco su `Storage` (LVM thick), non su `local-lvm`

Nuovo attributo `datastore` nella mappa `containers` (default `local-lvm`, le altre LXC non cambiano). `Storage` è un volume group LVM su `sdb1` (stesso array PERC H730P, 698 GB liberi). Thick vuol dire che i 40 GB sono allocati subito: Rakazo non può riempire il pool condiviso dalle altre LXC, e lo spazio non viene promesso due volte.

### 3. Firewall Proxmox, condiviso con Maus-117

`firewall.tf` è passato a un `for_each` su `local.isolated_containers` (LXC → porta di ingresso), con due blocchi `moved` perché le resource di Maus-117 cambiano solo indirizzo, non contenuto. Regole identiche: ingresso solo da Traefik-110 (qui sulla 5173) e SSH da pve-management, uscita libera verso Internet ma `DROP` su tutte le reti private.

### 4. Egress dei computer: `restricted`

Dentro la LXC, lo script upstream `restrict-computer-egress.sh` (copiato alla stessa versione del compose, lanciato da Ansible dopo il `compose up`) aggiunge regole iptables sui bridge `rakazo-c*`: i computer non raggiungono l'host, la LAN né i metadata cloud. Il compose imposta `SANDBOX_COMPUTER_EGRESS=restricted` e non `auto`: se le regole mancano, i computer non partono invece di partire senza restrizioni. Il firewall Proxmox del punto 3 fa da secondo livello verso la LAN, ma non protegge la LXC da se stessa; lo script sì.

### 5. Compose: copia del file upstream, modifiche marcate

`docker-compose/rakazo/docker-compose.yml` è `infra/compose/docker-compose.images.yml` della release `v0.8.0`, con modifiche cercabili con `grep homelab:`:

- tag fissi (`v0.8.0`) invece di `edge`, che si sposta a ogni build di `main`;
- `WEB_ORIGIN`, `BETTER_AUTH_URL`, `API_URL` e `RAKAZO_HOST` sull'hostname pubblico;
- `SIGNUPS_ENABLED=false`: gli account si creano con il comando `bootstrap-owner` lato server (niente email configurata, quindi una registrazione pubblica non sarebbe verificabile);
- `CLIENT_IP_HEADER=cf-connecting-ip`: l'unica strada per arrivare al web è Cloudflare → Traefik;
- porta 5173 aperta su tutte le interfacce (la chiude il firewall);
- un servizio `backup` in fondo.

Ho preferito copiare il file invece di usare l'installer `install-images.sh`: l'installer genera un `.env` locale con i segreti, che qui stanno su Infisical ([ADR-007](007-infisical-env-management.md)), e scarica i file a ogni esecuzione, fuori dal controllo di Renovate e del repo.

### 6. Segreti

`POSTGRES_PASSWORD`, `POSTGRES_APP_PASSWORD`, `BETTER_AUTH_SECRET`, `ENCRYPTION_KEY`, `SCREEN_PROXY_SECRET`, `SANDBOX_SUPERVISOR_TOKEN` su Infisical `prod/rakazo`, generati a caso. `ENCRYPTION_KEY` ha una seconda copia su 1Password: cifra i contenuti a riposo, e senza di essa un backup del database è inutile. I modelli si collegano dall'onboarding di Rakazo, non dal `.env`.

### 7. Backup

Ogni notte, verso `/var/lib/pve-persistent/rakazo-backups` su `pve` ([ADR-010](010-persistenza-dati-fuori-dalla-lxc.md)): `pg_dump` in formato custom, verificato con `pg_restore --list`, più un tar del volume `appdata` (home dei bot, file). Il dump lo fa il proprietario del database: `rakazo_app` è soggetto a row-level security e vedrebbe solo una parte delle righe.

### 8. Esposizione e aggiornamenti

`rakazo.alessandrogorla.it`: tunnel `Gorla` → Traefik-110 → `192.168.10.118:5173`. Niente forward-auth Authentik: Rakazo ha i propri account. Renovate senza automerge (pre-1.0), app e computer nello stesso gruppo, più un `customManager` regex per la variabile `RAKAZO_COMPUTER_IMAGE` del supervisor, che il manager docker-compose non legge.

## Alternative considerate

| Alternativa | Perché scartata |
|---|---|
| **Sulla LXC di Maus-117** | Stesso profilo di rischio, ma un supervisor con `docker.sock` accanto a OpenMausBot darebbe ai bot di Rakazo il controllo dei container di OpenMausBot e viceversa. |
| **Computer remoti (E2B, Daytona)** | Niente Docker nella LXC e niente `docker.sock`, quindi il rischio più grande sparisce. Scartati per costo e perché i dati dei bot finirebbero da terzi; restano l'opzione se Docker in LXC desse problemi. |
| **Disco su `local-lvm`** | Il pool è all'80% e condiviso: riempirlo mette a rischio tutte le LXC di `dell-emc`, non solo Rakazo. |
| **Disco su `NextcloudAle`** | Spazio ce n'è, ma il volume group è dedicato a Nextcloud: mescolarci altro confonde chi lo legge. |
| **Installer upstream (`install-images.sh`)** | Vedi punto 5: `.env` locale con i segreti e file scaricati a ogni esecuzione. |
| **VM QEMU** | Stesso ragionamento di ADR-012: nessuna VM gestita da Tofu nel repo. Qui pesa di più, perché `docker.sock` in una LXC unprivileged resta comunque dentro un kernel condiviso. |

## Conseguenze

> [!TIP] Positive
> - Primo disco di una LXC fuori dal thin pool: lo schema (`datastore` nella mappa) si può usare per spostare altre LXC e alleggerire `local-lvm`.
> - Il firewall di Maus-117 diventa un pattern riusabile: aggiungere una LXC isolata è una riga in `local.isolated_containers`.
> - Le LXC esistenti non cambiano: `datastore` ha default `local-lvm` e i `moved` evitano chiamate API sul firewall di Maus-117. Da confermare nel `plan`.

> [!WARNING] Da tenere presente
> - **`docker.sock` in una LXC.** Il supervisor ha il controllo del Docker della LXC; chi esce da un computer verso il supervisor ha quello. Il confine reale è la LXC unprivileged, non il compose.
> - **Docker in LXC unprivileged per i computer non è testato upstream.** Reti per bot, iptables e `DOCKER-USER` dentro il namespace della LXC vanno verificati al primo deploy. Se lo script non riesce, il ripiego è `SANDBOX_COMPUTER_EGRESS=open` con il solo firewall Proxmox a fare da muro, e va scritto qui.
> - **LVM thick non ha snapshot.** `vzdump` in modalità snapshot non funziona su questo disco; il backup vero è quello del servizio `backup`.
> - **Il backup è una sola copia sul nodo**, non 3-2-1, come per PACA, Karakeep e OpenMausBot. Gli archivi contengono contenuti cifrati e, nelle home, possibili credenziali dei bot: directory con `chmod 700`.
> - **Il compose è una copia da riallineare.** A ogni bump di versione il file upstream dello stesso tag va confrontato con questo: le variabili cambiano tra una release e l'altra e Renovate aggiorna solo i tag.
> - **Niente email.** Niente recupero password dalla pagina di login; nuovi account solo con `bootstrap-owner` da `pve`.
> - **Monitoring e Dockhand non vedono `Rakazo-118`**, come per Maus-117: il firewall lascia entrare solo Traefik e Ansible.
> - **Pre-1.0**: il progetto rilascia spesso e senza garanzie di compatibilità.

## Riferimenti

- Configurazione: [`variables.tf`](../../infrastructure/opentofu/nodes/dell-emc/variables.tf), [`firewall.tf`](../../infrastructure/opentofu/nodes/dell-emc/firewall.tf), [`docker-compose/rakazo/`](../../docker-compose/rakazo/), [`site.yml`](../../infrastructure/ansible/site.yml), [`dynamic.yml`](../../docker-compose/traefik/dynamic/dynamic.yml), [`renovate.json`](../../renovate.json)
- Upstream (v0.8.0): [`SETUP_PROMPT.md`](https://github.com/elie222/rakazo/blob/main/SETUP_PROMPT.md), [`docs/self-host.md`](https://github.com/elie222/rakazo/blob/v0.8.0/docs/self-host.md), [`docs/self-host-docker-computers.md`](https://github.com/elie222/rakazo/blob/v0.8.0/docs/self-host-docker-computers.md), [`docs/self-host-accounts.md`](https://github.com/elie222/rakazo/blob/v0.8.0/docs/self-host-accounts.md), [`docs/self-host-backups.md`](https://github.com/elie222/rakazo/blob/v0.8.0/docs/self-host-backups.md)
- [ADR-002](002-cloudflare-tunnel.md), [ADR-007](007-infisical-env-management.md), [ADR-010](010-persistenza-dati-fuori-dalla-lxc.md), [ADR-012](012-openmausbot.md)
