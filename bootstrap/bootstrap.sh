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
#   04 hand control to Argo CD (root ApplicationSet); register git PAT
#   05 install LaunchAgents so everything auto-starts at login
#   06 create cluster-side secrets that aren't in git (grafana-admin etc.)
#   07 drive the AdGuard first-run wizard via API
#   08 install the host-side UDP/53 DNS forwarder + macOS firewall rules
#   09 bring up host-side apps from host/apps/* (Docker compose on Colima)
#   10 install macOS-host Prometheus exporter (node_exporter + mac-extras)
#   11 install the Colima -> LAN mDNS reflector (HomeKit discovery)
#
# Finally: snapshot every cluster-side secret back into bootstrap/.env so
# the next teardown + bootstrap cycle reuses the exact same values (in
# particular any auto-generated Grafana admin password).
#
# Idempotent: safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh
load_env

# Activate the repo's versioned git hooks (e.g. pre-commit revision bumper).
# Idempotent — safe to re-run; see ../init.sh.
( cd .. && ./init.sh )

# Fail fast: the AdGuard wizard step (07) needs these, and finding out at
# second 0 is much nicer than at second 600.
require_var ADGUARD_USER
require_var ADGUARD_PASSWORD

./steps/00-install-deps.sh
./steps/01-start-runtime.sh
./steps/02-create-cluster.sh
./steps/03-install-argocd.sh
./steps/04-bootstrap-apps.sh
./steps/05-enable-autostart.sh
./steps/06-cluster-secrets.sh
./steps/07-adguard-setup.sh
./steps/08-dns-proxy.sh
./steps/09-host-apps.sh
./steps/10-mac-exporter.sh
./steps/11-mdns-reflector.sh

# Capture every cluster-side secret back into bootstrap/.env so a future
# `colima delete -f && ./bootstrap/bootstrap.sh` reuses the exact same
# values (Grafana auto-generated admin password in particular -- without
# this, the operator would have to fish it out of the bootstrap output
# scrollback before the next rebuild).
#
# Tolerated to fail (`|| true`): on a brand-new cluster some optional
# secrets may not exist yet, and dump-cluster-secrets simply skips them.
# A genuine failure to write .env shouldn't fail the bootstrap.
echo
echo "==> Refreshing bootstrap/.env from live cluster secrets"
./tools/dump-cluster-secrets.sh || \
  echo "    WARNING: dump-cluster-secrets failed; .env may be stale" >&2

# Restore the cert-manager root CA from a previous snapshot, if present.
# Only meaningful on a rebuild: the fresh bootstrap just had cert-manager
# generate a brand-new CA, so any device that previously trusted
# homelab-ca now sees an unknown cert. If a snapshot exists at
# bootstrap/.ca-secret.yaml (from the dump-cluster-secrets that preceded
# the teardown), restoring it round-trips every device's existing trust.
#
# Skipped silently on a true first-run install (no backup yet).
if [[ -f .ca-secret.yaml ]] || [[ -f "${CA_SECRET_BACKUP_PATH:-/nonexistent}" ]]; then
  echo
  echo "==> Restoring cert-manager root CA from snapshot"
  ./tools/restore-ca-secret.sh || \
    echo "    WARNING: CA restore failed; devices may need to re-import homelab-ca" >&2
fi

echo
echo "Bootstrap complete. Argo CD is now reconciling apps from /cluster/apps."
echo "Initial Argo CD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
