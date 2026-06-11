#!/usr/bin/env zsh
# Create the k3d cluster if it does not already exist, then patch each node's
# /etc/resolv.conf so kubelet can pull images.
#
# Why the resolv.conf patch is here (not in 06):
# 01-start-runtime.sh disables the Colima VM's dnsmasq so :53 is free for
# k3d. But k3d nodes inherit DNS from Docker's internal resolver, which was
# forwarding to that dnsmasq. With it gone, image pulls fail. Step 03
# (Argo CD install) starts pulling images immediately, so the fix has to
# land before 03 runs.
set -euo pipefail
cd "$(dirname "$0")"
source ../lib.sh
load_env
CLUSTER_NAME="homelab"
REPO_ROOT="$(cd ../.. && pwd)"
K3D_CONFIG="${REPO_ROOT}/cluster/k3d-config.yaml"

if k3d cluster list --no-headers | awk '{print $1}' | grep -qx "${CLUSTER_NAME}"; then
  # Cluster exists — check if nodes are actually running.
  RUNNING_NODES=$(docker ps --format '{{.Names}}' | grep -cE "^k3d-${CLUSTER_NAME}-(server|agent)" || true)
  if [[ "${RUNNING_NODES}" -gt 0 ]]; then
    echo "Cluster '${CLUSTER_NAME}' already exists with ${RUNNING_NODES} running nodes, skipping create."
  else
    echo "Cluster '${CLUSTER_NAME}' exists but has no running nodes — deleting and recreating."
    k3d cluster delete "${CLUSTER_NAME}" 2>&1 || true
    colima ssh --profile "${COLIMA_PROFILE:-default}" -- sudo mkdir -p /var/lib/homelab-pvcs 2>/dev/null || true
    k3d cluster create --config "${K3D_CONFIG}"
  fi
else
  # Pre-create PVC storage directory on the VM to suppress k3d warnings.
  colima ssh --profile "${COLIMA_PROFILE:-default}" -- sudo mkdir -p /var/lib/homelab-pvcs 2>/dev/null || true
  k3d cluster create --config "${K3D_CONFIG}"
fi

echo "==> Patching /etc/resolv.conf on k3d nodes (public upstream DNS)"
NODES=$(docker ps --format '{{.Names}}' | grep -E '^k3d-homelab-(server|agent)' || true)
if [[ -z "${NODES}" ]]; then
  echo "    no k3d-homelab-* nodes running, skipping"
else
  for n in ${(f)NODES}; do
    docker exec "${n}" sh -c 'printf "nameserver 1.1.1.1\nnameserver 9.9.9.9\noptions ndots:0\n" > /etc/resolv.conf'
    echo "    ${n} patched"
  done
  if kubectl -n kube-system get deploy coredns >/dev/null 2>&1; then
    kubectl -n kube-system rollout restart deploy/coredns >/dev/null
    echo "    coredns restarted"
  fi
fi

kubectl cluster-info
