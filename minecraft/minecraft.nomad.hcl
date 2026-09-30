# See ../CHANGELOG.md for the "why" behind anything here - this file stays
# lean, history/rationale lives there instead.

job "minecraft" {
  datacenters = ["jellify"]
  type        = "service"

  group "minecraft" {
    count = 1

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

    task "fetch-paper" {
      driver = "raw_exec"

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      template {
        data        = <<-EOT
        {{ with nomadVar "nomad/jobs/minecraft" }}PAPER_VERSION={{ .paper_version }}{{ end }}
        EOT
        destination = "secrets/paper-version.env"
        env         = true
      }

      template {
        data        = <<-EOT
        #!/bin/sh
        set -eu

        version="$${PAPER_VERSION:-latest}"
        ua="cosmonautical-nomad-jobs/1.0 (violet@cosmonautical.cloud)"
        api="https://fill.papermc.io/v3"
        data_dir="$NOMAD_ALLOC_DIR/minecraft-data"

        if [ "$version" = "latest" ]; then
          candidates=$(curl -sf -H "User-Agent: $ua" "$api/projects/paper" | python3 -c 'import json,sys
        d=json.load(sys.stdin, strict=False)
        for lst in d["versions"].values():
            for v in lst:
                print(v)')
        else
          candidates="$version"
        fi

        build=""
        resolved_version=""
        for v in $candidates; do
          b=$(curl -sf -H "User-Agent: $ua" "$api/projects/paper/versions/$v/builds/latest") || continue
          channel=$(echo "$b" | python3 -c 'import json,sys
        try:
            print(json.load(sys.stdin, strict=False)["channel"])
        except Exception:
            print("")')
          if [ "$version" != "latest" ] || [ "$channel" = "STABLE" ]; then
            build="$b"
            resolved_version="$v"
            break
          fi
        done

        if [ -z "$build" ]; then
          echo "no suitable Paper build found for paper_version=$version" >&2
          exit 1
        fi

        echo "Resolved Paper version: $resolved_version"

        url=$(echo "$build" | python3 -c 'import json, sys; print(json.load(sys.stdin, strict=False)["downloads"]["server:default"]["url"])')
        sha256=$(echo "$build" | python3 -c 'import json, sys; print(json.load(sys.stdin, strict=False)["downloads"]["server:default"]["checksums"]["sha256"])')

        tmp="$data_dir/paper.jar.tmp"
        curl -sfL -H "User-Agent: $ua" -o "$tmp" "$url"
        echo "$sha256  $tmp" | shasum -a 256 -c -
        mv "$tmp" "$data_dir/paper.jar"
        echo "$resolved_version" > "$data_dir/.paper-version"
        EOT
        destination = "local/fetch-paper.sh"
        perms       = "755"
      }

      config {
        command = "${NOMAD_TASK_DIR}/fetch-paper.sh"
      }

      resources {
        cpu    = 2
        memory = 256
      }
    }

    task "fetch-geyser-floodgate" {
      driver = "raw_exec"

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      template {
        data        = <<-EOT
        #!/bin/sh
        set -eu

        ua="cosmonautical-nomad-jobs/1.0 (violet@cosmonautical.cloud)"
        plugins_dir="$NOMAD_ALLOC_DIR/minecraft-data/plugins"
        mkdir -p "$plugins_dir"

        fetch_latest() {
          project="$1"
          out_name="$2"

          versions=$(curl -sfL -H "User-Agent: $ua" "https://download.geysermc.org/v2/projects/$project")
          version=$(echo "$versions" | python3 -c 'import json, sys; print(json.load(sys.stdin, strict=False)["versions"][-1])')

          build=$(curl -sfL -H "User-Agent: $ua" "https://download.geysermc.org/v2/projects/$project/versions/$version/builds/latest")
          build_id=$(echo "$build" | python3 -c 'import json, sys; print(json.load(sys.stdin, strict=False)["build"])')
          sha256=$(echo "$build" | python3 -c 'import json, sys; print(json.load(sys.stdin, strict=False)["downloads"]["spigot"]["sha256"])')

          out="$plugins_dir/$out_name"
          curl -sfL -H "User-Agent: $ua" -o "$out" \
            "https://download.geysermc.org/v2/projects/$project/versions/$version/builds/$build_id/downloads/spigot"
          echo "$sha256  $out" | shasum -a 256 -c -
          echo "$project $version build $build_id -> $out_name"
        }

        fetch_latest geyser Geyser-Spigot.jar
        fetch_latest floodgate floodgate-spigot.jar
        EOT
        destination = "local/fetch-geyser-floodgate.sh"
        perms       = "755"
      }

      config {
        command = "${NOMAD_TASK_DIR}/fetch-geyser-floodgate.sh"
      }

      resources {
        cpu    = 2
        memory = 256
      }
    }

    task "fetch-pinned-plugins" {
      driver = "raw_exec"

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      template {
        data        = <<-EOT
        #!/bin/sh
        set -eu

        ua="cosmonautical-nomad-jobs/1.0 (violet@cosmonautical.cloud)"
        data_dir="$NOMAD_ALLOC_DIR/minecraft-data"

        fetch_pinned() {
          url="$1"
          sha1="$2"
          out="$3"

          if [ -f "$out" ] && echo "$sha1  $out" | shasum -a 1 -c - >/dev/null 2>&1; then
            echo "$out already present and verified"
            return 0
          fi

          tmp="$out.tmp"
          curl -sfL -H "User-Agent: $ua" -o "$tmp" "$url"
          echo "$sha1  $tmp" | shasum -a 1 -c -
          mv "$tmp" "$out"
          echo "fetched $out"
        }

        fetch_pinned \
          "https://cdn.modrinth.com/data/8oi3bsk5/versions/CzijfXJQ/Terralith_26.2_v2.6.4.zip" \
          "96ccd25be9ba5240ebe8150cc29240aca781f0e1" \
          "$data_dir/world/datapacks/Terralith.zip"

        fetch_pinned \
          "https://cdn.modrinth.com/data/lWDHr9jE/versions/CmzMQNDL/tectonic-datapack-3.0.25.zip" \
          "790390ed8f5032bb0e9fc3bd7aa7017d838cf273" \
          "$data_dir/world/datapacks/Tectonic.zip"

        fetch_pinned \
          "https://cdn.modrinth.com/data/fALzjamp/versions/MdY6JATr/Chunky-Bukkit-1.5.3.jar" \
          "7ff47ee3afec89a1725e6eef393f373c549eff3b" \
          "$data_dir/plugins/Chunky.jar"

        fetch_pinned \
          "https://cdn.modrinth.com/data/uDdZAVls/versions/9rSJ3THD/AuraSkills-2.4.0.jar" \
          "f8c6c4a73bf853755108578625cf5ca212957b53" \
          "$data_dir/plugins/AuraSkills.jar"

        fetch_pinned \
          "https://cdn.modrinth.com/data/P1OZGk5p/versions/FaishMnD/ViaVersion-5.12.0.jar" \
          "7486c37c91b3cc892d37ee9a05470bf6ec49a59f" \
          "$data_dir/plugins/ViaVersion.jar"

        fetch_pinned \
          "https://cdn.modrinth.com/data/NpvuJQoq/versions/SxGhdsPK/ViaBackwards-5.12.0.jar" \
          "3603c85784c41387c56ec76c016c21e0a1ae303a" \
          "$data_dir/plugins/ViaBackwards.jar"

        fetch_pinned \
          "https://cdn.modrinth.com/data/swbUV1cr/versions/pILlMIlN/bluemap-5.28-paper.jar" \
          "6e9d1bb29a43aa24108b5cb4b61de6efec1f521a" \
          "$data_dir/plugins/BlueMap.jar"

        fetch_pinned \
          "https://cdn.modrinth.com/data/pwCm0TtE/versions/o9SdPqFP/AutoTreeChop-1.7.5.jar" \
          "5b2e013994950afadd3f22b0242dc0500da79c07" \
          "$data_dir/plugins/AutoTreeChop.jar"
        EOT
        destination = "local/fetch-pinned-plugins.sh"
        perms       = "755"
      }

      config {
        command = "${NOMAD_TASK_DIR}/fetch-pinned-plugins.sh"
      }

      resources {
        cpu    = 2
        memory = 256
      }
    }

    task "fetch-jdk" {
      driver = "raw_exec"

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      template {
        data        = <<-EOT
        #!/bin/sh
        set -eu

        jdk_dir="/opt/nomad/temurin-jdk"
        if [ -x "$jdk_dir/bin/java" ]; then
          echo "JDK already present at $jdk_dir"
          exit 0
        fi

        ua="cosmonautical-nomad-jobs/1.0 (violet@cosmonautical.cloud)"
        tmp="/opt/nomad/temurin-jdk.tar.gz"

        curl -sfL -H "User-Agent: $ua" -o "$tmp" \
          "https://api.adoptium.net/v3/binary/latest/25/ga/linux/x64/jdk/hotspot/normal/eclipse"

        rm -rf "$jdk_dir"
        mkdir -p "$jdk_dir"
        tar -xzf "$tmp" -C "$jdk_dir" --strip-components=1
        rm -f "$tmp"
        echo "JDK installed to $jdk_dir"
        EOT
        destination = "local/fetch-jdk.sh"
        perms       = "755"
      }

      config {
        command = "${NOMAD_TASK_DIR}/fetch-jdk.sh"
      }

      resources {
        cpu    = 2
        memory = 256
      }
    }

    task "minecraft" {
      driver = "raw_exec"

      env {
        PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
      }

      template {
        data        = <<-EOT
        #!/bin/sh
        set -eu

        local_dir="$NOMAD_ALLOC_DIR/minecraft-data"
        cd "$local_dir"

        echo "eula=true" > eula.txt

        /opt/nomad/temurin-jdk/bin/java \
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
