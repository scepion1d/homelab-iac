# mikrotik-exporter

[mktxp](https://github.com/akpw/mktxp) talking RouterOS API on
`192.168.10.1:8728`. Replaces the SNMP exporter — gives us per-DHCP-lease
records, per-wireless-client signal, queue stats, firewall counters that
SNMP can't.

## One-time setup

### 1. Create a read-only user on the router

In the MikroTik terminal (Winbox → New Terminal, or SSH):

```routeros
/user group add name=mktxp_group policy=api,read
/user add name=mktxp_user group=mktxp_group password=<your-password-here>
```

### 2. Create the Kubernetes Secret

The deployment expects a Secret named `mikrotik-exporter-credentials` in
the `monitoring` namespace with a single key `credentials.yaml`:

```bash
kubectl -n monitoring create secret generic mikrotik-exporter-credentials \
  --from-literal=credentials.yaml="username: mktxp_user
password: <your-password-here>
"
```

(Yes — multi-line literal. The yaml file must end with a newline.)

To rotate later, delete and recreate.

### 3. Sync the app

```bash
git push
argocd app sync mikrotik-exporter
```

## Verifying

```bash
kubectl -n monitoring get pods -l app.kubernetes.io/name=mikrotik-exporter
kubectl -n monitoring logs deploy/mikrotik-exporter

# Direct scrape
kubectl -n monitoring port-forward svc/mikrotik-exporter 49090:49090
curl -s http://localhost:49090/metrics | grep '^mktxp_' | head
```

In Prometheus: `up{kubernetes_name="mikrotik-exporter"}` should be `1`.

## DHCP lease type

mktxp doesn't expose a `dynamic` label, but the
`mktxp_dhcp_lease_info` metric's *value* is `expires_after` (seconds
until expiry):

- value `> 0` → dynamic lease
- value `== 0` → static lease (never expires)

The dashboard uses this distinction.
