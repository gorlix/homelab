#!/usr/bin/env bash
# Gira su pve-management (systemd timer, vedi scripts/setup-auto-deploy.sh).
# Sincronizza /opt con origin/main e ridispiega solo se c'è qualcosa di nuovo:
# docker compose stesso è idempotente (up -d non ricrea un servizio la cui
# configurazione non è cambiata), quindi non serve calcolare a mano quale
# servizio è stato toccato — si rilanciano sempre tutti, il costo di un
# "docker compose up -d" su un servizio invariato è nullo.
#
# Non sostituisce la revisione umana delle PR di Renovate: si limita a
# dispiegare quello che è già stato mergiato su main. Il freno per gli
# aggiornamenti rischiosi (major bump di immagini stateful) vive in
# renovate.json (dependencyDashboardApproval), non qui.
set -euo pipefail

cd /opt

BEFORE=$(git rev-parse HEAD)
git fetch origin --quiet
AFTER=$(git rev-parse origin/main)

if [ "$BEFORE" = "$AFTER" ]; then
  exit 0
fi

echo "[auto-deploy] $BEFORE -> $AFTER"
git reset --hard origin/main --quiet

# Servizi che girano direttamente su questo host, fuori dalla pipeline
# Ansible (stessa lista usata a mano finora: 1password-connect e infisical
# per dipendenza circolare, Semaphore/hawser/renovate perché pve-management
# non è nel gruppo docker_nodes — vedi commenti nei rispettivi
# docker-compose.yml).
for svc in 1password-connect infisical Semaphore hawser renovate; do
  echo "[auto-deploy] $svc"
  (cd "/opt/docker-compose/$svc" && docker compose pull --quiet && docker compose up -d --quiet-pull)
done

# Servizi sui nodi remoti (Docker-100, Traefik-110): run.sh è già idempotente
# e include hawser (girato sempre) + tutti i servizi elencati per host in
# infrastructure/opentofu/nodes/dell-emc/variables.tf.
(cd /opt/infrastructure/ansible && ./run.sh)

# Controllo finale, non un vero rollback automatico: se qualcosa è rimasto
# unhealthy dopo il redeploy lo si vede chiaramente nel journal invece che
# scoprirlo per caso (vedi incidente infisical-db dell'11/08/2026, scoperto
# solo perché qualcuno ha guardato i log a mano).
UNHEALTHY=$(docker ps --filter "health=unhealthy" --format "{{.Names}}" 2>/dev/null || true)
if [ -n "$UNHEALTHY" ]; then
  echo "[auto-deploy] ATTENZIONE, container unhealthy dopo il deploy: $UNHEALTHY" >&2
  exit 1
fi

echo "[auto-deploy] completato, tutto healthy"
