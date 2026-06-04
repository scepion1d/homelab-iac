#!/usr/bin/env zsh
# Install the userspace mDNS reflector that bridges _hap._tcp (and any
# other allowlisted service types) from the Colima vmnet onto the Mac's
# LAN interface.
#
# Why this exists:
#   Home Assistant runs in a Docker container with network_mode: host
#   inside the Colima VM. Its HomeKit Bridge broadcasts _hap._tcp via
#   mDNS, but those frames originate in the VM's network namespace.
#   macOS does not relay multicast between the vmnet bridge interface
#   (Mac side of Colima's --network-address vmnet) and the physical LAN
#   interface (en0). Result: Apple TV on the LAN never discovers HA.
#
#   The TCP path itself is fine: Colima auto-tunnels host-network
#   listeners, so <mac-lan-ip>:21063 reaches HA in the VM. Only the
#   discovery (mDNS) path is broken.
#
#   This script installs a tiny Python service (mdns-reflector.py) that
#   browses on the vmnet bridge and re-publishes on the LAN with the A
#   records rewritten to the Mac's LAN IP, so Apple TV connects back to
#   a reachable host.
#
# Companion to 08-dns-proxy.sh, same shape: discover live IPs, render
# the plist, install + activate. Idempotent: re-run any time the
# Colima VM IP changes (e.g. after `colima delete && colima start`).

set -euo pipefail
cd "$(dirname "$0")"
source ../lib.sh
load_env

LABEL="com.homelab.mdns-reflector"
PLIST_TEMPLATE="../launchd-system/${LABEL}.plist"
PLIST_DST="/Library/LaunchDaemons/${LABEL}.plist"
PY_SRC="../services/mdns-reflector.py"
APP_DIR="/usr/local/lib/homelab/mdns-reflector"
VENV_DIR="${APP_DIR}/venv"
PY_DST="${APP_DIR}/mdns-reflector.py"

PROFILE="${COLIMA_PROFILE:-default}"

# --- discover the Mac's LAN interface + IP -----------------------------------
# This is the DESTINATION side: where reflected announcements get published.
# Same discovery as 08-dns-proxy.sh; both services need the same LAN IP.
#
# `ipconfig getifaddr` works here because en0/en1 are managed by macOS
# IPConfiguration (DHCP). Vmnet bridges aren't, hence the different
# helper used below for the SRC side.
LAN_IFACE="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
if [[ -z "${LAN_IFACE}" ]]; then
  echo "ERROR: could not determine default LAN interface (route -n get default)." >&2
  exit 1
fi
LAN_IP="$(ipconfig getifaddr "${LAN_IFACE}" 2>/dev/null || true)"
if [[ -z "${LAN_IP}" ]]; then
  echo "ERROR: interface ${LAN_IFACE} has no IPv4 address." >&2
  exit 1
fi
echo "==> LAN side: ${LAN_IFACE} (${LAN_IP})"

# --- discover the Colima VM IP -----------------------------------------------
# The VM's vmnet IP tells us which Mac-side bridge interface to listen on.
# Same parsing as 08-dns-proxy.sh; keep them aligned.
VM_IP="$(colima status --profile "${PROFILE}" 2>&1 \
         | awk '/address:/ {print $NF; exit}' \
         | tr -d '"' \
         | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)"
if [[ -z "${VM_IP}" ]]; then
  echo "ERROR: Colima profile '${PROFILE}' has no vmnet address." >&2
  echo "       Start it with --network-address:" >&2
  echo "         colima stop --profile ${PROFILE}" >&2
  echo "         colima delete --profile ${PROFILE} -f" >&2
  echo "         ./bootstrap/01-start-runtime.sh" >&2
  exit 1
fi
echo "==> Colima VM IP: ${VM_IP}"

# --- discover the Mac-side vmnet bridge interface + IP ------------------------
# This is the SOURCE side. macOS creates a bridge (e.g. bridge100) for
# each shared/vmnet network; the Mac's end of the bridge owns the
# subnet's .1 address. `route -n get <VM_IP>` walks the routing table and
# tells us which interface egresses to that IP.
SRC_IFACE="$(route -n get "${VM_IP}" 2>/dev/null | awk '/interface:/{print $2; exit}')"
if [[ -z "${SRC_IFACE}" ]]; then
  echo "ERROR: no Mac-side route to VM IP ${VM_IP}." >&2
  echo "       Is colima up with --network-address? (colima status)" >&2
  exit 1
