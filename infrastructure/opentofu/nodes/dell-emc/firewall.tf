# Firewall Proxmox per Maus-117 (OpenMausBot, ADR-012). Primo uso del firewall
# Proxmox in questo repo: le altre LXC non ne hanno uno (firewall = false in
# variables.tf, nessun diff per loro).
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

resource "proxmox_virtual_environment_firewall_options" "maus" {
  provider     = proxmox.secure
  # Prima le regole, poi la policy DROP: al contrario ci sarebbe un momento in
  # cui la LXC accetta solo ESTABLISHED e Ansible non entra.
  depends_on = [proxmox_virtual_environment_firewall_rules.maus]

  node_name    = "pve"
  container_id = proxmox_virtual_environment_container.rocky_targets["Maus-117"].vm_id

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

resource "proxmox_virtual_environment_firewall_rules" "maus" {
  provider     = proxmox.secure
  node_name    = "pve"
  container_id = proxmox_virtual_environment_container.rocky_targets["Maus-117"].vm_id

  # Le regole sono valutate in ordine, la prima che corrisponde vince. Le
  # risposte alle connessioni già accettate (es. l'SSH di Ansible) passano
  # comunque: Proxmox accetta ESTABLISHED/RELATED prima di queste regole.

  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "Traefik-110 verso il Caddy sidecar di OpenMausBot"
    source  = "192.168.10.110"
    proto   = "tcp"
    dport   = "8080"
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
