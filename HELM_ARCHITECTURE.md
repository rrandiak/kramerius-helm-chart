# Helm Chart Architecture

Internal structure of the `kramerius` Helm chart: directory conventions, values file roles, helper scoping, documentation layout, and implementation status.

---

## 1. Directory Layout

```
kramerius/
├── Chart.yaml
├── values.yaml                    # authoritative defaults (full schema)
├── values.minimal.yaml            # smallest working configuration
├── values.maximal.yaml            # annotated reference with every key
├── values.standard.yaml           # standard deployment preset (Akubra, CNPG)
├── values.cdk.yaml                # CDK deployment preset (no Akubra, cache DB)
├── files/
│   ├── gateway/                   # nginx.conf, Lua, management client assets (.Files.Get)
│   └── observability/             # GeoIP download script, HyperDX dashboard JSON
└── templates/
    ├── _helpers.tpl               # chart-wide: labels, checksums, pod anti-affinity, …
    ├── namespace.yaml
    ├── timezone-configmap.yaml
    │
    ├── admin-client/
    ├── catalina-opts/             # mergeCatalinaOpts only
    ├── cdk/                       # CDK configuration.properties fragment + values
    ├── commons-kramerius/         # shared Kramerius props, logging defaults, configuration.properties assembly (no *.yaml)
    ├── database/
    ├── gateway/
    ├── index-solr/
    ├── keycloak/
    ├── kramerius-curator/
    ├── kramerius-public/
    ├── lock-server/
    ├── networking/
    ├── observability/
    ├── process-manager/
    ├── storage-akubra/
    ├── storage-import/
    ├── storage-javaagents/        # javaagents shared PVC (OTEL agent JARs, etc.)
    ├── storage-media/
    └── workers/
```

Root `templates/` currently has **only** `namespace.yaml` and `timezone-configmap.yaml` besides `_helpers.tpl`. There is **no** chart-level `pvc.yaml` or `image-pull-secrets.yaml`; PVCs and mounts are declared from feature templates (e.g. `storage-*`, `gateway`, `observability`, database), and image pull secrets are configured per component via `<component>.image.pullSecret`.

---

## 2. Feature Folder Convention

Every feature lives in its own subfolder. The files inside follow a consistent pattern:

| File | Role |
|---|---|
| `*.yaml` | Kubernetes resources rendered by Helm |
| `_helpers.tpl` | Helper templates used **only within this feature** (or shared across a small cluster of storage features) |
| `values.part.yaml` | Values schema for this feature — acts as a self-contained reference |
| `README.md` | Feature description, resources it creates, configuration reference, dependency notes |

### Helper scoping rule

- **`templates/_helpers.tpl`** — helpers that are called by **two or more features**. Keep it as small as possible.
- **`templates/<feature>/_helpers.tpl`** — helpers owned by that feature. If a helper is never referenced outside its folder, it belongs here.

When adding a new helper: check first whether it is truly cross-cutting. If only one feature needs it, put it in that feature's `_helpers.tpl`.

---

## 3. Documentation Structure

There are three layers of documentation, each at a different scope:

| Document | Scope |
|---|---|
| `PLATFORM_ARCHITECTURE.md` | **Runtime platform** — what components exist, how they communicate, what must be deployed together. No Helm internals. |
| `HELM_ARCHITECTURE.md` (this file) | **Helm chart internals** — directory layout, values conventions, helper scoping, deployment modes, implementation status. |
| `templates/<feature>/README.md` | **Feature detail** — what Kubernetes resources are created, full configuration reference for that feature's values keys, dependency notes, usage examples. |

The `values.part.yaml` inside each feature folder is the canonical schema for that feature. The root `values.yaml` is the composition of all part files with chart-wide defaults applied.

---

## 4. Values Files

| File | Purpose |
|---|---|
| `values.yaml` | Full default schema. Every key that the chart reads must appear here. |
| `values.minimal.yaml` | Smallest set of values needed for a working cluster. All required overrides. No optional features enabled. |
| `values.maximal.yaml` | Every configurable key present with representative values and inline comments. Used as a reference and for testing full render. |
| `values.standard.yaml` | Standard deployment preset: Akubra storage, CNPG database mode, Ingress networking. |
| `values.cdk.yaml` | CDK deployment preset: no Akubra, cache DB enabled, CDK worker image. |

Operators compose an environment-specific configuration by starting from a preset and layering site overrides:

```bash
helm upgrade kramerius . \
  -f values.standard.yaml \
  -f environments/mzk/override.yaml
```

---

## 5. Template Folder Reference

