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

## Structure

```
.
├── minecraft/           root module for the minecraft job (Paper server), own state
│   ├── minecraft.nomad.hcl
│   ├── main.tf          resource "nomad_job" "minecraft" { jobspec = file(...) }
│   └── versions.tf
└── discord-bot/         root module for the jellify Discord bot job, own state
    ├── jellify.nomad.hcl
    ├── main.tf          resource "nomad_job" "jellify" { jobspec = file(...) }
    └── versions.tf
```

One root module per job, each with its own Consul-backed state. This keeps
blast radius scoped to a single job — running Terraform for `minecraft` can
never lock or diff against another job's state. Each `main.tf` is a single
`nomad_job` resource, named to match that job's actual Nomad job ID (the
`job "..."` block's name, not the directory) — that's what makes
`terraform import <address> <job-id>` read intuitively, e.g.
`nomad_job.minecraft` importing job ID `minecraft`. The `hashicorp/nomad`
provider's `nomad_job` resource is already the whole abstraction here (one
`jobspec` string in, one job registered out), so there's no wrapper module —
one would only add indirection with no behavior of its own.

`jobspec` loads the job's `.nomad.hcl` file via `file()` rather than
embedding it as a Terraform heredoc — Nomad's own
`${NOMAD_ALLOC_DIR}`/`${NOMAD_TASK_DIR}`-style interpolation syntax would
otherwise collide with Terraform's own `${...}` template interpolation
inside a heredoc string.

Adding a new job: copy `minecraft/` to `<job>/`, replace `minecraft.nomad.hcl`
with that job's spec, rename the resource in `main.tf` to match its job ID,
and update the backend `path` in `versions.tf`.

## Why Consul for state

The cluster already runs Consul with ACLs disabled, shared across every Nomad
datacenter (`jellify`'s agents `retry_join` the same servers as every other
datacenter) — so it doubles as state storage with no new infra. Same
reasoning for the `nomad` provider's `address`: every host in the cluster
(any datacenter) reaches `127.0.0.1:4646` locally, and ACLs being off means
there's no token to configure.

## Bringing an already-running job under Terraform

`minecraft` was already registered and serving real players before this repo
existed — applying its config for the first time must not re-trigger a
deploy. Import the existing job into state instead of creating it fresh, then
confirm a plan is a true no-op before ever running apply:

```sh
cd minecraft
terraform init
terraform import nomad_job.minecraft minecraft
terraform plan   # must show "No changes" - if it doesn't, stop and diff by hand first
```

Only once `plan` is clean should Semaphore (or a human) ever run `apply`
against this directory. A genuinely new job with nothing registered yet (e.g.
`discord-bot`) skips this entirely — `terraform apply` after a clean `plan`
(showing a create, not an update) is all that's needed.

## Wiring into Semaphore

1. Add a Terraform "App" per job, each pointed at this repo with that job's
   directory (`minecraft`, `discord-bot`, ...) as the working directory —
   keeps one job's plan/apply from ever touching another's state.
2. No extra credentials needed in the task template — Consul and Nomad are
   both unauthenticated on `127.0.0.1`, reachable because Semaphore itself
   runs as a Nomad job on one of the cluster's hosts.
3. Trigger each app on merge to `main` touching its own directory, with the
   plan step requiring manual approval before apply.
