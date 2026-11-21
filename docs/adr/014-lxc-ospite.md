---
aliases:
  - ADR-014
  - LXC ospite
tags:
  - adr
  - security
  - networking
  - region/ditta
status: proposto
date: 2026-11-21
related:
  - "[[005-topologia-multi-sito]]"
  - "[[010-persistenza-dati-fuori-dalla-lxc]]"
  - "[[012-openmausbot]]"
  - "[[013-rakazo]]"
---

# ADR-014: LXC ospite isolata su `dell-emc` per una persona esterna

| | |
|---|---|
| **Stato** | Proposto: configurazione scritta, `plan` e `apply` non ancora eseguiti |
| **Data** | 2026-11-21 |
| **Nodi coinvolti** | `dell-emc` (LXC ospite, vmid 121, `192.168.10.121`) |
| **Task** | HOME-60 |

## Contesto

Devo concedere una macchina a una persona esterna, che ci farà girare uno o più container Docker con il proprio Cloudflare Tunnel e il proprio Tailscale. Vuole i privilegi massimi (sudo completo). Durata per ora illimitata; i backup li gestisce lei.

Tre vincoli:

- è root su una macchina dentro la mia rete, quindi deve essere isolata dal resto: Region B, Region A e il tailnet;
- la Region B sta dietro un firewall Cisco gestito da terzi (ADR-005): niente porte in ingresso, quindi la persona non può raggiungere la macchina da fuori finché non c'è un tunnel;
- il repo è pubblico: nome e chiave della persona non ci vanno.

## Decisione

### 1. LXC unprivileged, con il kernel condiviso come rischio accettato

Una LXC, come le altre macchine del nodo: stesso template Rocky 9, stesso schema di provisioning, meno risorse di una VM. È *unprivileged*: il root del container corrisponde all'uid 100000 sull'host, non al root vero. Il kernel però è quello di `pve` (vedi la sezione "Da tenere presente").

Il container non sta in `var.containers` ma in una variabile a parte, `guest_containers` (`guest.tf`), per due motivi. Il default di `var.containers` è nel repo, quindi nome e chiave finirebbero lì. E ogni voce di `var.containers` entra nell'inventario Ansible come nodo Docker gestito da me, mentre questa macchina è dell'ospite.

### 2. Utente con sudo e solo chiave

Alla creazione un `local-exec` (via `pct exec` da `pve`) fa queste cose:

- installa `sshd`;
- crea l'utente dell'ospite nel gruppo `wheel`, con sudo senza password, la sua chiave pubblica, la password bloccata e `PasswordAuthentication no`.

Le chiavi di root sono solo quella di `pve-management`, per il primo accesso e le emergenze. Un secondo `local-exec` aggiunge `/dev/net/tun` per Tailscale, come `tun_device` in `main.tf`. `nesting` serve a Docker.

Nome utente, chiavi, IP e risorse stanno in `guest.auto.tfvars` su `pve-management` (ignorato da git, esempio in `guest.auto.tfvars.example`). Senza quel file `guest_containers` è vuota e Tofu non crea nulla.

`lifecycle { ignore_changes = [initialization, mount_point] }`: cambiare chiavi o mount forzerebbe la sostituzione della LXC (ADR-010) e cancellerebbe i dati dell'ospite.

### 3. Firewall Proxmox, stesso schema di `Maus-117`

- ingresso: solo SSH da `pve-management`;
- uscita: DNS verso il gateway, poi DROP verso `10/8`, `172.16/12`, `192.168/16`, `100.64/10` e `169.254/16`, il resto verso Internet è libero;
- `ipfilter`: senza, l'ospite potrebbe assegnarsi `192.168.10.200` e passare la regola SSH. Sulle LXC Proxmox ricava l'IP ammesso dalla config.

Il prerequisito è lo stesso di ADR-012: il firewall del datacenter deve essere attivo (`pve-firewall status`, verificato `enabled/running` il 21/11/2026).

### 4. Primo accesso dal mio tailnet, poi il suo

La chiave da sola non basta: la LXC ha un IP privato dietro il Cisco e da fuori non è raggiungibile. Per il primo accesso:

1. creo nella console Tailscale un'auth key monouso, pre-autorizzata, con `tag:guest`;
2. da `pve-management` entro nella LXC come root, installo Tailscale e la registro con `tailscale up --authkey=... --advertise-tags=tag:guest`;
3. condivido **solo quel nodo** con l'ospite (Share node), non lo invito nel tailnet: con la condivisione vede la LXC e nient'altro;
4. l'ospite entra in SSH, fa login con il suo account Tailscale (la LXC passa al suo tailnet) e configura il suo Cloudflare Tunnel;
5. tolgo la macchina dalla console del mio tailnet.

Le ACL devono impedire a `tag:guest` di raggiungere qualunque cosa:

```jsonc
"tagOwners": { "tag:guest": ["autogroup:admin"] },
// nessuna regola in "grants"/"acls" con tag:guest come sorgente.
// Se la policy contiene ancora l'allow-all di default ({"src":["*"],"dst":["*:*"]}),
// "*" comprende anche tag:guest: va ristretta PRIMA del passo 2.
```

