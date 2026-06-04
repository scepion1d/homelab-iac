#!/usr/bin/env zsh
# Start the Colima VM (container runtime). Idempotent.
#
# Sizing guidelines (Intel Mac homelab):
#   - Give the VM at most ~75% of host RAM/CPU to leave headroom for macOS.
#   - Measure host: sysctl -n hw.physicalcpu ; sysctl -n hw.memsize ; df -h ~
#   - Measure VM:   colima ssh -- top -bn1 ; kubectl top nodes
#   - Re-tune:      colima stop && COLIMA_CPU=6 COLIMA_MEMORY=12 ./01-start-runtime.sh
set -euo pipefail
cd "$(dirname "$0")"
source ../lib.sh
load_env

PROFILE="${COLIMA_PROFILE:-default}"
CPU="${COLIMA_CPU:-10}"
MEMORY="${COLIMA_MEMORY:-32}"    # GiB
DISK="${COLIMA_DISK:-250}"       # GiB (sparse — only grows as used)
# Give the VM a LAN-routable IP via vmnet. Required for AdGuard to serve
# DNS on the LAN: k3d publishes 53/udp on the VM, and with a routable VM IP
# the LAN can reach it directly (no host port-forward, no mDNSResponder
# collision). See bootstrap/README.md "LAN DNS on :53". Set to "false" to
# fall back to user-mode networking (cluster works, but LAN DNS won't).
NETWORK_ADDRESS="${COLIMA_NETWORK_ADDRESS:-true}"

start_args=(
  --profile "${PROFILE}"
  --cpu "${CPU}"
  --memory "${MEMORY}"
  --disk "${DISK}"
)
if [[ "${NETWORK_ADDRESS}" == "true" ]]; then
  start_args+=(--network-address)
fi

if colima status --profile "${PROFILE}" >/dev/null 2>&1; then
  echo "Colima '${PROFILE}' already running, skipping."
else
  # Don't bail on Colima's spurious DNS-config errors -- newer Colima
  # (vz vmType) ships images without a real dnsmasq binary but creates
  # a `mask` symlink at /etc/systemd/system/dnsmasq.service then later
  # tries `systemctl restart dnsmasq` against its own mask, failing
  # the start hook even though the VM is up and healthy. We verify VM
  # state independently below.
  colima start "${start_args[@]}" || true
fi

# --- Verify VM came up regardless of Colima's exit code ----------------------
# Colima's start hook routinely errors after vm-up (see comment above), so
# we trust `colima status` over the exit code. If the address line is
# missing, the VM actually failed.
#
# Retry loop: even after `colima start` returns "done", the `address:`
# line in `colima status` output can take a few seconds to populate
# (vmnet setup happens after the docker socket is bound). Without
# this poll, the very next `colima status` call sees an addressless
# entry and the script aborts even though the VM is healthy.
#
# We capture stdout+stderr into a variable BEFORE grepping rather than
# piping. `set -o pipefail` is on (via `set -euo pipefail`), and
# `colima status` returns non-zero in some transient post-start states
# even when its output contains the address line; a pipe would inherit
# that non-zero status and the loop would never see success. Decoupling
# capture from match sidesteps the whole class of issue.
for _ in $(seq 1 30); do
  status_out="$(colima status --profile "${PROFILE}" 2>&1 || true)"
  if echo "${status_out}" | grep -q 'address:'; then
    break
  fi
  sleep 2
done
if ! echo "${status_out}" | grep -q 'address:'; then
  echo "ERROR: Colima VM did not come up (no 'address' line in status after 60s)." >&2
  echo "Last status output:" >&2
  echo "${status_out}" >&2
  exit 1
fi
# Same capture-then-grep pattern (pipefail safety) for the network-address check.
if [[ "${NETWORK_ADDRESS}" == "true" ]] \
   && ! echo "${status_out}" | grep -qE 'address:[[:space:]]+[0-9]'; then
  echo "WARNING: Colima is running WITHOUT --network-address. AdGuard LAN" >&2
  echo "         DNS will not work. Stop and recreate to fix:" >&2
  echo "           colima stop --profile ${PROFILE}" >&2
  echo "           colima delete --profile ${PROFILE} -f" >&2
  echo "           ./bootstrap/01-start-runtime.sh" >&2
fi

