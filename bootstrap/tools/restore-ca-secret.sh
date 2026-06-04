#!/usr/bin/env zsh
# Restore the cert-manager root CA secret from a previous dump-ca-secret
# snapshot, then force-reissue every leaf Certificate so it gets signed
# by the restored CA.
#
# When to run:
#   After a fresh ./bootstrap/bootstrap.sh, IF you want previously-
#   trusted devices (phones, laptops with the OLD homelab-ca already
#   imported) to keep working without re-importing the CA.
#
# Why the orchestration is non-trivial:
#   cert-manager actively reconciles the homelab-ca Secret. A naive
#   `kubectl delete secret && kubectl apply -f backup.yaml` races the
#   controller -- by the time apply runs, cert-manager has already
#   re-generated a fresh CA Secret, and apply fails with
#   "AlreadyExists" / "the object has been modified". To win the race
#   reliably we scale every Deployment in the cert-manager namespace
#   (controller + cainjector + webhook) to 0 first, swap, then scale
#   back up. On bring-up cert-manager sees a valid Secret matching the
#   Certificate spec and uses it instead of regenerating.
#
#   Leaf re-issue is then triggered by deleting each leaf Secret. The
#   Certificate object stays put; cert-manager re-issues into the same
#   Secret name immediately, signed by the restored CA. Tiny window
#   (~5s) where ingresses serve the old leaf -- still trusted because
#   we just put the matching CA back.

set -euo pipefail
cd "$(dirname "$0")"
source ../lib.sh
load_env

BACKUP="${CA_SECRET_BACKUP_PATH:-$(cd .. && pwd)/.ca-secret.yaml}"
NS=cert-manager
SECRET=homelab-ca-key-pair
CA_CERT=homelab-ca   # the Certificate resource the ClusterIssuer issues

if [[ ! -f "${BACKUP}" ]]; then
  echo "ERROR: no backup at ${BACKUP}." >&2
  echo "       Run ./bootstrap/dump-ca-secret.sh on a cluster with the desired" >&2
  echo "       CA first, or set CA_SECRET_BACKUP_PATH to point at one." >&2
  exit 1
fi
if ! yq '.data."tls.crt"' "${BACKUP}" >/dev/null 2>&1; then
  echo "ERROR: ${BACKUP} doesn't look like a Secret YAML (no .data.\"tls.crt\")." >&2
  exit 1
fi

backup_fp=$(yq '.data."tls.crt"' "${BACKUP}" | tr -d '"' \
  | base64 -d | openssl x509 -noout -fingerprint 2>/dev/null \
  | cut -d= -f2)
echo "==> Backup fingerprint: ${backup_fp}"

# 1. Wait for cert-manager + the current (fresh) CA Secret to exist.
# We need the controller to be in steady state so the pause-and-swap is
# deterministic.
echo "==> Waiting for cert-manager Deployment Ready..."
kubectl -n "${NS}" wait deploy/cert-manager --for=condition=Available --timeout=300s
echo "==> Waiting for ${NS}/${SECRET} to exist..."
for _ in $(seq 1 60); do
  if kubectl -n "${NS}" get secret "${SECRET}" >/dev/null 2>&1; then break; fi
  sleep 2
done
if ! kubectl -n "${NS}" get secret "${SECRET}" >/dev/null 2>&1; then
  echo "ERROR: ${NS}/${SECRET} never appeared. Is cluster-issuer synced?" >&2
  exit 1
fi

current_fp=$(kubectl -n "${NS}" get secret "${SECRET}" \
  -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -fingerprint 2>/dev/null | cut -d= -f2)
echo "==> Current fingerprint: ${current_fp}"

# --- Decide whether the CA swap is needed -----------------------------------
# Even if the CA already matches (idempotent re-runs), we still want to
# force-reissue leaf certs further down -- a CA-restore session may have
# bailed mid-way last time, leaving leaves signed by an earlier short-lived
# bootstrap CA. The browser sees AUTHORITY_INVALID; only re-issue fixes it.
SWAP_NEEDED=1
if [[ "${current_fp}" == "${backup_fp}" ]]; then
  echo "==> CA already matches backup; skipping pause/swap, but still re-issuing leaves."
  SWAP_NEEDED=0
