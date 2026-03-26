# Gateway (OpenResty)

The gateway is the single entry point for all Kramerius HTTP traffic. It runs **OpenResty** (nginx + LuaJIT) and enforces rate limiting, download quotas, and routes requests to either the public or curator backend.

## Position in the Stack

```
nginx-ingress
    │
    ▼
[OpenResty Gateway]  ◀── this component
    │
    ├── /search/api/admin/* ──▶ kramerius-curator:80
    └── /*               ──▶ kramerius-public:80
```

The gateway sits directly behind the nginx-ingress controller and in front of both Kramerius deployments. No Kramerius service is reachable from the ingress without going through this component.

## Kubernetes Resources

| Resource | Name | Notes |
|---|---|---|
| Deployment | `gateway-openresty` | `replicas` set to 1 |
| Service | `gateway-openresty` | ClusterIP, port 80 |
| ConfigMap | `gateway-openresty-nginx` | Full `nginx.conf` |
| ConfigMap | `gateway-openresty-lua` | All Lua scripts |
| ConfigMap | `gateway-openresty-errors` | 429 and quota HTML error pages |

## Routing Logic

Routing is handled by `access_ratelimit.lua`:

- Requests whose path starts with `gateway.curatorPathPrefix` (default: `/search/api/admin/`) are proxied to the **kramerius-curator** service.
- All other requests are proxied to the **kramerius-public** service.
- The upstream host is set dynamically in Lua so that OpenResty re-resolves CoreDNS on each request (uses `kube-dns.kube-system.svc.cluster.local` as the resolver).

## Rate Limiting

Rate limiting is implemented with Lua shared memory (`rateLimit` dict, 32 MB).

Configuration is in `ratelimit_config.lua` and exposed via `gateway.rateLimits` values:

```yaml
gateway:
  rateLimits:
    - pathPrefix: "/"
      maxRequests: 600          # requests per window
      windowSeconds: 60
      peakMaxRequests: 300      # used when peakHours.enabled is true
      offPeakMaxRequests: 600
```

- Keyed per **client IP** (resolved from `X-Forwarded-For` against `gateway.trustedProxyCidrs`, default: RFC-1918 ranges).
- If a limit is exceeded the gateway returns **HTTP 429** with the error page from the `gateway-openresty-errors` ConfigMap.
- Peak hours allow a tighter limit during business hours.
- Rules are evaluated **top to bottom** — the first matching rule wins. Each rule matches by `pathPrefix` and optionally by `pathSuffix`.

## Download Quota

Download quotas track bytes actually sent, not just request counts. Implemented across three Lua phases:

| Phase | Script | Action |
|---|---|---|
| `header_filter_by_lua` | `header_download_limit.lua` | Reads `Content-Length`; aborts early if quota already exceeded |
| `body_filter_by_lua` | `body_download_429.lua` | Replaces body with 429 page if quota was hit mid-stream |
| `log_by_lua` | `log_download_bytes.lua` | Adds actual bytes sent to the sliding-window counter |

Configuration via `gateway.downloadLimits`:

```yaml
gateway:
  downloadLimits:
    - pathPrefix: "/"
      maxBytes: 5368709120    # 5 GB
      windowSeconds: 3600     # per hour
      peakMaxBytes: 2147483648
      offPeakMaxBytes: 5368709120
```

Quota state lives in the `downloadQuota` shared dict (64 MB).

## Configuration

All gateway configuration lives in `values.yaml` under the `gateway` key.

| Value | Default | Description |
|---|---|---|
| `gateway.image` | `openresty/openresty:1.27.1.2-3-alpine` | Gateway image |
| `gateway.resolver` | `kube-dns.kube-system.svc.cluster.local valid=30s ipv6=off` | CoreDNS resolver for dynamic upstream resolution |
| `gateway.trustedProxyCidrs` | RFC-1918 ranges | CIDRs trusted for `X-Forwarded-For` (configurable) |
| `gateway.luaSharedDict` | `rateMisc: 1m`, `rateLimit: 32m`, `downloadQuota: 64m` | Shared memory sizes for Lua counters |
| `gateway.clientMaxBodySize` | `512m` | Max request body size |
| `gateway.curatorPathPrefix` | `/search/api/admin/` | Path routed to curator |
| `gateway.error429` | `Too Many Requests` | Error page for rate limit exceeded |
| `gateway.error429Download` | `Download quota exceeded...` | Error page for download quota exceeded |
| `gateway.proxy.connectTimeout` | `10s` | Upstream connect timeout |
| `gateway.proxy.sendTimeout` | `120s` | Upstream send timeout |
| `gateway.proxy.readTimeout` | `120s` | Upstream read timeout |
| `gateway.peakHours` | `enabled: false`, `from: 9`, `to: 18` | Peak window for tighter rate/download limits |
| `gateway.rateLimits` | see values.yaml | Array of rate limit rules |
| `gateway.downloadLimits` | see values.yaml | Array of download quota rules |
| `gateway.resources` | `100m`/`1000m` CPU, `128Mi`/`512Mi` memory | Resource requests and limits |

## Resource Requests / Limits

| | Request | Limit |
|---|---|---|
| CPU | `100m` | `1000m` |
| Memory | `128Mi` | `512Mi` |

OpenResty is an nginx event-loop process — steady-state CPU is very low. The 1 CPU burst limit covers traffic spikes and Lua script execution. Memory usage is dominated by the `lua_shared_dict` allocations (`rateLimit` 32MB + `downloadQuota` 64MB + misc 1MB ≈ 97MB); the 512Mi limit gives comfortable headroom.

## Dependencies

| Dependency | How |
|---|---|
| **kramerius-public** | Upstream HTTP proxy (`proxy_pass`) |
| **kramerius-curator** | Upstream HTTP proxy for admin paths |
| **kube-dns** | DNS resolver configured in `nginx.conf` for dynamic upstream resolution |
| **nginx-ingress** | Sends traffic to this service; forwards `X-Forwarded-For` |

## Notes

- The gateway does **not** perform TLS — TLS is terminated at the ingress controller.
- The shared dicts are in-memory and reset on pod restart.
- To add a new rate limit rule, add an entry to `gateway.rateLimits`; rules are matched top-to-bottom (first match wins). Use `pathSuffix` when you need to match the end of the path (e.g. `/image`).
