# Workers

Workers are the background task execution units. Each worker group is an independent StatefulSet that pulls work from the Process Manager and performs operations like document import, re-indexing, license change, and other long-running batch jobs.

## Position in the Stack

```
Process Manager  ──▶  [Worker Group(s)]  ◀── this component
                              │
                              ├── Akubra stores (NFS/PVC, read-write)
                              ├── Import storage (NFS/PVC, read-write)
                              ├── Image server data (NFS, read-write)
                              ├── Audio server data (NFS, read-write)
                              ├── PDF server data (NFS, read-write)
                              └── process-manager (HTTP callbacks)
```

## Kubernetes Resources

For each entry in `workerGroups`, the chart creates:

| Resource | Name pattern | Notes |
|---|---|---|
| StatefulSet | `worker-<name>` | Headless, `OrderedReady` |
| Service (headless) | `worker-<name>` | `clusterIP: None` — stable pod DNS |
| ServiceAccount | `worker-<name>` | — |
| ConfigMap | `worker-<name>-config` | `configuration.properties`, `server.xml`, `lp.xml` |

The headless service is required so each pod gets a stable DNS name:
```
<pod-name>.worker-<name>.<namespace>.svc.cluster.local
```
This is used as the worker's callback URL for the Process Manager.

## PVCs / Volumes

| Mount path in pod | Volume source | Access mode | Purpose |
|---|---|---|---|
| `/data/akubra/objectStore` | `akubra-object-store` PVC/NFS | **ReadWriteMany** | FOXML objects — written during import |
| `/data/akubra/datastreamStore` | `akubra-datastream-store` PVC/NFS | **ReadWriteMany** | External datastreams (ALTO, TEXT_OCR, etc.) — written during import/OCR |
| `/data/import` | `import` PVC/NFS | **ReadWriteMany** | Staging area — source files for import jobs; workers process and clean up |
| `/data/imageserver` | `imageserver` NFS | **ReadWriteMany** | Image tiles and pyramidal images written during import |
| `/data/audioserver` | `audioserver` NFS | **ReadWriteMany** | Audio files written during import |
| `/data/pdfserver` | `pdfserver` NFS | **ReadWriteMany** | PDF files written during import or generation jobs |
| `/root/.kramerius4/javaagent.jar` | `javaagents` PVC/NFS | RO | Java agent JAR (optional; `javaagent.enabled`) |
| `/usr/local/tomcat/logs` | `tomcat-logs` PVC | RW | Tomcat application logs — each pod gets its own PVC via `volumeClaimTemplates` |

Workers need read-write access to all stores because they produce output in multiple locations during a single import job: FOXML objects and datastreams go into the Akubra stores, image tiles go to the imageserver share, audio files to the audioserver share, and PDFs to the pdfserver share. The media server volumes are typically NFS shares that are also read directly by media server processes running outside the cluster.

## Configuration

### Worker Groups

Worker groups are defined in `values.yaml` under `workerGroups`. The default image for all groups is set via `defaultWorkerImage` (top-level key):

```yaml
defaultWorkerImage:
  repository: ceskaexpedice/curator-worker
  tag: "7.2.0"
  pullPolicy: Always
```

Each group can override the image and specify its own settings:

```yaml
workerGroups:
  - name: curator
    replicas: 1
    # image:                    # optional — overrides defaultWorkerImage
    #   repository: ceskaexpedice/curator-worker
    #   tag: "7.2.0"
    env:
      CATALINA_OPTS: "-Xms512M -Xmx2G"
    # profilesSubset: "import,new_indexer_index_object"  # empty = all process types
```

Tomcat logs for all worker groups are configured via the top-level `workerTomcatLogs` key (not per-group):

```yaml
workerTomcatLogs:
  type: pvc
  storageClass: nfs
  size: 5Gi
```

Multiple groups can be deployed simultaneously. This allows:
- **Specialisation** — one group for indexing, one for import, etc. (via `profilesSubset`)
- **Scale** — more replicas in a group for parallel execution of the same job type

