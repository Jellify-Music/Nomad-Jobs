# minecraft

Paper server, bridging Java and Bedrock clients. Paper, plugins and
datapacks are all pinned to an exact build + checksum in the
`locals.artifacts` table in [`minecraft.nomad.hcl`](minecraft.nomad.hcl),
and Nomad fetches and verifies them as `artifact`s when the main task
starts; this file is a quick-reference for *what's installed and why*. Full dated history
lives in [`../CHANGELOG.md`](../CHANGELOG.md#minecraft) — this file just
summarizes the current state.

## Where it runs

Constrained to Nomadable's `game_servers` inventory group (euler/kepler),
which provides the Java runtime: `openjdk-25-jre-headless` from Ubuntu's
archive, installed through `additional_apt_packages`. Paper 26.1+ needs Java
25+. The job runs `/usr/lib/jvm/java-25-openjdk-amd64/bin/java` directly, so
a JDK bump means changing that package and this path together.

## Server

| Component | Version | Source |
|---|---|---|
| [Paper](https://papermc.io/) | 26.2 build 129 (pinned) | Fill API, sha256 |

## Plugins

| Plugin | Version | Purpose |
|---|---|---|
| [Geyser](https://geysermc.org/) | 2.11.3 build 1248 (pinned) | Lets Bedrock clients connect to this Java server. |
| [Floodgate](https://geysermc.org/) | 2.2.5 build 141 (pinned) | Companion to Geyser — lets Bedrock players join as virtual accounts, no Java (Mojang) account required. |
| [ViaVersion](https://modrinth.com/plugin/viaversion) | 5.12.0 (pinned) | Lets newer Java clients connect to the server's pinned Paper protocol version. |
| [ViaBackwards](https://modrinth.com/plugin/viabackwards) | 5.12.1 (pinned) | Companion to ViaVersion — lets *older* Java clients connect the same way. |
| [Chunky](https://modrinth.com/plugin/chunky) | 1.5.3 | World pre-generation, so terrain doesn't generate live under players walking near the edge of explored land. |
| [AuraSkills](https://modrinth.com/plugin/auraskills) | 2.4.0 | RPG skills/leveling. |
| [BlueMap](https://modrinth.com/plugin/bluemap) | 5.28 (Paper build) | Live web map of the world, served at `minecraft.jellify.app`. |
| [AutoTreeChop](https://modrinth.com/plugin/autotreechop) | 1.7.5 | Fells an entire tree from one log break and auto-replants the correct sapling, so chopped forest actually grows back instead of leaving permanent stumps/clear-cuts. |

Everything is pinned: Geyser/Floodgate to an exact GeyserMC build (sha256),
the rest to an exact Modrinth file (sha1). Bump Geyser promptly when Bedrock
clients update — a Bedrock protocol change locks Bedrock players out until
it's bumped.

### Why these, and not alternatives

- **ViaVersion/ViaBackwards are pinned, not latest-tracking**, because
  Paper itself is pinned — a version pin only actually holds the
  server's protocol version steady if the bridge plugins are pinned
  alongside it.
- **AuraSkills over mcMMO**: mcMMO was considered and rejected — it isn't
  distributed via Modrinth or Hangar at all (own site + GitHub only), so
  there was no trusted API path to verify a build compatible with the
  server's pinned Paper version the way everything else here is verified.
- **BlueMap over a client-side minimap mod**: this server bridges multiple
  Java versions (ViaVersion/ViaBackwards) and Bedrock (Geyser/Floodgate) — a
  Fabric/Forge-only minimap mod would only ever work for a subset of
  players, where a server-side web map works for everyone regardless of
  client.
- **No self-hosted status page.** One was tried and removed — see the
  2026-09-30 entry in the changelog for the full incident (a Nomad
  `template` block mangling embedded CSS crash-looped the whole allocation).
  Not worth re-fixing and maintaining a hand-rolled Java SLP / Bedrock
  RakNet implementation for a cosmetic feature.
- **AutoTreeChop over alternatives considered** (TimberReplant, TreeFalls,
  RealisticGrowth, EzTree, TreeForce, Auto Crop Replant): most either hadn't
  published a release declaring support for the server's pinned game
  version (26.2) at time of writing, or (TimberReplant) share one Modrinth
  project page across an unrelated Fabric/Forge mod line and a separate,
  less mature Bukkit/Paper plugin line, which made picking the right file
  more error-prone than a dedicated single-purpose project. AutoTreeChop is
  Paper/Folia-only, has no hard dependencies (protection-plugin/CoreProtect/
  PlaceholderAPI support is optional), and its current release declares
  support up to 26.3 — the same forward-compatibility margin BlueMap's pin
  has over the pinned 26.2 build.

## World datapacks

| Datapack | Version | Purpose |
|---|---|---|
| [Terralith](https://modrinth.com/datapack/terralith) | 2.6.4 | Overworld terrain/biome generation overhaul. |
| [Tectonic](https://modrinth.com/datapack/tectonic) | 3.0.25 | Overworld terrain generation overhaul (mountains/geology), layered with Terralith. |

Both are dropped in as `.zip` files directly under `world/datapacks/`
(vanilla Minecraft loads zipped datapacks natively) — no plugin loader
involved. Each was confirmed compatible with the server's pinned Minecraft
version via Modrinth's API before being pinned here.

## Consul KV keys

| Key | Used for |
|---|---|
| `minecraft/RCON_PASSWORD` | RCON console auth |

## Updates

[`.github/workflows/minecraft-updates.yml`](../.github/workflows/minecraft-updates.yml)
runs daily (and on demand via *Run workflow*). It checks every
`locals.artifacts` entry against its upstream and opens one PR per update
(branch `minecraft-artifacts/<name>`). Each PR is complete: new URL, new
checksum (re-verified against a fresh download) and this README's version
cell. Merging doesn't deploy; run Semaphore when you're ready.

What counts as an update:

- **Paper:** a newer STABLE build of the *same* game version (26.2). Moving
  to a new game version stays a manual change, since every plugin and
  datapack has to be re-checked against it.
- **Geyser/Floodgate:** the newest GeyserMC build. Merge these promptly —
  they're what let Bedrock players back in after a client update.
- **Modrinth plugins/datapacks:** the newest *release* (no betas/snapshots)
  that declares support for the pinned game version, from the same loader
  family and file naming pattern as the current pin.

If an open PR's update gets superseded, the next run force-pushes the newer
one to the same branch. The logic lives in
[`.github/scripts/minecraft_artifacts.py`](../.github/scripts/minecraft_artifacts.py),
with offline tests in `tests/test_minecraft_artifacts.py`.

PRs opened with the default `GITHUB_TOKEN` don't trigger the Validate
workflow. Setting a `MINECRAFT_UPDATES_TOKEN` repo secret (a fine-grained
PAT with contents + pull requests read/write on this repo) makes CI run on
them. Without it, the repo setting *Allow GitHub Actions to create and
approve pull requests* has to be on.

## Adding a plugin/datapack

1. Confirm compatibility with the server's pinned Paper version (Modrinth's
   API, same as everything above) — don't rely on a mod page's "latest"
   label alone.
2. Use a source the update workflow understands (Modrinth, GeyserMC or
   Fill). Anything else fails `tests/test_minecraft_artifacts.py` until the
   script gets a resolver for it.
3. Add an entry (destination path, URL, `sha1:`/`sha256:` checksum) to the
   `locals.artifacts` table in [`minecraft.nomad.hcl`](minecraft.nomad.hcl).
4. Add a row here — linked as `[Name](...)`, where `Name` matches the
   entry's filename up to the first `-`/`_`/`.` — and record the decision
   (especially any alternative considered and rejected) in
   `../CHANGELOG.md` under a new dated entry. Upgrades after that arrive as
   PRs on their own.
