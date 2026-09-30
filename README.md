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

- [`jellyfin-music-bot`](jellyfin-music-bot)
- `minecraft`, `jerry`, `valheim`, `actions-runner` — READMEs for these
  exist on `main` but haven't been merged into this branch
  (`add-jellyfin-music-bot`) yet, so they're not linked here to avoid
  pointing at files that don't exist on this branch. Once merged, add them
  to this list the same way.

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
└── jellyfin-music-bot/
    └── jellyfin-music-bot.nomad.hcl
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
