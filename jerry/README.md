# jerry

Discord bot for the Jellify Discord server. Job ID is `jellify` (not `jerry`
— see [`../main.tf`](../main.tf)'s `nomad_job.jellify` and the repo README's
note on resource naming), running
[`ghcr.io/jellify-music/discord-bot`](https://github.com/orgs/jellify-music/packages/container/package/discord-bot).

## What it does

An OpenAI-API-compatible chat bot, prompted (via
`OPENAI_ADDITIONAL_SYSTEM_PROMPTS`) to answer in-character as Jerry Garcia,
plus a hard system-level instruction refusing to discuss media distribution
(torrenting/P2P/Usenet) regardless of how it's asked — a guardrail against
the bot being used to casually endorse piracy in a server themed around a
self-hosted media library.

`OPENAI_MODEL` (`gemma4:e2b`) and `OPENAI_BASE_URL` point at a
self-hosted/local inference endpoint rather than OpenAI's own API — see the
Consul KV value for the actual address.

## Secrets

Populated in Consul KV before first deploy, same convention as every other
job here:

- `jellify/discord-bot/DISCORD_TOKEN`
- `jellify/discord-bot/DISCORD_CLIENT_ID`
- `jellify/discord-bot/DISCORD_GUILD_ID`
- `jellify/discord-bot/OPENAI_API_KEY`
- `jellify/discord-bot/OPENAI_BASE_URL`

The Discord bot application itself (token, invite) has to be created by hand
in the Discord Developer Portal first, same as `jellyfin-music-bot`.

## Notable choices

- **No `constraint` block** — unlike `valheim`/`minecraft`/
  `jellyfin-music-bot` (amd64-only) and `actions-runner` (arm64/darwin-only),
  this job can land on any jellify node. It's a lightweight Docker container
  with no architecture-specific dependency (no SteamCMD, no native JVM/JDK
  fetch), so there's nothing to pin it to one CPU arch.
- No operational history recorded in [`../CHANGELOG.md`](../CHANGELOG.md#jerry)
  yet — this job has been stable since it was brought under Terraform. Any
  future fix/decision should get a dated entry there, not an inline comment.
