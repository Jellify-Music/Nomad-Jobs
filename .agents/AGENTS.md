# Agent operating guide — jellify Nomad-Jobs

`README.md` explains the Terraform structure and conventions of this repo.
This file is the operational context an agent needs but that doesn't belong
in a human-facing README: cluster topology, safety rules, and gotchas
specific to working here.

## This repo vs. the others

- **This repo** (`Jellify/Nomad-Jobs`) — Terraform-managed job specs for the
  **jellify** datacenter, deployed via Semaphore (see README's "Wiring into
  Semaphore"). Once a job has a directory here, it's edited and deployed
  here — never by hand against the cluster's HTTP API.
- **`~/Workspace/nomad-jobs`** — the older, hand-deployed sibling repo for
  the **cosmonautical** datacenter (`cassiopeia`/`taurus`/`betelgeuse`, all
  macOS). Its own `.agents/AGENTS.md` documents that repo's HTTP-API deploy
  workflow and a set of macOS/TCC/driver gotchas (see below — several also
  apply here, since jellify has macOS hosts too).
- **`~/Workspace/Nomadable`** — the Ansible playbook that *provisions* Nomad
  + Consul onto hosts (installs the agent, not job workloads). It's a parent
  playbook that dispatches per-host to one of two child playbooks based on
  `ansible_os_family`:
  - **`~/Workspace/Nomadintosh`** — macOS (Apple Silicon) nodes, via
    Homebrew + LaunchAgents.
  - **`~/Workspace/nomaduntu`** — Ubuntu nodes, via the HashiCorp apt repo +
    systemd.
  A single Nomadable inventory group can mix both host types under one
  Consul/Nomad datacenter name — that's exactly what `jellify` is.
  Nomadintosh's Ansible role that used to template+deploy job specs directly
  (`gh_actions` rendering `actions-runner.nomad.hcl`, etc.) was **removed
  2026-09-05** once job deployment moved to this repo and the legacy one —
  don't resurrect that pattern here.

## Cluster topology — jellify

Mixed OS/arch, provisioned by Nomadable (`~/Workspace/Nomadable/inventory/hosts.yml`
is the live-ish reference — see caveat below):

| Host | OS/arch | Notes |
|---|---|---|
| `galileo.jellify.app` | macOS, arm64 (Apple Silicon Mac mini) | `container`+`podman` enabled, runs `gh_actions` (the actions-runner job) |
| `hopper.jellify.app` | macOS, arm64 | `container` enabled |
| `euler.jellify.app` | Ubuntu, amd64 | added for x86-only jobs (minecraft/valheim/bobby) |
| `dijkstra.jellify.app` | Ubuntu, amd64 | same |
| `fibonacci.jellify.app` | Ubuntu, amd64 | same |
| `kepler.jellify.app` | Ubuntu, amd64 | same |

**Caveat:** Nomadable's `inventory/hosts.yml` is checked into git but can lag
what a job spec actually constrains to — e.g. it still shows
`minecraft: enabled: true` under `galileo`, but `minecraft.nomad.hcl`
constrains to `attr.cpu.arch = amd64` (an Ubuntu-only node), so that flag is
stale. Treat the inventory as a rough map of intent, not ground truth about
where a job currently runs — check the job's own `constraint` blocks (this
repo) or `GET /v1/job/<name>` against the live cluster instead.

**That inventory file also has plaintext `ansible_password` /
`ansible_become_password` / a Discord webhook URL checked into git** — same
issue already flagged for Nomadintosh's inventory. Worth raising if you're
ever in a position to fix it, but out of scope for job-spec work in this
repo.

## Mixed-arch/OS constraints — read this before writing a job spec

Because `jellify` mixes arm64 macOS and amd64 Ubuntu hosts (unlike
cosmonautical, which is all-macOS), **a job spec here can't assume every
node looks the same** — pick the right `constraint` block deliberately:

```hcl
# Pin to the Ubuntu/amd64 nodes (euler/dijkstra/fibonacci/kepler)
constraint {
  attribute = "${attr.cpu.arch}"
  value     = "amd64"
}

# Pin to the macOS/arm64 nodes (galileo/hopper)
constraint {
  attribute = "${attr.cpu.arch}"
  value     = "arm64"
}
constraint {
  attribute = "${attr.kernel.name}"
  value     = "darwin"
}
```

