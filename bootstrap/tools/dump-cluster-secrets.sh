#!/usr/bin/env zsh
# Dump cluster-side secrets back into bootstrap/.env so a `colima delete`
# (or any other VM/cluster wipe) is a non-event for credentials.
#
# This script is the inverse of bootstrap/06-cluster-secrets.sh:
#   06 reads .env -> creates secrets in the cluster
#   this script reads secrets from the cluster -> writes them back to .env
#
# Run periodically -- definitely before any teardown / colima delete /
# bootstrap re-run -- so the next bootstrap recreates exactly the same
# secrets (Grafana password, HA token, etc.) and you don't have to dig
# through a 3-month-old terminal scrollback for the generated values.
#
# What it captures
# ----------------
#   ADGUARD_USER / ADGUARD_PASSWORD          dns/adguard-credentials
#   GRAFANA_ADMIN_PASSWORD                   monitoring/grafana-admin
#   GRAFANA_SLACK_BOT_TOKEN                  monitoring/grafana-slack
#   HOMEASSISTANT_PROMETHEUS_TOKEN           monitoring/home-assistant-prometheus-token
#   MIKROTIK_USER / MIKROTIK_PASSWORD        monitoring/mikrotik-exporter-credentials
#   SLACK_TOKEN                              argocd/argocd-notifications-secret  (key slack-token)
#   ARGOCD_GIT_USER / ARGOCD_GIT_PAT         argocd/<repo-secret>  (selected by
#                                            label argocd.argoproj.io/secret-type=repository
#                                            and the repoUrl matching cluster/globals.yaml)
#
# What it deliberately doesn't capture
# ------------------------------------
#   argocd-initial-admin-secret  --  regenerated on every fresh argo-cd
#                                    install, so caching it would be
#                                    misleading.  bootstrap.sh prints it
#                                    at the end of each run.
#
# Idempotent:
#   - Each KEY in .env is either updated in place or appended at the
#     bottom.  Comments, ordering of OTHER keys, and unrelated lines are
#     preserved.
#   - Values are written with single-quote wrapping (and embedded ' is
#     escaped) so any special character survives shell sourcing intact.
#   - Skips a key cleanly if the corresponding secret doesn't exist
#     (e.g. you never set up the optional MikroTik exporter).
#
# Safety:
#   - Backs the existing .env up to .env.bak.<unix-ts> before writing.
#   - Does NOT echo secret values to stdout.  Lists only KEY names that
#     were captured / unchanged / skipped.
set -euo pipefail
cd "$(dirname "$0")"
source ../lib.sh
load_env

ENV_FILE="../.env"
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: bootstrap/.env does not exist. Copy bootstrap/.env.example first." >&2
  exit 1
fi

# Sanity: cluster reachable?
if ! kubectl version --request-timeout=5s >/dev/null 2>&1; then
  echo "ERROR: kubectl can't reach the cluster. Is it running?" >&2
  exit 1
fi

# --- read a value out of the cluster ----------------------------------------
# get_secret_key <namespace> <secret> <key>  -- prints decoded value or ""
get_secret_key() {
  local ns="$1" secret="$2" key="$3" b64
  b64="$(kubectl -n "${ns}" get secret "${secret}" \
           -o jsonpath="{.data.${key}}" 2>/dev/null || true)"
  if [[ -z "${b64}" ]]; then
    echo ""
    return
  fi
  printf '%s' "${b64}" | base64 -d 2>/dev/null || true
}

# Pull every secret value into local vars up front.  An empty value means
# "secret/key not present in cluster" -- we skip that env key entirely.
ADGUARD_USER_LIVE="$(get_secret_key dns adguard-credentials username)"
ADGUARD_PASSWORD_LIVE="$(get_secret_key dns adguard-credentials password)"
GRAFANA_ADMIN_PASSWORD_LIVE="$(get_secret_key monitoring grafana-admin admin-password)"
GRAFANA_SLACK_BOT_TOKEN_LIVE="$(get_secret_key monitoring grafana-slack token)"
HOMEASSISTANT_PROMETHEUS_TOKEN_LIVE="$(get_secret_key monitoring home-assistant-prometheus-token token)"
SLACK_TOKEN_LIVE="$(get_secret_key argocd argocd-notifications-secret slack-token)"

