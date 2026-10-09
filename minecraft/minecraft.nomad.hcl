# See ../CHANGELOG.md for the "why" behind anything here - this file stays
# lean, history/rationale lives there instead.

locals {
  user_agent = "cosmonautical-nomad-jobs/1.0 (violet@cosmonautical.cloud)"

  # Everything the server downloads, keyed by destination path relative to
  # the alloc's minecraft-data dir. Every entry is an exact build + checksum -
  # bumps arrive as PRs, never as a silent change on restart.
  artifacts = {
    "paper.jar" = {
      url      = "https://fill-data.papermc.io/v1/objects/bf1dcf627364f8a631ab15250d240eb5a8e89faaac523b391e1c61367fce9ff1/paper-26.2-133.jar"
      checksum = "sha256:bf1dcf627364f8a631ab15250d240eb5a8e89faaac523b391e1c61367fce9ff1"
    }
    "plugins/Geyser-Spigot.jar" = {
      url      = "https://download.geysermc.org/v2/projects/geyser/versions/2.11.3/builds/1248/downloads/spigot"
      checksum = "sha256:20f14813931758aa2e951aae3b5d333f7212fa9b059afffc6a782a2eb3bb2a81"
    }
    "plugins/floodgate-spigot.jar" = {
      url      = "https://download.geysermc.org/v2/projects/floodgate/versions/2.2.5/builds/141/downloads/spigot"
      checksum = "sha256:21570aff9ce17d6983928e8552777760e1ede5050026b04c686b0ae112e6fd7e"
    }
    "plugins/ViaVersion.jar" = {
      url      = "https://cdn.modrinth.com/data/P1OZGk5p/versions/FaishMnD/ViaVersion-5.12.0.jar"
      checksum = "sha1:7486c37c91b3cc892d37ee9a05470bf6ec49a59f"
    }
    "plugins/ViaBackwards.jar" = {
      url      = "https://cdn.modrinth.com/data/NpvuJQoq/versions/SxGhdsPK/ViaBackwards-5.12.0.jar"
      checksum = "sha1:3603c85784c41387c56ec76c016c21e0a1ae303a"
    }
    "plugins/Chunky.jar" = {
      url      = "https://cdn.modrinth.com/data/fALzjamp/versions/MdY6JATr/Chunky-Bukkit-1.5.3.jar"
      checksum = "sha1:7ff47ee3afec89a1725e6eef393f373c549eff3b"
    }
    "plugins/AuraSkills.jar" = {
      url      = "https://cdn.modrinth.com/data/uDdZAVls/versions/9rSJ3THD/AuraSkills-2.4.0.jar"
      checksum = "sha1:f8c6c4a73bf853755108578625cf5ca212957b53"
    }
    "plugins/BlueMap.jar" = {
      url      = "https://cdn.modrinth.com/data/swbUV1cr/versions/pILlMIlN/bluemap-5.28-paper.jar"
      checksum = "sha1:6e9d1bb29a43aa24108b5cb4b61de6efec1f521a"
    }
    "plugins/AutoTreeChop.jar" = {
      url      = "https://cdn.modrinth.com/data/pwCm0TtE/versions/o9SdPqFP/AutoTreeChop-1.7.5.jar"
      checksum = "sha1:5b2e013994950afadd3f22b0242dc0500da79c07"
    }
    "world/datapacks/Terralith.zip" = {
      url      = "https://cdn.modrinth.com/data/8oi3bsk5/versions/CzijfXJQ/Terralith_26.2_v2.6.4.zip"
      checksum = "sha1:96ccd25be9ba5240ebe8150cc29240aca781f0e1"
    }
    "world/datapacks/Tectonic.zip" = {
      url      = "https://cdn.modrinth.com/data/lWDHr9jE/versions/CmzMQNDL/tectonic-datapack-3.0.25.zip"
      checksum = "sha1:790390ed8f5032bb0e9fc3bd7aa7017d838cf273"
    }
  }
}

