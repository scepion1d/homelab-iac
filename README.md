# homelab-iac

GitOps-managed k3d homelab on an Intel Mac. One `bootstrap.sh` brings up
Colima → k3d → Argo CD → app-of-apps; after that, `git push` is the
deployment workflow.

## Connect

```bash
ssh homlab-admin@homelab
```

## Bootstrap (fresh Mac)

```bash
git clone https://github.com/scepion1d/homelab-iac.git
cd homelab-iac/bootstrap
chmod +x *.sh
./bootstrap.sh
```

Then add the two secrets that don't live in git:

```bash
# 1. Slack token for Argo CD notifications
kubectl -n argocd patch secret argocd-notifications-secret \
  --patch="{\"stringData\":{\"slack-token\":\"xoxb-YOUR-TOKEN\"}}"

# 2. Private repo access (fine-grained PAT, Contents: Read-only)
source scripts/argocd-login.sh && argocd-login
argocd repo add https://github.com/scepion1d/homelab-iac.git \
  --username scepion1d --password github_pat_YOUR_TOKEN
```

## Wipe & rebuild

```bash
./bootstrap/teardown.sh           # stop everything, keep Colima VM & images
./bootstrap/teardown.sh --purge   # also delete the Colima profile

./bootstrap/bootstrap.sh          # rebuild from scratch
# then redo the two secrets above
```

## Argo CD

UI: https://argocd.localhost (self-signed cert — accept the warning).

```bash
# Login helper (sources a function into the shell)
source scripts/argocd-login.sh && argocd-login

# Day-to-day
argocd app list
argocd app sync <name>
argocd app sync -l argocd.argoproj.io/application-set-name=root   # sync all
argocd app diff <name>
argocd app logs <name> -f
stern -n argocd argocd-application-controller                     # live controller logs
```

Push changes: `git push` → auto-synced within ~3 min, or force with
`argocd app sync <name>`. New app folders need the ApplicationSet to
re-scan:

```bash
kubectl -n argocd annotate applicationset root \
  argocd.argoproj.io/refresh=hard --overwrite
```

## LAN access

The UIs are exposed to the LAN under a custom domain (default: `.int`),
resolved by the MikroTik router's built-in DNS to the Mac's LAN IP.

The domain lives in [cluster/globals.yaml](cluster/globals.yaml) as `lanDomain`
and is injected into each Ingress by the root ApplicationSet (see the
*Constants* section below). On a domain change, update both this value AND
the MikroTik static DNS entries.

**MikroTik setup** (one-time):

```
/ip dns set allow-remote-requests=yes
/ip dns static add name=argocd.int  address=192.168.10.3 type=A
/ip dns static add name=grafana.int address=192.168.10.3 type=A
/ip dhcp-server network set [find] dns-server=192.168.10.1
```

(Replace `192.168.10.3` with the Mac's IP and `192.168.10.1` with the router's.)

From any LAN device:

- Argo CD:  https://argocd.int
- Grafana:  https://grafana.int

From the Mac itself, `*.localhost` URLs still work.

> macOS firewall: if connections from other devices time out, allow inbound
> on 80/443 (System Settings → Network → Firewall, or turn it off for
> homelab simplicity).

## TLS / certificates

Every ingress automatically gets a real TLS certificate signed by an
in-cluster CA managed by [cert-manager](cluster/apps/cert-manager/).
Browsers will warn until you install the **CA certificate** once per device
— after that, every current AND future app's cert is trusted.

```bash
# Export the CA cert from the cluster
./scripts/export-ca.sh                 # writes ./homelab-ca.crt
```

Then install it on each device (instructions in the script's header
comments cover Mac, iOS, Android, Linux, Windows, and Firefox).

**Adding TLS to a new app's ingress:** annotate + add a secretName.
cert-manager does the rest.

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: homelab-ca
spec:
  tls:
    - secretName: <app>-tls
      hosts:
        - <app>.localhost
```

## Grafana

UI: https://grafana.localhost (user `admin`).

```bash
# Login helper (prints URL + password, copies password to clipboard, opens browser)
source scripts/grafana-login.sh && grafana-login

# Or fetch the password directly
kubectl -n monitoring get secret grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d && echo
```

## Repository layout

```
bootstrap/                  one-shot scripts + launchd plists (Colima, k3d)
scripts/                    day-to-day helpers (source into shell)
├── argocd-login.sh         → argocd-login [host]
├── grafana-login.sh        → grafana-login [url]
└── export-ca.sh            → write homelab-ca.crt for device install
cluster/
├── k3d-config.yaml         cluster shape (nodes, host port mapping)
├── globals.yaml            shared constants (repoUrl, lanDomain, slackChannel)
├── root-appset.yaml        single ApplicationSet — scans apps/*/_appset.yaml
└── apps/                   one folder per Argo CD Application
    └── <name>/
        ├── _appset.yaml          metadata (namespace, optional Helm source)
        ├── kustomization.yaml    local manifests, OR
        └── *.yaml                ↳ omitted if _appset.yaml has `source:`
```

### Constants

[cluster/globals.yaml](cluster/globals.yaml) is the single source of truth for
shared values:

| Key            | How it's used                                                                                  |
| -------------- | ---------------------------------------------------------------------------------------------- |
| `repoUrl`      | [cluster/root-appset.yaml](cluster/root-appset.yaml) — templated as `{{ .repoUrl }}`           |
| `lanDomain`    | Injected per-app by the root ApplicationSet when `_appset.yaml` declares `ingressHost`. Kustomize apps get a patch that adds `<ingressHost>.<lanDomain>` to the Ingress; Helm apps get a `helm.parameter` setting `<ingressHelmParam>` to the same URL. DNS for `*.<lanDomain>` is served by the MikroTik router. |
| `slackChannel` | [cluster/apps/argocd-notifications/configmap.yaml](cluster/apps/argocd-notifications/configmap.yaml) — referenced by comment, not templated (ConfigMap content). |

Only `repoUrl` and `lanDomain` are interpolated. `slackChannel` is tracked in
`globals.yaml` purely as a single place to look — change both the global and
the literal site together.

Adding LAN access to a new app: set `ingressHost: <subdomain>` in its
`_appset.yaml` (and `ingressHelmParam:` for a Helm chart). No literal IPs.

### Add a new app

```bash
mkdir cluster/apps/<name>
# write _appset.yaml + manifests
git add cluster/apps/<name> && git commit -m "add <name>" && git push
kubectl -n argocd annotate applicationset root \
  argocd.argoproj.io/refresh=hard --overwrite
```

## Tooling installed by bootstrap

| Tool      | Purpose                                              |
| --------- | ---------------------------------------------------- |
| colima    | Headless container runtime for macOS                 |
| docker    | Docker CLI (talks to the Colima engine)              |
| k3d       | Run lightweight k3s Kubernetes clusters in Docker    |
| kubectl   | Kubernetes CLI                                       |
| helm      | Kubernetes package manager                           |
| kustomize | Template-free manifest customization                 |
| k9s       | Terminal UI for navigating Kubernetes                |
| stern     | Multi-pod / multi-container log tailing              |
| argocd    | Argo CD CLI (GitOps continuous delivery)             |
