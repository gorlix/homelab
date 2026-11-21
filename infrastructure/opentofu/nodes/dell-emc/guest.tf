# LXC ospiti: container concessi a persone esterne (HOME-60, ADR-014).
#
# Non stanno in var.containers per due motivi: il default di quella variabile
# è nel repo (pubblico) e finirebbero lì nome e chiave dell'ospite; e ogni voce
# di var.containers entra nell'inventario Ansible come nodo Docker gestito da
# me, mentre questa macchina è dell'ospite.
#
# Chi è l'ospite e la sua chiave pubblica li passa guest.auto.tfvars su
# pve-management, ignorato da git (*.tfvars). Senza quel file guest_containers
# è vuota e qui non viene creato nulla.
#
# RISCHIO ACCETTATO (ADR-014): l'ospite ha sudo, quindi è root nel container.
# Il container è unprivileged (root dentro = uid 100000 sull'host), ma il
# kernel è quello di pve: un exploit del kernel esce dal container. Il
# firewall qui sotto isola la rete, non il kernel.

resource "proxmox_virtual_environment_container" "guest" {
  for_each = var.guest_containers
  provider = proxmox.secure

  node_name    = "pve"
  vm_id        = each.value.vmid
  description  = "LXC ospite gestita via OpenTofu (ADR-014)"
  tags         = ["guest"]
  unprivileged = true

  initialization {
    hostname = each.key

    ip_config {
      ipv4 {
        address = each.value.ip
        gateway = "192.168.10.254"
      }
    }

    # Le chiavi di root: solo pve-management, per il primo accesso e le
    # emergenze. L'ospite entra con il suo utente (provisioner qui sotto).
    user_account {
      keys = each.value.root_ssh_keys
    }
  }

  cpu {
    cores = each.value.cores
  }

  memory {
    dedicated = each.value.memory
  }

  # Disco su Storage (LVM thick) come Rakazo-118 (ADR-013): l'ospite può
  # riempirlo senza toccare il thin pool delle altre LXC.
  disk {
    datastore_id = "Storage"
    size         = each.value.disk_size
  }

  operating_system {
    template_file_id = "local:vztmpl/rockylinux-9-default_20240912_amd64.tar.xz"
    type             = "centos"
  }

  # nesting: serve a Docker dentro la LXC, come per le altre LXC Docker.
  features {
    nesting = true
  }

  network_interface {
    name     = "eth0"
    bridge   = "vmbr0"
    firewall = true
  }

  # La macchina è dell'ospite: quello che cambia dentro non è drift. Cambiare
  # le chiavi o aggiungere un mount_point forzerebbe la sostituzione e gli
  # cancellerebbe il disco (ADR-010).
  lifecycle {
    ignore_changes = [initialization, mount_point]
  }

  # Utente dell'ospite con sudo senza password, sshd, solo chiave. Gira una
  # volta, alla creazione. Il primo heredoc è quotato: la shell non espande
  # nulla, i ${...} sono di Tofu.
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      ssh -o StrictHostKeyChecking=no root@192.168.10.199 'pct exec ${each.value.vmid} -- bash -s' <<'EOS'
      set -e
      dnf install -y openssh-server sudo
      ssh-keygen -A
      systemctl enable --now sshd
      id ${each.value.username} >/dev/null 2>&1 || useradd -m -G wheel ${each.value.username}
      install -d -m 700 -o ${each.value.username} -g ${each.value.username} /home/${each.value.username}/.ssh
      cat > /home/${each.value.username}/.ssh/authorized_keys <<'EOK'
      ${join("\n", each.value.ssh_keys)}
      EOK
      sed -i 's/^[[:space:]]*//' /home/${each.value.username}/.ssh/authorized_keys
      chown ${each.value.username}:${each.value.username} /home/${each.value.username}/.ssh/authorized_keys
      chmod 600 /home/${each.value.username}/.ssh/authorized_keys
      echo '${each.value.username} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-${each.value.username}
      chmod 440 /etc/sudoers.d/90-${each.value.username}
      passwd -l ${each.value.username}
      sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
      systemctl restart sshd
      EOS
    EOT
  }

  # /dev/net/tun per Tailscale, come tun_device in main.tf: l'API non lo
  # espone ai token, quindi riga in /etc/pve/lxc/<id>.conf e riavvio.
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      ssh -o StrictHostKeyChecking=no root@192.168.10.199 '
        CONF=/etc/pve/lxc/${each.value.vmid}.conf
        grep -qxF "lxc.cgroup2.devices.allow: c 10:200 rwm" "$CONF" || echo "lxc.cgroup2.devices.allow: c 10:200 rwm" >> "$CONF"
        grep -qxF "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file" "$CONF" || echo "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file" >> "$CONF"
        pct reboot ${each.value.vmid}
      '
    EOT
  }
}

# Sulle LXC Proxmox ricava da solo l'IP ammesso da ipfilter (dalla config
# di rete): niente ipset da dichiarare, a differenza delle VM.
resource "proxmox_virtual_environment_firewall_options" "guest" {
  for_each = var.guest_containers
  provider = proxmox.secure
  # Prima le regole, poi la policy DROP (stesso motivo di firewall.tf).
  depends_on = [proxmox_virtual_environment_firewall_rules.guest]

  node_name    = "pve"
  container_id = proxmox_virtual_environment_container.guest[each.key].vm_id

  enabled       = true
  input_policy  = "DROP"
  output_policy = "ACCEPT"
  # Senza ipfilter root nel container potrebbe prendersi 192.168.10.200 e
  # passare la regola SSH qui sotto.
  ipfilter  = true
  macfilter = true
  dhcp      = false
  radv      = false
  ndp       = false
}

resource "proxmox_virtual_environment_firewall_rules" "guest" {
  for_each = var.guest_containers
  provider = proxmox.secure

  node_name    = "pve"
  container_id = proxmox_virtual_environment_container.guest[each.key].vm_id

  # Unico ingresso: SSH da pve-management (primo accesso, emergenze).
  # L'ospite entra dal suo Tailscale, che è traffico in uscita: le risposte
  # passano come ESTABLISHED.
  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "SSH da pve-management"
    source  = "192.168.10.200"
    proto   = "tcp"
    dport   = "22"
  }

  # resolv.conf delle LXC Rocky elenca anche il gateway (vedi firewall.tf).
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

  # Come Maus-117: niente reti private, Internet libero. Il Tailscale e il
  # Cloudflare Tunnel dell'ospite escono verso IP pubblici e funzionano.
  # LIMITE: il traffico DENTRO un tunnel Tailscale è cifrato e questo firewall
  # non lo vede. Finché la LXC sta nel tailnet di Ale (primo accesso) la
  # protezione sono le ACL Tailscale (tag:guest senza permessi). Vedi ADR-014.
  rule {
    type    = "out"
    action  = "DROP"
    comment = "Nessun accesso a reti private dalla LXC ospite"
    dest    = "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,169.254.0.0/16"
    log     = "info"
  }
}
