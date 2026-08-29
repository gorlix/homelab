# Letto solo se non viene passato un override manuale di proxmox_token_secret (vedi
# variables.tf): il count condizionale evita di dover comunque contattare Connect
# quando si sta testando con un token passato a mano via -var.
data "onepassword_item" "proxmox_api_token" {
  count = var.proxmox_token_secret == null ? 1 : 0

  vault = var.onepassword_vault_id
  title = var.onepassword_proxmox_token_item_title
}

locals {
  # .credential, non .password: l'item esistente ("Proxmox API Token" nel vault
  # PVE-Automation) è di categoria API_CREDENTIAL, non "password" — il provider
  # espone il valore del campo "credential" come attributo top-level dedicato per
  # questa categoria (verificato contro lo schema del data source), non serve
  # passare da section/section_map.
  proxmox_token_secret = coalesce(
    var.proxmox_token_secret,
    try(data.onepassword_item.proxmox_api_token[0].credential, null)
  )
}
