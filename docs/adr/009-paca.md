---
aliases:
  - ADR-009
  - PACA
tags:
  - adr
  - docker
  - security
  - region/ditta
  - service/paca
status: accettato
date: 2026-08-29
related:
  - "[[002-cloudflare-tunnel]]"
  - "[[007-infisical-env-management]]"
  - "[[008-docker-compose-management]]"
---

# ADR-009: PACA su LXC dedicata (Paca-120)

| | |
|---|---|
| **Stato** | Accettato — in produzione, con più incidenti reali affrontati durante il primo deploy (vedi "Da tenere presente") |
| **Data** | 2026-08-29 |
| **Nodi coinvolti** | `dell-emc` (nuova LXC dedicata `Paca-120`, non `Docker-100`) |

## Contesto

[PACA](https://github.com/Paca-AI/paca) è una piattaforma di project management AI-native (board/sprint condivisi tra umani e agenti AI) aggiunta ai servizi self-hosted. Lo script di installazione ufficiale (`scripts/install.sh`, download-and-run non tracciato, pensato per "nessun clone del repository necessario") non è compatibile con le convenzioni di questo repository: docker-compose versionato, segreti via Infisical, deploy via Ansible/OpenTofu (vedi [ADR-008](008-docker-compose-management.md) e la skill `.claude/skills/new-docker-service/`).

Il punto che ha reso questo deploy diverso dagli altri 8 servizi già versionati: **`agent-runner`**, il componente che esegue le sandbox decise dall'agente AI, richiede accesso a `/var/run/docker.sock` dell'host per creare container sibling e un sidecar `docker:dind` per conversazione — un accesso equivalente a root sull'intero daemon Docker di quell'host, non solo sulla propria rete o sui propri container.

## Decisione

### 1. Compose riscritto dall'upstream, non lo script ufficiale

`docker-compose/paca/docker-compose.yml` è adattato da `deploy/docker-compose.prod.yml` del repository upstream (release `v0.13.3`) — già di per sé senza segreti letterali (usa solo `${VAR}`/`${VAR:?...}`). Differenze rispetto all'upstream: porta 443 del gateway rimossa (TLS termina su Cloudflare Tunnel + Traefik, non su Caddy interno), immagini pinnate a `0.13.3` invece di `:latest`. Segreti (application + non-segreti che comunque passano per `.env`) migrati su Infisical, cartella `/paca`, stesso schema di [ADR-007](007-infisical-env-management.md).

### 2. LXC dedicata (`Paca-120`), non `Docker-100`

Motivo: `Docker-100` ospita già Nextcloud, Authentik e i bot pubblici. Condividere quell'host con un container che ha accesso pieno al socket Docker avrebbe condiviso il loro blast radius con qualunque cosa l'agente AI di PACA decida (o sia indotto) a fare. **La segmentazione di rete Docker non mitiga questo rischio**: chi ha accesso al socket controlla l'intero daemon indipendentemente dalla rete assegnata al container — verificato ragionando sul meccanismo, non assunto. L'unica mitigazione reale è un host separato.

`Paca-120` (vmid 120, `192.168.10.120`) è stata aggiunta a `infrastructure/opentofu/nodes/dell-emc/variables.tf` con lo stesso pattern di `Docker-100`/`Traefik-110`. `features.nesting = true` (già generico per ogni container del `for_each`) dà il supporto di base per Docker-in-Docker.

### 3. Esposizione pubblica via Cloudflare Tunnel + Traefik

Stesso schema di Infisical/1Password Connect ([ADR-002](002-cloudflare-tunnel.md)): `Paca-120` è un host diverso da `Traefik-110`, quindi Traefik lo raggiunge come backend statico per IP (`docker-compose/traefik/dynamic/dynamic.yml`), non via provider Docker. Esposto pubblicamente (non solo LAN/Tailscale) per una ragione specifica: permettere a Claude e ad altri agenti AI esterni di accedere a PACA direttamente, non solo a me da dentro casa/ditta.

## Alternative considerate

| Alternativa | Perché scartata |
|---|---|
| **Restare su `Docker-100` con un `docker-socket-proxy` davanti al socket reale** | Mitigazione parziale, non isolamento: `agent-runner` ha comunque bisogno di creare container e sidecar `docker:dind`, quindi il proxy dovrebbe comunque permettere gran parte delle chiamate pericolose. Scartata a favore di un host dedicato, unica mitigazione reale per questo rischio specifico. |
| **Kong Gateway al posto del gateway Caddy/di Traefik** | Proposta durante la sessione come possibile soluzione al rischio `docker.sock`. Scartata: Kong è un API gateway L7 (routing/auth/rate-limiting sulle richieste HTTP), un livello completamente diverso da "chi può controllare il daemon Docker dell'host" — non avrebbe cambiato nulla sull'isolamento reale. |
| **Segmentazione di rete Docker (reti Docker separate per `agent-runner`)** | Stessa ragione della prima riga: il socket bypassa completamente l'isolamento di rete, chi lo controlla comanda l'intero host indipendentemente da quale rete Docker gli è assegnata. |

## Conseguenze

> [!TIP] Positive
> - Isolamento reale del rischio `docker.sock`: un problema con `agent-runner` (bug, prompt injection, uso improprio) resta confinato a `Paca-120`, non si estende a Nextcloud/Authentik/bot su `Docker-100`.
> - Segreti (13 chiavi: `JWT_SECRET`, `ADMIN_USERNAME`/`ADMIN_PASSWORD`, `ENCRYPTION_KEY`, `INTERNAL_API_KEY`, `AGENT_API_KEY`, `POSTGRES_*`, `STORAGE_*`, `PUBLIC_URL`, `SITE_ADDRESS`) su Infisical fin dall'inizio, mai passati per un `.env` versionato.
> - Deploy verificato end-to-end il 29/08/2026: `https://paca.alessandrogorla.it/api/healthz` risponde `200` attraverso l'intera catena Cloudflare → Traefik → gateway Caddy → API.

> [!WARNING] Da tenere presente
> - **Rischio residuo, non eliminato**: `agent-runner` ha comunque accesso pieno al `docker.sock` di `Paca-120`. L'isolamento limita il danno a quell'host specifico, non lo azzera — non è lo stesso livello di sicurezza di un servizio senza accesso al socket.
> - **Docker-in-Docker non ancora verificato in pratica**: il sidecar `docker:dind` che `agent-runner` crea per conversazione si materializza solo alla prima sandbox effettivamente avviata da un utente/agente. `features.nesting = true` ha permesso ad `agent-runner` di partire e restare `Up` (non più in crash loop), ma questo non prova che il DinD interno funzioni davvero su una LXC unprivileged — se una sandbox reale fallisce ad avviarsi, il prossimo passo è aggiungere `features.keyctl = true` in `infrastructure/opentofu/nodes/dell-emc/variables.tf` (impatta tutti i container del `for_each`, va verificato che non rompa `Docker-100`/`Traefik-110` prima di applicarlo).
> - **Incidente reale durante il primo deploy: tre secret troncati di un carattere.** `ENCRYPTION_KEY`, `INTERNAL_API_KEY` e `AGENT_API_KEY` (attesi a 64 caratteri hex) sono stati scritti su Infisical con 63 caratteri — un errore di trascrizione manuale nel passare i valori generati a `mcp__infisical__create-secret`, non rilevato perché la verifica di lunghezza era stata fatta sul valore *generato*, non su quello poi effettivamente scritto. Effetto: `agent-runner` in crash loop immediato (`decode hex key: odd length hex string`), mentre `api`/`minio` restavano `healthy` perché non validano quella stringa così a fondo all'avvio — bug silenzioso su un solo container, facile da non notare guardando solo `docker ps` per gli altri. Fix: valori rigenerati e riscritti con `update-secret`, lunghezza verificata via script (`${#v}` + regex hex) prima di scriverli, non più a occhio sull'output di un comando.
> - **`tofu apply` non riesegue Ansible se l'inventory generato non cambia.** `terraform_data.run_ansible` ha un `triggers_replace` legato al content hash di `local_file.ansible_inventory` — se `variables.tf` non aggiunge/toglie host o servizi, un nuovo `apply.sh apply` risulta in "no changes" e **non** rilancia Ansible, anche se serve rigenerare un `.env` da Infisical (es. dopo aver corretto un secret). In quel caso va lanciato `infrastructure/ansible/run.sh` direttamente (percorso già pensato per l'esecuzione standalone, vedi [ADR-008](008-docker-compose-management.md)), non basta ripetere l'apply.
> - **Le chiavi SSH private di TUTTI i container (`Docker-100`, `Traefik-110`, `Paca-120`) sono finite in chiaro in una sessione di chat durante un `tofu apply` fallito.** Tofu sopprime l'output "sensitive" solo quando il provisioner `local-exec` riesce; nel dump dell'errore di un provisioner fallito stampa il comando completo, heredoc delle chiavi incluso, senza redazione — comportamento di Tofu stesso, non uno specifico di questo repository. Le tre chiavi sono state trattate come compromesse e ruotate (`tofu state rm` sulle risorse `tls_private_key.container_ssh_keys[...]` + nuovo apply, che le rigenera e le riscrive automaticamente su 1Password).
> - **Trovato — non causato da questo deploy, ma scoperto mentre si risolveva un problema di accesso**: l'account amministratore di Infisical aveva `username` (`admin@homelab.internal`) diverso da `email` (l'email reale dell'autore). Il flusso "password dimenticata" di Infisical cerca l'utente per `username`, non per `email`, nonostante l'etichetta del campo nella UI dica "email" — inserire l'email reale fallisce silenziosamente ("Failed to find user data" nei log, nessun errore visibile in UI). Corretto allineando `username` all'email reale via UPDATE diretto sulla tabella `users` (colonna innocua, non tocca hash/chiavi di cifratura) dopo essere rientrati nell'account con lo username corretto.
> - **Cache DNS negativa, non un problema di questo repository ma utile da ricordare per il prossimo servizio esposto via Cloudflare Tunnel**: subito dopo aver aggiunto il Public Hostname per `paca.alessandrogorla.it`, il dominio risultava irraggiungibile da una macchina che l'aveva già interrogato (e ricevuto NXDOMAIN) prima che la route esistesse — `systemd-resolved` (e qualunque resolver ricorsivo) mette in cache anche le risposte negative, per il tempo indicato dal campo *minimum* della SOA della zona (1800s per `alessandrogorla.it`). Fix: `resolvectl flush-caches` (non un generico "flush dns"). Da aspettarsi ogni volta che si testa un hostname nuovo subito dopo averlo creato.

## Riferimenti

- [PACA — repository upstream](https://github.com/Paca-AI/paca)
- Configurazione: [`docker-compose/paca/`](../../docker-compose/paca/), [`infrastructure/opentofu/nodes/dell-emc/variables.tf`](../../infrastructure/opentofu/nodes/dell-emc/variables.tf)
- [ADR-002](002-cloudflare-tunnel.md) — schema di esposizione pubblica e backend statico cross-host riusato qui
- [ADR-007](007-infisical-env-management.md) — convenzioni delle cartelle Infisical usate per i segreti di PACA
- [ADR-008](008-docker-compose-management.md) — pattern di versionamento del compose e comportamento di `terraform_data.run_ansible`
