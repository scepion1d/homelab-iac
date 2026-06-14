# v1 → v2 migration plan

The v1 stack remains in `cluster/` and continues to be deployed by
Argo CD as long as the cluster runs. v2 is built greenfield in
`stacks/`, `host/caddy/`, and refactored Ansible. Once v2 is
validated, v1 directories are removed in a single commit.

## Status legend

- [ ] not started
- [-] in progress
- [x] done

## Phase 0 — repo scaffolding

- [x] `stacks/` skeleton + README per stack
- [x] `host/caddy/` skeleton
- [x] `docs/architecture.md`, `docs/migration-v1-v2.md`
- [x] `globals.yaml` v2 form (carry-over from v1 + new fields)
- [x] `.env.example` enumerating every secret

## Phase 1 — Ansible refactor

Build the orchestrator before any stacks need it.

- [x] `ansible/roles/compose-stack/` generic role
  (input: stack name, dir → output: rendered configs + `compose up -d`)
- [-] `ansible/roles/caddy/` install + template Caddyfile + LaunchDaemon (skeleton only, Phase 2)
- [ ] `ansible/roles/host-services/` refactor existing for v2 paths
  (currently reusing legacy `roles/host` — works because var names overlap)
- [x] `ansible/reconcile.yml` rewrite as v2 orchestrator
- [x] `ansible/stop.yml` rewrite
- [x] `ansible/teardown.yml` new — destructive cleanup
- [x] `ansible/requirements.yml` drop kubernetes.core, add community.docker

## Phase 2 — Caddy on host

Unblocks all subsequent web-facing stacks. Can coexist with k8s
ingress-nginx during transition (different ports? — TBD).

- [ ] Install Caddy via Ansible
- [ ] LaunchDaemon plist
- [ ] Caddyfile base + first snippet (test app)
- [ ] Internal CA wiring

## Phase 3 — Stack: dns

The simplest stack to validate (no ingress dependency until UI).

- [ ] `stacks/dns/compose.yaml`
- [ ] AdGuard config carry-over from `cluster/apps/adguard/configs/`
- [ ] Unbound config carry-over from `cluster/apps/unbound/`
- [ ] unbound-cache-dumper sidecar (port v1 sidecar logic to standalone)
- [ ] adguard-exporter, unbound-exporter
- [ ] Validate parallel with v1: run on different VM IP, dig against
      both, compare answers + latency
- [ ] Switch host `dns-proxy.py` target to v2 VM
- [ ] Decommission v1 adguard/unbound

## Phase 4 — Stack: monitoring

- [ ] `stacks/monitoring/compose.yaml`
- [ ] Prometheus scrape config (dynamic from labels + static for host)
- [ ] Grafana provisioning: datasources, dashboards, alerts
- [ ] Carry over dashboards from `cluster/apps/grafana-dashboards/`
- [ ] Carry over alert rules from `cluster/apps/grafana-alerts/`
- [ ] mikrotik-exporter
- [ ] Validate dashboards render against v2 metrics
- [ ] Decommission v1 prometheus/grafana

## Phase 5 — Stack: smart-home

- [ ] `stacks/smart-home/compose.yaml`
- [ ] Port `host/apps/home-assistant/compose.yaml` into stack
- [ ] Port `host/apps/mdns-reflector/compose.yaml` into stack
- [ ] HA prometheus token plumbing
- [ ] Validate HomeKit pairing still works after VM-side relocation
- [ ] Decommission v1 home-assistant

## Phase 6 — Decommission v1

Atomic commit on `v2` branch:

- [ ] `git rm -r cluster/`
- [ ] `git rm -r host/apps/`  (moved into stacks/)
- [ ] `git rm bootstrap/launchd-system/com.homelab.cluster.plist`
- [ ] Remove pre-commit revision-bumper hook (no Argo)
- [ ] Update top-level `README.md` for v2 layout

## Phase 7 — Promote v2 → main

- [ ] Final integration test from a clean shutdown
- [ ] PR `v2` → `main`
- [ ] Tag `v2` after merge
- [ ] `v1` tag remains as historic reference

## Rollback procedure (anytime during 0-6)

```bash
git checkout v1      # or main (v1 is tagged + main is on v1 baseline)
ansible-playbook ansible/reconcile.yml
```
