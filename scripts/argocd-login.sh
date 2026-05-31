#!/usr/bin/env zsh
# Source this file (don't execute it) to log in to Argo CD using the admin
# password stored in the cluster.
#
#   source ./bootstrap/argocd-login.sh
#
# Or add to ~/.zshrc:
#   source ~/src/homelab-iac/bootstrap/argocd-login.sh
#
# Defines the function `argocd-login`. Run with no args to log in to
# https://argocd.localhost (the ingress). Pass a host to override.
#
#   argocd-login                          # → argocd.localhost
#   argocd-login localhost:8080           # → port-forward
argocd-login() {
  local host="${1:-argocd.localhost}"
  local pwd
  pwd="$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)" || {
    echo "❌ Could not read argocd-initial-admin-secret. Is the cluster up?" >&2
    return 1
  }

  if [[ -z "${pwd}" ]]; then
    echo "❌ Admin password is empty (secret may have been deleted post-bootstrap)." >&2
    return 1
  fi

  argocd login "${host}" \
    --username admin \
    --password "${pwd}" \
    --grpc-web \
    --insecure
}