Status reflects **Kubernetes manifests** (`*.yaml`) and **Helm helpers** under `templates/` as of this revision.

| Folder | Kubernetes resources | Helpers / other |
|---|---|---|
| `admin-client/` | `Deployment`, `Service`, `ConfigMap` | `kramerius.adminClient.*` |
| `catalina-opts/` | — | `kramerius.mergeCatalinaOpts` |
| `cdk/` | — | `kramerius.cdk.configurationProperties.part`; `values.part.yaml`, `README.md` |
| `commons-kramerius/` | — | `kramerius.commonsKrameriusConfigurationPropertyMap`, `kramerius.configurationProperties.commonsKrameriusSection`, `kramerius.configurationProperties.{section,extraToString,baseContent,merged}`, `kramerius.defaultLoggingProperties`; static `configuration.properties` fragments |
| `database/` | CNPG `Cluster`/`Secret`; deployable PG `Deployment`/`Service`/`PVC`/`Secret` | `kramerius.database.*`, `kramerius.configurationProperties.databaseSection` |
| `gateway/` | OpenResty `Deployment`/`Service`, Redis `Deployment`/`Service`, error `ConfigMap`s, nginx/lua `ConfigMap`s; optional management client `Deployment`/`Service`/`ConfigMap` | `kramerius.gateway.*`, `kramerius.gateway.cachingDiskEnabled`, `kramerius.gateway.cacheConfigLua`, `kramerius.gateway.rateLimitConfigLua` |
| `index-solr/` | — | `kramerius.solrConfigurationPropertyMap`, `kramerius.configurationProperties.solrSection`; `values.part.yaml` (URLs + `clientConfig` timeouts → `solr.apache.client.*`) |
| `keycloak/` | `ConfigMap` (`keycloak.json`) | `kramerius.keycloakAdapterJson`, `kramerius.keycloakConfigurationPropertyMap`, `kramerius.configurationProperties.keycloakSection` |
| `kramerius-curator/` | `StatefulSet`, `Service`, `ServiceAccount`, `ConfigMap`, logging `ConfigMap` | `kramerius.curator.*` |
| `kramerius-public/` | same pattern as curator | `kramerius.public.*` |
| `lock-server/` | `StatefulSet`, headless `Service` (`clusterIP: None`), `ServiceAccount` | `kramerius.lockServer.*`, `kramerius.configurationProperties.lockServerSection` |
| `networking/` | Up to 5 `Ingress` objects (api, admin, process-manager, gateway-manager, hyperdx); optional **Gateway API** `Gateway` + `HTTPRoute`s when `networking.mode: gatewayApi` | `kramerius.networking.ingressEnabled`, `kramerius.networking.gatewayApiEnabled`, `kramerius.networking.validateEdgeHosts`; `values.part.yaml` |
| `observability/` | When `observability.enabled`: Vector sidecar `ConfigMap`/data `PVC`, ClickHouse `StatefulSet`/`Service`/`PVC`/init `Job`/init `ConfigMap`s, MongoDB `Deployment`/`Service`/`PVC`, HyperDX `Deployment`/`Service`, OTEL Collector `Deployment`/`Service`/`ConfigMap`, GeoIP scripts `ConfigMap`, GeoIP init `Job` (post-install/upgrade hook), GeoIP updater `CronJob` | `kramerius.observability.*`, `kramerius.perAppJavaagent*`, `kramerius.otelJvmOpts` |
| `process-manager/` | `StatefulSet`, `Service`, `ServiceAccount`, `ConfigMap`, logging `ConfigMap` | `kramerius.processManager*` |
| `storage-akubra/` | `PersistentVolumeClaim` when Akubra enabled | `kramerius.akubra.enabled`, `kramerius.akubraConfigurationPropertyMap`, `kramerius.configurationProperties.akubraSection` |
| `storage-import/` | import `PersistentVolumeClaim`s | `kramerius.import*`, `kramerius.configurationProperties.importSection` |
| `storage-javaagents/` | `PersistentVolumeClaim` when any component enables a javaagent | — |
| `storage-media/` | media `PersistentVolumeClaim`s | `kramerius.media*`, `kramerius.configurationProperties.mediaSection` |
| `workers/` | per-group `StatefulSet`, headless `Service`, `ConfigMap`, logging `ConfigMap`, `ServiceAccount` | `kramerius.worker*`, `kramerius.workers.*` |

---

## 6. Where Helpers Live

### `templates/_helpers.tpl` (chart-wide)

