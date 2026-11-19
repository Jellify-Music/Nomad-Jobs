# Shared by backend (enforcement), frontend (which login options it renders)
# and exporter - upstream's compose file passes the same set to all three.
# SSO-only: no password login or open registration, but a first Keycloak
# login creates the Penpot account (oidc-registration). Email verification
# is skipped since Keycloak already owns the address.
locals {
  penpot_flags = join(" ", [
    "enable-login-with-oidc",
    "enable-oidc-registration",
    "disable-login-with-password",
    "disable-registration",
    "disable-email-verification",
    "enable-smtp",
  ])
}

job "penpot" {
  datacenters = ["jellify"]
  type        = "service"

  group "penpot" {
    count = 1

    # Apple `container` tasks on the macOS/arm64 jellify nodes (galileo/
    # hopper/lovelace). All three images are multi-arch, and all three hosts
    # mount the Jellify NFS share at /Volumes/Jellify for assets.
    constraint {
      attribute = "${attr.cpu.arch}"
      value     = "arm64"
    }
    constraint {
      attribute = "${attr.kernel.name}"
      value     = "darwin"
    }

    # Dynamic host ports, mapped onto each image's fixed container port.
    # The three tasks reach each other via NOMAD_ADDR_<label> (host IP +
    # mapped port), standing in for upstream compose's service-name DNS.
    network {
      port "frontend" { to = 8080 }
      port "backend" { to = 6060 }
      port "exporter" { to = 6061 }
    }

    # Idempotent bootstrap, re-run on every deploy: creates the `penpot`
    # role/database on the shared postgres cluster if missing, plus the
    # uuid-ossp extension Penpot's first migration expects. Penpot runs its
    # own migrations on backend start. Uses a postgres image for psql since
    # only lovelace has Homebrew's installed. The container driver doesn't
    # mount the task's secrets/ dir into the VM, so the script is inline and
    # only the credentials come in, as env vars.
    task "schema-init" {
      driver = "container"

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      template {
        data        = <<EOT
PGHOST={{ range service "postgres" }}{{ .Address }}{{ end }}
PGPORT={{ range service "postgres" }}{{ .Port }}{{ end }}
PGPASSWORD="{{ key "postgres/PATRONI_SUPERUSER_PASSWORD" }}"
PENPOT_DB_PASSWORD="{{ key "jellify/penpot/DB_PASSWORD" }}"
EOT
        destination = "secrets/schema-init.env"
        env         = true
      }

      config {
        image      = "postgres:18-alpine@sha256:ff64c9e3bdf8e2120107d3559de8db314e8305f7e38c5105903c6295876738ff"
        entrypoint = "/bin/sh"
        args = [
          "-c",
          <<-EOT
          set -eu
          export PGUSER=violet

          psql -d postgres -v ON_ERROR_STOP=1 -v penpot_pw="$PENPOT_DB_PASSWORD" <<'SQL'
          SELECT 'CREATE ROLE penpot LOGIN PASSWORD ' || quote_literal(:'penpot_pw')
            WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'penpot')\gexec
          SELECT 'CREATE DATABASE penpot OWNER penpot'
            WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'penpot')\gexec
          SQL

          psql -d penpot -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION IF NOT EXISTS "uuid-ossp"'
          EOT
        ]
      }

      resources {
        cpu    = 100
        memory = 256
      }
    }

    # Assets live on the Jellify NFS share so they survive rescheduling onto
    # a different Mac. Apple container bind mounts write as the host user
    # running Nomad (violet, uid 1000) whatever uid the image runs as, so
    # /Volumes/Jellify/penpot just has to be owned by 1000:20. Nomad can't
    # create it itself: the share's root is 988:988 0755 and nothing on the
    # Macs runs as root. See README's "One-time setup".
    task "ensure-assets-dir" {
      driver = "raw_exec"

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      config {
        command = "/bin/sh"
        args = [
          "-c",
          "mkdir -p /Volumes/Jellify/penpot/assets",
        ]
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }

    task "backend" {
      driver = "container"

      config {
        image = "penpotapp/backend:2.18.2@sha256:5f362bda5b8df6684a5710c4c273f7c8aadb759ba6ebcd0cde18a348ad9b9828"
        ports = ["backend"]

        volumes = [
          "/Volumes/Jellify/penpot/assets:/opt/data/assets",
        ]
      }

      env {
        PENPOT_FLAGS = local.penpot_flags

        PENPOT_DATABASE_USERNAME = "penpot"

        PENPOT_OBJECTS_STORAGE_BACKEND      = "fs"
        PENPOT_OBJECTS_STORAGE_FS_DIRECTORY = "/opt/data/assets"

        PENPOT_OIDC_CLIENT_ID = "penpot"

        # Only members of a Jellify-Music GitHub team get in: Keycloak's
        # `penpot` client puts realm roles in a `roles` claim, and the
        # github-team-sync job grants `jellify-member` to everyone on a
        # synced team. Keycloak gates on the same role first (the client's
        # browser-penpot flow, and the github IdP's post-login flow); this
        # is the backstop for every login path.
        PENPOT_OIDC_ROLES      = "jellify-member"
        PENPOT_OIDC_ROLES_ATTR = "roles"

        PENPOT_SMTP_TLS = "true"
        PENPOT_SMTP_SSL = "false"

        PENPOT_TELEMETRY_ENABLED = "false"
      }

      # Non-sensitive, deployment-specific config - Nomad Variables, see
      # README's "Nomad Variables" table.
      template {
        data        = <<EOT
{{ with nomadVar "nomad/jobs/penpot" }}
PENPOT_PUBLIC_URI={{ .PUBLIC_URI }}
PENPOT_OIDC_BASE_URI={{ .OIDC_BASE_URI }}
{{ end }}
EOT
        destination = "local/penpot-config.env"
        env         = true
      }

      # Redis DB 3 - 0 is RomM, 1 is nextcloud/seaweedfs-filer, 2 is
      # audiomuse-ai on the shared redis cluster.
      template {
        data        = <<EOT
PENPOT_SECRET_KEY="{{ key "jellify/penpot/SECRET_KEY" }}"
PENPOT_DATABASE_URI="postgresql://{{ range service "postgres" }}{{ .Address }}:{{ .Port }}{{ end }}/penpot"
PENPOT_DATABASE_PASSWORD="{{ key "jellify/penpot/DB_PASSWORD" }}"
PENPOT_REDIS_URI="redis://:{{ key "redis/PASSWORD" }}@{{ range service "redis" }}{{ .Address }}:{{ .Port }}{{ end }}/3"
PENPOT_OIDC_CLIENT_SECRET="{{ key "jellify/penpot/OIDC_CLIENT_SECRET" }}"
PENPOT_SMTP_HOST="{{ key "smtp/SERVER" }}"
PENPOT_SMTP_PORT="{{ key "smtp/PORT" }}"
PENPOT_SMTP_USERNAME="{{ key "smtp/USERNAME" }}"
PENPOT_SMTP_PASSWORD="{{ key "smtp/PASSWORD" }}"
PENPOT_SMTP_DEFAULT_FROM="{{ key "smtp/USERNAME" }}"
PENPOT_SMTP_DEFAULT_REPLY_TO="{{ key "smtp/USERNAME" }}"
EOT
        destination = "secrets/backend.env"
        env         = true
      }

      resources {
        cpu    = 1000
        memory = 2048
      }
    }

    task "exporter" {
      driver = "container"

      config {
        image = "penpotapp/exporter:2.18.2@sha256:4329b95d4b334b6ff95e80642fa634872a3111d6264f20e6262e43db4129ee58"
        ports = ["exporter"]
      }

      env {
        PENPOT_FLAGS = local.penpot_flags

        # Headless Chromium renders exports by loading the frontend itself.
        PENPOT_INTERNAL_URI = "http://${NOMAD_ADDR_frontend}"
      }

      template {
        data        = <<EOT
{{ with nomadVar "nomad/jobs/penpot" }}
PENPOT_PUBLIC_URI={{ .PUBLIC_URI }}
{{ end }}
EOT
        destination = "local/penpot-config.env"
        env         = true
      }

      template {
        data        = <<EOT
PENPOT_SECRET_KEY="{{ key "jellify/penpot/SECRET_KEY" }}"
PENPOT_REDIS_URI="redis://:{{ key "redis/PASSWORD" }}@{{ range service "redis" }}{{ .Address }}:{{ .Port }}{{ end }}/3"
EOT
        destination = "secrets/exporter.env"
        env         = true
      }

      resources {
        cpu    = 500
        memory = 1024
      }
    }

    task "frontend" {
      driver = "container"

      config {
        image = "penpotapp/frontend:2.18.2@sha256:3619f48cbdd0c9197ad23bd3db1c9b4391d7c9c3137e22e806cd7f9c945c1c8e"
        ports = ["frontend"]

        # Read-only: nginx serves stored assets straight off disk via the
        # backend's X-Accel-Redirect (/internal/assets), never writes them.
        volumes = [
          "/Volumes/Jellify/penpot/assets:/opt/data/assets:ro",
        ]
      }

      env {
        PENPOT_FLAGS = local.penpot_flags

        PENPOT_BACKEND_URI  = "http://${NOMAD_ADDR_backend}"
        PENPOT_EXPORTER_URI = "http://${NOMAD_ADDR_exporter}"

        # Full label of the SSO button on the login page (Penpot uses it
        # verbatim instead of its default "OpenID").
        PENPOT_OIDC_NAME = "Sign in with Cosmonautical"
      }

      template {
        data        = <<EOT
{{ with nomadVar "nomad/jobs/penpot" }}
PENPOT_PUBLIC_URI={{ .PUBLIC_URI }}
{{ end }}
EOT
        destination = "local/penpot-config.env"
        env         = true
      }

      service {
        name = "penpot"
        port = "frontend"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.penpot.rule=Host(`penpot.jellify.app`)",
          "traefik.http.routers.penpot.entrypoints=websecure",
          "traefik.http.routers.penpot.tls.certresolver=cf-dns",
        ]

        # /readyz is proxied through to the backend, so this only passes
        # once the whole frontend -> backend path is up.
        check {
          name     = "readyz"
          type     = "http"
          path     = "/readyz"
          interval = "30s"
          timeout  = "10s"
        }
      }

      # Each Apple container task is its own Linux VM, so this covers the
      # guest kernel as well as nginx.
      resources {
        cpu    = 200
        memory = 512
      }
    }
  }
}
