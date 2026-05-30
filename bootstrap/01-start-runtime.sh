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

if colima status --profile "${PROFILE}" >/dev/null 2>&1; then
  echo "Colima '${PROFILE}' already running, skipping."
else
  colima start \
    --profile "${PROFILE}" \
    --cpu "${CPU}" \
    --memory "${MEMORY}" \
    --disk "${DISK}"
fi

docker info >/dev/null
echo "Docker engine reachable via Colima (cpu=${CPU}, mem=${MEMORY}GiB, disk=${DISK}GiB)."
