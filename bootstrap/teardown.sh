#!/usr/bin/env zsh
# Tear down the homelab in reverse order of bootstrap.sh:
#   - Unload & remove LaunchAgents (no more auto-start)
#   - Delete the k3d cluster (also removes Argo CD + all workloads)
#   - Stop Colima
#
# Does NOT (by default):
#   - Uninstall brew tooling (run `brew uninstall colima docker k3d ...` if wanted)
#   - Delete the Colima profile / its disk (use --purge to also do that)
#   - Touch host apps under host/apps/* (use --include-host-apps)
#   - Delete host-side persistent data under ~/homelab-data (use --nuke)
#
# Usage:
#   ./teardown.sh                       # stop cluster, keep Colima VM and host apps
#   ./teardown.sh --purge               # also delete the Colima profile (loses cached images)
#   ./teardown.sh --include-host-apps   # also stop+remove host-side containers
#                                       # (data under ~/homelab-data is kept)
#   ./teardown.sh --nuke                # everything: cluster + host apps + host data
#                                       # asks you to type the repo name to confirm
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh
load_env

PURGE=0
INCLUDE_HOST_APPS=0
NUKE=0
for arg in "$@"; do
  case "${arg}" in
    --purge)             PURGE=1 ;;
    --include-host-apps) INCLUDE_HOST_APPS=1 ;;
    --nuke)              NUKE=1; INCLUDE_HOST_APPS=1; PURGE=1 ;;
    --help|-h)
      sed -n '2,21p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown flag: ${arg}" >&2
      exit 2
      ;;
  esac
done

# --nuke is irreversible (deletes ~/homelab-data) — require confirmation.
if (( NUKE )); then
  echo
  echo "!! --nuke will DELETE host-side data under ~/homelab-data,"
  echo "!! stop all host containers, delete the cluster, AND delete the Colima profile."
  printf "Type 'homelab-iac' to confirm: "
  read -r reply
  if [[ "${reply}" != "homelab-iac" ]]; then
    echo "Aborted."
    exit 1
  fi
fi

# --- Snapshot cluster secrets into bootstrap/.env before destruction --------
# Runs only when the cluster is still reachable (skips silently after a
# previous failed teardown or when kubectl is misconfigured). Auto-
# generated values (Grafana admin password, anything else 06 created
# from scratch) would otherwise be lost forever; this preserves them so
# the next ./bootstrap/bootstrap.sh reuses the exact same credentials.
if kubectl version --request-timeout=5s >/dev/null 2>&1; then
  echo "==> Snapshotting cluster secrets into bootstrap/.env"
  ./tools/dump-cluster-secrets.sh || \
    echo "    WARNING: dump-cluster-secrets failed; proceeding anyway" >&2
else
  echo "==> Cluster not reachable; skipping secret snapshot"
fi

AGENTS_DIR="${HOME}/Library/LaunchAgents"
CLUSTER_NAME="homelab"
COLIMA_PROFILE="${COLIMA_PROFILE:-default}"
LEGACY_DNS_DAEMON="/Library/LaunchDaemons/com.homelab.dns-forwarder.plist"
DNS_PROXY_DAEMON="/Library/LaunchDaemons/com.homelab.dns-proxy.plist"
DNS_PROXY_SCRIPT_DIR="/usr/local/lib/homelab"
MDNS_REFLECTOR_DAEMON="/Library/LaunchDaemons/com.homelab.mdns-reflector.plist"
MDNS_REFLECTOR_APP_DIR="/usr/local/lib/homelab/mdns-reflector"
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

echo "==> Removing mDNS reflector LaunchDaemon (if present)"
if [[ -f "${MDNS_REFLECTOR_DAEMON}" ]]; then
  sudo launchctl bootout system "${MDNS_REFLECTOR_DAEMON}" 2>/dev/null || true
  sudo rm -f "${MDNS_REFLECTOR_DAEMON}"
  echo "    removed ${MDNS_REFLECTOR_DAEMON}"
fi
if [[ -d "${MDNS_REFLECTOR_APP_DIR}" ]]; then
  sudo rm -rf "${MDNS_REFLECTOR_APP_DIR}"
  echo "    removed ${MDNS_REFLECTOR_APP_DIR}"
