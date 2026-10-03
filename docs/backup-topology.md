# Backup topology

Which databases are backed up, where, and how retention works. Restore
procedures are in [waifubot-db-recovery.md](waifubot-db-recovery.md).

## What is backed up

| Cluster       | Namespace  | Backed up | Notes                                |
| ------------- | ---------- | --------- | ------------------------------------ |
| `waifubot-pg` | `waifubot` | yes       | R2, Barman Cloud plugin, daily + WAL |
| `outline-pg`  | `outline`  | **no**    | no backup configured                 |
| `attic-pg`    | `attic`    | **no**    | no backup configured                 |

Only `waifubot` has backups. `outline-pg` and `attic-pg` have no backup, so
protect them with an ad-hoc dump before any change that can lose data. To
give them real backups, configure the same shape as waifubot: an
`ObjectStore`, `plugins` on the `Cluster`, and a `ScheduledBackup`.

## Backup mechanism

The Barman Cloud plugin (chart 0.8.1, installed in `cnpg-system`) writes:

- base backups daily at 02:00 (`ScheduledBackup waifubot-pg-daily-backup`), to
  `base/<timestamp>/`;
- WAL continuously, to `wals/<timeline>/<segment>.gz`.

Both go to the Cloudflare R2 bucket `waifubot-cnpg`, path
`backups/<serverName>/`. The `ObjectStore` CR `waifubot-pg` holds the bucket,
credentials reference, and `retentionPolicy: "10d"`.

## Bucket layout

```
waifubot-cnpg/
  backups/
    waifubot-pg/     # PostgreSQL 17 chain (frozen before the 18 upgrade)
    waifubot-pg18/   # PostgreSQL 18 chain (active)
```

The `serverName` was changed from `waifubot-pg` to `waifubot-pg18` when the
database was upgraded to PostgreSQL 18, so the two major versions do not
share an archive. The `waifubot-pg/` path is **not** written to or pruned by
the plugin any more: it is a frozen pre-upgrade recovery point. Decide its
fate explicitly (keep as an archive, or delete by hand); nothing manages it.

## Retention

Retention is owned only by `ObjectStore.spec.retentionPolicy` (10 days),
which prunes the **active** `serverName` path via the barman catalog. Do not
add an R2 lifecycle rule: a second, catalog-unaware retainer deletes by
object age and can expire WAL a base backup still needs.

Check the effective window:

```bash
kubectl get cluster waifubot-pg -n waifubot \
  -o jsonpath='{.status.firstRecoverabilityPoint}{"\n"}'
```

## Credentials

The R2 access key lives in the `pg-backup-s3` Secret (SOPS-encrypted) in
`waifubot`. It needs Object Read & Write on the bucket only, not bucket
admin. The endpoint host is plaintext in the `ObjectStore`; it is not a
credential.
