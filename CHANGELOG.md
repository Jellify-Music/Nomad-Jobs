# Changelog

History and rationale for jobs managed in this repo. Job spec (`.nomad.hcl`)
files themselves stay lean — the "why" behind a decision, a fix, or a
workaround lives here instead, dated, so it's still findable without reading
through commit-by-commit diffs. As of 2026-09-30 this replaces the older
convention (still visible in this repo's git history, and still used in the
separate hand-deployed `nomad-jobs` repo) of writing that history as long
inline HCL comments.

Newest entries first, grouped by job.

## minecraft

### 2026-09-30

- **`start.sh`'s `cleanup()` trap now preserves the real exit code**, instead
  of always reporting 0. Root-caused a live incident: a Nomadable/Ansible run
  against `euler.jellify.app` (bumping the `nomadintosh`/`nomaduntu`
  collection pin) tore down the task's wrapper process without going through
  its own SIGTERM handling, orphaning the backgrounded `java` process — which
  kept `world/session.lock` held. Every subsequent restart's `java` then
  failed instantly with `DirectoryLock: already locked`, but Nomad's UI and
  API only ever showed `Terminated Exit Code: 0`, because `cleanup()`'s last
  line was `rsync ... || true` — under a `trap ... EXIT` with no explicit
  `exit`, the shell reports whatever the trap's own last command returned,
  not the status that actually triggered the trap. Masked the real failure
  through all 5 restart attempts before the job dropped into its 30m backoff.
  Fixed by capturing `rc=$?` as `cleanup()`'s first statement and calling
  `exit "$rc"` at the end, so a crashed `java` now surfaces as a real
  non-zero exit instead of a silent, misleading success. (The orphan itself
  was resolved by hand — `kill` the stray PID on the host, then stop the
  stuck allocation via the Nomad API so a fresh one gets scheduled with a
  reset restart counter, since the client refuses to restart a task that's
  already in backoff.)
- **Removed the self-hosted status page (`minecraft-status` task).** It
  crash-looped the entire allocation: its CSS was embedded in a Python
  f-string using doubled `{{ }}` to escape literal braces, but the file is
  written out through a Nomad `template` block, which runs raw file content
  through Go's `text/template` engine *before* Python ever sees it — Nomad
  parsed `{{ color-scheme: dark; }}` as a template action and failed on the
  hyphen (`bad character U+002D '-'`), which killed the task, which per
  Nomad's group semantics killed its sibling `minecraft` task too. Decided
  not worth re-fixing and maintaining a hand-rolled Java SLP / Bedrock
  RakNet implementation for a cosmetic status page — no solid premade
  alternative exists that's both self-hosted (not a third-party API) and
  independent of the game server process itself (so it can report
  "offline"), so this was cut rather than replaced.
- **BlueMap moved from `minecraft.jellify.app/map` to the bare root.** With
  the status page gone, nothing else needs the root — dropped the
  `PathPrefix(/map)` router rule and the `stripprefix` middleware entirely.
- **Moved off galileo/hopper (macOS/arm64 Mac minis) onto the Ubuntu/x86_64
  jellify nodes** (`kepler`/`fibonacci`/`euler`/`dijkstra`) via a
  `${attr.cpu.arch} == amd64` constraint — the same one `valheim.nomad.hcl`
  already uses. Confirmed via the Nomad API before the move: each of the
  four x86_64 nodes reports ~27600 MHz / ~31300MB fingerprinted capacity,
  comfortably covering the resource bump below; galileo/hopper's own arm64
  fingerprint was a small fraction of that.
- **Resources bumped to 10000 MHz / 16384MB** (was 8 MHz / 6144MB — the old
  numbers were conservative even for a Mac mini). JVM heap raised alongside
  it (`-Xms8G -Xmx14G`, was `-Xms2G -Xmx4G`) to actually use the new
  allocation, leaving ~2GB of the 16GB reservation for off-heap/OS overhead
  rather than handing the JVM the entire thing.
