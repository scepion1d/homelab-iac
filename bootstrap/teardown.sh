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
LEGACY_DNS_DAEMON="/Library/LaunchDaemons/com.homelab.dns-forwarder.plist"
DNS_PROXY_DAEMON="/Library/LaunchDaemons/com.homelab.dns-proxy.plist"
DNS_PROXY_SCRIPT_DIR="/usr/local/lib/homelab"
PF_DAEMON="/Library/LaunchDaemons/com.homelab.pf.plist"
PF_ANCHOR="/etc/pf.anchors/com.homelab.dns"
PF_CONF="/etc/pf.conf"

# Lima instance dir (matches the now-deprecated 06-dns-forwarder.sh).
if [[ "${COLIMA_PROFILE}" == "default" ]]; then
  LIMA_INSTANCE="colima"
else
  LIMA_INSTANCE="colima-${COLIMA_PROFILE}"
fi
LIMA_YAML="${HOME}/.colima/_lima/${LIMA_INSTANCE}/lima.yaml"

echo "==> Removing DNS proxy LaunchDaemon (if present)"
if [[ -f "${DNS_PROXY_DAEMON}" ]]; then
  sudo launchctl bootout system "${DNS_PROXY_DAEMON}" 2>/dev/null || true
  sudo rm -f "${DNS_PROXY_DAEMON}"
  echo "    removed ${DNS_PROXY_DAEMON}"
fi
if [[ -d "${DNS_PROXY_SCRIPT_DIR}" ]]; then
  sudo rm -rf "${DNS_PROXY_SCRIPT_DIR}"
  echo "    removed ${DNS_PROXY_SCRIPT_DIR}"
fi

echo "==> Removing pf forward LaunchDaemon (if present)"
if [[ -f "${PF_DAEMON}" ]]; then
  sudo launchctl bootout system "${PF_DAEMON}" 2>/dev/null || true
  sudo rm -f "${PF_DAEMON}"
  echo "    removed ${PF_DAEMON}"
fi
if [[ -f "${PF_ANCHOR}" ]]; then
  sudo rm -f "${PF_ANCHOR}"
  echo "    removed ${PF_ANCHOR}"
fi
if sudo grep -q '"com.homelab.dns"' "${PF_CONF}" 2>/dev/null; then
  sudo cp "${PF_CONF}" "${PF_CONF}.bak.$(date +%s)"
  sudo sed -i '' "\|# homelab-iac:pf BEGIN|,\|# homelab-iac:pf END|d" "${PF_CONF}"
  sudo sed -i '' "\|# Added by bootstrap/06-pf-forward.sh|,\|load anchor \"com.homelab.dns\"|d" "${PF_CONF}"
  sudo pfctl -f "${PF_CONF}" 2>/dev/null || true
  echo "    cleaned ${PF_CONF} (backup written)"
fi
# Removing the anchor from pf.conf does not evict already-loaded rules
# from the kernel; flush them explicitly so a stale rdr doesn't outlive
# teardown.
if sudo pfctl -sA 2>/dev/null | grep -q 'com.homelab.dns'; then
  sudo pfctl -a com.homelab.dns -F all 2>/dev/null || true
  echo "    flushed pf anchor com.homelab.dns"
fi

echo "==> Removing legacy socat DNS forwarder LaunchDaemon (if present)"
if [[ -f "${LEGACY_DNS_DAEMON}" ]]; then
  sudo launchctl bootout system "${LEGACY_DNS_DAEMON}" 2>/dev/null || true
  sudo rm -f "${LEGACY_DNS_DAEMON}"
  echo "    removed"
else
  echo "    not installed, skipping"
fi

echo "==> Reverting Lima UDP/53 portForward edit (if present)"
if [[ -f "${LIMA_YAML}" ]] && grep -qF '# homelab-iac:udp-53' "${LIMA_YAML}"; then
  sed -i.bak '/# homelab-iac:udp-53/,/^$/d' "${LIMA_YAML}"
  echo "    cleaned (backup at ${LIMA_YAML}.bak)"
else
  echo "    not present, skipping"
fi

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
