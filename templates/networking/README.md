# Networking

North-south exposure for Kramerius workloads. This feature renders either:

- Kubernetes Ingress resources (`ingress.enabled: true`), or
- Gateway API resources (`gatewayApi.enabled: true`)

Both modes are mutually exclusive.

## Traffic flow

| Service | Host key | Auth |
|---------|----------|------|
| kramerius-public | `ingress.api.host` | none |
| kramerius-curator | `ingress.api.host` (path prefix) | none |
| admin-client | `ingress.admin.host` | configurable via annotations |
| process-manager | `ingress.processManager.host` | configurable via annotations |
| gateway-management-client | `ingress.gatewayManager.host` | configurable via annotations |
| hyperdx | `ingress.hyperdx.host` | configurable via annotations |

Authentication (OIDC proxy, IP allowlist, etc.) is configured by adding the appropriate annotations directly in each backend's `annotations` map. There are no special chart-level auth flags.

## Values shape

### Ingress mode

```yaml
ingress:
  enabled: true
  className: nginx

  api:
    host: "k7.example.com"
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt
      nginx.ingress.kubernetes.io/real-ip-header: X-Forwarded-For
    tls:
      secretName: kramerius-gateway-tls

  # Admin SPA — points directly to admin-client.
  admin:
    host: "admin.k7.example.com"
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt
      nginx.ingress.kubernetes.io/real-ip-header: X-Forwarded-For
    tls:
      secretName: kramerius-admin-tls

  processManager:
    host: "process-manager.k7.example.com"
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt
      nginx.ingress.kubernetes.io/real-ip-header: X-Forwarded-For
    tls:
      secretName: kramerius-process-manager-tls

  gatewayManager:
    host: ""
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt
      nginx.ingress.kubernetes.io/real-ip-header: X-Forwarded-For
    tls:
      secretName: gateway-manager-tls

  hyperdx:
    host: "hyperdx.k7.example.com"
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt
      nginx.ingress.kubernetes.io/real-ip-header: X-Forwarded-For
    tls:
      secretName: hyperdx-tls
```

### Gateway API mode

```yaml
gatewayApi:
  enabled: false
  gatewayClassName: ""   # e.g. "cilium", "istio", "envoy-gateway"
  annotations: {}

  api:
    host: "k7.example.com"
    annotations: {}
    tls:
      secretName: kramerius-gateway-tls

  admin:
    host: "admin.k7.example.com"
    annotations: {}
    tls:
      secretName: kramerius-admin-tls

  processManager:
    host: "process-manager.k7.example.com"
    annotations: {}
    tls:
      secretName: kramerius-process-manager-tls

  gatewayManager:
    host: ""
    annotations: {}
    tls:
      secretName: gateway-manager-tls

  hyperdx:
    host: "hyperdx.k7.example.com"
    annotations: {}
    tls:
      secretName: hyperdx-tls
```

## Notes

- TLS uses `secretName` in both modes. For Gateway API the chart converts this to the `certificateRefs` format expected by the spec.
- `admin` points directly to the `admin-client` service (not through the gateway).
- To require authentication on any backend, add the appropriate ingress controller annotations (e.g. `nginx.ingress.kubernetes.io/auth-url` / `nginx.ingress.kubernetes.io/auth-signin` for nginx with an external OIDC proxy) directly in that backend's `annotations` map.

## CDK cross-site users database

**Only relevant when `cdk.enabled` is true** and you run the **`users`** PostgreSQL in two locations with **logical replication** (or equivalent) between them.

- **Ingress / Gateway API in this chart** terminate **HTTP(S)** to Kramerius, admin, process-manager, etc. They **do not** publish PostgreSQL.
- Replication needs **east-west connectivity** between the two Postgres endpoints (typically **TCP 5432**, or TLS via a proxy / cloud provider pattern). Plan that with your **platform / network** team: VPN, VPC peering, private link, security groups, NetworkPolicies on CNPG pods if you restrict egress, and DNS or IP reachability from the **subscriber** cluster to the **publisher** (or vice versa, depending on your topology).
- **Helm values** under `networking.*` do not configure this path; **`values.cdk.yaml`** calls it out in comments next to the networking block so CDK operators do not miss it during design.
