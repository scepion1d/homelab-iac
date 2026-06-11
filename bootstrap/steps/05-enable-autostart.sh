#!/usr/bin/env zsh
# Install all homelab LaunchDaemons so services start at boot.
# Re-running re-installs (bootout, copy, bootstrap) — safe and idempotent.
# Requires sudo.
#
# Plists installed:
#   com.homelab.cluster         RunAtLoad=true   cluster + host apps
#   com.homelab.dns-proxy       RunAtLoad=true   DNS forwarder (tolerates no upstream)
#   com.homelab.mac-extras      RunAtLoad=true   macOS metrics (timer, tolerates no Colima)
#   com.homelab.node-exporter   RunAtLoad=false  kicked by start.sh after Colima
#   com.homelab.mdns-reflector  RunAtLoad=false  kicked by start.sh after Colima
set -euo pipefail
cd "$(dirname "$0")"
source ../lib.sh
load_env

DAEMONS_DIR="/Library/LaunchDaemons"

# --- Remove old LaunchAgents (migration from login-time to boot-time) ---------
OLD_AGENTS_DIR="${HOME}/Library/LaunchAgents"
for old in com.homelab.colima.plist com.homelab.k3d.plist; do
  old_target="${OLD_AGENTS_DIR}/${old}"
  if [[ -f "${old_target}" ]]; then
    launchctl unload "${old_target}" 2>/dev/null || true
    rm -f "${old_target}"
    echo "Removed old LaunchAgent ${old}"
  fi
done

# Also remove old separate LaunchDaemons if they were installed previously.
for old in com.homelab.colima.plist com.homelab.k3d.plist; do
  old_target="${DAEMONS_DIR}/${old}"
  if [[ -f "${old_target}" ]]; then
    sudo launchctl bootout system "${old_target}" 2>/dev/null || true
    sudo rm -f "${old_target}"
    echo "Removed old LaunchDaemon ${old}"
  fi
done

# --- Install / refresh all system plists --------------------------------------
for plist in ../launchd-system/*.plist; do
  name="$(basename "${plist}")"
  target="${DAEMONS_DIR}/${name}"

  sudo launchctl bootout system "${target}" 2>/dev/null || true

  sudo cp "${plist}" "${target}"
  sudo chmod 644 "${target}"
  sudo chown root:wheel "${target}"
  sudo launchctl bootstrap system "${target}"
  echo "Loaded ${name}"
done

# Make lifecycle scripts executable.
BOOTSTRAP_DIR="$(cd .. && pwd)"
chmod +x "${BOOTSTRAP_DIR}/start.sh"
chmod +x "${BOOTSTRAP_DIR}/stop.sh"
chmod +x "${BOOTSTRAP_DIR}/restart.sh"
chmod +x "${BOOTSTRAP_DIR}/heal.sh"
chmod +x "${BOOTSTRAP_DIR}/shutdown-hook.sh"
chmod +x "${BOOTSTRAP_DIR}/tools/build-images.sh"

# --- Passwordless sudo for headless boot --------------------------------------
# start.sh runs as homelab-admin via LaunchDaemon and needs sudo for:
#   - launchctl kickstart (node-exporter, mdns-reflector)
#   - Colima's internal vmnet bridge setup
#   - heal.sh dnsmasq masking inside the VM
SUDOERS="/etc/sudoers.d/homelab"
SUDOERS_CONTENT="homelab-admin ALL=(ALL) NOPASSWD: /usr/local/bin/colima, /bin/launchctl, /usr/local/bin/limactl"
if [[ ! -f "${SUDOERS}" ]] || ! grep -qF "homelab-admin" "${SUDOERS}" 2>/dev/null; then
  echo "${SUDOERS_CONTENT}" | sudo tee "${SUDOERS}" >/dev/null
  sudo chmod 440 "${SUDOERS}"
  echo "Installed sudoers rule: ${SUDOERS}"
else
  echo "Sudoers rule already exists: ${SUDOERS}"
fi

echo
echo "All LaunchDaemons installed. Boot sequence:"
echo "  1. com.homelab.cluster (RunAtLoad) → start.sh"
echo "     → Colima → Docker → k3d → heal.sh → kick node-exporter + mdns-reflector → host apps"
echo "  2. com.homelab.dns-proxy (RunAtLoad, KeepAlive)"
echo "  3. com.homelab.mac-extras (RunAtLoad, timer)"
echo "  4. com.homelab.node-exporter (kicked by start.sh)"
echo "  5. com.homelab.mdns-reflector (kicked by start.sh)"
echo
echo "Logs: /tmp/homelab-cluster.{log,err}, /var/log/homelab-*.log"
