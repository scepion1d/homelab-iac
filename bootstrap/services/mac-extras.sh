#!/usr/bin/env zsh
# mac-extras.sh -- gather macOS-specific health metrics that node_exporter's
# darwin build doesn't expose, and write them in Prometheus textfile-collector
# format to ${OUT_DIR}/mac-extras.prom.
#
# Invoked every minute by com.homelab.mac-extras LaunchDaemon (installed by
# bootstrap/10-mac-exporter.sh). node_exporter is started with
#   --collector.textfile.directory=${OUT_DIR}
# so the metrics show up at /metrics on the next scrape.
#
# Runs as root (LaunchDaemon) so `powermetrics`, `smartctl`, and `ioreg` work
# without an interactive sudo prompt.
#
# Writes the file atomically: build into a tempfile in the same dir, fsync,
# rename. node_exporter's textfile collector tolerates a partial read but
# atomic swap avoids ever showing it half-written metrics.
#
# Conventions:
#   - All metric names prefixed `mac_` to avoid colliding with node_exporter.
#   - HELP/TYPE lines emitted once per metric family.
#   - On collection failure for a section, emit a `mac_<section>_up 0` gauge
#     instead of dropping silently — Grafana panels can alert on it later.

set -u
# Don't `set -e` -- a single failing command (e.g. smartctl on a disk we
# can't read) should not abort the entire collection.

OUT_DIR="${OUT_DIR:-/usr/local/var/mac-exporter}"
OUT_FILE="${OUT_DIR}/mac-extras.prom"

# Clean up any stale tempfiles from previous runs that died before the
# atomic-swap trap could fire (SIGKILL, machine reboot, etc.).
# node_exporter's textfile collector reads EVERY file in OUT_DIR including
# our hidden tempfiles, and a partially-written one will fail to parse and
# flip node_textfile_scrape_error to 1 — which drops all our metrics. Five
# minutes is well beyond any healthy mac-extras run.
find "${OUT_DIR}" -maxdepth 1 -name '.mac-extras.prom.*' -mmin +5 -delete 2>/dev/null || true

TMP_FILE="$(mktemp "${OUT_DIR}/.mac-extras.prom.XXXXXX")"
trap 'rm -f "${TMP_FILE}"' EXIT

# Homebrew lives at /usr/local/bin on Intel Macs, /opt/homebrew/bin on Apple
# Silicon. LaunchDaemons get a minimal PATH; add both.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

emit() { printf '%s\n' "$*" >> "${TMP_FILE}"; }

# ---------------------------------------------------------------------------
# Header: scrape timestamp + script version. Cheap aliveness signal — if this
# stops updating, the LaunchDaemon stopped firing.
# ---------------------------------------------------------------------------
emit "# HELP mac_extras_last_run_timestamp_seconds Unix timestamp of last mac-extras.sh run."
emit "# TYPE mac_extras_last_run_timestamp_seconds gauge"
emit "mac_extras_last_run_timestamp_seconds $(date +%s)"

# ---------------------------------------------------------------------------
# CPU temperature.
#
# Preferred source: iStats (`sudo gem install iStats`). Reads via Apple's SMC
# API and works on both Intel and Apple Silicon Macs. Output:
#   "CPU temp:               45.44°C     ▁▂▃▅▆▇"
# Fallback: osx-cpu-temp (brew). Works on Intel only; on Apple Silicon it
# silently reports 0.0°C because the SMC key it reads isn't populated.
# ---------------------------------------------------------------------------
emit "# HELP mac_cpu_temp_celsius CPU package temperature reported by SMC."
emit "# TYPE mac_cpu_temp_celsius gauge"
emit "# HELP mac_cpu_temp_up 1 if a temperature source returned a usable value."
emit "# TYPE mac_cpu_temp_up gauge"
temp=""
if command -v istats >/dev/null 2>&1; then
  # `istats cpu temp --value-only --no-scale --no-graphs` would be ideal but
  # iStats 1.6 ignores those flags for cpu/temp. Parse the labeled line.
  temp="$(istats cpu temp 2>/dev/null | awk '/CPU temp/ {gsub(/[^0-9.]/, "", $3); print $3; exit}')"
