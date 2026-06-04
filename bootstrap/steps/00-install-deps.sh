#!/usr/bin/env zsh
# Install Homebrew (if missing) and all CLI tooling required to manage the cluster.
set -euo pipefail
cd "$(dirname "$0")"
source ../lib.sh
load_env

if ! command -v brew >/dev/null 2>&1; then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

TOOLS=(
  colima         # Headless container runtime for macOS (replaces Docker Desktop)
  docker         # Docker CLI (talks to the colima-managed engine)
  docker-compose # Compose CLI plugin (Colima's docker doesn't ship it; needed by bootstrap/09-host-apps.sh)
  k3d            # Run k3s Kubernetes clusters inside Docker
  kubectl        # Kubernetes CLI
  helm           # Kubernetes package manager
  kustomize      # Template-free manifest customization
  k9s            # Terminal UI for Kubernetes
  stern          # Multi-pod log tailing
  argocd         # Argo CD CLI (GitOps)
  yq             # YAML processor (used by .github/hooks/pre-commit and 09-host-apps.sh)
  jq             # JSON processor (used by 07-adguard-setup.sh to build API request bodies)
  gettext        # Provides envsubst, used by 09-host-apps.sh for ${HOST_IP} substitution
  node_exporter  # Prometheus host metrics exporter (darwin build) -- step 10
  osx-cpu-temp   # CPU temperature reader (mac-extras.sh textfile collector)
  smartmontools  # smartctl for internal SSD SMART metrics (mac-extras.sh)
)

brew install "${TOOLS[@]}"
