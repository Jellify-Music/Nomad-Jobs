# Nomad-Jobs

A Terraform plan for the services and jobs we run on Nomad, deployed via
Semaphore: merges to `main` trigger `terraform plan`, surfaced in Semaphore's
UI as an approval gate before `apply`. This is the canonical source for any
job managed here — once a job has a directory in this repo, its spec is
edited and deployed here, not by hand against the cluster's HTTP API.

Nomad job specs that *aren't* migrated to Terraform yet still live in a
separate repo and are deployed by hand against the cluster's HTTP API. A job
moves out of that repo and into this one when it's brought under Terraform,
at which point its `.nomad.hcl` file's canonical copy lives here.

## Jobs

- [`minecraft`](minecraft)
- [`jerry`](jerry) — job ID is `jellify`, directory/README named `jerry`
- [`valheim`](valheim)
- [`actions-runner`](actions-runner)
- [`bobby`](bobby) — Discord bots in this repo are named after Grateful Dead
  members; see [`jerry/README.md`](jerry/README.md#naming) for the
  convention

## Structure

```
.
├── main.tf               one nomad_job resource per job, shared state
├── versions.tf
├── minecraft/
│   └── minecraft.nomad.hcl
├── jerry/                 the jellify Discord bot job
│   └── jerry.nomad.hcl
├── valheim/
│   └── valheim.nomad.hcl
├── actions-runner/
│   └── actions-runner.nomad.hcl
└── bobby/                  the Jellyfin-to-Discord voice bot
    └── bobby.nomad.hcl
```

This is a single root module — every job is one `nomad_job` resource in the
same `main.tf`, sharing one Consul-backed state, and Semaphore only needs one
Terraform App (pointed at the repo root) to plan/apply everything. The
tradeoff: `plan`/`apply` always cover every job at once, so a change to one
job's spec shows up in the same diff as everyone else's, and approving an
apply applies all of them together. Read the whole plan before approving —
there's no way to approve just one job's change here. If a job ever needs to
be isolated from that blast radius (frequent changes, higher risk, whatever
the reason), split it back out into its own directory with its own
`main.tf`/`versions.tf`/backend `path`, same pattern as before.

Each resource is named to match its job's actual Nomad job ID (the
`job "..."` block's name, not the directory) — that's what makes
`terraform import <address> <job-id>` read intuitively, e.g.
`nomad_job.minecraft` importing job ID `minecraft`, or `nomad_job.jellify`
(in the `jerry/` directory) importing job ID `jellify`. The `hashicorp/nomad`
provider's `nomad_job` resource is already the whole abstraction here (one
`jobspec` string in, one job registered out), so there's no wrapper module —
one would only add indirection with no behavior of its own.

`jobspec` loads each job's `.nomad.hcl` file via `file()` rather than
embedding it as a Terraform heredoc — Nomad's own
`${NOMAD_ALLOC_DIR}`/`${NOMAD_TASK_DIR}`-style interpolation syntax would
otherwise collide with Terraform's own `${...}` template interpolation
inside a heredoc string.

Adding a new job: create `<job>/<job>.nomad.hcl` with that job's spec, then
add a resource block to `main.tf`:

```hcl
resource "nomad_job" "<job-id>" {
  jobspec = file("${path.module}/<job>/<job>.nomad.hcl")
}
```

## Changelog

Job spec (`.nomad.hcl`) files here stay lean — no long inline comment blocks
explaining *why* something is the way it is, or the history of how it got
there. That belongs in [`CHANGELOG.md`](CHANGELOG.md) instead, dated, grouped
by job. A comment in a `.nomad.hcl` file should only ever describe something
non-obvious about its *current* state in a line or two; anything more (a
fix, a migration, a "confirmed on this date" note, a decision between
alternatives) goes in the changelog. This is a deliberate departure from the
separate hand-deployed `nomad-jobs` repo's convention (heavy inline comments,
no changelog) - that repo isn't changing retroactively, but anything brought
under Terraform here follows this convention going forward.

## Testing

[`tests/`](tests) validates every job spec and the Terraform config itself -
`terraform fmt`/`validate`, `nomad job validate` against a throwaway local
dev agent, and the repo's own written conventions (every job has a README,
is linked from this file, has a matching `main.tf` resource, and has no
hardcoded secret). Runs locally with `pytest tests/`, and in CI on every
push/PR via [`.github/workflows/validate.yml`](.github/workflows/validate.yml)
- see `tests/README.md` for detail. This is separate from, and faster than,
Semaphore's `terraform plan`: it catches spec errors before a PR is even
opened, but doesn't talk to the real cluster or Consul state.

