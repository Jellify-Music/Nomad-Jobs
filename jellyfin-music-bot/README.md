# jellyfin-music-bot

Discord bot that broadcasts the Jellify Jellyfin library into a Discord
voice channel, via
[`manuel-rw/jellyfin-discord-music-bot`](https://github.com/manuel-rw/jellyfin-discord-music-bot)
(`ghcr.io/manuel-rw/jellyfin-discord-music-bot:latest`). Runs specifically
for `The Music Hall` (channel ID `1437161572396044288`) on the Jellify
Discord server (guild ID `1351285328400351344`).

## Not zero-touch after a deploy

This bot has no env var for auto-joining a fixed voice channel or guild —
it's single-guild only, and joins whichever voice channel the command issuer
is in when they run `/summon`. So after every deploy/restart, someone has to
sit in The Music Hall and run `/summon` (then `/play`, `/playliked`,
`/random`, etc.) to actually start playback.

`LOCKED_CHANNEL_IDS` would restrict which *text* channel(s) accept bot
commands (not which voice channel it joins) — left unset here.

## Consul KV keys

Populated in Consul KV before first deploy, same pattern as `jerry`'s
Discord token:

| Key | Used for |
|---|---|
| `jellify/jellyfin-music-bot/DISCORD_CLIENT_TOKEN` | Discord bot application token |
| `jellify/jellyfin-music-bot/JELLYFIN_AUTHENTICATION_USERNAME` | Dedicated Jellyfin bot account username |
| `jellify/jellyfin-music-bot/JELLYFIN_AUTHENTICATION_PASSWORD` | Dedicated Jellyfin bot account password |

The Jellyfin credentials must belong to a **dedicated bot account**, not the
admin account (per upstream's own advice). The Discord bot application
itself (token, invite with voice-connect/speak permissions) has to be
created by hand in the Discord Developer Portal first.

## Notable choices

- **`amd64`-only constraint**, same as `valheim`/`minecraft` — runs via
  Nomad's built-in Docker driver on the Ubuntu/x86_64 jellify nodes, not the
  macOS-only "container" driver galileo/hopper use. Chosen by request: it
  doesn't need galileo/hopper's arm64 capacity, unlike `jerry`.
- **`JELLYFIN_SERVER_ADDRESS` is the public `https://jellyfin.jellify.app`
  Traefik hostname**, not a LAN address — Jellyfin itself runs on
  `cassiopeia` in the separate `cosmonautical` datacenter (see the legacy
  `nomad-jobs` repo's `jellyfin.nomad.hcl`), not in `jellify` alongside this
  bot. No trailing slash/path — the bot rejects `/web` or
  `/web/index.html` suffixes.
