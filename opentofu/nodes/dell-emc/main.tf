# Genero una chiave SSH dinamica in memoria per CIASCUN container. La chiave privata
# non viene mai scritta su disco qui: vive nello state (vedi ADR-006 per i limiti di
# questo approccio) e, solo per la durata dell'apply, in un file temporaneo su tmpfs
# (/run) che l'automazione Ansible usa per registrarla su 1Password prima di essere
# distrutta (vedi terraform_data.run_ansible più sotto).
resource "tls_private_key" "container_ssh_keys" {
  for_each  = var.containers
  algorithm = "ED25519"
}

# Definizione dei Container LXC
resource "proxmox_virtual_environment_container" "rocky_targets" {
  for_each = var.containers
  provider = proxmox.secure

  node_name   = "pve"
  vm_id       = each.value.vmid
  description = "Container Target ${each.key} gestito via OpenTofu"

  unprivileged = true

  initialization {
    hostname = each.key

    ip_config {
      ipv4 {
        address = each.value.ip
        gateway = each.value.gateway
      }
    }

    user_account {
      keys = [
        trimspace(tls_private_key.container_ssh_keys[each.key].public_key_openssh)
      ]
    }
  }

  cpu {
    cores = each.value.cores
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = "local-lvm"
    size         = each.value.disk_size
  }

  operating_system {
    template_file_id = "local:vztmpl/rockylinux-9-default_20240912_amd64.tar.xz"
    type             = "centos"
  }

  features {
    nesting = true
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

  # AUTO-SETUP SSH: Installa openssh-server, genera le chiavi host ed avvia il servizio
  provisioner "local-exec" {
    command = "ssh -o StrictHostKeyChecking=no root@192.168.10.199 'pct exec ${each.value.vmid} -- bash -c \"dnf install -y openssh-server && ssh-keygen -A && systemctl enable --now sshd\"'"
  }
}

# Generazione dell'inventory.yml per Ansible. op_item_title è il titolo con cui il
# ruolo onepassword_ssh_keys (ansible/roles/onepassword_ssh_keys) salverà la chiave
# del rispettivo host su 1Password: la convenzione va tenuta in sync manualmente,
# tls_private_key non espone il nome del container come attributo utilizzabile qui.
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../../../ansible/inventory.yml"
  content  = <<EOT
all:
  children:
    docker_nodes:
      hosts:
%{for name, config in var.containers~}
        ${name}:
          ansible_host: ${split("/", config.ip)[0]}
          ansible_user: root
          op_item_title: "${name}-ssh"
          services: ${jsonencode(config.services)}
%{endfor~}
EOT
}

# AUTOMAZIONE FINALE: trigger automatico di Ansible in sequenza, non appena i
# container sono su e l'inventory è stato rigenerato.
resource "terraform_data" "run_ansible" {
  depends_on = [
    proxmox_virtual_environment_container.rocky_targets,
    local_file.ansible_inventory
  ]

  triggers_replace = [
    local_file.ansible_inventory.id
  ]

  provisioner "local-exec" {
    working_dir = "${path.module}/../../../ansible"
    command     = <<EOT
      set -euo pipefail

      # Deve girare prima di ansible-playbook: Ansible risolve staticamente tutti i
      # moduli usati nel playbook (anche di play che non matchano host) prima di
      # eseguire il primo task, quindi la collection non può auto-installarsi da un
      # task interno a site.yml (verificato: fallisce con "couldn't resolve module").
      ansible-galaxy collection install -r requirements.yml

      # SECRETS_FILE porta le chiavi SSH appena generate ad Ansible (ruolo
      # onepassword_ssh_keys) perché le scriva su 1Password. Vive solo su tmpfs
      # (/run) per la durata di questo provisioner e viene distrutto (shred, non
      # semplice rm) qualunque sia l'esito del playbook: non deve mai finire su
      # disco persistente né tantomeno nel repo git.
      SECRETS_FILE=""
      trap 'ssh-agent -k >/dev/null 2>&1; [ -n "$SECRETS_FILE" ] && shred -u "$SECRETS_FILE" 2>/dev/null' EXIT

      eval $(ssh-agent -s) > /dev/null
%{for name, key in tls_private_key.container_ssh_keys ~}
      ssh-add - <<'EOF'
${key.private_key_openssh}
EOF
%{endfor ~}

      SECRETS_FILE=$(mktemp /run/tofu-op-secrets.XXXXXX)
      chmod 600 "$SECRETS_FILE"
      cat > "$SECRETS_FILE" <<'JSONEOF'
${jsonencode({
  container_ssh_keys = {
    for name, key in tls_private_key.container_ssh_keys : name => {
      op_item_title = "${name}-ssh"
      public_key    = trimspace(key.public_key_openssh)
      private_key   = key.private_key_openssh
    }
  }
})}
JSONEOF

      # OP_CONNECT_HOST ha un default sensato, va sempre esportato. OP_CONNECT_TOKEN
      # invece va esportato SOLO se passato esplicitamente come -var: altrimenti,
      # sovrascriverlo con una stringa vuota cancellerebbe un token già valido
      # ereditato dall'ambiente di chi lancia `tofu apply` (es. da
      # /opt/docker-compose/1password-connect/.env, la fonte canonica, vedi ADR-006
      # e run.sh) — bug reale trovato mentre si testava questo stesso file.
      export OP_CONNECT_HOST="${var.onepassword_connect_url}"
      %{if var.onepassword_connect_token != null~}
      export OP_CONNECT_TOKEN="${var.onepassword_connect_token}"
      %{endif~}

      ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i inventory.yml site.yml \
        -e @"$SECRETS_FILE" \
        -e onepassword_vault_id="${var.onepassword_vault_id}"
    EOT
  }
}
