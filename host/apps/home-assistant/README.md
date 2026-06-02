# home-assistant

Home Assistant Container running directly on the host (Colima Docker), not
inside k3d. Lives on the host because:

- **mDNS / HomeKit pairing.** HA's HomeKit Bridge advertises virtual
  accessories via mDNS so Apple TV (acting as HomeKit hub) can discover
  and pair. NATed k3d networking can't deliver multicast cleanly.
- **LAN-side device discovery.** Any future Wi-Fi integration (Shelly,
  Sonos, Cast) needs broadcast reach on the home subnet.

Stub-only setup: virtual `input_boolean` / `input_number` / `input_select`
entities exposed to Apple Home as switches and sensors. No physical
device passthrough; the Aqara M3 talks to Apple Home directly (HA is not
in that path).

## URLs

- LAN (friendly): `https://homeassistant.int` — fronted by nginx-ingress
  in cluster/apps/home-assistant-ingress, terminates TLS with the same
  cert-manager issuer as grafana/prometheus/adguard.
- LAN (direct, for debugging or if cluster is down): `http://<host LAN IP>:8123`.
- Mobile app pairing: uses mDNS, bypasses both ingress and DNS — works
  as long as `network_mode: host` stays set in compose.yaml.

DNS setup on MikroTik:

```
/ip dns static add name=homeassistant.int address=<cluster ingress IP> ttl=1h
```

The cluster ingress IP is the same one your grafana.int / prometheus.int /
adguard.int records already point at (k3d port-forwards nginx-ingress to
the host's 80/443, so for a single-host setup the cluster ingress IP is
the host LAN IP).

## Bootstrap

```sh
./bootstrap/09-host-apps.sh home-assistant
./bootstrap/11-mdns-reflector.sh   # required for Apple TV / HomeKit discovery
```

First run brings the container up. Open the URL above, finish the
first-time setup wizard (create owner account), then proceed to the
Prometheus token step below.

### HomeKit reachability across VLANs

Apple Home discovery requires three non-obvious pieces of plumbing, all
handled by the repo but worth knowing for debugging:

1. **L3: iot -> int:21063 must be open.** Apple TV (iot VLAN) opens HAP
   TCP to HA on the server (int VLAN). MikroTik forward rule
   `iac.fw.filter.forward.15` accepts this single host:port (see
   `mikrotik-iac/src/segmented/40-firewall.yaml`).
2. **mDNS hop 1 (in-VM): eth0 -> col0.** HA's HomeKit Bridge broadcasts
   `_hap._tcp` on the VM's `eth0` (192.168.5.x, user-mode NAT) because
   eth0 has a lower routing metric than the vmnet `col0`. Those frames
   never cross to col0 on their own. The `host/apps/mdns-reflector`
   compose stack runs a small reflector inside the VM that browses on
   eth0 and re-publishes on col0.
3. **mDNS hop 2 (Mac-side): bridge100 -> en0/en1.** macOS does NOT
   relay multicast between the vmnet bridge (Mac end of col0) and the
   physical LAN interface. `bootstrap/11-mdns-reflector.sh` installs a
   LaunchDaemon that browses on `bridge100` and re-publishes on the
   Mac's LAN interface, rewriting the A record to the Mac's LAN IP
   (192.168.10.3). MikroTik's `mdns-repeat-ifaces` then relays from
   int to iot, and Apple TV finally sees the bridge.

`advertise_ip: 192.168.10.3` in `config/homekit.yaml` ensures the SRV
target ultimately resolves to the Mac's LAN IP so Apple TV connects
back to a host it can actually reach (Colima's auto-tunnel forwards
`<mac-lan-ip>:21063` into the VM to HA).

Debug the chain in order:

```sh
# Hop 1: in-VM reflector is publishing?
colima ssh -- docker logs homelab-mdns-reflector --tail 20

# Hop 2: Mac reflector is publishing?
sudo tail /var/log/homelab-mdns-reflector.log

# End-to-end (run from any non-Mac LAN device, e.g. an iPhone with
# the free "Discovery - DNS-SD Browser" app):
#   _hap._tcp shows a "Home Lab ..." entry
```

## Prometheus scrape token (two-pass setup)

HA's `/api/prometheus` endpoint requires a long-lived access token.
There is no way to seed it before HA's user database exists, so the
flow is two-pass:

1. **Pass 1 (this script does this):** bring HA up.
2. **You, manually:**
   - Open `https://homeassistant.int` (or the direct IP if the ingress
     app hasn't synced yet), create the owner account.
   - Go to your user profile -> Security -> Long-Lived Access Tokens.
   - Click "Create Token", give it a name like `prometheus-scrape`,
     copy the value (shown once only).
   - Paste it into `bootstrap/.env` as
     `HOMEASSISTANT_PROMETHEUS_TOKEN=...`.
3. **Pass 2 (you run this):**
   ```sh
   ./bootstrap/06-cluster-secrets.sh
   ```
   Creates Secret `monitoring/home-assistant-prometheus-token`. Prometheus
   picks it up via `extraSecretMounts` and starts scraping HA on the next
   reload (15-30s).

   Note: the scrape goes **direct** to `${HOST_IP}:8123`, not through the
   ingress — keeps the scrape path simple and low-latency, no nginx hop.

4. **Wire the mount into Prometheus.** Open
   `cluster/apps/prometheus/_appset.yaml` and add the following under
   `server.scrapeConfigFiles:` (keep 8-space indent so it sits as a
   sibling of `scrapeConfigFiles`, not nested inside it):

   ```yaml
           extraSecretMounts:
             - name: home-assistant-prometheus-token
               mountPath: /etc/secrets/home-assistant-token
               subPath: token
               secretName: home-assistant-prometheus-token
               readOnly: true
   ```

   Commit + push. The pre-commit hook auto-bumps the prometheus
   `revision:`. Argo CD picks up the change on its next sync; Prometheus
   pod restarts with the mount and the scrape job starts succeeding.

   The mount is gated behind this manual step because k8s blocks pod
   start if a referenced Secret is missing — keeping the mount out of
   the default file lets a fresh cluster bootstrap cleanly before HA
   exists.

## Stub entities for HomeKit

`config/configuration.yaml` declares a starter set of `input_boolean` and
`input_number` helpers (Guest Mode, Vacation Mode, Night Mode, Ambient
Brightness). `config/homekit.yaml` exposes them to Apple HomeKit via HA's
HomeKit Bridge integration (port 21063). Pair by scanning the QR code in
HA UI: Settings -> Devices & Services -> HomeKit Bridge.

Add more helpers either by editing `configuration.yaml` and re-running
the reconciler with `--recopy-config`, or by using HA's UI helpers
(Settings -> Devices & Services -> Helpers); UI-created helpers live in
`.storage/` and are not managed by this repo.

```sh
./bootstrap/09-host-apps.sh home-assistant --recopy-config
# Then in HA UI: Developer Tools -> YAML -> Reload All YAML Configuration
```

## What's managed vs not managed

`config/.managed-by-homelab-iac` lists files the bootstrap owns and will
re-copy. Anything not listed (notably `automations.yaml`, `scenes.yaml`,
`scripts.yaml`, and the entire `.storage/` tree) is left alone so
UI-edited automations survive reconciles.

## Backup

Everything HA cares about lives under `~/homelab-data/home-assistant/`.
That includes the HomeKit pairing keys in `.storage/` -- losing them
means re-pairing every accessory with Apple Home. Back up the whole
tree the same way you back up the rest of `~/homelab-data/`.
