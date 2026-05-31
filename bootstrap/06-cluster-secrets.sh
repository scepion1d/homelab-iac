#!/usr/bin/env zsh
# Create the cluster-side secrets that Argo CD apps need but that aren't
# committed to git. Idempotent: never overwrites an existing secret.
#
# Required by:
#   - grafana (helm chart wires `existingSecret: grafana-admin`; without
#     this the chart rolls a new password on every sync and you can't
#     log in).
#
# Optional (created only if the corresponding env var is set in
# bootstrap/.env):
#   - argocd-notifications-secret patch with SLACK_TOKEN.
#   - mikrotik-exporter-credentials with MIKROTIK_USER + MIKROTIK_PASSWORD.
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh
load_env

ensure_ns() {
  kubectl get ns "$1" >/dev/null 2>&1 \
    || kubectl create ns "$1" >/dev/null
}

create_secret_if_missing() {
  local ns="$1" name="$2"
  shift 2
  if kubectl -n "${ns}" get secret "${name}" >/dev/null 2>&1; then
    echo "    ${ns}/${name}: already exists, skipping"
    return
  fi
  ensure_ns "${ns}"
  kubectl -n "${ns}" create secret generic "${name}" "$@" >/dev/null
  echo "    ${ns}/${name}: created"
}

echo "==> Ensuring cluster-side secrets exist"

# Grafana admin (mandatory for a usable grafana UI).
GRAFANA_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-$(openssl rand -base64 24)}"
if ! kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1; then
  GRAFANA_GENERATED=1
fi
create_secret_if_missing monitoring grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="${GRAFANA_PASSWORD}"

# MikroTik exporter (optional; only if credentials provided).
if [[ -n "${MIKROTIK_USER:-}" && -n "${MIKROTIK_PASSWORD:-}" ]]; then
  create_secret_if_missing monitoring mikrotik-exporter-credentials \
    --from-literal=credentials.yaml="username: ${MIKROTIK_USER}
password: ${MIKROTIK_PASSWORD}
"
else
  echo "    monitoring/mikrotik-exporter-credentials: skipped (MIKROTIK_USER/MIKROTIK_PASSWORD not set)"
fi

# Slack notifications (optional; patches an existing secret installed by
# the argocd-notifications chart).
if [[ -n "${SLACK_TOKEN:-}" ]]; then
  if kubectl -n argocd get secret argocd-notifications-secret >/dev/null 2>&1; then
    kubectl -n argocd patch secret argocd-notifications-secret \
      --patch="{\"stringData\":{\"slack-token\":\"${SLACK_TOKEN}\"}}" >/dev/null
    echo "    argocd/argocd-notifications-secret: slack-token patched"
  else
    echo "    argocd/argocd-notifications-secret: not present yet, skipping (re-run after argocd-notifications app syncs)"
  fi
else
  echo "    argocd/argocd-notifications-secret: skipped (SLACK_TOKEN not set)"
fi

if [[ "${GRAFANA_GENERATED:-0}" == "1" ]]; then
  echo
  echo "Grafana admin password (printed once -- save it now):"
  echo "    user:     admin"
  echo "    password: ${GRAFANA_PASSWORD}"
fi
