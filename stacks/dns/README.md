# stacks/dns/

AdGuard (DNS filter) → Unbound (recursive resolver, DNSSEC off in v1
carry-over) → upstream auth. Exporters scrape both. A sidecar persists
Unbound's cache across restarts.

## Layout

```
stacks/dns/
├── compose.yaml
├── unbound/
│   ├── unbound.conf              # carry-over from v1 (commit 4c7a83e)
│   └── cache-dumper/
│       └── entrypoint.sh         # dump every 5 min, load + warm on startup
└── README.md
```

## Services

| Service | Image | Ports |
|---|---|---|
| `unbound` | mvance/unbound:1.22.0 | internal only |
| `unbound-cache-dumper` | mvance/unbound:1.22.0 | none — sidecar |
| `unbound-exporter` | letsencrypt/unbound_exporter | `:9167` on `homelab` net |
| `adguard` | adguard/adguardhome:latest | `:53` UDP/TCP host-published; `:80` `:3000` internal |
| `adguard-exporter` | henrywhitaker3/adguard-exporter | `:9618` on `homelab` net |

## Volumes (named, persist across compose down)

| Volume | Used by | Purpose |
|---|---|---|
| `homelab-dns-adguard-conf` | adguard | configuration (DNS settings, blocklists, users) |
| `homelab-dns-adguard-work` | adguard | query log, stats |
| `homelab-dns-unbound-ctl` | unbound + dumper + exporter | shared control socket |
| `homelab-dns-unbound-cache` | unbound-cache-dumper | persisted cache dump |

## Networking

- `unbound` and `unbound-cache-dumper` are on `internal` only — back-end.
- `adguard`, both exporters are on `homelab` (external network created by
  the compose-stack role) **and** `internal`. The exporters need
  `homelab` so prometheus (in another stack) can scrape them.
- `adguard` publishes :53 on the Colima VM IP. `${DNS_PORT}` defaults to
  53 for production, override to e.g. 5353 for parallel-with-v1 testing.

## Parallel-with-v1 test recipe

```bash
# In your shell (or in .env):
export DNS_PORT=5353

cd ~/src/homelab-iac
set -a; source .env; set +a
ansible-playbook ansible/reconcile.yml -e stack=dns

dig @192.168.10.3 -p 5353 example.com +short
docker logs homelab-dns-unbound | tail -30
docker logs homelab-dns-adguard | tail -30
```

When confident, set `DNS_PORT=53`, scale v1 AdGuard/Unbound to 0, and
reconcile again.

## AdGuard first-run configuration

On a fresh data volume, AdGuard opens its wizard on port 3000 instead of
serving on 80. The compose stack publishes only :53 externally, so the
wizard isn't directly reachable.

Easiest path: `docker exec -it homelab-dns-adguard sh` and run the
wizard from inside, or temporarily add `- "3000:3000"` to the adguard
ports list, complete the wizard via the browser, then revert.

A reconcile-time wizard auto-completer is a follow-up — see the v1
`bootstrap/steps/07-adguard-setup.sh` for the API shape.
