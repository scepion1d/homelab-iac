# homelab-iac

GitOps-managed k3d homelab on an Intel Mac. Argo CD owns the cluster;
`git push` deploys.

## Spin up

See [bootstrap/README.md](bootstrap/README.md) for the fresh-install walkthrough
(tooling, cluster, Argo CD, ad-hoc secrets).

## UIs

| URL | App | Login |
|---|---|---|
| https://argocd.int | Argo CD | `source scripts/argocd-login.sh && argocd-login` |
| https://grafana.int | Grafana | `source scripts/grafana-login.sh && grafana-login` |
| https://prometheus.int | Prometheus | none (LAN only) |
| https://adguard.int | AdGuard Home | wizard on first launch — see [adguard/README.md](cluster/apps/adguard/README.md) |

All also reachable at `*.localhost` (locally) and `*.192-168-10-3.nip.io`
(any device). cert-manager signs them with the in-cluster homelab CA —
install it once per device with `./bootstrap/export-ca.sh`.

## Operate

```bash
# Status
argocd app list
kubectl get nodes
k9s

# Sync
argocd app sync <name>
git push                              # auto-sync within ~3 min

# Force re-scan of apps/ (after adding a new folder)
kubectl -n argocd annotate applicationset root \
  argocd.argoproj.io/refresh=hard --overwrite

# Logs
stern -n argocd argocd-application-controller
stern -n <ns> <pod-pattern>
```

## Add a new app

```bash
mkdir cluster/apps/<name>
# drop in _appset.yaml (+ kustomization.yaml or Helm source)
git add . && git commit -m "add <name>" && git push
kubectl -n argocd annotate applicationset root \
  argocd.argoproj.io/refresh=hard --overwrite
```

Set `ingressHost: <subdomain>` in `_appset.yaml` for a LAN-reachable
hostname (`<subdomain>.int`). Helm apps also need `ingressHelmParam:`.

> **Caveat:** `ingressHost` adds a single `server-alias` annotation that
> bleeds into every server block on the Ingress. If your app has
> multiple rules, list hosts explicitly in the Ingress instead (see
> [cluster/apps/adguard/ingress.yaml](cluster/apps/adguard/ingress.yaml)).

## Layout

```
bootstrap/      bring-up scripts + LaunchAgents (see bootstrap/README.md)
scripts/        argocd-login.sh, grafana-login.sh
cluster/        k3d-config.yaml, globals.yaml, root-appset.yaml, apps/<name>/
```

Each `apps/<name>/_appset.yaml` declares namespace, optional Helm source,
and optional `ingressHost`. The root ApplicationSet templates the rest.
Per-app extras (dashboards, scrape configs, README) live alongside.
