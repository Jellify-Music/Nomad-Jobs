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
        # in the legacy repo).
        JELLYCHORD_JF_SERVER = "https://jellyfin.jellify.app"
      }

      template {
        destination = "secrets/.env"
        env         = true
        data        = <<EOF
JELLYCHORD_DC_TOKEN="{{ key "jellify/bobby/DISCORD_CLIENT_TOKEN" }}"
JELLYCHORD_JF_APIKEY="{{ key "jellify/bobby/JELLYFIN_API_KEY" }}"
EOF
      }

      config {
        image = "ghcr.io/felix920506/jellychord:latest@sha256:72c88b03f27c6468b950cb89dda55904b798b1d3fc03c22b7f319b089b296b6d"
      }

      resources {
        cpu    = 200   # MHz
        memory = 512   # MiB
      }
    }
  }
}
