---
aliases:
  - ADR-010
  - Persistenza dati
  - Incidente PACA
tags:
  - adr
  - backup
  - proxmox
  - incident
  - region/ditta
  - service/paca
status: accettato
date: 2026-09-21
related:
  - "[[006-1password-connect]]"
  - "[[008-docker-compose-management]]"
  - "[[009-paca]]"
---

# ADR-010: Persistenza dei dati fuori dalla LXC, dopo la perdita dei dati di PACA

| | |
|---|---|
| **Stato** | Accettato — in produzione per `Paca-120`. È una prima copia fuori dalla LXC, non una strategia 3-2-1 (vedi "Da tenere presente") |
| **Data** | 2026-09-21 (incidente: 14-17/09/2026) |
| **Nodi coinvolti** | `dell-emc` (nodo Proxmox `pve` e LXC `Paca-120`; toccate per errore anche `Traefik-110` e `Minder-130`) |

## Contesto

Il 14/09/2026, aggiungendo una nuova LXC (`Minder-130`, vedi [ADR-011](011-minder-130-runner-staging.md)), il primo `tofu apply` è fallito a metà: il provisioner Ansible non trovava il token Hawser del nuovo host su Infisical. Quando il provisioner `local-exec` fallisce, OpenTofu stampa il comando completo, **compresi gli heredoc con le chiavi private SSH di tutti i container** — lo stesso comportamento già documentato in [ADR-009](009-paca.md). Le chiavi sono finite in chiaro in una sessione di chat, quindi le ho trattate come compromesse e ho deciso di ruotarle.

Per ruotarle si è seguito il precedente di ADR-009: `tofu state rm` sulle risorse `tls_private_key` e nuovo `apply`, **presupponendo che la LXC venisse aggiornata sul posto**. Non era vero. Il plan mostrava `# forces replacement` sull'attributo `initialization.user_account.keys`, ma non è stato notato prima della conferma: `Traefik-110`, `Paca-120` e `Minder-130` sono state **distrutte e ricreate da zero**, con disco root nuovo. Solo `Docker-100` si è salvata, per caso: il suo `state rm` non era andato a buon fine.

`Paca-120` era in produzione. I suoi dati (database Postgres, volumi Valkey e MinIO) stavano in volumi Docker sul disco della LXC, e i backup automatici di `db-backup` scrivevano su `./backups`, **sullo stesso disco**. Backup e dati sono spariti insieme. I dati sono stati recuperati solo perché l'autore ha trovato un dump in cache sul proprio computer.

La sequenza è poi peggiorata per una serie di scoperte a catena:

1. Il primo `docker compose up` sulla LXC ricreata è fallito: `minio/minio:latest` non è più scaricabile da Docker Hub (`repository does not exist or may require 'docker login'`). Il pull da `quay.io/minio/minio` ha funzionato, quindi con ogni probabilità MinIO ha spostato lì le build open source; non ho verificato la motivazione. Il deploy originale del 29/08 aveva probabilmente funzionato perché l'immagine era già in cache.
2. Per mettere i backup fuori dalla LXC ho provato un blocco `mount_point` nativo del provider. L'API Proxmox l'ha rifiutato (`403: mount point type bind is only allowed for root@pam`) **dopo** che la LXC era già stata distrutta: `Paca-120` non esisteva più, e tra il 17/09 e il 21/09 circa PACA è rimasto irraggiungibile.
3. La ricreazione è poi fallita di nuovo in Ansible con `No space left on device`: il thin pool `local-lvm` di `pve` era al 100% (flag `D`, out of data space), quindi le scritture fallivano per tutte le LXC su quel pool.

## Decisione

### 1. Backup su una directory del nodo Proxmox, montata dentro la LXC

`/var/lib/pve-persistent/paca-backups` su `pve` (fuori dal disco di qualunque LXC) è montata come bind mount in `/mnt/persistent-backups` dentro `Paca-120`. `docker-compose/paca/` usa quel path come `BACKUP_DIR` di default, quindi `db-backup` scrive lì. Distruggere e ricreare la LXC non tocca la directory: viene solo rimontata.

Nel codice è un campo opzionale `backup_host_path` per ogni container in `infrastructure/opentofu/nodes/dell-emc/variables.tf`; se è `null` non succede nulla. Oggi è impostato solo per `Paca-120`.

### 2. Il bind mount si fa con `pct set` via SSH, non con l'API

