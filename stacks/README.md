# stacks/ — docker compose stacks

Each subdirectory is one independently-deployable Docker Compose project
running inside the Colima VM. Ansible (`ansible/roles/compose-stack`)
brings each stack to its desired state on every reconcile.

## Conventions

- **One concern per stack.** Stacks must not share state with each other.
  Cross-stack communication only via published ports or shared external
  networks (see `networks.yaml`).
- **Stack layout:**
  ```
  stacks/<name>/
    compose.yaml         # main compose file
    <service>/           # per-service config, scripts, sidecar Dockerfiles
    README.md            # what's in here, how it talks to the rest
  ```
- **Persistent data:** named volumes (preferred) or bind mounts under
  `${DATA_ROOT}/<stack>/<service>`. Never bind-mount into the repo.
- **Configs:** templated by Ansible from this repo into the data root
  before `compose up`. Source files live next to the service that uses
  them; Ansible never edits them in place.
- **Metrics:** services that expose Prometheus metrics declare a label
  `homelab.metrics.port=<port>` on the container. The monitoring stack's
  prometheus.yml is generated from these labels at reconcile time.
- **Ingress:** services that need HTTPS through Caddy declare
  `homelab.caddy.host=<subdomain>` and `homelab.caddy.port=<port>`.
  The host-side Caddyfile is regenerated from these labels.

## Stacks

| Stack | Purpose |
|---|---|
| [dns/](dns/) | AdGuard (filtering) + Unbound (recursive) + exporters + cache dumper |
| [monitoring/](monitoring/) | Prometheus + Grafana + MikroTik exporter |
| [smart-home/](smart-home/) | Home Assistant + mDNS reflector (VM side) |

## Networks

See [networks.yaml](networks.yaml) for the shared external network
definitions. All stacks attach to `homelab` (LAN-routable via Colima
vmnet); back-end-only services use the per-stack default network.
