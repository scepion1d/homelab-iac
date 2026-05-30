## Connection

```bash
ssh homlab-admin@homelab
```

## Repository layout

```
homelab-iac/
├── bootstrap/                          # One-shot scripts to bring up a fresh Mac
│   ├── bootstrap.sh                    #   orchestrator (runs 00 → 05)
│   ├── 00-install-deps.sh              #   brew + CLI tooling
│   ├── 01-start-runtime.sh             #   start Colima (container runtime)
│   ├── 02-create-cluster.sh            #   k3d cluster create
│   ├── 03-install-argocd.sh            #   install Argo CD
│   ├── 04-bootstrap-apps.sh            #   apply root "app-of-apps"
│   ├── 05-enable-autostart.sh          #   install LaunchAgents
│   ├── teardown.sh                     #   reverse of bootstrap (stop & remove)
│   └── launchd/                        #   macOS LaunchAgent plists
│       ├── com.homelab.colima.plist    #     starts Colima at login
│       └── com.homelab.k3d.plist       #     starts k3d cluster after Colima
├── cluster/                            # Declarative cluster-level IaC
│   ├── k3d-config.yaml                 #   cluster definition (nodes, ports)
│   ├── root-appset.yaml                #   ApplicationSet — scans apps/*/_appset.yaml
│   └── apps/                           #   One folder per Argo CD Application
│       ├── argocd-notifications/       #     Slack notifications ConfigMap
│       │   ├── _appset.yaml            #       metadata for the ApplicationSet
│       │   ├── kustomization.yaml
│       │   └── configmap.yaml
│       ├── argocd-server-ingress/      #     Argo CD UI ingress + insecure mode patch
│       │   ├── _appset.yaml
│       │   ├── kustomization.yaml
│       │   ├── cmd-params-cm.yaml
│       │   └── ingress.yaml
│       └── ingress-nginx/              #     Helm chart (no local manifests)
│           └── _appset.yaml            #       source: { helm chart from upstream }
└── README.md
```

### Adding a new app

1. Create `cluster/apps/<name>/` with a `_appset.yaml` (at minimum `namespace: <ns>`).
2. Drop your manifests + a `kustomization.yaml` next to it.
3. `git push` — the ApplicationSet picks it up automatically.

For a remote Helm chart, the folder only needs `_appset.yaml` with a `source:` block (see [cluster/apps/ingress-nginx/_appset.yaml](cluster/apps/ingress-nginx/_appset.yaml) as an example).

## Tooling

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

## First-time bootstrap

On the Mac, after cloning this repo:

```bash
cd bootstrap
chmod +x *.sh
./bootstrap.sh
```

This installs tooling, starts Colima, creates the cluster, installs Argo CD,
applies the root app-of-apps, and installs LaunchAgents so everything comes
back up automatically on the next login.

## Manage auto-start

```bash
# Disable
launchctl unload ~/Library/LaunchAgents/com.homelab.k3d.plist
launchctl unload ~/Library/LaunchAgents/com.homelab.colima.plist

# Re-enable (or update after editing plists)
./bootstrap/05-enable-autostart.sh
```

## Accessing Argo CD

Exposed via ingress-nginx (also managed by Argo CD):

- UI:  https://argocd.localhost  (self-signed cert — accept the warning)
- CLI: `argocd login argocd.localhost --grpc-web --insecure`

Browsers and `curl` resolve `*.localhost` to 127.0.0.1 automatically — no
`/etc/hosts` edit needed. Host ports 80/443 are mapped to the cluster's
load balancer in [cluster/k3d-config.yaml](cluster/k3d-config.yaml).

The initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

## Teardown

```bash
./bootstrap/teardown.sh           # stop everything, keep Colima VM & images
./bootstrap/teardown.sh --purge   # also delete the Colima profile (loses cached images)
```

Brew-installed tools stay; uninstall them manually with `brew uninstall …` if desired.
