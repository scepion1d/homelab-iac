# v2 architecture

Single-VM Docker on macOS, Ansible-controlled, no Kubernetes.

```
┌─ macOS host (192.168.10.3) ──────────────────────────────────────┐
│                                                                  │
│  LaunchDaemons (host-native):                                    │
│    • node-exporter      :9100      (Prometheus scrape)           │
│    • mac-extras                    (textfile metrics)            │
│    • dns-proxy.py       :53        (LAN :53 → Colima VM :53)     │
│    • mdns-reflector.py             (LAN ↔ Colima mDNS bridge)    │
│    • caddy              :80/:443   (reverse proxy, TLS, *.int)   │
│    • ansible-reconcile             (every 5 min)                 │
│    • shutdown-hook                 (graceful shutdown)           │
│                                                                  │
│  Colima VM (Linux, vmnet-bridged):                               │
│    └─ Docker engine                                              │
│       ├─ stack: dns         (adguard, unbound, exporters)        │
│       ├─ stack: monitoring  (prometheus, grafana, mktxp)         │
│       └─ stack: smart-home  (home-assistant, mdns-reflector)     │
└──────────────────────────────────────────────────────────────────┘
```

## What changed vs v1

| Layer | v1 | v2 |
|---|---|---|
| Orchestrator | Kubernetes (k3d) + Argo CD | Ansible |
| Deploys | `git push` → Argo polls → kustomize | `ansible-playbook reconcile.yml` |
| Ingress | ingress-nginx + cert-manager + ClusterIssuer | Caddy (host) with internal CA |
| Service mesh | k8s ClusterIP svc DNS | docker compose network DNS |
| Storage | PVC + local-path | named volumes + bind mounts |
| App definition | Helm/kustomize manifests | docker compose |
| Config reload | configmap → pod rollout | template + `compose up -d` |

## What stayed the same

- macOS LaunchDaemons for host-native pieces
- Colima as the Linux VM (unavoidable on macOS)
- mDNS two-hop bridge (host-native `mdns-reflector.py` + VM container)
- The DNS topology: LAN → AdGuard → Unbound → internet
- Prometheus + Grafana for observability, same dashboards/alerts
- Slack notification channels: #infra, #deploy, #dns, #network
- Internal CA (`homelab-ca`) — Caddy uses it instead of cert-manager

## Repo layout

```
homelab-iac/
├── globals.yaml              # hostIp, dataRoot, networkName, lanDomain
├── .env.example              # secrets enumerated (real .env gitignored)
├── ansible/                  # the orchestrator
│   ├── reconcile.yml         # bootstrap + update + start, idempotent
│   ├── stop.yml              # graceful shutdown
│   ├── teardown.yml          # destructive: stop + wipe data
│   └── roles/
│       ├── common/
│       ├── colima/
│       ├── caddy/
│       ├── host-services/
│       └── compose-stack/    # generic: render + compose up -d
├── host/                     # host-side artifacts
│   ├── caddy/                # Caddyfile + snippets
│   └── services/             # python/shell for LaunchDaemons
├── stacks/                   # docker compose stacks
│   ├── dns/
│   ├── monitoring/
│   └── smart-home/
└── docs/
```

## Networking model

- One external docker network `homelab` (bridge) — all stacks attach.
  Cross-stack DNS works by service name (`adguard.homelab`,
  `unbound.homelab`).
- Per-stack default network for back-end-only traffic.
- Only **two** processes publish ports on the macOS host:
  - `caddy` on `:80`/`:443`
  - `dns-proxy.py` on `:53` (forwards to Colima VM)

Everything else stays inside Colima.

## Failure isolation

- A stack going down doesn't take the platform down (compose-level).
- Caddy going down breaks ingress but not DNS, smart-home, or
  observability collection.
- Colima going down breaks everything in-VM but host monitoring
  (node-exporter, mac-extras) keeps reporting — useful for diagnosis.
