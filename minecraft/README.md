# minecraft

Paper server, bridging Java and Bedrock clients. Plugins and datapacks are
fetched and checksum-verified at task start (see `fetch-geyser-floodgate` and
`fetch-pinned-plugins` in [`minecraft.nomad.hcl`](minecraft.nomad.hcl)); this
file is a quick-reference for *what's installed and why*. Full dated history
lives in [`../CHANGELOG.md`](../CHANGELOG.md#minecraft) — this file just
summarizes the current state.

## Plugins

| Plugin | Version | Purpose |
|---|---|---|
| [Geyser](https://geysermc.org/) | latest | Lets Bedrock clients connect to this Java server. |
| [Floodgate](https://geysermc.org/) | latest | Companion to Geyser — lets Bedrock players join as virtual accounts, no Java (Mojang) account required. |
| [ViaVersion](https://modrinth.com/plugin/viaversion) | 5.12.0 (pinned) | Lets newer Java clients connect to the server's pinned Paper protocol version. |
| [ViaBackwards](https://modrinth.com/plugin/viabackwards) | 5.12.0 (pinned) | Companion to ViaVersion — lets *older* Java clients connect the same way. |
| [Chunky](https://modrinth.com/plugin/chunky) | 1.5.3 | World pre-generation, so terrain doesn't generate live under players walking near the edge of explored land. |
| [AuraSkills](https://modrinth.com/plugin/auraskills) | 2.4.0 | RPG skills/leveling. |
| [BlueMap](https://modrinth.com/plugin/bluemap) | 5.28 (Paper build) | Live web map of the world, served at `minecraft.jellify.app`. |

Geyser/Floodgate track latest on every restart; everything else is pinned
(exact version + sha1, fetched in `fetch-pinned-plugins`).

### Why these, and not alternatives

- **ViaVersion/ViaBackwards are pinned, not latest-tracking**, because
  `paper_version` itself is pinned — a version pin only actually holds the
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

## World datapacks

| Datapack | Version | Purpose |
|---|---|---|
| [Terralith](https://modrinth.com/datapack/terralith) | 2.6.4 | Overworld terrain/biome generation overhaul. |
| [Tectonic](https://modrinth.com/datapack/tectonic) | 3.0.25 | Overworld terrain generation overhaul (mountains/geology), layered with Terralith. |

Both are dropped in as `.zip` files directly under `world/datapacks/`
(vanilla Minecraft loads zipped datapacks natively) — no plugin loader
involved. Each was confirmed compatible with the server's pinned Minecraft
version via Modrinth's API before being pinned here.

## Adding or upgrading a plugin/datapack

1. Confirm compatibility with the server's pinned `paper_version` (Modrinth
   or Hangar's API, same as everything above) — don't rely on a mod page's
   "latest" label alone.
2. Prefer a source with a checkable version/build/checksum API (Modrinth,
   Hangar, GeyserMC's own API) over a bare downloads page — that's what
   makes `fetch_pinned`'s sha1 verification possible.
3. Add the fetch + checksum to `fetch-pinned-plugins` (or a new prestart
   task, if it needs its own dependencies) in
   [`minecraft.nomad.hcl`](minecraft.nomad.hcl).
4. Add a row here, and record the decision (especially any alternative
   considered and rejected) in `../CHANGELOG.md` under a new dated entry.
