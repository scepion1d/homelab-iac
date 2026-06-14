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
│   │   └── alerting/
│   │       ├── contact-points.yaml
│   │       ├── policies.yaml
│   │       ├── templates.yaml
│   │       ├── mute-timings.yaml
│   │       ├── inhibit-rules.yaml
│   │       └── rules/             # per-domain alert YAMLs
│   └── dashboards/                # one folder per dashboard, single dashboard.json
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
- **Dashboards**: file provider scans `/var/lib/grafana/dashboards/*/dashboard.json`.
- **Alerts**: native Grafana provisioning. Contact points, policies,
  templates, mute timings, inhibit rules all loaded from
  `grafana/provisioning/alerting/*.yaml`.

## What's NOT here

- Loki / logs aggregation — out of scope for v2 baseline.
- Home Assistant scrape — comes with the smart-home stack.
- argocd-removed dashboards / alerts — pruned.
