# host/ — host-side apps

Mirrors `cluster/` structurally but holds workloads that run **directly on
the host machine** (via Docker on Colima), not inside the k3d cluster.

Use `host/apps/<name>/` for things that:

- need physical/host-network features the cluster can't provide cleanly
  (mDNS, broadcast discovery, HomeKit pairing, USB passthrough);
- predate the cluster or outlive it (you want to recreate k3d without
  losing their state);
- are easier to reason about as a single container with a bind-mount than
  as a Helm chart.

Everything else belongs under `cluster/apps/`.

## Layout

```
host/
├── globals.yaml                # constants (hostIp, dataRoot, networkName, lanDomain)
└── apps/<name>/                # one folder per host app
    ├── compose.yaml            # required (docker compose v3+)
    ├── README.md               # required
    ├── prometheus-target.yaml  # optional (scrape-config fragment)
    └── config/                 # optional (bind-mounted into the container)
        ├── .managed-by-homelab-iac   # allowlist of repo-owned files
        └── <repo-owned files>
```

## Lifecycle

Imperative, not GitOps. Bootstrap step `09-host-apps.sh` reconciles the
tree on demand:

```sh
./bootstrap/09-host-apps.sh                # reconcile all
./bootstrap/09-host-apps.sh home-assistant # one app
./bootstrap/09-host-apps.sh --diff         # show what would change, no action
./bootstrap/09-host-apps.sh --prune        # also stop containers whose apps were removed
./bootstrap/09-host-apps.sh --recopy-config # re-copy managed config files
```

Run it directly any time you change a `compose.yaml`, bump an image tag,
or want to pick up edits. It's idempotent.

## Data persistence

Each app gets `${dataRoot}/<name>/` on the host (default
`~/homelab-data/<name>/`). That's the *only* place containers should
write persistent data — no Docker named volumes. Backup story is the same
for every app: `rsync` the data root.

## Prometheus scrape targets

Apps with metrics drop a `prometheus-target.yaml` in their folder.
Bootstrap concatenates them and splices the result into
`cluster/apps/prometheus/_appset.yaml` under
`server.serverFiles."host-targets.yml".scrape_configs`. If the file
changes, bootstrap prints a notice; commit + push so Argo CD picks it up.

## Why this is separate from `cluster/`

The cluster reconciles continuously via Argo CD. The host doesn't have a
Kubernetes-shaped control loop, so host apps are reconciled by an
imperative script you run on demand. Keeping the two trees physically
separate makes the boundary obvious and prevents Argo CD from trying to
manage things it can't see.