- **Every macOS-specific path/tool updated for Linux**, following this same
  move: `/Volumes/Jellify/minecraft` → `/mnt/jellify/minecraft` (Linux
  jellify nodes mount the same NFS export at a different path — confirmed
  live via SSH to all four nodes); the NFS-mount-wait check's string match
  updated for Linux `mount`'s output format (`" on <path> type nfs"`, not
  macOS's `" on <path> (nfs"`); `fetch-jdk`'s Adoptium download switched
  from `mac/aarch64` to `linux/x64`, and its JDK-present check from
  `$jdk_dir/Contents/Home/bin/java` (macOS bundle layout) to
  `$jdk_dir/bin/java` (Linux tarball's flat layout); dropped an unused
  `HOME=/Users/violet` env var. `shasum`, `rsync`, `curl`, and `mount` were
  all confirmed present on all four target hosts before relying on them.
  `raw_exec` itself was kept (not switched to the `java` driver) even
  though the original macOS-only bug that forced `raw_exec` doesn't apply
  on Linux — it's a proven working setup already, no reason to swap it out.
- **Confirmed, then fixed: the job really was running as root.** Live alloc
  logs on `euler.jellify.app` showed Paper's own
  `YOU ARE RUNNING THIS SERVER AS AN ADMINISTRATIVE OR ROOT USER` warning —
  `raw_exec` tasks with no `user` set inherit the Nomad agent's own user, and
  that agent's systemd unit (as shipped by HashiCorp's apt package) runs as
  root by default for the client role. Fixed at the agent level, not here:
  `nomaduntu` (the Ansible collection managing these hosts) now overrides
  that with a systemd drop-in so the agent — and everything it runs via
  `raw_exec`, this job included — runs as a dedicated non-root `nomad`
  system user instead, matching how `consul` and the macOS/Nomadintosh
  agents already run non-root. See that repo's `CHANGELOG.md` (1.3.0) and
  `roles/nomad/README.md` for the actual change and its tradeoffs. No edit
  needed here — this job never set `user` itself, so it picks up the fix
  automatically once that playbook is deployed.
- **`/mnt/jellify/minecraft` re-permissioned ahead of the deploy.** `chgrp -R
  900` + `chmod -R g+rwX`, done directly (not through either repo) since it's
  live NFS data, not host config or a job spec — gid 900 is what `nomaduntu`
  will pin the new `nomad` service user to (see above); numeric-gid
  ownership works even before that group name exists on the hosts
  themselves, so this didn't need to wait for the `nomaduntu` deploy. Once
  that deploy runs, the `nomad` user lands in the same gid and can write
  here immediately - nothing further needed on this directory.
- Established this CHANGELOG.md as where this kind of history goes from now
  on, instead of long inline `.nomad.hcl` comments.
- **AutoTreeChop 1.7.5 added**, pinned and checksum-verified: fells an entire
  tree from one log break and auto-replants the correct sapling, so chopped
  forest actually regrows instead of leaving permanent stumps. Requested
  directly ("auto regrowth plugin ... trees and other vegetation
  automatically regrow"). Confirmed via Modrinth's API to declare support up
  to game version 26.3, covering the pinned 26.2 build — same margin
  BlueMap's pin has. Chosen over TimberReplant, TreeFalls, RealisticGrowth,
  EzTree, TreeForce, and Auto Crop Replant: most of those hadn't published a
  release declaring 26.2 support yet, and TimberReplant splits an unrelated
  Fabric/Forge mod line and a separate, less mature Bukkit/Paper plugin line
  across the same Modrinth project page, making it easy to pin the wrong
  file. No hard dependencies (protection-plugin/CoreProtect/PlaceholderAPI
  integration is optional) — doesn't need Vault or any other plugin already
  running here.

### 2026-09-29

- **BlueMap v5.28 (Paper build) added**, pinned and checksum-verified,
  originally mounted at `/map` behind a Traefik `PathPrefix` + `stripprefix`
  middleware (superseded above, now at the bare root). Chosen over a
  client-side minimap mod because this server bridges multiple Java
  versions (via ViaVersion/ViaBackwards) and Bedrock (via Geyser/Floodgate)
  — a Fabric/Forge-only minimap mod would only ever work for a subset of
  players. Confirmed via Modrinth's API to declare support up to game
  version 26.3, covering the pinned 26.2 Paper build. Not yet fully
  redeploy-safe as of this writing: BlueMap's own `plugins/bluemap/core.conf`
  needs its `accept-download` flag set (Mojang asset download consent) and
  `webserver.conf`'s port pinned to 8100 to match the network port, but the
  exact generated key names/layout for v5.28 hadn't been confirmed live at
  time of writing. Plan: deploy once the server is empty, let BlueMap
  generate its own defaults, patch the real config by hand/RCON once the
  keys are visible, then fold the confirmed values into an idempotent seed
  step (same `set_prop` pattern `seed-data` already uses).
- **A self-hosted status page was added** (removed 2026-09-30, see above) —
  pinged the server's own Java (SLP handshake) and Bedrock (RakNet
  unconnected-ping) ports directly, both protocols hand-implemented in
  Python's stdlib, specifically to avoid depending on a third-party status
  API/widget.
- **ViaVersion + ViaBackwards v5.12.0 added**, pinned (not always-latest
  like Geyser/Floodgate) specifically because `paper_version` is pinned too
  — a version pin only actually holds the server's protocol version steady
  if the bridge plugins are pinned alongside it. Confirmed via Modrinth's
  API to have a real (non-SNAPSHOT) release declaring Paper 26.2 support.
