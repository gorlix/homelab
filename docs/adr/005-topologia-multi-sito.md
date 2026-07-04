---
aliases:
  - ADR-005
  - Topologia multi-sito
  - Due region
tags:
  - adr
  - topologia
  - rete
  - region/casa
  - region/ditta
status: accettato
date: 2026
related:
  - "[[001-adguard-ha-failover]]"
---

# ADR-005: Topologia multi-sito (2 region) e separazione dei ruoli tra i nodi

| | |
|---|---|
| **Stato** | ✅ Accettato — in produzione |
| **Data** | 2026 |
| **Nodi coinvolti** | `hp-laptop` + `thinkcentre` (Region A, casa) · `dell-emc` (Region B, ditta) |

## Contesto

Questo homelab non vive in un unico rack. I tre nodi sono nati in momenti e luoghi diversi, e le loro caratteristiche fisiche hanno finito per determinare *dove* ha senso tenerli:

- `hp-laptop` e `thinkcentre` sono a **casa**: bassi consumi, silenziosi, adatti a stare sempre accesi in un ambiente domestico. Sono anche i nodi che *devono* stare in casa per fare bene il loro lavoro — l'hub domotico (Home Assistant) e il DNS della rete domestica hanno senso solo dentro la LAN che servono.
- `dell-emc` è un Xeon a 16 thread: molto più capace, ma anche più rumoroso, energivoro e ingombrante. Tenerlo acceso 24/7 in casa sarebbe scomodo e costoso. È invece ospitato presso l'**azienda di famiglia**, dove esistono già le condizioni giuste (raffreddamento, connettività stabile, UPS, continuità).

Questa collocazione porta con sé un vincolo importante e non negoziabile: la rete della ditta è **gestita e supervisionata da terzi** (l'azienda che amministra l'infrastruttura aziendale), con un **firewall Cisco** e una **VLAN dedicata** assegnata al nodo. Non ho — né voglio avere — controllo sulle regole del firewall aziendale: niente port forwarding, niente pretese di modifiche alla loro configurazione, nessuna dipendenza da manutenzioni che non decido io.

Serviva quindi una topologia che:

- sfruttasse la potenza di `dell-emc` senza doverlo tenere in casa;
- non dipendesse da **alcuna** modifica alla rete aziendale (solo traffico in uscita);
- tenesse i due siti collegati per una gestione unificata;
- mantenesse la resilienza del DNS *dove serve davvero*, cioè nella LAN di casa;
- esponesse pubblicamente i servizi da entrambi i siti **senza aprire porte** in nessuno dei due.

## Decisione

Ho organizzato l'homelab in **due region** distinte, ciascuna autosufficiente per esposizione e reverse proxy, collegate da un overlay Tailscale.

**Region A — Casa (rete controllata)**
`hp-laptop` e `thinkcentre` formano un **cluster Proxmox** sulla stessa LAN.

- `hp-laptop` — nodo edge: Home Assistant, Traefik, AdGuard primario, Tailscale, Cloudflare Tunnel di casa.
- `thinkcentre` — Frigate NVR e AdGuard di backup.
- Il DNS gira in HA locale (VIP + VRRP) interamente dentro la LAN di casa — vedi [ADR-001](001-adguard-ha-failover.md).

**Region B — Ditta (rete non controllata)**
`dell-emc` è un nodo Proxmox **standalone** (non in cluster), su una VLAN dedicata dietro il firewall Cisco gestito da terzi.

- Traefik proprio e Cloudflare Tunnel dedicato per i servizi di produzione: Authentik, Nextcloud, bot pubblici, monitoring, nodi Kubernetes (WIP).

**Interconnessione tra i siti**
Un overlay **Tailscale** collega `hp-laptop` (Region A) e `dell-emc` (Region B): è la rete di gestione cross-site e il canale per i servizi non pensati per l'esposizione pubblica. `thinkcentre` **non** ha un nodo Tailscale — resta raggiungibile solo dentro la LAN di casa (superficie minima, gestione da remoto via `hp-laptop` come jump o dalla LAN).

**Esposizione pubblica**
Ogni region ha il **proprio** Cloudflare Tunnel e il **proprio** Traefik. I due domini di guasto restano separati e, soprattutto, **nessuna porta è aperta in ingresso** in nessuno dei due siti: tutto passa da tunnel in uscita. Questo è ciò che rende la topologia compatibile con una rete (quella della ditta) su cui non ho controllo.

> [!WARNING] Nota onesta sul perimetro
> La rete della Region B **non è sotto il mio controllo**: firewall Cisco, VLAN e policy sono gestiti da terzi. L'intera topologia (tunnel in uscita, Tailscale, nessuna porta in ingresso) nasce proprio per non dipendere da modifiche che non decido io. È un vincolo, non una scelta estetica.

Due scelte meritano una nota esplicita sul *perché*:

