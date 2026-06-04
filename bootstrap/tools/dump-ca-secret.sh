#!/usr/bin/env zsh
# Snapshot the cert-manager root CA secret to a local backup file so a
# future teardown + bootstrap can restore it (via restore-ca-secret.sh)
# and devices that previously trusted homelab-ca don't need to re-import.
#
# Backup location: bootstrap/.ca-secret.yaml (gitignored). chmod 600.
# Override with CA_SECRET_BACKUP_PATH if you want a different location.
#
# Idempotent. Safe to run anytime. Also invoked from dump-cluster-secrets.sh
# so the standard before-teardown snapshot captures the CA too.

set -euo pipefail
cd "$(dirname "$0")"
source ../lib.sh
load_env

BACKUP="${CA_SECRET_BACKUP_PATH:-$(cd .. && pwd)/.ca-secret.yaml}"
NS=cert-manager
SECRET=homelab-ca-key-pair

if ! kubectl version --request-timeout=5s >/dev/null 2>&1; then
  echo "ERROR: kubectl can't reach the cluster. Is it running?" >&2
  exit 1
fi

if ! kubectl -n "${NS}" get secret "${SECRET}" >/dev/null 2>&1; then
  echo "==> ${NS}/${SECRET} not present; nothing to back up."
  exit 0
fi

# Dump and scrub instance-only metadata so the result applies cleanly
# anywhere. annotations and labels are dropped too -- they're set by
# cert-manager / Argo CD on creation and would otherwise stick around
# and confuse future reconciliation. Atomic move avoids torn file on
# Ctrl-C mid-dump.
tmp="${BACKUP}.tmp.$$"
trap 'rm -f "${tmp}"' EXIT
kubectl -n "${NS}" get secret "${SECRET}" -o yaml \
  | yq 'del(
      .metadata.resourceVersion,
      .metadata.uid,
      .metadata.creationTimestamp,
      .metadata.managedFields,
      .metadata.ownerReferences,
      .metadata.annotations,
      .metadata.labels
    )' > "${tmp}"
mv "${tmp}" "${BACKUP}"
trap - EXIT
chmod 600 "${BACKUP}"

# Print fingerprint + validity window so the operator can confirm
# what's been captured.
fingerprint=$(yq '.data."tls.crt"' "${BACKUP}" | tr -d '"' \
  | base64 -d | openssl x509 -noout -fingerprint 2>/dev/null \
  | cut -d= -f2)
notafter=$(yq '.data."tls.crt"' "${BACKUP}" | tr -d '"' \
  | base64 -d | openssl x509 -noout -enddate 2>/dev/null \
  | cut -d= -f2)
echo "==> Backed up ${NS}/${SECRET} -> ${BACKUP}"
echo "    fingerprint: ${fingerprint}"
echo "    valid until: ${notafter}"