### configuration.properties

Each worker group gets the shared roots (`akubraConfig`, `solrConfig`, `auth.keycloak`). Workers do **not** connect to any database — all task state is managed by the Process Manager. Worker-specific properties (for example `import.directory`, image-server conversion flags) go in `workerGroups[].config.configurationPropertiesExtra`.

| Mechanism | Description |
|---|---|
| `MANAGER_BASE_URL` / `WORKER_BASE_URL` | Set via environment (not `configuration.properties`) for Process Manager callbacks |
| `HAZELCAST_SERVER_ADDRESSES` | Chart-generated: `hazelcast.<namespace>.svc.cluster.local:5701` |

### Environment Variables

| Variable | Source | Description |
|---|---|---|
| `CATALINA_OPTS` | `workerGroups[].env.CATALINA_OPTS` | JVM flags |
| `WORKER_BASE_URL` | rendered per-pod | `http://$(POD_NAME).worker-<name>.<ns>.svc.cluster.local:8080/worker/api/` |
| `MANAGER_BASE_URL` | process manager service | URL for task status callbacks |
| `PROFILES_SUBSET` | `workerGroups[].profilesSubset` | Comma-separated list of process types (empty = all) |
| `TZ` | `timezone-configmap` | Timezone (`Europe/Prague`) |
| `HAZELCAST_SERVER_ADDRESSES` | chart-generated | Hazelcast host:port (`hazelcast.<namespace>.svc.cluster.local:5701`) |

### lp.xml

Worker-specific configuration file (`lp.xml`) is also rendered into the ConfigMap. It contains process profiles settings for the worker application.

## Task Execution Flow

```
1. Process Manager selects an available worker pod
2. Process Manager POSTs task payload to worker's WORKER_BASE_URL
3. Worker executes task (reads/writes Akubra + import storage)
4. Worker POSTs progress/completion updates back to MANAGER_BASE_URL
5. Process Manager updates task status in process-db
```

Because each pod has a unique, stable DNS name, the Process Manager can address a specific pod for task status — even across restarts (StatefulSet preserves pod ordinal naming).

## Scaling

- Increase `workerGroups[].replicas` to parallelize task execution.
- Add new groups to `workerGroups` for job type isolation.
- Workers are stateless with respect to Kubernetes — all persistent state is in the Akubra stores or process-db.

## Resource Requests / Limits (defaults)

| | Request | Limit |
|---|---|---|
| CPU | `250m` | `1500m` |
| Memory | `640Mi` | `3Gi` |

The 3Gi memory limit covers the JVM heap (`-Xmx2G`) plus ~1Gi for JVM overhead. Workers can be CPU-intensive during bulk imports and indexing runs, so the CPU limit is higher than other JVM components with the same heap. Tune `env.CATALINA_OPTS` heap and these limits together if workers handle very large imports.

## Dependencies

| Component | Protocol | Purpose |
|---|---|---|
| **Process Manager** | HTTP | Receives task payloads; sends status callbacks |
| **Akubra stores** | POSIX filesystem RW | Read and write FOXML objects and datastreams |
| **Import storage** | POSIX filesystem RW | Read source files for import; clean up after processing |
| **Image server data** | NFS RW | Write image tiles and pyramidal images during import |
| **Audio server data** | NFS RW | Write audio files during import |
| **PDF server data** | NFS RW | Write PDF files during import or generation jobs |
| **Hazelcast** | TCP :5701 | Distributed locking (if used by worker image) |

## Notes

- `profilesSubset` is optional. An empty list means the worker accepts all process types registered with the Process Manager. Populate it to restrict a group to specific job types (e.g., only OCR jobs).
- The headless service is critical — do not change it to a ClusterIP service. Without per-pod DNS names the Process Manager cannot address individual workers.
- Worker images may differ per group (`workerGroups[].image`). The default curator-worker image handles the standard Kramerius ingest and management processes.
