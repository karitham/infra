# PostgreSQL major upgrades

Procedure for moving a CNPG `Cluster` to a higher PostgreSQL major version.

## Read the upgrade doc first

Before any version hop, read CNPG's `postgres_upgrades.md` for the range you
are crossing. Grep it for `must`, `before`, `breaking`, `requires`, and
version ranges. Known caveat: PostgreSQL 17.0 through 17.5 has a bug that
breaks `pg_upgrade` when replication slots exist, fixed in 17.6.

## Two kinds of upgrade

|                | Minor (17.5 → 17.11)        | Major (17 → 18)               |
| -------------- | --------------------------- | ----------------------------- |
| on-disk format | compatible                  | incompatible                  |
| mechanism      | image swap, rolling restart | `pg_upgrade`                  |
| downtime       | none                        | yes, offline                  |
| backups        | chain continues             | chain branches (`serverName`) |

Bump the minor first. It is cheap and clears preconditions for the major.

## Preconditions

1. Same OS distro. Check both images before starting:

   ```bash
   kubectl run pgimg -n default --rm -i --restart=never \
     --image=ghcr.io/cloudnative-pg/postgresql:18.4 --command -- \
     sh -c 'postgres --version; grep CODENAME /etc/os-release'
   ```

   If the target major is a different distro, move the current major to that
   distro first. Here all of 17.5, 17.11, and 18.4 were Debian 11 bullseye.

2. Extensions available in the target major. List them:

   ```bash
   kubectl exec -n <ns> <cluster>-1 -c postgres -- \
     psql -U postgres -tAc "SELECT extname, extversion FROM pg_extension;"
   ```

3. A safety backup. For clusters without CNPG backup, take a logical dump (see
   [waifubot-db-recovery.md](waifubot-db-recovery.md)); for backed-up
   clusters, take an on-demand `Backup`.

## Procedure (per cluster)

1. Minor bump. Set `spec.imageName` to the latest patch of the current major
   (e.g. `17.11`). Push. It rolls as a normal restart.
2. Verify the cluster is healthy and on the new minor.
3. Major bump.
   - Set `spec.imageName` to the target major (e.g. `18.4`).
   - If the cluster has the Barman plugin, also change
     `spec.plugins[].parameters.serverName` (e.g. `waifubot-pg` →
     `waifubot-pg18`) in the same commit. This starts a fresh archive so the
     pre-upgrade chain is preserved.
   - Push and reconcile. The cluster shuts down and a
     `<cluster>-1-major-upgrade` job runs `pg_upgrade --link`.
4. Verify:
   ```bash
   kubectl exec -n <ns> <cluster>-1 -c postgres -- \
     psql -U postgres -tAc "SELECT version();"
   # row counts against a known table
   ```
5. Run `VACUUM ANALYZE`; CNPG does not do this after a major upgrade:
   ```bash
   kubectl exec -n <ns> <cluster>-1 -c postgres -- \
     psql -U postgres -d <db> -c "VACUUM ANALYZE;"
   ```

## Rollback

A failed major upgrade can be rolled back by reverting `imageName` (and
`serverName`) before the upgrade job completes. CNPG deletes the job and
restarts on the old version. After it completes the on-disk format is 18 and
there is no downgrade; restore from backup instead.

## Timing

Offline window is dominated by `pg_upgrade --link` on the data size. Rough
sizing for riko's databases: tens of MB take seconds to a minute, hundreds of
MB a few minutes. Plan for downtime per cluster.
