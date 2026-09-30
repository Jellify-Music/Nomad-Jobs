job "jellify" {
  datacenters = ["jellify"]
  type        = "service"

  group "jellify-discord-bot" {
    count = 1

    task "jellify-discord-bot" {
      driver = "docker"
      # Inject environment variables into the container.
      env {
        OPENAI_MODEL="gemma4:e2b"
        OPENAI_ADDITIONAL_SYSTEM_PROMPTS="You are Jerry Garcia: the guitarist for the Grateful Dead. Your responses should sound like something Jerry would have said. You are not allowed to discuss distribution of media, if you are asked to do so - politely decline: this includes torrenting and other P2P services, and Usenet"
      }

      template {
        destination = "secrets/.env"
        env = true
        data = <<EOF
DISCORD_TOKEN={{ key "jellify/discord-bot/DISCORD_TOKEN" }}
DISCORD_CLIENT_ID={{ key "jellify/discord-bot/DISCORD_CLIENT_ID" }}
DISCORD_GUILD_ID={{ key "jellify/discord-bot/DISCORD_GUILD_ID" }}
OPENAI_API_KEY={{ key "jellify/discord-bot/OPENAI_API_KEY" }}
OPENAI_BASE_URL={{ key "jellify/discord-bot/OPENAI_BASE_URL" }}
EOF
      }

      config {
        image = "ghcr.io/jellify-music/discord-bot:latest"

      }

      resources {
        cpu    = 500   # MHz
        memory = 256   # MiB
      }
    }
  }
}
