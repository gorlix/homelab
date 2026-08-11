---
aliases:
  - ADR-002
  - Cloudflare Tunnel
tags:
  - adr
  - networking
  - region/ditta
  - service/cloudflare
  - service/traefik
status: accettato
date: 2026-08-11
related:
  - "[[005-topologia-multi-sito]]"
  - "[[006-1password-connect]]"
---

# ADR-002: Esposizione pubblica con Cloudflare Tunnel

| | |
|---|---|
| **Stato** | Accettato — in produzione, con un incidente reale già affrontato (vedi "Da tenere presente") |
| **Data** | 2026-08-11 (placeholder aperto da mesi, scritto per esteso solo ora — la decisione di fondo è precedente) |
| **Nodi coinvolti** | `dell-emc` (container dedicato `Traefik-110`) |

## Contesto

Nessuno dei tre nodi di questo homelab ha una porta in ingresso aperta verso internet — vincolo esplicito, non solo preferenza (vedi [ADR-005](005-topologia-multi-sito.md)): la Region B (`dell-emc`) gira dietro un firewall Cisco gestito da terzi, rete non sotto il mio controllo diretto. Qualunque servizio debba essere raggiungibile da fuori casa/ditta (Infisical, 1Password Connect, in futuro altri) ha bisogno di un modo per esporsi che non richieda mai una regola di port forwarding in ingresso.

## Decisione

**Cloudflare Tunnel**: un connettore (`cloudflared`) apre una connessione in **uscita** verso l'edge di Cloudflare e riceve da lì il traffico instradato verso il dominio pubblico — nessuna porta aperta sul firewall, nessuna dipendenza da regole che non controllo. Davanti al connettore, **Traefik** fa da reverse proxy verso i servizi reali (vedi `docker-compose/traefik/`), instradando per hostname (`env.alessandrogorla.it`, `1p.alessandrogorla.it`, ...).

Traefik e `cloudflared` girano insieme, nello stesso `docker-compose.yml`, sullo stesso container dedicato (`Traefik-110`, provisionato da OpenTofu — vedi `opentofu/nodes/dell-emc/`). Non è sempre stato così: **in origine `cloudflared` girava come processo diretto sull'host Proxmox bare-metal** (`pve`), avviato a mano, prima ancora che esistesse un container dedicato a Traefik. Migrato al container attuale per due motivi: isolare il connettore dal resto di quello che gira sull'host reale, e poter versionare la sua configurazione come qualunque altro servizio invece di un processo avviato a mano e mai più toccato.

## Alternative considerate

| Alternativa | Perché scartata |
|---|---|
| **Port forwarding classico** | Richiederebbe una regola sul firewall Cisco della Region B, non sotto il mio controllo — oltre a esporre direttamente una porta in ingresso, superficie d'attacco che preferisco evitare in un homelab. |
| **VPN (Tailscale) per l'accesso pubblico invece del Tunnel** | Tailscale è già in uso per l'overlay `hp-laptop` <-> `dell-emc` (vedi ADR-005), ma è pensato per accesso *mio*, non per esporre un servizio a chiunque abbia il link pubblico (es. un webhook GitHub, un client OAuth). Cloudflare Tunnel resta lo strumento giusto per "pubblico ma senza porta aperta". |
| **Lasciare `cloudflared` sul processo bare-metal invece di containerizzarlo** | Era lo stato originario, scartato dopo l'incidente descritto sotto: un processo avviato a mano, mai versionato, con il token visibile in chiaro nel comando stesso (`ps aux`) — esattamente il tipo di configurazione "invisibile" che questo repository cerca di eliminare. |

## Conseguenze

> [!TIP] Positive
> - Nessuna porta in ingresso su nessuno dei tre nodi, coerente col vincolo di rete della Region B.
> - Traefik e `cloudflared` versionati insieme in `docker-compose/traefik/` (vedi [ADR-008](008-docker-compose-management.md)), non più un processo avviato a mano e dimenticato.
> - Verificato end-to-end l'11/08/2026 dopo la rotazione (vedi sotto): richieste reali attraverso l'intera catena Cloudflare -> Traefik-110 -> servizio finale, non solo "il container è su".

