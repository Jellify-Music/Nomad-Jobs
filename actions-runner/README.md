# actions-runner

Self-hosted GitHub Actions runners for the Jellify App repo
(`Jellify-Music/App`), giving it ARM macOS runners for Android builds and
Maestro tests. A `system` job: one runner on every node in Nomadable's
`github_runners` inventory group (currently `galileo` and `hopper`).

## How it works

- **Placement** — Nomadintosh's `nomad` role publishes each client's
  inventory groups as node meta `inventory_groups`; this job constrains on it
  containing `github_runners`. Adding or removing a runner host is an
  inventory change in Nomadable, not a change here.
- **Runner binary** — downloaded by the `artifact` block at
  `local.runner_version` (tracked by Renovate) into the allocation. Nothing
  is installed or registered by hand on the host.
- **Registration** — `start.sh` loops forever: it asks GitHub for a
  [JIT runner config](https://docs.github.com/en/rest/actions/self-hosted-runners#create-configuration-for-a-just-in-time-runner-for-a-repository)
  and runs the runner with it. A JIT runner is ephemeral — it takes exactly
  one job, then deregisters itself — so the next loop iteration registers a
  fresh one. Runner names are `<host>-<unix time>`.
- **Clean work folder** — `_work` (the checkout, `node_modules`, Android
  build output) is deleted before every job, so no job sees the previous
  one's files. Cross-run caching is `actions/cache`'s job.

## Directories

| Path | What | Lifetime |
|---|---|---|
| `<alloc>/actions-runner/local/runner/` | Runner binary, `_work` | `_work` wiped per job; the rest goes with the allocation |
| `/opt/github-actions/home` | The runner's `HOME`: `~/.gradle`, `~/.android/avd`, bun's install cache | Persistent. Gradle prunes its own caches; bun's cache is cleared once it passes `BUN_CACHE_MAX_GB` (10) |
| `/opt/github-actions/toolcache` | `actions/setup-*` downloads (`AGENT_TOOLSDIRECTORY`) | Persistent |

## Toolchain (provisioned by Ansible, not this job)

The host-side tools come from Nomadable's
[`group_vars/github_runners.yml`](https://github.com/Cosmonautical-Cloud/Nomadable/blob/main/group_vars/github_runners.yml),
applied by Nomadintosh's generic roles. This job hardcodes their paths in its
`env` block — keep them in sync:

| Tool | Path in `env` | Version owned by |
|---|---|---|
| bun | `/opt/homebrew/bin/bun` (on `PATH`) | `github_runner_bun_version` there — workflows don't use `setup-bun` |
| Maestro | `/opt/maestro/current/bin` | `github_runner_maestro_version` there |
| JDK 17 | `JAVA_HOME` | `openjdk@17` (Nomadintosh `android_sdk` role) |
| Android SDK | `ANDROID_HOME` / `ANDROID_SDK_ROOT` | `android_sdk_packages` there |

## Consul KV keys

| Key | Used for |
|---|---|
| `jellify/actions-runner/GITHUB_PAT` | Fine-grained personal access token scoped to `Jellify-Music/App` with **Administration: read and write** — the permission `generate-jitconfig` requires. Only used to mint JIT configs; `start.sh` reads it once and deletes the rendered file so workflow steps can't read it |

The allocation stays pending until the key exists.

## Notable choices

- **`type = "system"` instead of `count`** — the old `count = 2` had no
  `distinct_hosts` constraint, so both allocations could land on one host;
  they only ever spread because `cpu = 16` against the Macs' odd 28 MHz
  fingerprint left room for exactly one per node.
- **No `artifact` checksum** — Renovate can bump `runner_version` but can't
  recompute a checksum, so a pinned one would break every bump PR. The
  download is over HTTPS from GitHub's release assets.
- **`raw_exec`** — the runner needs the host's real toolchain, emulator and
  Hypervisor.framework access.
- **`cpu = 16` / `memory = 8192`** — unchanged from the job as it ran before
  this rewrite.

## History

See [`../CHANGELOG.md`](../CHANGELOG.md#actions-runner).
