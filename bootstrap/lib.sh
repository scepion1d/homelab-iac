#!/usr/bin/env zsh
# Common helpers for bootstrap/*.sh. Source me, don't exec me.
#
#   source "$(dirname "$0")/lib.sh"
#   load_env
#   require_var ADGUARD_PASSWORD

# Source .env and set up DOCKER_HOST.
load_env() {
  local script_dir env_file
  script_dir="$(cd "$(dirname "${(%):-%x}")" && pwd)"  # zsh: path of sourced file
  env_file="${script_dir}/.env"
  if [[ -f "${env_file}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a
  fi
  ensure_docker_host
}

# Auto-fix DOCKER_HOST when Colima's docker context wasn't written
# (common after a failed `colima start`). Also detects stale entries
# left in ~/.zshrc after a COLIMA_PROFILE change.
ensure_docker_host() {
  local profile="${COLIMA_PROFILE:-default}"
  local sock="${HOME}/.colima/${profile}/docker.sock"

  if [[ -n "${DOCKER_HOST:-}" ]]; then
    if docker info >/dev/null 2>&1; then
      return 0
    fi
    # Stale DOCKER_HOST — warn once and override.
    if [[ -z "${_HOMELAB_DOCKER_HOST_NOTICED:-}" ]]; then
      echo "Note: DOCKER_HOST=${DOCKER_HOST} doesn't work; overriding."
      echo "      Update your shell rc to match COLIMA_PROFILE=${profile}:"
      echo "        sed -i.bak '/DOCKER_HOST=.*\\/\\.colima\\//d' ~/.zshrc"
      echo "        echo 'export DOCKER_HOST=unix://${sock}' >> ~/.zshrc"
      export _HOMELAB_DOCKER_HOST_NOTICED=1
    fi
    unset DOCKER_HOST
  elif docker info >/dev/null 2>&1; then
    return 0
  fi

  if [[ -S "${sock}" ]]; then
    export DOCKER_HOST="unix://${sock}"
    if [[ -z "${_HOMELAB_DOCKER_HOST_NOTICED:-}" ]]; then
      echo "Note: exporting DOCKER_HOST=${DOCKER_HOST}"
      echo "      Persist: echo 'export DOCKER_HOST=${DOCKER_HOST}' >> ~/.zshrc"
      export _HOMELAB_DOCKER_HOST_NOTICED=1
    fi
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

# --- host-apps helpers (09-host-apps.sh) ---

# Repo root from lib.sh's location.
__repo_root() {
  local lib_dir
  lib_dir="$(cd "$(dirname "${(%):-%x}")" && pwd)"
  cd "${lib_dir}/.." && pwd
}

# Parse host/globals.yaml -> HOST_IP, DATA_ROOT, NETWORK_NAME, LAN_DOMAIN.
load_host_globals() {
  local repo globals raw_host_ip raw_data_root
  repo="$(__repo_root)"
  globals="${repo}/host/globals.yaml"
  if [[ ! -f "${globals}" ]]; then
    echo "ERROR: missing ${globals}" >&2
    return 1
  fi
  if ! command -v yq >/dev/null 2>&1; then
    echo "ERROR: yq required for host-apps layer (brew install yq)." >&2
    return 1
  fi

  raw_host_ip="$(yq -r '.hostIp' "${globals}")"
  raw_data_root="$(yq -r '.dataRoot' "${globals}")"
  export NETWORK_NAME="$(yq -r '.networkName' "${globals}")"
  export LAN_DOMAIN="$(yq -r '.lanDomain' "${globals}")"

  # hostIp: literal wins; 'auto' triggers detection; HOST_IP_OVERRIDE overrides both.
  if [[ -n "${HOST_IP_OVERRIDE:-}" ]]; then
    export HOST_IP="${HOST_IP_OVERRIDE}"
  elif [[ "${raw_host_ip}" == "auto" ]]; then
    export HOST_IP="$(__detect_host_ip)"
  else
    export HOST_IP="${raw_host_ip}"
  fi

  # Tilde-expand dataRoot.
  export DATA_ROOT="${raw_data_root/#\~/${HOME}}"
}

# Detect LAN IP via default route.
__detect_host_ip() {
  local iface ip
  iface="$(route -n get 8.8.8.8 2>/dev/null | awk '/interface:/{print $2; exit}')"
  if [[ -z "${iface}" ]]; then
    echo "ERROR: could not auto-detect host LAN IP (no route to 8.8.8.8). Set HOST_IP_OVERRIDE in .env." >&2
    return 1
  fi
  ip="$(ipconfig getifaddr "${iface}" 2>/dev/null)"
  if [[ -z "${ip}" ]]; then
    echo "ERROR: interface ${iface} has no IPv4 address. Set HOST_IP_OVERRIDE in .env." >&2
    return 1
  fi
  echo "${ip}"
}

# Validate host globals. Call AFTER load_host_globals.
validate_host_globals() {
  local repo cluster_globals cluster_lan_domain
  repo="$(__repo_root)"

  # 1. Required env vars set by load_host_globals.
  for v in HOST_IP DATA_ROOT NETWORK_NAME LAN_DOMAIN; do
    if [[ -z "${(P)v:-}" ]]; then
      echo "ERROR: ${v} not set; load_host_globals must run first." >&2
      return 1
    fi
  done

  # 2. lanDomain consistency (soft warning).
  cluster_globals="${repo}/cluster/globals.yaml"
  if [[ -f "${cluster_globals}" ]]; then
    cluster_lan_domain="$(yq -r '.lanDomain' "${cluster_globals}" 2>/dev/null || echo "")"
    if [[ -n "${cluster_lan_domain}" && "${cluster_lan_domain}" != "${LAN_DOMAIN}" ]]; then
      echo "    WARNING: host/globals.yaml lanDomain (${LAN_DOMAIN}) != cluster/globals.yaml lanDomain (${cluster_lan_domain})" >&2
    fi
  fi

  # 3. Data root parent exists and is writable.
  local parent="$(dirname "${DATA_ROOT}")"
  if [[ ! -d "${parent}" ]]; then
    echo "ERROR: ${parent} (parent of dataRoot) does not exist." >&2
    return 1
  fi
  if [[ ! -w "${parent}" ]]; then
    echo "ERROR: ${parent} not writable by $(whoami)." >&2
    return 1
  fi

  # 4. Docker daemon reachable.
  if ! docker info >/dev/null 2>&1; then
    echo "ERROR: docker daemon not reachable. Run ./01-start-runtime.sh first." >&2
    return 1
  fi

  # 5. Docker network exists or can be created.
  if ! docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
    if ! docker network create "${NETWORK_NAME}" >/dev/null 2>&1; then
      echo "ERROR: failed to create docker network '${NETWORK_NAME}'." >&2
      return 1
    fi
  fi

  return 0
}

# List app folder names under host/apps/ that contain compose.yaml.
list_host_apps() {
  local repo="$(__repo_root)"
  if [[ ! -d "${repo}/host/apps" ]]; then
    return 0
  fi
  for d in "${repo}"/host/apps/*/; do
    [[ -f "${d}/compose.yaml" ]] || continue
    basename "${d}"
  done
}

# Resolve docker-compose CLI (v2 plugin or v1 standalone).
# Cached in __COMPOSE_CMD.
__resolve_compose() {
  if [[ -n "${__COMPOSE_CMD:-}" ]]; then
    return 0
  fi
  if docker compose version >/dev/null 2>&1; then
    __COMPOSE_CMD=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    __COMPOSE_CMD=(docker-compose)
  else
    echo "ERROR: neither 'docker compose' nor 'docker-compose' available." >&2
    echo "       Install with: brew install docker-compose" >&2
    return 1
  fi
}

# docker compose up -d for one app.
# FORCE_RECREATE=1 adds --force-recreate.
compose_up() {
  local app="$1" repo extra=()
  __resolve_compose || return 1
  repo="$(__repo_root)"
  (( ${FORCE_RECREATE:-0} )) && extra+=(--force-recreate)
  APP_NAME="${app}" APP_DATA="${DATA_ROOT}/${app}" \
    "${__COMPOSE_CMD[@]}" \
      -p "homelab-${app}" \
      -f "${repo}/host/apps/${app}/compose.yaml" \
      up -d --remove-orphans "${extra[@]}"
}

compose_down() {
  local app="$1" repo
  __resolve_compose || return 1
  repo="$(__repo_root)"
  APP_NAME="${app}" APP_DATA="${DATA_ROOT}/${app}" \
    "${__COMPOSE_CMD[@]}" \
      -p "homelab-${app}" \
      -f "${repo}/host/apps/${app}/compose.yaml" \
      down
}

# Sync managed config files for one app.
# Sets __SYNC_DID_COPY=1 if any file was overwritten.
sync_managed_config() {
  local app="$1" repo src dst sentinel line
  repo="$(__repo_root)"
  src="${repo}/host/apps/${app}/config"
  dst="${DATA_ROOT}/${app}/config"
  sentinel="${src}/.managed-by-homelab-iac"
  __SYNC_DID_COPY=0

  [[ -d "${src}" ]] || return 0     # no managed config for this app
  if [[ ! -f "${sentinel}" ]]; then
    echo "    WARNING: ${app}: config/ exists but no .managed-by-homelab-iac sentinel; skipping sync." >&2
    return 0
  fi

  mkdir -p "${dst}"
  while IFS= read -r line; do
    # Strip comments and blanks.
    line="${line%%#*}"
    line="${line## }"; line="${line%% }"
    [[ -z "${line}" ]] && continue

    if [[ ! -f "${src}/${line}" ]]; then
      echo "    WARNING: ${app}: sentinel lists '${line}' but file missing in repo." >&2
      continue
    fi
    # Only copy if different (avoids needlessly bumping mtimes).
    if [[ ! -f "${dst}/${line}" ]] || ! cmp -s "${src}/${line}" "${dst}/${line}"; then
      mkdir -p "$(dirname "${dst}/${line}")"
      cp "${src}/${line}" "${dst}/${line}"
      echo "    ${app}: config/${line} copied"
      __SYNC_DID_COPY=1
    fi
  done < "${sentinel}"
}

# Regenerate prometheus host-targets block from host/apps/*/prometheus-target.yaml.
# Returns 0 if unchanged; 1 if file was modified.
regenerate_host_targets() {
  local repo appset combined scrape_yaml tmp before after app target_file
  repo="$(__repo_root)"
  appset="${repo}/cluster/apps/prometheus/_appset.yaml"

  if [[ ! -f "${appset}" ]]; then
    echo "    WARNING: ${appset} missing; skipping host-target regeneration." >&2
    return 0
  fi

  # Build the combined scrape_configs list. Each target file is itself
  # a YAML doc with a top-level `targets:` list; we flatten into one list.
  combined="$(mktemp)"
  : > "${combined}"     # start empty
  for app in $(list_host_apps); do
    target_file="${repo}/host/apps/${app}/prometheus-target.yaml"
    [[ -f "${target_file}" ]] || continue
    # Substitute ${HOST_IP} (compose-style) so the rendered scrape config
    # contains a concrete address Prometheus can dial. Anything else is
    # left intact for future env-var support.
    HOST_IP="${HOST_IP}" envsubst '${HOST_IP}' < "${target_file}" \
      | yq -o yaml '.targets[]' - >> "${combined}"
  done

  # If nothing has metrics, blank out the splice target so Prometheus
  # doesn't try to load an empty file.
  if [[ ! -s "${combined}" ]]; then
    scrape_yaml='[]'
  else
    # Wrap the per-target docs back into a single list. JSON output is
    # picked up natively by `env()` in the splice below (no from_json).
    scrape_yaml="$(yq -o json eval-all '[.]' "${combined}")"
  fi

  tmp="$(mktemp)"
  before="$(sha256sum "${appset}" | awk '{print $1}')"

  # Splice: write the scrape_configs into helm.values.serverFiles."host-targets.yml".
  # Also ensure scrapeConfigFiles contains the path (idempotent set-via-uniq).
  # NOTE: `serverFiles` and `scrapeConfigFiles` are TOP-LEVEL chart keys,
  # NOT nested under `server:`. The prometheus-community chart silently
  # drops them under `server:` — that bug cost us several hours.
  # env(SCRAPE) returns parsed YAML/JSON natively — no from_json needed.
  # `... style=""` recursively resets the subtree to default (block) style
  # so the on-disk file uses readable block YAML, not inlined JSON.
  SCRAPE="${scrape_yaml}" yq -i '
    .source.helm.values.serverFiles."host-targets.yml".scrape_configs = (env(SCRAPE) | ... style="")
    | .source.helm.values.scrapeConfigFiles = (
        ((.source.helm.values.scrapeConfigFiles // []) + ["/etc/config/host-targets.yml"]) | unique
      )
  ' "${appset}"

  after="$(sha256sum "${appset}" | awk '{print $1}')"
  rm -f "${combined}" "${tmp}"

  if [[ "${before}" != "${after}" ]]; then
    return 1     # changed — caller prints commit notice
  fi
  return 0
}
