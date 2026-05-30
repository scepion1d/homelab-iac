#!/usr/bin/env zsh
# Create the k3d cluster if it does not already exist.
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER_NAME="homelab"

if k3d cluster list --no-headers | awk '{print $1}' | grep -qx "${CLUSTER_NAME}"; then
  echo "Cluster '${CLUSTER_NAME}' already exists, skipping."
else
  k3d cluster create --config ../cluster/k3d-config.yaml
fi

kubectl cluster-info