Existing precedent in this repo: `minecraft`, `valheim`, and
`bobby` constrain to `amd64` (native x86_64 Linux, no
Rosetta/emulation); `actions-runner` constrains to `arm64` + `darwin`
(needs `ANDROID_HOME`/Xcode-adjacent tooling only present on the Mac
minis). `jerry` (the Discord bot) is unconstrained — it's a plain `docker`
task with no host-specific dependency, so it can land anywhere `docker`
driver is available.

Don't assume `docker`/`container`/`podman` availability is uniform across
jellify hosts — check the target host's actual driver fingerprint
(`GET /v1/nodes` → node's `Drivers` map) rather than trusting the Nomadable
inventory flags, per the caveat above.

**CPU sizing also isn't uniform across the two host types, for the same
reason.** `galileo`/`hopper` (macOS/arm64) fingerprint CPU in the
single/double digits, not the usual Nomad MHz-scale totals — same quirk
documented in full in `~/Workspace/nomad-jobs/.agents/AGENTS.md`'s "macOS
CPU fingerprint" section (cosmonautical is all-macOS, so it has the fuller
writeup and the incident that exposed it). Evidence from this repo:
`actions-runner` (constrained to `darwin`/`arm64`, i.e. `galileo`) uses
`cpu = 16`, while `amd64`-constrained jobs on the Ubuntu nodes use
normal-scale values (`minecraft`'s main task and `valheim` both use
`cpu = 10000`). Don't copy a `cpu` value from one job to a new one without
checking which host type it's actually constrained to — `bobby`'s
`cpu = 200` and `jerry`'s `cpu = 100` are genuinely small MHz values on a
normal-scale Ubuntu host, not examples of this quirk, and sizing a
`galileo`/`hopper`-bound job the same way would ask for far more headroom
than those hosts can actually fingerprint.

## Gotchas that carry over from the macOS side of the fleet

`galileo`/`hopper` are macOS hosts, same as all of cosmonautical, so the
macOS-specific gotchas documented in `~/Workspace/nomad-jobs/.agents/AGENTS.md`
apply here too whenever a job targets them — most notably:

