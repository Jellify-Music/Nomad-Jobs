job "actions-runner" {
  datacenters = ["jellify"]
  type        = "service"

  group "actions-runner" {
    count = 2

    # Runs on both galileo and hopper (arm64 macOS Mac minis) - it's how the
    # Jellify App repo gets an ARM macOS runner for Android/iOS builds,
    # the opposite constraint from valheim/minecraft's amd64 nodes.
    constraint {
      attribute = "${attr.cpu.arch}"
      value     = "arm64"
    }

    constraint {
      attribute = "${attr.kernel.name}"
      value     = "darwin"
    }

    task "actions-runner" {
      driver = "raw_exec"

      # Non-login-shell raw_exec processes don't source /etc/profile, so the
      # Android SDK path has to be injected explicitly here.
      env {
        ANDROID_HOME = "/Users/violet/Library/Android/sdk"
      }

      # The runner itself is downloaded and configured by hand on the host
      # first (GitHub repo/org -> Settings -> Actions -> Runners -> New
      # self-hosted runner), same manual step as before - Nomad only starts
      # run.sh, it doesn't register the runner with GitHub.
      config {
        command = "/opt/github-actions/run.sh"
      }

      resources {
        cpu    = 16     # MHz
        memory = 8192   # MiB
      }
    }
  }
}
