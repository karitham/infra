# Backup & Disaster Recovery (CloudNativePG)

Runbook for recovering a CNPG database on this cluster. Backups go to the
Cloudflare R2 bucket `waifubot-cnpg`. Only `waifubot` has backup configured.

## Inventory

| Object                                   | Purpose                                            |
| ---------------------------------------- | -------------------------------------------------- |
| `Cluster` (`postgresql.cnpg.io/v1`)      | Postgres instances + `spec.plugins` (WAL archiver) |
| `ObjectStore` (`barmancloud.cnpg.io/v1`) | backup destination and retention                   |
| `ScheduledBackup`                        | daily base backup, 02:00 (`method: plugin`)        |
| `Backup`                                 | one-off base backup, created by the schedule       |
| `pg-backup-s3` Secret (in `waifubot`)    | R2 credentials                                     |

Retention lives only in `ObjectStore.spec.retentionPolicy` (currently
`"10d"`). Do not add an R2 bucket lifecycle rule; a second retainer deletes
by object age without knowing what a base backup still needs, silently
shortening the window.

Check the recoverable window:

```bash
kubectl get cluster waifubot-pg -n waifubot \
  -o jsonpath='{.status.firstRecoverabilityPoint}{"\n"}'
```

## Restore

Restore into a new Cluster and verify before cutting over. Do not overwrite
the live cluster: if the restore is bad, the good copy is gone.

### Prerequisites

- `pg-backup-s3` Secret copied into the target namespace (Secrets are
  namespaced).
- An `ObjectStore` of the same name in the target namespace.
- `spec.imageName` pinned to the backup's PostgreSQL major. Backups here are
  PG 17; CNPG 1.30 defaults to PG 18. A mismatch fails with
  `database files are incompatible with server`, and a cross-major restore
  needs `pg_upgrade`, not plain recovery.

```bash
kubectl create namespace pg-restore
kubectl get secret pg-backup-s3 -n waifubot -o json \
  | jq 'del(.metadata.creationTimestamp,.metadata.resourceVersion,.metadata.uid,.metadata.managedFields)
        | .metadata.namespace="pg-restore"' \
  | kubectl apply -f -
```

### Restore to latest

```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata: { name: waifubot-pg, namespace: pg-restore }
spec:
  retentionPolicy: "10d"
  configuration:
    destinationPath: s3://waifubot-cnpg/backups/
    endpointURL: https://<account>.r2.cloudflarestorage.com
    s3Credentials:
      accessKeyId: { name: pg-backup-s3, key: accessKeyId }
      secretAccessKey: { name: pg-backup-s3, key: secretAccessKey }
    wal: { compression: gzip }
    data: { compression: gzip }
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: waifubot-pg-restore, namespace: pg-restore }
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:17.5
  storage: { size: 2Gi, storageClass: local-path }
  externalClusters:
    - name: waifubot-pg
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters: { barmanObjectName: waifubot-pg, serverName: waifubot-pg }
  bootstrap:
    recovery:
      source: waifubot-pg
```

```bash
kubectl apply -f restore.yaml
kubectl get cluster -n pg-restore -w   # Setting up primary -> Cluster in healthy state
```

### Point-in-time recovery

Add a target under `bootstrap.recovery`:

```yaml
bootstrap:
  recovery:
    source: waifubot-pg
    recoveryTarget:
      targetTime: "2026-10-03T14:34:33Z"
```

Replay stops at the last transaction committed at or before `targetTime`.
Other target types: `targetName`, `targetLSN`, `targetXID`, `targetImmediate`.

### Verify

```bash
kubectl exec -n pg-restore waifubot-pg-restore-1 -c postgres -- \
  psql -U postgres -d waifubot -tAc "SELECT max(acquired_at) FROM collection;"
```

For a "latest" restore the counts and newest row match the source. For PITR
they match the target instead. Check both before cutting over.

### Cut over

Repoint consumers at the recovered cluster, then decommission the old one.
Nothing performs cutover automatically.

## Local dump for experiments

Use a logical dump, not the backup bucket:

```bash
kubectl port-forward -n waifubot svc/waifubot-pg-rw 5432:5432 &

PGPASSWORD="$(kubectl get secret pg-credentials -n waifubot \
  -o jsonpath='{.data.password}' | base64 -d)" \
  pg_dump -h localhost -U waifubot waifubot > /tmp/waifubot.sql
```

`pg_dump` is portable across PG versions and easy to inspect, but it is not
a substitute for the physical backups: no PITR.

## Gotchas

- `imageName` must match the backup's PostgreSQL major, or recovery fails.
- A gap in the WAL chain stops replay. Every segment from the base backup
  forward must exist.
- "Latest" only replays WAL archived so far. If archiving stalls, it is
  older than expected.
- Two retention mechanisms fight. Only `ObjectStore.retentionPolicy`.
- The bucket is a base+WAL chain, not a dump. You cannot `psql` it or pull a
  single file out.

## Alerts worth having

`pg_stat_archiver.failed_count` rising, and `ContinuousArchiving=False` on
the Cluster, both mean the recovery window is shrinking.