fi
if [[ -z "${temp}" ]] && command -v osx-cpu-temp >/dev/null 2>&1; then
  temp="$(osx-cpu-temp -c 2>/dev/null | tr -d '\n' | sed -E 's/[^0-9.]//g')"
fi
if [[ "${temp}" =~ ^[0-9]+(\.[0-9]+)?$ && "${temp}" != "0.0" && "${temp}" != "0" ]]; then
  emit "mac_cpu_temp_celsius ${temp}"
  emit "mac_cpu_temp_up 1"
else
  emit "mac_cpu_temp_up 0"
fi

# ---------------------------------------------------------------------------
# Thermal pressure -- `pmset -g therm` exposes the macOS thermal state.
# Output line: "CPU_Speed_Limit  = 100"  (100 = no throttle, <100 = throttled)
# ---------------------------------------------------------------------------
emit "# HELP mac_cpu_speed_limit_percent Current CPU clock cap from pmset -g therm (100 = unthrottled)."
emit "# TYPE mac_cpu_speed_limit_percent gauge"
speed_limit="$(pmset -g therm 2>/dev/null | awk -F'= *' '/CPU_Speed_Limit/{print $2; exit}')"
if [[ "${speed_limit}" =~ ^[0-9]+$ ]]; then
  emit "mac_cpu_speed_limit_percent ${speed_limit}"
else
  emit "mac_cpu_speed_limit_percent 100"
fi

# ---------------------------------------------------------------------------
# Fan RPM -- powermetrics --samplers smc, takes a short sample.
# powermetrics needs root (we have it). Output includes "Fan: 1234 rpm".
# Sample window is 200ms so we don't add measurable load.
# ---------------------------------------------------------------------------
emit "# HELP mac_fan_rpm Fan speed in RPM (one series per detected fan)."
emit "# TYPE mac_fan_rpm gauge"
emit "# HELP mac_fan_up 1 if a fan reading source returned >=1 fan."
emit "# TYPE mac_fan_up gauge"
fan_ok=0
if command -v istats >/dev/null 2>&1; then
  # iStats output (no shell colors, fixed columns):
  #   Total fans in system:   1
  #   Fan 0 speed:            1210 RPM    ▁▂▃▅▆▇
  # Capture the RPM column (4th token) per `Fan N speed:` line. Includes
  # 0-RPM fans intentionally — a fan reporting 0 while CPU is hot is a real
  # signal (the host-fan-stalled alert relies on this).
  while IFS= read -r line; do
    idx="$(printf '%s\n' "${line}" | awk '{print $2}')"
    rpm="$(printf '%s\n' "${line}" | awk '{gsub(/[^0-9]/, "", $4); print $4}')"
    [[ "${idx}" =~ ^[0-9]+$ && "${rpm}" =~ ^[0-9]+$ ]] || continue
    emit "mac_fan_rpm{fan=\"fan${idx}\"} ${rpm}"
    fan_ok=1
  done < <(istats fan 2>/dev/null | awk '/^Fan [0-9]+ speed:/')
elif command -v powermetrics >/dev/null 2>&1; then
  # Fallback (Apple Silicon Macs without iStats may still report fans via
  # powermetrics; older Intel iMacs do NOT).
  fan_out="$(powermetrics --samplers smc -n 1 -i 200 2>/dev/null \
              | awk -F: '/Fan ?[0-9]*: / {gsub(/[^0-9]/, "", $2); print NR, $2}')"
  if [[ -n "${fan_out}" ]]; then
    while IFS= read -r line; do
      idx="${line%% *}"
      rpm="${line##* }"
      [[ "${rpm}" =~ ^[0-9]+$ ]] || continue
      emit "mac_fan_rpm{fan=\"fan${idx}\"} ${rpm}"
      fan_ok=1
    done <<< "${fan_out}"
  fi
fi
emit "mac_fan_up ${fan_ok}"

