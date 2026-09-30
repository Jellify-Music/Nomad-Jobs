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

## Consul KV keys

Populated in Consul KV before first deploy, same convention as every other
job here. **Note the prefix is `jellify/discord-bot/*`, not `jellify/jerry/*`**
— job ID and KV namespace don't match here, the one exception to this
repo's `jellify/<job>/<KEY_NAME>` convention (see `.agents/AGENTS.md`).

| Key | Used for |
|---|---|
| `jellify/discord-bot/DISCORD_TOKEN` | Discord bot application token |
| `jellify/discord-bot/DISCORD_CLIENT_ID` | Discord application client ID |
| `jellify/discord-bot/DISCORD_GUILD_ID` | Jellify Discord server guild ID |
| `jellify/discord-bot/OPENAI_API_KEY` | Self-hosted inference endpoint API key |
| `jellify/discord-bot/OPENAI_BASE_URL` | Self-hosted inference endpoint address |

The Discord bot application itself (token, invite) has to be created by hand
in the Discord Developer Portal first, same as `bobby`.

## Notable choices

- **No `constraint` block** — unlike `valheim`/`minecraft`/`bobby`
  (amd64-only) and `actions-runner` (arm64/darwin-only), this job can land
  on any jellify node. It's a lightweight Docker container with no
  architecture-specific dependency (no SteamCMD, no native JVM/JDK fetch),
  so there's nothing to pin it to one CPU arch.
- No operational history recorded in [`../CHANGELOG.md`](../CHANGELOG.md#jerry)
  yet — this job has been stable since it was brought under Terraform. Any
  future fix/decision should get a dated entry there, not an inline comment.

## Naming

Discord bots in this repo are named after Grateful Dead members, matching
each bot's role to the band member it's "voiced" as:

| Job | Named for | Role |
|---|---|---|
| `jerry` | Jerry Garcia | Chat bot — text-channel conversation |
| [`bobby`](../bobby) | Bobby Weir | Voice bot — streams the Jellyfin library into a voice channel |

Job ID and directory name should match this bot name going forward for any
new Discord bot added here (`jerry` is the one legacy exception — see its
"Consul KV keys" section above).
