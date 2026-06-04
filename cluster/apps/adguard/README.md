# adguard

[AdGuard Home](https://github.com/AdguardTeam/AdGuardHome) — LAN-wide
DNS resolver with ad/tracker blocking, DoH/DoT upstream, per-client
rules, and a web UI.

```
LAN client ──UDP/TCP 53──► Mac:53 ──► k3d serverlb ──► node:53
                                                         └─► adguard pod
                                                                  │
                                                                  ▼
                                                     DoH/DoT to Cloudflare / Quad9
```

## One-time setup

### 1. k3d must publish :53

Adding port 53 to a running k3d cluster requires recreation **or** a
live edit (k3d ≥ 5.4). Try the live edit first:

```bash
k3d cluster edit homelab \
  --port-add "53:53/udp@loadbalancer" \
  --port-add "53:53/tcp@loadbalancer"
```

If your k3d is too old:

```bash
./bootstrap/teardown.sh
./bootstrap/bootstrap.sh
```

Verify the serverlb is listening on the host:

```bash
docker port k3d-homelab-serverlb | grep 53
# 53/udp -> 0.0.0.0:53
# 53/tcp -> 0.0.0.0:53
```

> macOS firewall must allow inbound on 53/udp and 53/tcp.
> System Preferences → Network → Firewall → Options → add `colima`.

### 2. Run the AdGuard first-run wizard

After Argo CD syncs the app, the wizard is reachable on the pod's
:3000. Port-forward once:

```bash
kubectl -n dns port-forward svc/adguard-ui 3000:3000
```

Open <http://localhost:3000> and click through:

- **Admin interface listen**: `0.0.0.0:80`
- **DNS server listen**:      `0.0.0.0:53`
- **Admin user / password**: pick something strong; AdGuard bcrypts it
  and stores it in the PVC, NOT in this repo.

Once done, AdGuard restarts; the UI moves to :80 and is reachable
through the ingress at <https://adguard.int> /  <https://adguard.localhost>.

### 3. Configure upstream DNS

Codified in [`dns-config.yaml`](dns-config.yaml) and pushed automatically
by `bootstrap/07-adguard-setup.sh` after the wizard succeeds:

```text
[/int/]192.168.10.1                       # MikroTik holds *.int static records
https://dns.cloudflare.com/dns-query      # public DoH
https://dns.quad9.net/dns-query
```

Bootstrap DNS (used only to resolve the DoH hostnames at startup):

```text
1.1.1.1
9.9.9.9
```

To change upstreams, edit `dns-config.yaml`, commit, and re-run
`./bootstrap/07-adguard-setup.sh`. UI edits work too but won't survive
a PVC wipe.

### 4. Enable blocklists

Codified in [`blocklists.yaml`](blocklists.yaml) and pushed automatically
by `bootstrap/07-adguard-setup.sh` via `/control/filtering/add_url`
(idempotent — already-present URLs are skipped).

Default set:
- AdGuard DNS filter, AdAway Default Blocklist  (lightweight starters)
- HaGeZi's Pro++, OISD Big, HaGeZi's Gambling, HaGeZi's Badware Hoster
  (heavier multi-category protection)
- uBlock badware risks, URLHaus, Stalkerware Indicators, Phishing Army
  (targeted security)

URLs point at the [AdGuard HostlistsRegistry](https://github.com/AdguardTeam/HostlistsRegistry)
mirror so they stay stable across upstream re-organisations. To change
the set, edit `blocklists.yaml`, commit, and re-run
`./bootstrap/07-adguard-setup.sh`. UI removals are honoured because
step 07 only adds — never prunes.

### 5. Point the LAN at AdGuard via MikroTik DHCP

On the router (Winbox terminal or SSH):

```routeros
# Primary DNS = Mac (AdGuard), secondary = router itself (fallback when k3d is down).
/ip dhcp-server network set [find] dns-server=192.168.10.3,192.168.10.1
```

Replace `192.168.10.3` with the Mac's LAN IP, `192.168.10.1` with the
router's. Existing leases keep their old DNS until renewal — force a
renew on the client or `release` on the router:

```routeros
/ip dhcp-server lease print
/ip dhcp-server lease remove [find]   # nuclear: re-leases everyone
```

## Verifying

From a LAN client:

```bash
# Should answer from 192.168.10.3, and the .int hosts should still resolve
# (forwarded back to the router).
dig @192.168.10.3 grafana.int +short
dig @192.168.10.3 cloudflare.com +short

# Blocking sanity check — should return 0.0.0.0 if a default blocklist is on.
dig @192.168.10.3 doubleclick.net +short
```

In the AdGuard UI: Query log shows live queries with the real client
IP (because the Service uses `externalTrafficPolicy: Local`).

## Fallback / failure modes

- **k3d down** → clients fall back to MikroTik (secondary DNS). `.int`
  hosts still resolve; public lookups go via the router's own DNS.
- **AdGuard pod restart** → ~10s outage on primary DNS; clients usually
  retry on the secondary without users noticing.
- **PVC lost** → re-run the wizard. No secrets in git, nothing else to
  recover — blocklists are URLs, not data.

## Operations

```bash
# Logs
kubectl -n dns logs -f deploy/adguard

# Live config (don't hand-edit unless you know what you're doing — the
# UI rewrites this file on every save).
kubectl -n dns exec deploy/adguard -- cat /opt/adguardhome/conf/AdGuardHome.yaml

# Reset everything (wizard runs again on next deploy):
kubectl -n dns delete pvc adguard-data
argocd app sync adguard
```

## Notes on `externalTrafficPolicy: Local`

We need the real client IP for per-client rules and meaningful query
logs. The trade-off: the LoadBalancer only routes to nodes that have
a pod running, so if `replicas: 1` and the pod's node is unhealthy,
traffic is dropped on the other nodes. Acceptable here — single-replica
DNS resolver with no HA story.
