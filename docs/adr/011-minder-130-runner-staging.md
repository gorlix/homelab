---
aliases:
  - ADR-011
  - Minder-130
  - Runner staging
tags:
  - adr
  - docker
  - security
  - networking
  - region/ditta
  - service/minder
status: accettato
date: 2026-09-21
related:
  - "[[002-cloudflare-tunnel]]"
  - "[[005-topologia-multi-sito]]"
  - "[[009-paca]]"
  - "[[010-persistenza-dati-fuori-dalla-lxc]]"
---

# ADR-011: `Minder-130`, LXC dedicata per il runner di staging di project_minder

| | |
|---|---|
| **Stato** | Accettato — l'unità esiste ed è raggiungibile; runner e stack applicativo non ancora installati (per scelta, vedi sotto) |
| **Data** | 2026-09-21 (unità creata il 14/09/2026) |
| **Nodi coinvolti** | `dell-emc` (nuova LXC dedicata `Minder-130`, vmid 130, `192.168.10.130`) |

## Contesto

`project_minder` ha bisogno di un ambiente di staging: un runner GitHub Actions self-hosted più uno stack Docker Compose (`minder_server` e un reverse proxy Caddy), con un volume dati `pb_data` (SQLite) che deve sopravvivere a riavvii e manutenzione ordinaria.

Il runner deve poter creare e gestire container, quindi avrà accesso a Docker: un accesso equivalente a root sull'host che lo ospita. È la stessa classe di rischio di `agent-runner` in [ADR-009](009-paca.md).

La richiesta iniziale chiedeva anche l'esposizione di `api-minder.alessandrogorla.it` sulle porte 80 e 443 in ingresso, per la challenge ACME HTTP-01 di Let's Encrypt.

## Decisione

### 1. LXC dedicata, stesso schema di `Paca-120`

`Minder-130`: Rocky Linux 9, unprivileged con `nesting`, 1 vCPU, 2 GB di RAM, 10 GB su `local-lvm`. È una voce in più nella mappa `containers` di `infrastructure/opentofu/nodes/dell-emc/variables.tf`; Docker, Docker Compose e l'agente Hawser arrivano dai ruoli Ansible già esistenti (`common`, `hawser`), senza codice nuovo. Non condivide l'host con nessun altro servizio, per lo stesso motivo di ADR-009: la segmentazione di rete Docker non mitiga un accesso al socket, l'unica mitigazione reale è un host separato.

### 2. Nessuna porta in ingresso: Cloudflare Tunnel, non 80/443

Non ho aperto le porte 80 e 443. La Region B sta dietro un firewall Cisco gestito da terzi che non posso modificare, e la regola di tutto questo homelab è "nessuna porta in ingresso" ([ADR-002](002-cloudflare-tunnel.md), [ADR-005](005-topologia-multi-sito.md)). La richiesta lasciava esplicitamente la possibilità di instradare tramite un layer già esistente, ed è quello che ho fatto:

- Cloudflare Tunnel `Gorla` (quello di `dell-emc`): una regola ingress `api-minder.alessandrogorla.it` → `http://traefik:80`, più un record DNS CNAME proxato verso il tunnel. Stesso schema di `paca.alessandrogorla.it`.
- Traefik (`docker-compose/traefik/dynamic/dynamic.yml`): router per quell'host verso il backend statico `http://192.168.10.130:80`.
- Il Caddy dello stack di staging servirà solo `:80`, **senza ACME**: il TLS termina sul bordo Cloudflare, come per il gateway di PACA. La challenge HTTP-01 non serve, e di conseguenza non serve nemmeno la porta 443 sull'unità.

### 3. Il provisioning si ferma all'unità

Il campo `services` di `Minder-130` è vuoto. La registrazione del runner, il clone del repository, il `.env` e il `docker-compose.yml` di `minder-server`/Caddy sono fatti a mano, dopo. Aggiungere `minder-server` a `services` solo quando `docker-compose/minder-server/` esiste nel repository, altrimenti il ruolo `docker_service` fallisce nel `copy`.

### 4. Prerequisito per ogni nuovo host: il token Hawser su Infisical

