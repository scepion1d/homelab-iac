# host/caddy/ — host-level reverse proxy + TLS

Caddy runs as a macOS LaunchDaemon on the host (port :80/:443),
terminating TLS and reverse-proxying to docker containers inside
the Colima VM.

Replaces the v1 stack of `ingress-nginx` + `cert-manager` +
`cluster-issuer`.

## Why on the host (not in a container)

- LAN clients connect to `*.int` on the host IP (192.168.10.3). Caddy
  must bind :80/:443 on the host LAN interface — running it in Colima
  would require yet another port-forward layer.
- Caddy's auto-cert flow and config reload work fine as a brew formula
  + LaunchDaemon. No reason to containerize.

## Install

Managed by Ansible (`ansible/roles/caddy`):

- `brew install caddy`
- `/Library/LaunchDaemons/com.homelab.caddy.plist`
- `/usr/local/etc/caddy/Caddyfile` (templated from this dir)

## Caddyfile composition

The active Caddyfile is assembled by Ansible from:

1. `Caddyfile.template` — base config (TLS provider, global options,
   logging)
2. `snippets/*.caddy` — one snippet per app exposed via Caddy

This means **adding a new web-facing service is a single snippet drop**,
no full Caddyfile edit needed.

## TLS

Uses the **existing homelab internal CA** carried over from v1 cert-manager
(same root cert, same fingerprint — devices that previously trusted
`homelab-ca` keep working with zero re-import).

### Sources

- `.crt` lives at `~/.cert/homelab-ca.crt` (standalone PEM cert) — what
  you AirDrop / push to client devices to establish trust.
- The full Secret YAML (with both `tls.crt` and `tls.key`, k8s-style
  base64-encoded) lives at `~/.cert/homelab-ca-secret.yaml`. Paths
  overridable via `.env` `CERT` and `CERT_YAML` (same names as v1).

### What ansible does

On every reconcile, `roles/caddy/tasks/extract-ca.yml` reads the YAML,
base64-decodes the private key, and writes it to
`~/.cache/homelab/homelab-ca.key` with mode 0600. Caddy then uses that
key together with the `.crt` to sign per-host leaf certs at runtime via
its `tls internal` directive.

### Caddyfile shape (Phase 2)

```caddy
{
    pki {
        ca homelab {
            root_cn "homelab-ca"
            root /path/from/caddy_ca_cert
            root_key /path/from/caddy_ca_key
        }
    }
}

grafana.int {
    tls internal { ca homelab }
    reverse_proxy localhost:3000
}
```

Same root CA → no client re-trust needed when migrating from v1
ingress-nginx + cert-manager.

## Hosts (planned, from v1 ingress list)

| Host | Backend |
|---|---|
| `grafana.int` | monitoring stack, `:3000` |
| `prometheus.int` | monitoring stack, `:9090` |
| `adguard.int` | dns stack, `:3000` (AdGuard UI) |
| `hass.int` | smart-home stack, `:8123` |

No more `argocd.int` (no Argo). No more `*.<hostIp-dashed>.nip.io`
aliases — single CA + Caddy's auto-cert handles it cleanly.
