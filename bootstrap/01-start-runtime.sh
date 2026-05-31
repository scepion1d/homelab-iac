#!/usr/bin/env zsh
# Start the Colima VM (container runtime). Idempotent.
#
# Sizing guidelines (Intel Mac homelab):
#   - Give the VM at most ~75% of host RAM/CPU to leave headroom for macOS.
#   - Measure host: sysctl -n hw.physicalcpu ; sysctl -n hw.memsize ; df -h ~
#   - Measure VM:   colima ssh -- top -bn1 ; kubectl top nodes
#   - Re-tune:      colima stop && COLIMA_CPU=6 COLIMA_MEMORY=12 ./01-start-runtime.sh
set -euo pipefail

PROFILE="${COLIMA_PROFILE:-default}"
CPU="${COLIMA_CPU:-6}"
MEMORY="${COLIMA_MEMORY:-24}"    # GiB
DISK="${COLIMA_DISK:-100}"       # GiB (sparse — only grows as used)
# Give the VM a LAN-routable IP via vmnet. Required for AdGuard to serve
# DNS on the LAN: k3d publishes 53/udp on the VM, and with a routable VM IP
# the LAN can reach it directly (no host port-forward, no mDNSResponder
# collision). See bootstrap/README.md "LAN DNS on :53". Set to "false" to
# fall back to user-mode networking (cluster works, but LAN DNS won't).
NETWORK_ADDRESS="${COLIMA_NETWORK_ADDRESS:-true}"

start_args=(
  --profile "${PROFILE}"
  --cpu "${CPU}"
  --memory "${MEMORY}"
  --disk "${DISK}"
)
if [[ "${NETWORK_ADDRESS}" == "true" ]]; then
  start_args+=(--network-address)
fi

if colima status --profile "${PROFILE}" >/dev/null 2>&1; then
  echo "Colima '${PROFILE}' already running, skipping."
  if [[ "${NETWORK_ADDRESS}" == "true" ]] \
     && ! colima status --profile "${PROFILE}" 2>&1 | grep -qE 'address:[[:space:]]+[0-9]'; then
    echo "WARNING: Colima is running WITHOUT --network-address. AdGuard LAN" >&2
    echo "         DNS will not work. Stop and recreate to fix:" >&2
    echo "           colima stop --profile ${PROFILE}" >&2
    echo "           colima delete --profile ${PROFILE} -f" >&2
    echo "           ./bootstrap/01-start-runtime.sh" >&2
  fi
else
  colima start "${start_args[@]}"
fi

docker info >/dev/null
echo "Docker engine reachable via Colima (cpu=${CPU}, mem=${MEMORY}GiB, disk=${DISK}GiB)."

# --- Disable VM dnsmasq ------------------------------------------------------
# The Colima/Lima VM ships with dnsmasq listening on :53 inside the VM, which
# Lima then forwards to host :53. That blocks k3d (step 02) from publishing
# AdGuard's DNS service on host :53 ("address already in use"). We don't need
# the VM's dnsmasq — step 02 wires k3d nodes' /etc/resolv.conf to public DNS.
#
# We `mask` as well as `disable` because a plain `disable` lets dnsmasq come
# back on the next `colima stop && colima start`, which has bitten us:
# after the VM restarts the k3d serverlb fails to bind :53 and the whole
# DNS path breaks. mask is the only way to make the disable survive.
if colima ssh --profile "${PROFILE}" -- systemctl is-active dnsmasq >/dev/null 2>&1 \
   || colima ssh --profile "${PROFILE}" -- systemctl is-enabled dnsmasq >/dev/null 2>&1 \
   || ! colima ssh --profile "${PROFILE}" -- systemctl is-enabled dnsmasq 2>&1 | grep -q masked; then
  echo "Disabling + masking dnsmasq inside the Colima VM (frees :53 for k3d)..."
  colima ssh --profile "${PROFILE}" -- sudo systemctl disable --now dnsmasq 2>/dev/null || true
  colima ssh --profile "${PROFILE}" -- sudo systemctl mask dnsmasq 2>/dev/null || true
fi
