#!/usr/bin/env zsh
# Install + configure the macOS host metrics pipeline:
#   1. node_exporter (darwin build, from Homebrew) as a LaunchDaemon
#   2. mac-extras.sh as a LaunchDaemon (textfile collector, every 60s)
#   3. Splice a scrape job into cluster/apps/prometheus/_appset.yaml so
#      in-cluster Prometheus pulls /metrics from the Mac host.
#
# Bind address:
#   node_exporter binds to the Mac's vmnet bridge IP — the address that
#   `host.docker.internal` resolves to from inside Colima. That IP is
#   private to the Colima VM, not advertised on the home LAN, so the
#   exporter is reachable from cluster pods but not from phones/laptops
#   on the LAN. (Pure loopback wouldn't work: containers inside the VM
#   can't reach the Mac's 127.0.0.1.)
#
# Idempotent: safe to re-run. Bind address is re-discovered each time —
# rerun after colima delete + start.

set -euo pipefail
cd "$(dirname "$0")"
source ../lib.sh
load_env

LABEL_NE="com.homelab.node-exporter"
LABEL_MX="com.homelab.mac-extras"
PLIST_NE_TEMPLATE="../launchd-system/${LABEL_NE}.plist"
PLIST_MX_TEMPLATE="../launchd-system/${LABEL_MX}.plist"
PLIST_NE_DST="/Library/LaunchDaemons/${LABEL_NE}.plist"
PLIST_MX_DST="/Library/LaunchDaemons/${LABEL_MX}.plist"
SCRIPT_SRC="../services/mac-extras.sh"
SCRIPT_DST_DIR="/usr/local/lib/homelab"
SCRIPT_DST="${SCRIPT_DST_DIR}/mac-extras.sh"
TEXTFILE_DIR="/usr/local/var/mac-exporter"

PROFILE="${COLIMA_PROFILE:-default}"

# --- locate node_exporter from Homebrew --------------------------------------
# Both Intel (/usr/local) and Apple Silicon (/opt/homebrew) prefixes are
# acceptable; whichever has the formula installed wins.
NODE_EXPORTER=""
for candidate in /opt/homebrew/bin/node_exporter /usr/local/bin/node_exporter; do
  [[ -x "${candidate}" ]] && { NODE_EXPORTER="${candidate}"; break; }
done
if [[ -z "${NODE_EXPORTER}" ]]; then
  echo "ERROR: node_exporter not found. Install via:" >&2
  echo "         brew install node_exporter" >&2
  exit 1
fi
echo "==> node_exporter binary: ${NODE_EXPORTER}"

# --- locate iStats (optional; preferred CPU temp + fan source on Intel) -----
# iStats is a Ruby gem (`sudo gem install iStats`). When present, mac-extras
# uses it for CPU temperature and fan RPM because it works on hardware that
# `powermetrics --samplers smc` doesn't (notably iMac 2020 Intel which doesn't
# expose fan info via powermetrics at all). When absent, mac-extras falls
# back to osx-cpu-temp + powermetrics.
if ! command -v istats >/dev/null 2>&1; then
  echo "==> NOTE: iStats not installed. CPU temp + fan readings will use the"
  echo "          fallback path (works on some hardware, missing on others)."
  echo "          To enable richer host metrics:  sudo gem install iStats"
fi

# --- discover the bind address ----------------------------------------------
# `host.docker.internal` is set up by Colima inside the VM as the Mac-side
# gateway of the user-mode (lima vmnet) network — typically 192.168.5.2 on
# the qemu/lima default, sometimes 192.168.106.1 on bridged-vmnet, etc.
# Look it up from inside the VM rather than hardcoding.
echo "==> Discovering Colima bridge address (host.docker.internal)"
BIND_ADDR=""
if command -v colima >/dev/null 2>&1; then
  # `getent ahosts` is GNU; lima ships busybox so use `nslookup`/`cat /etc/hosts`.
  # /etc/hosts inside the VM has the mapping in plain text.
  BIND_ADDR="$(colima ssh --profile "${PROFILE}" -- \
                 awk '/host\.docker\.internal/ {print $1; exit}' /etc/hosts \
                 2>/dev/null | tr -d '\r' || true)"
fi
if [[ -z "${BIND_ADDR}" ]]; then
  # Fallback: parse from `ifconfig bridge100` (the lima-shared interface
  # on macOS qemu). Pick the first inet address.
  BIND_ADDR="$(ifconfig bridge100 2>/dev/null | awk '/inet /{print $2; exit}' || true)"
fi
if [[ -z "${BIND_ADDR}" ]]; then
  echo "ERROR: could not discover Mac-side address visible from Colima VM." >&2
  echo "       Make sure colima is running:  colima status --profile ${PROFILE}" >&2
  exit 1
fi
echo "==> node_exporter will bind to ${BIND_ADDR}:9100"

# --- discover the user who owns the colima profile --------------------------
# mac-extras runs as root, but `colima status` reads ~/.colima — so it has
# to step down to whoever installed colima. SUDO_USER is set when this
# script is invoked via sudo; USER otherwise. Both safe to stamp in.
COLIMA_USER="${SUDO_USER:-${USER}}"
echo "==> mac-extras will run colima commands as: ${COLIMA_USER}"

