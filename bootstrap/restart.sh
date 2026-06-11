#!/usr/bin/env zsh
# One-shot operational restart for the homelab runtime.
#
# Use this after a host reboot, sleep/wake weirdness, or when DNS/ingress
# become flaky and you want a deterministic restart path.
#
#   ~/src/homelab-iac/bootstrap/restart.sh            # everything
#   ~/src/homelab-iac/bootstrap/restart.sh cluster     # cluster only
#   ~/src/homelab-iac/bootstrap/restart.sh host-apps   # host apps only
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh
load_env

TARGET="${1:-all}"

echo "==> Stopping (${TARGET})..."
./stop.sh "${TARGET}"

echo "==> Starting (${TARGET})..."
./start.sh "${TARGET}"

# Refresh host DNS proxy so upstream VM IP changes are picked up.
if [[ "${TARGET}" == "all" || "${TARGET}" == "cluster" ]]; then
  echo "==> Refreshing host DNS proxy"
  ./steps/08-dns-proxy.sh || echo "WARNING: dns-proxy refresh failed" >&2
fi

echo
cat <<'EOF'
Restart complete.
Quick checks:
  kubectl get nodes
  dig @127.0.0.1 cloudflare.com +short
  curl -skI https://argocd.int
EOF
