#!/usr/bin/env zsh
# Source this file (don't execute it) to get a `grafana-login` helper that
# prints the Grafana URL + admin credentials and opens the UI.
#
#   source ./scripts/grafana-login.sh
#
# Or add to ~/.zshrc:
#   source ~/src/homelab-iac/scripts/grafana-login.sh
#
# Defines the function `grafana-login`. Run with no args for the default
# ingress (https://grafana.localhost). Pass a URL to override.
#
#   grafana-login                              # → grafana.localhost
#   grafana-login http://localhost:3000        # → port-forward
grafana-login() {
  local url="${1:-https://grafana.localhost}"
  local namespace="${GRAFANA_NAMESPACE:-monitoring}"
  local pwd

  pwd="$(kubectl -n "${namespace}" get secret grafana \
    -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)" || {
    echo "❌ Could not read 'grafana' secret in namespace '${namespace}'." >&2
    echo "   Is Grafana deployed? Check: kubectl -n ${namespace} get pods" >&2
    return 1
  }

  if [[ -z "${pwd}" ]]; then
    echo "❌ Admin password is empty in the 'grafana' secret." >&2
    return 1
  fi

  echo "URL:      ${url}"
  echo "Username: admin"
  echo "Password: ${pwd}"

  # Copy password to clipboard (macOS) for quick paste.
  if command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "${pwd}" | pbcopy
    echo "          (copied to clipboard)"
  fi

  # Open browser if available.
  command -v open >/dev/null 2>&1 && open "${url}"
}
