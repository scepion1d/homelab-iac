#!/usr/bin/env zsh
# Register git repo credentials with Argo CD (so the root AppSet can
# enumerate cluster/apps/* in a private repo), then apply the root
# ApplicationSet. From this point on Argo CD owns the cluster state --
# add a folder under cluster/apps/ with an _appset.yaml and commit;
# nothing else.
#
# Why the port-forward
# --------------------
# At this point in bootstrap nginx-ingress isn't synced yet, so we can't
# hit `argocd.<lanDomain>` over the LAN. `argocd login` needs the gRPC
# endpoint on argocd-server, so we port-forward to a high local port
# and tear it down at the end. Self-contained: no shell state survives.
#
# Credentials source
# ------------------
# ARGOCD_GIT_USER + ARGOCD_GIT_PAT in bootstrap/.env. If either is unset
# the script logs a warning and proceeds; the root AppSet will land in
# Degraded state with `authentication required: Repository not found`
# until creds are added by hand or .env + re-run.
set -euo pipefail
cd "$(dirname "$0")"
source ../lib.sh
load_env

REPO_URL="$(yq -r '.repoUrl' ../cluster/globals.yaml 2>/dev/null || true)"
if [[ -z "${REPO_URL}" || "${REPO_URL}" == "null" ]]; then
  echo "ERROR: could not read .repoUrl from ../cluster/globals.yaml (is yq installed?)." >&2
  exit 1
fi

if [[ -n "${ARGOCD_GIT_USER:-}" && -n "${ARGOCD_GIT_PAT:-}" ]]; then
  echo "==> Registering ${REPO_URL} with Argo CD"

  # Pick a free high port for the temporary port-forward. Fixed default
  # but search a small window in case the operator already has a
  # port-forward running on that port.
  PF_PORT=18083
  if lsof -nP -iTCP:${PF_PORT} -sTCP:LISTEN >/dev/null 2>&1; then
    for p in 18084 18085 18086 18087; do
      if ! lsof -nP -iTCP:${p} -sTCP:LISTEN >/dev/null 2>&1; then
        PF_PORT=${p}
        break
      fi
    done
  fi

  # Background port-forward. trap guarantees teardown even if argocd
  # login / repo add fails mid-way (set -e would otherwise leave the
  # process dangling).
  kubectl -n argocd port-forward svc/argocd-server "${PF_PORT}:443" \
    >/dev/null 2>&1 &
  PF_PID=$!
  trap 'kill "${PF_PID}" 2>/dev/null || true' EXIT

  # Wait for the port-forward to accept connections.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if nc -z 127.0.0.1 "${PF_PORT}" 2>/dev/null; then break; fi
    sleep 1
  done
  if ! nc -z 127.0.0.1 "${PF_PORT}" 2>/dev/null; then
    echo "ERROR: port-forward to argocd-server didn't come up within 10s." >&2
    exit 1
  fi

  # Read the initial admin password straight from the cluster Secret.
  # If it's gone (operator rotated via UI), we can't reconstruct the
  # password from the bcrypt hash in argocd-secret -- bail with a
  # clear pointer to the manual recovery path.
  ADMIN_PWD="$(kubectl -n argocd get secret argocd-initial-admin-secret \
                 -o jsonpath='{.data.password}' 2>/dev/null \
               | base64 -d || true)"
  if [[ -z "${ADMIN_PWD}" ]]; then
    echo "ERROR: argocd-initial-admin-secret is gone (admin password rotated)." >&2
    echo "       Add the repo manually:" >&2
    echo "         source scripts/argocd-login.sh && argocd-login" >&2
    echo "         argocd repo add ${REPO_URL} --username '${ARGOCD_GIT_USER}' --password '<your-pat>'" >&2
    exit 1
  fi

  argocd login "127.0.0.1:${PF_PORT}" \
    --username admin --password "${ADMIN_PWD}" \
    --grpc-web --insecure >/dev/null

  # --upsert: replace credentials in place if the PAT was rotated.
  # No-op when the same value is already present.
  argocd repo add "${REPO_URL}" \
    --username "${ARGOCD_GIT_USER}" \
    --password "${ARGOCD_GIT_PAT}" \
    --upsert >/dev/null
  echo "    ${REPO_URL}: registered"

  kill "${PF_PID}" 2>/dev/null || true
  trap - EXIT
else
  cat >&2 <<EOF
==> WARNING: ARGOCD_GIT_USER / ARGOCD_GIT_PAT not set; skipping repo registration.

    If ${REPO_URL} is private, the root ApplicationSet will be Degraded
    with "authentication required: Repository not found" until creds are
    added. Either:
      - set them in bootstrap/.env and re-run this script, or
      - add manually:
          source scripts/argocd-login.sh && argocd-login
          argocd repo add ${REPO_URL} \\
            --username <gh-user> --password '<github_pat_...>'
EOF
fi

echo "==> Applying root ApplicationSet"
kubectl apply -f ../cluster/root-appset.yaml

# Kick the AppSet to re-resolve immediately rather than waiting for the
# next poll cycle. Harmless on a fresh apply (next reconcile is imminent
# anyway); useful when re-running after a PAT update.
kubectl -n argocd annotate appset root --overwrite \
  argocd.argoproj.io/refresh="$(date +%s)" >/dev/null 2>&1 || true
