# Firewall Proxmox per le LXC che fanno girare agenti AI con una shell o un
# computer: Maus-117 (OpenMausBot, ADR-012) e Rakazo-118 (Rakazo, ADR-013).
# Stesse regole per entrambe, cambia solo la porta su cui entra Traefik-110.
# In fondo al file Paperless-119, con regole proprie (solo ingresso, HOME-53).
# Le altre LXC non hanno firewall (firewall = false in variables.tf).
#
# PREREQUISITO MANUALE, fuori da Tofu: queste regole valgono solo se il firewall
# è attivo anche a livello datacenter (/etc/pve/firewall/cluster.fw con
# `enable: 1`). Con il datacenter spento Proxmox salva le regole ma non le
# applica, in silenzio: `pve-firewall status` deve dire "enabled/running".
# Non gestito qui per non dare al token di Tofu permessi sull'intero cluster
# (Sys.Modify su /); vedi ADR-012 per le policy datacenter scelte.
#
# Perché un firewall solo qui: OpenMausBot dà ai bot una shell reale con i
# privilegi dell'utente del server. Una LXC dedicata isola i dati, non la rete:
# da dentro Maus-117 una shell raggiungerebbe comunque ogni servizio della LAN
# (Docker-100, pve-management, la rete aziendale dietro il Cisco, ADR-005).
# Per Rakazo vale lo stesso per i container dei computer dei bot.

locals {
  # LXC isolata => porta su cui Traefik-110 raggiunge il servizio.
  isolated_containers = {
    "Maus-117"   = "8080" # Caddy sidecar di OpenMausBot
    "Rakazo-118" = "5173" # web di Rakazo (vite preview, fa da proxy verso l'API)
  }
}

# Indirizzi delle resource cambiati quando sono passate a for_each: i moved
# dicono a Tofu che sono le stesse, nessuna chiamata API per Maus-117.
moved {
  from = proxmox_virtual_environment_firewall_options.maus
  to   = proxmox_virtual_environment_firewall_options.isolated["Maus-117"]
}

moved {
  from = proxmox_virtual_environment_firewall_rules.maus
  to   = proxmox_virtual_environment_firewall_rules.isolated["Maus-117"]
}

resource "proxmox_virtual_environment_firewall_options" "isolated" {
  for_each     = local.isolated_containers
  provider     = proxmox.secure
  # Prima le regole, poi la policy DROP: al contrario ci sarebbe un momento in
  # cui la LXC accetta solo ESTABLISHED e Ansible non entra.
  depends_on = [proxmox_virtual_environment_firewall_rules.isolated]

  node_name    = "pve"
  container_id = proxmox_virtual_environment_container.rocky_targets[each.key].vm_id

  enabled       = true
  input_policy  = "DROP"
  output_policy = "ACCEPT"
  # ipfilter: la LXC può usare solo il proprio IP. Senza, root nel container
  # potrebbe assegnarsi 192.168.10.110 o .200 e passare le regole IN qui sotto,
  # che si fidano dell'IP sorgente.
  ipfilter  = true
  macfilter = true
  dhcp      = false
  radv      = false
  ndp       = false
}

