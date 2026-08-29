#!/usr/bin/env bash
# Wrapper per non dover ripetere a mano il sourcing di OP_CONNECT_TOKEN/HOST e il
# vault id ad ogni plan/apply — stesso schema di ansible/run.sh.
#
# La conferma interattiva di `tofu apply` (digitare "yes") resta manuale per
# scelta: un cambiamento reale su Proxmox non deve poter partire da solo. Non è
# solo una preferenza — un tentativo di lanciare `tofu apply -auto-approve` da
# Claude Code viene bloccato a monte dal classificatore di sicurezza dello
# strumento stesso, prima ancora di arrivare a Tofu.
#
# Uso: ./apply.sh plan   |   ./apply.sh apply   |   ./apply.sh <qualsiasi comando tofu>
set -euo pipefail

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
  echo "OP_CONNECT_TOKEN non impostato (né in ambiente né in $OP_CONNECT_ENV_FILE)." >&2
  exit 1
fi

# L'id del vault non è di per sé un segreto (senza OP_CONNECT_TOKEN non apre
# nulla), ma è comunque l'identificativo reale del vault di produzione: repo
# pubblico, quindi niente default hardcoded qui — va passato esplicitamente.
if [ -z "${ONEPASSWORD_VAULT_ID:-}" ]; then
  echo "ONEPASSWORD_VAULT_ID non impostato. Esporta l'id del vault 1Password da usare (vedi ADR-006)." >&2
  exit 1
fi

cd "$(dirname "$0")"
tofu "$@" -var onepassword_vault_id="$ONEPASSWORD_VAULT_ID"