# --- Repair VM state Colima's failed start hook left behind ------------------
# Four side effects to undo when the start hook errored mid-way OR when
# Colima auto-started a working dnsmasq during boot:
#   1. /etc/systemd/system/dnsmasq.service is left as a `mask` (symlink to
#      /dev/null). Harmless on its own, but the NEXT `colima start` will
#      hit the same trap. Unmask now so the next start runs cleanly.
#   2. dnsmasq is actually running and bound to :53 inside the VM. k3d's
#      serverlb publishes 0.0.0.0:53 from the VM to the host, so any
#      :53 listener inside the VM makes the publish fail with
#      "failed to bind host port 0.0.0.0:53/tcp: address already in use"
#      when step 02 brings k3d up. Stop+disable so it doesn't come back.
#   3. /etc/resolv.conf inside the VM may not have been wired up, leaving
#      DNS pointed at a 192.168.5.1:53 that doesn't answer. Symptom is
#      "i/o timeout" on docker pulls and k3d cluster start. Patch with
#      public DNS as a backstop.
#   4. The docker context (~/.docker/contexts/meta/<hash>/meta.json) may
#      not have been written, leaving the docker CLI looking at
#      /var/run/docker.sock (doesn't exist on Mac). Export DOCKER_HOST
#      directly from the known socket path (handled by ensure_docker_host
#      below, called after this block).
#
# All idempotent / no-op when the VM is already in the desired state.
if colima ssh --profile "${PROFILE}" -- true 2>/dev/null; then
  # 1. Phantom dnsmasq mask.
  if colima ssh --profile "${PROFILE}" -- systemctl is-enabled dnsmasq 2>&1 | grep -q masked; then
    echo "Unmasking dnsmasq.service (was left masked by Colima start hook)..."
    colima ssh --profile "${PROFILE}" -- sudo systemctl unmask dnsmasq 2>/dev/null || true
  fi

  # 2. dnsmasq actively bound to :53. Don't trust `systemctl is-active`
  # alone -- some Colima images run dnsmasq via a different unit name,
  # or via a wrapper script that systemd doesn't track. Check the actual
  # listener and stop/disable whatever owns it.
  #
  # Match strategy: any line containing both a `:53` port AND `dnsmasq`
  # in the users column. `ss` output has the port glued to the address
  # (`192.168.5.1:53`), so a leading word-boundary on `:53` is needed
  # rather than a leading whitespace -- the regex `:53($|[[:space:]])`
  # anchors on end-of-port-field.
  if colima ssh --profile "${PROFILE}" -- sudo ss -lntp 2>/dev/null \
       | awk '/dnsmasq/ && /:53([[:space:]]|$)/' | grep -q .; then
    echo "dnsmasq is listening on :53 inside the VM; stopping+disabling..."
    colima ssh --profile "${PROFILE}" -- sudo systemctl stop dnsmasq 2>/dev/null || true
    colima ssh --profile "${PROFILE}" -- sudo systemctl disable dnsmasq 2>/dev/null || true
    # Confirm it actually let go of the port.
    if colima ssh --profile "${PROFILE}" -- sudo ss -lntp 2>/dev/null \
         | awk '/:53([[:space:]]|$)/' | grep -q .; then
      echo "ERROR: something is still bound to :53/tcp inside the VM after dnsmasq stop." >&2
      colima ssh --profile "${PROFILE}" -- sudo ss -lntp 2>/dev/null | grep ':53' >&2
      exit 1
    fi
  fi

  # 3. Broken VM DNS. cloudflare.com is a stable resolution test;
  # `getent hosts` exits non-zero on resolution failure.
  if ! colima ssh --profile "${PROFILE}" -- getent hosts cloudflare.com >/dev/null 2>&1; then
    echo "VM DNS resolution failed; writing public nameservers to /etc/resolv.conf..."
    printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' \
      | colima ssh --profile "${PROFILE}" -- sudo tee /etc/resolv.conf >/dev/null
    # Confirm.
    if ! colima ssh --profile "${PROFILE}" -- getent hosts cloudflare.com >/dev/null 2>&1; then
      echo "ERROR: VM DNS still broken after /etc/resolv.conf patch." >&2
      exit 1
    fi
  fi
else
  echo "WARNING: cannot reach VM via 'colima ssh'; skipping post-start repair." >&2
fi

# 3. Docker socket fallback. If the CLI can't reach the daemon but
# Colima's socket exists, lib.sh::ensure_docker_host exports DOCKER_HOST
# for the rest of this script and warns the operator to persist it.
# Idempotent and no-op if docker already works.
ensure_docker_host

docker info >/dev/null
echo "Docker engine reachable via Colima (cpu=${CPU}, mem=${MEMORY}GiB, disk=${DISK}GiB)."
