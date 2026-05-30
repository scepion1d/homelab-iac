#!/usr/bin/env zsh
# Tear down the homelab in reverse order of bootstrap.sh:
#   - Unload & remove LaunchAgents (no more auto-start)
#   - Delete the k3d cluster (also removes Argo CD + all workloads)
#   - Stop Colima
#
# Does NOT:
#   - Uninstall brew tooling (run `brew uninstall colima docker k3d ...` if wanted)
#   - Delete the Colima profile / its disk (use --purge to also do that)
#
# Usage:
#   ./teardown.sh              # stop everything, keep Colima VM intact
#   ./teardown.sh --purge      # also delete the Colima profile (loses cached images)
set -euo pipefail
cd "$(dirname "$0")"

PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

AGENTS_DIR="${HOME}/Library/LaunchAgents"
CLUSTER_NAME="homelab"
COLIMA_PROFILE="${COLIMA_PROFILE:-default}"

echo "==> Removing LaunchAgents"
for plist in launchd/*.plist; do
  name="$(basename "${plist}")"
  target="${AGENTS_DIR}/${name}"
  if [[ -f "${target}" ]]; then
    launchctl unload "${target}" 2>/dev/null || true
    rm -f "${target}"
    echo "    removed ${name}"
  fi
done

echo "==> Deleting k3d cluster '${CLUSTER_NAME}'"
if k3d cluster list --no-headers 2>/dev/null | awk '{print $1}' | grep -qx "${CLUSTER_NAME}"; then
  k3d cluster delete "${CLUSTER_NAME}"
else
  echo "    cluster not present, skipping"
fi

echo "==> Stopping Colima profile '${COLIMA_PROFILE}'"
if colima status --profile "${COLIMA_PROFILE}" >/dev/null 2>&1; then
  colima stop --profile "${COLIMA_PROFILE}"
else
  echo "    not running, skipping"
fi

if (( PURGE )); then
  echo "==> Deleting Colima profile '${COLIMA_PROFILE}' (--purge)"
  colima delete --profile "${COLIMA_PROFILE}" --force
fi

echo
echo "Teardown complete. Re-run ./bootstrap.sh to rebuild."
