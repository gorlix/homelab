# Api Endpoint
variable "proxmox_api_url" {
  type        = string
  description = "L'endpoint API del server Proxmox principale"
  default     = "https://192.168.10.199:8006/api2/json"
}

# Token Id
variable "proxmox_token_id" {
  type        = string
  description = "Il Token ID per l'autenticazione su Proxmox VE"
  default     = "opentofu@pve!tofu-token"
}

variable "proxmox_token_secret" {
  type        = string
  description = <<-EOT
    Il segreto del token API per Proxmox VE. Override manuale opzionale, utile per test
    senza dipendere da Connect. Se lasciato a null (caso normale), il segreto viene letto
    dall'item 1Password indicato in onepassword_proxmox_token_item_title tramite Connect.
  EOT
  sensitive   = true
  default     = null
}

# 1Password Connect
variable "onepassword_connect_url" {
  type        = string
  description = "URL del bridge locale di 1Password Connect (equivalente a OP_CONNECT_HOST)"
  default     = "http://localhost:8080"
}

variable "onepassword_connect_token" {
  type        = string
  description = "Access token per 1Password Connect Server (equivalente a OP_CONNECT_TOKEN). Deve essere un token di accesso valido per il server Connect, non il file di credenziali del server stesso. Se il valore è null, OpenTofu userà il token esportato in ambiente come OP_CONNECT_TOKEN."
  sensitive   = true
  default     = null
}

variable "onepassword_vault_id" {
  type        = string
  description = <<-EOT
    UUID del vault 1Password in cui salvare le chiavi SSH generate per i container e
    da cui leggere il token API di Proxmox. Nessun default apposta: se manca, l'apply
    deve fallire subito invece di scrivere silenziosamente nel vault sbagliato.
    Si ottiene con: curl -s -H "Authorization: Bearer $OP_CONNECT_TOKEN" \
      http://localhost:8080/v1/vaults
  EOT
}

variable "onepassword_proxmox_token_item_title" {
  type        = string
  description = "Titolo dell'item 1Password (categoria API_CREDENTIAL) che contiene il token API Proxmox nel campo 'credential'. Deve corrispondere esattamente all'item già esistente nel vault."
  default     = "Proxmox API Token"
}

# Mappa Nodi / Container Target
variable "containers" {
  type = map(object({
    vmid      = number
    ip        = string
    gateway   = string
    cores     = number
    memory    = number
    disk_size = number
    # Nomi delle cartelle sotto /opt/docker-compose/ che il ruolo Ansible
    # docker_service deve copiare e avviare SU QUESTO host specifico (Fase 2 di
    # site.yml, letto per-host da inventory.yml — non più una lista unica valida
    # per tutto il gruppo docker_nodes, dato che ora i nodi fanno cose diverse).
    services = list(string)
  }))
  description = "Mappa dei container LXC da creare su Proxmox"
  default = {
    "Docker-100" = {
      vmid      = 100
      ip        = "192.168.10.100/24"
      gateway   = "192.168.10.254"
      cores     = 4
      memory    = 8192
      disk_size = 50
      services  = ["linkwarden", "monitoring"]
    }

    "Traefik-110" = {
      vmid      = 110
      ip        = "192.168.10.110/24"
      gateway   = "192.168.10.254"
      cores     = 2
      memory    = 2048
      disk_size = 20
      services  = ["traefik"]
    }

    # LXC dedicata (non su Docker-100): agent-runner monta /var/run/docker.sock
    # dell'host per creare le sandbox dell'agente AI (e un sidecar docker:dind
    # per conversazione) — chi ha quell'accesso controlla l'intero daemon
    # Docker, non solo la propria rete. Isolata qui per non condividere il
    # blast radius con Nextcloud/Authentik/bot su Docker-100.
    "Paca-120" = {
      vmid      = 120
      ip        = "192.168.10.120/24"
      gateway   = "192.168.10.254"
      cores     = 4
      memory    = 8192
      disk_size = 60
      services  = ["paca"]
    }

    # Per aggiungere macchine future basterà inserire qui nuovi blocchi, ad esempio:
    # "rocky-target-101" = {
    #   vmid      = 101
    #   ip        = "192.168.10.101/24"
    #   gateway   = "192.168.10.1"
    #   cores     = 2
    #   memory    = 4096
    #   disk_size = 30
    #   services  = []
    # }
  }
}
