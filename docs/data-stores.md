# Data Stores

Shared persistent volumes supply storage for Kramerius Public, Kramerius Curator, the process manager, and workers. They hold FOXML objects, external datastreams, staged import packages, and files written for image, audio, and PDF delivery.

Kramerius does not serve those media files itself. Separate components (for example IIPImage for tiled images) read the same directories that workers populate, often from an **NFS export** mounted both on worker pods and on the media hosts.

Most data volumes are declared under `storages` in `values.yaml` as **`pvc`** (a `PersistentVolumeClaim`, usually with ReadWriteMany) or **`nfs`** (a direct NFS mount in the pod, no PVC). **imageserver**, **audioserver**, and **pdfserver** are commonly **`nfs`** so services outside the cluster can mount the same path. The **`tomcat-logs`** PVC/NFS is configured per component (public/curator/process-manager/workers), not under `storages`.

## Volumes

| Volume | Default mount path | Who mounts | Access |
|---|---|---|---|
| `akubra-object-store` | `/data/akubra/objectStore` | Public (RO), Curator (RW), Workers (RW) | ReadWriteMany / ReadOnlyMany |
| `akubra-datastream-store` | `/data/akubra/datastreamStore` | Public (RO), Curator (RW), Workers (RW) | ReadWriteMany / ReadOnlyMany |
| `import` | `/data/import` | Curator (RO), Workers (RW) | ReadWriteMany |
| `imageserver` | `/data/imageserver` | Workers (RW) | ReadWriteMany |
| `audioserver` | `/data/audioserver` | Workers (RW) | ReadWriteMany |
| `pdfserver` | `/data/pdfserver` | Workers (RW) | ReadWriteMany |
| `tomcat-logs` | `/usr/local/tomcat/logs` | Public (RW), Curator (RW), Process Manager (RW), Workers (RW) | ReadWriteOnce (PVC) / ReadWriteMany (NFS) |
| `javaagents` | `/root/.kramerius4/javaagent.jar` (single file when `javaagent.enabled`) | Public (RO), Curator (RO), Process Manager (RO), Workers (RO) | ReadOnlyMany |

## Akubra Object Store

Stores **FOXML objects** — the canonical metadata and content model records for every digitized document. Each FOXML file describes a digital object: its datastreams, relationships, and descriptive metadata. Organized according to the Akubra fedora-compatible layout.

- **Read by**: Kramerius Public (resolving document objects), Kramerius Curator (reading and editing objects), Workers (during processing)
- **Written by**: Kramerius Curator (direct object editing), Workers (import jobs writing new objects)
- **Volume name**: `akubra-object-store`
- **Path inside**: `/data/akubra/objectStore`

## Akubra Datastream Store

Stores **external datastreams** referenced by FOXML objects — content of datastreams that are marked E in FOXML (external). Typical datastreams include:

- `ALTO` — layout analysis XML (word coordinates for full-text search)
- `TEXT_OCR` — plain-text OCR output
- Other structured metadata or binary attachments

- **Read by**: Kramerius Public (serving datastream content), Kramerius Curator, Workers
- **Written by**: Workers (storing datastreams during import)
- **Volume name**: `akubra-datastream-store`
- **Path inside**: `/data/akubra/datastreamStore`

## Import Volume

A staging area for content being ingested into the library. Operators or automated pipelines drop source packages (FOXML archives, image sets, etc.) here. Workers read from this staging area, process the content, and write results to the Akubra stores and media server volumes. The curator mounts this volume **read-only** — it can inspect staged content but does not write or clean it up.

- **Read by**: Kramerius Curator (RO — inspect staged packages), Workers (RW — process and clean up)
- **Volume name**: `import`
- **Path inside**: `/data/import`

## Image Server Data

Stores image files written by workers during import jobs. The image server (IIPImage) reads from this same NFS share to serve images to clients. Workers are the only component that write here.

- **Written by**: Workers (during import — writing source images)
- **Typically**: NFS share shared with the image server process
- **Volume name**: `imageserver`
- **Path inside**: `/data/imageserver`

## Audio Server Data

Stores audio files written by workers during import jobs. The audio server reads from this same NFS share to serve audio to clients.

- **Written by**: Workers (during import — copying audio files)
- **Typically**: NFS share shared with the audio server process
- **Volume name**: `audioserver`
- **Path inside**: `/data/audioserver`

## PDF Server Data

Stores PDF files written by workers during import jobs or on-demand PDF generation. The PDF server reads from this NFS share to serve downloads.

- **Written by**: Workers (during import or PDF generation jobs)
- **Typically**: NFS share shared with the PDF server process
- **Volume name**: `pdfserver`
- **Path inside**: `/data/pdfserver`

## Tomcat Logs Volume

Stores Tomcat application logs for all app pods (Public, Curator, Process Manager, Workers). Each pod gets its own PVC via `volumeClaimTemplates`, so logs from different replicas are isolated.

- **Written by**: All app pods
- **Volume name**: `tomcat-logs`
- **Path inside pod**: `/usr/local/tomcat/logs`
- **Typically**: `type: pvc` — each pod gets its own `ReadWriteOnce` PVC

