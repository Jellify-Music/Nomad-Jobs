job "minecraft" {
  datacenters = ["jellify"]
  type        = "service"

  group "minecraft" {
    count = 1

    # Local disk backs the live/hot copy of everything (world, plugins,
    # server.properties, ...) as of 2026-09-28 - see the "seed-data" task
    # below and the README's minecraft section for why: the NFS-mounted
    # Jellify share was causing multi-second main-thread stalls during
    # Paper's own level-data saves (confirmed via an in-game thread dump),
    # which is what was actually causing placed blocks to disappear.
    # sticky+migrate carries this across a restart/reschedule on the same
    # host for free; seed-data's one-time restore-from-NFS covers a fresh
    # host or total local-disk loss. 5120MB against a 557MB world (measured
    # 2026-09-28) leaves plenty of headroom for growth.
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
      # BlueMap's own embedded webserver (default port) - reverse-proxied
      # through Traefik at minecraft.jellify.app/map (see the "minecraft"
      # task's minecraft-bluemap service below), never port-forwarded
      # directly like java/bedrock are.
      port "bluemap" { static = 8100 }
      # minecraft-status's own tiny HTTP server (see that task below) -
      # reverse-proxied at the bare minecraft.jellify.app root, same
      # never-port-forwarded-directly treatment as bluemap above.
      port "status" { static = 8101 }
    }

    # Two copies of everything (worlds, player data, server config, plugins)
    # exist by design as of 2026-09-28: a durable one on the Jellify NFS
    # share (/Volumes/Jellify/minecraft) and a live/hot one on local disk
    # (ephemeral_disk above) that the "minecraft" task actually reads and
    # writes. This task bridges the two - one-time restore from NFS onto a
    # fresh/empty local disk, plus the server.properties seed/upsert, which
    # now has to target the local copy since that's what Paper reads.
    task "seed-data" {
      driver = "raw_exec"

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      env {
        HOME = "/Users/violet"
      }

      # RCON is internal-only by design: bound to localhost, never
      # registered as a Nomad service, never port-forwarded or routed
      # through Traefik. It exists so ops tooling (Chunky pre-gen kicked off
      # once by hand below, and a future Nextcloud-whitelist automation) can
      # issue console commands without needing raw_exec stdin access, which
      # Nomad doesn't expose for this driver.
      template {
        data        = <<-EOT
        RCON_PASSWORD={{ key "minecraft/RCON_PASSWORD" }}
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
          until /sbin/mount | /usr/bin/grep -Fq " on /Volumes/Jellify (nfs"; do
            attempts=$((attempts + 1))
            if [ "$attempts" -ge 30 ]; then
              echo "Jellify NFS mount did not appear" >&2
              exit 1
            fi
            /bin/sleep 2
          done

          durable_dir="/Volumes/Jellify/minecraft"
          local_dir="$NOMAD_ALLOC_DIR/minecraft-data"
          mkdir -p "$durable_dir/config" "$durable_dir/plugins" "$durable_dir/world/datapacks"

          # One-time restore from the durable NFS copy - only when local
          # disk doesn't already have a world. A normal restart on the same
          # host skips this: sticky/migrate already carried the local copy
          # forward, and re-pulling from NFS every start would be exactly
          # the NFS I/O this migration exists to avoid. Only actually fires
          # on a fresh host, total local-disk loss, or (per sticky/migrate's
          # known limits - see lidarr/sabnzbd/openldap elsewhere in this
          # repo) a full job redeploy, not just a crash/restart.
          #
          # mkdir -p here creates only $local_dir itself, deliberately not
          # $local_dir/world - creating that ourselves before this check
          # would make it always true, so the restore would never fire
          # (hit for real on 2026-09-28: silently produced empty local
          # whitelist.json/ops.json, which locked out an already-whitelisted
          # player until caught and fixed by hand over RCON).
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

          # Idempotent upsert, run every start - keeps these specific keys
          # correct without touching anything else in server.properties
          # (which is otherwise seeded once and left alone for hand-editing,
          # see above). view-distance/simulation-distance are set
          # separately on purpose: view-distance is what a client actually
          # sees (safe to push far for a big-screen setup), simulation-distance
          # governs how far out entities/redstone/etc. actually tick, which
          # is much more expensive - keeping it modest bounds server load
          # independent of how far players can see.
          set_prop() {
            key="$1"
            value="$2"
            grep -v "^$key=" "$local_dir/server.properties" > "$local_dir/server.properties.tmp" 2>/dev/null || true
            echo "$key=$value" >> "$local_dir/server.properties.tmp"
            mv "$local_dir/server.properties.tmp" "$local_dir/server.properties"
          }
          set_prop view-distance 24
          set_prop simulation-distance 10
          # Default (16) blocks non-ops from building/breaking anywhere near
          # spawn; 0 disables that restriction entirely.
          set_prop spawn-protection 0
          # Bedrock players connect through Floodgate as virtual accounts with
          # no real Mojang-signed chat key, so the default (true) leaves them
          # muted server-side: "Chat disabled due to missing profile public
          # key" (confirmed live in the server log 2026-09-28) while Java
          # players chat normally. false drops the signed-chat requirement
          # entirely so Floodgate players aren't excluded.
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

    # Resolves nomad var nomad/jobs/minecraft's paper_version ("latest" by
    # default) against PaperMC's Fill API and downloads that build's jar
    # straight onto the local data dir (see seed-data above), overwriting it
    # fresh on every allocation start.
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

        # Paper currently runs two version lines side by side (the new 26.x
        # scheme, presently ALPHA-channel, alongside the real stable 1.21.x
        # line) - a version string with no "-rc"/"-pre" suffix isn't enough
        # to tell a real release from an alpha one, only the build's own
        # "channel" field is (confirmed 2026-09-27: version "26.3" has no
        # such suffix but its latest build's channel is "ALPHA"). So walk
        # candidates in order and use the first whose latest build is
        # actually STABLE - unless a version was pinned explicitly via the
        # Nomad variable, in which case that's a deliberate choice and its
        # channel isn't second-guessed.
        #
        # json.load(..., strict=False) matters on every parse of a live
        # build response below: PaperMC's commit messages sometimes contain
        # raw, unescaped newlines (confirmed 2026-09-29 on build 129 for
        # 26.2, among others) - strict mode (the default) rejects that as an
        # "Invalid control character", and the try/except around the
        # channel check was silently swallowing that as channel="" and
        # skipping right past a genuinely STABLE build (26.2) down to an
        # older one (26.1.2) that just happened to have no commits to choke
        # on. Left the try/except in place as a backstop for a truly
        # malformed response, but strict=False means it shouldn't normally
        # trigger at all now.
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

    # Geyser + Floodgate are re-downloaded (latest build) on every start,
    # overwriting whatever was there - they land in the same local plugins
    # directory as every other plugin (see seed-data above). Only these two
    # files are ever touched by this task; anything else placed in that
    # directory is left alone.
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

          # -L matters here: /builds/latest is a 302 redirect to the actual
          # build number's endpoint (confirmed 2026-09-27 - without -L this
          # silently "succeeds" with an empty body instead of following it,
          # since a 3xx isn't itself an error to curl's -f).
          #
          # strict=False on every parse below: these builds' "changes"
          # commit summaries/messages can contain raw unescaped newlines,
          # the same "Invalid control character" issue confirmed on
          # PaperMC's API (see fetch-paper.sh) - untested whether GeyserMC's
          # API actually hits this in practice, but it's the same shape of
          # response and cheap to guard against regardless.
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

    # Every plugin/datapack that isn't Geyser/Floodgate lands here: pinned
    # to a specific checksummed version and only fetched once (skipped if
    # already present), not re-fetched fresh every start like
    # Geyser/Floodgate deliberately are. Version churn on any of these needs
    # to be a conscious choice (bump the pinned URL/checksum by hand), not
    # something that just happens on a restart - this matters most for
    # Terralith/Tectonic specifically, since an unplanned mid-world
    # worldgen-datapack version bump can leave a visible seam where old and
    # new generation algorithms meet at a chunk boundary, but the same
    # "don't silently change under me" reasoning applies to any plugin here.
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

        # Terralith v2.6.4 (datapack) and Tectonic v3.0.25 (datapack) -
        # both confirmed compatible with Minecraft 26.2 via Modrinth's API
        # (2026-09-29). Dropped straight in as .zip files - Minecraft loads
        # zipped datapacks natively, no extraction needed, confirmed both
        # zips have "data/" at the archive root with no wrapper folder.
        fetch_pinned \
          "https://cdn.modrinth.com/data/8oi3bsk5/versions/CzijfXJQ/Terralith_26.2_v2.6.4.zip" \
          "96ccd25be9ba5240ebe8150cc29240aca781f0e1" \
          "$data_dir/world/datapacks/Terralith.zip"

        fetch_pinned \
          "https://cdn.modrinth.com/data/lWDHr9jE/versions/CmzMQNDL/tectonic-datapack-3.0.25.zip" \
          "790390ed8f5032bb0e9fc3bd7aa7017d838cf273" \
          "$data_dir/world/datapacks/Tectonic.zip"

        # Chunky 1.5.3 (Paper plugin) - lives alongside Geyser/Floodgate in
        # the same persistent plugins directory.
        fetch_pinned \
          "https://cdn.modrinth.com/data/fALzjamp/versions/MdY6JATr/Chunky-Bukkit-1.5.3.jar" \
          "7ff47ee3afec89a1725e6eef393f373c549eff3b" \
          "$data_dir/plugins/Chunky.jar"

        # AuraSkills v2.4.0 (RPG skills/leveling plugin, formerly branded
        # "Aurelium Skills") - confirmed compatible with Minecraft 26.2 via
        # Modrinth's API (2026-09-29): 215k downloads, actively maintained.
        # mcMMO was considered too but isn't distributed via Modrinth/Hangar
        # at all (own site + GitHub only), so it couldn't be verified or
        # fetched the same trusted way as everything else here.
        fetch_pinned \
          "https://cdn.modrinth.com/data/uDdZAVls/versions/9rSJ3THD/AuraSkills-2.4.0.jar" \
          "f8c6c4a73bf853755108578625cf5ca212957b53" \
          "$data_dir/plugins/AuraSkills.jar"

        # ViaVersion + ViaBackwards v5.12.0, added 2026-09-29 to let older
        # Java clients connect to this server. Pinned rather than
        # "always latest" like Geyser/Floodgate specifically because
        # paper_version is now pinned too (see fetch-paper.sh/README) - a
        # version pin only actually holds the server's protocol version
        # steady if these bridge plugins are pinned alongside it. Both
        # confirmed via Modrinth's API (2026-09-29) to have a real
        # (non-SNAPSHOT) release build declaring support for Paper 26.2.
        # Load order is handled by Paper's own plugin dependency resolution
        # (ViaBackwards declares ViaVersion as a dependency), not fetch
        # order here.
        fetch_pinned \
          "https://cdn.modrinth.com/data/P1OZGk5p/versions/FaishMnD/ViaVersion-5.12.0.jar" \
          "7486c37c91b3cc892d37ee9a05470bf6ec49a59f" \
          "$data_dir/plugins/ViaVersion.jar"

        fetch_pinned \
          "https://cdn.modrinth.com/data/NpvuJQoq/versions/SxGhdsPK/ViaBackwards-5.12.0.jar" \
          "3603c85784c41387c56ec76c016c21e0a1ae303a" \
          "$data_dir/plugins/ViaBackwards.jar"

        # BlueMap v5.28 (Paper build), added 2026-09-29 - confirmed via
        # Modrinth's API the same day to declare support for game versions
        # up to 26.3, covering the pinned 26.2 Paper build. Gives a live
        # web map at minecraft.jellify.app/map (see the minecraft-bluemap
        # service/Traefik tags on the "minecraft" task, and the "bluemap"
        # network port above) instead of a client-side minimap mod -
        # deliberate, since this server bridges Java (multiple versions via
        # ViaVersion/ViaBackwards) and Bedrock (via Geyser/Floodgate)
        # clients, and a Fabric/Forge-only minimap mod would only ever work
        # for a subset of players.
        #
        # NOT yet fully redeploy-safe: BlueMap needs its own
        # plugins/bluemap/core.conf "accept-download" flag set (Mojang
        # asset download consent for rendering) and its webserver.conf
        # port pinned to 8100 to match the network port above, but the
        # exact generated key names/file layout for v5.28 haven't been
        # confirmed live yet (unlike every other "confirmed" claim in this
        # file). Plan: deploy once the server is empty, let BlueMap
        # generate its own defaults on first boot, patch the real
        # core.conf/webserver.conf by hand (or over RCON) once the actual
        # keys are visible, then fold the confirmed values back into an
        # idempotent seed step here - same set_prop pattern seed-data
        # already uses for server.properties.
        fetch_pinned \
          "https://cdn.modrinth.com/data/swbUV1cr/versions/pILlMIlN/bluemap-5.28-paper.jar" \
          "6e9d1bb29a43aa24108b5cb4b61de6efec1f521a" \
          "$data_dir/plugins/BlueMap.jar"
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

    # Installs a portable JDK to a fixed local (non-NFS) path if it isn't
    # there already, rather than relying on a host having a JDK
    # pre-installed. Deliberately NOT the Homebrew `temurin` cask: that cask
    # shells out to macOS's privileged `installer -pkg`, which needs
    # interactive Authorization Services approval and hangs indefinitely
    # over a plain SSH session (confirmed 2026-09-28, twice, on hopper -
    # same unfixable-remotely class of problem as the TCC gotchas above, but
    # a different mechanism, so no TCC grant fixes it). A plain tarball
    # extraction needs no privilege escalation at all. Lands under
    # /opt/nomad (already writable by violet, since Nomad itself lives
    # there) rather than /Volumes/Jellify - this is host-local and has
    # nothing to do with the server's actual data, and re-fetching a JDK
    # over NFS on every restart would be wasteful; it only needs to survive
    # restarts on whichever single host it was fetched to.
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
        if [ -x "$jdk_dir/Contents/Home/bin/java" ]; then
          echo "JDK already present at $jdk_dir"
          exit 0
        fi

        ua="cosmonautical-nomad-jobs/1.0 (violet@cosmonautical.cloud)"
        tmp="/opt/nomad/temurin-jdk.tar.gz"

        curl -sfL -H "User-Agent: $ua" -o "$tmp" \
          "https://api.adoptium.net/v3/binary/latest/25/ga/mac/aarch64/jdk/hotspot/normal/eclipse"

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
      # Originally the java driver - it can fingerprint the real JDK fine
      # (driver.java.version reports it correctly) but its own executor
      # can't actually fork/exec java on these hosts (EPERM, confirmed
      # 2026-09-27: no TCC denial logged for it at all, unlike the
      # NFS-volume issue above, so it isn't a grantable permission - looks
      # like a deeper incompatibility between the java driver's executor and
      # this specific macOS/Java combination). raw_exec + a wrapper script
      # that execs java directly is the same pattern keycloak.nomad.hcl
      # already uses successfully in this cluster.
      driver = "raw_exec"

      env {
        PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
      }

      # Points at fetch-jdk's extracted JDK directly, not /usr/bin/java or
      # PATH - keeps this independent of whatever (if anything) happens to
      # be registered as the system default JDK on a given host.
      #
      # cd's into the local ephemeral_disk data dir before launching java
      # (2026-09-28) rather than passing --world-dir et al. and leaving cwd
      # at the task's own ephemeral directory: ops.json/whitelist.json/ban
      # lists/usercache.json have no CLI flag - Paper always writes these to
      # cwd - so this is what makes them land in the same persistent,
      # synced-back directory as everything else, instead of needing the
      # old restore-identity-files/sync-identity-files reach-into-a-sibling-
      # task workaround (removed, no longer needed).
      #
      # java runs backgrounded rather than exec'd directly so this script
      # can also run the sync-back loop and trap the stop signal - same
      # shape as traefik.nomad's start.sh. kill_timeout below gives Paper
      # room to actually save and disconnect players on a real SIGTERM
      # forwarded through the trap, not just get SIGKILLed.
      template {
        data        = <<-EOT
        #!/bin/sh
        set -eu

        local_dir="$NOMAD_ALLOC_DIR/minecraft-data"
        cd "$local_dir"

        # Static, deterministic content - fine to just write it fresh into
        # cwd every start rather than persist it.
        echo "eula=true" > eula.txt

        /opt/nomad/temurin-jdk/Contents/Home/bin/java \
          -Xms2G -Xmx4G -XX:+UseG1GC \
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

        # Periodic sync-back to the durable Jellify copy (2026-09-28),
        # covering the whole local_dir tree - world, plugins, configs, and
        # now the identity files too (see cd above). rsync instead of a
        # plain cp: a full copy every 2 minutes would push the entire world
        # over NFS on every tick regardless of what actually changed, which
        # is exactly the sustained NFS write load .agents/AGENTS.md gotcha
        # #5 already measured as a real bottleneck on this cluster - rsync's
        # delta transfer only pushes files that changed since the last tick.
        # No --delete: a file missing locally shouldn't get force-deleted
        # from the backup copy.
        sync_loop() {
          while true; do
            sleep 120
            /usr/bin/rsync -a "$local_dir/" /Volumes/Jellify/minecraft/ 2>/dev/null || true
          done
        }
        sync_loop &
        sync_pid=$!

        cleanup() {
          kill "$sync_pid" 2>/dev/null || true
          kill "$mc_pid" 2>/dev/null || true
          wait "$mc_pid" 2>/dev/null || true
          # One last sync after java has actually exited, so a deliberate
          # stop/redeploy (the common case - Nomad sends SIGTERM here) loses
          # nothing, not just whatever the last 2-minute tick happened to
          # catch. Only a hard crash (SIGKILL, OS crash) skips this and
          # falls back to the periodic tick's last save.
          /usr/bin/rsync -a "$local_dir/" /Volumes/Jellify/minecraft/ 2>/dev/null || true
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

      # BlueMap's web UI, reverse-proxied at minecraft.jellify.app/map -
      # relies on the same wildcard-capable cf-dns DNS challenge every
      # other *.jellify.app host here already uses (jellyfin.jellify.app
      # etc.), so no separate DNS record should be needed, but that's
      # inferred from the existing pattern, not confirmed live yet.
      # stripprefix strips "/map" before forwarding, since BlueMap's own
      # webserver serves from its own root and has no config for being
      # mounted under a subpath - BlueMap's web assets are all
      # relative-pathed, which is what makes this work.
      service {
        name = "minecraft-bluemap"
        port = "bluemap"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.bluemap.rule=Host(`minecraft.jellify.app`) && PathPrefix(`/map`)",
          "traefik.http.routers.bluemap.entrypoints=websecure",
          "traefik.http.routers.bluemap.tls.certresolver=cf-dns",
          "traefik.http.routers.bluemap.middlewares=bluemap-stripprefix",
          "traefik.http.middlewares.bluemap-stripprefix.stripprefix.prefixes=/map",
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
        cpu    = 8
        memory = 6144
      }

      kill_timeout = "30s"
    }

    # A live status page at the bare minecraft.jellify.app root (bluemap's
    # PathPrefix(`/map`) router above takes priority for that path - Traefik
    # ranks routers by rule specificity/length by default, and Host+PathPrefix
    # is strictly longer than Host alone, so no explicit priority needed).
    #
    # Pings the real server itself (Java SLP handshake on 127.0.0.1:25565,
    # Bedrock RakNet unconnected-ping on 127.0.0.1:19132) fresh on every
    # request rather than depending on a third-party status API/widget - both
    # protocols implemented directly in Python's stdlib below (socket/struct/
    # json only, no pip install), matching this job's existing
    # no-extra-runtime-dependencies posture (raw_exec, no container image).
    task "minecraft-status" {
      driver = "raw_exec"

      template {
        data        = <<-EOT
        #!/usr/bin/env python3
        import html, json, os, random, re, socket, struct, time
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

        RAKNET_MAGIC = bytes.fromhex("00ffff00fefefefefdfdfdfd12345678")
        STRIP_FORMATTING = re.compile("§.")


        def recv_exact(sock, n):
            buf = b""
            while len(buf) < n:
                chunk = sock.recv(n - len(buf))
                if not chunk:
                    raise IOError("connection closed early")
                buf += chunk
            return buf


        def read_varint_sock(sock):
            value = 0
            for i in range(5):
                b = recv_exact(sock, 1)[0]
                value |= (b & 0x7f) << (7 * i)
                if not (b & 0x80):
                    return value
            raise IOError("varint too long")


        def read_varint_buf(buf, idx):
            value = 0
            shift = 0
            while True:
                b = buf[idx]
                idx += 1
                value |= (b & 0x7f) << shift
                if not (b & 0x80):
                    return value, idx
                shift += 7


        def write_varint(value):
            out = bytearray()
            while True:
                b = value & 0x7f
                value >>= 7
                if value:
                    out.append(b | 0x80)
                else:
                    out.append(b)
                    break
            return bytes(out)


        def write_string(s):
            data = s.encode("utf-8")
            return write_varint(len(data)) + data


        def java_status(host, port, timeout=3.0):
            with socket.create_connection((host, port), timeout=timeout) as sock:
                sock.settimeout(timeout)
                handshake = (
                    write_varint(0)
                    + write_varint(0)
                    + write_string(host)
                    + struct.pack(">H", port)
                    + write_varint(1)
                )
                sock.sendall(write_varint(len(handshake)) + handshake)
                sock.sendall(write_varint(1) + write_varint(0))

                length = read_varint_sock(sock)
                payload = recv_exact(sock, length)
                _pid, idx = read_varint_buf(payload, 0)
                json_len, idx = read_varint_buf(payload, idx)
                return json.loads(payload[idx : idx + json_len].decode("utf-8"))


        def bedrock_status(host, port, timeout=3.0):
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.settimeout(timeout)
            try:
                packet = (
                    bytes([0x01])
                    + struct.pack(">Q", int(time.time() * 1000) & ((1 << 64) - 1))
                    + RAKNET_MAGIC
                    + struct.pack(">Q", random.getrandbits(64))
                )
                sock.sendto(packet, (host, port))
                data, _ = sock.recvfrom(4096)
            finally:
                sock.close()

            if not data or data[0] != 0x1C:
                raise IOError("unexpected unconnected-pong response")

            offset = 1 + 8 + 8 + 16
            (str_len,) = struct.unpack(">H", data[offset : offset + 2])
            offset += 2
            info = data[offset : offset + str_len].decode("utf-8", errors="replace")
            keys = [
                "edition", "motd1", "protocol", "version",
                "online", "max", "server_id", "motd2",
                "gamemode", "gamemode_num", "port_v4", "port_v6",
            ]
            return dict(zip(keys, info.split(";")))


        def describe(desc):
            if isinstance(desc, str):
                return desc
            if isinstance(desc, dict):
                text = desc.get("text", "")
                for extra in desc.get("extra") or []:
                    text += describe(extra)
                return text
            return ""


        def clean(text):
            return STRIP_FORMATTING.sub("", text or "").strip()


        def card(title, online, body):
            status_class = "online" if online else "offline"
            status_label = "Online" if online else "Offline"
            return f"""
            <section class="card">
              <h2>{html.escape(title)} <span class="badge {status_class}">{status_label}</span></h2>
              {body}
            </section>
            """


        def render():
            java_port = int(os.environ.get("NOMAD_PORT_java", "25565"))
            bedrock_port = int(os.environ.get("NOMAD_PORT_bedrock", "19132"))

            try:
                j = java_status("127.0.0.1", java_port)
                players = j.get("players", {})
                sample = players.get("sample") or []
                names = ", ".join(html.escape(p.get("name", "?")) for p in sample) or "no players online"
                java_body = f"""
                <p class="motd">{html.escape(clean(describe(j.get("description"))))}</p>
                <p>{players.get("online", "?")} / {players.get("max", "?")} players</p>
                <p class="players">{names}</p>
                <p class="version">{html.escape(j.get("version", {}).get("name", ""))}</p>
                """
                java_online = True
            except Exception:
                java_body = "<p>Server is not responding.</p>"
                java_online = False

            try:
                b = bedrock_status("127.0.0.1", bedrock_port)
                bedrock_body = f"""
                <p class="motd">{html.escape(clean(b.get("motd1", "")))}</p>
                <p>{html.escape(b.get("online", "?"))} / {html.escape(b.get("max", "?"))} players</p>
                <p class="version">{html.escape(b.get("version", ""))}</p>
                """
                bedrock_online = True
            except Exception:
                bedrock_body = "<p>Server is not responding.</p>"
                bedrock_online = False

            return f"""<!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="refresh" content="30">
        <title>Cosmonautical Minecraft</title>
        <style>
          :root {{ color-scheme: dark; }}
          body {{
            margin: 0; padding: 2.5rem 1.25rem; min-height: 100vh; box-sizing: border-box;
            background: #14181f; color: #e7ebf1;
            font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            display: flex; flex-direction: column; align-items: center; gap: 1.5rem;
          }}
          h1 {{ margin: 0 0 0.25rem; font-size: 1.6rem; }}
          .sub {{ color: #8b95a5; margin: 0 0 1rem; }}
          .cards {{ display: flex; flex-wrap: wrap; gap: 1.25rem; justify-content: center; width: 100%; max-width: 760px; }}
          .card {{
            background: #1c212b; border: 1px solid #2a3140; border-radius: 12px;
            padding: 1.25rem 1.5rem; flex: 1 1 320px; max-width: 360px;
          }}
          .card h2 {{ margin: 0 0 0.75rem; font-size: 1.1rem; display: flex; align-items: center; gap: 0.6rem; }}
          .badge {{ font-size: 0.7rem; font-weight: 600; padding: 0.15rem 0.55rem; border-radius: 999px; letter-spacing: 0.02em; }}
          .badge.online {{ background: #1c3a2a; color: #6fe3a0; }}
          .badge.offline {{ background: #3a1c1c; color: #e36f6f; }}
          .motd {{ color: #c7cee0; white-space: pre-wrap; }}
          .players {{ color: #8b95a5; font-size: 0.9rem; }}
          .version {{ color: #5f6980; font-size: 0.8rem; }}
          a {{ color: #6fa8e3; }}
          footer {{ color: #5f6980; font-size: 0.85rem; }}
        </style>
        </head>
        <body>
          <div>
            <h1>Cosmonautical Minecraft</h1>
            <p class="sub">minecraft.jellify.app</p>
          </div>
          <div class="cards">
            {card("Java Edition", java_online, java_body)}
            {card("Bedrock Edition", bedrock_online, bedrock_body)}
          </div>
          <footer><a href="/map">View the live map</a></footer>
        </body>
        </html>
        """


        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path not in ("/", "/index.html"):
                    self.send_response(404)
                    self.end_headers()
                    return
                body = render().encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, format, *args):
                pass


        def main():
            port = int(os.environ["NOMAD_PORT_status"])
            ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()


        if __name__ == "__main__":
            main()
        EOT
        destination = "local/status-server.py"
      }

      config {
        command = "/usr/bin/python3"
        args    = ["${NOMAD_TASK_DIR}/status-server.py"]
      }

      service {
        name = "minecraft-status"
        port = "status"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.minecraft-status.rule=Host(`minecraft.jellify.app`)",
          "traefik.http.routers.minecraft-status.entrypoints=websecure",
          "traefik.http.routers.minecraft-status.tls.certresolver=cf-dns",
          "traefik.http.services.minecraft-status.loadbalancer.server.port=8101",
        ]

        check {
          name     = "tcp"
          type     = "tcp"
          port     = "status"
          interval = "30s"
          timeout  = "5s"
        }
      }

      resources {
        cpu    = 1
        memory = 64
      }
    }
  }
}
