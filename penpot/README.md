# penpot

Runs [Penpot](https://penpot.app) 2.18.2 — the open-source design and
prototyping tool — at `penpot.jellify.app`. It runs as three Apple
`container` tasks in one group on the macOS/arm64 jellify nodes (galileo,
hopper, lovelace), matching upstream's compose file:

| Task | Image | Role |
|---|---|---|
| `frontend` | `penpotapp/frontend:2.18.2` | nginx: serves the SPA and proxies `/api`, `/ws`, and `/assets` to the backend. This is what Traefik routes to. |
| `backend` | `penpotapp/backend:2.18.2` | Clojure/JVM API server: runs DB migrations on start, handles OIDC login |
| `exporter` | `penpotapp/exporter:2.18.2` | Headless Chromium that renders PNG/PDF/SVG exports by loading the frontend |

Two prestart tasks run before them on every deploy. Both are idempotent:

- `schema-init` creates the `penpot` role and database on the shared
  [`postgres`](https://github.com/Cosmonautical-Cloud/Nomad-Jobs/tree/main/postgres)
  cluster if they're missing, plus the `uuid-ossp` extension. It uses a
  `postgres:18-alpine` container because only lovelace has `psql`. The
  script is inline in `args`, since the container driver doesn't mount the
  task's `secrets/` dir into the VM.
- `ensure-assets-dir` makes sure `/Volumes/Jellify/penpot/assets` exists
  on the Jellify NFS share. Apple container bind mounts write as the host
  user running Nomad (`violet`, uid 1000), so the directory only needs to
  be owned by that user; the images' own uid (1001) doesn't matter.

### One-time setup: the assets directory

Nomad can't create `/Volumes/Jellify/penpot` itself: the share's root is
owned by 988:988 with mode 0755, and nothing on the Macs runs as root. Create
it once from any Ubuntu node, where root can write to the share:

```sh
ssh -t euler.jellify.app 'sudo install -d -o 1000 -g 20 -m 0755 /mnt/jellify/penpot /mnt/jellify/penpot/assets'
```

Until it exists, `ensure-assets-dir` fails with "Permission denied" and the
allocation doesn't start.

### One-time setup: Network Volumes permission (each Mac)

The backend and frontend bind-mount a path under `/Volumes/Jellify`. The
first time `container-runtime-linux` touches a network volume, macOS asks
for **Network Volumes** access (TCC `kTCCServiceSystemPolicyNetworkVolumes`).
On a headless Mac mini nobody answers the prompt, so the container stays at
"Starting container" forever and the task never starts or fails. This was
found 2026-11-18 on galileo, hopper and lovelace.

On each Mac, through Screen Sharing: start any container with a
`/Volumes/Jellify` mount and click **Allow** on the prompt. If the prompt
isn't showing, turn on `container-runtime-linux` under System Settings →
Privacy & Security → Files & Folders → Network Volumes. Check it with:

```sh
container run --rm -v /Volumes/Jellify/penpot/assets:/d docker.io/library/alpine:3.22 ls /d
```

That should return in a few seconds. Don't test with a short timeout and
walk away: a killed run leaves a stopped container plus a running
`container-runtime-linux` process behind, and those block later starts until
you remove them (`container ls -a`, then kill that container's runtime
process and `container rm` it).

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
  connect by IP (from the rendered template) rather than by
  `*.service.consul` name. If Patroni or Sentinel fails over, consul-template
  re-renders and Nomad restarts the task. RomM and audiomuse-ai work the
  same way.

## Auth: Keycloak SSO only, Jellify GitHub teams only

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

### Who can sign in

Only users with the `jellify-member` realm role. The role comes from either
of two groups:

- `Jellify Members`, which [`github-team-sync`](../github-team-sync) keeps
  in sync with the Jellify-Music `design`, `engineering` and `triage` GitHub
  teams. A team member gets in after signing in to Keycloak with GitHub once
  (which links their GitHub account) and the next sync run, at most 15
  minutes later. Someone who already has a Cosmonautical account can link
  GitHub from the account console instead.
- `Admins`, so Senior Cosmonauts don't need a linked GitHub account.

It's enforced twice:

- **Penpot** (`PENPOT_OIDC_ROLES=jellify-member`,
  `PENPOT_OIDC_ROLES_ATTR=roles`) refuses any login whose ID token's `roles`
  claim lacks it. The `penpot` client's "realm roles (penpot gate)" mapper
  adds that claim. This check covers every login path.
- **Keycloak**: the client's browser flow override, `browser-penpot`, is a
  copy of `semaphore`'s gate flow that denies users without the role. It
  shows a clearer error, but Keycloak doesn't re-run a client's browser flow
  after a GitHub (identity provider) login. So it doesn't stop those logins,
  and Penpot's check does.

Penpot's role names can't contain spaces, because `PENPOT_OIDC_ROLES` is
split on whitespace. That's why this role is `jellify-member` rather than
something like "Senior Cosmonaut".

### Keycloak client

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
| `jellify/penpot/OIDC_CLIENT_SECRET` | Keycloak `penpot` client secret (set 2026-11-18) |
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