- **AuraSkills v2.4.0 added** (RPG skills/leveling, formerly "Aurelium
  Skills"). mcMMO was considered and rejected — it isn't distributed via
  Modrinth or Hangar at all (own site + GitHub only), so there was no
  trusted API path to verify a 26.2-compatible build the way everything
  else here is verified.
- **Terralith v2.6.4 and Tectonic v3.0.25 datapacks added**, confirmed
  compatible with Minecraft 26.2 via Modrinth's API, dropped in as `.zip`
  files directly (Minecraft loads zipped datapacks natively).
- **`json.loads(..., strict=False)` fix for PaperMC's Fill API.** Confirmed
  on build 129 for Paper 26.2: PaperMC's commit messages sometimes contain
  raw unescaped newlines, which strict-mode JSON parsing rejects as an
  "Invalid control character" — the try/except around the channel check was
  silently swallowing that as `channel=""` and skipping right past a
  genuinely `STABLE` build down to an older one that happened not to have
  problematic commit text. `strict=False` fixes the root cause; the
  try/except stays as a backstop for a truly malformed response.
- **Plugins directory made persistent** (`/Volumes/Jellify/minecraft/plugins`,
  now `/mnt/jellify/minecraft/plugins`). Originally deliberately ephemeral
  so Geyser/Floodgate always got a fresh dev build on every start, but that
  left nowhere for any *other* plugin to keep its own config/data across a
  restart. `fetch-geyser-floodgate` still overwrites only its own two files
  fresh every start; everything else in the directory is left alone.

### 2026-09-28

- **Local disk (via `ephemeral_disk`, `sticky` + `migrate`) became the
  live/hot copy** instead of the server reading/writing NFS directly. Root
  cause of a real bug where placed blocks were disappearing: the
  NFS-mounted share was causing multi-second main-thread stalls during
  Paper's own level-data saves, confirmed via an in-game thread dump. A new
  `seed-data` task does a one-time restore-from-NFS onto a fresh/empty local
  disk (only when local disk doesn't already have a world — `sticky`/
  `migrate` normally carries the local copy forward across a restart on the
  same host) plus an idempotent `server.properties` upsert.
- **`enforce-secure-profile` set to `false`.** Bedrock players connect
  through Floodgate as virtual accounts with no real Mojang-signed chat
  key, so the default (`true`) left them muted server-side ("Chat disabled
  due to missing profile public key", confirmed live in the server log)
  while Java players chatted normally.
- **`raw_exec` + a wrapper script adopted for the main task**, replacing the
  `java` driver. The `java` driver correctly fingerprinted the real JDK on
  `galileo` but its own executor couldn't actually fork/exec it
  (`operation not permitted`) — confirmed no corresponding TCC denial was
  logged for this one, ruling out a grantable-permission fix; the identical
  command worked fine over plain SSH. Same pattern `keycloak.nomad.hcl`
  already used successfully. (Superseded 2026-09-30: this job now runs
  exclusively on Linux, where this specific bug doesn't apply, but
  `raw_exec` was kept anyway as an already-proven setup.)
- **`fetch-jdk` added**: downloads a portable Adoptium JDK tarball rather
  than relying on a pre-installed JDK or a Homebrew cask. The cask
  (`brew install --cask temurin`) shells out to macOS's privileged
  `installer -pkg`, which needs an interactive Authorization Services
  approval and hung indefinitely over plain SSH (confirmed twice on
  `hopper`) — a different, unfixable-remotely mechanism from the TCC
  prompts below. Pinned to JDK feature version 25 specifically: Paper
  26.1+ requires Java 25+, confirmed the hard way when the first
  end-to-end deploy crash-looped against a JDK 21 fetched before this was
  known.
- **`cd` into the local data dir before launching java**, rather than
  passing every path as a CLI flag and leaving cwd at the task's own
  directory. `ops.json`/`whitelist.json`/ban lists/`usercache.json` have no
  CLI flag — Paper always writes these to cwd — so this is what makes them
  land in the same persistent, synced-back directory as everything else.
  Replaced an earlier `restore-identity-files`/`sync-identity-files`
  workaround that reached into a sibling task's directory (removed, no
  longer needed).
- **Periodic `rsync` sync-back added** (every 120s) to the durable NFS
  copy, covering the whole local data tree. `rsync`'s delta transfer
  instead of a plain `cp`, specifically to avoid pushing the entire world
  over NFS on every tick — that sustained-NFS-write-load pattern is exactly
  what caused the multi-second stalls above. No `--delete`: a file missing
  locally shouldn't get force-deleted from the backup copy. One final sync
  runs on a trapped `EXIT`/`INT`/`TERM` so a deliberate stop/redeploy loses
  nothing beyond the last tick.
- **`spawn-protection` set to `0`** (default 16 blocks non-op
  building/breaking near spawn).
- **RCON exposed internal-only by design**: bound to localhost, never
  registered as a Nomad service, never port-forwarded or routed through
  Traefik. Exists purely so ops tooling (the Chunky pre-gen run below, and
  a possible future whitelist automation) can issue console commands
  without needing `raw_exec` stdin access, which Nomad doesn't expose for
  that driver.
- **Chunky 1.5.3 added** for world pre-generation; its ~5,000-block-radius
  pre-gen run was kicked off once by hand over RCON, not wired into the
  job's own startup logic.

### 2026-09-27

- **First deploy**, to `galileo.jellify.app`, in a new `jellify` Nomad
  datacenter (data on the Jellify NAS, 10.10.37.32, mounted via
  Nomadintosh's `nfs_mounts` role). `violet` turned out to already be UID
  1000 on both jellify hosts, so no UID change was needed despite that
  being the original plan.
- **NFS/network-volume TCC gate hit**: `prepare-data-dir`'s `mkdir -p`
  against the NFS mount hung with zero output/error rather than failing
  fast, confirmed via `log show` as a `kTCCServiceSystemPolicyNetworkVolumes`
  denial against the `nomad` process itself (not the `mkdir` binary) — the
  same command over plain SSH succeeded instantly. Needs a human at the
  physical machine (or an active Screen Sharing session) to grant `nomad`
  access under Privacy & Security → Files and Folders/Full Disk Access;
  can't be scripted. Expected once per new macOS host. (Moot as of
  2026-09-30's move to Linux hosts.)
- **`restore-identity-files` had to be `poststart`, not `prestart`**: Nomad
  doesn't create every task's directory up front for a whole allocation,
  only for the tasks in the currently-active lifecycle tier — as
  `prestart` this failed outright because the main task's own directory
  didn't exist yet at that point.
- **Paper version-resolution channel-check bug found and fixed.** Paper
  runs two version lines side by side (a new `26.x` scheme, at the time
  `ALPHA`-channel, alongside the real stable `1.21.x` line) — a version
  string with no `-rc`/`-pre` suffix isn't enough to tell a real release
  from an alpha one, only the build's own `channel` field is. `26.3` had no
  such suffix but its latest build's channel was `ALPHA`; the naive
  string-based filter picked it as "latest" on the first run. Fixed to walk
  candidates and use the first whose latest build is actually `STABLE`,
  unless a version is pinned explicitly (a deliberate pin isn't
  second-guessed).
- **GeyserMC's `/builds/latest` needs `curl -L`.** That endpoint is a `302`
  redirect to the actual build-number endpoint — without `-L`, `curl -f`
  "succeeds" with an empty body instead of erroring, since a redirect isn't
  itself a failure.
- **`eula.txt` rendered fresh via a plain `template` block on every start.**
  Its content is static (`eula=true`), so there's nothing to lose by not
  persisting it.

## jerry

No history recorded here yet — `jerry.nomad.hcl` is small and has had no
notable operational incidents so far. Future changes to it should still get
an entry here rather than inline comments, per the convention above.

## actions-runner

### 2026-09-30

- **Brought under Terraform**, migrated from the `Nomadintosh` Ansible
  collection's `github_actions` role (a Jinja2 `.j2` template rendered to
  `actions-runner.nomad.hcl` on the host and registered via `nomad job run`),
  which was removed 2026-09-05 once job deployment moved out of Ansible.
  `galileo.jellify.app`'s inventory entry still shows `gh_actions.enabled:
  true` in that repo (`hopper.jellify.app` runs it too, just not reflected
  there) - this file is the same job, just brought under Terraform rather
  than a fresh spec. `count`, `resources`, and the env block were taken from
  the job as actually registered (`GET /v1/job/actions-runner` on
  `cassiopeia`, confirmed running on both `galileo`/`hopper`), not from the
  removed Ansible role's defaults, which had drifted (the role's own
  default was `memory = 10240`; the live job has been running at `cpu = 16`,
  `memory = 8192` for a while, presumably tuned by hand after the role was
  removed) - no restart policy is set either, matching the live job, which
  never had one and just runs on Nomad's own service-job default
  (`attempts = 2`, `interval = "30m"`, `delay = "15s"`, `mode = "fail"`).
- **Added an explicit `arm64`/`darwin` constraint**, which the live job
  doesn't have (`Constraints: null` in the API response) - it only ever
  landed on `galileo`/`hopper` because `gh_actions` was enabled by hand on
  exactly those two hosts, not because of any scheduler-enforced rule. Made
  explicit so the job can't drift onto one of the amd64 Ubuntu jellify
  nodes (kepler/fibonacci/euler/dijkstra, added for valheim/minecraft) if
  the cluster's node pool changes - the runner needs to build for
  Android/iOS, which is why it has to be this specific arch/OS combination
  and not just "any jellify node."