Ogni host del gruppo `docker_nodes` deve avere una cartella Infisical `/<nome-host>` con il secret `HAWSER_TOKEN` (ambiente `prod`), letto dal ruolo `infisical_secrets` per **tutti** gli host ad ogni run. Senza, l'intero playbook fallisce: è successo con `Minder-130` ed è la causa scatenante dell'incidente descritto in [ADR-010](010-persistenza-dati-fuori-dalla-lxc.md). Va creata prima del primo `apply` di un nuovo host.

## Alternative considerate

| Alternativa | Perché scartata |
|---|---|
| **Aprire 80 e 443 in ingresso e lasciare a Caddy la challenge ACME** | Richiede una regola sul firewall Cisco che non controllo, ed è l'esatto contrario del principio "solo traffico in uscita" su cui poggia l'esposizione di tutti gli altri servizi. |
| **ACME con challenge DNS-01 su Cloudflare** | Avrebbe evitato le porte in ingresso ma inutilmente: con il tunnel il TLS pubblico lo gestisce già Cloudflare, e un certificato locale in più sarebbe un segreto in più da gestire. |
| **Runner su `Docker-100` o `Paca-120`** | Condividerebbe il blast radius di un accesso Docker con Nextcloud/Authentik/bot o con i dati di PACA. |
| **Una VM invece di una LXC** | Isolamento migliore (kernel separato) e Docker nativo, ma su questo nodo tutto il tooling (OpenTofu, Ansible, Hawser) è già scritto per LXC. Non ho valutato il costo reale di una VM: resta un'opzione se l'isolamento di una LXC risultasse insufficiente. |

## Conseguenze

> [!TIP] Positive
> - Unità pronta senza codice nuovo: Docker, Docker Compose (v5.5.1) e Hawser attivi, verificati con `docker ps` dopo il deploy.
> - Nessuna nuova superficie in ingresso: stessa catena Cloudflare → Traefik → backend di tutti gli altri servizi.

> [!WARNING] Da tenere presente
> - **`api-minder.alessandrogorla.it` risponde `502` finché lo stack non è deployato.** La route Traefik e il tunnel sono già cablati per scelta; è il comportamento atteso, non un guasto.
> - **`pb_data` oggi vive sul disco della LXC.** Sopravvive a un riavvio, ma non a un destroy+recreate, cioè lo stesso rischio che ha fatto perdere i dati di PACA ([ADR-010](010-persistenza-dati-fuori-dalla-lxc.md)). Prima di metterci dati reali va impostato `backup_host_path` e un backup dell'SQLite (una copia coerente, non del file live) verso quella directory. Per una LXC esistente il bind mount va aggiunto a mano con `pct set`, perché il provisioner gira solo alla creazione.
> - **Isolamento da verificare.** Un runner con accesso Docker è root sulla LXC; il resto della rete `192.168.10.0/24` è raggiungibile da lì come da ogni altra LXC. Non ho applicato nessuna regola di rete per limitarlo. Lo stesso vale per `nesting`: non ho provato un build reale nel runner, quindi non so se basta o se serve `keyctl`.
> - **Un `apply` che ricrea la LXC cancella il runner registrato e i dati.** Vale per qualunque modifica che marca `forces replacement`, chiavi SSH incluse. Va ricordato prima di ruotare le chiavi.
> - **I 10 GB di disco sono quelli richiesti, non una stima mia**: immagini Docker e `pb_data` potrebbero crescere più di così.

## Riferimenti

- Configurazione: [`infrastructure/opentofu/nodes/dell-emc/variables.tf`](../../infrastructure/opentofu/nodes/dell-emc/variables.tf), [`docker-compose/traefik/dynamic/dynamic.yml`](../../docker-compose/traefik/dynamic/dynamic.yml)
- [ADR-002](002-cloudflare-tunnel.md) — esposizione con Cloudflare Tunnel e Traefik
- [ADR-005](005-topologia-multi-sito.md) — il vincolo di rete della Region B
- [ADR-009](009-paca.md) — lo stesso schema di isolamento per un accesso a `docker.sock`
- [ADR-010](010-persistenza-dati-fuori-dalla-lxc.md) — perché `pb_data` non va lasciato solo sul disco della LXC
