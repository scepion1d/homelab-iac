#!/usr/bin/env zsh
# shutdown-hook.sh — runs as a KeepAlive LaunchDaemon that does nothing until
# macOS sends SIGTERM on shutdown/reboot. The trap runs stop.sh for a clean
# cluster shutdown (k3d stop → colima stop).
#
# Without this, Colima's VM gets force-killed on reboot, which can corrupt
# Docker metadata and require a full cluster rebuild on next boot.
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh
load_env

BOOTSTRAP_DIR="$(pwd)"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [shutdown-hook] $*"; }

cleanup() {
  log "System shutting down — stopping homelab gracefully..."
  "${BOOTSTRAP_DIR}/stop.sh" 2>&1 || true
  log "Clean shutdown complete"
  exit 0
}

trap cleanup TERM INT

log "Shutdown hook active (PID $$)"

# Sleep forever — macOS SIGTERM wakes us on shutdown.
while true; do
  sleep 86400 &
  wait $! || true
done