fi
# Vmnet bridges are NOT in IPConfiguration's database, so
# `ipconfig getifaddr bridge100` returns empty even though `ifconfig`
# clearly shows the inet address. Parse ifconfig directly. The first
# `inet ...` (non-localhost, non-link-local) on the interface is the
# Mac side of the vmnet subnet.
SRC_IP="$(ifconfig "${SRC_IFACE}" 2>/dev/null \
          | awk '/^[[:space:]]*inet / && $2 != "127.0.0.1" {print $2; exit}')"
if [[ -z "${SRC_IP}" ]]; then
  echo "ERROR: vmnet bridge ${SRC_IFACE} has no IPv4 address on the Mac side." >&2
  echo "       Try: ifconfig ${SRC_IFACE}" >&2
  exit 1
fi
echo "==> vmnet side: ${SRC_IFACE} (${SRC_IP})"

if [[ "${SRC_IP}" == "${LAN_IP}" ]]; then
  echo "ERROR: SRC and DST IPs are identical (${SRC_IP})." >&2
  echo "       This would create an mDNS broadcast loop. Aborting." >&2
  exit 1
fi

# --- install python script + venv with zeroconf ------------------------------
# Pinned: zeroconf moves slowly and we don't want surprise breakage on
# every reboot. Bump intentionally.
ZEROCONF_VERSION="0.132.2"

echo "==> Installing reflector to ${PY_DST}"
sudo install -d -m 0755 -o root -g wheel "${APP_DIR}"
sudo install -m 0755 -o root -g wheel "${PY_SRC}" "${PY_DST}"

# Create venv on first run. python3 -m venv is a no-op (well, error) on
# an existing venv unless --upgrade is passed; checking presence is
# simpler and lets us skip pip on repeated runs unless the script
# itself changed.
if [[ ! -x "${VENV_DIR}/bin/python3" ]]; then
  echo "==> Creating venv at ${VENV_DIR}"
  sudo /usr/bin/python3 -m venv "${VENV_DIR}"
fi

# Always ensure zeroconf is at the pinned version. Cheap when already
# installed (pip short-circuits), and self-heals if the venv was hand-
# tampered with.
echo "==> Ensuring zeroconf==${ZEROCONF_VERSION} in venv"
sudo "${VENV_DIR}/bin/pip" install --quiet --upgrade pip
sudo "${VENV_DIR}/bin/pip" install --quiet "zeroconf==${ZEROCONF_VERSION}"

# --- render & install the LaunchDaemon plist ---------------------------------
echo "==> Installing LaunchDaemon ${PLIST_DST}"
TMP_PLIST="$(mktemp)"
trap 'rm -f "${TMP_PLIST}"' EXIT
sed -e "s|__SRC_IP__|${SRC_IP}|g" -e "s|__DST_IP__|${LAN_IP}|g" \
    "${PLIST_TEMPLATE}" > "${TMP_PLIST}"
sudo install -m 0644 -o root -g wheel "${TMP_PLIST}" "${PLIST_DST}"

# Reload so changed SRC/DST IPs take effect.
sudo launchctl bootout system "${PLIST_DST}" 2>/dev/null || true
sudo launchctl bootstrap system "${PLIST_DST}"

# --- macOS application firewall ---------------------------------------------
# If the firewall is on, allow the venv python so it can receive mDNS
# (UDP/5353). socketfilterfw is a no-op when the firewall is off.
SFW="/usr/libexec/ApplicationFirewall/socketfilterfw"
if [[ -x "${SFW}" ]]; then
  STATE="$(sudo "${SFW}" --getglobalstate 2>/dev/null || true)"
  if echo "${STATE}" | grep -qi 'enabled'; then
    VENV_PY="${VENV_DIR}/bin/python3"
    echo "==> macOS firewall is enabled; allowing ${VENV_PY}"
    sudo "${SFW}" --add "${VENV_PY}" >/dev/null 2>&1 || true
    sudo "${SFW}" --unblockapp "${VENV_PY}" >/dev/null 2>&1 || true
  fi
fi

cat <<EOF

Done. mdns-reflector is browsing _hap._tcp on ${SRC_IFACE} (${SRC_IP})
and re-publishing on ${LAN_IFACE} (${LAN_IP}).

Verify (from any LAN device, NOT this Mac -- macOS dns-sd browses on
en0 by default which is what we publish to):

    dns-sd -B _hap._tcp

Expect to see a 'Home Lab ...' entry within a few seconds, in addition
to whatever HomeKit hubs are already on the LAN. Then on Apple TV:
    Settings -> AirPlay & HomeKit -> Add Accessory.

Logs: /var/log/homelab-mdns-reflector.log
Re-run this script whenever the Colima VM is recreated (the vmnet
bridge name / IP may change) or the Mac's LAN IP changes.
EOF
