# Kramerius Public

The public-facing Kramerius instance. Serves the search API, IIIF endpoints, and document viewer for end users. Reads content from the Akubra stores and can write to the kramerius-db database (e.g. user folders). Can be scaled horizontally.

## Position in the Stack

```
OpenResty Gateway
    │
    └── /* ──▶ [Kramerius Public]  ◀── this component
                    │
                    ├── kramerius-db (CNPG PostgreSQL, RW)
                    ├── Hazelcast :5701 (distributed locks)
                    ├── Keycloak (OIDC token validation)
                    ├── Akubra stores (NFS/PVC, read-only)
                    └── Process Manager (task submission)
```

## Kubernetes Resources

| Resource | Name | Notes |
|---|---|---|
| StatefulSet | `kramerius-public` | `replicas` configurable |
| Service | `kramerius-public` | ClusterIP, port 80 → 8080 |
| ServiceAccount | `kramerius-public` | — |
| ConfigMap | `kramerius-public-config` | `configuration.properties`, `server.xml` |

Pod anti-affinity (`requiredDuringSchedulingIgnoredDuringExecution`) ensures replicas land on different nodes.

## PVCs / Volumes

| Mount path in pod | Volume source | Access mode | Purpose |
|---|---|---|---|
| `/root/.kramerius4/keycloak.json` | `kramerius-keycloak` ConfigMap | RO | OIDC adapter config |
| `/usr/local/tomcat/conf/logging.properties` | `kramerius-tomcat-logging` ConfigMap | RO | Tomcat log config |
| `/data/akubra/objectStore` | `akubra-object-store` PVC/NFS | **ReadOnlyMany** | FOXML object storage |
| `/data/akubra/datastreamStore` | `akubra-datastream-store` PVC/NFS | **ReadOnlyMany** | Datastream storage |
| `/root/.kramerius4/javaagent.jar` | `javaagents` PVC/NFS | RO | Java agent JAR (optional; `javaagent.enabled`) |
| `/usr/local/tomcat/logs` | `tomcat-logs` PVC/NFS | RW | Tomcat application logs — each pod writes to its own PVC |

The public instance mounts both Akubra stores **read-only**. It never writes to storage directly.

## Configuration

### configuration.properties

The chart renders `configuration.properties` from shared roots (`akubraConfig`, `solrConfig`, and `auth.keycloak`) plus:
- a **Kramerius** `## Postgresql` JDBC section built from `cnpg.kramerius` (URL/user/pass)
- and finally the per-component tail `krameriusPublic.config.configurationPropertiesExtra` (where you can add JDBC pool tuning keys like `jdbcMaximumPoolSize`, `jdbcLeakDetectionThreshold`, `jdbcConnectionTimeout`, ...).

The result is stored in `kramerius-public-config` and mounted at `/root/.kramerius4/configuration.properties`.

Structured values:

| Section | Source | Notes |
|---|---|---|
| Akubra | `akubraConfig` | Set **patterns only** (`objectStore.pattern`, `datastreamStore.pattern`). Paths are always `/data/akubra/objectStore` and `/data/akubra/datastreamStore` (pod mounts). |
| Solr | `solrConfig` | `search` / `searchUseComposite` / `processing` / `sdnnt` / `logs` / `monitor` map to `solrSearchHost`, `solrSearch.useCompositeId`, `solrProcessingHost`, `solrSdnntHost`, `k7.log.solr.point`, `api.monitor.point`. |
| Keycloak | `auth.keycloak` | Drives `keycloak.json` (ConfigMap) and `keycloak.tokenurl` / `keycloak.clientId` / `keycloak.secret` in `configuration.properties`. |
| JDBC (Kramerius DB only) | `cnpg.kramerius` | `jdbcUrl` / `jdbcUserName` / `jdbcUserPass` are built from the Kramerius CNPG cluster (`<cluster.name>-rw`) with fixed database/owner (`kramerius`). Pool tuning keys can be added in `krameriusPublic.config.configurationPropertiesExtra`. |
| Process Manager | chart-generated | `processManagerHost` is set to `http://process-manager.<namespace>.svc.cluster.local:8080`. |

`HAZELCAST_SERVER_ADDRESSES` and `PROCESS_MANAGER_URL` are set automatically by the chart (Hazelcast to `hazelcast.<namespace>.svc.cluster.local:5701`, Process Manager to the in-cluster service URL). The chart also sets `processManagerHost` in `configuration.properties` to the in-cluster Process Manager host.

### Environment Variables

| Variable | Source | Description |
|---|---|---|
| `CATALINA_OPTS` | `krameriusPublic.env.CATALINA_OPTS` | JVM flags, defaults to `-Xms4g -Xmx8g` |
| `TOMCAT_PASSWORD` | `krameriusPublic.env.TOMCAT_PASSWORD` | Tomcat manager password |
| `PROCESS_MANAGER_URL` | chart-generated | In-cluster URL for the Process Manager REST API |
| `HAZELCAST_SERVER_ADDRESSES` | chart-generated | Hazelcast host:port (`hazelcast.<namespace>.svc.cluster.local:5701`) |
| `TZ` | `timezone-configmap` | Timezone (`Europe/Prague`) |

### Keycloak

`keycloak.json` is mounted from the `kramerius-keycloak` ConfigMap, generated from **`auth.keycloak`** in `values.yaml`. It configures the Keycloak adapter with:
- realm
- auth-server-url (external Keycloak)
- resource (client ID)
- credentials secret

Authentication is optional per endpoint — public document access is unauthenticated, admin/curator paths require a valid token.

## Scaling

`krameriusPublic.replicas` controls the replica count. Because both akubra stores are mounted read-only, there are no write conflicts between replicas.

Pod anti-affinity prevents colocation so a single node failure does not take down all replicas.

## Resource Requests / Limits

Defaults in `values.yaml`:

| | Request | Limit |
|---|---|---|
| CPU | `500m` | `2000m` |
| Memory | `6Gi` | `11Gi` |

JVM heap is set via `CATALINA_OPTS` (`-Xms4g -Xmx8g`). The 6Gi request covers the initial heap (`-Xms4g`) plus JVM overhead; the 11Gi limit gives ~3Gi of headroom above `Xmx` for off-heap memory (metaspace, code cache, direct buffers). The 2 CPU limit allows bursting during search-heavy traffic.

## Dependencies

| Component | Protocol | Purpose |
|---|---|---|
| **Gateway** | HTTP (upstream) | Receives all public requests |
| **kramerius-db** | JDBC / PostgreSQL RW | Application metadata; public instance may write (e.g. statistics) |
| **Hazelcast** | TCP :5701 | Distributed locking |
| **Keycloak** (external) | HTTPS / OIDC | Token validation |
| **Akubra stores** | POSIX filesystem | FOXML object reads |
| **Process Manager** | HTTP REST | Task submission |

## Notes

- This instance is read-only with respect to the **Akubra stores** — it never writes FOXML objects or datastreams. It may write to kramerius-db (user folders, etc.) which is safe to do from multiple replicas.
- Like the curator, the public instance can submit tasks to the Process Manager (e.g. user-triggered operations). The `PROCESS_MANAGER_URL` env var and `processManagerHost` in `configuration.properties` are both set automatically by the chart.
