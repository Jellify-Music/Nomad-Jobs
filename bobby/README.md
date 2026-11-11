# bobby

Discord bot that broadcasts the Jellify Jellyfin library into a Discord
voice channel, via [`felix920506/jellychord`](https://github.com/felix920506/jellychord)
(`ghcr.io/felix920506/jellychord:latest`). Runs specifically for
`The Music Hall` (channel ID `1437161572396044288`) on the Jellify Discord
server (guild ID `1351285328400351344`).

Named after Bobby Weir, same convention as [`jerry`](../jerry) (Jerry
Garcia) — see [`jerry/README.md`](../jerry/README.md#naming) for the full
naming table. Requires its own, distinct Discord bot application/token;
`jerry`'s token can't be reused (see `bobby`'s `CHANGELOG.md` entry for
why).

## Not zero-touch after a deploy

The bot has no setting for auto-joining a fixed voice channel — it joins
whichever voice channel the command issuer is in when they queue something.
So after every deploy/restart, someone has to sit in The Music Hall and run
`/jellychord play <term>` (or `/jellychord radio song` for nonstop random
tracks) to actually start playback. All commands live under the
`/jellychord` group (upstream's default `JELLYCHORD_COMMAND_GROUP`); see
upstream's README for the full list.

## Consul KV keys

Populated in Consul KV before first deploy, same pattern as `jerry`'s
Discord token:

| Key | Used for |
|---|---|
| `jellify/bobby/DISCORD_CLIENT_TOKEN` | Discord bot application token (`JELLYCHORD_DC_TOKEN`) |
| `jellify/bobby/JELLYFIN_API_KEY` | Jellyfin API key (`JELLYCHORD_JF_APIKEY`) |

The API key is created by hand in the Jellyfin dashboard (Administration →
API Keys). The Discord bot application itself (token, invite with
voice-connect/speak permissions) has to be created by hand in the Discord
Developer Portal first.

## Notable choices

- **`amd64`-only constraint**, same as `valheim`/`minecraft` — runs via
  Nomad's built-in Docker driver on the Ubuntu/x86_64 jellify nodes, not the
  macOS-only "container" driver galileo/hopper use. Chosen by request: it
  doesn't need galileo/hopper's arm64 capacity, unlike `jerry`.
- **`JELLYCHORD_JF_SERVER` is the public `https://jellyfin.jellify.app`
  Traefik hostname**, not a LAN address — Jellyfin itself runs on
  `cassiopeia` in the separate `cosmonautical` datacenter (see the legacy
  `nomad-jobs` repo's `jellyfin.nomad.hcl`), not in `jellify` alongside this
  bot.
- **Jellyfin does the transcoding** — the bot asks Jellyfin for `opus`
  audio, so Jellyfin's audio transcoding has to work for that codec.
