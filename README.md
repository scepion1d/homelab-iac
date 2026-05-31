# homelab-iac

GitOps-managed k3d homelab on an Intel Mac. `bootstrap.sh` brings up
Colima → k3d → Argo CD → app-of-apps. After that, `git push` deploys.

## Bootstrap

```bash
git clone https://github.com/scepion1d/homelab-iac.git && cd homelab-iac
chmod +x bootstrap/*.sh && ./bootstrap/bootstrap.sh

kubectl -n argocd patch secret argocd-notifications-secret \
  --patch='{"stringData":{"slack-token":"xoxb-YOUR-TOKEN"}}'
source scripts/argocd-login.sh && argocd-login
argocd repo add https://github.com/scepion1d/homelab-iac.git \
  --username scepion1d --password github_pat_YOUR_TOKEN

# Grafana admin Secret — picked up by the chart via `admin.existingSecret`.
# Required, otherwise the chart re-rolls the password on every sync.
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -base64 24)"
```

Wipe & rebuild: `./bootstrap/teardown.sh [--purge]` then `./bootstrap/bootstrap.sh`.

## UIs

| URL (LAN / local) | App | Login |
|---|---|---|
| https://argocd.int / .localhost | Argo CD | `source scripts/argocd-login.sh && argocd-login` |
| https://grafana.int / .localhost | Grafana | `source scripts/grafana-login.sh && grafana-login` |
| https://prometheus.int / .localhost | Prometheus | none (LAN only) |

## Argo CD day-to-day

```bash
argocd app list
argocd app sync <name>
argocd app sync -l argocd.argoproj.io/application-set-name=root
stern -n argocd argocd-application-controller

kubectl -n argocd annotate applicationset root \
  argocd.argoproj.io/refresh=hard --overwrite
```

`git push` → auto-sync within ~3 min.

## LAN access (`.int` domain)

`lanDomain` in [cluster/globals.yaml](cluster/globals.yaml) is injected into
each Ingress by the root ApplicationSet. The MikroTik router resolves it:

```routeros
/ip dns set allow-remote-requests=yes
/ip dns static add name=argocd.int     address=192.168.10.3 type=A
/ip dns static add name=grafana.int    address=192.168.10.3 type=A
/ip dns static add name=prometheus.int address=192.168.10.3 type=A
/ip dhcp-server network set [find] dns-server=192.168.10.1
```

Replace `192.168.10.3` with Mac IP, `192.168.10.1` with router IP.

> macOS firewall must allow inbound on 80/443.

## TLS

cert-manager signs every ingress with an in-cluster CA. Install the CA once
per device:

```bash
./bootstrap/export-ca.sh
```

New ingress → add:

```yaml
metadata:
  annotations: { cert-manager.io/cluster-issuer: homelab-ca }
spec:
  tls: [{ secretName: <app>-tls, hosts: [<app>.localhost] }]
```

## Prometheus

Default scrapes: node-exporter, kube-state-metrics, kubelet/cAdvisor,
Argo CD `*-metrics` (via [argocd-server-ingress](cluster/apps/argocd-server-ingress/metrics-services.yaml)),
MikroTik via [snmp-exporter](cluster/apps/snmp-exporter/_appset.yaml).

Add a workload by annotating its Service:

```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "<metrics-port>"
```

MikroTik SNMP setup (one-time on router):

```routeros
/snmp community add name=homelab addresses=192.168.10.0/24 read-access=yes
/snmp set enabled=yes
```

## Grafana dashboards

Dashboards live as JSON files under
[cluster/apps/grafana-dashboards/dashboards/](cluster/apps/grafana-dashboards/dashboards/).
Each dashboard is its own folder (`dashboards/<name>/dashboard.json` +
`kustomization.yaml`). Kustomize turns each into a ConfigMap; Grafana's
sidecar watches the `monitoring` namespace and imports anything labeled
`grafana_dashboard=1`.

Add a dashboard:

1. Build/edit it in the Grafana UI.
2. **Share → Export → Save to file** (toggle "Export for sharing externally"
   OFF — we want the resolved Prometheus datasource).
3. Drop the file at
   `cluster/apps/grafana-dashboards/dashboards/<name>/dashboard.json`.
4. Copy a sibling `kustomization.yaml` and rename `dashboard-<name>` +
   `grafana_folder: <Folder>`.
5. Add `- dashboards/<name>` to the top-level
   [kustomization.yaml](cluster/apps/grafana-dashboards/kustomization.yaml).
6. `git commit && git push`. Sidecar imports it within ~30s of the next
   Argo CD sync.

Remove one: delete its folder and the matching `resources:` line, commit.

## Repository layout

```
bootstrap/      bootstrap.sh, teardown.sh, export-ca.sh, launchd/
scripts/        argocd-login.sh, grafana-login.sh
cluster/
├── k3d-config.yaml        cluster shape
├── globals.yaml           shared constants (repoUrl, lanDomain, slackChannel)
├── root-appset.yaml       single ApplicationSet, scans apps/*/_appset.yaml
└── apps/<name>/
    ├── _appset.yaml       metadata (namespace, optional Helm source, ingressHost)
    ├── kustomization.yaml local manifests, OR
    └── (Helm chart via _appset.yaml `source:`)
```

`globals.yaml` keys: `repoUrl` and `lanDomain` are templated into apps;
`slackChannel` is tracked as documentation only (literal in
[argocd-notifications/configmap.yaml](cluster/apps/argocd-notifications/configmap.yaml)).

LAN access for a new app: set `ingressHost: <subdomain>` in its
`_appset.yaml` (plus `ingressHelmParam:` for Helm charts).

### Add a new app

```bash
mkdir cluster/apps/<name>
git add . && git commit -m "add <name>" && git push
kubectl -n argocd annotate applicationset root \
  argocd.argoproj.io/refresh=hard --overwrite
```

## Tooling (installed by bootstrap)

colima, docker, k3d, kubectl, helm, kustomize, k9s, stern, argocd
