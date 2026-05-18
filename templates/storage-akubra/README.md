# Storage Akubra

Akubra is the federated content store at the heart of the standard Kramerius deployment. It holds two distinct storage trees: the **object store** (FOXML descriptive and structural metadata objects) and the **datastream store** (binary datastreams such as ALTO OCR, text, MODS, DC, and other externally-stored bytestreams). Together they make up the complete digital object repository that Kramerius serves.

This feature defines the PVs, PVCs, and volume wiring for both Akubra stores. The chart generates the corresponding `akubra.*` lines in `configuration.properties` automatically from the `akubraConfig` block.
`akubraConfig.enabled` is the master switch: when false, Akubra PV/PVC resources, workload mounts, and Akubra `configuration.properties` section are all omitted.

## Position in the Stack

```mermaid
flowchart TD
  PUB[kramerius-public] -->|RO| OBJ[/data/akubra/objectStore
PV/PVC]
  CUR[kramerius-curator] -->|RW| OBJ
  W[workers] -->|RW| OBJ

  PUB -->|RO| DS[/data/akubra/datastreamStore
PV/PVC]
  CUR -->|RW| DS
  W -->|RW| DS

  CUR -. write coordination .-> LS[lock-server (Hazelcast)]
  W -. write coordination .-> LS
```

Write access to both stores is coordinated through the Hazelcast lock server. Curator and each worker group acquire distributed locks before modifying objects, preventing concurrent write corruption on shared NFS storage.

## Kubernetes Resources

### Standard profile

| Resource | Name | Notes |
|---|---|---|
| PersistentVolume | `<release>-akubra-object-store` | Created when `type: nfs` and no `existingClaim` |
| PersistentVolumeClaim | `<release>-akubra-object-store` | Bound to the PV above; `ReadWriteMany` |
| PersistentVolume | `<release>-akubra-datastream-store` | Created when `type: nfs` and no `existingClaim` |
| PersistentVolumeClaim | `<release>-akubra-datastream-store` | Bound to the PV above; `ReadWriteMany` |

When `existingClaim` is set, the chart skips PV/PVC creation and uses the named claim directly. When `type: pvc` (without NFS), only a PVC is created (no PV).

### CDK profile

No Akubra resources are created (`akubraConfig.enabled: false`). The CDK profile does not use local Akubra storage.

## PVCs / Volumes

| Mount path in pod | Volume name | Access mode | Consumers | Purpose |
|---|---|---|---|---|
| `/data/akubra/objectStore` | `akubra-objectstore` | ReadWriteMany | public (RO), curator (RW), workers (RW) | FOXML objects |
| `/data/akubra/datastreamStore` | `akubra-datastream` | ReadWriteMany | public (RO), curator (RW), workers (RW) | Binary datastreams (ALTO, text, etc.) |

Note: the access mode on the PV/PVC is always `ReadWriteMany` to allow all consumers to mount it. Read-only enforcement is done at the pod `volumeMount` level (`readOnly: true` on `kramerius-public`), not at the storage level.

## Configuration

### Storage backend selection

Each of the two Akubra volumes is configured independently under `storages`. The same `type / nfsServer / nfsPath / existingClaim / storageClass / size / mountOptions` pattern applies to both.

```yaml
storages:
  # Fallback NFS server address used when nfsServer is empty on any NFS-type volume.
  defaultNfsServer: "10.0.1.10"

  akubra-object-store:
    type: nfs                                    # "nfs" or "pvc"
    nfsServer: ""                                # Leave empty to use defaultNfsServer
    nfsPath: /data/kramerius/akubra/objectStore
    existingClaim: ""                            # Set to skip PV/PVC creation
    storageClass: nfs                            # StorageClass name for the PVC
    size: 50Gi
    mountOptions:
      - hard
      - nfsvers=4.1

  akubra-datastream-store:
    type: nfs
    nfsServer: ""
    nfsPath: /data/kramerius/akubra/datastreamStore
    existingClaim: ""
    storageClass: nfs
    size: 50Gi
    mountOptions:
      - hard
      - nfsvers=4.1
```

To use a pre-existing PVC (for example, created by an external storage provisioner):

```yaml
storages:
  akubra-object-store:
    type: pvc
    existingClaim: my-akubra-objectstore-pvc
    size: 100Gi                                  # Informational only when existingClaim is set
```

### Akubra path patterns

The `akubraConfig` block controls the directory sharding pattern written into `configuration.properties`. The default `"##/##/##"` creates a three-level hex shard tree (e.g., `ab/cd/ef/uuid`).

```yaml
akubraConfig:
  enabled: true
  objectStore:
    # objectStore.pattern in configuration.properties
    pattern: "##/##/##"
  datastreamStore:
    # datastreamStore.pattern in configuration.properties
    pattern: "##/##/##"
```

These values are injected into the `configuration.properties` ConfigMap for every workload that mounts it (public, curator, each worker group). Do not change these values on an existing populated store without migrating the on-disk directory structure first.

### CDK profile override

```yaml
# values.cdk.yaml overlay
akubraConfig:
  enabled: false
```

When `akubraConfig.enabled` is false, the chart omits all Akubra PV/PVC resources and does not inject Akubra paths into `configuration.properties`. Workloads in CDK profile do not mount `/data/akubra/objectStore` or `/data/akubra/datastreamStore`.

## Resource Requests / Limits

Akubra storage volumes carry no standalone compute resources — there are no Pods or containers in this feature. Storage throughput and capacity sizing are the critical operational parameters.

| Metric | Guidance |
|---|---|
| Capacity (objectStore) | Minimum `50Gi`; size based on expected FOXML count (typically 1–5 KB per object) |
| Capacity (datastreamStore) | Minimum `50Gi`; size based on total binary datastream volume (ALTO files can be 50–200 KB each) |
| NFS throughput | Use `nfsvers=4.1` with `hard` mounts for reliability; size NFS server I/O to handle concurrent worker writes |

## Dependencies

| Component | How |
|---|---|
| `lock-server` (Hazelcast) | All writers acquire cluster-wide locks before modifying Akubra objects. Akubra storage is unsafe to write without the lock server running. |
| `kramerius-public` | Mounts both volumes read-only; reads FOXML and datastreams for serving |
| `kramerius-curator` | Mounts both volumes read-write; ingests, updates, and deletes objects |
| `workers` | Mounts both volumes read-write; runs batch ingestion and conversion processes |
| NFS server | External dependency; must be reachable from all pod nodes before workloads start |

## Notes

- In CDK profile, the entire Akubra storage layer is omitted from manifests. Do not configure `storages.akubra-*` in CDK deployments.
- The PV `persistentVolumeReclaimPolicy` is set to `Retain`. Deleting the chart does not delete the backing NFS data.
- NFS mounts use `ReadWriteMany` access mode. The chart does not create any `ReadWriteOnce` Akubra resources.
- When `existingClaim` is set, the chart skips PV/PVC creation entirely. The named claim must already exist in the namespace and be in `Bound` state before workloads start.
- Keep `akubraConfig.objectStore.pattern` and `akubraConfig.datastreamStore.pattern` consistent across all deployments sharing the same physical store. Mismatched patterns cause path lookup failures at runtime.
- The `storages.defaultNfsServer` fallback applies to any `type: nfs` volume with an empty `nfsServer` field — including both Akubra stores.
