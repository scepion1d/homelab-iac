# ansible/roles/caddy/ — host Caddy reverse proxy

Installs and configures Caddy on macOS as a LaunchDaemon. Replaces
v1's ingress-nginx + cert-manager + ClusterIssuer chain.

## What it does (planned — Phase 2)

1. `brew install caddy` (idempotent via community.general.homebrew)
2. Template `/usr/local/etc/caddy/Caddyfile` from `host/caddy/Caddyfile.template`
   composed with `host/caddy/snippets/*.caddy`
3. Install `/Library/LaunchDaemons/com.homelab.caddy.plist`
4. Bootout/enable/bootstrap on plist change (the launchd pattern)
5. `caddy validate` before reload; `caddy reload` for config-only changes

## TLS

Uses the existing homelab internal CA (`caddy_ca_cert` / `caddy_ca_key`
from group_vars). Caddy's `tls.internal` directive uses these to sign
leaf certs for all `*.{{ lan_domain }}` hosts.

## Currently

Skeleton only. `tasks/main.yml` is a placeholder. Actual implementation
lands in Phase 2 of [docs/migration-v1-v2.md](../../../docs/migration-v1-v2.md).
