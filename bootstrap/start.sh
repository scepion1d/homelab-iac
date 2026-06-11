#!/usr/bin/env zsh
# start.sh — bring up the full homelab: cluster + host apps.
#
# Called at boot by com.homelab.cluster LaunchDaemon, or manually:
#   ~/src/homelab-iac/bootstrap/start.sh           # everything
#   ~/src/homelab-iac/bootstrap/start.sh cluster    # cluster only
#   ~/src/homelab-iac/bootstrap/start.sh host-apps  # host apps only
#
# Logs (when run via LaunchDaemon): /tmp/homelab-cluster.{log,err}
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh
load_env

BOOTSTRAP_DIR="$(pwd)"
STEPS_DIR="${BOOTSTRAP_DIR}/steps"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [start] $*"; }

TARGET="${1:-all}"

# --- Cluster ------------------------------------------------------------------
start_cluster() {
  # 1. Start Colima VM (delegates to 01-start-runtime.sh which handles
  #    --network-address, dnsmasq masking, profile, sizing, and retries).
  log "Starting Colima..."
  if colima status --profile "${COLIMA_PROFILE:-default}" >/dev/null 2>&1; then
    log "Colima already running"
  else
    local runtime_script="${STEPS_DIR}/01-start-runtime.sh"
    if [[ -x "${runtime_script}" ]]; then
      "${runtime_script}"
    else
      colima start --profile "${COLIMA_PROFILE:-default}"
    fi
    log "Colima started"
  fi

  # Re-discover DOCKER_HOST now that Colima is up (the socket path
  # may not have existed when load_env ran at script start).
  ensure_docker_host

  # 2. Wait for Docker daemon
  log "Waiting for Docker daemon..."
  for i in {1..60}; do
    docker info >/dev/null 2>&1 && break
    sleep 2
  done

  if ! docker info >/dev/null 2>&1; then
    log "ERROR: Docker daemon not reachable after 120s — aborting"
    exit 1
  fi
  log "Docker ready"

  # 3. Start k3d cluster (or auto-recover if containers are broken)
  log "Starting k3d cluster..."
  local cluster_ok=false

  if k3d cluster start homelab 2>&1; then
    sleep 5
    # Refresh kubeconfig (API port may change across restarts).
    k3d kubeconfig merge homelab --kubeconfig-merge-default --kubeconfig-switch-context >/dev/null 2>&1 || true
    # Verify the cluster is actually reachable.
    if kubectl get nodes >/dev/null 2>&1; then
      cluster_ok=true
      log "k3d cluster started"
    else
      log "k3d cluster started but API unreachable"
    fi
  else
    log "k3d cluster start failed"
  fi

  # 4. Auto-recovery: if the cluster is broken, rebuild from scratch.
  #    Everything that matters is in git + .env — no data is lost.
  if [[ "${cluster_ok}" != "true" ]]; then
    log "=== AUTO-RECOVERY: rebuilding cluster from scratch ==="

    # Delete the broken cluster (ignore errors if already gone).
    log "Deleting broken cluster..."
    k3d cluster delete homelab 2>&1 || true

    # Recreate: cluster → ArgoCD → apps → secrets → AdGuard wizard.
    log "Creating cluster..."
    "${STEPS_DIR}/02-create-cluster.sh"

    # Refresh kubeconfig for the new cluster.
    k3d kubeconfig merge homelab --kubeconfig-merge-default --kubeconfig-switch-context >/dev/null 2>&1 || true
    log "Kubeconfig refreshed"

    log "Installing ArgoCD..."
    "${STEPS_DIR}/03-install-argocd.sh"

    # Wait for ArgoCD to be ready before registering repo creds.
    log "Waiting for ArgoCD pods..."
    kubectl -n argocd wait --for=condition=available deploy/argocd-server \
      --timeout=180s 2>&1 || log "WARNING: ArgoCD server not ready after 180s"

    log "Bootstrapping apps (repo creds + root AppSet)..."
    "${STEPS_DIR}/04-bootstrap-apps.sh"

    log "Creating cluster secrets..."
    "${STEPS_DIR}/06-cluster-secrets.sh"

    # Restore CA secret from backup so devices keep trusting the same CA.
    local restore_ca="${BOOTSTRAP_DIR}/tools/restore-ca-secret.sh"
    local ca_backup="${CERT_YAML:-${BOOTSTRAP_DIR}/.ca-secret.yaml}"
    if [[ -x "${restore_ca}" && -f "${ca_backup}" ]]; then
      log "Restoring CA secret from ${ca_backup}..."
      CA_SECRET_BACKUP_PATH="${ca_backup}" "${restore_ca}" 2>&1 || log "WARNING: CA restore failed"
    else
      log "No CA backup found — cert-manager will generate a new CA"
    fi

    log "Configuring AdGuard..."
    "${STEPS_DIR}/07-adguard-setup.sh" || log "WARNING: AdGuard setup failed (may need manual wizard)"

    # Wait for DNS to settle before running heal smoke tests.
    log "Waiting for AdGuard pods..."
    kubectl -n dns wait --for=condition=ready pod -l app.kubernetes.io/name=adguard \
      --timeout=120s 2>&1 || log "WARNING: AdGuard pod not ready after 120s"

    log "=== AUTO-RECOVERY COMPLETE ==="
  fi

  # 5. Post-restart recovery (fixes serverlb wedge, dnsmasq, etc.)
  local heal="${BOOTSTRAP_DIR}/heal.sh"
  if [[ -x "${heal}" ]]; then
    log "Running heal.sh..."
    "${heal}"
    log "heal.sh complete"
  fi

  # 6. Ensure custom images are built and available.
  local build_images="${BOOTSTRAP_DIR}/tools/build-images.sh"
  if [[ -x "${build_images}" ]]; then
    log "Building custom images..."
    "${build_images}" 2>&1 || log "WARNING: image build failed"
  fi
}

# --- Host Services (need Colima up) -------------------------------------------
start_host_services() {
  # Reinstall dns-proxy (VM IP may have changed after recreate).
  local dns_proxy="${STEPS_DIR}/08-dns-proxy.sh"
  if [[ -x "${dns_proxy}" ]]; then
    log "Refreshing dns-proxy..."
    "${dns_proxy}" 2>&1 || log "WARNING: dns-proxy setup failed"
  fi

  # These LaunchDaemons have RunAtLoad=false because they need the Colima
  # vmnet bridge to exist. Kick them now that Colima is confirmed up.
  for svc in com.homelab.node-exporter com.homelab.mdns-reflector; do
    log "Kicking ${svc}..."
    sudo launchctl kickstart -k "system/${svc}" 2>&1 || true
  done
  log "Host services started"
}

# --- Host Apps ----------------------------------------------------------------
start_host_apps() {
  local host_apps_script="${STEPS_DIR}/09-host-apps.sh"
  if [[ -x "${host_apps_script}" ]]; then
    log "Reconciling host apps..."
    "${host_apps_script}"
    log "Host apps up"
  else
    log "WARNING: 09-host-apps.sh not found"
  fi
}

# --- Dispatch -----------------------------------------------------------------
case "${TARGET}" in
  all)
    start_cluster
    start_host_services
    start_host_apps
    ;;
  cluster)
    start_cluster
    ;;
  host-apps)
    start_host_apps
    ;;
  *)
    echo "Usage: $0 [all|cluster|host-apps]" >&2
    exit 1
    ;;
esac

log "Homelab is up (${TARGET})"