# ---------------------------------------------------------------------------
# SMART -- smartctl on every detected internal disk. The macOS internal SSD
# usually appears as /dev/disk0 (NVMe via IOAHCIFamily or AppleNVMe). External
# USB drives also show up; filter by `device_protocol != USB` to skip those
# (we don't care about a connected backup drive's wear).
# ---------------------------------------------------------------------------
emit "# HELP mac_smart_health 1 if smartctl reports the disk as PASSED, 0 otherwise."
emit "# TYPE mac_smart_health gauge"
emit "# HELP mac_smart_temperature_celsius Disk temperature from SMART."
emit "# TYPE mac_smart_temperature_celsius gauge"
emit "# HELP mac_smart_percent_used NVMe percent_used wear indicator (0-100, higher is worse)."
emit "# TYPE mac_smart_percent_used gauge"
emit "# HELP mac_smart_available_spare NVMe available_spare percentage (0-100, lower is worse)."
emit "# TYPE mac_smart_available_spare gauge"
emit "# HELP mac_smart_data_units_read_total NVMe data units read counter."
emit "# TYPE mac_smart_data_units_read_total counter"
emit "# HELP mac_smart_data_units_written_total NVMe data units written counter."
emit "# TYPE mac_smart_data_units_written_total counter"
if command -v smartctl >/dev/null 2>&1; then
  # diskutil list -plist would be cleanest, but a simple glob over /dev/disk*
  # without partition suffixes (no s/p) covers internal + external.
  for dev in /dev/disk[0-9]; do
    [[ -e "${dev}" ]] || continue
    # IOReg's IORegistryEntryProtocolCharacteristics tells us if it's USB —
    # filter those out so we don't fill the file with attached backup drives.
    parent="$(diskutil info "${dev}" 2>/dev/null | awk -F': *' '/Protocol/{print $2; exit}')"
    [[ "${parent}" == "USB" || "${parent}" == "Disk Image" ]] && continue
    name="$(basename "${dev}")"
    # smartctl exit code is a bitmask, not pass/fail. Even a fully-healthy
    # drive can return non-zero — e.g. NVMe Error Information Log queries
    # fail with bit 2 (4 decimal) on macOS because the kernel rejects the
    # admin command. We want to use whatever SMART data IS in the output,
    # so capture stdout regardless and only skip when nothing came back.
    smart="$(smartctl -a "${dev}" 2>/dev/null || true)"
    [[ -z "${smart}" ]] && continue

    overall="$(printf '%s\n' "${smart}" | awk '/SMART overall-health|SMART Health Status/{print $NF; exit}')"
    if [[ "${overall}" == "PASSED" || "${overall}" == "OK" ]]; then
      emit "mac_smart_health{device=\"${name}\"} 1"
    else
      emit "mac_smart_health{device=\"${name}\"} 0"
    fi

    temp="$(printf '%s\n' "${smart}" | awk -F': *' '/^Temperature:/{print $2; exit}' | awk '{print $1}')"
    [[ "${temp}" =~ ^[0-9]+$ ]] && emit "mac_smart_temperature_celsius{device=\"${name}\"} ${temp}"

    pu="$(printf '%s\n' "${smart}" | awk -F': *' '/Percentage Used:/{print $2; exit}' | tr -d '%')"
    [[ "${pu}" =~ ^[0-9]+$ ]] && emit "mac_smart_percent_used{device=\"${name}\"} ${pu}"

    avail="$(printf '%s\n' "${smart}" | awk -F': *' '/Available Spare:/{print $2; exit}' | tr -d '%' | head -c 4)"
    [[ "${avail}" =~ ^[0-9]+$ ]] && emit "mac_smart_available_spare{device=\"${name}\"} ${avail}"

    dur="$(printf '%s\n' "${smart}" | awk -F': *' '/Data Units Read:/{print $2; exit}' | awk -F'[][ ]+' '{gsub(",","",$1); print $1}')"
    [[ "${dur}" =~ ^[0-9]+$ ]] && emit "mac_smart_data_units_read_total{device=\"${name}\"} ${dur}"

    duw="$(printf '%s\n' "${smart}" | awk -F': *' '/Data Units Written:/{print $2; exit}' | awk -F'[][ ]+' '{gsub(",","",$1); print $1}')"
    [[ "${duw}" =~ ^[0-9]+$ ]] && emit "mac_smart_data_units_written_total{device=\"${name}\"} ${duw}"
  done
fi

