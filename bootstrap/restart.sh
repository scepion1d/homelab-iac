#!/usr/bin/env zsh
# One-shot operational restart for the homelab runtime.
#
# Use this after a host reboot, sleep/wake weirdness, or when DNS/ingress
# become flaky and you want a deterministic restart path.
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh
load_env

PROFILE="${COLIMA_PROFILE:-default}"
CLUSTER="homelab"

echo "==> Restarting Colima profile '${PROFILE}'"
if colima status --profile "${PROFILE}" >/dev/null 2>&1; then
  colima restart --profile "${PROFILE}"
else
  ./01-start-runtime.sh
fi

# 01 is idempotent and keeps dnsmasq masked (required for :53 publishing).
echo "==> Re-applying runtime prerequisites"
./01-start-runtime.sh

echo "==> Ensuring k3d cluster '${CLUSTER}' is running"
if k3d cluster list | awk 'NR>1 {print $1}' | grep -qx "${CLUSTER}"; then
  k3d cluster start "${CLUSTER}"
else
  echo "ERROR: k3d cluster '${CLUSTER}' does not exist yet." >&2
  echo "       Run ./bootstrap.sh once to create it." >&2
  exit 1
fi

echo "==> Running heal workflow"
./heal.sh

# Refresh host DNS proxy so upstream VM IP changes are picked up.
echo "==> Refreshing host DNS proxy"
./08-dns-proxy.sh || echo "WARNING: dns-proxy refresh failed; run ./08-dns-proxy.sh manually" >&2

echo
cat <<'EOF'
Restart complete.
Quick checks:
  kubectl get nodes
  dig @127.0.0.1 cloudflare.com +short
  curl -skI https://argocd.int
EOF
