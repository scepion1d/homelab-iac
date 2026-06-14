# ansible/roles/colima/ — Colima VM lifecycle

Idempotent role that ensures the Colima VM is running and Docker is
reachable. Run on every `reconcile.yml` so a stopped Colima self-heals.

## What it does

1. Probe `colima status --profile {{ colima_profile }}`.
2. If down: `colima start` with cpu/memory/disk from `group_vars`.
3. Wait for it to come back up.
4. Resolve VM address → `colima_vm_ip` fact.
5. Fix in-VM `/etc/resolv.conf` (masks dnsmasq, points at public DNS).
6. Set `docker_host` fact (Colima's profile-scoped socket).
7. Wait for `docker info` to succeed.

## Outputs (facts)

- `colima_vm_ip` — vmnet IP (e.g. `192.168.64.2`)
- `docker_host` — `unix:///Users/<user>/.colima/<profile>/docker.sock`

Both are consumed by downstream roles (`compose-stack`,
`host` for templating `dns-proxy.plist`).
