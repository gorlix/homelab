---
aliases:
  - ADR-014
  - Paperless-119
  - Paperless
tags:
  - adr
  - docker
  - backup
  - proxmox
  - region/ditta
  - service/paperless
status: accettato
date: 2026-11-13
related:
  - "[[002-cloudflare-tunnel]]"
  - "[[007-infisical-env-management]]"
  - "[[010-persistenza-dati-fuori-dalla-lxc]]"
  - "[[013-rakazo]]"
---

# ADR-014: Paperless-ngx su `Paperless-119`, con i dati su un LV dedicato

| | |
|---|---|
| **Stato** | Accettato: in produzione dal 13/11/2026. Backup offsite non ancora presente (vedi "Da tenere presente") |
| **Data** | 2026-11-13 |
| **Nodi coinvolti** | `dell-emc` (nuova LXC `Paperless-119`, vmid 119, `192.168.10.119`; LV `paperless-data` nel volume group `Storage`; Traefik-110 per l'esposizione) |

## Contesto

[Paperless-ngx](https://docs.paperless-ngx.com/) è un archivio documentale: scansioni e PDF entrano da una cartella o dall'app mobile, vengono letti con OCR e resi ricercabili. Qui ci finiranno documenti personali, quindi il servizio è l'opposto di un bot sacrificabile: se si perde il database o la cartella `media`, il danno è reale e non si recupera da una sessione di chat.

[ADR-010](010-persistenza-dati-fuori-dalla-lxc.md) nasce da un incidente esattamente di questo tipo: dati e backup sul disco della LXC, `tofu apply` che la ricrea, tutto perso. Con Paperless voglio evitare la stessa situazione fin dall'inizio, e non solo per i backup come è stato per PACA: tutti i dati devono stare fuori dalla LXC.

Il 13/11/2026 il thin pool `local-lvm` era all'81%, la stessa situazione di [ADR-013](013-rakazo.md). Un archivio documentale cresce e basta, e un thin pool che si riempie rompe tutte le LXC di `dell-emc`.

## Decisione

### 1. LXC dedicata `Paperless-119`

Unprivileged, 4 core, 4 GB di RAM, root da 20 GB sul datastore `Storage` (LVM thick, non il thin pool), come già per `Rakazo-118`. Lo stack è quello upstream con Postgres e Tika: `paperless-ngx` 3.4.2, `postgres:18`, `valkey` 9, `tika` 3.3.1.0, `gotenberg` 8.38. L'OCR è `ita+eng`; le lingue sono già nell'immagine, quindi non uso `PAPERLESS_OCR_LANGUAGES`, che le scaricherebbe a ogni avvio.

Nessun firewall Proxmox dedicato, a differenza di `Maus-117` e `Rakazo-118` ([ADR-012](012-openmausbot.md), [ADR-013](013-rakazo.md)): qui non gira codice arbitrario di agenti e non c'è `docker.sock` esposto a un servizio, quindi il rischio che quel firewall mitiga non c'è.

### 2. Dati su un LV dedicato, montato su `pve`

Il LV `paperless-data` (100 GB, ext4) sta nel volume group `Storage`. È montato su `pve` in `/var/lib/pve-persistent/paperless` con una riga in `fstab` con `nofail` e passato alla LXC come bind mount `mp1` su `/mnt/persistent-data`. Sul LV stanno `pgdata` (Postgres 18, montato su `/var/lib/postgresql`), `data`, `media`, `export` e `consume`. L'unico volume Docker locale è Valkey, che tiene solo la coda dei task e si può perdere.

Il bind mount segue lo schema di [ADR-010](010-persistenza-dati-fuori-dalla-lxc.md), con il nuovo attributo `data_host_path` nella voce della LXC:

- `pct set -mp1` lo lancia un provisioner `local-exec` in `main.tf` via SSH come `root@pam`, perché l'API Proxmox rifiuta i bind mount ai token. Parte solo se `mountpoint -q` conferma che l'LV è davvero montato.
- `lifecycle { ignore_changes = [mount_point] }` resta sul container, come in ADR-010: senza, il mount aggiunto a mano sarebbe drift e il plan sostituirebbe la LXC.
- La directory è di proprietà `100000:100000`, cioè il root della LXC unprivileged.
- La directory sottostante, quella che si vede quando l'LV non è montato, ha `chattr +i`: se il mount manca, le scritture falliscono invece di finire in silenzio sulla root di `pve`.

Il LV non è creato da OpenTofu: lo preparo a mano e i comandi sono nel [README](../../README.md#creare-un-lv-dati-dedicato-per-una-lxc).

### 3. Esposizione: `paperless.alessandrogorla.it`, senza forward-auth

Tunnel `Gorla` → Traefik-110 → `192.168.10.119:8000`. Non ho messo il forward-auth di Authentik davanti: bloccherebbe le chiamate API con token dell'app mobile, che non sanno completare un flusso di login nel browser. `PAPERLESS_PROXY_SSL_HEADER` è impostato perché il TLS lo termina Cloudflare e Traefik parla HTTP: senza, Django crede di essere su `http` e il redirect URI verso Authentik non coincide con quello registrato.

### 4. Login: OIDC nativo verso Authentik

Authentik è il provider OIDC (app `paperless`, un gruppo dedicato e un solo binding, come nel resto del modello di accessi). Il client sta in `PAPERLESS_SOCIALACCOUNT_PROVIDERS`. Le registrazioni sono chiuse sia per gli account locali sia per quelli social: un login Authentik si collega solo a un account locale già esistente, dal profilo dell'utente. Il login con password resta attivo finché l'admin non ha collegato il proprio account ad Authentik; poi `PAPERLESS_DISABLE_REGULAR_LOGIN=true` su Infisical lo spegne. Le API con token funzionano comunque.

### 5. Segreti

Su Infisical `prod/paperless` ([ADR-007](007-infisical-env-management.md)): `PAPERLESS_SECRET_KEY`, `PAPERLESS_DBPASS` e `PAPERLESS_SOCIALACCOUNT_PROVIDERS` (JSON con client id e secret OIDC). Nel repo solo i nomi.

### 6. Aggiornamenti

Renovate non fa automerge per l'immagine `paperless-ngx`: ogni release può portare migrazioni del database. Il PR si merge a mano, dopo aver letto le release notes. `postgres` ricade già nella regola delle immagini stateful.

## Alternative considerate

| Alternativa | Perché scartata |
|---|---|
| **Dati sul rootfs della LXC** | È lo schema che ha causato l'incidente di [ADR-010](010-persistenza-dati-fuori-dalla-lxc.md): un replace della LXC distrugge i dati. Per documenti personali non è accettabile. |
| **Volume sul thin pool `local-lvm`** | Il pool è all'81% e condiviso: se un archivio che cresce lo riempie, si rompono tutte le LXC di `dell-emc`, non solo Paperless. |
| **Forward-auth di Authentik davanti** | Blocca le API con token dell'app mobile. Il login OIDC nativo dà lo stesso SSO senza rompere le API. |
| **Paperless su `Docker-100`** | Documenti personali accanto agli altri servizi, con un ciclo di vita legato a quello della LXC condivisa. Una LXC dedicata si può aggiornare, fermare e ripristinare da sola. |

## Conseguenze

> [!TIP] Positive
> - I dati sopravvivono a un `destroy` e ricreazione della LXC: la LXC torna a essere sostituibile, i dati no.
> - Il thin pool non cresce per colpa di Paperless.
> - `data_host_path` è riusabile: un'altra LXC con dati in produzione è una voce in `variables.tf` più un LV preparato con gli stessi comandi.

> [!WARNING] Da tenere presente
> - **Il backup offsite non esiste ancora.** L'LV sta sullo stesso storage fisico del nodo: un guasto del disco porta via tutto. Oggi non è 3-2-1 e non è nemmeno una vera copia, solo dati fuori dalla LXC. Il piano (task HOME-49) è `document_exporter` più `pg_dump`, cifrati con `rclone crypt` su Google Drive, ancora da progettare. Fino ad allora non conviene tenere su Paperless l'unica copia di documenti insostituibili.
> - **Il LV non è gestito da OpenTofu.** Lo creo a mano e i passi sono documentati, ma un `tofu apply` su un nodo nuovo non lo ricrea.
> - **`nofail` vuol dire che la LXC può partire senza dati.** Se l'LV non monta al boot di `pve`, la LXC parte lo stesso: `chattr +i` impedisce che qualcosa scriva sulla root del nodo, ma Paperless va in errore invece di funzionare con un archivio vuoto. È il comportamento voluto, ma è un guasto da saper riconoscere.
> - **Il bind mount si aggiunge dopo la creazione** della LXC, con un riavvio, e non nello stesso passo del container. Il provisioner aspetta `sshd` prima di lasciare la mano ad Ansible: eseguito una volta, il 13/11/2026, su `Paperless-119`. È la parte meno collaudata, e un errore lì lascia la LXC senza il mount dei dati.
> - **Niente firewall Proxmox.** Una vulnerabilità in Paperless, Tika o Gotenberg darebbe accesso alla rete della LXC, senza un confine come quello di `Maus-117`.
> - **Funzioni non ancora attive.** L'ingest da email e l'integrazione con `paperless-gpt` (HOME-48) sono ancora da fare.
> - **Le migrazioni del database dipendono da me.** Senza automerge, un PR dimenticato lascia l'immagine indietro; con il backup assente, anche un upgrade andato male è più rischioso.

## Riferimenti

- Configurazione: [`variables.tf`](../../infrastructure/opentofu/nodes/dell-emc/variables.tf), [`main.tf`](../../infrastructure/opentofu/nodes/dell-emc/main.tf), [`docker-compose/paperless/`](../../docker-compose/paperless/), [`dynamic.yml`](../../docker-compose/traefik/dynamic/dynamic.yml), [`renovate.json`](../../renovate.json)
- Upstream: [documentazione Paperless-ngx](https://docs.paperless-ngx.com/), compose `docker-compose.postgres-tika.yml` della release 3.4.2
- [ADR-002](002-cloudflare-tunnel.md), [ADR-007](007-infisical-env-management.md), [ADR-010](010-persistenza-dati-fuori-dalla-lxc.md), [ADR-012](012-openmausbot.md), [ADR-013](013-rakazo.md)
