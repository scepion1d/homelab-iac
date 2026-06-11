#!/usr/bin/env zsh
# build-images.sh — build and push all custom container images to the
# local k3d registry (homelab-registry:5111).
#
# Called by start.sh during auto-recovery, or manually:
#   ~/src/homelab-iac/bootstrap/tools/build-images.sh
#
# Each image is defined by a Dockerfile.* in cluster/apps/. The script
# discovers them automatically — add a new Dockerfile and it picks it up.
set -euo pipefail
cd "$(dirname "$0")"
source ../lib.sh
load_env

CLUSTER="homelab"
REPO_ROOT="$(cd ../.. && pwd)"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [build-images] $*"; }

# Discover and build all Dockerfile.* files under cluster/apps/.
count=0
for dockerfile in "${REPO_ROOT}"/cluster/apps/*/Dockerfile.*; do
  [[ -f "${dockerfile}" ]] || continue

  app_dir="$(dirname "${dockerfile}")"
  app="$(basename "${app_dir}")"
  suffix="${dockerfile##*Dockerfile.}"
  image_name="${app}-${suffix}"

  # Read image tag from the deployment.
  tag="$(grep -oE "${image_name}:[^ \"']+" "${app_dir}/deployment.yaml" 2>/dev/null | head -1 | cut -d: -f2 || true)"
  if [[ -z "${tag}" ]]; then
    tag="latest"
  fi

  local_image="homelab-${image_name}:${tag}"
  log "Building ${local_image} from ${dockerfile}"
  docker build -t "${local_image}" -f "${dockerfile}" "${app_dir}"
  k3d image import "${local_image}" -c "${CLUSTER}"
  log "Imported ${local_image} into k3d"
    docker build -t "${local_image}" -f "${dockerfile}" "${app_dir}"
    k3d image import "${local_image}" -c "${CLUSTER}"
    log "Imported ${local_image} into k3d"
  fi

  count=$((count + 1))
done

log "Done. Built ${count} image(s) (registry=${USE_REGISTRY})."
