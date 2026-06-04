#!/usr/bin/env zsh
# Run a userspace UDP/53 DNS forwarder on the Mac so LAN clients can use
# AdGuard (which lives inside the Colima VM) as their resolver.
#
# Why userspace and not pf NAT:
#   Earlier versions of this script used pf `rdr` + `nat` to forward
#   <mac-lan-ip>:53/udp to the Colima VM. On the wire that worked
#   (tcpdump showed clean request/reply pairs on both interfaces) but
#   Windows clients silently dropped every reply with
#   `DropReason INET: checksum is invalid` (pktmon, tcpip.sys L3/L4).
#   Apple's pf is a 15-year-old fork of OpenBSD pf; its `scrub` directive
#   does NOT recompute UDP checksums after NAT rewrite, and the Wi-Fi
#   driver does not expose a `txcsum` knob (`ifconfig en1 -txcsum`
#   returns "does not support -txcsum"). Forwarded UDP packets ship with
#   stale/zero checksums and stricter clients reject them.
#
#   A userspace forwarder (dns-proxy.py) avoids the whole class of bug:
#   the kernel composes brand-new UDP packets for both directions with
#   valid checksums, just like any other socket app.
#
# Idempotent: re-run any time the Colima VM IP changes.

set -euo pipefail
cd "$(dirname "$0")"
source ../lib.sh
load_env

LABEL="com.homelab.dns-proxy"
PLIST_TEMPLATE="../launchd-system/${LABEL}.plist"
PLIST_DST="/Library/LaunchDaemons/${LABEL}.plist"
PY_SRC="../services/dns-proxy.py"
PY_DST_DIR="/usr/local/lib/homelab"
PY_DST="${PY_DST_DIR}/dns-proxy.py"

PROFILE="${COLIMA_PROFILE:-default}"

# --- discover the Mac's LAN IP ----------------------------------------------
# We must bind to a specific local IP, not 0.0.0.0, because mDNSResponder
# already owns the *:53 wildcard whenever Internet Sharing is enabled. A
# specific-IP bind plus SO_REUSEPORT (set in dns-proxy.py) lets BSD route
# UDP/53 packets destined for our LAN IP to python and leaves everything
# else to mDNSResponder.
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
echo "==> Binding UDP/53 on ${LAN_IFACE} (${LAN_IP})"

# --- discover the VM IP ------------------------------------------------------
# Colima >= 0.6 prints "address: 192.168.x.y" in `colima status` when
# started with --network-address. Tolerate both stdout/stderr placement
# and the quoted form some versions emit.
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
echo "==> Forwarding UDP/53 -> VM ${VM_IP}:53"

# --- migrate away from the legacy pf-based setup -----------------------------
# Older revisions of this script wrote an anchor + nat-anchor/rdr-anchor
# into /etc/pf.conf and installed com.homelab.pf as a LaunchDaemon. Clean
# both up so an upgrade leaves no orphans.
LEGACY_PF_DAEMON="/Library/LaunchDaemons/com.homelab.pf.plist"
LEGACY_PF_ANCHOR="/etc/pf.anchors/com.homelab.dns"
PF_CONF="/etc/pf.conf"
if [[ -f "${LEGACY_PF_DAEMON}" ]]; then
  echo "==> Removing legacy pf LaunchDaemon"
  sudo launchctl bootout system "${LEGACY_PF_DAEMON}" 2>/dev/null || true
  sudo rm -f "${LEGACY_PF_DAEMON}"
fi
if [[ -f "${LEGACY_PF_ANCHOR}" ]]; then
  sudo rm -f "${LEGACY_PF_ANCHOR}"