fi

# 2. Pause every Deployment in cert-manager namespace. Only if a swap
# is actually needed -- on a no-op rerun we skip straight to the leaf
# re-issue below.
if (( SWAP_NEEDED )); then
  echo "==> Scaling cert-manager namespace Deployments to 0..."
  typeset -a deploys
  deploys=("${(@f)$(kubectl -n "${NS}" get deploy -o name)}")
  typeset -A replicas
  for d in "${deploys[@]}"; do
    replicas[$d]=$(kubectl -n "${NS}" get "$d" -o jsonpath='{.spec.replicas}')
    kubectl -n "${NS}" scale "$d" --replicas=0 >/dev/null
  done
  # Wait for pods to actually terminate so they can't fight us during swap.
  echo "==> Waiting for cert-manager pods to terminate..."
  for _ in $(seq 1 30); do
    count=$(kubectl -n "${NS}" get pod --no-headers 2>/dev/null \
              | awk '$3!="Terminating"' | wc -l | tr -d ' ')
    [[ "${count}" == "0" ]] && break
    sleep 1
  done

  # 3. Swap the Secret. cert-manager is asleep; nothing races us.
  echo "==> Replacing ${NS}/${SECRET} with backup..."
  kubectl -n "${NS}" delete secret "${SECRET}" --ignore-not-found
  kubectl create -f "${BACKUP}"

  # 4. Scale cert-manager back up to original replica counts.
  echo "==> Scaling cert-manager Deployments back up..."
  for d in "${deploys[@]}"; do
    kubectl -n "${NS}" scale "$d" --replicas="${replicas[$d]:-1}" >/dev/null
  done
  kubectl -n "${NS}" wait deploy/cert-manager --for=condition=Available --timeout=180s

  # Confirm cert-manager didn't immediately overwrite our restored Secret.
  new_fp=$(kubectl -n "${NS}" get secret "${SECRET}" \
    -o jsonpath='{.data.tls\.crt}' | base64 -d \
    | openssl x509 -noout -fingerprint 2>/dev/null | cut -d= -f2)
  if [[ "${new_fp}" != "${backup_fp}" ]]; then
    echo "ERROR: Secret was overwritten after scale-up (fp=${new_fp}, expected ${backup_fp})." >&2
    echo "       Something else may be reconciling it. Investigate:" >&2
    echo "         kubectl -n ${NS} get secret ${SECRET} -o yaml | yq .metadata.managedFields" >&2
    exit 1
  fi
  echo "==> Restored. New fingerprint: ${new_fp}"
fi

# 5. Force re-issue every leaf Certificate so it's signed by the
# restored CA.  Runs unconditionally -- even when the CA didn't need
# swapping, leaves may have been issued by a brief earlier bootstrap CA
# and never re-signed (operator browser still sees AUTHORITY_INVALID).
# Delete the per-leaf Secret (not the Certificate object); cert-manager
# re-issues into the same Secret name within seconds. Skip the CA
# Certificate itself.
echo "==> Re-issuing leaf Certificates..."
kubectl get certificate -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}/{.spec.secretName}{"\n"}{end}' \
  | while IFS=/ read -r ns name secret_name; do
      [[ -z "${name}" || -z "${secret_name}" ]] && continue
      [[ "${ns}/${name}" == "${NS}/${CA_CERT}" ]] && continue
      kubectl -n "${ns}" delete secret "${secret_name}" --ignore-not-found >/dev/null
      echo "    ${ns}/${name} (secret ${secret_name}) -> re-issuing"
    done

cat <<EOF

Done. Watch leaf certificates come back Ready:
    kubectl get certificates -A -w

Once all show READY=True, hit https://grafana.int from a previously-
trusting device. No CA re-import needed.

If something later regenerates the CA Secret unexpectedly, re-run this
script -- it's idempotent.
EOF
