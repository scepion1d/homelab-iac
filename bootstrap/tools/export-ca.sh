#!/usr/bin/env zsh
# Export the homelab CA certificate so you can install it on devices
# (Mac, iPhone, Android, etc.) to make browsers trust every *.localhost
# and *.<lanDomain> URL in the cluster.
#
# Usage:
#   ./scripts/export-ca.sh                  # writes homelab-ca.crt in $PWD
#   ./scripts/export-ca.sh /tmp/ca.crt      # writes to the given path
#
# After exporting:
#
#   macOS — install + trust as root:
#     sudo security add-trusted-cert -d -r trustRoot \
#       -k /Library/Keychains/System.keychain homelab-ca.crt
#
#   iOS / iPadOS:
#     1. AirDrop the .crt to the device
#     2. Settings → General → VPN & Device Management → Install the profile
#     3. Settings → General → About → Certificate Trust Settings →
#        toggle ON for "homelab-ca"
#
#   Android (varies by vendor):
#     Settings → Security → Encryption & credentials → Install a certificate
#     → CA certificate → pick the .crt
#
#   Linux (Debian/Ubuntu):
#     sudo cp homelab-ca.crt /usr/local/share/ca-certificates/
#     sudo update-ca-certificates
#
#   Windows:
#     Double-click → Install Certificate → Local Machine →
#     "Trusted Root Certification Authorities"
#
#   Firefox (any OS — uses its own trust store):
#     about:preferences#privacy → View Certificates → Import → tick
#     "Trust this CA to identify websites"
set -euo pipefail

OUT="${1:-homelab-ca.crt}"

kubectl -n cert-manager get secret homelab-ca-key-pair \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > "${OUT}"

echo "==> Wrote ${OUT}"
echo
openssl x509 -in "${OUT}" -noout -subject -issuer -dates
echo
echo "Install instructions: see the comments at the top of this script."
