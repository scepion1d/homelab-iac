#!/usr/bin/env zsh
# Create the cluster-side secrets that Argo CD apps need but that aren't
# committed to git. Idempotent: never overwrites an existing secret.
#
# Required by:
#   - grafana (helm chart wires `existingSecret: grafana-admin`; without
#     this the chart rolls a new password on every sync and you can't
#     log in).
#   - grafana-alerts (slack contact points read $SLACK_BOT_TOKEN from the
#     `grafana-slack` Secret; without this Grafana pod fails to start once
#     `envValueFrom` is wired in cluster/apps/grafana/_appset.yaml).
#
# Optional (created only if the corresponding env var is set in
# bootstrap/.env):
#   - argocd-notifications-secret patch with SLACK_TOKEN.
#   - mikrotik-exporter-credentials with MIKROTIK_USER + MIKROTIK_PASSWORD.
#   - grafana-slack with GRAFANA_SLACK_BOT_TOKEN (xoxb-… bot token).
set -euo pipefail
cd "$(dirname "$0")"
source ../lib.sh
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

# AdGuard exporter credentials (mandatory for adguard-exporter to scrape AdGuard API).
if [[ -n "${ADGUARD_USER:-}" && -n "${ADGUARD_PASSWORD:-}" ]]; then
  create_secret_if_missing dns adguard-credentials \
    --from-literal=username="${ADGUARD_USER}" \
    --from-literal=password="${ADGUARD_PASSWORD}"
else
  echo "    dns/adguard-credentials: skipped (ADGUARD_USER/ADGUARD_PASSWORD not set)"
fi

# Grafana Slack bot token (required for Slack alerting; without it Grafana
# pod CrashLoops because of the missing env source mounted in
# cluster/apps/grafana/_appset.yaml).
if [[ -n "${GRAFANA_SLACK_BOT_TOKEN:-}" ]]; then
  create_secret_if_missing monitoring grafana-slack \
    --from-literal=token="${GRAFANA_SLACK_BOT_TOKEN}"
else
  echo "    monitoring/grafana-slack: skipped (GRAFANA_SLACK_BOT_TOKEN not set)"
fi

# Home Assistant Prometheus scrape token (optional; only meaningful once
# host/apps/home-assistant is deployed and you've created a Long-Lived
# Access Token in the HA UI). Mounted into Prometheus via
# `server.extraSecretMounts` in cluster/apps/prometheus/_appset.yaml; the
# scrape job (from host/apps/home-assistant/prometheus-target.yaml)
# references it via credentials_file: /etc/secrets/home-assistant-token.
if [[ -n "${HOMEASSISTANT_PROMETHEUS_TOKEN:-}" ]]; then
  create_secret_if_missing monitoring home-assistant-prometheus-token \
    --from-literal=token="${HOMEASSISTANT_PROMETHEUS_TOKEN}"
else
  echo "    monitoring/home-assistant-prometheus-token: skipped (HOMEASSISTANT_PROMETHEUS_TOKEN not set)"
fi

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
