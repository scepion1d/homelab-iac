#!/usr/bin/env zsh
# Heal the homelab after a Colima/VM restart wedge.
#
# Symptoms this script fixes:
#   - `colima stop && colima start` (or a Mac sleep/wake cycle) left the
#     k3d serverlb in a CrashLoopBackOff with
#         nginx: [emerg] host not found in upstream "k3d-homelab-agent-0:443"
#     and `k3d cluster start` can't bring it back. Host ports 80/443/53
#     (and the kube apiserver) are no longer published.
#   - kubelet container IPs registered before colima restart no longer
#     match the docker network IPs (kubectl logs/exec returns 502).
#   - VM dnsmasq came back from the dead (we `mask` it in 01 now, but
#     older deployments only `disable`'d it).
#
# What heal does:
#   1. Verify the VM is healthy (docker DNS works).
#   2. Ensure dnsmasq stays dead.
#   3. Restart the k3d node containers so kubelets re-register their IPs.
#   4. If serverlb isn't Up, replace it with four alpine/socat containers
#      that forward 6443/80/443/53 from the VM into k3d-homelab-server-0.
#   5. Point kubectl at the socat apibridge.
#   6. Smoke-test ingress + DNS.
#
# Idempotent. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh
load_env

PROFILE="${COLIMA_PROFILE:-default}"
CLUSTER="homelab"
NET="k3d-${CLUSTER}"
SERVER="k3d-${CLUSTER}-server-0"
AGENT0="k3d-${CLUSTER}-agent-0"
AGENT1="k3d-${CLUSTER}-agent-1"
SERVERLB="k3d-${CLUSTER}-serverlb"

APIBRIDGE="k3d-${CLUSTER}-apibridge"
HTTP_BRIDGE="k3d-${CLUSTER}-http"
HTTPS_BRIDGE="k3d-${CLUSTER}-https"
DNS_UDP_BRIDGE="k3d-${CLUSTER}-dns-udp"
DNS_TCP_BRIDGE="k3d-${CLUSTER}-dns-tcp"
API_HOST_PORT="${HOMELAB_API_HOST_PORT:-6445}"

# --- 1. VM health ------------------------------------------------------------
echo "==> Checking Colima VM health"
if ! colima status --profile "${PROFILE}" >/dev/null 2>&1; then
  echo "    Colima profile '${PROFILE}' is not running; starting it"
  ./steps/01-start-runtime.sh
fi

# Test if Docker daemon is reachable (not DNS — DNS requires the cluster).
if ! docker info >/dev/null 2>&1; then
  echo "    Docker not reachable — restarting Colima"
  colima stop --profile "${PROFILE}" 2>/dev/null || true
  ./steps/01-start-runtime.sh
  for _ in $(seq 1 30); do
    docker info >/dev/null 2>&1 && break
    sleep 1
  done
  if ! docker info >/dev/null 2>&1; then
    echo "    ERROR: Docker still not reachable after restart" >&2
    exit 1
  fi
fi

# --- 2. Fix VM DNS (dnsmasq is masked, Docker needs a working resolver) ------
# With dnsmasq masked, Docker inside the VM can't resolve registry hostnames.
# Point /etc/resolv.conf at public DNS so image pulls work.
if ! colima ssh --profile "${PROFILE}" -- nslookup registry-1.docker.io >/dev/null 2>&1; then
  echo "==> Fixing VM DNS (pointing at public resolvers)"
  colima ssh --profile "${PROFILE}" -- sudo sh -c \
    'printf "nameserver 1.1.1.1\nnameserver 9.9.9.9\noptions ndots:0\n" > /etc/resolv.conf'
fi

# --- 3. Re-mask dnsmasq (defense; 01 already does this on new bootstraps) ---
if colima ssh --profile "${PROFILE}" -- systemctl is-active dnsmasq >/dev/null 2>&1 \
   || colima ssh --profile "${PROFILE}" -- systemctl is-enabled dnsmasq 2>&1 | grep -qvE '^masked|disabled'; then
  echo "==> Masking dnsmasq inside the VM"
  colima ssh --profile "${PROFILE}" -- sudo systemctl disable --now dnsmasq 2>/dev/null || true
  colima ssh --profile "${PROFILE}" -- sudo systemctl mask dnsmasq 2>/dev/null || true
fi

# --- 3. Restart k3d node containers so kubelet IPs refresh ------------------
NODES=$(docker ps --format '{{.Names}}' \
        | grep -E "^k3d-${CLUSTER}-(server|agent)" || true)
