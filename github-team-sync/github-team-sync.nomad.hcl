# Mirrors Jellify-Music GitHub team membership into Keycloak: everyone on
# one of GITHUB_TEAMS who has signed in to the cosmonautical realm with
# GitHub at least once ends up in the `Jellify Members` group (which carries
# the `jellify-member` realm role Penpot checks), and anyone else is removed
# from it. Removal from a team takes effect on the next run.
job "github-team-sync" {
  datacenters = ["jellify"]
  type        = "batch"

  periodic {
    crons            = ["*/15 * * * *"]
    prohibit_overlap = true
  }

  group "github-team-sync" {
    # Apple `container` on the macOS/arm64 jellify nodes (galileo/hopper/
    # lovelace).
    constraint {
      attribute = "${attr.cpu.arch}"
      value     = "arm64"
    }
    constraint {
      attribute = "${attr.kernel.name}"
      value     = "darwin"
    }

    # A failed run is retried by the next scheduled one in 15 minutes.
    restart {
      attempts = 0
      mode     = "fail"
    }

    reschedule {
      attempts  = 0
      unlimited = false
    }

    task "sync" {
      driver = "container"

      env {
        KEYCLOAK_URL       = "https://auth.cosmonautical.cloud"
        KEYCLOAK_REALM     = "cosmonautical"
        KEYCLOAK_CLIENT_ID = "github-team-sync"
        KEYCLOAK_GROUP     = "Jellify Members"
        KEYCLOAK_IDP_ALIAS = "github"

        GITHUB_ORG   = "Jellify-Music"
        GITHUB_TEAMS = "design,engineering,triage"

        # "true" logs what would change without touching Keycloak.
        DRY_RUN = "false"
      }

      template {
        data        = <<EOT
KEYCLOAK_CLIENT_SECRET="{{ key "jellify/github-team-sync/KEYCLOAK_CLIENT_SECRET" }}"
GITHUB_TOKEN="{{ key "jellify/github-team-sync/GITHUB_TOKEN" }}"
EOT
        destination = "secrets/sync.env"
        env         = true
      }

      # The container driver doesn't mount the task's local/ or secrets/
      # dirs into the VM, so the script is passed inline. Standard library
      # only, so there's nothing to install.
      config {
        image      = "python:3.14-alpine@sha256:5862d971d1f0ae26b258cefa4e893556b1d3aba81bd2ff30888704ad378bab67"
        entrypoint = "python3"
        args = [
          "-c",
          <<-EOT
          import json
          import os
          import sys
          import urllib.parse
          import urllib.request

          KEYCLOAK = os.environ["KEYCLOAK_URL"].rstrip("/")
          REALM = os.environ["KEYCLOAK_REALM"]
          GROUP = os.environ["KEYCLOAK_GROUP"]
          IDP = os.environ["KEYCLOAK_IDP_ALIAS"]
          ORG = os.environ["GITHUB_ORG"]
          TEAMS = [t.strip() for t in os.environ["GITHUB_TEAMS"].split(",") if t.strip()]
          DRY_RUN = os.environ.get("DRY_RUN", "") == "true"


          def request(method, url, token=None, data=None, headers=None):
              headers = dict(headers or {})
              if token:
                  headers["Authorization"] = f"Bearer {token}"
              req = urllib.request.Request(url, data=data, method=method, headers=headers)
              with urllib.request.urlopen(req, timeout=30) as resp:
                  body = resp.read()
                  return json.loads(body) if body else None, resp.headers


          def github_team_members():
              """{github user id: login} across every configured team."""
              members = {}
              for team in TEAMS:
                  url = f"https://api.github.com/orgs/{ORG}/teams/{team}/members?per_page=100"
                  while url:
                      page, headers = request("GET", url, os.environ["GITHUB_TOKEN"], headers={
                          "Accept": "application/vnd.github+json",
                          "X-GitHub-Api-Version": "2022-11-28",
                      })
                      for user in page:
                          members[str(user["id"])] = user["login"]
                      url = next(
                          (part.split(";")[0].strip(" <>") for part in headers.get("Link", "").split(",")
                           if 'rel="next"' in part),
                          None,
                      )
              return members


          def keycloak_token():
              data = urllib.parse.urlencode({
                  "grant_type": "client_credentials",
                  "client_id": os.environ["KEYCLOAK_CLIENT_ID"],
                  "client_secret": os.environ["KEYCLOAK_CLIENT_SECRET"],
              }).encode()
              body, _ = request("POST", f"{KEYCLOAK}/realms/{REALM}/protocol/openid-connect/token", data=data,
                                headers={"Content-Type": "application/x-www-form-urlencoded"})
              return body["access_token"]


          def main():
              github = github_team_members()
              # An empty result means a bad token or team slug far more often than a
              # real empty team - don't empty the group over it.
              if not github:
                  sys.exit(f"no members found in {ORG} teams {TEAMS}; refusing to empty {GROUP!r}")
              print(f"github: {len(github)} member(s) across {', '.join(TEAMS)}")

              token = keycloak_token()
              admin = f"{KEYCLOAK}/admin/realms/{REALM}"

              def kc(method, path, **params):
                  query = f"?{urllib.parse.urlencode(params)}" if params else ""
                  return request(method, f"{admin}{path}{query}", token)[0]

              groups = kc("GET", "/groups", search=GROUP, exact="true")
              group = next((g for g in groups if g["name"] == GROUP), None)
              if group is None:
                  sys.exit(f"keycloak group {GROUP!r} not found")

              # Team members who've signed in with GitHub at least once, i.e. have a
              # Keycloak user linked to their GitHub account.
              desired = {}
              for github_id, login in sorted(github.items(), key=lambda m: m[1].lower()):
                  users = kc("GET", "/users", idpAlias=IDP, idpUserId=github_id, briefRepresentation="true")
                  if users:
                      desired[users[0]["id"]] = f"{users[0]['username']} (github: {login})"
                  else:
                      print(f"skip {login}: no keycloak user linked to this github account yet")

              current = {}
              first = 0
              while True:
                  page = kc("GET", f"/groups/{group['id']}/members", first=first, max=100, briefRepresentation="true")
                  current.update({u["id"]: u["username"] for u in page})
                  if len(page) < 100:
                      break
                  first += 100

              prefix = "[dry run] " if DRY_RUN else ""
              for user_id in desired.keys() - current.keys():
                  print(f"{prefix}add {desired[user_id]}")
                  if not DRY_RUN:
                      kc("PUT", f"/users/{user_id}/groups/{group['id']}")
              for user_id in current.keys() - desired.keys():
                  print(f"{prefix}remove {current[user_id]}")
                  if not DRY_RUN:
                      kc("DELETE", f"/users/{user_id}/groups/{group['id']}")
              print(f"{GROUP!r}: {len(desired)} member(s)")


          main()
          EOT
        ]
      }

      resources {
        cpu    = 100
        memory = 256
      }
    }
  }
}