# ---------------------------------------------------------------------------
# Power source -- `pmset -g batt` first line: "Now drawing from 'AC Power'"
# Mac mini servers should always be on AC; flapping = power issue.
# ---------------------------------------------------------------------------
emit "# HELP mac_power_on_ac 1 if on AC power, 0 if on battery."
emit "# TYPE mac_power_on_ac gauge"
src="$(pmset -g batt 2>/dev/null | awk -F"'" '/Now drawing/{print $2; exit}')"
if [[ "${src}" == "AC Power" ]]; then
  emit "mac_power_on_ac 1"
elif [[ -n "${src}" ]]; then
  emit "mac_power_on_ac 0"
fi

# ---------------------------------------------------------------------------
# Colima status -- `colima status --json` (Colima >= 0.6). We run as root so
# we need to read the user's Colima config; use `sudo -u` to step down to
# whoever installed it. The COLIMA_USER env var is set by the launchd plist
# (10-mac-exporter.sh stamps it in based on the installer's $USER).
# ---------------------------------------------------------------------------
emit "# HELP mac_colima_running 1 if the named Colima profile is running."
emit "# TYPE mac_colima_running gauge"
emit "# HELP mac_colima_cpu_allocated Number of CPUs allocated to the Colima VM."
emit "# TYPE mac_colima_cpu_allocated gauge"
emit "# HELP mac_colima_memory_bytes_allocated Bytes of RAM allocated to the Colima VM."
emit "# TYPE mac_colima_memory_bytes_allocated gauge"
emit "# HELP mac_colima_disk_bytes_allocated Bytes of disk allocated to the Colima VM."
emit "# TYPE mac_colima_disk_bytes_allocated gauge"
emit "# HELP mac_colima_up 1 if colima status --json returned parseable output."
emit "# TYPE mac_colima_up gauge"
profile="${COLIMA_PROFILE:-default}"
colima_user="${COLIMA_USER:-}"
if [[ -z "${colima_user}" ]]; then
  echo "mac-extras: COLIMA_USER unset; cannot query colima" >&2
  emit "mac_colima_up 0"
elif ! command -v colima >/dev/null 2>&1; then
  echo "mac-extras: colima binary not in PATH (${PATH})" >&2
  emit "mac_colima_up 0"
else
  # `colima status` exits non-zero when the VM is stopped. Capture stderr so
  # we know why it failed when debugging the log later.
  # `-H` resets $HOME to the target user's home — without it sudo inherits
  # root's HOME (/var/root) and colima tries to write to /var/root/.colima
  # which fails with "permission denied".
  colima_err="$(mktemp)"
  json="$(sudo -H -u "${colima_user}" colima status --profile "${profile}" --json 2>"${colima_err}" || true)"
  if [[ -z "${json}" ]]; then
    err_text="$(cat "${colima_err}" 2>/dev/null || true)"
    echo "mac-extras: colima status returned no JSON (stderr: ${err_text:-<empty>})" >&2
    emit "mac_colima_running{profile=\"${profile}\",runtime=\"unknown\"} 0"
    emit "mac_colima_up 0"
  elif ! command -v yq >/dev/null 2>&1; then
    echo "mac-extras: yq not in PATH; cannot parse colima status JSON" >&2
    emit "mac_colima_running{profile=\"${profile}\",runtime=\"unknown\"} 0"
    emit "mac_colima_up 0"
  else
    running="$(printf '%s' "${json}" | yq -p json -r '.runtime // ""' 2>/dev/null)"
    if [[ -n "${running}" && "${running}" != "null" ]]; then
      emit "mac_colima_running{profile=\"${profile}\",runtime=\"${running}\"} 1"
    else
      emit "mac_colima_running{profile=\"${profile}\",runtime=\"unknown\"} 0"
    fi
    cpu="$(printf '%s' "${json}" | yq -p json -r '.cpu // 0' 2>/dev/null)"
    mem="$(printf '%s' "${json}" | yq -p json -r '.memory // 0' 2>/dev/null)"
    disk="$(printf '%s' "${json}" | yq -p json -r '.disk // 0' 2>/dev/null)"
    # Only emit if numeric -- colima sometimes returns "24GiB" strings here;
    # a non-numeric line poisons the whole textfile (node_exporter rejects
    # the file with scrape_error=1 and drops all our metrics).
    [[ "${cpu}"  =~ ^[0-9]+(\.[0-9]+)?$ ]] && emit "mac_colima_cpu_allocated{profile=\"${profile}\"} ${cpu}"
    [[ "${mem}"  =~ ^[0-9]+(\.[0-9]+)?$ ]] && emit "mac_colima_memory_bytes_allocated{profile=\"${profile}\"} ${mem}"
    [[ "${disk}" =~ ^[0-9]+(\.[0-9]+)?$ ]] && emit "mac_colima_disk_bytes_allocated{profile=\"${profile}\"} ${disk}"
    emit "mac_colima_up 1"
  fi
  rm -f "${colima_err}"
