# unbound

Recursive DNS resolver sitting behind AdGuard.

```
client ─▶ AdGuard (filter + final-answer cache)
              │
              ├─ "*.int"  ─▶ MikroTik (192.168.10.1)  ← LAN static records
              │
              └─ everything else
                    │
                    ▼
                Unbound (this app)
                    │
                    ├─ in-cluster cache hit ─▶ answer (~1 ms)
                    │
                    └─ cache miss ─▶ recursive walk
                                       root NS → TLD NS → authoritative
                                       → cache + return (~50–200 ms cold)
```

## Why this exists

AdGuard was forwarding every cache miss to a fixed list of public
resolvers (1.1.1.1, 8.8.8.8, 9.9.9.9). That model has three problems
this app addresses:

1. **Single-party visibility.** One upstream saw every domain we ever
   resolved. With recursion, each authoritative server learns only the
   names in its own zone.
2. **Single PoP bottleneck.** A degraded upstream PoP dragged every
   uncached lookup until AdGuard's load balancer noticed. Recursive
   resolution distributes queries across hundreds of independent
   auth servers.
3. **No local DNSSEC validation.** We trusted upstream resolvers to
   validate; with Unbound's `validator` module we validate ourselves.

## What it doesn't do

- **No CDN-aware forwarding.** A pure recursive resolver may pick
  a worse geographic PoP for Netflix / YouTube / Cloudflare than a
  global resolver with EDNS Client Subnet would. We accepted this
  trade-off and will revisit if monitoring shows real impact.
- **No filtering / blocking.** That's AdGuard's job. Unbound's job
  is just to answer "what is this name actually?".

## Configuration

[`unbound.conf`](unbound.conf) is the single source of truth. Edit +
commit + push:

1. Kustomize hashes the file into a generated ConfigMap name.
2. Argo CD sees the ConfigMap hash changed → updates the Deployment's
   volume reference.
3. Pod restarts with the new config.

No manual `kubectl rollout restart` needed.

Key knobs (see comments in `unbound.conf` for the full list):

| Setting | Value | Why |
|---|---|---|
| `msg-cache-size` | 64m | Final-answer cache |
| `rrset-cache-size` | 128m | Per-record cache; serves AdGuard restarts hot |
| `num-threads` | 2 | Two threads with `so-reuseport` for balanced load |
| `qname-minimisation` | yes | Auth servers see only their own zone names |
| `aggressive-nsec` | yes | NXDOMAIN answers cached at NS level |
| `prefetch` / `serve-expired` | yes | No client-visible stalls on TTL boundaries |
| `auto-trust-anchor-file` | yes (init container) | DNSSEC validation enabled |

## Operations

```sh
# Logs (verbosity: 1 by default -- errors + SERVFAIL only)
kubectl -n dns logs deploy/unbound -f

# Live stats via unbound-control on loopback
kubectl -n dns exec deploy/unbound -- unbound-control stats_noreset

# Force a cache flush (e.g. after a registrar change you can't wait for)
kubectl -n dns exec deploy/unbound -- unbound-control flush_zone example.com

# Reload config without restarting (if you want to skip the pod roll)
kubectl -n dns exec deploy/unbound -- unbound-control reload
```

## Removing Unbound (rollback)

If you want to go back to AdGuard talking directly to public resolvers:

1. Edit [`cluster/apps/adguard/dns-config.yaml`](../adguard/dns-config.yaml):
   replace the `unbound-dns...` upstream with the old anycast IPs
   (1.1.1.1, 8.8.8.8, 9.9.9.9).
2. Re-run `./bootstrap/07-adguard-setup.sh` to push the change.
3. Delete this app from cluster/apps/ + commit; Argo CD removes the
   Deployment / Service / ConfigMap.

The DNS path stays working throughout — AdGuard reloads the upstream
list before Argo CD touches Unbound.
