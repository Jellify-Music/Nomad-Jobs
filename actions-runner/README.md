# actions-runner

Self-hosted GitHub Actions runner for the Jellify App repo, giving it an ARM
macOS runner for Android/iOS builds. Runs on both `galileo` and `hopper`
(`count = 2`) — the arm64 Mac minis in the jellify datacenter.

## Notable choices

- **`arm64`/`darwin` constraint, added explicitly** when this job was
  brought under Terraform (2026-09-30) — the job as it actually ran before
  had no constraint at all (`Constraints: null`), and only ever landed on
  `galileo`/`hopper` because the old Ansible role (`Nomadintosh`'s
  `github_actions`) was enabled by hand on exactly those two hosts. Made
  explicit here so the job can't drift onto one of the amd64 Ubuntu jellify
  nodes (kepler/fibonacci/euler/dijkstra) if the cluster's node pool
  changes — the runner needs to build for Android/iOS, which is why it has
  to be this specific arch/OS combination, not just "any jellify node."
- **The runner binary itself is set up by hand**, not by this job.
  `/opt/github-actions/run.sh` has to already be downloaded and registered
  with GitHub first (repo/org → Settings → Actions → Runners → New
  self-hosted runner) on each host — Nomad only starts `run.sh`, it doesn't
  register the runner.
- **`ANDROID_HOME` is set explicitly** because `raw_exec` runs a
  non-login shell that never sources `/etc/profile`, so the Android SDK path
  wouldn't otherwise be on the process's environment even though it's set
  system-wide for interactive sessions.
- **No `restart` block**, matching the job as it actually ran before
  migration — it just uses Nomad's own service-job default (`attempts = 2`,
  `interval = "30m"`, `delay = "15s"`, `mode = "fail"`).
- **`cpu = 16` / `memory = 8192`** — taken from the job as actually
  registered at migration time (`GET /v1/job/actions-runner`), not from the
  removed Ansible role's own defaults, which had drifted (the role
  defaulted to `memory = 10240`).

## History

Brought under Terraform 2026-09-30, replacing the `Nomadintosh` Ansible
collection's `github_actions` role (removed once job deployment moved out of
Ansible). See [`../CHANGELOG.md`](../CHANGELOG.md#actions-runner) for the
full migration note.
