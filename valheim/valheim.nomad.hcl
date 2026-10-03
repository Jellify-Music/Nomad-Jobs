job "valheim" {
  datacenters = ["jellify"]
  type        = "service"

  group "valheim" {
    count = 1

    # Valheim's dedicated server (and its SteamCMD installer) is amd64-only,
    # and the container driver's Rosetta translation on the arm64 jellify
    # nodes (galileo/hopper) can't run SteamCMD's 32-bit bootstrap binary -
    # see kepler/fibonacci/euler/dijkstra, the x86_64 jellify nodes added
    # specifically for jobs like this one. Of those, only Nomadable's
    # game_servers inventory group (published as node meta by nomaduntu's
    # nomad role) runs game servers.
    constraint {
      attribute = "${meta.inventory_groups}"
      operator  = "set_contains"
      value     = "game_servers"
    }

    constraint {
      attribute = "${attr.cpu.arch}"
      value     = "amd64"
    }

    restart {
      attempts = 5
      interval = "30m"
      delay    = "15s"
      mode     = "delay"
    }

    # The dedicated server binds PORT plus the two ports above it (game,
    # Steam query, and a spare) - not a Nomad convention, this is how
    # Iron Gate's own server binary behaves.
    network {
      port "game"  { static = 2456 }
      port "query" { static = 2457 }
      port "extra" { static = 2458 }
    }

    task "valheim" {
      # Nomad's built-in docker driver, not the macOS-only "container" driver
      # used elsewhere in this repo - kepler/fibonacci/euler/dijkstra are
      # Ubuntu/x86_64 nodes (see the constraint above), so this runs
      # mbround18/valheim natively, no Rosetta/emulation involved.
      driver = "docker"

      # Server password, same Consul KV convention as every other secret in
      # this repo (see minecraft's RCON_PASSWORD, dispatcharr's DB_PASSWORD).
      # Quoted because Nomad's env-file template parser treats a bare
      # unescaped `#` as a comment start, which truncates any password
      # containing one.
      template {
        data        = <<-EOT
        PASSWORD="{{ key "valheim/SERVER_PASSWORD" }}"
        EOT
        destination = "secrets/valheim.env"
        env         = true
      }

      # World/save/BepInEx-plugin data all live on the Jellify NFS share so
      # they survive restarts/reschedules, same as minecraft's
      # /Volumes/Jellify/minecraft on the macOS side - these nodes mount the
      # same export at /mnt/jellify instead (see nomaduntu's nfs_mounts
      # role). mbround18/valheim's Odin manager owns /home/steam/valheim
      # entirely (server binary, BepInEx install, fetched mods) - that whole
      # tree is persisted, not just the world save, so a redeploy doesn't
      # have to re-download BepInEx/mods from Thunderstore every time.
      config {
        image = "mbround18/valheim:latest"
        ports = ["game", "query", "extra"]

        volumes = [
          "/mnt/jellify/valheim/server:/home/steam/valheim",
          "/mnt/jellify/valheim/saves:/home/steam/.config/unity3d/IronGate/Valheim",
          "/mnt/jellify/valheim/backups:/home/steam/backups",
        ]
      }

      env {
        NAME = "Cosmonautical"
        # World save name - changing this after first boot starts a brand
        # new world, not a rename. Pick deliberately before first deploy.
        WORLD  = "Jellify"
        PORT   = "2456"
        # Not listed in the public Steam server browser - this is a
        # friends-only server, reachable by direct IP/Steam invite, and
        # staying off the public list avoids random scan/join attempts
        # against a modded, password-protected server.
        PUBLIC = "0"

        # BepInEx mods hook Steam networking specifically - crossplay
        # (Xbox/PlayStation via PlayFab) is mutually exclusive with them, no
        # workaround exists. Costs nothing here since every client is on
        # Steam (Linux/Windows/macOS) already.
        ENABLE_CROSSPLAY = "0"

        TYPE = "BepInEx"

        # The "Jellify" pack: toil-reduction only, no stat/balance/loot
        # changes. See README for what each mod does and why.
        #
        # AzuAutoStore and AzuCraftyBoxes (both Azumatt ServerSync-based)
        # were dropped 2026-09-29: ServerSync's own networking handshake
        # requires the client to have the mod installed at all, independent
        # of its "Lock Configuration" setting - a vanilla client never
        # answers that handshake and gets disconnected with an
        # "Incompatible version" error. Kept vanilla-client compatibility
        # over those two mods' QoL.
        #
        # potto007-OttoFuel added 2026-09-29: auto-feeds fuel/ore into
        # smelters/kilns/fires/torches from nearby chests and ground items.
        # No Jotunn/ServerSync dependency (bare BepInEx only) and no version
        # handshake - same vanilla-client-safe shape as the two mods above,
        # not the AzuAutoStore/AzuCraftyBoxes shape dropped above.
        #
        # MaxFoxGaming-Better_Beehives added 2026-09-29: queen bee/royal
        # jelly drop chance on honey harvest, plus a pollination growth
        # buff for crops near hives. Bare BepInEx dependency, no
        # ServerSync/version handshake - does NOT auto-collect honey
        # (no maintained mod does that without also requiring the ServerSync
        # hard-block, or being single-player-only - see README).
        MODS = <<-EOT
        ValheimModding-Jotunn-2.30.2
        Goldenrevolver-Quick_Stack_Store_Sort_Trash_Restock-1.4.15
        RandyKnapp-EquipmentAndQuickSlots-3.1.3
        potto007-OttoFuel-1.6.5
        MaxFoxGaming-Better_Beehives-1.3.0
        EOT
      }

      service {
        name = "valheim-game"
        port = "game"

        tags = [
          "traefik.enable=true",
          "traefik.udp.routers.valheim-game.entrypoints=valheim-game",
          "traefik.udp.services.valheim-game.loadbalancer.server.port=2456",
        ]
      }

      service {
        name = "valheim-query"
        port = "query"

        tags = [
          "traefik.enable=true",
          "traefik.udp.routers.valheim-query.entrypoints=valheim-query",
          "traefik.udp.services.valheim-query.loadbalancer.server.port=2457",
        ]
      }

      service {
        name = "valheim-extra"
        port = "extra"

        tags = [
          "traefik.enable=true",
          "traefik.udp.routers.valheim-extra.entrypoints=valheim-extra",
          "traefik.udp.services.valheim-extra.loadbalancer.server.port=2458",
        ]
      }

      resources {
        cpu    = 10000   # MHz
        memory = 16384   # MiB
      }

      # Give the server time to flush the world save on SIGTERM rather than
      # getting killed mid-write, same reasoning as minecraft's kill_timeout.
      kill_timeout = "30s"
    }
  }
}
