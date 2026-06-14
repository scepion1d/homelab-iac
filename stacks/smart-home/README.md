# stacks/smart-home/

Home Assistant + VM-side mDNS reflector.

Both run `network_mode: host` inside the Colima VM (mandatory for
HomeKit/mDNS to work). Neither joins the shared `homelab` docker
network — Prometheus scrapes HA via the VM's vmnet IP.

## Services

| Service | Image | Ports / interfaces |
|---|---|---|
| `home-assistant` | `ghcr.io/home-assistant/home-assistant:2026.5` | host net, :8123 (UI/API), :21063 (HomeKit Bridge) |
| `mdns-reflector` | `python:3.12-alpine` | host net, bridges UDP/5353 between VM eth0 ↔ col0 |

## Configs (managed by ansible)

`home-assistant/config/.managed-by-homelab-iac` lists which files
ansible re-copies on every reconcile. UI-edited files (automations,
scenes, integrations) are untouched.

- `configuration.yaml` — HA base config: name, TZ, http proxy trust, prometheus exporter
- `homekit.yaml` — HomeKit Bridge filter rules

## Data

| Path | Used by |
|---|---|
| `${DATA_ROOT}/smart-home/home-assistant/config` | HA state, sqlite DB, integrations, .storage (HomeKit pairings) |

## Ingress

Caddy snippet at `host/caddy/snippets/home-assistant.caddy` fronts
`https://homeassistant.int` → `192.168.64.2:8123`.

## Prometheus integration

HA exposes `/api/prometheus` with Bearer auth. Token from HA UI →
Profile → Long-Lived Access Tokens, set as
`HOMEASSISTANT_PROMETHEUS_TOKEN` in `.env`. The monitoring stack's
`prepare.yml` writes it into `${DATA_ROOT}/monitoring/prometheus/secrets/ha_token`
which prometheus.yml references via `credentials_file:`.

Without the token the scrape returns 401; first-run HA needs the
two-pass setup:

1. Bring HA up: `ansible-playbook ansible/reconcile.yml -e stack=smart-home`
2. Open `https://homeassistant.int`, create the owner account
3. Profile → Security → Long-Lived Access Tokens → Create
4. Paste into `.env` as `HOMEASSISTANT_PROMETHEUS_TOKEN=...`
5. Re-run reconcile (monitoring stack picks up the token)

## mDNS chain

```
HA (eth0 broadcasts) → stacks/smart-home/mdns-reflector → col0
   → host/services/mdns-reflector.py (LaunchDaemon) → en0
   → MikroTik mdns-repeat-ifaces → Apple TV (iot VLAN)
```

The VM-side reflector (this stack) and host-side reflector (LaunchDaemon
managed by `ansible/roles/host`) share one script: `bootstrap/services/mdns-reflector.py`.
