---
aliases:
  - Homelab MOC
  - Mappa dei contenuti
tags:
  - moc
  - homelab
---

# 🗺️ Homelab — Mappa dei contenuti

Nota di ingresso del vault: da qui si raggiunge il resto della documentazione. Su GitHub è l'indice della cartella `docs/`; in Obsidian è l'hub da cui si dirama il *graph view*.

## Architettura

- [Panoramica e diagramma](../README.md#architettura) — le due *region* (Casa / Ditta) e i flussi di traffico
- [Hardware e ruoli dei nodi](../README.md#hardware)
- [Il repository come Obsidian vault](../README.md#repository-come-obsidian-vault)

## Architecture Decision Records

Ogni decisione non banale è un ADR nel formato *Contesto → Decisione → Alternative → Conseguenze → "Da tenere presente"*.

| ADR | Titolo | Stato |
|---|---|---|
| [ADR-000](adr/000-metodologia-ai.md) | Metodologia di lavoro e uso di strumenti AI | ✅ Accettato |
| [ADR-001](adr/001-adguard-ha-failover.md) | DNS ad alta disponibilità (Keepalived/VRRP) | ✅ Accettato |
| [ADR-005](adr/005-topologia-multi-sito.md) | Topologia multi-sito (2 region) | ✅ Accettato |

**In programmazione:** ADR-002 (Cloudflare Tunnel), ADR-003 (Authentik SSO), ADR-004 (backup 3-2-1 su S3 Cubbit), ADR-006 (1Password).

## Navigare per tag

In Obsidian, dal *tag pane* o dalla ricerca:

- `#adr` — tutte le decisioni architetturali
- `#region/casa` · `#region/ditta` — note per sito fisico
- `#service/adguard` — note legate a un servizio
- `#topologia` · `#dns` · `#rete` — aree tematiche

> [!NOTE]
> Questa nota fa doppio lavoro: è la *Map of Content* del vault Obsidian e, in prospettiva, la home del sito di documentazione (MkDocs Material su GitHub Pages, vedi roadmap nel README).
