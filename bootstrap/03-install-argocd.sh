#!/usr/bin/env zsh
# Install Argo CD into the cluster using upstream stable manifests.
set -euo pipefail

NAMESPACE="argocd"

kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"

# Server-side apply is required: the ApplicationSet CRD exceeds the 256 KiB
# annotation limit that client-side `kubectl apply` imposes via
# `last-applied-configuration`.
kubectl apply -n "${NAMESPACE}" --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl -n "${NAMESPACE}" rollout status deploy/argocd-server --timeout=300s