job "minecraft" {
  datacenters = ["jellify"]
  type        = "service"

  group "minecraft" {
    count = 1

    # Nomadable's game_servers inventory group (published as node meta by
    # nomaduntu's nomad role), which also installs the JRE the main task runs
    # (openjdk-25-jre-headless, via additional_apt_packages). amd64 stays as
    # a guard against a non-x86 host joining the group.
    constraint {
      attribute = "${meta.inventory_groups}"
      operator  = "set_contains"
      value     = "game_servers"
    }

    constraint {
      attribute = "${attr.cpu.arch}"
      value     = "amd64"
    }

    ephemeral_disk {
      size    = 5120
      migrate = true
      sticky  = true
    }

    restart {
      attempts = 5
      interval = "30m"
      delay    = "15s"
      mode     = "delay"
    }

    network {
      port "java"    { static = 25565 }
      port "bedrock" { static = 19132 }
      port "bluemap" { static = 8100 }
    }

    task "seed-data" {
      driver = "raw_exec"

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      template {
        data        = <<-EOT
        RCON_PASSWORD="{{ key "minecraft/RCON_PASSWORD" }}"
        EOT
        destination = "secrets/rcon.env"
        env         = true
      }

      config {
        command = "/bin/sh"
        args = [
          "-c",
          <<-EOT
          set -eu
          attempts=0
          until /usr/bin/mount | /usr/bin/grep -Fq " on /mnt/jellify type nfs"; do
            attempts=$((attempts + 1))
            if [ "$attempts" -ge 30 ]; then
              echo "Jellify NFS mount did not appear" >&2
              exit 1
            fi
            /bin/sleep 2
          done

          durable_dir="/mnt/jellify/minecraft"
          local_dir="$NOMAD_ALLOC_DIR/minecraft-data"
          mkdir -p "$durable_dir/config" "$durable_dir/plugins" "$durable_dir/world/datapacks"

          mkdir -p "$local_dir"
          if [ ! -d "$local_dir/world" ]; then
            echo "no local world found, restoring from $durable_dir"
            cp -a "$durable_dir/." "$local_dir/"
          fi

          mkdir -p "$local_dir/config" "$local_dir/plugins" "$local_dir/world/datapacks"

          if [ ! -s "$local_dir/server.properties" ]; then
            cat > "$local_dir/server.properties" <<-'PROPS'
          motd=A Cosmonautical Paper Server
          online-mode=true
          white-list=true
          level-name=world
          PROPS
          fi

          set_prop() {
            key="$1"
            value="$2"
            grep -v "^$key=" "$local_dir/server.properties" > "$local_dir/server.properties.tmp" 2>/dev/null || true
            echo "$key=$value" >> "$local_dir/server.properties.tmp"
            mv "$local_dir/server.properties.tmp" "$local_dir/server.properties"
          }
          set_prop view-distance 24
          set_prop simulation-distance 10
          set_prop spawn-protection 0
          set_prop enforce-secure-profile false
          set_prop enable-rcon true
          set_prop rcon.port 25575
          set_prop "rcon.password" "$RCON_PASSWORD"
          set_prop broadcast-rcon-to-ops false
          EOT
        ]
      }

      resources {
        cpu    = 2
        memory = 128
      }
    }

    task "minecraft" {
      driver = "raw_exec"

      env {
        PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
      }

      # Fetched by the Nomad client when this task starts, i.e. after
      # seed-data's restore from NFS, so fresh jars overwrite restored ones.
      dynamic "artifact" {
        for_each = local.artifacts
        content {
          source      = artifact.value.url
          destination = "../alloc/minecraft-data/${artifact.key}"
          mode        = "file"
          options {
            checksum = artifact.value.checksum
            archive  = "false"
          }
          headers {
            User-Agent = local.user_agent
          }
        }
      }

      template {
        data        = <<-EOT
        #!/bin/sh
        set -eu

        local_dir="$NOMAD_ALLOC_DIR/minecraft-data"
        cd "$local_dir"

        echo "eula=true" > eula.txt

        /usr/lib/jvm/java-25-openjdk-amd64/bin/java \
          -Xms8G -Xmx14G -XX:+UseG1GC \
          -jar "$local_dir/paper.jar" \
          --nogui \
          --world-dir "$local_dir" \
          --config "$local_dir/server.properties" \
          --bukkit-settings "$local_dir/bukkit.yml" \
          --spigot-settings "$local_dir/spigot.yml" \
          --commands-settings "$local_dir/commands.yml" \
          --paper-settings-directory "$local_dir/config" \
          --plugins "$local_dir/plugins" &
        mc_pid=$!

        sync_loop() {
          while true; do
            sleep 120
            /usr/bin/rsync -a "$local_dir/" /mnt/jellify/minecraft/ 2>/dev/null || true
          done
        }
        sync_loop &
        sync_pid=$!

        cleanup() {
          rc=$?
          kill "$sync_pid" 2>/dev/null || true
          kill "$mc_pid" 2>/dev/null || true
          wait "$mc_pid" 2>/dev/null || true
          /usr/bin/rsync -a "$local_dir/" /mnt/jellify/minecraft/ 2>/dev/null || true
          exit "$rc"
        }
        trap cleanup EXIT INT TERM

        wait "$mc_pid"
        EOT
        destination = "local/start.sh"
        perms       = "755"
      }

      config {
        command = "${NOMAD_TASK_DIR}/start.sh"
      }

      service {
        name = "minecraft-java"
        port = "java"

        tags = [
          "traefik.enable=true",
          "traefik.tcp.routers.minecraft.rule=HostSNI(`*`)",
          "traefik.tcp.routers.minecraft.entrypoints=minecraft",
          "traefik.tcp.services.minecraft.loadbalancer.server.port=25565",
        ]

        check {
          name     = "tcp"
          type     = "tcp"
          port     = "java"
          interval = "30s"
          timeout  = "5s"
        }
      }

      service {
        name = "minecraft-bedrock"
        port = "bedrock"

        tags = [
          "traefik.enable=true",
          "traefik.udp.routers.bedrock.entrypoints=bedrock",
          "traefik.udp.services.bedrock.loadbalancer.server.port=19132",
        ]
      }

      service {
        name = "minecraft-bluemap"
        port = "bluemap"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.bluemap.rule=Host(`minecraft.jellify.app`)",
          "traefik.http.routers.bluemap.entrypoints=websecure",
          "traefik.http.routers.bluemap.tls.certresolver=cf-dns",
          "traefik.http.services.bluemap.loadbalancer.server.port=8100",
        ]

        check {
          name     = "tcp"
          type     = "tcp"
          port     = "bluemap"
          interval = "30s"
          timeout  = "5s"
        }
      }

      resources {
        cpu    = 10000
        memory = 16384
      }

      kill_timeout = "30s"
    }
  }
}
