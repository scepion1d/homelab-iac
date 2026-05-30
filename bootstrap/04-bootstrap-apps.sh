#!/usr/bin/env zsh
# Apply the root ApplicationSet.
# From this point on, Argo CD owns the cluster state — add a folder under
# /cluster/apps with an `_appset.yaml` and commit; nothing else.
set -euo pipefail
cd "$(dirname "$0")"

kubectl apply -f ../cluster/root-appset.yaml
