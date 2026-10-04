# Changelog

History and rationale for jobs managed in this repo. Job spec (`.nomad.hcl`)
files themselves stay lean — the "why" behind a decision, a fix, or a
workaround lives here instead, dated, so it's still findable without reading
through commit-by-commit diffs. As of 2026-09-30 this replaces the older
convention (still visible in this repo's git history, and still used in the
separate hand-deployed `nomad-jobs` repo) of writing that history as long
inline HCL comments.

Newest entries first, grouped by job.

## bobby

### 2026-09-30

- **Fixed: bot joined voice but never actually played anything, stuck
  reconnecting its Jellyfin WebSocket forever.** Reported as "bobby can't
  join my voice channel" - misleading, since `/summon`/`/play` did put it in
  the channel; the real failure was `[JellyfinWebSocketService] WebSocket
  error: Unexpected server response: 403` on a 5s reconnect loop, confirmed
  against Jellyfin's own log on `cassiopeia`
  (`Error processing request: "Token is required". URL "GET" "/socket"`,
  paired with `User "bobby" ... stopped playback ... at "0"ms` - REST auth
  succeeded, the `/socket` handshake didn't). Root cause: Jellyfin here runs
  **12.1.0**, but the image was pinned to `:latest` -> the `1.5.0` release
  (built 2026-08-26), which predates a jellyfin-sdk compatibility fix the
  upstream maintainer merged 2026-09-13
  ([`manuel-rw/jellyfin-discord-music-bot#618`](https://github.com/manuel-rw/jellyfin-discord-music-bot/issues/618),
  merged as #621) specifically for Jellyfin 12's websocket auth. No tagged
  release has shipped with that fix as of this writing - only the rolling
  `:dev` tag (confirmed built 2026-09-13T18:38:35Z, right after the fix
  landed) has it, and the upstream issue thread itself fizzled out without a
  maintainer confirmation that `:dev` fully resolves it end-to-end for
  everyone. Chose to pin the exact `:dev` digest
  (`sha256:c429544911995cff5d5d0bc88c5f89ef96305dde3abb1638bc7cdeb08735866b`)
  rather than float on `:dev` or wait indefinitely for a stable release -
  same `image:tag@sha256:digest` shape Renovate's existing regex manager for
  this repo already parses (`renovate.json`, `customManagers`), so a later
  digest change on `:dev` still surfaces as a normal Renovate PR rather than
  silently drifting; needs a human to actually merge it though, since
  `:dev` is an unstable branch build, not a release - don't auto-merge a
  bobby image bump the way `jerry`/`valheim`'s `:latest` bumps might be
  treated.
- **Fixed: bot couldn't authenticate to Jellyfin, so it never found music or
  joined voice.** Root cause - the `secrets/.env` template's values were
  unquoted, and Nomad's `template { env = true }` line parser
  ([`hashicorp/go-envparse`](https://github.com/hashicorp/go-envparse))
  treats a bare `#` as the start of a comment *anywhere* in an unquoted
  value, no preceding whitespace required - it doesn't follow the
  dotenv/shell convention of only doing that after whitespace. The Jellyfin
  account's password contains a `#`, so only the characters before it ever
  reached the container's environment; every `POST
  /Users/AuthenticateByName` to Jellyfin came back `401`, confirmed via
  `/v1/client/fs/logs` on the alloc's `stderr`. Fixed by wrapping all three
  templated values in double quotes - `go-envparse` preserves `#` (and most
  other characters) literally inside quotes. Applied the same fix to
  `jerry/jerry.nomad.hcl` and `minecraft/minecraft.nomad.hcl`'s
  `RCON_PASSWORD` line, which had the identical unquoted-value pattern and
  the same latent bug risk (`valheim/valheim.nomad.hcl`'s `PASSWORD` was
  already quoted). Note this only guards against unquoted special
  characters like `#` - a literal `"` inside a secret would still need
  escaping (`go-envparse` supports `\"` inside double quotes, same as JSON),
  not handled here since none of the current secrets are known to contain one.
- **Renamed from `jellyfin-music-bot` to `bobby`** (job ID, directory, and
  Consul KV prefix all moved from `jellyfin-music-bot`/`jellify/jellyfin-music-bot/*`
  to `bobby`/`jellify/bobby/*`) before its first deploy - no import/migration
  needed since nothing was registered yet. Considered reusing `jerry`'s
  Discord token instead of provisioning a new bot application; rejected -
  Discord tokens are one-session-per-application, so both jobs running under
  the same token would fight over the gateway connection, and `jerry`'s
  application was never granted the voice-connect/speak permissions or
  Voice States intent this bot needs. Reusing it would also make `/summon`
  etc. show up under `jerry`'s bot identity in Discord, not a distinct bot.
  This established the naming convention for Discord bots in this repo:
  named after Grateful Dead members matching their role - `jerry` (Jerry
  Garcia, chat bot) and `bobby` (Bobby Weir, voice bot) - see
  [`jerry/README.md`](../jerry/README.md#naming).
- **Added.** Runs [`manuel-rw/jellyfin-discord-music-bot`](https://github.com/manuel-rw/jellyfin-discord-music-bot)
  (`ghcr.io/manuel-rw/jellyfin-discord-music-bot:latest`) to broadcast the
  Jellify Jellyfin library into Discord voice channels, specifically for
  streaming into `The Music Hall` (channel ID `1437161572396044288`) on the
  Jellify Discord server (guild ID `1351285328400351344`). Constrained to
  `amd64` (the Ubuntu jellify nodes), by request - it doesn't need
  galileo/hopper's arm64 capacity, unlike `jerry`.
  - This bot has no env var for auto-joining a fixed voice channel or guild -
    it's single-guild only, and joins whichever voice channel the command
    issuer is in when they run `/summon`. So after each deploy/restart,
    someone has to sit in The Music Hall and run `/summon` (then `/play`,
    `/playliked`, `/random`, etc.) to actually start playback - it isn't
    zero-touch. `LOCKED_CHANNEL_IDS` (unset here) would restrict which text
    channel(s) accept bot commands, not which voice channel it joins - left
    unset for now.
  - Needs a dedicated Jellyfin account for the bot (not the admin account,
    per upstream's own advice) - its credentials plus the Discord bot token
    must be populated in Consul KV at `jellify/bobby/DISCORD_CLIENT_TOKEN`,
    `.../JELLYFIN_AUTHENTICATION_USERNAME`, and
    `.../JELLYFIN_AUTHENTICATION_PASSWORD` before the first deploy - same
    pattern as `jerry`'s Discord token. The Discord bot application itself
    (token, invite with voice-connect/speak permissions) still has to be
    created by hand in the Discord Developer Portal first.
  - `JELLYFIN_SERVER_ADDRESS` points at the public
    `https://jellyfin.jellify.app` Traefik hostname, not a LAN address -
    Jellyfin itself runs on `cassiopeia` in the separate `cosmonautical`
    datacenter (see the legacy `nomad-jobs` repo's `jellyfin.nomad.hcl`), not
    in `jellify` alongside this bot.
  - A genuinely new job, nothing registered yet - skips the `terraform
    import` step other jobs in this repo needed.

## Repo tooling

### 2026-09-30

- **Added Renovate** (`renovate.json`), requested directly ("keep track of
  updates... so I can just merge an auto generated PR to bump changes").
  Covers the two things that are both (a) actually tracked by a version or
  digest and (b) require no bespoke verification to bump: the `:latest`
  Docker images in `jerry`/`valheim`/`bobby` (via `pinDigests`
  and a custom regex manager, since a bare `image = "..."` line in a
  `.nomad.hcl` file isn't a format Renovate recognizes natively — its
  `terraform`/Dockerfile managers don't scan Nomad job specs), and the
  `hashicorp/nomad` provider constraint in `versions.tf` (Renovate's
  `terraform` manager already scans any `*.tf` file for this, no extra
  config needed). Deliberately does **not** cover the pinned plugin/datapack
  jars in `minecraft/minecraft.nomad.hcl`'s `fetch-pinned-plugins` task
  (Chunky, AuraSkills, ViaVersion, ViaBackwards, BlueMap, AutoTreeChop,
  Terralith, Tectonic) — each of those pins a Modrinth CDN URL and a sha1
  together, and Renovate's regex-based custom managers can only swap in a
  new version/digest string in place, not regenerate an independent URL
  (the CDN path embeds a Modrinth-assigned version ID, not the plain version
  number) and recompute a hash from it. Those still need the same manual
  compatibility-with-pinned-game-version check and checksum verification
  done for each one so far. See `README.md`'s "Dependency updates (Renovate)"
  section.
- **Added version-number tracking for the 8 Modrinth-pinned plugins/datapacks**
  above, requested directly ("extract version numbers from the minecraft
  mods so that they could be tracked"). A `customDatasources.modrinth` entry
  queries each project's Modrinth releases filtered to `loaders=["paper"]`
  and `game_versions=["26.2"]` — the same filter used by hand for every past
  entry — and 8 regex managers (one per plugin/datapack) extract just the
  version number already embedded in each pinned filename for comparison.
  Deliberately set `dependencyDashboardApproval: true` rather than letting
  these open PRs outright: a regex manager can only swap in the matched
  version-number text, so an approved PR here would still carry the old,
  now-mismatched URL and sha1 — actively wrong if merged as-is. A new
  compatible version instead just appears as a pending item on the
  Dependency Dashboard issue, meant purely as a "check this one" nudge, not
  something to approve into a PR.

## minecraft

### 2026-10-04

- **Every download is now a pinned Nomad `artifact`, and the three fetch
  prestart tasks are gone** (`fetch-paper`, `fetch-geyser-floodgate`,
  `fetch-pinned-plugins`). All of them were hand-rolled curl + python3 +
  shasum scripts doing what go-getter already does: fetch a URL, verify a
  checksum, skip if already present. The job spec now has one
  `locals.artifacts` table (destination -> URL + checksum) and a single
  `dynamic "artifact"` block on the main `minecraft` task. The job file
  dropped from 463 to ~330 lines, and the hosts no longer need curl/python3
  to fetch anything.
- **Paper, Geyser and Floodgate are pinned too, not just the Modrinth
  plugins.** Paper is pinned to 26.2 build 129 (sha256, from Fill's
  content-addressed download URL), and Geyser 2.11.3 build 1248 / Floodgate
  2.2.5 build 141 are pinned to exact GeyserMC builds (sha256). Previously
  `fetch-paper` resolved the build from the `paper_version` Nomad Variable,
  and Geyser/Floodgate tracked latest on every restart, so a restart could
  quietly change the server. Every bump is now a reviewed diff instead.
  Floodgate's Spigot build isn't published on Modrinth (only Fabric/NeoForge),
  so both GeyserMC jars come from GeyserMC's own API.
  Trade-off: Bedrock clients auto-update, and a Bedrock protocol change
  locks Bedrock players out until Geyser is bumped, so Geyser bumps need
  prompt merging.
- **Artifacts live on the main task, not a prestart task, on purpose.**
  Nomad fetches a task's artifacts when that task starts, which is after
  `seed-data`'s restore from NFS, so fresh jars always overwrite restored
  copies. Every artifact sets `mode = "file"` and `archive = "false"`;
  otherwise go-getter would unpack the `.zip` datapacks into directories.
  `../alloc/minecraft-data/...` as a destination was confirmed accepted by
  `nomad job validate` (it stays inside the allocation directory).
- The `paper_version` key in the `nomad/jobs/minecraft` Nomad Variable is
  unused now and can be deleted once this is deployed.

### 2026-10-02

- **Moved to Nomadable's `game_servers` group, Java now comes from apt.**
  Constrained to `meta.inventory_groups` containing `game_servers`
  (euler/kepler), keeping the `amd64` constraint as a guard. The
  `fetch-jdk` prestart task is gone: the JRE is now
  `openjdk-25-jre-headless`, installed on that group by Nomadable through
  `additional_apt_packages`, and `start.sh` runs
  `/usr/lib/jvm/java-25-openjdk-amd64/bin/java`. Libraries a job needs are
  host provisioning, not something each job downloads for itself; Ubuntu
  26.04's OpenJDK build was the same 25.0.4.1 that Adoptium served, without
  adding Adoptium's apt repo to nomaduntu. Java now updates with the rest of
  the host's packages instead of to Adoptium's latest 25.x on each fresh
  node. The leftover `/opt/nomad/temurin-jdk` on each amd64 node is unused
  and safe to delete.

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

## valheim

### 2026-10-02

- **Constrained to Nomadable's `game_servers` group** (euler/kepler) via
  `meta.inventory_groups`, alongside the existing `amd64` constraint, so
  game servers stay off the other amd64 nodes. Already running on kepler,
  so this was an in-place update.

## jerry

No history recorded here yet — `jerry.nomad.hcl` is small and has had no
notable operational incidents so far. Future changes to it should still get
an entry here rather than inline comments, per the convention above.

## actions-runner

### 2026-10-04

- **UTF-8 locale (`LANG`/`LC_ALL` = `en_US.UTF-8`).** Nomad starts the
  runner with no locale, and CocoaPods then fails `pod install` with
  `Unicode Normalization not appropriate for ASCII-8BIT`. That broke the
  App's first `maestro-ios` run on these runners (Jellify-Music/App#1443).
  The App's `install-pods` action now sets the locale itself too, but other
  tools (Ruby, Python, `xcodebuild` output) expect one as well, and
  GitHub-hosted macOS runners always have one.

### 2026-10-03

- **Ruby 4.0 on `PATH` (`/opt/homebrew/opt/ruby@4.0/bin`).** For the App's
  iOS jobs (CocoaPods and fastlane through bundler) once they move to these
  runners. The App's shared `install-pods` action uses `ruby/setup-ruby` only
  on GitHub-hosted runners, pinned by its `ios/.ruby-version`; here the
  version comes from Nomadable's `ruby@4.0` formula, which tracks the same
  major.minor. The versioned opt path stays on 4.0 when Homebrew's plain
  `ruby` moves to a newer line.
- **Node 24 on `PATH` (`/opt/homebrew/opt/node@24/bin`).** The Android
  build needs `node` even though the App repo standardizes on bun: React
  Native's Gradle plugin bundles the JS and resolves autolinking with it.
  Workflows got it from `actions/setup-node` until now; the runners now
  have Homebrew's `node@24` instead, so `setup-node` was dropped from the
  Maestro workflow (Jellify-Music/App#1468). `node@24` is keg-only and the
  LTS line, so a `brew upgrade` won't move the build to a new major.

### 2026-10-02

- **Rewritten: runners are now fully managed by this job.** Previously the
  runner was downloaded and registered by hand on each host
  (`/opt/github-actions`, a persistent registration named after the host)
  and Nomad only started its `run.sh`. Now Nomadable pre-warms the runner
  at `/opt/actions-runner/current` (Renovate-tracked there), and `start.sh`
  copies it into the allocation and loops over single-use [JIT registrations](https://docs.github.com/en/rest/actions/self-hosted-runners#create-configuration-for-a-just-in-time-runner-for-a-repository),
  using a PAT from Consul KV (`jellify/actions-runner/GITHUB_PAT`). The
  `_work` folder is wiped before every job.
- **Why the runner isn't an `artifact`:** the first deploy of this rewrite
  downloaded it with one, and every allocation failed with `tar archive
  contains too many files: 4097 > 4096` (go-getter's decompression limit).
- **`service` with `count = 2` → `system` constrained to
  `meta.inventory_groups` containing `github_runners`.** Prompted by hopper
  silently having no runner: its `raw_exec` driver wasn't healthy when
  version 7 deployed (2026-10-01), the deployment hit its progress deadline,
  and a failed deployment stops Nomad placing the missing allocation even
  after the node recovered (`nomad job eval` placed nothing). A system job
  has no deployment to get stuck, and `count = 2` never had a
  `distinct_hosts` constraint anyway. The `arm64` constraint is gone (the
  group membership is the real constraint); `darwin` stays because the `env`
  paths are macOS-specific.
- **Runner state moved out of violet's home.** `HOME` is
  `/opt/github-actions/home` and the tool cache
  `/opt/github-actions/toolcache`, so Gradle caches, AVDs and bun's install
  cache (previously ~18 GB per host under `/Users/violet`) live in one tree.
  bun's cache is cleared once it passes 10 GB.
- **Toolchain is now Ansible-managed and version-pinned** (Nomadable
  `github_runners` group vars → Nomadintosh's `homebrew_packages`,
  `release_archives` and `android_sdk` roles): bun via
  `oven-sh/bun/bun@<version>`, Maestro under `/opt/maestro/current`,
  `openjdk@17` as `JAVA_HOME`. The App's self-hosted workflows stopped
  installing bun, Maestro and the JDK themselves.

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
