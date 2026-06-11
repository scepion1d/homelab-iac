#!/usr/bin/env zsh
# Drive the AdGuard Home first-run wizard via its HTTP API so we don't
# need a human to click through localhost:3000. Idempotent: if AdGuard
# is already configured, the install endpoint refuses the request and we
# treat that as success.
#
# Requires ADGUARD_USER and ADGUARD_PASSWORD in bootstrap/.env.
#
# Flow:
#   1. Wait for the adguard Deployment to exist (Argo CD sync).
#   2. Wait for any adguard pod to be at least Running (the wizard is
#      reachable on :3000 even while the :53 liveness probe keeps
#      restarting the container).
#   3. Open a kubectl port-forward to svc/adguard-ui:3000.
#   4. POST /control/install/configure with the desired bind addresses
#      and credentials.
#   5. Wait for the pod to come up Ready (now that :53 binds).
set -euo pipefail
cd "$(dirname "$0")"
source ../lib.sh
load_env
require_var ADGUARD_USER
require_var ADGUARD_PASSWORD

NS="dns"
DEPLOY="adguard"
SVC="adguard-ui"
LOCAL_PORT=33000
CONFIGS_PATH="/cluster/apps/adguard/configs"

echo "==> Waiting for the adguard Deployment to appear (Argo CD sync)"
for _ in $(seq 1 180); do
  if kubectl -n "${NS}" get deploy "${DEPLOY}" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
kubectl -n "${NS}" get deploy "${DEPLOY}" >/dev/null

echo "==> Waiting for an adguard pod to be Running"
# Don't wait on Ready -- before the wizard runs, the :53 liveness probe
# fails forever and the pod ping-pongs Running -> CrashLoopBackOff. The
# wizard UI on :3000 is reachable during the Running phases.
for _ in $(seq 1 180); do
  phase="$(kubectl -n "${NS}" get pod -l app.kubernetes.io/name=adguard \
            -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
  [[ "${phase}" == "Running" ]] && break
  sleep 2
done
if [[ "${phase:-}" != "Running" ]]; then
  echo "ERROR: no adguard pod reached Running phase." >&2
  kubectl -n "${NS}" get pods -l app.kubernetes.io/name=adguard
  exit 1
fi

echo "==> Port-forwarding svc/${SVC}:3000 -> 127.0.0.1:${LOCAL_PORT}"
PF_LOG="$(mktemp)"
kubectl -n "${NS}" port-forward "svc/${SVC}" "${LOCAL_PORT}:3000" \
  >"${PF_LOG}" 2>&1 &
PF_PID=$!
cleanup() { kill "${PF_PID}" 2>/dev/null || true; rm -f "${PF_LOG}"; }
trap cleanup EXIT

# Wait for the local listener.
for _ in $(seq 1 30); do
  if curl -fsS -o /dev/null --max-time 1 "http://127.0.0.1:${LOCAL_PORT}/" 2>/dev/null \
     || curl -sS -o /dev/null --max-time 1 "http://127.0.0.1:${LOCAL_PORT}/" 2>/dev/null; then
    break
  fi
  sleep 1
done

echo "==> Submitting wizard configuration"
RESP_BODY="$(mktemp)"
trap 'cleanup; rm -f "${RESP_BODY}"' EXIT

HTTP=$(curl -sS -o "${RESP_BODY}" -w '%{http_code}' \
  -X POST "http://127.0.0.1:${LOCAL_PORT}/control/install/configure" \
  -H 'Content-Type: application/json' \
  -d "{
    \"web\":      {\"ip\": \"0.0.0.0\", \"port\": 80, \"autofix\": false},
    \"dns\":      {\"ip\": \"0.0.0.0\", \"port\": 53, \"autofix\": false},
    \"username\": \"${ADGUARD_USER}\",
    \"password\": \"${ADGUARD_PASSWORD}\"
  }" || true)

