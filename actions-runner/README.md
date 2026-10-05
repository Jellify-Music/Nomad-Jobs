# actions-runner

Self-hosted GitHub Actions runners for the Jellify App repo
(`Jellify-Music/App`): ARM macOS runners for Android/iOS builds and Maestro
tests, plus x64 Linux runners for everything that doesn't need a Mac. A
`system` job: one runner on every node in Nomadable's `github_runners`
inventory group, through one task group per OS:

| Group | Hosts | Labels | How it runs |
|---|---|---|---|
| `actions-runner-macos` | `galileo`, `hopper` | `self-hosted,macOS,ARM64` | `raw_exec` against the host toolchain Nomadable provisions |
| `actions-runner-linux` | `fibonacci`, `dijkstra` (once added to the group) | `self-hosted,Linux,X64` | `docker`, official `ghcr.io/actions/actions-runner` image |

Workflows pick an OS by label, so a job only lands on Linux if its
`runs-on` asks for `Linux`.

## How it works

- **Placement** — Nomadintosh's `nomad` role publishes each client's
  inventory groups as node meta `inventory_groups`; this job constrains on it
  containing `github_runners`, and each group adds an `attr.kernel.name`
  constraint (`darwin` / `linux`). Adding or removing a runner host is an
  inventory change in Nomadable, not a change here.
- **Runner binary (macOS)** — pre-warmed by Nomadable at
  `/opt/actions-runner/current` (`github_runner_actions_runner_version`,
  tracked by Renovate there). `start.sh` copies it into the allocation, so
  the runner's self-updates stay in the allocation and Ansible can prune old
  versions under a running runner. Nothing is installed or registered by
  hand on the host.
- **Runner binary (Linux)** — the image tag, pinned by digest and bumped by
  Renovate here. It can drift from the macOS version Nomadable pins; the
  runner self-updates either way.
- **Registration** — `start.sh` loops forever: it asks GitHub for a
  [JIT runner config](https://docs.github.com/en/rest/actions/self-hosted-runners#create-configuration-for-a-just-in-time-runner-for-a-repository)
  and runs the runner with it. A JIT runner is ephemeral — it takes exactly
  one job, then deregisters itself — so the next loop iteration registers a
  fresh one. Runner names are `<host>-<unix time>`.
- **Clean work folder** — `_work` (the checkout, `node_modules`, Android
  build output) is deleted before every job, so no job sees the previous
  one's files. Cross-run caching is `actions/cache`'s job.

## Linux group

- **No host toolchain.** nomaduntu installs nothing for `github_runners`, and
  Nomadable's `group_vars/github_runners.yml` only means anything to
  Nomadintosh's macOS roles. Workflows bring their own tools with
  `actions/setup-*`; the image has `git`, `curl`, `jq` and the Docker CLI
  (no daemon socket is mounted, so Docker-based steps won't work).
- **No sudo.** `start.sh` runs as root, reads the PAT, then empties
  `/etc/sudoers` and runs each runner as the image's `runner` user. The
  image would otherwise give `runner` passwordless sudo, and any CI job
  could read the PAT out of `start.sh`'s memory. Steps that `sudo apt-get
  install` won't work here.
- **Fresh state per job, within one container.** `_work` is wiped and every
  process left by `runner` (Gradle daemons, background servers) is killed
  between jobs. The toolcache (`/home/runner/toolcache`) is kept for the
  life of the allocation and goes with the container.
- **No Android emulator yet.** That needs `/dev/kvm` passed into the
  container and an `x86_64` system image.

## Directories (macOS group)

| Path | What | Lifetime |
|---|---|---|
| `/opt/actions-runner/current` | Pre-warmed runner binary (Nomadable) | Replaced on each version bump |
| `<alloc>/actions-runner/local/runner/` | This allocation's copy of the runner, `_work` | `_work` wiped per job; the rest goes with the allocation |
| `/opt/github-actions/home` | The runner's `HOME`: `~/.gradle`, `~/.android/avd`, bun's install cache | Persistent. Gradle prunes its own caches; bun's cache is cleared once it passes `BUN_CACHE_MAX_GB` (10) |
| `/opt/github-actions/toolcache` | `actions/setup-*` downloads (`AGENT_TOOLSDIRECTORY`) | Persistent |

## Toolchain (provisioned by Ansible, not this job)

The host-side tools come from Nomadable's
[`group_vars/github_runners.yml`](https://github.com/Cosmonautical-Cloud/Nomadable/blob/main/group_vars/github_runners.yml),
applied by Nomadintosh's generic roles. This job hardcodes their paths in its
`env` block — keep them in sync:

| Tool | Path in `env` | Version owned by |
|---|---|---|
| actions/runner | `RUNNER_DIST` (`/opt/actions-runner/current`) | `github_runner_actions_runner_version` there |
| bun | `/opt/homebrew/bin/bun` (on `PATH`) | `github_runner_bun_version` there — workflows don't use `setup-bun` |
| Maestro | `/opt/maestro/current/bin` | `github_runner_maestro_version` there |
| Node 24 | `/opt/homebrew/opt/node@24/bin` (keg-only, so on `PATH` explicitly) | `node@24` Homebrew formula, added through Semaphore's `additional_homebrew_packages__*` variables — workflows don't use `setup-node` |
| Ruby 4.0 | `/opt/homebrew/opt/ruby@4.0/bin` (on `PATH` explicitly) | `ruby@4.0` Homebrew formula there, kept in sync with the App's `ios/.ruby-version` — the App's `install-pods` action skips `setup-ruby` here |
| JDK 17 | `JAVA_HOME` | `openjdk@17` (Nomadintosh `android_sdk` role) |
| Android SDK | `ANDROID_HOME` / `ANDROID_SDK_ROOT` | `android_sdk_packages` there |

## Consul KV keys

| Key | Used for |
|---|---|
| `jellify/actions-runner/GITHUB_PAT` | Shared by both groups. Fine-grained personal access token scoped to `Jellify-Music/App` with **Administration: read and write** — the permission `generate-jitconfig` requires. Only used to mint JIT configs; `start.sh` reads it once and deletes the rendered file so workflow steps can't read it |

The allocation stays pending until the key exists.

## Notable choices

- **`type = "system"` instead of `count`** — the old `count = 2` had no
  `distinct_hosts` constraint, so both allocations could land on one host;
  they only ever spread because `cpu = 16` against the Macs' odd 28 MHz
  fingerprint left room for exactly one per node.
- **No `artifact` block** — the runner tarball holds 4097 files, one over
  go-getter's decompression limit (`tar archive contains too many files:
  4097 > 4096`). Raising `decompression_file_count_limit` in every client's
  config would work too, but pre-warming also saves a ~200 MB download on
  every allocation start.
- **`raw_exec`** — the runner needs the host's real toolchain, emulator and
  Hypervisor.framework access.
- **`cpu = 16` / `memory = 8192`** — unchanged from the job as it ran before
  this rewrite.
- **Linux in Docker, not a ported host toolchain** — nomaduntu would need
  Homebrew-equivalent roles for every tool, and the macOS group's paths
  don't exist on Ubuntu anyway. The official image keeps the hosts clean
  and the runner version in one Renovate-tracked line.
- **The PAT goes to `curl` on stdin** (Linux group), so it never appears in
  a process's argv.

## History

See [`../CHANGELOG.md`](../CHANGELOG.md#actions-runner).
