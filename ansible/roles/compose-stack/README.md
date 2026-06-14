# ansible/roles/compose-stack/ — generic docker compose deployer

A single, reusable role that brings one compose stack to its desired
state. Every entry in `stacks/` is deployed via this role.

## Inputs

| Var | Required | Purpose |
|---|---|---|
| `stack` | yes | Stack name. Must match a directory under `stacks/`. |
| `stack_action` | no | `up` (default), `down`, `pull`, `restart` |

## What it does

1. Resolves stack dir: `{{ stacks_dir }}/{{ stack }}`
2. Ensures persistent data dir exists: `{{ data_root }}/{{ stack }}`
3. Ensures the shared `homelab` docker network exists
4. Runs `docker compose -p homelab-{{ stack }} -f compose.yaml <action>`
5. Reports changed only when compose actually changed anything

## Outputs

- `compose_changed_<stack>` fact: true if `docker compose up` modified
  any container. Used by callers to trigger Caddy reload, Slack notify,
  etc.

## Conventions enforced

- Project name: `homelab-{{ stack }}` so `docker ps --filter
  name=^homelab-` works for all stack containers across all stacks.
- `${DATA_ROOT}`, `${HOST_IP}`, `${TZ}`, `${NETWORK_NAME}` exported
  into compose's environment for variable substitution in compose.yaml.
- Stack must declare external network `${NETWORK_NAME}` if it needs
  cross-stack DNS; this role does not patch compose files.

## Usage from a playbook

```yaml
- name: Reconcile all stacks
  hosts: localhost
  tasks:
    - include_role:
        name: compose-stack
      vars:
        stack: "{{ item }}"
      loop:
        - dns
        - monitoring
        - smart-home
```
