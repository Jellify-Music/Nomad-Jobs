job "bobby" {
  datacenters = ["jellify"]
  type        = "service"

  group "bobby" {
    count = 1

    # amd64-only, same as valheim/minecraft - runs via Nomad's built-in
    # docker driver on the Ubuntu/x86_64 jellify nodes (kepler/fibonacci/
    # euler/dijkstra), not the macOS-only "container" driver galileo/hopper
    # use.
    constraint {
      attribute = "${attr.cpu.arch}"
      value     = "amd64"
    }

    task "bobby" {
      driver = "docker"

      env {
        # Public Traefik hostname, not a LAN address - this bot runs in the
        # jellify Nomad datacenter, but Jellyfin itself runs on cassiopeia in
        # the separate cosmonautical datacenter (see nomad-jobs/jellyfin.nomad.hcl
        # in the legacy repo). No trailing slash/path - the bot rejects
        # /web or /web/index.html suffixes.
        JELLYFIN_SERVER_ADDRESS = "https://jellyfin.jellify.app"
      }

      template {
        destination = "secrets/.env"
        env         = true
        data        = <<EOF
DISCORD_CLIENT_TOKEN="{{ key "jellify/bobby/DISCORD_CLIENT_TOKEN" }}"
JELLYFIN_AUTHENTICATION_USERNAME="{{ key "jellify/bobby/JELLYFIN_AUTHENTICATION_USERNAME" }}"
JELLYFIN_AUTHENTICATION_PASSWORD="{{ key "jellify/bobby/JELLYFIN_AUTHENTICATION_PASSWORD" }}"
EOF
      }

      config {
        image = "ghcr.io/manuel-rw/jellyfin-discord-music-bot:latest"
      }

      resources {
        cpu    = 200   # MHz
        memory = 512   # MiB
      }
    }
  }
}