## Dependency updates (Renovate)

[`renovate.json`](renovate.json) tracks two things repo-wide and opens a PR
whenever either changes — no config needed to get the second one, Renovate's
built-in `terraform` manager already scans any `*.tf` file for
`required_providers` blocks:

- **Docker images** referenced by `.nomad.hcl` job specs (`jerry`, `valheim`,
  `bobby` once merged). These are all pinned to the `:latest`
  tag, which has nothing for Renovate to version-bump on its own, so
  `pinDigests` makes it pin each one to the digest `:latest` currently
  resolves to (`image:latest@sha256:...`) and open a PR each time that
  digest changes upstream — same "new build published" signal, just keyed
  off the digest instead of a version number.
- **The `hashicorp/nomad` Terraform provider** version constraint in
  [`versions.tf`](versions.tf).

Minecraft's downloads (Paper, Geyser/Floodgate and the Modrinth
plugins/datapacks pinned in
[`minecraft/minecraft.nomad.hcl`](minecraft/minecraft.nomad.hcl)'s
`locals.artifacts` table) aren't tracked by Renovate: each entry pins a URL
*and* a checksum together, and a regex manager can only swap a version
string in place — it can't regenerate a Modrinth CDN URL (the path embeds a
Modrinth-assigned version ID) or recompute the hash. Those are handled by
[`.github/workflows/minecraft-updates.yml`](.github/workflows/minecraft-updates.yml)
instead, which runs daily and opens one complete, mergeable PR per update —
see [`minecraft/README.md`](minecraft/README.md#updates).

Onboarding step (one-time, not something I can do from here): install the
[Renovate GitHub App](https://github.com/apps/renovate) on this repo. Once
installed it picks up `renovate.json` on its own.

## Why Consul for state

The cluster already runs Consul with ACLs disabled, shared across every Nomad
datacenter — so it doubles as state storage with no new infra. Same
reasoning for the `nomad` provider's `address`: every host in the cluster
(any datacenter) reaches `127.0.0.1:4646` locally, and ACLs being off means
there's no token to configure.

## Bringing an already-running job under Terraform

`minecraft` and `valheim` were both already registered and running (real
players, a real world save) before this repo existed — applying either's
config for the first time must not re-trigger a deploy. `actions-runner` is
the same situation (already running on `galileo`/`hopper`, previously
deployed by the now-removed `Nomadintosh` Ansible role). Import the existing
job into state instead of creating it fresh, then confirm a plan is a true
no-op before ever running apply:

```sh
terraform init
terraform import nomad_job.minecraft minecraft
terraform import nomad_job.valheim valheim
terraform import nomad_job.actions-runner actions-runner
terraform plan   # must show "No changes" - if it doesn't, stop and diff by hand first
```

Because this is a single shared state, that `plan` will also show whatever
every other job in `main.tf` is doing (a create, for anything not yet
imported/applied) — only the `minecraft`/`valheim`/`actions-runner` portions
need to read as a no-op. `valheim`'s CPU/memory were bumped as part of moving
it here (see its job file), so its first plan after import is expected to
show that resource change, not a true no-op — everything else about it
should still match. `actions-runner`'s first plan after import is expected to
show its new `arm64`/`darwin` constraint being added the same way — an
in-place update on both existing allocations, not a destructive one
(confirmed via `/v1/job/actions-runner/plan` before this was written).

Only once `plan` looks right should Semaphore (or a human) ever run `apply`.
A genuinely new job with nothing registered yet (e.g. `jerry`) skips the
import step entirely — its resource just needs to show up as a create in
that same plan.

## Wiring into Semaphore

1. Add a single Terraform "App" pointed at this repo, working directory set
   to the repo root (not a job subdirectory — the `.tf` files live there
   now).
2. No extra credentials needed in the task template — Consul and Nomad are
   both unauthenticated on `127.0.0.1`, reachable because Semaphore itself
   runs as a Nomad job on one of the cluster's hosts.
3. Trigger the app on every merge to `main`, with the plan step requiring
   manual approval before apply.
