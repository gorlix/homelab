#!/usr/bin/env bash
# Esecuzione manuale/standalone del playbook, fuori dal flusso automatico innescato
# da terraform_data.run_ansible in opentofu/nodes/dell-emc/main.tf. Richiede
# OP_CONNECT_HOST e OP_CONNECT_TOKEN (vedi ADR-006) e onepassword_vault_id.
#
# Senza container_ssh_keys (che solo OpenTofu fornisce), questo run passa dal
# ruolo onepassword_ssh_agent: recupera le chiavi SSH dei nodi da 1Password invece
# che da un ssh-agent già popolato da Tofu — per questo serve comunque il vault.
set -euo pipefail

# L'id del vault non è di per sé un segreto (senza OP_CONNECT_TOKEN non apre
# nulla), ma è comunque l'identificativo reale del vault di produzione: repo
# pubblico, quindi niente default hardcoded qui — va passato esplicitamente.
if [ -z "${ONEPASSWORD_VAULT_ID:-}" ]; then
  echo "ONEPASSWORD_VAULT_ID non impostato. Esporta l'id del vault 1Password da usare (vedi ADR-006)." >&2
  exit 1
fi

# Fonte canonica del token: il file .env accanto a credentials.json (0600, mai in
# git). Se già esportato in ambiente (es. da un run precedente nella stessa shell)
# non lo sovrascrive.
OP_CONNECT_ENV_FILE="${OP_CONNECT_ENV_FILE:-/opt/docker-compose/1password-connect/.env}"
if [ -z "${OP_CONNECT_TOKEN:-}" ] && [ -f "$OP_CONNECT_ENV_FILE" ]; then
  set -a
  # shellcheck source=/dev/null
  source "$OP_CONNECT_ENV_FILE"
  set +a
fi
: "${OP_CONNECT_HOST:=http://localhost:8080}"
export OP_CONNECT_HOST

if [ -z "${OP_CONNECT_TOKEN:-}" ]; then
  echo "OP_CONNECT_TOKEN non impostato (né in ambiente né in $OP_CONNECT_ENV_FILE). Vedi ADR-006 per come ottenerlo." >&2
  exit 1
fi

# Deve girare PRIMA di ansible-playbook: Ansible risolve staticamente tutti i moduli
# usati nel playbook (anche quelli di play che non matcheranno nessun host) prima di
# eseguire il primo task, quindi la collection non può installarsi da sola come task
# interno a site.yml (verificato: fallisce con "couldn't resolve module/action").
ansible-galaxy collection install -r requirements.yml

eval $(ssh-agent -s) > /dev/null 2>&1
trap 'ssh-agent -k >/dev/null 2>&1' EXIT

ansible-playbook -i inventory.yml site.yml -e onepassword_vault_id="$ONEPASSWORD_VAULT_ID" "$@"