fi
if sudo grep -q '"com.homelab.dns"' "${PF_CONF}" 2>/dev/null; then
  echo "==> Cleaning legacy pf anchors out of ${PF_CONF}"
  sudo cp "${PF_CONF}" "${PF_CONF}.bak.$(date +%s)"
  sudo sed -i '' "\|# homelab-iac:pf BEGIN|,\|# homelab-iac:pf END|d" "${PF_CONF}"
  sudo sed -i '' "\|# Added by bootstrap/06-pf-forward.sh|,\|load anchor \"com.homelab.dns\"|d" "${PF_CONF}"
  sudo pfctl -f "${PF_CONF}" 2>/dev/null || true
fi
# Flush any rules still loaded under the anchor from a previous boot.
# Removing the anchor from pf.conf does NOT evict cached rules from the
# kernel; without this, pf may still rdr <mac-lan-ip>:53 to the VM and
# our forwarder never sees the packet.
if sudo pfctl -sA 2>/dev/null | grep -q 'com.homelab.dns'; then
  echo "==> Flushing stale pf rules under anchor com.homelab.dns"
  sudo pfctl -a com.homelab.dns -F all 2>/dev/null || true
fi

# --- install the python forwarder --------------------------------------------
echo "==> Installing forwarder to ${PY_DST}"
sudo install -d -m 0755 -o root -g wheel "${PY_DST_DIR}"
sudo install -m 0755 -o root -g wheel "${PY_SRC}" "${PY_DST}"

# --- render & install the LaunchDaemon plist ---------------------------------
echo "==> Installing LaunchDaemon ${PLIST_DST}"
TMP_PLIST="$(mktemp)"
trap 'rm -f "${TMP_PLIST}"' EXIT
# Stamp the live VM IP + LAN IP into the template; everything else is fixed.
sed -e "s|__VM_IP__|${VM_IP}|g" -e "s|__LAN_IP__|${LAN_IP}|g" \
    "${PLIST_TEMPLATE}" > "${TMP_PLIST}"
sudo install -m 0644 -o root -g wheel "${TMP_PLIST}" "${PLIST_DST}"

# Reload so a changed VM_IP takes effect.
sudo launchctl bootout system "${PLIST_DST}" 2>/dev/null || true
sudo launchctl bootstrap system "${PLIST_DST}"

# --- smoke test --------------------------------------------------------------
echo "==> Waiting for forwarder to come up"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if sudo lsof -nP -iUDP:53 2>/dev/null | grep -q python3; then
    break
  fi
  sleep 0.3
done

echo
echo "==> Active UDP/53 listeners on the Mac:"
sudo lsof -nP -iUDP:53 2>/dev/null | sed 's/^/    /' || true

# --- macOS application firewall ---------------------------------------------
# If the firewall is on, allow python3 (the forwarder) and colima
# (k3d's serverlb on 80/443) to receive inbound connections. socketfilterfw
# is a no-op when the firewall is off, so this is safe either way.
SFW="/usr/libexec/ApplicationFirewall/socketfilterfw"
if [[ -x "${SFW}" ]]; then
  STATE="$(sudo "${SFW}" --getglobalstate 2>/dev/null || true)"
  if echo "${STATE}" | grep -qi 'enabled'; then
    echo "==> macOS firewall is enabled; allowing python3 + colima"
    for app in /usr/bin/python3 "$(command -v colima 2>/dev/null || true)"; do
      [[ -z "${app}" || ! -e "${app}" ]] && continue
      sudo "${SFW}" --add "${app}" >/dev/null 2>&1 || true
      sudo "${SFW}" --unblockapp "${app}" >/dev/null 2>&1 || true
      echo "    allowed: ${app}"
    done
  else
    echo "==> macOS firewall is off; no allow rules needed"
  fi
fi

cat <<EOF

Done. Forwarder is bound on ${LAN_IP}:53/udp and proxies to ${VM_IP}:53.

Verify from another LAN device (phone/laptop, NOT this Mac):
    dig @${LAN_IP:-<mac-lan-ip>} cloudflare.com +short +timeout=2

Logs: /var/log/homelab-dns-proxy.log
Re-run this script whenever the VM IP changes (colima recreate, etc.).
EOF
