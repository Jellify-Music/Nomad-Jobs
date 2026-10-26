# penpot

Runs [Penpot](https://penpot.app) 2.18.2 — the open-source design and
prototyping tool — at `penpot.jellify.app`. It runs as three `docker` tasks
in one group on the Ubuntu/amd64 jellify nodes, matching upstream's compose
file:

| Task | Image | Role |
|---|---|---|
| `frontend` | `penpotapp/frontend:2.18.2` | nginx: serves the SPA and proxies `/api`, `/ws`, and `/assets` to the backend. This is what Traefik routes to. |
| `backend` | `penpotapp/backend:2.18.2` | Clojure/JVM API server: runs DB migrations on start, handles OIDC login |
| `exporter` | `penpotapp/exporter:2.18.2` | Headless Chromium that renders PNG/PDF/SVG exports by loading the frontend |

Two prestart tasks run before them on every deploy. Both are idempotent:

- `schema-init` creates the `penpot` role and database on the shared
  [`postgres`](https://github.com/Cosmonautical-Cloud/Nomad-Jobs/tree/main/postgres)
  cluster if they're missing, plus the `uuid-ossp` extension. It uses a
  `postgres:18-alpine` container because the Ubuntu nodes don't have `psql`.
- `ensure-assets-dir` creates `/mnt/jellify/penpot/assets` on the Jellify
  NFS share and `chown`s it to uid/gid 1001, which both the backend and
  frontend images run as.

The upstream compose file's `admin-console` and `mcp` services aren't
deployed. Both are optional, and the frontend's entrypoint drops their nginx
routes when their flags are off.

## Shared backing services (cosmonautical)

Postgres and Redis both come from the shared HA clusters in
[`Cosmonautical-Cloud/Nomad-Jobs`](https://github.com/Cosmonautical-Cloud/Nomad-Jobs),
not from per-job instances. Consul is a single datacenter across both Nomad
datacenters, so `{{ range service "postgres" }}` and `{{ range service
"redis" }}` resolve to the current Patroni leader and Sentinel master from
here, the same as for any cosmonautical job.

- **Redis DB 3.** The shared cluster's other DBs are already taken: 0 is
  RomM, 1 is nextcloud and seaweedfs-filer, 2 is audiomuse-ai. Penpot only
  uses it for websocket notification pub/sub.
- **The address is resolved once, at template render time.** The tasks
  connect by IP, because Docker containers on these nodes can't resolve
  `*.service.consul`. If Patroni or Sentinel fails over, consul-template
  re-renders and Nomad restarts the task. RomM and audiomuse-ai work the
  same way.

## Auth: Keycloak SSO only

The only way to log in is Keycloak (`cosmonautical` realm, confidential
client `penpot`). The button reads **"Sign in with Cosmonautical"** because
`PENPOT_OIDC_NAME` on the frontend sets its full label; the default would be
"OpenID".

These flags are set on all three tasks (`locals.penpot_flags`):

- `enable-login-with-oidc`, `disable-login-with-password`: SSO is the only
  login form shown.
- `disable-registration` + `enable-oidc-registration`: there's no open
  signup form, but a first Keycloak login creates the user's Penpot account.
- `disable-email-verification`: Keycloak already owns and verifies the
  address.

The Keycloak client must have the redirect URI
`https://penpot.jellify.app/api/auth/oidc/callback` (Penpot builds it from
`PENPOT_PUBLIC_URI`) and the `openid profile email` scopes. The backend finds
the issuer's endpoints through
`<OIDC_BASE_URI>.well-known/openid-configuration`.

Email (team invitations, etc.) goes through the shared `smtp/*` Gmail
credentials, the same ones nextcloud uses. Messages are sent from the
authenticated account itself, so Gmail doesn't rewrite the sender.

## Consul KV keys

| Key | Used for |
|---|---|
| `jellify/penpot/DB_PASSWORD` | `penpot` Postgres role password (set by `schema-init` on first deploy) |
| `jellify/penpot/SECRET_KEY` | `PENPOT_SECRET_KEY`, the master key for sessions and tokens. Generate with `python3 -c "import secrets; print(secrets.token_urlsafe(64))"`. Rotating it logs everyone out. |
| `jellify/penpot/OIDC_CLIENT_SECRET` | Keycloak `penpot` client secret |
| `postgres/PATRONI_SUPERUSER_PASSWORD` | Bootstrap: creating the `penpot` role/database/extension |
| `redis/PASSWORD` | Shared Redis cluster auth |
| `smtp/SERVER` | SMTP host |
| `smtp/PORT` | SMTP port (STARTTLS) |
| `smtp/USERNAME` | SMTP auth, also used as the From/Reply-To address |
| `smtp/PASSWORD` | SMTP auth |

## Nomad Variables

Path `nomad/jobs/penpot`. Populate it via the HTTP API, since there's no
`nomad` CLI on the hosts:

```sh
curl -X PUT 127.0.0.1:4646/v1/var/nomad/jobs/penpot -d '{
  "Items": {
    "PUBLIC_URI": "https://penpot.jellify.app",
    "OIDC_BASE_URI": "https://auth.cosmonautical.cloud/realms/cosmonautical/"
  }
}'
```

| Item | Used for |
|---|---|
| `PUBLIC_URI` | `PENPOT_PUBLIC_URI`: the public URL. It's also the base of the OIDC redirect URI. |
| `OIDC_BASE_URI` | Keycloak realm issuer URL. **Keep the trailing slash**: Penpot appends `.well-known/openid-configuration` to it. |

The Traefik `Host()` rule is still hardcoded in the service tags, because
service tags can't read Nomad Variables.

For history/rationale, see [`CHANGELOG.md`](../CHANGELOG.md).