> [!WARNING] Da tenere presente
> - **Incidente reale (risolto l'11/08/2026): il token del tunnel era esposto da mesi.** Il connettore bare-metal originario (vedi sopra) girava con il token passato come argomento a riga di comando (`cloudflared tunnel --token eyJ...`), quindi leggibile in chiaro da chiunque avesse accesso a `ps aux` sull'host — non un bug di questa sessione, uno stato ereditato. Quando il container `Traefik-110` è stato creato, per non bloccare la migrazione si è deciso di riusare **lo stesso token già compromesso**, con l'intenzione esplicita di ruotarlo appena possibile. La rotazione effettiva è avvenuta solo l'11/08/2026, mesi dopo.
> - **Trovata una seconda via di esposizione durante la stessa sessione, non collegata alla prima:** verificando un id di progetto Infisical, una chiamata al tool MCP `list-secrets` su un path che conteneva già il `TUNNEL_TOKEN` reale ne ha restituito il valore in chiaro nell'output — questi tool MCP di Infisical restituiscono sempre i valori, mai solo i nomi delle chiavi, cosa non ovvia dal loro nome. Trattato allo stesso modo: token considerato compromesso, ruotato. Vedi [ADR-008](008-docker-compose-management.md) e `.claude/skills/new-docker-service/SKILL.md` per la regola scritta dopo questo incidente.
> - **Rotazione fatta via API Cloudflare, non da interfaccia**: `PATCH /accounts/{account}/cfd_tunnel/{tunnel}` con un nuovo `tunnel_secret` generato casualmente (32 byte, mai visto in chiaro — generato ed usato interamente lato Cloudflare tramite l'esecuzione JS del tool MCP, senza mai transitare nella conversazione). Il nuovo token risultante è stato recuperato una sola volta, il minimo indispensabile per poterlo scrivere su Infisical, e non più ripetuto altrove.
> - **La rotazione ha invalidato anche il connettore bare-metal originario**, che condivideva lo stesso `tunnel_secret`. Le sue connessioni esistenti sono rimaste aperte per un po' (l'edge di Cloudflare non re-autentica una connessione già stabilita), ma non si sarebbe più potuto riconnettere. Deciso di terminarlo invece di riemettergli un token: era ridondante, `Traefik-110` gestiva già tutte le route attive.
> - **Terminare quel processo ha richiesto un'indagine, non un semplice `kill`**: era in esecuzione come processo figlio del server Node di Uptime Kuma (gestito da PM2 su quello stesso host `pve`), quindi ereditava le variabili d'ambiente di PM2 (incluso `autorestart=true`) pur non essendo lui stesso un'app registrata in PM2 — verificato con `pm2 list` prima di toccare nulla, per non rischiare di far cadere il vero Uptime Kuma insieme al connettore vestigiale. Confermato dopo la terminazione: Uptime Kuma (processo separato, PID diverso) rimasto `online`, zero restart.
> - **Nodo Proxmox bare-metal e container LXC condividono lo stesso kernel**: i processi di un container LXC (come `Traefik-110`) sono visibili con `ps aux` anche dal nodo Proxmox host che lo ospita, a differenza di una VM KVM. Utile da sapere per debugging, ma anche un altro motivo per non fare mai affidamento sull'isolamento dei processi come unica barriera di sicurezza.
> - **Nessun accenno esplicito, nella configurazione di Traefik, di dove vivano davvero i backend**: `docker-compose/traefik/dynamic/dynamic.yml` instrada verso IP privati statici (`192.168.10.200:8090`, `192.168.10.200:8080`) perché Infisical e 1Password Connect girano su un host diverso da Traefik — nessun provider Docker/label può funzionare tra host diversi, va mantenuto manualmente se cambia l'IP di quell'host.

## Riferimenti

- [Cloudflare Tunnel — documentazione](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/)
- [Cloudflare API — Cloudflare Tunnel endpoints](https://developers.cloudflare.com/api/resources/zero_trust/subresources/tunnels/subresources/cloudflare/)
- Configurazione: [`docker-compose/traefik/`](../../docker-compose/traefik/), [`opentofu/nodes/dell-emc/`](../../opentofu/nodes/dell-emc/)
- [ADR-005](005-topologia-multi-sito.md) — vincolo di rete della Region B che motiva l'assenza di porte in ingresso
- [ADR-008](008-docker-compose-management.md) — dove vive oggi la configurazione di Traefik/cloudflared, e la regola sui tool MCP di Infisical nata da questo stesso incidente
