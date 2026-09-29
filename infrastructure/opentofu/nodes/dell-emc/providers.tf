terraform {
  required_version = ">= 1.8.0"

  required_providers {
    proxmox = {
      source = "bpg/proxmox"
      # Pinnato a 0.113.x (non "~> 0.114.0" come mergiato da Renovate in #24):
      # 0.114.0 introduce una lettura del mount_point mp0 di Paca-120 (creato
      # out-of-band via `pct set` per il bind mount dei backup, mai dichiarato
      # come risorsa Terraform — vedi backup_host_path in variables.tf) che il
      # refresh ora vede come drift da rimuovere, con `forces replacement` sul
      # container — cioè destroy+recreate della stessa LXC dell'incidente di
      # perdita dati del 14-17/09/2026 (ADR-010). Verificato dal vivo con
      # `tofu plan` il 29/09/2026, non assunto dal changelog. Restare su
      # 0.113.x finché non si capisce la causa esatta e si decide una
      # soluzione (vedi commento vicino a backup_host_path in variables.tf).
      version = "~> 0.113.1"
    }
    onepassword = {
      source  = "1password/onepassword"
      version = "~> 3.3.0"
    }
    tls = {
      source = "hashicorp/tls"
    }
    local = {
      source = "hashicorp/local"
    }
  }
}

# Provider 1Password, autenticato via Connect (mai via account personale/CLI interattiva).
# connect_token non ha default: se non passato via -var, ripiega sulla variabile
# d'ambiente OP_CONNECT_TOKEN già esportata nello script di run (vedi run.sh) — non è
# mai scritto su disco né nello state di questo provider.
provider "onepassword" {
  connect_url   = var.onepassword_connect_url
  connect_token = var.onepassword_connect_token != null ? var.onepassword_connect_token : null
}

# Provider Proxmox, autenticato via token API. L'alias "secure" (unico usato dalle
# risorse in questo modulo) evita di dover dichiarare anche una configurazione di
# default: prima di bpg/proxmox 0.111 qui esisteva un secondo blocco "proxmox" senza
# alias, autenticato via ssh-agent e non referenziato da nessuna risorsa — rimosso
# perché morto (nessun resource lo usava, restava solo per confusione in review).
provider "proxmox" {
  alias    = "secure"
  endpoint = var.proxmox_api_url
  insecure = true

  api_token = local.proxmox_token_secret != null ? "${var.proxmox_token_id}=${local.proxmox_token_secret}" : null

  ssh {
    agent = true
  }
}