resource "proxmox_virtual_environment_firewall_rules" "isolated" {
  for_each     = local.isolated_containers
  provider     = proxmox.secure
  node_name    = "pve"
  container_id = proxmox_virtual_environment_container.rocky_targets[each.key].vm_id

  # Le regole sono valutate in ordine, la prima che corrisponde vince. Le
  # risposte alle connessioni già accettate (es. l'SSH di Ansible) passano
  # comunque: Proxmox accetta ESTABLISHED/RELATED prima di queste regole.

  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = each.key == "Maus-117" ? "Traefik-110 verso il Caddy sidecar di OpenMausBot" : "Traefik-110 verso ${each.key}"
    source  = "192.168.10.110"
    proto   = "tcp"
    dport   = each.value
  }

  # Ansible gira su pve-management. Nessuna regola per hawser
  # (2376): resta in ascolto ma nessuno può raggiungerlo, Dockhand non gestisce
  # questa LXC. Scelta voluta, meno porte aperte (ADR-012).
  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "SSH da pve-management (Ansible)"
    source  = "192.168.10.200"
    proto   = "tcp"
    dport   = "22"
  }

  # resolv.conf delle LXC Rocky elenca 1.1.1.1, 8.8.8.8 e poi il gateway: i
  # primi due sono pubblici e passano comunque, il gateway va aperto a parte
  # perché sta nella LAN bloccata dalla regola successiva.
  rule {
    type    = "out"
    action  = "ACCEPT"
    comment = "DNS verso il gateway"
    dest    = "192.168.10.254"
    proto   = "udp"
    dport   = "53"
  }

  rule {
    type    = "out"
    action  = "ACCEPT"
    comment = "DNS verso il gateway (tcp)"
    dest    = "192.168.10.254"
    proto   = "tcp"
    dport   = "53"
  }

  # Eccezione al blocco qui sotto per le LXC dei bot: l'entrypoint lan-upload
  # di Traefik-110, da cui i bot caricano file nella cartella consume di
  # Paperless (HOME-53; Maus-117 dal 25/11/2026, client "omb", HOME-54). Solo
  # la 8099: le route pubbliche su :80 restano irraggiungibili dalla LAN dei bot.
  dynamic "rule" {
    for_each = contains(["Rakazo-118", "Maus-117"], each.key) ? [1] : []
    content {
      type    = "out"
      action  = "ACCEPT"
      comment = "Upload verso Paperless via Traefik-110 lan-upload (HOME-53)"
      dest    = "192.168.10.110"
      proto   = "tcp"
      dport   = "8099"
    }
  }

  # Eccezione solo per Maus-117: il server TTS Chatterbox su Docker-100 (voce
  # dei bot, stack chatterbox-tts). Solo quella porta: il server non ha
  # autenticazione e non si apre il resto di Docker-100. Conseguenza: anche una
  # shell dei bot può chiamarlo (può solo sintetizzare voce, consumando CPU).
  dynamic "rule" {
    for_each = each.key == "Maus-117" ? [1] : []
    content {
      type    = "out"
      action  = "ACCEPT"
      comment = "TTS Chatterbox su Docker-100"
      dest    = "192.168.10.100"
      proto   = "tcp"
      dport   = "3036"
    }
  }

  # Tutto il resto verso reti private è bloccato: LAN di casa e della ditta
  # (192.168.0.0/16 copre anche 192.168.10.0/24), altri RFC1918, CGNAT di
  # Tailscale/Netbird, link-local. Quello che non è qui esce verso Internet
  # (output_policy ACCEPT), che è ciò di cui i bot hanno bisogno: API degli
  # engine, npm, siti web per agent-browser.
  rule {
    type    = "out"
    action  = "DROP"
    comment = "Nessun accesso a reti private dalla LXC dei bot"
    dest    = "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,169.254.0.0/16"
    log     = "info"
  }
}

# Paperless-119 (HOME-53): firewall solo in ingresso. Serve perché il servizio
# webdav dello stack paperless (porta 8020) non ha autenticazione propria: chi
# può scrivere lo decide Traefik-110 (entrypoint lan-upload). Senza queste
# regole chiunque nella LAN scriverebbe nella cartella consume saltando
# Traefik. In uscita nessun limite: Paperless deve raggiungere IMAP, il
# provider di paperless-gpt e i registry.
resource "proxmox_virtual_environment_firewall_options" "paperless" {
  provider   = proxmox.secure
  depends_on = [proxmox_virtual_environment_firewall_rules.paperless]

  node_name    = "pve"
  container_id = proxmox_virtual_environment_container.rocky_targets["Paperless-119"].vm_id

  enabled       = true
  input_policy  = "DROP"
  output_policy = "ACCEPT"
  # Come per le LXC isolate: senza ipfilter root nella LXC potrebbe prendersi
  # un altro IP (per esempio quello di Traefik-110).
  ipfilter  = true
  macfilter = true
  dhcp      = false
  radv      = false
  ndp       = false
}

resource "proxmox_virtual_environment_firewall_rules" "paperless" {
  provider     = proxmox.secure
  node_name    = "pve"
  container_id = proxmox_virtual_environment_container.rocky_targets["Paperless-119"].vm_id

  # Traefik-110 è l'unico client di web UI (8000), server MCP (8010) e webdav
  # (8020). Verificato il 14/11/2026 che nessun altro host apre connessioni
  # verso la LXC (hawser in ascolto ma Dockhand non la gestisce, niente
  # monitoring): stessa scelta di Maus-117 e Rakazo-118.
  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "Traefik-110 verso la web UI di Paperless"
    source  = "192.168.10.110"
    proto   = "tcp"
    dport   = "8000"
  }

  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "Traefik-110 verso il server MCP di Paperless"
    source  = "192.168.10.110"
    proto   = "tcp"
    dport   = "8010"
  }

  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "Traefik-110 verso il webdav della cartella consume (HOME-53)"
    source  = "192.168.10.110"
    proto   = "tcp"
    dport   = "8020"
  }

  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "SSH da pve-management (Ansible)"
    source  = "192.168.10.200"
    proto   = "tcp"
    dport   = "22"
  }
}
