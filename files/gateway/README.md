# Gateway files (`files/gateway/`)

Source artefacts for the Kramerius **edge gateway** (OpenResty/Lua) and the **management client** (Bottle/Python). The Helm chart embeds these files into ConfigMaps.

---

## Two halves

| Half | Role | Pod |
|------|------|-----|
| **OpenResty / Lua** | Terminate HTTP, enforce rate limits and download quotas, route to Kramerius Public/Curator on the API host, emit structured access logs. | `gateway-openresty` |
| **Management client** | Web UI + JSON API + optional Slack slash commands. Reads/writes config state in Redis. | `gateway-management-client` |

---

## Management backend (`management.py`)

Single-file [Bottle](https://bottlepy.org/) application (vendored, no framework install needed).

### Authentication

The management UI re-uses the session token already held by the **Kramerius admin client** (`localStorage['account.token']`). On first visit the server returns a tiny bootstrap page; its inline JS reads the token and POSTs it to `/gateway/auth`. The server validates it against the Kramerius **actions API** — the token holder must have the `a_rights_edit` action. On success a signed session cookie is issued (1 h TTL, in-memory store).

```
Browser → GET /gateway          → bootstrap page (no session)
       → POST /gateway/auth     → server checks actions API
       → 403 if unauthorised    → /gateway/forbidden
       → 200 if OK              → session cookie + redirect to /gateway
```

### Redis storage

State is stored in Redis under three keys:

| Key | Value |
|-----|-------|
| `gw:state` | Full gateway state as a JSON blob (`State.to_dict()`) |
| `gw:version` | INCR counter — incremented on every write; OpenResty polls this to detect changes cheaply |
| `gw:removed_bans` | JSON array of soft-deleted ban audit records |

All three keys are written atomically in a single pipeline on every save. OpenResty reads `gw:version` on each poll tick; it only fetches `gw:state` when the version changes.

### Data model

| Entity | Fields |
|--------|--------|
| **Peak schedule** | `from_hour`, `to_hour` (0–23, must differ) |
| **Access rule** | `name`, `endpoints[]`, `user_refs[]`, `rl_window/peak/off` (req count), `dl_window/peak/off` (bytes) |
| **User profile** | `name`, `ip` (CIDR), `username`, `headers{}` |
| **Ban** | `target` (IP/CIDR), `reason` (≥ 4 chars), `banned_at` (ISO-8601 UTC) |

Rules and users are identified by **list index**; renaming a user profile automatically updates all rule references.

### Routes

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/gateway` | session | Dashboard (tab=rules\|users\|bans) |
| POST | `/gateway/auth` | bearer token | Exchange token for session cookie |
| GET | `/gateway/forbidden` | — | 403 page |
| POST | `/gateway/ui/peak/save` | session | Save peak schedule |
| POST | `/gateway/ui/rule/add` | session | Append blank rule, redirect to its edit row |
| POST | `/gateway/ui/rule/save` | session | Save rule by index |
| POST | `/gateway/ui/rule/remove` | session | Remove rule by index |
| POST | `/gateway/ui/user/add` | session | Append blank user profile, redirect to its edit row |
| POST | `/gateway/ui/user/save` | session | Save user profile by index |
| POST | `/gateway/ui/user/remove` | session | Remove user profile by index |
| POST | `/gateway/ui/bans/add` | session | Add ban |
| POST | `/gateway/ui/bans/delete` | session | Remove ban |
| POST | `/slack/commands` | Slack signature | Slack slash command handler |
| GET | `/healthz` | — | `{"status":"ok"}` |

### Slack commands

Enabled when `SLACK_SIGNING_SECRET` is set. Commands available to the slash command:

| Command | Effect |
|---------|--------|
| `ban <ip> <reason>` | Add IP/CIDR ban |
| `unban <ip>` | Remove ban |
| `bans` | List all active bans |
| `limits` | Summary of all rules |
| `peak` | Show current peak window |

### Environment variables

| Variable | Required | Description |
|----------|----------|-------------|
| `K7_HOST` | yes | Kramerius base URL **including the `/search` path prefix** (e.g. `https://kramerius.example.org/search`). Used to build the actions API URL. |
| `MANAGEMENT_API_SECRET` | yes | Shared secret that protects the JSON API and Slack commands. |
| `SLACK_SIGNING_SECRET` | no | Slack app signing secret. Required only when Slack slash commands are used. |
| `REDIS_HOST` | yes | Redis hostname. In-cluster: `gateway-redis.<namespace>.svc.cluster.local`. |
| `REDIS_PORT` | no | Redis port. Defaults to `6379`. |
| `REDIS_PASSWORD` | no | Redis password. Leave unset if Redis runs without auth. |

Volume mounts expected by the chart:

| Mount | Purpose |
|-------|---------|
| `/app` | All gateway source files (this directory, read-only). |

---

## Management frontend (`dashboard.html`, `dashboard.css`)

Server-rendered HTML via Bottle's `SimpleTemplate`. CSS is injected **inline** at render time (no CDN, no external requests):

- `water.css` — vendored [water.css](https://watercss.kognise.dev/) dark theme (base styles).
- `dashboard.css` — custom overrides and layout rules (tables, edit rows, peak form, flash messages).

### UI structure

Three tabs, all in a single page with server-side tab switching:

**Access rules** (`?tab=rules`)
- Peak hours form (From / To, 0–23, must differ).
- Rules table: name, endpoints, matched users, rate-limit config, download-limit config.
- Each row has an inline edit form (collapsed by default). Clicking _Edit_ or adding a new rule opens the edit form for that row only.
- Edit row contains: rule name, endpoint checkboxes (grouped by section from `endpoints.txt`), user checkboxes, rate-limit fieldset, download-limit fieldset, and a Save / Cancel / Remove bar.

**Users** (`?tab=users`)
- User profiles table: name, IP/CIDR, username, HTTP headers.
- Inline edit form: name (required), IP/CIDR, username, headers (one `Header: value` per line).
- At least one of IP/CIDR, username, or a header must be set.

**Bans** (`?tab=bans`)
- Add-ban form: IP/CIDR target + reason (≥ 4 chars).
- Bans table: target, reason, timestamp (formatted to local time by JS).
- Remove link per row.

### Edit row mechanics

When a row is opened after a server action (add/save/remove), the server embeds `style="display:table-row"` directly in the relevant `<tr>` — no JS required for the initial state. The `openEdit` / `closeEdit` JS functions handle interactive toggling (only one row open at a time).

---

## OpenResty / Nginx / Lua

| File | Purpose |
|------|---------|
| `nginx.conf` | Helm-templated server config. Declares `lua_shared_dict` for rate and download counters. One default server block for the public/curator API host. |
| `gateway_common.lua` | Shared helpers: client IP resolution, path-template → regex compilation, rule matching, IP whitelist checks. |
| `gateway_config.lua` | Polls Redis for config changes (`gw:version` check, then `gw:state` fetch). Preprocesses the JSON blob into Lua tables used by the ratelimiter. |
| `ratelimiter.lua` | Access phase: loads config from `gateway_config`, enforces per-client request-rate limits via `lua_shared_dict gateway_rl`, selects upstream (curator vs public). |
| `ratelimit_config.lua` | Generated by Helm — bakes in Redis connection details and `poll_secs`. |

---

## Other files

| File | Purpose |
|------|---------|
| `endpoints.txt` | Catalog of API path templates, one per line, grouped under `# Section Name` comments. Loaded at management startup; used for endpoint checkbox validation. |
| `bottle.py` | Vendored Bottle 0.14-dev — no pip install required for the framework itself. |
| `water.css` | Vendored water.css (dark) — embedded inline; no CDN dependency. |
| `requirements.txt` | `redis` — the only runtime pip dependency. |

---

## How the Helm chart uses these files

| Helm template | Embedded files |
|---------------|----------------|
| `configmap-management-client.yaml` | `management.py`, `dashboard.html`, `dashboard.css`, `endpoints.txt`, `bottle.py`, `water.css` |
| `configmap-nginx.yaml` | `nginx.conf` (processed via Helm `tpl`) |
| `configmap-lua.yaml` | `gateway_common.lua`, `gateway_config.lua`, `ratelimiter.lua`, `response_cache.lua`, `cache_memory_body.lua` |
| `configmap-errors.yaml` | `429.body` |
| `configmap-error-titles.yaml` | `429.titles` |

---

## Local development

See [`dev/README.md`](../../dev/README.md) for the full local development setup (Docker Compose stack, environment variables, Redis state, and per-file descriptions of the dev directory).