# --- install mac-extras.sh --------------------------------------------------
echo "==> Installing mac-extras.sh to ${SCRIPT_DST}"
sudo install -d -m 0755 -o root -g wheel "${SCRIPT_DST_DIR}"
sudo install -m 0755 -o root -g wheel "${SCRIPT_SRC}" "${SCRIPT_DST}"

# --- prepare textfile collector dir -----------------------------------------
# root:wheel 0755; node_exporter (root) writes its own; mac-extras (root)
# writes the .prom file. Mode lets future user-mode debugging cat it.
echo "==> Ensuring textfile collector dir ${TEXTFILE_DIR}"
sudo install -d -m 0755 -o root -g wheel "${TEXTFILE_DIR}"

# --- render & install the LaunchDaemon plists -------------------------------
echo "==> Installing LaunchDaemon ${PLIST_NE_DST}"
TMP_NE="$(mktemp)"
TMP_MX="$(mktemp)"
trap 'rm -f "${TMP_NE}" "${TMP_MX}"' EXIT

sed -e "s|__NODE_EXPORTER__|${NODE_EXPORTER}|g" \
    -e "s|__BIND_ADDR__|${BIND_ADDR}|g" \
    "${PLIST_NE_TEMPLATE}" > "${TMP_NE}"
sudo install -m 0644 -o root -g wheel "${TMP_NE}" "${PLIST_NE_DST}"

echo "==> Installing LaunchDaemon ${PLIST_MX_DST}"
sed -e "s|__COLIMA_USER__|${COLIMA_USER}|g" \
    -e "s|__COLIMA_PROFILE__|${PROFILE}|g" \
    "${PLIST_MX_TEMPLATE}" > "${TMP_MX}"
sudo install -m 0644 -o root -g wheel "${TMP_MX}" "${PLIST_MX_DST}"

# Reload both so config changes (bind addr, profile, etc.) take effect.
for daemon in "${PLIST_NE_DST}" "${PLIST_MX_DST}"; do
  sudo launchctl bootout system "${daemon}" 2>/dev/null || true
  sudo launchctl bootstrap system "${daemon}"
done

# --- smoke test -------------------------------------------------------------
echo "==> Waiting for node_exporter to come up on ${BIND_ADDR}:9100"
ok=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl -sf -m 1 "http://${BIND_ADDR}:9100/metrics" >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 0.5
done
if (( ok )); then
  echo "    /metrics responding."
else
  echo "    WARNING: /metrics not responding yet. Check /var/log/homelab-node-exporter.log" >&2
fi

# Kick mac-extras once so the textfile collector has data before the next
# scrape — without this, the first 60s after install would show only
# node_exporter's built-in metrics.
echo "==> Priming mac-extras (one-shot run)"
sudo /bin/zsh "${SCRIPT_DST}" || echo "    WARNING: mac-extras priming failed; will retry on next StartInterval." >&2

# --- splice the scrape job into cluster/apps/prometheus/_appset.yaml --------
echo "==> Updating cluster/apps/prometheus/_appset.yaml with mac-host scrape job"
APPSET="$(__repo_root)/cluster/apps/prometheus/_appset.yaml"
if [[ ! -f "${APPSET}" ]]; then
  echo "    WARNING: ${APPSET} missing; skipping splice." >&2
else
  before="$(sha256sum "${APPSET}" | awk '{print $1}')"
  # Wire the scrape config into helm.values.serverFiles."mac-host.yml"
  # (separate from host-targets.yml so 09-host-apps.sh and this script don't
  # fight over the same key) and ensure scrapeConfigFiles references it.
  # NOTE: `serverFiles` and `scrapeConfigFiles` are TOP-LEVEL chart keys,
  # NOT nested under `server:` — the prometheus-community chart silently
  # ignores them otherwise.
  BIND_ADDR="${BIND_ADDR}" yq -i '
    .source.helm.values.serverFiles."mac-host.yml".scrape_configs = (
      [{
        "job_name": "mac-host",
        "scrape_interval": "30s",
        "scrape_timeout": "10s",
        "static_configs": [{
          "targets": [strenv(BIND_ADDR) + ":9100"],
          "labels": {"host": "mac", "source": "host-native"}
        }]
      }] | ... style=""
    )
    | .source.helm.values.server.scrapeConfigFiles = (
        ((.source.helm.values.server.scrapeConfigFiles // []) + ["/etc/config/mac-host.yml"]) | unique
      )
  ' "${APPSET}"
  after="$(sha256sum "${APPSET}" | awk '{print $1}')"
  if [[ "${before}" == "${after}" ]]; then
    echo "    unchanged."
  else
    echo "    !! file changed — commit + push for Argo CD to pick up."
  fi
fi

cat <<EOF

Done. Mac host metrics are now scraped by in-cluster Prometheus.

  exporter:   http://${BIND_ADDR}:9100/metrics  (Colima VM-side only)
  log:        /var/log/homelab-node-exporter.log
              /var/log/homelab-mac-extras.log
  textfiles:  ${TEXTFILE_DIR}/mac-extras.prom

Query examples (Prometheus UI at https://prometheus.int):
  node_load1{host="mac"}
  mac_cpu_temp_celsius
  mac_smart_percent_used
  mac_colima_running

Re-run this script any time:
  - colima is recreated (bind address may change)
  - the colima profile name in .env changes
  - you edit mac-extras.sh or either plist
EOF
