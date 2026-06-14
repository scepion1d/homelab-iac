#!/bin/sh
# Unbound cache persistence: dump every 5 min, load on startup.
# Run by the unbound-cache-dumper sidecar — see compose.yaml.

set -eu

log() { echo "$(date -u +%H:%M:%S) cache-dumper: $*"; }

CTL="unbound-control -c /opt/unbound/etc/unbound/unbound.conf"
CACHE_DIR=/var/cache/unbound
CACHE=$CACHE_DIR/dump.bin

mkdir -p "$CACHE_DIR"

# Wait for unbound to accept control commands. Sidecar's depends_on
# uses condition: service_healthy so we should be fine, but defensive.
log "waiting for unbound..."
i=0
while ! $CTL status >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -ge 30 ] && { log "unbound did not respond in 60s; bailing"; exit 1; }
  sleep 2
done
log "unbound ready"

# Load saved cache if a dump exists.
if [ -s "$CACHE" ]; then
  log "loading cache from $CACHE"
  if $CTL load_cache < "$CACHE" 2>&1 | head -5; then
    log "loaded"
  else
    log "load failed; continuing with empty cache"
  fi

  # Warm-up: re-query every cached A/AAAA/CNAME/MX/SRV/TXT name once so
  # entries that expired between dump and load get refreshed. NSEC3-
  # hashed names are filtered out to avoid flooding upstream with junk.
  WARM=$CACHE_DIR/warm.list
  grep -E '\sIN\s+(A|AAAA|CNAME|MX|SRV|TXT)\s' "$CACHE" 2>/dev/null \
    | awk '{print $1}' | sort -u > "$WARM" || true
  if [ -s "$WARM" ]; then
    count=$(wc -l < "$WARM" | tr -d ' ')
    log "warming up $count names (40 parallel)"
    n=0
    while IFS= read -r name; do
      unbound-host "$name" >/dev/null 2>&1 &
      n=$((n + 1))
      if [ "$n" -ge 40 ]; then wait; n=0; fi
    done < "$WARM"
    wait
    rm -f "$WARM"
    log "warm-up complete"
  fi
fi

# Periodic dump every 5 minutes. Atomic: tmp + mv.
dump() {
  log "dumping cache"
  if $CTL dump_cache > "${CACHE}.tmp" 2>/dev/null; then
    mv "${CACHE}.tmp" "$CACHE"
    log "dump ok ($(wc -c < "$CACHE" | tr -d ' ') bytes)"
  else
    log "dump failed; keeping previous"
    rm -f "${CACHE}.tmp"
  fi
}

trap 'dump; exit 0' TERM INT

while true; do
  sleep 300 &
  wait $!
  dump || true
done