- **TCC blocks writes to external/removable and NFS/network volumes** from
  SSH-launched or `raw_exec`-driven processes (gotchas #6/#6b there) — needs
  a human at the physical machine to grant access once per host; expect it
  to surface the first time a path is actually written to, not at
  registration. Hit for real on `minecraft.nomad.hcl`'s first deploy to
  `galileo` (2026-09-27) — see `CHANGELOG.md`.
- **The `java` task driver can't fork/exec on these hosts** (gotcha #7) —
  use `raw_exec` + a wrapper script instead, same pattern `minecraft`
  already uses.
- **Don't install anything via a Homebrew cask that wraps a `.pkg`** (gotcha
  #7b) — it needs an interactive Authorization Services prompt and hangs
  forever over SSH; use a portable tarball/zip instead.

Read that file's "Known gotchas" section in full before debugging anything
odd on `galileo`/`hopper` — don't re-litigate a gotcha already diagnosed
there.

## Checking live drift

`/opt/nomad/jobs` (or any host-side copy of a job spec) is never the source
of truth — this repo is. When auditing host-side state for drift against
git:

- **Staleness cutoff: if a host-side file hasn't been modified in the last
  week, don't bother diffing it** — the user has stated they don't care
  about anything older than that, even if it differs from git.
- For anything modified more recently, diff *content*, not mtimes — a local
  working tree's own checkout mtimes cluster around one bulk timestamp and
  are not meaningful; only the live host's mtime is.
- Confirm explicitly before any destructive multi-host action (deleting
  stale `/opt/nomad/jobs` copies, etc.) even if the user's phrasing sounds
  like a decision already made — a one-line explicit go-ahead first.

## Secrets

Same Consul KV pattern as the legacy repo — nothing here manages secrets
via Terraform (no `consul_keys` resource in `main.tf`). Every credential is
populated by hand into Consul KV ahead of a job's first deploy, then
referenced from a `template` block inside the `.nomad.hcl` file:

```hcl
template {
  data        = <<EOT
TOKEN={{ key "jellify/jerry/DISCORD_TOKEN" }}
EOT
  destination = "secrets/app.env"
  env         = true
}
```

Convention here: keys live under `jellify/<job>/<KEY_NAME>` (see
`bobby`'s entry in `CHANGELOG.md` for a real example). List
keys under a prefix without reading values first
(`curl 'http://127.0.0.1:8500/v1/kv/<prefix>?keys'`) before reading an
actual value.

**Exception to the naming convention**: `jerry`'s keys live under
`jellify/discord-bot/*`, not `jellify/jerry/*` — the job ID and its Consul
KV namespace don't match here (unlike every other job in this repo). Not
worth renaming/migrating just for consistency (live keys, no functional
issue), but don't assume job ID == KV prefix without checking when adding a
new job's `template` block.

Each job's own README has a "Consul KV keys" table listing exactly what it
needs — check there rather than grepping the `.hcl` by hand.

## Non-secret config (Nomad Variables)

**Convention started 2026-09-30, on cosmonautical's `romm` job — not yet
used by anything in this repo.** Split by sensitivity, not just "is it
config": secrets stay in Consul KV as above; non-sensitive but
deployment-specific values (URLs, hostnames, labels — anything a redeploy
to a different environment/domain would need to change) go in a [Nomad
Variable](https://developer.hashicorp.com/nomad/docs/job-declare/nomad-variables)
instead of being hardcoded into the `.nomad.hcl` file, so the spec stays
reusable. Structural identifiers a job owns (DB name/user, a task's own
OIDC client ID, port labels) stay as plain HCL literals either way — this
is about environment-shaped config specifically, not "anything that isn't
a password."

Path convention: `nomad/jobs/<job-id>`. Read in a `template` block with
`{{ with nomadVar "nomad/jobs/<job-id>" }}{{ .KEY }}{{ end }}` — same
consul-template engine as `{{ key "..." }}`, different backend. Keep these
in their own `template` block (`destination = "local/..."`, not
`secrets/...`) rather than merging into the same template as Consul KV
secrets. No `nomad` CLI on any host, so populate by hand via the HTTP API:
`curl -X PUT 127.0.0.1:4646/v1/var/nomad/jobs/<job-id> -d '{"Items": {"KEY": "value"}}'`.
Full writeup and the first real example:
`~/Workspace/Cosmonautical/Nomad-Jobs/.agents/AGENTS.md`'s own copy of this
section, and `Cosmonautical/Nomad-Jobs/romm`'s job spec/README.

## Adding a new job — checklist

1. `<job>/<job>.nomad.hcl` + a `nomad_job` resource in `main.tf` (README's
   "Adding a new job" has the exact snippet).
2. `<job>/README.md` — what it runs, notable choices, a "Consul KV keys"
   table (or an explicit "None" line if it needs none).
3. **Add it to the linked job list at the top of `README.md`'s "Jobs"
   section.** The list is only useful if it's actually complete, so treat a
   new job dir without a corresponding list entry as an incomplete PR, same
   as one missing a README. `tests/test_conventions.py` now enforces this
   (and the README/`main.tf` requirements below) in CI — see the top-level
   README's "Testing" section.
4. If it's already running (migrated/brought under Terraform), add its
   `terraform import` line to `README.md`'s import command list.

## Don't

- Don't hand-deploy a job spec that lives in this repo directly against the
  cluster's HTTP API — it goes through Terraform/Semaphore, or state drifts
  out from under the next `plan`.
- Don't trust `terraform plan` output at face value for an import — verify
  the specific job's portion reads as a true no-op (or only the intended
  change) against the live cluster's `/v1/job/<id>/plan` too, not just by
  reading the Terraform diff.
- Don't assume a host-side `/opt/nomad/jobs/*` copy, or Nomadable's
  `inventory/hosts.yml` flags, reflect current reality — verify against this
  repo and what's actually registered (`GET /v1/job/<name>`).
- Don't run `ansible-playbook` (Nomadable or either child repo) against a
  live/in-use host without asking first, for the same reason as the legacy
  repo's guide: the user sometimes wants a risky change applied by hand,
  node by node, rather than a fleet-wide pass.
