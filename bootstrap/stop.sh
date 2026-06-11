#!/usr/bin/env zsh
# stop.sh — gracefully stop the homelab: host apps + cluster.
#
#   ~/src/homelab-iac/bootstrap/stop.sh             # everything
#   ~/src/homelab-iac/bootstrap/stop.sh cluster      # cluster only
#   ~/src/homelab-iac/bootstrap/stop.sh host-apps    # host apps only
#
# For destructive teardown (delete cluster, purge data), use teardown.sh.
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh
load_env

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [stop] $*"; }

TARGET="${1:-all}"

# --- Host Apps ----------------------------------------------------------------
stop_host_apps() {
  log "Stopping host apps..."
  # Host app containers are named homelab-<app>. Stop them directly
  # rather than going through docker compose (which needs env vars
  # like APP_DATA that only 09-host-apps.sh sets up).
  for container in $(docker ps -a --filter "name=^homelab-" --format '{{.Names}}' 2>/dev/null); do
    log "Stopping ${container}..."
    docker stop "${container}" 2>&1 || true
  done
  log "Host apps stopped"
}

# --- Cluster ------------------------------------------------------------------
stop_cluster() {
  # Dump the CA secret before stopping so it survives a cluster recreate.
  local dump_ca="$(cd "$(dirname "$0")" && pwd)/tools/dump-ca-secret.sh"
  if [[ -x "${dump_ca}" ]] && kubectl get ns cert-manager >/dev/null 2>&1; then
    log "Dumping CA secret..."
    CA_SECRET_BACKUP_PATH="${CERT_YAML:-}" "${dump_ca}" 2>&1 || log "WARNING: CA dump failed"
  fi

  log "Stopping k3d cluster..."
  k3d cluster stop homelab 2>&1 || true
  log "k3d cluster stopped"

  log "Stopping Colima..."
  colima stop 2>&1 || true
  log "Colima stopped"
}

# --- Dispatch -----------------------------------------------------------------
case "${TARGET}" in
  all)
    stop_host_apps
    stop_cluster
    ;;
  cluster)
    stop_cluster
    ;;
  host-apps)
    stop_host_apps
    ;;
  *)
    echo "Usage: $0 [all|cluster|host-apps]" >&2
    exit 1
    ;;
esac

log "Homelab stopped (${TARGET})"
