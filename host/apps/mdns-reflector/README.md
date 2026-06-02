# mdns-reflector (VM-side hop)

In-VM mDNS reflector. Bridges multicast announcements between the two
network interfaces inside the Colima VM (`eth0` user-mode and `col0`
vmnet) so the Mac-side reflector can pick them up and forward them onto
the LAN.

This is half of a two-stage chain; see `host/apps/home-assistant/README.md`
under "HomeKit reachability across VLANs" for the full picture.

## Why it exists

Home Assistant runs with `network_mode: host` inside the VM. Its
HomeKit Bridge announces `_hap._tcp` via mDNS on the VM's default
network interface (`eth0`, 192.168.5.0/24 — user-mode NAT). Those
multicast frames never cross to `col0` (the vmnet side, 192.168.64.0/24)
on their own, so the Mac-side reflector — which listens on `bridge100`
(the Mac end of col0) — never sees them.

This container browses on the user-mode interface and re-publishes
matching services on the vmnet interface. The address rewrite in the
re-publication step bakes in `col0`'s IP, which lets the Mac-side
reflector see the service and chain another rewrite (this time to the
Mac's LAN IP).

## What it relays

Service types reflected: `_hap._tcp.local.` only (the HomeKit Accessory
Protocol). Extend by editing `MDNS_SERVICE_TYPES` in `compose.yaml`
(comma-separated, each entry must end with `.local.`).

## What it does NOT do

- Does not affect L3 reachability. HA is reachable from the iot VLAN
  because (a) Colima auto-tunnels host-network listeners so
  `<mac-lan-ip>:21063` reaches HA, and (b) MikroTik forward rule
  `iac.fw.filter.forward.15` allows iot → 192.168.10.3:21063.
- Does not relay traffic from any iot device back into the VM. Each
  reflector is one-way (browse on src, publish on dst).
- Does not handle IPv6. HomeKit on Apple devices works fine over v4 and
  adding v6 doubles the loop-prevention reasoning surface.

## Image

Uses the upstream `python:3.12-alpine` image with `zeroconf==0.132.2`
installed at container startup via `pip install`. No custom Dockerfile.
The reflector script itself is canonical at `bootstrap/mdns-reflector.py`
and bind-mounted in read-only — one source of truth shared with the
Mac-side LaunchDaemon.

## Env vars

| Var | Default | Purpose |
|---|---|---|
| `MDNS_VM_USERMODE_IP` | `192.168.5.1` | The VM's eth0 IP (source side) |
| `MDNS_VM_VMNET_IP`    | `192.168.64.3` | The VM's col0 IP (destination side) |

Set in `bootstrap/.env` if your Colima VM uses different addresses
(verify with `colima ssh -- ip -br addr`).

## Bootstrap

```sh
./bootstrap/09-host-apps.sh mdns-reflector
```

## Verify

From inside the VM:

```sh
colima ssh -- docker logs homelab-mdns-reflector --tail 20
```

Expect (after HA finishes its first re-announce cycle, ~30s):

```
INFO mdns-reflector: browsing ['_hap._tcp.local.'] on 192.168.5.1, publishing on 192.168.64.3
INFO mdns-reflector: ADD Home Lab XXXXXX._hap._tcp.local. -> 192.168.64.3:21063 (server=...-hap.local.)
```

From the Mac (after the Mac-side reflector picks up the chained ad):

```sh
sudo tail /var/log/homelab-mdns-reflector.log
```

Expect:

```
INFO mdns-reflector: ADD Home Lab XXXXXX._hap._tcp.local. -> 192.168.10.3:21063 (server=...-hap.local.)
```

From any LAN device (NOT the Mac, since macOS's own zeroconf doesn't
always loop back local publications to `dns-sd`):

```sh
dns-sd -B _hap._tcp
```

Expect a `Home Lab …` entry alongside whatever HomeKit hubs are
already on the LAN. Then on Apple TV: Settings → AirPlay & HomeKit →
Add Accessory.
