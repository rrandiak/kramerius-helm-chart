# Kramerius Curator

The administrative Kramerius instance. Handles direct editing of digital objects in the Akubra store (FOXML and datastreams), access control management, and planning of long-running batch processes via the Process Manager. Deployed as a single instance to avoid concurrent write conflicts on the Akubra stores.

## Position in the Stack

```
OpenResty Gateway
    │
    └── /search/api/admin/* ──▶ [Kramerius Curator]  ◀── this component
                                        │
                                        ├── kramerius-db (CNPG PostgreSQL, RW)
                                        ├── Hazelcast :5701 (distributed locks)
                                        ├── Keycloak (OIDC token validation)
                                        ├── Akubra stores (NFS/PVC, read-write)
                                        ├── Import storages (NFS/PVC, read-only)
                                        └── Process Manager (task submission)
```

## Kubernetes Resources

| Resource | Name | Notes |
|---|---|---|
| StatefulSet | `kramerius-curator` | Typically 1 replica (single-writer) |
| Service | `kramerius-curator` | ClusterIP, port 80 → 8080 |
| ServiceAccount | `kramerius-curator` | — |
| ConfigMap | `kramerius-curator-config` | `configuration.properties`, `server.xml` |

## PVCs / Volumes

| Mount path in pod | Volume source | Access mode | Purpose |
|---|---|---|---|
| `/root/.kramerius4/keycloak.json` | `kramerius-keycloak` ConfigMap | RO | OIDC adapter config |
| `/usr/local/tomcat/conf/logging.properties` | `kramerius-tomcat-logging` ConfigMap | RO | Tomcat log config |
| `/data/akubra/objectStore` | `akubra-object-store` PVC/NFS | **ReadWriteMany** | FOXML object storage |
| `/data/akubra/datastreamStore` | `akubra-datastream-store` PVC/NFS | **ReadWriteMany** | External datastream storage (ALTO, TEXT_OCR, etc.) |
| per-entry `mountPath` | `imports[]` PVC/NFS | **ReadOnlyMany** | Import staging areas (inspect only — workers write here). Multiple import storages supported. |
| `/root/.kramerius4/javaagent.jar` | `javaagents` PVC/NFS | RO | Java agent JAR (optional; `javaagent.enabled`) |
| `/usr/local/tomcat/logs` | `tomcat-logs` PVC | RW | Tomcat application logs — each pod gets its own PVC via `volumeClaimTemplates` |

The curator mounts both Akubra stores **read-write** — it is the authoritative editor for FOXML objects and their datastreams. Import volumes are mounted **read-only**; the curator can inspect staged packages but actual processing and cleanup is done by workers.

## Configuration

### configuration.properties

The curator uses the same shared roots as public (`akubraConfig`, `solrConfig`, `auth.keycloak`), plus a **Kramerius** `## Postgresql` JDBC section built from `cnpg.kramerius`, a **Process Manager** section with `processManagerHost` set to the in-cluster service URL (`http://process-manager.<namespace>.svc.cluster.local:8080`), and an **Import** section with `import.directory` auto-generated as a comma-joined list of all `storages.imports[].mountPath` values. Finally it appends **`krameriusCurator.config.configurationPropertiesExtra`** (curator-only keys like optional JDBC pool tuning keys). Both `processManagerHost` in `configuration.properties` and the `PROCESS_MANAGER_URL` env var are set automatically by the chart.

### Environment Variables

| Variable | Source | Description |
|---|---|---|
| `CATALINA_OPTS` | `krameriusCurator.env.CATALINA_OPTS` | JVM flags, defaults to `-Xms4g -Xmx8g` |
| `TOMCAT_PASSWORD` | `krameriusCurator.env.TOMCAT_PASSWORD` | Tomcat manager password |
| `PROCESS_MANAGER_URL` | chart-generated | In-cluster URL for the Process Manager REST API |
| `HAZELCAST_SERVER_ADDRESSES` | chart-generated | Hazelcast host:port (`hazelcast.<namespace>.svc.cluster.local:5701`) |
| `TZ` | `timezone-configmap` | Timezone (`Europe/Prague`) |

### Keycloak

Same `keycloak.json` ConfigMap as the public instance.

## Process Submission

When an administrator triggers a long-running operation (re-index, import, license change, etc.) via the curator API or admin UI, the curator POSTs the task definition to the **Process Manager** REST API. The curator itself does not execute the task — it delegates immediately and returns a task ID to the caller.

```
Admin UI / API client
    │
    ▼
Kramerius Curator  POST /api/processes  ──▶  Process Manager
                                              (persists in process-db)
                                                    │
                                                    ▼
                                              Worker pod
```

The `PROCESS_MANAGER_URL` env var and `processManagerHost` in `configuration.properties` are both set automatically by the chart to point to the in-cluster Process Manager service.

## Scaling

The curator is intentionally kept at **1 replica**. Running multiple write-capable instances concurrently on the same Akubra storage without additional coordination would risk data corruption. Horizontal scaling for write throughput is achieved by adding more worker groups, not more curator replicas.

## Resource Requests / Limits

Defaults in `values.yaml`:

| | Request | Limit |
|---|---|---|
| CPU | `250m` | `1000m` |
| Memory | `6Gi` | `11Gi` |

JVM heap: `-Xms4g -Xmx8g` (tune in `krameriusCurator.env.CATALINA_OPTS`). The 11Gi limit gives ~3Gi of headroom above `Xmx` for JVM off-heap overhead. The curator sees far less traffic than the public instance (admin-only paths), so CPU limits are lower.

## Dependencies

| Component | Protocol | Purpose |
|---|---|---|
| **Gateway** | HTTP (upstream) | Receives admin requests |
| **kramerius-db** | JDBC / PostgreSQL RW | Application metadata, write path |
| **Hazelcast** | TCP :5701 | Distributed locking |
| **Keycloak** (external) | HTTPS / OIDC | Token validation (required for all admin ops) |
| **Akubra stores** | POSIX filesystem RW | Direct FOXML object and datastream editing |
| **Import storages** | POSIX filesystem RO | Inspecting staged import packages (one or more volumes) |
| **Process Manager** | HTTP REST | Task submission |

## Notes

- The gateway routes to this service only for paths matching `curatorPathPrefix`.
- Both the curator and workers hold read-write mounts on the Akubra stores. Concurrent access is coordinated through Hazelcast locks.
- The curator never writes to import volumes. Only workers move or delete staged files there.
