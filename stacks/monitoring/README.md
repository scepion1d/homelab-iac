# stacks/monitoring/

Prometheus + Grafana + MikroTik exporter.

## Services

| Service | Image | Ports (host) |
|---|---|---|
| `prometheus` | `prom/prometheus:v3.7.5` | `:9090` |
| `grafana` | `grafana/grafana:11.7.0` | `:3001` (3000 collides with AdGuard wizard) |
| `mikrotik-exporter` | `ghcr.io/akpw/mktxp:1.2.17` | internal only (scraped via `homelab` net) |

Both UIs front-by Caddy on `https://grafana.int` / `https://prometheus.int`.

## Scrape targets

Prometheus reaches the dns stack via the shared `homelab` external
network (resolves `homelab-dns-adguard-exporter`, `homelab-dns-unbound-exporter`).
Host node-exporter is reached via `host.docker.internal:9100`.

## Layout

```
stacks/monitoring/
├── compose.yaml
├── prometheus/
│   ├── prometheus.yml
│   └── rules/                     # (empty; alerts live in grafana provisioning)
├── grafana/
│   ├── provisioning/
│   │   ├── datasources/datasources.yaml
│   │   ├── dashboards/providers.yaml
│   │   └── alerting/              # FLAT — Grafana does NOT recurse here
│   │       ├── contact-points.yaml
│   │       ├── policies.yaml
│   │       ├── templates.yaml
│   │       ├── mute-timings.yaml
│   │       ├── inhibit-rules.yaml
│   │       ├── dns-rules.yaml     # AdGuard + Unbound groups → folder: DNS
│   │       ├── host-rules.yaml    # → folder: infra
│   │       └── router-rules.yaml  # → folder: infra
│   └── dashboards/                # foldersFromFilesStructure=true
│       ├── homelab.json           # root (no folder) — pinned as Grafana home
│       ├── infra/                 # → UI folder "infra"
│       │   ├── host.json
│       │   └── router.json
│       └── DNS/                   # → UI folder "DNS"
│           ├── adguard.json
│           ├── dns-overview.json
│           └── unbound.json
├── mktxp/
│   ├── _mktxp.conf                # daemon-wide
│   └── mktxp.conf                 # per-router (references credentials.yaml)
└── ansible/setup.yml              # renders mktxp credentials.yaml from .env
```

## Credentials

`stacks/monitoring/ansible/setup.yml` reads `MIKROTIK_USER` + `MIKROTIK_PASSWORD`
from `.env` and writes `${DATA_ROOT}/monitoring/mktxp/credentials.yaml`.
Volume-mounted into the mktxp container at `/etc/mktxp/credentials.yaml`.

Grafana admin password from `GRAFANA_ADMIN_PASSWORD`, Slack alerting
bot token from `GRAFANA_SLACK_BOT_TOKEN` — both passed as env vars to
the container.

## Provisioning

- **Datasources**: Prometheus auto-registered as default.
- **Dashboards**: file provider scans `/var/lib/grafana/dashboards/**`.
  With `foldersFromFilesStructure: true`, the parent directory of each
  JSON becomes its Grafana UI folder; files at the root of
  `dashboards/` (currently just `homelab.json`) live in the "General"
  folder. The homelab overview is pinned as the default home page via
  `GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH` in compose.yaml.
- **Alerts**: native Grafana provisioning. Contact points, policies,
  templates, mute timings, inhibit rules, and rule groups all loaded
  from `grafana/provisioning/alerting/*.yaml`. **All files must live
  at the top of `alerting/`** — Grafana's alerting provisioner does
  NOT recurse into subdirectories (it logs `"file has invalid suffix
  'rules' (.yaml,.yml,.json accepted), skipping"` and drops them).
  Each rule group's `folder:` field controls the UI alerts folder
  (kept in sync with the dashboard folder names: `DNS` / `infra`).

## What's NOT here

- Loki / logs aggregation — out of scope for v2 baseline.
- Home Assistant scrape — comes with the smart-home stack.
- argocd-removed dashboards / alerts — pruned.
