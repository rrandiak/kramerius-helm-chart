# Hazelcast

Hazelcast runs as a distributed lock server. It provides cluster-wide mutex semantics so that Kramerius  curator instance and workers can coordinate access to shared resources — to the Akubra stores.

The image used is `ceskaexpedice/hazelcast-locks-server`, a purpose-built wrapper around Hazelcast that exposes a lock-oriented API.

## Position in the Stack

```
Kramerius Public  ──▶  [Hazelcast]  ◀── this component
Kramerius Curator ──▶  [Hazelcast]
Workers           ──▶  [Hazelcast]
```

## Kubernetes Resources

| Resource | Name | Notes |
|---|---|---|
| StatefulSet | `hazelcast` | 1 replica |
| Service (headless) | `hazelcast` | `clusterIP: None`, port 5701 |
| ServiceAccount | `hazelcast` | — |

A headless service is used so clients connect directly to the pod by DNS name (`hazelcast.<namespace>.svc.cluster.local`). The Hazelcast cluster protocol requires stable addresses.

## PVCs / Volumes

Hazelcast does **not** use any PVCs. Lock state is held entirely in memory. On pod restart all locks are released, which is the correct behavior (any pod holding a lock when Hazelcast goes down must re-acquire it on reconnect).

## Configuration

### Environment Variables

| Variable | Value | Description |
|---|---|---|
| `JAVA_OPTS` | `hazelcast.env.JAVA_OPTS` | JVM flags, defaults to `-Xms512M -Xmx2G -Dhazelcast.diagnostics.enabled=true` |
| `TZ` | `timezone-configmap` | Timezone (`Europe/Prague`) |

No ConfigMaps are mounted. The lock server image includes its own embedded Hazelcast configuration.

### Connecting Components

All components that use Hazelcast configure the lock endpoint via env:

```
HAZELCAST_SERVER_ADDRESSES=hazelcast.<namespace>.svc.cluster.local:5701
```

The chart sets `HAZELCAST_SERVER_ADDRESSES` to **`hazelcast.<namespace>.svc.cluster.local:5701`** automatically for all connecting components (matching this chart’s headless Service).

## Resource Requests / Limits

| | Request | Limit |
|---|---|---|
| CPU | `100m` | `500m` |
| Memory | `640Mi` | `3Gi` |

The JVM heap (`-Xmx2G`) must be set below the memory limit. The 3Gi limit provides ~1Gi of headroom above the max heap for JVM metaspace, code cache, thread stacks, and GC overhead. Hazelcast is mostly idle between lock requests so CPU demand is low.

## Availability

Deployed as a **single replica** (hardcoded). This means Hazelcast is a single point of failure — if the pod restarts, all in-flight locks are dropped. Kramerius and workers are expected to handle this gracefully by treating a lost lock as a signal to retry.

Multi-member Hazelcast HA is not supported by this chart. Enabling it would require template changes to configure Kubernetes member discovery (Hazelcast Kubernetes plugin) and to list all members in `HAZELCAST_SERVER_ADDRESSES`.

## Dependencies

Hazelcast has no dependencies on other components in this chart. It is a pure in-memory service.

## Notes

- The `hazelcast.diagnostics.enabled=true` flag writes diagnostic logs that are useful for tuning lock contention.
