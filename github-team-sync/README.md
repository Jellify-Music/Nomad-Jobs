# github-team-sync

Every 15 minutes, mirrors the Jellify-Music GitHub teams `design`,
`engineering` and `triage` into the Keycloak group `Jellify Members`
(`cosmonautical` realm). That group carries the `jellify-member` realm role,
which [`penpot`](../penpot) requires.

The task runs on the macOS/arm64 nodes (galileo, hopper, lovelace) as an
Apple `container` task using `python:3.14-alpine`. The script uses only the
standard library and is inline in the job spec, because the container
driver doesn't mount the task's `local/` or `secrets/` dirs into the VM.

## What a run does

1. Lists the members of every team in `GITHUB_TEAMS`.
2. Looks each one up in Keycloak by GitHub user ID, through the `github`
   identity provider link. Team members who have never signed in with
   GitHub have no linked user yet, so they're logged as `skip` and picked up
   on a later run. That first sign-in is denied by the `github` provider's
   post-login flow, because they don't have the role yet, but it still
   creates and links their user. See penpot's README for that flow.
3. Adds linked team members to `Jellify Members` and removes anyone else
   from it, including people added by hand. Manual access belongs in
   another group with the role, as with `Admins`.

If GitHub returns no members at all, the run fails instead of emptying the
group. A revoked token or a renamed team is much more likely than a really
empty team. To preview changes, set `DRY_RUN = "true"`: it logs every
add/remove without making it.

## Keycloak setup (done 2026-11-18)

- Realm role `jellify-member`, mapped to the groups `Jellify Members` and
  `Admins`.
- Confidential client `github-team-sync`: service account only, with
  `realm-management` roles `view-users`, `query-users`, `query-groups` and
  `manage-users`. `fullScopeAllowed` is off and those roles are scope-mapped.
  It also has the **`kc-admin-api`** default client scope. Without that
  audience in the token, Keycloak 26.8's admin API returns a bare 401, even
  with the right roles.
- Identity provider `github` (alias must match `KEYCLOAK_IDP_ALIAS`): a
  GitHub OAuth App owned by the Jellify-Music org, callback
  `https://auth.cosmonautical.cloud/realms/cosmonautical/broker/github/endpoint`.

## Consul KV keys

| Key | Used for |
|---|---|
| `jellify/github-team-sync/KEYCLOAK_CLIENT_SECRET` | Keycloak `github-team-sync` client secret |
| `jellify/github-team-sync/GITHUB_TOKEN` | Reads team membership. A fine-grained token on the Jellify-Music org with **Members: read** (or a classic token with `read:org`) |

For history and rationale, see [`CHANGELOG.md`](../CHANGELOG.md).
