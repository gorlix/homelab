# Contesto progetto: Homelab Portfolio

Questo file fornisce contesto persistente per Claude Code su questo repository. Leggerlo interamente prima di proporre modifiche a struttura, documentazione o configurazioni.

## Obiettivo del progetto

Repository GitHub pubblico che documenta e — progressivamente — definisce come codice (GitOps) l'homelab personale dell'autore. Ha esplicitamente uno **scopo di portfolio tecnico** da mostrare in CV/colloqui: la qualità e l'onestà della documentazione contano quanto il codice stesso.

## Hardware (fisso, non modificare senza conferma esplicita)

| Nodo | CPU | Ruolo |
|---|---|---|
| `dell-emc` | 16 × Intel Xeon Silver 4110 @ 2.10GHz | Produzione + sperimentazione + k8s (WIP) |
| `hp-laptop` | 4 × Intel Core i5-6200U @ 2.30GHz | Hub domotico, Traefik, Tailscale, AdGuard primario |
| `thinkcentre` | 4 × Intel Core i3-4130 @ 3.40GHz | Frigate NVR, AdGuard backup |

Tutti e 3 su **Proxmox VE**.

**Topologia multi-sito (2 region) — vedi ADR-005:**
- **Region A — Casa:** `hp-laptop` + `thinkcentre` in **cluster Proxmox** sulla stessa LAN. Cloudflare Tunnel proprio + Traefik su `hp-laptop`. Tailscale **solo** su `hp-laptop`.
- **Region B — Ditta:** `dell-emc` Proxmox **standalone**, VLAN dedicata dietro firewall Cisco **gestito da terzi** (rete non controllata dall'autore). Cloudflare Tunnel ad-hoc + Traefik propri. Nodo Tailscale proprio.
- **Interconnessione:** overlay Tailscale `hp-laptop` ↔ `dell-emc`. `thinkcentre` niente Tailscale (raggiungibile solo dentro LAN casa).
- Ogni region ha esposizione indipendente (tunnel + Traefik propri): domini di guasto separati, nessuna porta in ingresso, solo traffico in uscita. Vincolo chiave: la rete della Region B non è modificabile dall'autore.

## Servizi attuali per nodo

**hp-laptop**
- Home Assistant (hub domotica — componente di punta, da documentare con cura). Backup 3-2-1 multi-destinazione: Cloudflare R2 (2 copie: milestone + daily), Google Drive (4 copie: milestone, daily, parziali solo-Zigbee), copia locale sul dispositivo
- Traefik (reverse proxy)
- Tailscale
- AdGuard Home (istanza primaria/origin)
- Cloudflare Tunnel

**thinkcentre**
- Frigate (videosorveglianza)
- AdGuard Home (istanza backup/replica)

**dell-emc**
- Bot pubblici (hosting)
- Nextcloud (backup su S3 Cubbit)
- Authentik (SSO centralizzato)
- Monitoring infrastruttura
- Nodi Kubernetes (work in progress)
- Traefik (reverse proxy della Region B)
- Cloudflare Tunnel (ad-hoc per la Region B)
- Tailscale (nodo di interconnessione con la Region A)

## Stack tecnologico deciso

| Area | Strumento | Stato |
|---|---|---|
| Provisioning | OpenTofu (`bpg/proxmox` provider) | Da iniziare |
| Config management | Ansible | Da iniziare |
| Servizi | Docker Compose | Esistente, da versionare/sanitizzare |
| Orchestrazione | Kubernetes + Flux CD | WIP |
| DNS HA | AdGuard Home + **Keepalived/VRRP** (failover IP) + **adguardhome-sync** (bakito/adguardhome-sync, sync config origin→replica) | Documentato in ADR-001 |
| Secret management | **1Password** (Connect self-hosted su hp-laptop via Tailscale, + Service Accounts per CI/Ansible/Terraform) | Deciso, da implementare (ADR-006, non ancora scritto per esteso) |
| Documentazione | MkDocs Material + GitHub Pages | Da impostare |
| CI | GitHub Actions (lint, validate, gitleaks) | Da impostare |

## Struttura repository

```
homelab/
├── README.md
├── docs/
│   └── adr/                   # Architecture Decision Records
├── terraform/
│   └── nodes/{dell-emc,hp-laptop,thinkcentre}/
├── ansible/
├── docker/
│   ├── traefik/
│   ├── adguard/
│   │   ├── keepalived/
│   │   └── sync/              # config adguardhome-sync
│   ├── frigate/
│   ├── nextcloud/
│   ├── authentik/
│   └── monitoring/
├── kubernetes/
├── home-assistant/
└── .github/workflows/
```

## ADR scritti finora

- **ADR-000** — Metodologia di lavoro e uso di strumenti AI (meta-ADR, leggere per capire come trattare l'assistenza AI in questo repo)
- **ADR-001** — DNS HA con Keepalived/VRRP + adguardhome-sync
- **ADR-005** — Topologia multi-sito (2 region) e separazione dei ruoli tra i nodi

## ADR ancora da scrivere (menzionati nel README come placeholder)

- ADR-002 — Cloudflare Tunnel invece di port forwarding
- ADR-003 — Authentik come SSO centralizzato
- ADR-004 — Strategia di backup 3-2-1 Nextcloud su S3 Cubbit
- ADR-006 — Secret management con 1Password Connect

## Convenzioni stabilite

**Formato ADR:** Contesto → Decisione → Alternative considerate → Conseguenze → Riferimenti. Includere sempre una sezione "Da tenere presente" onesta sui limiti reali della soluzione, non solo i pregi.

**Commit:** Conventional Commits (`feat(traefik): ...`, `docs(adr): ...`). Dove l'assistenza AI è stata sostanziale nella stesura di un documento, segnalarlo nel messaggio, es: `docs(adr): draft AI-assisted, reviewed and edited by author` (vedi ADR-000).

**Regola d'oro per ogni file pubblicato (config, non solo doc):** prima di ogni commit, l'autore deve poter spiegare il file riga per riga senza guardarlo. Claude Code non deve generare configurazioni che l'utente non ha revisionato e compreso — se propone una configurazione complessa, deve accompagnarla con una spiegazione chiara del *perché*, non solo del *cosa*.

**Segreti:** nessun valore in chiaro nel repo. Solo riferimenti `op://vault/item/field` risolti a runtime con 1Password CLI/Connect. Gitleaks in pre-commit e CI come rete di sicurezza aggiuntiva. Attenzione anche a segreti "impliciti": IP pubblici, MAC address, coordinate GPS in config Home Assistant, serial number nei log — vanno sanitizzati a mano.

**Niente emoji nella documentazione.** README, ADR, note del vault e diagrammi non usano emoji decorative (né nei titoli né nelle tabelle di stato): testo semplice, più professionale e stabile per anchor e rendering. Le frecce tipografiche (`→`, `↔`) e i simboli tecnici non sono emoji e restano ammessi.

## Domande aperte / decisioni non ancora prese

- `adguardhome-sync`: modalità cron o webhook? (da decidere)
- Piano 1Password dell'utente (Personal/Family/Business) — determina se usare Connect o solo Service Accounts + CLI nelle fasi iniziali
- Autenticazione VRRP tra i nodi Keepalived (consigliata, da verificare se già impostata)

## Roadmap (fasi)

1. **Fatto** — Documentazione architetturale e primi ADR
2. **Da fare** — Docker Compose versionato e sanitizzato per tutti i servizi + MkDocs/Pages
3. **Da fare** — Ansible playbook per i 3 nodi
4. **Da fare** — OpenTofu per provisioning Proxmox
5. **Da fare** — Migrazione secret management su 1Password Connect
6. **Da fare** — Cluster k8s gestito in GitOps con Flux

## Tono e stile richiesti nella documentazione

Italiano, tono professionale ma personale (non aziendalese). Onestà sui trade-off e sui limiti reali di ogni soluzione — è parte del valore da portfolio, non un difetto da nascondere. Evitare di far sembrare tutto già completo o perfetto: la roadmap con item ancora da fare è un punto di forza, non di debolezza.
