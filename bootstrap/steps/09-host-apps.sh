#!/usr/bin/env zsh
# Reconcile the host-side apps under host/apps/* against the running
# Docker engine. See host/README.md for the full design.
#
# Idempotent: safe to re-run any time. Default action is to reconcile
# every app folder it finds. Pass a single app name to act on just that one.
#
# Usage:
#   ./09-host-apps.sh                       # reconcile all apps
#   ./09-host-apps.sh <name>                # reconcile one app only
#   ./09-host-apps.sh --diff                # show what would change, no action
#   ./09-host-apps.sh --prune               # also stop+remove containers whose
#                                           # app folders no longer exist
#   ./09-host-apps.sh --recopy-config       # re-copy managed config from repo
#                                           # to host data dir (overwrites only
#                                           # files listed in the sentinel)
#
# Exits 0 on full success, 1 if any app failed, 2 on usage error.
set -euo pipefail
cd "$(dirname "$0")"
source ../lib.sh
load_env

ONLY_APP=""
DIFF_ONLY=0
PRUNE=0
RECOPY_CONFIG=0

for arg in "$@"; do
  case "${arg}" in
    --diff)            DIFF_ONLY=1 ;;
    --prune)           PRUNE=1 ;;
    --recopy-config)   RECOPY_CONFIG=1 ;;
    --help|-h)
      sed -n '2,18p' "$0"
      exit 0
      ;;
    -*)
      echo "Unknown flag: ${arg}" >&2
      exit 2
      ;;
    *)
      if [[ -n "${ONLY_APP}" ]]; then
        echo "Only one app name accepted (got '${ONLY_APP}' and '${arg}')." >&2
        exit 2
      fi
      ONLY_APP="${arg}"
      ;;
  esac
done

load_host_globals
if ! validate_host_globals; then
  exit 2
fi

echo "==> Reconciling host apps  (dataRoot=${DATA_ROOT}, hostIp=${HOST_IP}, network=${NETWORK_NAME})"

apps=()
if [[ -n "${ONLY_APP}" ]]; then
  if [[ ! -f "host/apps/${ONLY_APP}/compose.yaml" ]] && [[ ! -f "../host/apps/${ONLY_APP}/compose.yaml" ]]; then
    echo "ERROR: no compose.yaml at host/apps/${ONLY_APP}/" >&2
    exit 2
  fi
  apps=("${ONLY_APP}")
else
  while IFS= read -r line; do
    [[ -n "${line}" ]] && apps+=("${line}")
  done < <(list_host_apps)
fi

if (( ${#apps[@]} == 0 )); then
  echo "    no host apps to reconcile (host/apps/ is empty)."
fi

failed=()
for app in "${apps[@]}"; do
  echo "  ${app}:"
  if (( DIFF_ONLY )); then
    echo "    [--diff] would: ensure data dir, sync managed config, compose up -d"
    continue
  fi

  # 1. Data directory.
  app_data="${DATA_ROOT}/${app}"
  if [[ ! -d "${app_data}" ]]; then
    mkdir -p "${app_data}"
    echo "    data dir:        ${app_data} (created)"
  else
    echo "    data dir:        ${app_data}"
  fi

  # 2. Managed config sync. Only files in .managed-by-homelab-iac are
  #    copied; anything UI-edited is preserved. --recopy-config forces a
  #    re-copy even when content matches (paranoia mode; useful after
  #    debugging a "did the file actually update?" situation).
  if (( RECOPY_CONFIG )); then
    sentinel="$(__repo_root)/host/apps/${app}/config/.managed-by-homelab-iac"
    if [[ -f "${sentinel}" ]]; then
      while IFS= read -r line; do
        line="${line%%#*}"; line="${line## }"; line="${line%% }"
        [[ -z "${line}" ]] && continue
        rm -f "${DATA_ROOT}/${app}/config/${line}"
      done < "${sentinel}"
    fi
  fi
  sync_managed_config "${app}" || true

  # 3. docker compose up. Continue-on-error per app so one broken compose
  #    file doesn't tank the rest of the reconcile.
  #
  # Auto-force-recreate when EITHER a managed config file was just rewritten
  # OR the compose.yaml itself changed on disk after the running container
  # was created. Without this, docker-compose's default change detection
  # misses healthcheck/restart-policy/env-var-only edits and the user has
  # to manually `docker rm` the container to pick them up.
  FORCE_RECREATE=0
  if (( ${__SYNC_DID_COPY:-0} )); then
    FORCE_RECREATE=1
  fi
  compose_path="$(__repo_root)/host/apps/${app}/compose.yaml"
  if [[ -f "${compose_path}" ]]; then
    cont_started_iso="$(docker inspect "homelab-${app}" --format '{{.State.StartedAt}}' 2>/dev/null || true)"
    if [[ -n "${cont_started_iso}" ]]; then
      # Convert both to epoch seconds for a simple > comparison.
      # macOS `date -j` parser tolerates the ISO with fractional seconds
      # stripped (`${var%.*}` chops the .NNN...Z tail).
      cont_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%S" "${cont_started_iso%.*}" "+%s" 2>/dev/null || echo 0)"
      compose_epoch="$(stat -f "%m" "${compose_path}" 2>/dev/null || echo 0)"
      if (( compose_epoch > cont_epoch )); then
        FORCE_RECREATE=1
      fi
    fi
  fi
  export FORCE_RECREATE

  if compose_up "${app}"; then
    if (( FORCE_RECREATE )); then
      echo "    docker compose:  up -d --force-recreate"
    else
      echo "    docker compose:  up -d"
    fi
  else
    echo "    docker compose:  FAILED" >&2
    failed+=("${app}")
    continue
  fi
done

# 4. Prune mode: stop containers whose source folder no longer exists.
if (( PRUNE )) && [[ -z "${ONLY_APP}" ]]; then
  echo "==> Prune: removing containers for apps no longer in host/apps/"
  while IFS= read -r line; do
    proj="${line#homelab-}"
    [[ -z "${proj}" || "${proj}" == "${line}" ]] && continue
    # If the matching app folder still exists, keep it.
    if [[ -d "../host/apps/${proj}" || -d "host/apps/${proj}" ]]; then
      continue
    fi
    echo "  ${proj}: stopping (app folder removed)"
    docker rm -f "homelab-${proj}" >/dev/null 2>&1 || true
  done < <(docker ps -a --filter "name=^homelab-" --format '{{.Names}}')
fi

# 5. Regenerate the cluster-side prometheus scrape file. Only when we
#    actually walked the full app list (skip for single-app runs to keep
#    the file deterministic).
if [[ -z "${ONLY_APP}" ]] && (( DIFF_ONLY == 0 )); then
  echo "==> Regenerating cluster/apps/prometheus/_appset.yaml host-targets block"
  if regenerate_host_targets; then
    echo "    unchanged."
  else
    echo "    !! file changed — commit + push for Argo CD to pick up."
  fi
fi

echo
if (( ${#failed[@]} )); then
  echo "==> Done with errors. Failed apps: ${failed[*]}" >&2
  exit 1
fi
echo "==> Done."
