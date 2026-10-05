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

    # Plain docker tasks on the Ubuntu/amd64 jellify nodes (euler/dijkstra/
    # fibonacci/kepler) - the only jellify hosts with the docker driver, and
    # the ones that mount the Jellify NFS share at /mnt/jellify for assets.
    constraint {
      attribute = "${attr.cpu.arch}"
      value     = "amd64"
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
    # the Ubuntu nodes don't have it installed.
    task "schema-init" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      template {
        data        = <<-EOT
        #!/bin/sh
        set -eu

        export PGHOST="{{ range service "postgres" }}{{ .Address }}{{ end }}"
        export PGPORT="{{ range service "postgres" }}{{ .Port }}{{ end }}"
        export PGUSER=violet
        export PGPASSWORD="{{ key "postgres/PATRONI_SUPERUSER_PASSWORD" }}"

        psql -d postgres -v ON_ERROR_STOP=1 \
          -v penpot_pw="{{ key "jellify/penpot/DB_PASSWORD" }}" <<'SQL'
        SELECT 'CREATE ROLE penpot LOGIN PASSWORD ' || quote_literal(:'penpot_pw')
          WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'penpot')\gexec
        SELECT 'CREATE DATABASE penpot OWNER penpot'
          WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'penpot')\gexec
        SQL

        psql -d penpot -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION IF NOT EXISTS "uuid-ossp"'
        EOT
        destination = "secrets/schema-init.sh"
        perms       = "755"
      }

      config {
        image   = "postgres:18-alpine"
        command = "/secrets/schema-init.sh"
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }

    # Assets live on the Jellify NFS share so they survive rescheduling onto
    # a different Ubuntu node. The backend and frontend images both run as
    # uid/gid 1001 (`penpot`), so the directory has to be owned by that -
    # raw_exec runs as root on these nodes, which the NFS export allows.
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
          "mkdir -p /mnt/jellify/penpot/assets && chown 1001:1001 /mnt/jellify/penpot /mnt/jellify/penpot/assets",
        ]
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }

    task "backend" {
      driver = "docker"

      config {
        image = "penpotapp/backend:2.18.2"
        ports = ["backend"]

        volumes = [
          "/mnt/jellify/penpot/assets:/opt/data/assets",
        ]
      }

      env {
        PENPOT_FLAGS = local.penpot_flags

        PENPOT_DATABASE_USERNAME = "penpot"

        PENPOT_OBJECTS_STORAGE_BACKEND      = "fs"
        PENPOT_OBJECTS_STORAGE_FS_DIRECTORY = "/opt/data/assets"

        PENPOT_OIDC_CLIENT_ID = "penpot"

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
      driver = "docker"

      config {
        image = "penpotapp/exporter:2.18.2"
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
      driver = "docker"

      config {
        image = "penpotapp/frontend:2.18.2"
        ports = ["frontend"]

        # Read-only: nginx serves stored assets straight off disk via the
        # backend's X-Accel-Redirect (/internal/assets), never writes them.
        volumes = [
          "/mnt/jellify/penpot/assets:/opt/data/assets:ro",
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

      resources {
        cpu    = 200
        memory = 256
      }
    }
  }
}
