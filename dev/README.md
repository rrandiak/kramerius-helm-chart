# Local development stack (`dev/`)

Runs standalone gateway management UI (Bottle + Redis) without admin client.

---

## Quick start

From the **chart root** (`helm/kramerius/`):

```sh
make run    # build images and start in background
make logs   # follow all container logs
make stop   # tear everything down
```

Open `http://localhost:8080` — gateway management UI.

---

## Environment variables

| Variable | Required | Description |
|----------|----------|-------------|
| `SLACK_SIGNING_SECRET` | no | Slack request signing secret. If empty, `/slack/commands` returns `503`. |
| `GATEWAY_MANAGER_PORT` | no | Host port exposed by `gateway-management`. Defaults to `8080`. |
| `TZ` | no | Timezone for the management container. Defaults to `UTC`. |

---

## Containers

### `redis`

| | |
|-|-|
| **Image** | `redis:7-alpine` |
| **Port** | `6379:6379` (host-exposed for inspection) |

### `gateway-management`

| | |
|-|-|
| **Image** | `python:3.12-slim` (no custom build; dependencies installed at startup) |
| **Port** | `${GATEWAY_MANAGER_PORT:-8080}:8080` |
| **Volumes** | `../files/gateway → /app` (read-only) |
| **Startup** | Runs `pip install redis` then `python /app/management.py 8080` |

The management app is served directly on port 8080.

---

## Files in this directory

### `docker-compose.dev.yaml`

Defines standalone `redis` and `gateway-management`. Not intended to be run directly — use `make run` from the chart root.

---

## Redis state

State (rules, users, bans, peak schedule) is stored in Redis under the `gw:state` key. It persists between `make stop` / `make run` cycles via Docker's anonymous volume for the Redis container. To reset state, run `make stop` then `docker volume prune` (or remove the named volume manually).
