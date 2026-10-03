# Monitoring and alerting

What is observed on riko, where alerts live, and how to change them. Backup facts are in [backup-topology.md](backup-topology.md).

## Pipeline

Metrics and logs are shipped by Grafana Alloy (`apps/alloy/`) to Grafana Cloud. The stack is `karitham.grafana.net`.

- Metrics go to Grafana Cloud Prometheus via `prometheus.remote_write`.
- Logs go to Grafana Cloud Loki via `loki.write`.
- Traces go to Tempo via `otelcol.exporter.otlp`.
- Pod and Service scrapes select targets by `prometheus.io/scrape` annotations, so a workload is scraped only after its pods carry them. CNPG instance metrics on pod port `9187` are the exception: the pods carry no annotations, so `discovery.kubernetes.cnpg` / `prometheus.scrape.cnpg` discovers them explicitly.
- The Alloy configuration is `apps/alloy/config.alloy`; kustomize generates it into the `alloy-config` ConfigMap, which the Helm release mounts.

Alert rules are evaluated by Grafana-managed alerting on the stack. The rules live in this repo, and a Flux Job pushes them to the Grafana API:

```
apps/grafana-alerts/rules.json      (rule definitions)
apps/grafana-alerts/provision.py    (uploader script)
apps/grafana-alerts/provision.yaml  (Job)
  -> kustomize builds both files into ConfigMaps
  -> Grafana provisioning API  (PUT/POST /api/v1/provisioning/alert-rules)
  -> Grafana-managed alerting  (evaluates against grafanacloud-prom)
  -> notification policy
  -> Discord contact point
```

The Flux Kustomization `grafana-alerts` applies the Job into namespace `grafana-alerts`. The Job creates the `riko` folder if missing, then upserts each rule by a fixed `uid` (PUT, falling back to POST on 404), so a re-run converges.

## Rules

The three rules are in the `riko` folder, group `riko-backups`, evaluated every 60s:

| Alert                          | Fires when                                                      |
| ------------------------------ | --------------------------------------------------------------- |
| `PostgreSQL backup is stale`   | newest successful base backup older than 27h                    |
| `PostgreSQL backup is failing` | the last failed backup is newer than the last successful backup |
| `PostgreSQL instance is down`  | `cnpg_collector_up` is below 1                                  |

Thresholds are the `B` expression in each rule's `data`; the `A` expression is the PromQL query against the `grafanacloud-prom` datasource. `noDataState` is `Alerting` for the stale and down rules, so loss of the whole series set pages; the failing rule uses `OK`, because no failure signal is a good state. The backup rules produce instances only for clusters that expose the `barman_cloud_*` metrics, so the clusters without backups (`attic-pg`, `outline-pg`) do not page.

The backup metrics come from the Barman Cloud plugin:

- `barman_cloud_cloudnative_pg_io_last_available_backup_timestamp`: Unix seconds of the last successful backup. Reads 0 until the first plugin-managed backup completes.
- `barman_cloud_cloudnative_pg_io_last_failed_backup_timestamp`: Unix seconds of the last failed backup. Reads 0 when none has failed.
- `cnpg_collector_up`: 1 while the instance metrics endpoint answers.

## Changing a rule

Edit the rule JSON in `apps/grafana-alerts/rules.json` and push. The Job does not re-run when the ConfigMap changes; recreate it:

```bash
kubectl delete job -n grafana-alerts grafana-alerts-provision
flux reconcile kustomization grafana-alerts
```

Add a rule by adding an object to the `rules.json` array with a unique `uid`. Remove a rule from the array and delete it in Grafana as well; the Job does not prune rules.

## Notification routing

Routing is not managed from this repo. Re-apply the contact point and policy by hand after a stack rebuild:

```bash
# contact point (POST creates; a 409 means it exists)
curl -s -X POST -H "Authorization: Bearer $GT" -H "Content-Type: application/json" \
  https://karitham.grafana.net/api/v1/provisioning/contact-points \
  -d '{"name":"discord","type":"discord","settings":{"url":"'"$DISCORD"'"}}'

# root notification policy -> that contact point
curl -s -X PUT -H "Authorization: Bearer $GT" -H "Content-Type: application/json" \
  https://karitham.grafana.net/api/v1/provisioning/policies \
  -d '{"receiver":"discord","group_by":["grafana_folder","alertname"],
       "group_wait":"30s","group_interval":"5m","repeat_interval":"4h"}'
```

`$GT` is the `glsa_` service-account token and `$DISCORD` is the Discord webhook URL. The contact point is named `discord`; the policy's root receiver is `discord`.

## Tokens

Two Grafana Cloud credentials are in play:

- Alloy's write token, in the SOPS-encrypted `apps/alloy/secret.yaml` as `GRAFANA_CLOUD_TOKEN`. The chart injects it into the Alloy pods as an environment variable, and `apps/alloy/config.alloy` reads it with `env("GRAFANA_CLOUD_TOKEN")`. It is scoped for pushing metrics and logs; it cannot query or provision.
- The `glsa_` service-account token, in the SOPS-encrypted `apps/grafana-alerts/secret.yaml`. It authorizes the Grafana API for alerting and folders, and the provisioning Job uses it.

Rotate the service-account token by editing the encrypted file in place:

```bash
sops apps/grafana-alerts/secret.yaml
sops apps/alloy/secret.yaml   # Alloy write token; restart the pods afterwards
```

SOPS decrypts to a temporary file, opens it in `$EDITOR`, and re-encrypts on save. The file's embedded SOPS metadata supplies the recipients, so the command works from any directory. The Alloy pods read the token as an environment variable at startup, so roll them after rotating: `kubectl rollout restart daemonset -n alloy -l app.kubernetes.io/name=alloy`.

## Known quirks

- `ObjectStore.status.lastSuccessfulBackupTime` and `firstRecoverabilityPoint` can stay empty even when plugin backups succeed. Trust the `barman_cloud_*` metrics and the `Backup` CRs, not the CR status.
- The plugin backup metrics read 0 until the first plugin-managed backup runs. After a cluster moves to `method: plugin`, run one backup or wait for the schedule before the stale alert is meaningful.
- `cnpg_collector_last_*` reports stale values after the plugin migration and is not alerted on.