case "${HTTP}" in
  200|201|204)
    echo "    wizard accepted (HTTP ${HTTP})"
    WIZARD_RAN=1
    ;;
  *)
    # After the wizard runs, AdGuard stops serving on :3000 and moves to
    # :80. Re-running this step against an already-configured AdGuard
    # therefore looks like:
    #   - HTTP 403/404      install endpoints exist but refuse new config
    #   - HTTP 000          curl couldn't connect at all (the most common
    #                       re-run case -- :3000 just isn't bound anymore)
    # All three are "already configured, proceed to the next phase".
    if [[ "${HTTP}" == "000" || "${HTTP}" == "403" || "${HTTP}" == "404" ]] \
       || grep -qiE 'already.*configured|forbidden' "${RESP_BODY}" 2>/dev/null; then
      echo "    AdGuard appears already configured (HTTP ${HTTP}); skipping wizard."
      WIZARD_RAN=0
    else
      echo "ERROR: wizard returned HTTP ${HTTP}:" >&2
      cat "${RESP_BODY}" >&2 || true
      exit 1
    fi
    ;;
esac

# Only restart the deployment if we actually wrote new wizard config.
# On a re-run (WIZARD_RAN=0) the rollout restart is pointless churn --
# AdGuard is already healthy with :53 bound, and a restart would drop
# in-flight DNS queries from every LAN client for ~5s.
if (( WIZARD_RAN )); then
  echo "==> Waiting for adguard rollout (now that :53 is bound)"
  kubectl -n "${NS}" rollout restart deploy/"${DEPLOY}" >/dev/null
  kubectl -n "${NS}" rollout status deploy/"${DEPLOY}" --timeout=300s
fi

# Tear down the :3000 port-forward before opening :80 -- two forwards
# on the same svc can confuse kubectl's selectors and we don't need
# :3000 again.
kill "${PF_PID}" 2>/dev/null || true

# --- POST DNS config (upstreams + bootstrap) --------------------------------
# Codifies what the README used to ask the operator to set in the UI:
# upstream rule for [/int/]192.168.10.1 (so *.int resolves via MikroTik
# static records), DoH upstreams for public queries, bootstrap IPs.
# Source of truth is dns.yaml -- edit and
# re-run this script to change behaviour without UI clicks.
#
# Why we re-port-forward: AdGuard's API moved from :3000 (install wizard)
# to :80 once the wizard wrote a config. We open a fresh tunnel against
# the new port. The post-wizard endpoints require basic auth (admin
# user + password from .env), so we send that explicitly.
DNS_CFG_YAML="$(cd ../.. && pwd)${CONFIGS_PATH}/dns.yaml"
if [[ ! -f "${DNS_CFG_YAML}" ]]; then
  echo "==> No ${CONFIGS_PATH}/dns.yaml; skipping DNS config push."
else
  echo "==> Pushing DNS config from ${DNS_CFG_YAML##*/}"
  # Convert YAML -> JSON for the API.
  DNS_CFG_JSON="$(yq -o=json '.' "${DNS_CFG_YAML}")"

  # Wait for the post-wizard :80 to actually answer.
  LOCAL_API=33080
  kubectl -n "${NS}" port-forward "svc/${SVC}" "${LOCAL_API}:80" \
    >/dev/null 2>&1 &
  PF_API_PID=$!
  trap 'kill "${PF_PID}" "${PF_API_PID}" 2>/dev/null || true; rm -f "${PF_LOG}" "${RESP_BODY}"' EXIT

  for _ in $(seq 1 30); do
    if curl -fsS -o /dev/null --max-time 1 -u "${ADGUARD_USER}:${ADGUARD_PASSWORD}" \
         "http://127.0.0.1:${LOCAL_API}/control/status" 2>/dev/null; then
      break
    fi
    sleep 1
  done

  HTTP=$(curl -sS -o "${RESP_BODY}" -w '%{http_code}' \
    -X POST "http://127.0.0.1:${LOCAL_API}/control/dns_config" \
    -u "${ADGUARD_USER}:${ADGUARD_PASSWORD}" \
    -H 'Content-Type: application/json' \
    -d "${DNS_CFG_JSON}" || true)

  case "${HTTP}" in
    200|204)
      echo "    DNS config applied (HTTP ${HTTP})"
      ;;
    *)
      echo "WARNING: /control/dns_config returned HTTP ${HTTP}:" >&2
      cat "${RESP_BODY}" >&2 || true
      echo "         You can still set upstreams manually in the UI." >&2
      ;;
  esac
