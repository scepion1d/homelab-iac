# bootstrap

Scripts that take a fresh Intel Mac from zero → fully working homelab cluster.
After this runs, [Argo CD](https://argo-cd.readthedocs.io/) owns everything;
the only ongoing workflow is `git push`.

## TL;DR

```bash
git clone https://github.com/scepion1d/homelab-iac.git && cd homelab-iac
chmod +x bootstrap/*.sh
./bootstrap/bootstrap.sh
```

Then create the ad-hoc secrets in the [Secrets](#secrets-create-these-once)
section below.

## What `bootstrap.sh` does

Runs the numbered scripts in order. Each is idempotent — safe to re-run.

| # | Script | What it does |
|---|---|---|
| 00 | [00-install-deps.sh](00-install-deps.sh) | `brew install` colima, docker, k3d, kubectl, helm, kustomize, k9s, stern, argocd |
| 01 | [01-start-runtime.sh](01-start-runtime.sh) | `colima start` (defaults: 6 CPU, 24 GiB RAM, 100 GiB disk) |
| 02 | [02-create-cluster.sh](02-create-cluster.sh) | `k3d cluster create` per [cluster/k3d-config.yaml](../cluster/k3d-config.yaml) (1 server + 2 agents, Traefik disabled, host ports 80/443) |
| 03 | [03-install-argocd.sh](03-install-argocd.sh) | `kubectl apply --server-side` the upstream Argo CD stable manifests |
| 04 | [04-bootstrap-apps.sh](04-bootstrap-apps.sh) | `kubectl apply` the root ApplicationSet — Argo CD now owns the cluster |
| 05 | [05-enable-autostart.sh](05-enable-autostart.sh) | Install LaunchAgents from [launchd/](launchd/) so Colima + k3d start at login |

`bootstrap.sh` finishes by printing the Argo CD initial admin password
(`argocd-initial-admin-secret`).

## Tunables

Environment variables read by the runtime script:

| Var | Default | Notes |
|---|---|---|
| `COLIMA_PROFILE` | `default` | profile name |
| `COLIMA_CPU` | `6` | CPU cores allocated to the VM |
| `COLIMA_MEMORY` | `24` | GiB of RAM |
| `COLIMA_DISK` | `100` | GiB (sparse, only grows as used) |

Re-tune later:

```bash
colima stop
COLIMA_CPU=8 COLIMA_MEMORY=32 ./bootstrap/01-start-runtime.sh
```

## Secrets (create these once)

Argo CD will reconcile every app, but a few apps need credentials that
**must not** live in git. Create them by hand after `bootstrap.sh` finishes,
**before** the corresponding apps will go healthy.

### 1. Argo CD: Git repo credentials (PAT)

So Argo CD can pull from this private repo:

```bash
source scripts/argocd-login.sh && argocd-login
argocd repo add https://github.com/scepion1d/homelab-iac.git \
  --username scepion1d \
  --password github_pat_YOUR_TOKEN
```

GitHub → Settings → Developer settings → Personal access tokens (fine-grained) →
read-only on `Contents` for this repo.

### 2. Argo CD: Slack notifications token (optional)

```bash
kubectl -n argocd patch secret argocd-notifications-secret \
  --patch='{"stringData":{"slack-token":"xoxb-YOUR-TOKEN"}}'
```

Without this the notifications controller logs auth errors but everything
else keeps working. See
[cluster/apps/argocd-notifications/configmap.yaml](../cluster/apps/argocd-notifications/configmap.yaml)
for channel config.

### 3. Grafana admin password

The chart is wired to `existingSecret: grafana-admin`. **If you skip this**,
the chart auto-rolls a new password on every sync and you can't log in.

```bash
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -base64 24)"
```

Retrieve later with `scripts/grafana-login.sh`.

### 4. MikroTik exporter credentials

The `mikrotik-exporter` Deployment mounts a Secret containing a YAML
blob with the RouterOS API user/password. Full instructions:
[cluster/apps/mikrotik-exporter/README.md](../cluster/apps/mikrotik-exporter/README.md).

Short form (after creating the `mktxp_user` on the router):

```bash
kubectl -n monitoring create secret generic mikrotik-exporter-credentials \
  --from-literal=credentials.yaml="username: mktxp_user
password: <router-api-password>
"
```

### 5. AdGuard Home first-run wizard

AdGuard stores its admin user/password (bcrypted) inside the PVC — not in
git, not a Kubernetes Secret. The pod is **NotReady until the wizard is
done** (the readiness probe targets :53, which only binds after setup).

Full walkthrough (terminal-only API flow + LAN DHCP wiring):
[cluster/apps/adguard/README.md](../cluster/apps/adguard/README.md).

## Trust the in-cluster CA

cert-manager mints a self-signed CA on first sync and signs every ingress
with it. Install the CA on each device you want to use without browser
warnings:

```bash
./bootstrap/export-ca.sh           # writes ./homelab-ca.crt
```

Then follow the per-OS instructions in the comments at the top of
[export-ca.sh](export-ca.sh) (macOS keychain, iOS profile, Android, Linux,
Windows, Firefox).

## Verifying

```bash
kubectl get nodes
kubectl -n argocd get pods
argocd app list                    # everything should reach Synced + Healthy
```

App-by-app sync progress in the Argo CD UI: `https://argocd.int` or
`https://argocd.localhost` (after trusting the CA).

## Gotchas

### Colima's VM dnsmasq holds host :53

k3d publishes the AdGuard DNS port via the loadbalancer (see
[cluster/k3d-config.yaml](../cluster/k3d-config.yaml)). Colima's VM ships
with dnsmasq bound to :53 inside the VM, and Lima forwards that to the
Mac. On a fresh install, `k3d cluster edit ... --port-add 53:53` will
fail with `bind host port 0.0.0.0:53: address already in use`.

Fix:

```bash
colima ssh -- sudo systemctl disable --now dnsmasq
```

This breaks the k3d nodes' own DNS resolution (they were inheriting
dnsmasq via Docker's internal resolver). Patch each node's resolv.conf
to point at public DNS:

```bash
for n in $(docker ps --format '{{.Names}}' | grep -E '^k3d-homelab-(server|agent)'); do
  docker exec "$n" sh -c 'printf "nameserver 1.1.1.1\nnameserver 9.9.9.9\noptions ndots:0\n" > /etc/resolv.conf'
done
kubectl -n kube-system rollout restart deploy/coredns
```

Not yet baked into the bootstrap scripts — this whole sequence is needed
only on first AdGuard setup.

## Teardown / rebuild

```bash
./bootstrap/teardown.sh            # remove LaunchAgents, delete cluster, stop Colima
./bootstrap/teardown.sh --purge    # also delete the Colima profile (loses cached images)
./bootstrap/bootstrap.sh           # rebuild
```

Teardown does **not** uninstall brew tooling and does **not** touch the secrets
listed above — those live only in the cluster, so deleting the cluster
deletes them. You'll need to recreate them after the next `bootstrap.sh`.

## Order of operations diagram

```mermaid
flowchart TD
  A[00 install brew tools] --> B[01 colima start]
  B --> C[02 k3d cluster create]
  C --> D[03 kubectl apply argocd]
  D --> E[04 apply root ApplicationSet]
  E --> F[05 install LaunchAgents]
  F --> G[Create ad-hoc secrets:<br/>repo PAT, slack, grafana-admin,<br/>mikrotik-exporter-credentials]
  G --> H[Argo CD reconciles<br/>everything to Healthy]
  H --> I[export-ca.sh<br/>+ trust on each device]
  H --> J[AdGuard first-run wizard<br/>via API or :3000 port-forward]
```