L'API Proxmox non permette mount point di tipo bind a nessun token API, indipendentemente dai privilegi. Un provisioner `local-exec` in `main.tf` esegue quindi `pct set` via SSH come root sul nodo, lo stesso meccanismo già usato per il bootstrap SSH. Tre dettagli sono necessari e non ovvi:

- `chown 100000:100000` sulla directory: la LXC è unprivileged, il suo root è l'uid 100000 dell'host. Senza, `db-backup` non può scrivere.
- `pct reboot`: un mount point aggiunto a un container già avviato si attiva solo al riavvio. Senza, Ansible farebbe partire `db-backup` prima che il mount esista e Docker creerebbe `/mnt/persistent-backups` sul disco della LXC, **in silenzio**: backup di nuovo effimeri, cioè esattamente il problema da evitare.
- Un ciclo di attesa su `sshd`, perché Ansible parte subito dopo.

### 3. Regola operativa: mai un `apply` che può ricreare una LXC senza un backup fuori dalla LXC

Prima di ogni modifica a `variables.tf`/`main.tf` che tocca una LXC con dati: `plan`, cercare `forces replacement`, e se c'è, dump verificato (`gzip -t`) copiato fuori dalla LXC. È la regola che avrebbe evitato l'incidente. I dump da conservare a lungo vanno nominati fuori dal pattern del pruner (`keep-*`, non `paca-*`), che cancella i `paca-*.sql.gz` più vecchi di 7 giorni.

### 4. Correzioni collaterali

- `minio` da `quay.io/minio/minio:latest` invece di Docker Hub, in `docker-compose/paca/docker-compose.yml`.
- `fstrim` sulle LXC in esecuzione per riportare il thin pool dal 100% al 70%.
- Per rieseguire solo il deploy senza rischiare un nuovo dump di chiavi, usare `infrastructure/ansible/run.sh` invece di `tofu apply`.

### Procedura di ripristino (verificata il 21/09/2026)

Su `Paca-120`, in `/opt/paca`, con un dump in `/mnt/persistent-backups`:

```
docker compose stop api realtime agent-runner gateway web db-backup
docker compose exec -T postgres psql -U paca -d postgres -v ON_ERROR_STOP=1 \
  -c "DROP DATABASE paca WITH (FORCE)" -c "CREATE DATABASE paca OWNER paca"
zcat /mnt/persistent-backups/<dump>.sql.gz \
  | docker compose exec -T postgres psql -U paca -d paca -1 -v ON_ERROR_STOP=1 -q
docker compose up -d
```

`-1` esegue il restore in una sola transazione: se fallisce, il database resta vuoto invece che a metà. Il `DROP DATABASE` è una scelta da fare a mano e con il database verificato vuoto.

## Alternative considerate

| Alternativa | Perché scartata |
|---|---|
| **Blocco `mount_point` nativo del provider `bpg/proxmox`** | Provato per primo. Rifiutato dall'API (`root@pam` richiesto per i bind mount) e, in ogni caso, anche aggiungerlo a una LXC esistente forza la sostituzione del container. |
| **Volume aggiuntivo gestito da Proxmox (`local-lvm`) come secondo disco** | Un volume di storage appartiene a un vmid: quando il provider ricrea il container lo distrugge insieme al resto. Non risolve il problema. |
| **Push dei dump su S3 (Cubbit o R2) dal container `db-backup`** | La soluzione più robusta, e resta la seconda copia da aggiungere (ADR-004, sulla strategia 3-2-1, è ancora da scrivere). Rimandata perché richiede un account e credenziali che oggi non ci sono, e l'urgenza era un posto che sopravvivesse alla LXC. |
| **Solo ripristinare e andare avanti** | I dati di produzione sarebbero stati esposti allo stesso rischio al prossimo `apply` che tocca la LXC. |

## Conseguenze

> [!TIP] Positive
> - I backup di PACA sopravvivono a un destroy+recreate della LXC. Verificato dal vivo il 21/09/2026: backup manuale lanciato dal container, file comparso su `pve` con owner `100000` e `gzip -t` valido.
> - Il ripristino è stato provato davvero: 66 task, 5 utenti e 28 documenti tornati, e le migrazioni di PACA `0.16.3` sono partite correttamente sopra uno schema `0.14.1`.
> - Errori latenti trovati e corretti: immagine MinIO non più su Docker Hub, thin pool sovra-allocato, `apply.sh` che appende `-var` a comandi che non lo accettano (`state rm`).