| Helper | Used for |
|---|---|
| `kramerius.fullname` | release-scoped names |
| `kramerius.labels` | standard labels on resources |
| `kramerius.hazelcastServerAddresses` | lock-server address in app config |
| `kramerius.podAntiAffinity` | curator / workers (configurable hard vs soft) |
| `kramerius.checksum.*` | pod template checksum annotations (public, curator, PM, workers, gateway, hazelcast); `kramerius.checksum.adminClientPod` lives in `admin-client/_helpers.tpl` |
| `kramerius.storageNfsServer` | NFS server address for a storage entry (with defaultNfsServer fallback) |
| `kramerius.storagePvcStorageClass` | storage class for a PVC-backed storage entry |
| `kramerius.storagePvcName` | PVC name for a storage entry (existing claim or chart-generated) |
| `kramerius.sharedStorageVolume` | pod volume spec for an NFS or PVC storage entry |
| `kramerius.tomcatLogsNfsVolume` | NFS volume spec for Tomcat log directory |
| `kramerius.tomcatLogsVolumeClaimTemplates` | volumeClaimTemplates for PVC-backed Tomcat logs |
| `kramerius.tomcatLogsPodNameEnv` | POD_NAME env var from fieldRef for log subdirectory naming |

The comment block at the top of `_helpers.tpl` lists other feature-owned helper **prefixes** and where to find them.

### Feature-owned (by folder)

| Location | Notable defines |
|---|---|
| `catalina-opts/_helpers.tpl` | `kramerius.mergeCatalinaOpts` |
| `database/_helpers.tpl` | `kramerius.database.*`, JDBC section helper |
| `gateway/_helpers.tpl` | `kramerius.gateway.*`, caching Lua emit helpers |
| `observability/_helpers.tpl` | `kramerius.observability.*`, `kramerius.checksum.clickhousePod`, `kramerius.perAppJavaagentCatalinaFlags`, `kramerius.perAppJavaagentVolumeMounts`, `kramerius.perAppJavaagentVolumes`, `kramerius.otelJvmOpts` |
| `networking/_helpers.tpl` | `kramerius.networking.ingressEnabled`, `kramerius.networking.gatewayApiEnabled`, `kramerius.networking.validateEdgeHosts` |
| `process-manager/_helpers.tpl` | `kramerius.processManagerUrl`, `kramerius.processManagerHost`, `kramerius.processManager.matchLabels` |
| `storage-akubra`, `storage-import`, `storage-media/_helpers.tpl` | storage mounts, `kramerius.akubraConfigurationPropertyMap`, `kramerius.configurationProperties.*Section` |
| `keycloak/_helpers.tpl` | Keycloak adapter JSON + Keycloak configuration.properties section |
| `commons-kramerius/_helpers.tpl` | commons Kramerius map + commons section + default logging properties + configuration.properties assembly (`section`, `extraToString`, `baseContent`, `merged`) |
| `lock-server/_helpers.tpl` | lock-server labels, `kramerius.lockServerConfigurationPropertyMap`, configuration.properties section |
| `index-solr/_helpers.tpl` | Solr property map + Solr configuration.properties section |
| `cdk/_helpers.tpl` | `kramerius.cdk.configurationProperties.part` |
| `kramerius-public`, `kramerius-curator`, `workers/_helpers.tpl` | per-workload `configurationProperties`, `serverXml`, worker image / lp.xml / server.xml |
| `admin-client/_helpers.tpl` | admin client labels + globals.js render |

---

## 7. Implementation Status

Current chart capabilities at a glance:

| Area | Status | Notes |
|---|---|---|
| Feature folder structure | ✅ Implemented | Feature-focused folders with local helpers and docs. |
| Database roles and modes | ✅ Implemented | `databases.*` supports CNPG and in-chart PG resources. |
| Standard and CDK profiles | ✅ Implemented | Profile overlays via `values.standard.yaml` and `values.cdk.yaml`. |
| Networking modes | ✅ Implemented | Ingress and Gateway API with mutual exclusivity validation. |
| App replica validation | ✅ Implemented | StatefulSet checks prevent invalid replica counts. |
| Observability stack | ✅ Implemented | Vector, ClickHouse, MongoDB, HyperDX, optional OTEL Collector. |
| Worker affinity controls | ✅ Implemented | Per-group `affinity.type` support. |
| Gateway runtime controls | ⚠️ Partially implemented | Redis + management client + caching rules exist; some advanced dynamic management remains optional. |
| Solr advanced tuning | ⚠️ Partially implemented | Core endpoints and client config are first-class; additional tuning remains environment-specific. |

---
