#!/usr/bin/env zsh
# Apply the root "app-of-apps" Application.
# From this point on, Argo CD owns the cluster state — edit /apps in git, not kubectl.
set -euo pipefail
cd "$(dirname "$0")"

kubectl apply -f ../cluster/root-app.yaml