if [[ -n "${NODES}" ]]; then
  echo "==> Restarting k3d node containers (kubelet IP refresh)"
  for n in ${(f)NODES}; do
    docker restart "${n}" >/dev/null
    echo "    restarted ${n}"
  done
fi

# --- 4. Replace broken serverlb with socat bridges if needed ----------------
serverlb_state="$(docker inspect "${SERVERLB}" --format '{{.State.Status}}' 2>/dev/null || echo missing)"
echo "==> k3d serverlb state: ${serverlb_state}"

run_socat() {
  local name="$1" host_port="$2" proto="$3" target_port="$4"
  local listen target
  if [[ "${proto}" == "udp" ]]; then
    listen="udp-listen:${target_port},fork,reuseaddr"
    target="udp:${SERVER}:${target_port}"
    publish="${host_port}:${target_port}/udp"
  else
    listen="tcp-listen:${target_port},fork,reuseaddr"
    target="tcp:${SERVER}:${target_port}"
    publish="${host_port}:${target_port}"
  fi
  docker rm -f "${name}" >/dev/null 2>&1 || true
  docker run -d --name "${name}" \
    --network "${NET}" \
    -p "${publish}" \
    --restart unless-stopped \
    alpine/socat "${listen}" "${target}" >/dev/null
  echo "    ${name}: host :${host_port}/${proto} -> ${SERVER}:${target_port}"
}

if [[ "${serverlb_state}" != "running" ]]; then
  echo "==> serverlb not healthy; installing socat bridges as fallback"
  # Wipe any prior incarnation, including the k3d-as-LB misadventure.
  docker rm -f "${SERVERLB}" "k3d-lb1-0" 2>/dev/null || true

  run_socat "${APIBRIDGE}"      "${API_HOST_PORT}" tcp 6443
  run_socat "${HTTP_BRIDGE}"    80                 tcp 80
  run_socat "${HTTPS_BRIDGE}"   443                tcp 443
  run_socat "${DNS_UDP_BRIDGE}" 53                 udp 53
  run_socat "${DNS_TCP_BRIDGE}" 53                 tcp 53
else
  echo "    serverlb is running; nothing to bridge"
fi

# --- 5. Point kubectl at whichever port is now correct ----------------------
echo "==> Refreshing kubectl context"
if docker ps --filter "name=^${APIBRIDGE}$" --format '{{.Names}}' | grep -q .; then
  # We are on socat fallback.
  kubectl config set-cluster "k3d-${CLUSTER}" --server="https://0.0.0.0:${API_HOST_PORT}" >/dev/null
  kubectl config set-cluster "k3d-${CLUSTER}" --insecure-skip-tls-verify=true >/dev/null
  kubectl config unset "clusters.k3d-${CLUSTER}.certificate-authority-data" >/dev/null 2>&1 || true
  echo "    kubectl -> https://0.0.0.0:${API_HOST_PORT} (socat apibridge)"
else
  # Real serverlb is back; let k3d regenerate the kubeconfig with the right port.
  k3d kubeconfig merge "${CLUSTER}" --kubeconfig-merge-default --kubeconfig-switch-context >/dev/null
  echo "    kubectl -> k3d-provided port"
fi

# Wait for the apiserver to answer.
for _ in $(seq 1 30); do
  kubectl get --raw='/readyz' >/dev/null 2>&1 && break
  sleep 1
done

# --- 6. Smoke tests ----------------------------------------------------------
echo
echo "==> Cluster nodes"
kubectl get nodes -o wide || true

echo
echo "==> DNS smoke test (Mac -> dns-proxy -> VM:53 -> AdGuard)"
if command -v dig >/dev/null 2>&1; then
  dig @127.0.0.1 cloudflare.com +short +timeout=3 || true
fi

echo
echo "==> Ingress smoke test"
curl -sk -o /dev/null -w 'argocd.int  -> HTTP %{http_code}\n' --max-time 5 https://argocd.int  || true
curl -sk -o /dev/null -w 'grafana.int -> HTTP %{http_code}\n' --max-time 5 https://grafana.int || true

cat <<EOF

Healing complete.
If something still looks wrong, the heavy hammer is:
    ./bootstrap/teardown.sh && ./bootstrap/bootstrap.sh
which rebuilds the cluster with a real k3d serverlb (loses AdGuard PVC).
EOF
