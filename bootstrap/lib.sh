#!/usr/bin/env zsh
# Common helpers for bootstrap/*.sh. Source me, don't exec me.
#
#   source "$(dirname "$0")/lib.sh"
#   load_env
#   require_var ADGUARD_PASSWORD

# Load bootstrap/.env into the environment if it exists. Lines starting
# with '#' or blank lines are ignored. Values may be quoted.
load_env() {
  local script_dir env_file
  # ${(%):-%x} is the path of the file currently being sourced (zsh).
  script_dir="$(cd "$(dirname "${(%):-%x}")" && pwd)"
  env_file="${script_dir}/.env"
  if [[ -f "${env_file}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a
  fi
}

# Fail loudly if an env var is unset or empty.
require_var() {
  local name="$1"
  if [[ -z "${(P)name:-}" ]]; then
    echo "ERROR: ${name} is required." >&2
    echo "       Set it in bootstrap/.env (see bootstrap/.env.example)." >&2
    exit 1
  fi
}

# Wait until the named Argo CD applications all reach Synced+Healthy.
# Usage: wait_for_argo_apps <timeout-seconds> app1 [app2 ...]
# Tolerates missing apps for the first ~60s (gives Argo CD time to
# instantiate them from the root ApplicationSet).
wait_for_argo_apps() {
  local timeout="$1"; shift
  local apps=("$@")
  local deadline=$(( $(date +%s) + timeout ))

  echo "==> Waiting up to ${timeout}s for Argo CD apps: ${apps[*]}"
  while (( $(date +%s) < deadline )); do
    local all_ok=1 line app sync health
    for app in "${apps[@]}"; do
      line=$(kubectl -n argocd get application "${app}" \
               -o jsonpath='{.status.sync.status},{.status.health.status}' \
               2>/dev/null || true)
      if [[ -z "${line}" ]]; then
        all_ok=0
        echo "    ${app}: not yet created"
        continue
      fi
      sync="${line%,*}"
      health="${line#*,}"
      if [[ "${sync}" != "Synced" || "${health}" != "Healthy" ]]; then
        all_ok=0
        echo "    ${app}: sync=${sync:-?} health=${health:-?}"
      fi
    done
    if (( all_ok )); then
      echo "    all apps Synced+Healthy"
      return 0
    fi
    sleep 10
  done
  echo "WARNING: timed out waiting for: ${apps[*]}" >&2
  return 1
}