## Java Agents Volume

Holds the Java agent JAR on the shared volume. When `javaagent.enabled: true`, the chart mounts **one** file from this directory into every application pod at a fixed path: `/root/.kramerius4/javaagent.jar`. The filename inside the volume is set with `javaagent.jarFile` (default `opentelemetry-javaagent.jar`).

- **Read by**: Kramerius Public, Curator, Workers, Process Manager
- **Volume name**: `javaagents`
- **Path inside pod**: `/root/.kramerius4/javaagent.jar` (file mount via `subPath`)

## Storage Backend Configuration

Each volume is configured independently in `values.yaml`:

```yaml
storages:
  defaultNfsServer: nfs.example.com   # fallback for any nfs volume without nfsServer

  akubra-object-store:
    type: nfs            # "pvc" or "nfs" (default: nfs)
    nfsServer: ""        # empty = uses defaultNfsServer
    nfsPath: /data/kramerius/akubra/objectStore
    existingClaim: ""    # set to reuse an existing PVC; chart skips PVC creation
    storageClass: nfs    # used when type: pvc
    size: 50Gi

  akubra-datastream-store:
    type: nfs
    nfsPath: /data/kramerius/akubra/datastreamStore
    storageClass: nfs
    size: 50Gi

  import:
    type: nfs
    nfsPath: /data/kramerius/import
    storageClass: nfs
    size: 50Gi

  # Media server volumes — typically NFS so the media server processes
  # running outside the cluster can mount the same share.
  imageserver:
    type: nfs
    nfsPath: /data/imageserver

  audioserver:
    type: nfs
    nfsPath: /data/audioserver

  pdfserver:
    type: nfs
    nfsPath: /data/pdfserver

  javaagents:
    type: nfs
    nfsPath: /data/javaagents
```

### PVC Mode

When `type: pvc`, the chart creates a `PersistentVolumeClaim` (unless `existingClaim` is set). The StorageClass must support `ReadWriteMany` (RWX) access mode — most NFS-backed StorageClasses and some CSI drivers (e.g. NFS CSI, Ceph RBD with rwx) satisfy this.

Note: `tomcatLogs` is configured per component (`krameriusPublic.tomcatLogs`, `krameriusCurator.tomcatLogs`, `processManager.tomcatLogs`, `workerTomcatLogs`). Each pod gets its own `ReadWriteOnce` PVC via `volumeClaimTemplates`.

If `storageClass` is empty for a PVC-backed volume, the chart falls back to `defaultStorageClass`.

If `existingClaim` is set, the chart skips PVC creation and mounts the named claim directly.

### NFS Mode

When `type: nfs`, volumes are mounted directly as `nfs` volume types in the pod spec (no PVC is created). `nfsPath` must be set. `nfsServer` can be omitted if `storages.defaultNfsServer` is set — the chart uses it as a fallback for any NFS volume that does not specify its own server:

```yaml
storages:
  defaultNfsServer: nfs.example.com   # used for all nfs volumes without an explicit nfsServer

  imageserver:
    type: nfs
    nfsPath: /exports/imageserver     # nfsServer falls back to defaultNfsServer

  audioserver:
    type: nfs
    nfsServer: other-nfs.example.com  # override for this volume only
    nfsPath: /exports/audioserver
```

This is the recommended mode for `imageserver`, `audioserver`, and `pdfserver` because the same NFS export is typically mounted by media server processes running outside Kubernetes.

## Access Modes Summary

| Volume | Kramerius Public | Kramerius Curator | Process Manager | Workers |
|---|---|---|---|---|
| `objectStore` | ReadOnly | ReadWrite | — | ReadWrite |
| `datastreamStore` | ReadOnly | ReadWrite | — | ReadWrite |
| `import` | — | **ReadOnly** | — | ReadWrite |
| `imageserver` | — | — | — | ReadWrite |
| `audioserver` | — | — | — | ReadWrite |
| `pdfserver` | — | — | — | ReadWrite |
| `tomcat-logs` | ReadWrite (RWO request) | ReadWrite (RWO request) | ReadWrite (RWO request) | ReadWrite (RWO request) |
| `javaagents` | ReadOnly | ReadOnly | ReadOnly | ReadOnly |

## Coordination

Multiple pods holding read-write mounts on the same NFS/PVC volume can conflict. Write coordination is handled by **Hazelcast locks** — all writers (curator, workers) must acquire the appropriate distributed lock before modifying objects in the Akubra stores.

## Sizing Guidance

| Volume | Typical size | Notes |
|---|---|---|
| `objectStore` | 50 Gi – several TB | Grows with every imported document |
| `datastreamStore` | 50 Gi – several TB | Roughly proportional to objectStore |
| `import` | 50 Gi+ | Needs headroom for the largest single batch |
| `imageserver` | 50 Gi – several TB | Image tiles; size depends on resolution and collection |
| `audioserver` | variable | Depends on audio collection size |
| `pdfserver` | variable | Depends on PDF generation volume |
| `tomcat-logs` | 5 Gi | One sub-directory per pod; size depends on log verbosity and retention |
| `javaagents` | 1 Gi | Rarely changes |
