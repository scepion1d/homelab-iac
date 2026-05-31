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
source ./lib.sh
load_env
require_var ADGUARD_USER
require_var ADGUARD_PASSWORD

NS="dns"
DEPLOY="adguard"
SVC="adguard-ui"
LOCAL_PORT=33000

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
    ;;
  *)
    # AdGuard returns 403 once it's already configured (the install
    # endpoints become unreachable). Treat that as success.
    if [[ "${HTTP}" == "403" || "${HTTP}" == "404" ]] \
       || grep -qiE 'already.*configured|forbidden' "${RESP_BODY}" 2>/dev/null; then
      echo "    AdGuard appears already configured (HTTP ${HTTP}); skipping."
    else
      echo "ERROR: wizard returned HTTP ${HTTP}:" >&2
      cat "${RESP_BODY}" >&2 || true
      exit 1
    fi
    ;;
esac

echo "==> Waiting for adguard rollout (now that :53 is bound)"
# The wizard write triggers AdGuard to reload; the liveness probe should
# now pass. Restart to be deterministic.
kubectl -n "${NS}" rollout restart deploy/"${DEPLOY}" >/dev/null
kubectl -n "${NS}" rollout status deploy/"${DEPLOY}" --timeout=300s

echo
echo "AdGuard is configured. UI: https://adguard.int  (user: ${ADGUARD_USER})"
