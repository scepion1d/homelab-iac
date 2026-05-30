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
│   └── root-app.yaml                   #   Argo CD root Application
└── apps/                               # Everything Argo CD manages lives here
```

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

## Teardown

```bash
./bootstrap/teardown.sh           # stop everything, keep Colima VM & images
./bootstrap/teardown.sh --purge   # also delete the Colima profile (loses cached images)
```

Brew-installed tools stay; uninstall them manually with `brew uninstall …` if desired.