## Revoca

Con root, l'ospite può rimettere qualunque chiave o utente che gli tolgo da dentro: **l'unica revoca vera è da Proxmox.**

1. **Sospensione immediata:** `pct shutdown 121` (o `pct stop 121`). Si fermano anche il suo tunnel e il suo Tailscale.
2. **Revoca definitiva:** togliere la voce da `guest.auto.tfvars`, poi `./apply.sh plan` (deve mostrare la distruzione della LXC e delle sue regole e opzioni firewall, nient'altro) e `./apply.sh apply`. Il disco viene cancellato: se i dati gli servono, deve copiarseli prima.
3. Controllare che la macchina non compaia più nella console del mio tailnet. L'IP `.121` torna libero.

## Alternative considerate

- **VM.** Kernel separato: un exploit del kernel resterebbe dentro la VM. Era la mia prima proposta. Scartata per scelta: si è preferita una LXC, come le altre macchine del nodo, accettando il rischio.
- **Accesso con Cloudflare Tunnel e Access per SSH.** Funziona, ma per un uso solo iniziale significa regole Access e `cloudflared` anche dal suo lato.
- **Auth key Tailscale fornita dall'ospite.** Più pulita, perché il mio tailnet non viene mai toccato, ma serve che lui me la faccia avere. Resta un'alternativa valida se preferisce.
- **Region A (casa).** Avrebbe usato l'IP di casa invece di quello della ditta. Scelta la Region B per le risorse (RAM e storage thick liberi su `pve`).

## Conseguenze

> [!TIP] Positive
> - Rete isolata dal firewall Proxmox, che l'ospite non può modificare da dentro.
> - Nessuna porta in ingresso nuova: entra dal suo Tailscale, espone dal suo Cloudflare Tunnel.
> - Dati personali fuori dal repo, schema riusabile per altri ospiti (una voce in più in `guest_containers`).

> [!WARNING] Da tenere presente
> - **Kernel condiviso con `pve`.** L'ospite è root in un container unprivileged: per uscire gli serve una vulnerabilità del kernel o di LXC, ma se la trova arriva all'host e da lì a tutte le macchine del nodo (Authentik, PACA, Nextcloud, `pve-management`). Il firewall non protegge da questo. È accettabile solo perché mi fido della persona, e il kernel di `pve` va tenuto aggiornato.
> - **L'IP pubblico in uscita è quello della ditta.** Quello che fa l'ospite su Internet (scansioni, abusi, contenuti) risulta fatto dalla rete aziendale. È un rischio accettato.
> - **Il firewall non vede dentro i tunnel.** Il traffico Tailscale è cifrato: finché la LXC è nel mio tailnet la protezione sono le ACL (`tag:guest`), non Proxmox. Una ACL sbagliata, o l'allow-all di default lasciato com'è, gli aprirebbe i miei nodi e le subnet route verso le LAN. Dopo il passaggio al suo tailnet il problema non c'è più.
> - **La chiave di root di `pve-management` resta nella LXC.** L'ospite può toglierla, perché è root. Per un accesso di emergenza garantito c'è `pct enter 121` da `pve`.
> - **Niente backup.** Nessun vzdump, per scelta concordata: se il disco o il nodo si rompono, i dati dell'ospite sono persi.
> - **Nessun monitoring.** Il firewall blocca la LAN in ingresso: da Proxmox si vedono solo CPU, RAM, disco e rete.
> - **Risorse condivise.** 2 vCPU e 4 GB tolti a `pve`. Un uso intenso di CPU o disco da parte dell'ospite rallenta le altre macchine: i limiti stanno solo nella dimensione della LXC.
> - **Il provisioning gira una sola volta.** Utente, sudo e `/dev/net/tun` li configurano i `local-exec` alla creazione: cambiarli in `guest.auto.tfvars` dopo non cambia nulla nella LXC.

## Riferimenti

- Configurazione: [`guest.tf`](../../infrastructure/opentofu/nodes/dell-emc/guest.tf), [`variables.tf`](../../infrastructure/opentofu/nodes/dell-emc/variables.tf), [`guest.auto.tfvars.example`](../../infrastructure/opentofu/nodes/dell-emc/guest.auto.tfvars.example)
- [Proxmox VE Firewall, IP filter](https://pve.proxmox.com/wiki/Firewall#pve_firewall_ip_address_filter)
- [Proxmox: unprivileged LXC](https://pve.proxmox.com/wiki/Unprivileged_LXC_containers)
- [Tailscale: sharing](https://tailscale.com/kb/1084/sharing), [tags](https://tailscale.com/kb/1068/tags)
- [ADR-005](005-topologia-multi-sito.md), [ADR-010](010-persistenza-dati-fuori-dalla-lxc.md), [ADR-012](012-openmausbot.md), [ADR-013](013-rakazo.md)
