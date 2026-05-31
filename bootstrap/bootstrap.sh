#!/usr/bin/env zsh
# Bootstraps the homelab from a fresh Intel Mac.
#
# All credentials (AdGuard wizard password, optional Slack/MikroTik) live
# in bootstrap/.env -- gitignored. Copy bootstrap/.env.example to
# bootstrap/.env, fill it in, then run me.
#
# Runs the numbered scripts in order:
#   00 install CLI tooling
#   01 start the colima runtime (with --network-address so the VM gets a
#      LAN-routable IP -- needed for AdGuard to serve DNS on the LAN)
#   02 create the k3d cluster
#   03 install Argo CD
#   04 hand control to Argo CD (root ApplicationSet)
#   05 install LaunchAgents so everything auto-starts at login
#   06 create cluster-side secrets that aren't in git (grafana-admin etc.)
#   07 drive the AdGuard first-run wizard via API
#   08 install the host-side UDP/53 DNS forwarder + macOS firewall rules
#
# Idempotent: safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh
load_env

# Fail fast: the AdGuard wizard step (07) needs these, and finding out at
# second 0 is much nicer than at second 600.
require_var ADGUARD_USER
require_var ADGUARD_PASSWORD

./00-install-deps.sh
./01-start-runtime.sh
./02-create-cluster.sh
./03-install-argocd.sh
./04-bootstrap-apps.sh
./05-enable-autostart.sh
./06-cluster-secrets.sh
./07-adguard-setup.sh
./08-dns-proxy.sh

echo
echo "Bootstrap complete. Argo CD is now reconciling apps from /cluster/apps."
echo "Initial Argo CD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
