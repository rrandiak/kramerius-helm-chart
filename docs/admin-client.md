# Admin Client

The admin client is a static single-page application (SPA) served by nginx. It provides the web UI for library administrators — document management, process monitoring, and curator operations. It communicates directly with the Kramerius API from the browser; it has no server-side logic of its own.

## Position in the Stack

```
nginx-ingress  ──▶  [Admin Client]  ◀── this component
                          │
                          │ (browser-side API calls)
                          ├──▶ Kramerius Curator  (/search/api/admin/*)
                          ├──▶ Kramerius Public   (/search/api/*)
```

The admin client is deployed alongside Kramerius but is completely decoupled at runtime — it is just static files. All actual operations happen via the Kramerius REST APIs called from the user's browser.

## Kubernetes Resources

| Resource | Name | Notes |
|---|---|---|
| Deployment | `admin-client` | `replicas` configurable, defaults to 1 |
| Service | `admin-client` | ClusterIP, port 80 |
| ConfigMap | `admin-client-globals` | Runtime configuration injected as `globals.js` |

## PVCs / Volumes

The admin client uses **no PVCs**. It is stateless — all persistent state lives in the Kramerius backend.

| Mount path in pod | Volume source | Purpose |
|---|---|---|
| `/usr/share/nginx/html/assets/globals.js` | `admin-client-globals` ConfigMap | Runtime config (API base URLs, feature flags) |

`globals.js` is the only injection point. It is mounted as a single file into the nginx html root so the SPA can read environment-specific configuration (e.g. API endpoint URLs) at runtime without rebuilding the image.

## Configuration

### globals.js

The content of `globals.js` is set via `adminClient.config.globalsJs` in `values.yaml`. This is a raw JavaScript snippet that the SPA reads on load. Typical content:

```js
window.APP_CONFIG = {
  apiBase: "https://k7.example.com/search/api",
  adminBase: "https://k7.example.com/search/api/admin",
  processManagerBase: "https://process-manager.k7.example.com",
  keycloakUrl: "https://keycloak.example.com/",
  keycloakRealm: "kramerius",
  keycloakClientId: "krameriusClient"
};
```

The exact shape depends on the admin client application version. Check the image documentation for the expected config keys.

### values.yaml reference

| Value | Default | Description |
|---|---|---|
| `adminClient.enabled` | `true` | Set to `false` to skip deploying the admin UI entirely |
| `adminClient.replicas` | `1` | Number of nginx pods |
| `adminClient.image.repository` | `registry.example.com/k7-admin` | Image registry + name |
| `adminClient.image.tag` | `latest` | Image tag |
| `adminClient.image.pullPolicy` | `Always` | Pull policy |
| `adminClient.config.globalsJs` | `""` | Raw JS content for `globals.js` |
| `adminClient.resources` | see below | CPU / memory requests and limits |

## Ingress

The admin client is exposed via a dedicated ingress object (`kramerius-admin`) on its own hostname:

```yaml
ingress:
  admin:
    host: "admin.k7.example.com"
    oauthProtected: false   # set true to add oauth2-proxy annotations
    tls:
      secretName: kramerius-admin-tls
```

When `oauthProtected: true`, the ingress annotations for oauth2-proxy are added automatically (`nginx.ingress.kubernetes.io/auth-url`, `nginx.ingress.kubernetes.io/auth-signin`). The oauth2-proxy endpoints are configured via `ingress.oauth.authUrl` and `ingress.oauth.authSignin`.

## Resource Requests / Limits

| | Request | Limit |
|---|---|---|
| CPU | `10m` | `50m` |
| Memory | `32Mi` | `64Mi` |

The admin client is a static nginx server — it only serves files. Resource requirements are minimal.

## Dependencies

| Component | How | Purpose |
|---|---|---|
| **nginx-ingress** | HTTPS | Exposes the SPA to browser clients |
| **Kramerius Curator** | Browser → HTTPS | Admin API calls (document management) |
| **Kramerius Public** | Browser → HTTPS | Read API calls (search, document view) |
| **Keycloak** (external) | Browser → HTTPS | OIDC login flow |

All API calls are made from the **browser**, not from the admin client pod. The pod only serves static files.

## Notes

- The image (`registry.example.com/k7-admin`) is a placeholder — replace with the actual registry and image name before deploying.
- `imagePullPolicy: Always` is the default. If the image is tagged with a fixed version, consider switching to `IfNotPresent` to avoid unnecessary pulls.
- To update runtime config without rebuilding the image, change `adminClient.config.globalsJs` in `values.yaml` and re-run `helm upgrade`. The pod will restart automatically due to the ConfigMap checksum annotation.
