#!/usr/bin/env bash
# Installa il timer systemd che tiene pve-management allineato a origin/main.
# Da eseguire una volta sola su pve-management, come root, dalla root del
# checkout (/opt). auto-deploy.sh resta dov'è (/opt/scripts/), letto in place
# dal service unit — solo le unit systemd vanno copiate fuori dal repo,
# perché systemd non le legge da /opt.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Esegui come root (systemctl system-wide)." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

chmod +x "$SCRIPT_DIR/auto-deploy.sh"

cp "$SCRIPT_DIR/auto-deploy.service" /etc/systemd/system/auto-deploy.service
cp "$SCRIPT_DIR/auto-deploy.timer" /etc/systemd/system/auto-deploy.timer

systemctl daemon-reload
systemctl enable --now auto-deploy.timer

echo "Timer installato e attivo. Stato:"
systemctl status auto-deploy.timer --no-pager
echo ""
echo "Log del prossimo run: journalctl -u auto-deploy.service -f"