# MikroTik creds live inside a YAML blob keyed credentials.yaml. Parse out
# `username:` and `password:` lines (single space after colon per 06's
# heredoc; tolerate extra spaces just in case).
MIKROTIK_CREDS_YAML="$(get_secret_key monitoring mikrotik-exporter-credentials 'credentials\.yaml')"
MIKROTIK_USER_LIVE=""
MIKROTIK_PASSWORD_LIVE=""
if [[ -n "${MIKROTIK_CREDS_YAML}" ]]; then
  MIKROTIK_USER_LIVE="$(printf '%s\n' "${MIKROTIK_CREDS_YAML}" \
    | awk -F': *' '/^username:/ {print $2; exit}')"
  MIKROTIK_PASSWORD_LIVE="$(printf '%s\n' "${MIKROTIK_CREDS_YAML}" \
    | awk -F': *' '/^password:/ {print $2; exit}')"
fi

# Argo CD git repo PAT lives in a Secret labelled
# argocd.argoproj.io/secret-type=repository. Multiple repos can be
# registered; we pick the one whose `url` matches cluster/globals.yaml's
# repoUrl (the same source 04-bootstrap-apps.sh registers).
ARGOCD_GIT_USER_LIVE=""
ARGOCD_GIT_PAT_LIVE=""
REPO_URL="$(yq -r '.repoUrl' "$(dirname "$0")/../../cluster/globals.yaml" 2>/dev/null || true)"
if [[ -n "${REPO_URL}" && "${REPO_URL}" != "null" ]]; then
  # List candidate secret names; find the one whose decoded `url` matches.
  while IFS= read -r repo_secret; do
    [[ -z "${repo_secret}" ]] && continue
    secret_url="$(get_secret_key argocd "${repo_secret}" url)"
    if [[ "${secret_url}" == "${REPO_URL}" ]]; then
      ARGOCD_GIT_USER_LIVE="$(get_secret_key argocd "${repo_secret}" username)"
      ARGOCD_GIT_PAT_LIVE="$(get_secret_key argocd "${repo_secret}" password)"
      break
    fi
  done < <(kubectl -n argocd get secret \
             -l 'argocd.argoproj.io/secret-type=repository' \
             -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
fi

# --- in-place .env updater ---------------------------------------------------
# upsert_env <KEY> <VALUE>
#   - skips silently if value is empty
#   - if KEY=... already present, replaces the line
#   - else appends KEY='value' at the bottom
#
# Single-quote wrapping with ' escape handles secrets containing $, `,
# backslashes, double quotes, spaces, etc.  Reading these back via
# `source .env` (the way lib.sh::load_env does it) restores them
# byte-identical.
upsert_env() {
  local key="$1" value="$2"
  if [[ -z "${value}" ]]; then
    echo "    ${key}: skipped (no cluster secret)"
    return
  fi

  # Escape single quotes for shell-safe quoting: ' -> '\''
  local escaped="${value//\'/\'\\\'\'}"
  local new_line="${key}='${escaped}'"

  # Already present with the same effective value?  Note this matches both
  # quoted and unquoted existing forms.  Use grep to detect presence; awk
  # to confirm decoded value match (rough -- treat existing line as
  # source-able and compare).
  if grep -qE "^[[:space:]]*${key}=" "${ENV_FILE}"; then
    # Pull the existing value (everything after the first =), strip wrapping
    # quotes if simple, compare.  If different -> rewrite the line.
    local existing
    existing="$(awk -F= -v k="${key}" '
      $0 ~ "^[[:space:]]*"k"=" {
        sub("^[[:space:]]*"k"=", "")
        # Strip a single matched pair of leading/trailing quotes if present.
        if ((substr($0,1,1)=="\"" && substr($0,length($0),1)=="\"") \
            || (substr($0,1,1)=="\x27" && substr($0,length($0),1)=="\x27")) {
          $0 = substr($0,2,length($0)-2)
        }
        print
        exit
      }' "${ENV_FILE}")"

    if [[ "${existing}" == "${value}" ]]; then
      echo "    ${key}: unchanged"
      return
    fi

    # sed replace.  Use a delimiter unlikely to appear in either side --
    # ASCII record-separator (\x1e) -- so we don't have to escape `/`,
    # `&`, etc. in the value.  GNU/BSD sed both support custom delimiters.
    local tmp
    tmp="$(mktemp)"
    awk -v k="${key}" -v repl="${new_line}" '
      $0 ~ "^[[:space:]]*"k"=" && !done {
        print repl
        done = 1
        next
      }
      { print }
    ' "${ENV_FILE}" > "${tmp}"
    mv "${tmp}" "${ENV_FILE}"
    echo "    ${key}: updated"
  else
    # Append.  Ensure there's a trailing newline before the new line so
    # we don't accidentally append to a partial line.
    if [[ -s "${ENV_FILE}" ]] \
       && [[ "$(tail -c1 "${ENV_FILE}")" != $'\n' ]]; then
      printf '\n' >> "${ENV_FILE}"
    fi
    printf '%s\n' "${new_line}" >> "${ENV_FILE}"
    echo "    ${key}: appended"
  fi
}

# --- back up and write ------------------------------------------------------
BACKUP="${ENV_FILE}.bak.$(date +%s)"
cp "${ENV_FILE}" "${BACKUP}"
echo "==> Backed up ${ENV_FILE} -> ${BACKUP}"
echo "==> Syncing secrets into ${ENV_FILE}"

upsert_env ADGUARD_USER                  "${ADGUARD_USER_LIVE}"
upsert_env ADGUARD_PASSWORD              "${ADGUARD_PASSWORD_LIVE}"
upsert_env GRAFANA_ADMIN_PASSWORD        "${GRAFANA_ADMIN_PASSWORD_LIVE}"
upsert_env GRAFANA_SLACK_BOT_TOKEN       "${GRAFANA_SLACK_BOT_TOKEN_LIVE}"
upsert_env HOMEASSISTANT_PROMETHEUS_TOKEN "${HOMEASSISTANT_PROMETHEUS_TOKEN_LIVE}"
upsert_env MIKROTIK_USER                 "${MIKROTIK_USER_LIVE}"
upsert_env MIKROTIK_PASSWORD             "${MIKROTIK_PASSWORD_LIVE}"
upsert_env SLACK_TOKEN                   "${SLACK_TOKEN_LIVE}"
upsert_env ARGOCD_GIT_USER               "${ARGOCD_GIT_USER_LIVE}"
upsert_env ARGOCD_GIT_PAT                "${ARGOCD_GIT_PAT_LIVE}"

# The CA Secret is too large (cert + private key, multi-KB) to inline
# into .env sanely, so it gets its own file via dump-ca-secret.sh.
# Same backup-before-destruction guarantee: a teardown + bootstrap that
# follows this dump will restore the same CA via restore-ca-secret.sh.
# Tolerated to fail (cluster might not have cert-manager up yet).
echo
echo "==> Snapshotting cert-manager CA Secret"
./dump-ca-secret.sh || \
  echo "    WARNING: CA snapshot failed; .ca-secret.yaml may be stale" >&2

cat <<EOF

Done. ${ENV_FILE} now holds every recoverable cluster secret.
Safe to run anytime; safe to run before a teardown.

If a key shows "skipped (no cluster secret)" you probably never set up
that optional integration -- nothing to worry about.

Next teardown + bootstrap will reuse these values exactly, so:
  - Grafana admin password stays the same
  - Home Assistant prometheus token stays valid
  - MikroTik exporter keeps scraping without manual re-credentialing
  - AdGuard wizard re-runs against the same admin user/password
EOF
