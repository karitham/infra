# Cluster operations

How to work on the riko cluster: the GitOps flow, how to make and verify a
change, and the conventions that must not break.

## The flow

FluxCD reconciles `main` of this repo. There is no imperative path: every
change is a commit, pushed, then applied by Flux.

- `GitRepository flux-system` tracks `branch: main`, polls every 1m.
- Root `Kustomization flux-system` applies `./clusters/riko` (core + apps)
  every 10m, `prune: true`.
- App Kustomizations (`clusters/riko/apps/*.yaml`) each point at `./apps/<name>`.

Flux applies the tip of `main`, not individual commits. Pushing several
commits at once means Flux sees one snapshot, and intermediate states never
happen. To realize a sequence (e.g. per-cluster upgrades), push and reconcile
one commit at a time.

### Making a change

```bash
# edit, then commit (jj)
jj commit -m "area: change"

# advance main and push
jj bookmark set main -r <change-id>
jj git push -b main

# apply immediately instead of waiting for the poll
flux reconcile kustomization <name> --with-source
```

Then verify:

```bash
kubectl get kustomizations -A                 # all True?
kubectl get pods -A | grep -v Running         # nothing stuck?
```

### Adding an app

1. `apps/<name>/` with manifests + `kustomization.yaml`.
2. `clusters/riko/apps/<name>.yaml` — a Flux Kustomization, `path: ./apps/<name>`.
3. Add it to `clusters/riko/apps/kustomization.yaml`.
4. Push.

### Adding a core component

Core lives under `clusters/riko/core/` and is applied by the root sync, so
it is listed in `clusters/riko/core/kustomization.yaml`. Components that are
their own Helm release follow the `cert-manager` shape (inline
HelmRepository + HelmRelease). Components that need a health gate (a CRD
other Kustomizations depend on) follow the `cnpg` / `barman-plugin` shape: a
nested Flux Kustomization with `wait: true`.

## Conventions

- Secrets are SOPS+age. Rules in `.sops.yaml`; Flux decrypts with the
  `sops-age` Secret in `flux-system`. Only credential values belong in a
  Secret. Do not encrypt non-secrets; an R2 endpoint host is plaintext.
- `${TSNET}` substitution is scoped, not global. The root patch applies it
  only to the ingress apps, because a blanket `postBuild.substitute` runs
  envsubst over every Kustomization and breaks on upstream `${...}` text. If
  a new app needs `${TSNET}`, add its name to the regex in
  `clusters/riko/kustomization.yaml`.
- Retention is owned in one place. Backup retention lives in the `ObjectStore`
  CR only. Do not add an R2 lifecycle rule; two retainers fight and the
  shorter one silently wins.
- `imageName` is explicit on every CNPG `Cluster`. Do not rely on the operator
  default, which changes between CNPG versions.
- Versions are pinned. Helm charts and operator releases are pinned; `*` is
  reserved for the few apps with Flux image automation.

## Cluster facts

- Single node `k1`, k3s on Ubuntu 26.04 (Oracle ARM64), SQLite datastore.
- k3s upgrades: official `get.k3s.io` installer with `INSTALL_K3S_VERSION`
  pinned; back up `state.db` + `server/token` first.
- OS release upgrades: LTS to LTS, one hop per session, cluster verified
  between hops. See [os-upgrades.md](os-upgrades.md).
- Postgres: CNPG, all clusters on PostgreSQL 18. See
  [backup-topology.md](backup-topology.md) and
  [postgres-upgrades.md](postgres-upgrades.md).

## Version management

- Flux upgrades across a minor require `flux migrate`. Flux 2.9 removed the
  `image/v1beta2` and `notification/v1beta2` CRDs; the CRD update is rejected
  until stale `status.storedVersions` are cleared. Migrate the manifests
  (`flux migrate -f .`) and the cluster (`flux migrate`) before bumping the
  toolkit. Because Flux is self-managing, a rejected CRD wedges the controller
  reconciling its own manifests.
- Dry-run against the live cluster before a self-managing bump.
  `kubectl apply --dry-run=server` on the changed manifests catches CRD
  validation that reading release notes does not.
- `imageName` and `serverName` move together on a PG major upgrade (see
  [postgres-upgrades.md](postgres-upgrades.md)).

## Support matrix

The cluster runs k3s 1.37, which is ahead of the tested Kubernetes range of
every controller: Flux 2.9 supports 1.34–1.36, cert-manager 1.21 supports
1.33–1.36, CNPG 1.30 supports 1.34–1.36. Treat further k8s bumps with care.