fi

echo "==> Removing DNS proxy LaunchDaemon (if present)"
if [[ -f "${DNS_PROXY_DAEMON}" ]]; then
  sudo launchctl bootout system "${DNS_PROXY_DAEMON}" 2>/dev/null || true
  sudo rm -f "${DNS_PROXY_DAEMON}"
  echo "    removed ${DNS_PROXY_DAEMON}"
fi
# DNS_PROXY_SCRIPT_DIR is the shared /usr/local/lib/homelab parent.
# Only purge it if no other homelab artifacts (e.g. the mdns-reflector
# app dir handled above) live under it -- the mdns-reflector branch may
# have already removed its subdir, but other future scripts might add
# theirs. Empty-directory check keeps this safe either way.
if [[ -d "${DNS_PROXY_SCRIPT_DIR}" ]]; then
  # Remove the dns-proxy.py file itself before considering rmdir.
  sudo rm -f "${DNS_PROXY_SCRIPT_DIR}/dns-proxy.py"
  if [[ -z "$(ls -A "${DNS_PROXY_SCRIPT_DIR}" 2>/dev/null)" ]]; then
    sudo rmdir "${DNS_PROXY_SCRIPT_DIR}"
    echo "    removed ${DNS_PROXY_SCRIPT_DIR}"
  else
    echo "    kept ${DNS_PROXY_SCRIPT_DIR} (other artifacts present)"
  fi
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

echo "==> Removing LaunchAgents (legacy)"
for old in com.homelab.colima.plist com.homelab.k3d.plist; do
  target="${AGENTS_DIR}/${old}"
  if [[ -f "${target}" ]]; then
    launchctl unload "${target}" 2>/dev/null || true
    rm -f "${target}"
    echo "    removed ${old}"
  fi
done

echo "==> Removing LaunchDaemons"
DAEMONS_DIR="/Library/LaunchDaemons"
for plist in launchd-system/*.plist; do
  [[ -f "${plist}" ]] || continue
  name="$(basename "${plist}")"
  target="${DAEMONS_DIR}/${name}"
  if [[ -f "${target}" ]]; then
    sudo launchctl bootout system "${target}" 2>/dev/null || true
    sudo rm -f "${target}"
    echo "    removed ${name}"
  fi
done

echo "==> Removing heal.sh socat bridges (if present)"
for c in apibridge http https dns-udp dns-tcp; do
  name="k3d-${CLUSTER_NAME}-${c}"
  if docker rm -f "${name}" >/dev/null 2>&1; then
    echo "    removed ${name}"
  fi
done

if (( INCLUDE_HOST_APPS )); then
  echo "==> Stopping host-side apps (--include-host-apps)"
  # Iterate every compose project named homelab-*, then drop the shared
  # network if empty. Data under ~/homelab-data is kept unless --nuke also
  # set above.
  while IFS= read -r line; do
    proj="${line#homelab-}"
    [[ -z "${proj}" || "${proj}" == "${line}" ]] && continue
    if [[ -f "../host/apps/${proj}/compose.yaml" ]]; then
      ( source ./lib.sh && load_host_globals 2>/dev/null && compose_down "${proj}" ) \
        || docker rm -f "homelab-${proj}" >/dev/null 2>&1 || true
    else
      docker rm -f "homelab-${proj}" >/dev/null 2>&1 || true
    fi
    echo "    stopped ${line}"
  done < <(docker ps -a --filter "name=^homelab-" --format '{{.Names}}')

  # Drop the homelab docker network if no containers remain on it.
  if docker network inspect homelab >/dev/null 2>&1; then
    if [[ -z "$(docker network inspect homelab -f '{{range .Containers}}{{.Name}} {{end}}')" ]]; then
      docker network rm homelab >/dev/null 2>&1 && echo "    removed network 'homelab'" || true
    fi
  fi
fi

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

if (( NUKE )) && [[ -d "${HOME}/homelab-data" ]]; then
  echo "==> Deleting host-side data under ~/homelab-data (--nuke)"
  rm -rf "${HOME}/homelab-data"
fi

echo
echo "Teardown complete. Re-run ./bootstrap.sh to rebuild."
