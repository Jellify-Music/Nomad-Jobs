job "actions-runner" {
  datacenters = ["jellify"]

  # One runner on every node in Nomadable's `github_runners` inventory group
  # (published as node meta by Nomadintosh's nomad role) - adding a runner is
  # an inventory change, not a change here.
  type = "system"

  constraint {
    attribute = "${meta.inventory_groups}"
    operator  = "set_contains"
    value     = "github_runners"
  }

  # The env paths below are macOS/Homebrew-specific.
  constraint {
    attribute = "${attr.kernel.name}"
    value     = "darwin"
  }

  group "actions-runner" {
    # start.sh loops forever on its own (one JIT registration per CI job), so
    # a task exit is always a failure - usually GitHub's API being
    # unreachable. Keep retrying rather than ever giving up on the node.
    restart {
      attempts = 3
      interval = "10m"
      delay    = "30s"
      mode     = "delay"
    }

    task "actions-runner" {
      driver = "raw_exec"

      # Fine-grained PAT (Jellify-Music/App, Administration: read & write),
      # only used to mint single-use JIT runner configs. start.sh reads it
      # once and deletes the file, so workflow steps can't read it.
      template {
        destination = "secrets/github_pat"
        perms       = "0600"
        data        = <<EOF
{{ key "jellify/actions-runner/GITHUB_PAT" }}
EOF
      }

      # No ${...} or {{...}} in here: HCL and Nomad's template engine would
      # both try to interpolate them. Plain $VAR is untouched.
      template {
        destination = "local/start.sh"
        perms       = "0755"
        data        = <<EOF
#!/bin/bash
set -euo pipefail

pat="$(tr -d '[:space:]' < "$NOMAD_SECRETS_DIR/github_pat")"
rm -f "$NOMAD_SECRETS_DIR/github_pat"

# The runner binary is pre-warmed by Nomadable (its tarball has more files
# than Nomad's artifact getter allows). Each allocation gets its own copy:
# the runner self-updates in place, and Ansible prunes old versions.
if [ ! -x "$RUNNER_DIST/run.sh" ]; then
  echo "no runner at $RUNNER_DIST - run Nomadable against this host" >&2
  exit 1
fi
runner_dir="$NOMAD_TASK_DIR/runner"
rm -rf "$runner_dir"
cp -R "$RUNNER_DIST/" "$runner_dir"
mkdir -p "$HOME" "$AGENT_TOOLSDIRECTORY"

child=""
trap 'if [ -n "$child" ]; then kill -TERM "$child" 2>/dev/null; wait "$child"; fi; exit 0' TERM INT

labels="$(printf '"%s",' $(echo "$RUNNER_LABELS" | tr ',' ' '))"
labels="[$(echo "$labels" | sed 's/,$//')]"

while true; do
  # Every CI job starts from an empty work folder.
  rm -rf "$runner_dir/_work"

  # Gradle prunes its own caches; bun's install cache only grows.
  bun_cache="$HOME/.bun/install/cache"
  if [ -d "$bun_cache" ] && [ "$(du -sk "$bun_cache" | cut -f1)" -gt $((BUN_CACHE_MAX_GB * 1024 * 1024)) ]; then
    echo "bun cache over $BUN_CACHE_MAX_GB GB, clearing"
    rm -rf "$bun_cache"
  fi

  # A JIT config registers an ephemeral runner that takes exactly one job
  # and then deregisters itself, so nothing is configured on disk and no
  # stale registration outlives the allocation.
  name="$(hostname -s)-$(date +%s)"
  response="$(curl -fsS -X POST \
    -H "Authorization: Bearer $pat" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$GITHUB_REPOSITORY/actions/runners/generate-jitconfig" \
    -d "{\"name\":\"$name\",\"runner_group_id\":1,\"labels\":$labels,\"work_folder\":\"_work\"}")"
  jit="$(printf '%s' "$response" | plutil -extract encoded_jit_config raw -o - -)"

  echo "starting runner $name"
  "$runner_dir/run.sh" --jitconfig "$jit" &
  child=$!
  wait "$child" || echo "runner $name exited with $?"
  child=""
  sleep 5
done
EOF
      }

      # Paths provisioned by Nomadable's github_runners group_vars (via
      # Nomadintosh's homebrew_packages / release_archives / android_sdk
      # roles) - keep in sync with those. node@24 comes from Semaphore's
      # additional_homebrew_packages__* variables instead.
      env {
        GITHUB_REPOSITORY = "Jellify-Music/App"
        RUNNER_LABELS     = "self-hosted,macOS,ARM64"
        RUNNER_DIST       = "/opt/actions-runner/current"

        # Everything CI writes outside the allocation lands under
        # /opt/github-actions instead of violet's real home: ~/.gradle,
        # ~/.android/avd, bun's install cache, actions/setup-* downloads.
        HOME                 = "/opt/github-actions/home"
        AGENT_TOOLSDIRECTORY = "/opt/github-actions/toolcache"
        RUNNER_TOOL_CACHE    = "/opt/github-actions/toolcache"
        BUN_CACHE_MAX_GB     = "10"

        # Nomad starts tasks without a locale; CocoaPods needs UTF-8.
        LANG   = "en_US.UTF-8"
        LC_ALL = "en_US.UTF-8"

        JAVA_HOME        = "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
        ANDROID_HOME     = "/Users/violet/Library/Android/sdk"
        ANDROID_SDK_ROOT = "/Users/violet/Library/Android/sdk"
        PATH             = "/opt/maestro/current/bin:/opt/homebrew/opt/node@24/bin:/opt/homebrew/opt/ruby@4.0/bin:/Users/violet/Library/Android/sdk/platform-tools:/Users/violet/Library/Android/sdk/emulator:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

        MAESTRO_CLI_NO_ANALYTICS                   = "1"
        MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED = "true"
      }

      config {
        command = "local/start.sh"
      }

      # Long enough for the runner to report a cancelled job back to GitHub.
      kill_timeout = "30s"

      resources {
        cpu    = 16   # MHz
        memory = 8192 # MiB
      }
    }
  }
}
