#!/usr/bin/env zsh
# Bootstraps the homelab from a fresh Intel Mac:
#   00 install CLI tooling
#   01 start container runtime (colima)
#   02 create the k3d cluster
#   03 install Argo CD
#   04 hand control to Argo CD (app-of-apps)
#   05 install LaunchAgents so everything auto-starts at login
#
# Idempotent: safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"

./00-install-deps.sh
./01-start-runtime.sh
./02-create-cluster.sh
./03-install-argocd.sh
./04-bootstrap-apps.sh
./05-enable-autostart.sh

echo
echo "Bootstrap complete. Argo CD is now reconciling apps from /apps."
echo "Initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