- **`dell-emc` standalone e non nel cluster di casa.** Il clustering Proxmox si appoggia su Corosync, che assume latenza bassa e rete affidabile tra i membri: un cluster esteso su WAN è fragile (problemi di quorum, fencing complicato, rischio di split-brain al primo hiccup di connettività). Per un nodo remoto la scelta robusta è tenerlo standalone.
- **Tailscale per l'interconnessione, non una VPN site-to-site sul firewall Cisco.** Tailscale stabilisce la connessione **in uscita** da entrambi i lati (NAT traversal, nessuna porta in ingresso): non richiede alcuna modifica né manutenzione sulla rete aziendale. Una IPsec site-to-site classica sul Cisco mi renderebbe invece dipendente da configurazioni e interventi di terzi.

## Alternative considerate

| Alternativa | Perché scartata |
|---|---|
| **Tutti i nodi a casa** (niente sito remoto) | `dell-emc` è rumoroso ed energivoro: poco adatto a stare sempre acceso in un ambiente domestico. La ditta offre condizioni operative migliori (raffreddamento, UPS, connettività) senza costi aggiuntivi in casa. |
| **Cluster Proxmox unico sui 3 nodi cross-site** | Corosync richiede latenza bassa e rete affidabile tra i membri; un cluster su WAN è fragile (quorum, fencing, split-brain). Il beneficio (gestione unica) non compensa la fragilità. |
| **VPN site-to-site IPsec sul firewall Cisco** | Mi renderebbe dipendente da configurazioni e manutenzioni gestite da terzi, con tempi e controllo non miei. Tailscale in uscita elimina del tutto questa dipendenza. |
| **Un solo Cloudflare Tunnel + un Traefik centrale** (ingress unico per entrambi i siti) | Accoppia i due domini di guasto e farebbe transitare il traffico di casa attraverso il sito remoto (latenza, dipendenza), oltre a esporre Home Assistant fuori dal suo sito. Due ingress indipendenti sono più semplici e più resilienti. |
| **Port forwarding sul firewall aziendale** | Non ho controllo sulla rete della ditta, e in ogni caso sarebbe un peggioramento della postura di sicurezza rispetto a un tunnel in uscita. |

## Conseguenze

> [!TIP] Positive
> - Sfrutto l'hardware più potente (`dell-emc`) senza gli svantaggi di tenerlo in casa.
> - **Domini di guasto separati**: un guasto o una manutenzione in un sito non tocca l'altro né la sua esposizione pubblica.
> - **Zero dipendenza dalla rete aziendale**: tutto è traffico in uscita (Cloudflare Tunnel + Tailscale, porta 443), il più difficile da bloccare e quello che non richiede nulla ai terzi.
> - Il DNS resiliente resta dove serve davvero — nella LAN di casa, vicino ai client domestici e alle automazioni.
> - Gestione unificata dei due siti tramite l'overlay Tailscale.

> [!WARNING] Da tenere presente
> - **Rete della Region B fuori dal mio controllo**: policy del firewall, manutenzioni o eventuali blocchi in uscita decisi dai terzi possono impattarmi senza preavviso. Mitigazione: dipendo solo da traffico HTTPS in uscita standard, il caso più difficile da bloccare — ma la dipendenza esiste ed è onesto dichiararla.
> - **Dipendenza da terze parti per interconnessione ed esposizione**: Tailscale e Cloudflare sono due single point of failure *esterni*. Accettabile per un homelab; da rivalutare con un fallback se un servizio diventasse davvero critico.
> - **`dell-emc` standalone = nessuna HA di virtualizzazione per la produzione**: un guasto del nodo mette giù i servizi di produzione finché non lo riparo. I dati sono protetti da backup (ADR-004, in programmazione), ma non esiste failover di *compute*. Trade-off accettato consapevolmente: qui la "produzione" è best-effort da homelab, non un SLA.
> - **Latenza cross-site**: i servizi che devono parlarsi tra le due region pagano la latenza WAN più l'overlay. Oggi i servizi sono in larga parte confinati nella propria region, quindi l'impatto è basso; da monitorare se in futuro il monitoring centralizzato dovrà scrapare metriche dall'altro sito.
> - **`thinkcentre` non raggiungibile via Tailscale**: per gestirlo da remoto passo da `hp-laptop` (jump) o dalla LAN di casa. È una scelta voluta (superficie minima), ma va ricordata quando si automatizza la gestione.
> - **Doppia configurazione da mantenere**: due Traefik e due Cloudflare Tunnel significano doppia config da versionare e sanitizzare. Quando si versionerà lo stack (fase 2 della roadmap), la cartella `docker/traefik/` andrà organizzata per sito/nodo per evitare ambiguità.

## Riferimenti

- [ADR-001](001-adguard-ha-failover.md) — DNS ad alta disponibilità, interno alla Region A
- ADR-002 — Cloudflare Tunnel invece di port forwarding (in programmazione): approfondisce il *perché* dell'esposizione in sola uscita
- [Tailscale — How it works](https://tailscale.com/blog/how-tailscale-works) — NAT traversal e connessioni in uscita
- [Proxmox VE — Cluster Manager](https://pve.proxmox.com/wiki/Cluster_Manager) — requisiti di rete di Corosync (latenza, affidabilità)