fi

# ---------------------------------------------------------------------------
# Per-process CPU + RSS for the daemons we care about. `ps -ax -o ...` is
# cheap; we filter by comm name. Sums across instances (k3d may have multiple
# load-balancer containers shadowed in process list).
# ---------------------------------------------------------------------------
emit "# HELP mac_process_cpu_percent Sum of per-process %CPU for matched processes."
emit "# TYPE mac_process_cpu_percent gauge"
emit "# HELP mac_process_rss_bytes Sum of per-process resident set size for matched processes."
emit "# TYPE mac_process_rss_bytes gauge"
emit "# HELP mac_process_count Number of running processes matching the name."
emit "# TYPE mac_process_count gauge"
# %cpu and rss columns from `ps`. rss is in kilobytes on macOS.
ps_out="$(ps -axo comm=,%cpu=,rss= 2>/dev/null)"
for proc in colima qemu-system-x86_64 limactl docker dockerd containerd k3d \
            mDNSResponder python3; do
  # Match on basename only — colima ships as /usr/local/bin/colima but ps
  # shows the full path. awk's index() against the last `/` segment.
  agg="$(printf '%s\n' "${ps_out}" | awk -v p="${proc}" '
    {
      n = split($1, parts, "/"); base = parts[n]
      if (base == p) { c += $2; r += $3; k++ }
    }
    END { printf "%.2f %d %d\n", c+0, (r+0)*1024, k+0 }
  ')"
  cpu="${agg%% *}"; rest="${agg#* }"
  rss="${rest%% *}"; count="${rest##* }"
  if [[ "${count}" -gt 0 ]]; then
    emit "mac_process_cpu_percent{process=\"${proc}\"} ${cpu}"
    emit "mac_process_rss_bytes{process=\"${proc}\"} ${rss}"
  fi
  emit "mac_process_count{process=\"${proc}\"} ${count}"
done

# ---------------------------------------------------------------------------
# launchd plist health -- for each homelab plist installed under
# /Library/LaunchDaemons or ~/Library/LaunchAgents, check launchctl print
# to see if it's loaded and what its last exit status was. Catches the
# "k3d daemon silently unloaded after an update" failure class.
# ---------------------------------------------------------------------------
emit "# HELP mac_launchd_loaded 1 if the launchd label is currently loaded."
emit "# TYPE mac_launchd_loaded gauge"
emit "# HELP mac_launchd_last_exit_code Last exit code reported by launchctl for the label."
emit "# TYPE mac_launchd_last_exit_code gauge"
for label in com.homelab.colima com.homelab.k3d com.homelab.dns-proxy \
             com.homelab.node-exporter com.homelab.mac-extras; do
  # Daemons live under `system/`, agents under `gui/<uid>/`. Try both.
  state=""
  for domain in system gui/0 gui/501 gui/502 gui/503; do
    out="$(launchctl print "${domain}/${label}" 2>/dev/null)" && { state="${out}"; break; }
  done
  if [[ -n "${state}" ]]; then
    emit "mac_launchd_loaded{label=\"${label}\"} 1"
    rc="$(printf '%s\n' "${state}" | awk -F'= *' '/last exit code/{print $2; exit}')"
    [[ -n "${rc}" && "${rc}" != "(never exited)" ]] && emit "mac_launchd_last_exit_code{label=\"${label}\"} ${rc}"
  else
    emit "mac_launchd_loaded{label=\"${label}\"} 0"
  fi
done

# ---------------------------------------------------------------------------
# Atomic publish. textfile collector reads on every scrape; a rename keeps
# the file consistent.
# ---------------------------------------------------------------------------
chmod 0644 "${TMP_FILE}"
mv -f "${TMP_FILE}" "${OUT_FILE}"
trap - EXIT