> [!WARNING] Da tenere presente
> - **Dati persi, non recuperabili.** Tutto ciò che è stato scritto in PACA dopo il backup trovato in cache e prima del 14/09 è perso, e non so quantificarlo. Quel che è stato scritto tra il dump di sicurezza del 16/09 e la distruzione del 17/09 è perso a sua volta. Gli **allegati su MinIO** non erano nel dump e non sono recuperabili: se il database li referenzia, risultano mancanti. I **plugin** `checklist` e `github` di PACA vivevano nel volume `/plugins`, anch'esso perso: l'API li segnala come non caricabili e vanno reinstallati dall'interfaccia.
> - **Questa non è una strategia 3-2-1.** La directory sta sul volume root di `pve` (`pve-root`): sopravvive alla distruzione della LXC, ma non alla perdita del nodo o del suo disco. Manca una seconda copia fuori dall'host (S3 o simile).
> - **Un `agent-runner` compromesso può cancellare i propri backup.** Il motivo per cui `Paca-120` esiste ([ADR-009](009-paca.md)) è che `agent-runner` ha accesso a `docker.sock`, cioè è root sulla LXC, e la LXC ha il bind mount in scrittura sulla directory dei backup. Il rischio che l'isolamento doveva contenere non è coperto da questo meccanismo. Una copia pull-based da `pve` verso un altro posto risolverebbe.
> - **Il bind mount è applicato solo alla creazione.** Il provisioner `local-exec` gira quando la LXC viene creata, non ad ogni `apply`. Per una LXC esistente il mount va aggiunto a mano con `pct set`; un'eventuale deriva non viene rilevata.
> - **Le chiavi SSH restano da ruotare bene.** Sono state esposte in chat tre volte in questa sessione (`Docker-100` mai ruotata). Ruotarle oggi ricreerebbe di nuovo le LXC. La correzione strutturale non è ancora fatta: scollegare le chiavi da `initialization.user_account.keys` (con `ignore_changes`) e passarle al provisioner via `environment` invece che nel testo del comando, così una rotazione non ricrea più i container e un errore non le stampa.
> - **`terraform_data.run_ansible` è rimasto `tainted`** dopo il fallimento, e il prossimo `tofu apply` rieseguirebbe l'intero playbook. Va fatto `tofu untaint`, oppure usato `run.sh` per i deploy.
> - **ADR-009 aveva dato l'impressione sbagliata.** Documentava la precedente rotazione delle chiavi come avvenuta senza problemi. Quella volta `Paca-120` era appena stata deployata, quindi con ogni probabilità fu ricreata già allora, senza dati da perdere e senza che nessuno se ne accorgesse. Non è stato verificato a posteriori.
> - **Il thin pool `local-lvm` resta sovra-allocato.** `fstrim` l'ha portato al 70%, ma senza un `pct fstrim` periodico si riempie di nuovo. Non ho ancora configurato né il cron né un alert sul `Data%`: al 100% le scritture falliscono per tutte le LXC sul pool, produzione compresa.
> - **Errori di processo** (vedi [ADR-000](000-metodologia-ai.md) sull'uso dell'assistenza AI). La rotazione è stata presentata come "in-place" dall'assistente AI, che si è fidato del precedente di ADR-009 senza verificarlo nel plan; l'`apply` è stato poi confermato senza rileggere il plan fino a `forces replacement`. Con il `mount_point` la sostituzione era invece nota e accettata, con un dump verificato fuori dalla LXC; quello che non era previsto è che l'API rifiutasse la creazione **dopo** la distruzione, lasciando il container inesistente per giorni (con lo stesso vmid non esiste un `create_before_destroy`). Nel primo caso il plan era leggibile e non è stato letto con abbastanza attenzione. La regola al punto 3 della Decisione nasce da qui.

## Riferimenti

- Configurazione: [`infrastructure/opentofu/nodes/dell-emc/`](../../infrastructure/opentofu/nodes/dell-emc/) (`variables.tf`: campo `backup_host_path`; `main.tf`: provisioner `pct set`), [`docker-compose/paca/`](../../docker-compose/paca/)
- [ADR-009](009-paca.md) — PACA su LXC dedicata, e il precedente di rotazione delle chiavi che ho seguito
- [ADR-006](006-1password-connect.md) — dove vivono le chiavi SSH generate da OpenTofu e i limiti dello state
- [ADR-008](008-docker-compose-management.md) — `run.sh` e il comportamento di `terraform_data.run_ansible`
- [Proxmox VE — Linux Container](https://pve.proxmox.com/wiki/Linux_Container) — sezione sui mount point; l'errore che ho visto dice che i bind mount richiedono `root@pam`
