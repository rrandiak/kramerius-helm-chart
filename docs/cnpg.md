# CNPG (PostgreSQL Databases)

The chart provisions two PostgreSQL clusters using the **CloudNative-PG (CNPG)** operator. Each cluster is an independent managed PostgreSQL instance with its own credentials, storage, and connection endpoints.

## Clusters

| Cluster | Name | Database | Owner | Used by |
|---|---|---|---|---|
| Kramerius DB | `kramerius-db` | `kramerius` | `kramerius` | Kramerius Public, Kramerius Curator |
| Process Manager DB | `process-db` | `process` | `process` | Process Manager |

## Position in the Stack

```
Kramerius Public  ──▶  [kramerius-db]  ◀── this component
Kramerius Curator ──▶  [kramerius-db]
Process Manager   ──▶  [process-db]
```

## Kubernetes Resources

For each cluster, the chart creates:

| Resource | Name | Notes |
|---|---|---|
| `Cluster` (CNPG CRD) | `kramerius-db` / `process-db` | Managed by CNPG operator |
| `Secret` | `kramerius-db-secret` / `process-db-secret` | Bootstrap credentials |

Additionally the CNPG operator creates:
- `<cluster-name>-rw` — Service pointing to the primary (read-write)
- `<cluster-name>-ro` — Service pointing to replicas (read-only, if replicas > 1)
- `<cluster-name>-r` — Service pointing to any instance

## Storage

| Cluster | Default size | Storage class | Configured in |
|---|---|---|---|
| `kramerius-db` | `10Gi` | `cnpg.kramerius.storage.storageClass` (empty = cluster default) | `cnpg.kramerius.storage` |
| `process-db` | `10Gi` | `cnpg.processManager.storage.storageClass` (empty = cluster default) | `cnpg.processManager.storage` |

Storage is provisioned as a PVC per PostgreSQL pod by the CNPG operator. When `storageClass` is empty, the cluster's default StorageClass is used.

## Credentials and Secrets

Each cluster requires a bootstrap Secret containing the initial owner password. The chart creates this Secret from the password values:

```yaml
cnpg:
  kramerius:
    password: changeme        # ← change this before deploying
  processManager:
    password: changeme        # ← change this before deploying
```

Secrets must be of type `kubernetes.io/basic-auth` with `username` and `password` fields (the chart uses fixed owner names `kramerius` and `process`).

## Connection Endpoints

| Cluster | Read-Write | Read-Only |
|---|---|---|
| `kramerius-db` | `kramerius-db-rw:5432` | `kramerius-db-ro:5432` |
| `process-db` | `process-db-rw:5432` | `process-db-ro:5432` |

Applications always connect to the `-rw` endpoint so writes land on the primary. The public Kramerius instance could use `-ro` for further load distribution, but currently uses `-rw` by default.

## Topology

Both clusters are configured with `instances: 1` by default — a single primary with no replicas. For production:

```yaml
cnpg:
  kramerius:
    cluster:
      instances: 2    # 1 primary + 1 standby
  processManager:
    cluster:
      instances: 1    # process-db is low-traffic, single instance is fine
```

## Cluster Provisioning

Both CNPG clusters (`kramerius-db` and `process-db`) are always created by the chart.

## Prerequisites

- [CloudNative-PG operator](https://cloudnative-pg.io/) must be installed in the cluster before applying this chart.
- The operator manages the `Cluster` CRD, backup schedules, failover, and connection pooling.

## Notes

- **Never store plain-text passwords** in `values.yaml` committed to version control. Inject credentials via CI/CD pipeline or a secrets manager.
- CNPG handles PostgreSQL upgrades, minor-version patching, and WAL archiving. Check CNPG release notes when upgrading the operator.
- The JDBC URL for `process-manager` is rendered from `cnpg.processManager.cluster.name` (`<name>-rw:5432/process`). Renaming the cluster automatically updates the URL.