fi

# --- POST blocklists --------------------------------------------------------
# Push each filter in blocklists.yaml via the
# /control/filtering/add_url endpoint. Already-present URLs return 409
# Conflict (or a 4xx with "filter already exists" body, depending on
# AdGuard version) -- treated as success so re-runs are idempotent.
#
# Uses the same port-forward as the DNS config push above (still live
# at this point; trap-cleanup runs at script exit).
BLOCKLISTS_YAML="$(cd ../.. && pwd)${CONFIGS_PATH}/blocklists.yaml"
if [[ -z "${LOCAL_API:-}" ]]; then
  echo "==> Skipping blocklists push (no API port-forward open -- DNS config push was skipped earlier)."
elif [[ ! -f "${BLOCKLISTS_YAML}" ]]; then
  echo "==> No ${CONFIGS_PATH}/blocklists.yaml; skipping blocklists push."
else
  echo "==> Pushing blocklists from ${BLOCKLISTS_YAML##*/}"
  filter_count=$(yq '.filters | length' "${BLOCKLISTS_YAML}")
  added=0; skipped=0; failed=0
  for i in $(seq 0 $((filter_count - 1))); do
    name="$(yq -r ".filters[${i}].name" "${BLOCKLISTS_YAML}")"
    url="$(yq -r ".filters[${i}].url"  "${BLOCKLISTS_YAML}")"
    [[ -z "${name}" || -z "${url}" || "${name}" == "null" || "${url}" == "null" ]] && continue

    HTTP=$(curl -sS -o "${RESP_BODY}" -w '%{http_code}' \
      -X POST "http://127.0.0.1:${LOCAL_API}/control/filtering/add_url" \
      -u "${ADGUARD_USER}:${ADGUARD_PASSWORD}" \
      -H 'Content-Type: application/json' \
      -d "$(jq -nc --arg n "${name}" --arg u "${url}" '{name:$n,url:$u,whitelist:false}')" \
      2>/dev/null || true)

    case "${HTTP}" in
      200|201|204)
        echo "    + ${name}"
        added=$((added + 1))
        ;;
      400|409)
        # Already present (409 Conflict, or 400 with "filter already exists" body).
        if grep -qiE 'already exists|exists already' "${RESP_BODY}" 2>/dev/null; then
          echo "    = ${name} (already present)"
          skipped=$((skipped + 1))
        else
          echo "    ! ${name}: HTTP ${HTTP}: $(cat "${RESP_BODY}" 2>/dev/null | head -c 200)" >&2
          failed=$((failed + 1))
        fi
        ;;
      *)
        echo "    ! ${name}: HTTP ${HTTP}: $(cat "${RESP_BODY}" 2>/dev/null | head -c 200)" >&2
        failed=$((failed + 1))
        ;;
    esac
  done
  echo "    blocklists: ${added} added, ${skipped} already present, ${failed} failed"

  # Trigger AdGuard to actually download the new filters' rules so
  # they're enforced immediately (without this they'd update on the
  # next scheduled refresh -- typically hours).
  if (( added > 0 )); then
    curl -sS -o /dev/null \
      -X POST "http://127.0.0.1:${LOCAL_API}/control/filtering/refresh" \
      -u "${ADGUARD_USER}:${ADGUARD_PASSWORD}" \
      -H 'Content-Type: application/json' \
      -d '{"whitelist":false}' || true
    echo "    triggered filtering/refresh"
  fi
fi

echo
echo "AdGuard is configured. UI: https://adguard.int  (user: ${ADGUARD_USER})"
