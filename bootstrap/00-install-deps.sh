#!/usr/bin/env zsh
# Install Homebrew (if missing) and all CLI tooling required to manage the cluster.
set -euo pipefail

if ! command -v brew >/dev/null 2>&1; then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

TOOLS=(
  colima     # Headless container runtime for macOS (replaces Docker Desktop)
  docker     # Docker CLI (talks to the colima-managed engine)
  k3d        # Run k3s Kubernetes clusters inside Docker
  kubectl    # Kubernetes CLI
  helm       # Kubernetes package manager
  kustomize  # Template-free manifest customization
  k9s        # Terminal UI for Kubernetes
  stern      # Multi-pod log tailing
  argocd     # Argo CD CLI (GitOps)
)

brew install "${TOOLS[@]}"
