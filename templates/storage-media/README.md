# Storage Media

Media storage provides the output volumes where Kramerius workers write derivative media files produced during ingestion and conversion. Three independent volumes are supported: `imageserver` (JPEG2000/IIIF-compatible image tiles and pyramids), `audioserver` (compressed audio derivatives), and `pdfserver` (generated PDF output). Each volume is optional — configure only the types relevant to your deployment.

These volumes are shared with external media server processes running outside the Kubernetes cluster. Typically each volume is an NFS share that the external image/audio/pdf server mounts directly. Workers write into the share; the external media server reads from the same paths to serve content to end users via Kramerius Public.

## Position in the Stack

```mermaid
flowchart LR
  W[workers] -->|RW| IM[/data/imageserver
NFS/PVC]
  W -->|RW| AU[/data/audioserver
NFS/PVC]
  W -->|RW| PDF[/data/pdfserver
NFS/PVC]

  EXTIMG[External IIPImage / Cantaloupe] -->|read| IM
  EXTAUD[External audio server] -->|read| AU
  EXTPDF[External PDF service] -->|read| PDF
```

Workers are the only Kubernetes workloads that mount media volumes. The external media servers (image, audio, PDF) are not managed by this chart — they mount the same NFS exports directly.

## Kubernetes Resources

A PV + PVC pair is created for each configured media volume when `type: nfs` and no `existingClaim` is set. When `type: pvc` without `existingClaim`, only a PVC is created.

| Resource | Name | Notes |
|---|---|---|
| PersistentVolume | `<release>-imageserver` | Created when `storages.imageserver.type` is set and no `existingClaim` |
| PersistentVolumeClaim | `<release>-imageserver` | `ReadWriteMany` |
| PersistentVolume | `<release>-audioserver` | Created when `storages.audioserver.type` is set and no `existingClaim` |
| PersistentVolumeClaim | `<release>-audioserver` | `ReadWriteMany` |
| PersistentVolume | `<release>-pdfserver` | Created when `storages.pdfserver.type` is set and no `existingClaim` |
| PersistentVolumeClaim | `<release>-pdfserver` | `ReadWriteMany` |

If a media volume's `type` key is absent (commented out), no resources are created for that volume and it is not mounted in worker pods.

## PVCs / Volumes

| Mount path in pod | Volume name | Access mode | Consumers | Purpose |
|---|---|---|---|---|
| `/data/imageserver` | `imageserver-storage` | ReadWriteMany | workers (RW) | Image tiles, pyramids, IIIF derivatives |
| `/data/audioserver` | `audioserver-storage` | ReadWriteMany | workers (RW) | Audio derivatives (MP3, OGG, etc.) |
| `/data/pdfserver` | `pdfserver-storage` | ReadWriteMany | workers (RW) | Generated PDF output |

Only workers mount media volumes. `kramerius-public` and `kramerius-curator` do not mount media storage directly.

## Configuration

### Enabling media volumes

A media volume is enabled by setting its `type` key. Leaving a volume block empty (all keys commented out) disables it — no PV/PVC is created and the volume is not mounted in worker pods.

### Media conversion properties (`convert.*`)

Worker conversion behavior and generated media URLs are configured under `convert`.
These values are rendered into the `Media` section of `configuration.properties`.

```yaml
convert:
  imageserver:
    enabled: false
    directory: /mzk
    useContract: true
    subfolders: true
    removeExtensions: true
    tilesUrlPrefix: https://imageserver.example.com${convert.imageServerDirectory}
    imagesUrlPrefix: http://imageserver.example.com${convert.imageServerDirectory}
    suffixBig: /big.jpg
    suffixThumb: /thumb.jpg
    suffixPreview: /preview.jpg
    suffixTiles: ""
  audioserver:
    enabled: false
    urlPrefix: http://audioserver.example.com
    directory: /mnt/audioserver
    subfolders: true
```

