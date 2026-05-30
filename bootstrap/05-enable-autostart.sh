#!/usr/bin/env zsh
# Install LaunchAgents so Colima + k3d start automatically on user login.
# Re-running re-installs (unload, copy, load) — safe and idempotent.
set -euo pipefail
cd "$(dirname "$0")"

AGENTS_DIR="${HOME}/Library/LaunchAgents"
mkdir -p "${AGENTS_DIR}"

for plist in launchd/*.plist; do
  name="$(basename "${plist}")"
  target="${AGENTS_DIR}/${name}"

  # Unload first if already installed (ignore errors on first install).
  launchctl unload "${target}" 2>/dev/null || true

  cp "${plist}" "${target}"
  launchctl load "${target}"
  echo "Loaded ${name}"
done

echo "Auto-start enabled. Logs: /tmp/homelab-*.log"
