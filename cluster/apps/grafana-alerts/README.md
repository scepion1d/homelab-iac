# grafana-alerts

Grafana managed alert rules, contact points, policies, templates, and inhibit
rules — provisioned via the Grafana sidecar (`sidecar.alerts`) from
`ConfigMap`s labeled `grafana_alert=1` in the `monitoring` namespace.

## Layout

```
notifications/
  contact-points.yaml   one Slack receiver per channel (#infra/#cluster/#network/#dns)
  policies.yaml         routing tree: channel label → Slack receiver; critical override
  templates.yaml        shared Slack message templates (mobile-first card)
  mute-timings.yaml     `always` interval (used by the silence-info policy route)
  inhibit-rules.yaml    "exporter-down silences downstream" + "critical silences warning"
rules/
  cluster/rules.yaml    12 cluster rules  (folder: Cluster)
  router/rules.yaml      9 router rules   (folder: Router)
  adguard/rules.yaml     5 adguard rules  (folder: AdGuard)
```

The Grafana folder per entity contains BOTH the dashboard (`Overview`) and
the alert rules. The matching dashboard CMs in
`cluster/apps/grafana-dashboards/dashboards/<entity>/` carry the
`grafana_folder` annotation that puts them into the same folder.
`Home Lab` lives in the General folder (no entity).

## Channels & severity

| Severity | Color    | Mention | Where it shows |
| -------- | -------- | ------- | -------------- |
| critical | `#E01E5A`| `@here` | per `channel` label |
| warning  | `#ECB22E`| none    | per `channel` label |
| info     | n/a      | none    | silenced (reserved tier) |
| resolved | `#2EB67D`| none    | same channel as firing |

Each rule carries a `channel` label that maps directly to the Slack channel:
`infra`, `cluster`, `network`, `dns`.

## Bootstrap (one-time, outside GitOps)

Set `GRAFANA_SLACK_BOT_TOKEN=xoxb-…` in `bootstrap/.env`
(see [bootstrap/.env.example](../../../bootstrap/.env.example)) and run:

```sh
./bootstrap/06-cluster-secrets.sh
```

That creates Secret `monitoring/grafana-slack` (key `token`). Grafana mounts
it as env `SLACK_BOT_TOKEN`; contact points reference it as
`$SLACK_BOT_TOKEN` (see `cluster/apps/grafana/_appset.yaml` →
`envValueFrom`).

If you skip the env var, the bootstrap step is a no-op and Grafana will
CrashLoop until the Secret exists, since `envValueFrom` requires its source.

Quiet hours are user-managed on the Slack side (channel notification
schedule), not in Grafana.

## Adding a rule

1. Pick the entity folder (`rules/<entity>/rules.yaml`).
2. Append a rule using the same shape as existing entries:
   - data[0] (`refId: A`) — PromQL that returns *only* rows that should fire.
   - data[1] (`refId: B`) — `type: math`, `expression: '$A > 0'` (or your threshold).
   - `condition: B`, `noDataState: OK`, `for: <bucket>`.
   - Labels: `severity`, `entity`, `component`, `channel`.
   - Annotations: `summary`, `description` (use `{{ $values.A.Value }}`),
     `dashboard_url`, optional `value_label`.
3. Bump `revision` in `cluster/apps/grafana-alerts/_appset.yaml` only if Argo
   gets stuck on a stale render.

`for:` bucket menu: `0m / 2m / 5m / 10m / 30m`. Don't introduce new values.

## Adding a contact point / channel

1. Append a receiver to `notifications/contact-points.yaml`.
2. Add a matching route under both the critical and warning branches of
   `notifications/policies.yaml`.
3. Add the new `channel` label value to the routing matrix in
   `cluster/apps/grafana-alerts/README.md` (this file).