```yaml
storages:
  # Fallback NFS server used when a volume's nfsServer is empty.
  defaultNfsServer: "10.0.1.10"

  imageserver:
    type: nfs
    nfsServer: ""                    # Empty uses defaultNfsServer
    nfsPath: /data/imageserver
    existingClaim: ""
    storageClass: nfs
    size: 50Gi
    mountOptions:
      - hard
      - nfsvers=4.1

  audioserver:
    type: nfs
    nfsServer: ""
    nfsPath: /data/audioserver
    existingClaim: ""
    storageClass: nfs
    size: 10Gi
    mountOptions: []

  pdfserver:
    type: nfs
    nfsServer: ""
    nfsPath: /data/pdfserver
    existingClaim: ""
    storageClass: nfs
    size: 10Gi
    mountOptions: []
```

### Disabling individual media volumes

Leave the block empty (type key absent) to disable a volume entirely:

```yaml
storages:
  imageserver:
    type: nfs
    nfsPath: /data/imageserver
    size: 50Gi

  audioserver: {}    # Disabled — no PVC created, not mounted in workers

  pdfserver: {}      # Disabled — no PVC created, not mounted in workers
```

### Using an existing claim

To attach a pre-provisioned PVC:

```yaml
storages:
  imageserver:
    type: pvc
    existingClaim: my-imageserver-pvc
    size: 200Gi      # Informational only when existingClaim is set
```

### Backend types reference

| `type` | PV created? | PVC created? | Notes |
|---|---|---|---|
| `nfs` + no `existingClaim` | Yes | Yes | Chart creates static PV + PVC bound by name |
| `nfs` + `existingClaim` set | No | No | Named claim used directly |
| `pvc` + no `existingClaim` | No | Yes | Dynamic provisioning via `storageClass` |
| `pvc` + `existingClaim` set | No | No | Named claim used directly |
| key absent / empty map | No | No | Volume not mounted in any pod |

## Resource Requests / Limits

Media storage volumes carry no standalone compute resources. Storage capacity and throughput are the critical operational parameters.

| Volume | Typical size range | Access pattern |
|---|---|---|
| `imageserver` | 50 Gi – several TB | Write-once by workers; sequential reads by image server |
| `audioserver` | 10 Gi – 500 Gi | Write-once by workers; sequential reads by audio server |
| `pdfserver` | 10 Gi – 500 Gi | Write-once by workers; sequential reads by PDF service |

Use `hard` NFS mounts with `nfsvers=4.1` for production deployments to prevent silent stale-handle failures during long worker conversion jobs.

## Dependencies

| Component | How |
|---|---|
| `workers` | Only Kubernetes workload that writes to media volumes; conversion processes produce all derivative files |
| External image server (IIPImage, Cantaloupe, etc.) | Mounts the same NFS share as `imageserver`; reads tiles and pyramids to serve IIIF/IIP responses |
| External audio server | Mounts the same NFS share as `audioserver`; streams audio files to clients |
| External PDF service | Mounts the same NFS share as `pdfserver`; serves generated PDF downloads |
| NFS server | External dependency; must be reachable from worker nodes and from external media server hosts |

## Notes

- Media volumes are write-once from the worker perspective — once a derivative is written, workers do not normally update it. Re-ingestion overwrites existing files.
- The mount paths (`/data/imageserver`, `/data/audioserver`, `/data/pdfserver`) are fixed by the chart templates and cannot be changed via values. External media servers must reference the same absolute paths.
- The PV `persistentVolumeReclaimPolicy` is `Retain`. Deleting the Helm release does not delete the backing NFS data or PVs.
- `storages.defaultNfsServer` applies as a fallback to all three media volumes when their `nfsServer` field is empty.
- Media conversion URL/path configuration lives under `convert.*` and is rendered into `configuration.properties` by this feature helper.
- In CDK profile these volumes remain available; CDK profile disables Akubra but keeps media storage fully configurable.
