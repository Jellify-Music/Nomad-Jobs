#!/usr/bin/env python3
"""Checks minecraft.nomad.hcl's pinned `locals.artifacts` for upstream updates.

    check            print the keys that have an update available (JSON list,
                     also written to $GITHUB_OUTPUT as `updates`)
    apply --key KEY  rewrite that entry's url + checksum and its README row,
                     and write the PR title/body/branch to $GITHUB_OUTPUT

Used by .github/workflows/minecraft-updates.yml. Stdlib only, so the workflow
needs nothing beyond a Python interpreter.

Every entry's source is inferred from its URL:
  - Paper (fill-data.papermc.io): newest STABLE build of the *same* game
    version. Moving to a new game version is a deliberate, manual change.
  - GeyserMC (download.geysermc.org): newest build of the newest version.
  - Modrinth (cdn.modrinth.com): newest release compatible with the pinned
    Paper game version, for the same loader family (plugin vs datapack) and
    the same file naming pattern (so e.g. BlueMap's -paper build never turns
    into its -spigot one).
"""
import argparse
import hashlib
import json
import os
import re
import sys
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_HCL = REPO_ROOT / "minecraft" / "minecraft.nomad.hcl"
DEFAULT_README = REPO_ROOT / "minecraft" / "README.md"

ENTRY_RE = re.compile(
    r'"(?P<key>[^"]+)"\s*=\s*\{\s*'
    r'url\s*=\s*"(?P<url>[^"]+)"\s*'
    r'checksum\s*=\s*"(?P<checksum>[^"]+)"\s*\}'
)
USER_AGENT_RE = re.compile(r'user_agent\s*=\s*"([^"]+)"')

PAPER_RE = re.compile(
    r"^https://fill-data\.papermc\.io/v1/objects/[0-9a-f]+/"
    r"paper-(?P<version>.+)-(?P<build>\d+)\.jar$"
)
GEYSER_RE = re.compile(
    r"^https://download\.geysermc\.org/v2/projects/(?P<project>[^/]+)/"
    r"versions/(?P<version>[^/]+)/builds/(?P<build>\d+)/downloads/(?P<platform>[^/]+)$"
)
MODRINTH_RE = re.compile(
    r"^https://cdn\.modrinth\.com/data/(?P<project>[^/]+)/"
    r"versions/(?P<version>[^/]+)/(?P<filename>[^/]+)$"
)
VERSION_NUMBER_RE = re.compile(r"\d+(?:\.\d+)*")


@dataclass
class Pin:
    key: str
    url: str
    checksum: str
    start: int
    end: int


@dataclass
class Update:
    url: str
    checksum: str
    old: str
    new: str
    link: str


def parse_pins(hcl_text: str) -> list[Pin]:
    return [
        Pin(m["key"], m["url"], m["checksum"], m.start(), m.end())
        for m in ENTRY_RE.finditer(hcl_text)
    ]


def display_name(key: str) -> str:
    """`plugins/Geyser-Spigot.jar` -> `Geyser`, `paper.jar` -> `paper`."""
    return re.split(r"[-_.]", Path(key).name)[0]


def slug(key: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", Path(key).stem.lower()).strip("-")


def file_shape(filename: str) -> str:
    """Filename with every version number blanked out, to compare release lines."""
    return VERSION_NUMBER_RE.sub("#", filename)


def numeric_prefix(version: str) -> str | None:
    m = VERSION_NUMBER_RE.match(version)
    return m.group(0) if m else None


class Client:
    def __init__(self, user_agent: str):
        self.user_agent = user_agent

    def fetch(self, url: str) -> bytes:
        req = urllib.request.Request(url, headers={"User-Agent": self.user_agent})
        with urllib.request.urlopen(req, timeout=120) as resp:
            return resp.read()

    def json(self, url: str):
        # PaperMC's Fill API embeds raw newlines from commit messages, which
        # strict JSON parsing rejects - see CHANGELOG (minecraft, 2026-09-29).
        return json.loads(self.fetch(url).decode(), strict=False)


def paper_game_version(pins: list[Pin]) -> str:
    for pin in pins:
        m = PAPER_RE.match(pin.url)
        if m:
            return m["version"]
    raise SystemExit("no Paper entry in locals.artifacts - can't tell which game version to target")


def paper_update(client: Client, m: re.Match) -> Update | None:
    version, current = m["version"], int(m["build"])
    build = client.json(f"https://fill.papermc.io/v3/projects/paper/versions/{version}/builds/latest")
    if build["channel"] != "STABLE" or build["id"] <= current:
        return None
    download = build["downloads"]["server:default"]
    return Update(
        url=download["url"],
        checksum="sha256:" + download["checksums"]["sha256"],
        old=f"{version} build {current}",
        new=f"{version} build {build['id']}",
        link="https://papermc.io/downloads/paper",
    )


def geyser_update(client: Client, m: re.Match) -> Update | None:
    project, platform, current = m["project"], m["platform"], int(m["build"])
    base = f"https://download.geysermc.org/v2/projects/{project}"
    version = client.json(base)["versions"][-1]
    build = client.json(f"{base}/versions/{version}/builds/latest")
    if build["build"] <= current:
        return None
    return Update(
        url=f"{base}/versions/{version}/builds/{build['build']}/downloads/{platform}",
        checksum="sha256:" + build["downloads"][platform]["sha256"],
        old=f"{m['version']} build {current}",
        new=f"{version} build {build['build']}",
        link="https://geysermc.org/download",
    )


def _published(version: dict) -> datetime:
    return datetime.fromisoformat(version["date_published"].replace("Z", "+00:00"))


def modrinth_update(client: Client, m: re.Match, game_version: str) -> Update | None:
    api = "https://api.modrinth.com/v2"
    current = client.json(f"{api}/version/{m['version']}")
    loaders = ["datapack"] if "datapack" in current["loaders"] else ["paper"]
    query = urllib.parse.urlencode(
        {"loaders": json.dumps(loaders), "game_versions": json.dumps([game_version])}
    )
    candidates = sorted(
        client.json(f"{api}/project/{m['project']}/version?{query}"),
        key=_published,
        reverse=True,
    )
    shape = file_shape(m["filename"])
    for candidate in candidates:
        if candidate["version_type"] != "release":
            continue
        files = [f for f in candidate["files"] if f["primary"]] or candidate["files"]
        if not files or file_shape(files[0]["filename"]) != shape:
            continue
        if _published(candidate) <= _published(current):
            return None
        return Update(
            url=files[0]["url"],
            checksum="sha1:" + files[0]["hashes"]["sha1"],
            old=current["version_number"],
            new=candidate["version_number"],
            link=f"https://modrinth.com/project/{m['project']}/version/{candidate['id']}",
        )
    return None


def resolve(client: Client, pin: Pin, game_version: str) -> Update | None:
    if m := PAPER_RE.match(pin.url):
        return paper_update(client, m)
    if m := GEYSER_RE.match(pin.url):
        return geyser_update(client, m)
    if m := MODRINTH_RE.match(pin.url):
        return modrinth_update(client, m, game_version)
    raise ValueError(f"don't know how to check {pin.url} for updates")


def apply_to_hcl(hcl_text: str, pin: Pin, update: Update) -> str:
    entry = hcl_text[pin.start:pin.end]
    entry = entry.replace(f'"{pin.url}"', f'"{update.url}"', 1)
    entry = entry.replace(f'"{pin.checksum}"', f'"{update.checksum}"', 1)
    return hcl_text[:pin.start] + entry + hcl_text[pin.end:]


def apply_to_readme(readme_text: str, key: str, old: str, new: str) -> tuple[str, bool]:
    """Bumps the version cell of the table row linking `display_name(key)`.

    Tries the full version string first, then just its leading number (the
    README writes BlueMap's `5.28-paper` as `5.28`, Tectonic's
    `3.0.25-datapack` as `3.0.25`).
    """
    name = display_name(key).lower()
    lines = readme_text.splitlines(keepends=True)
    for i, line in enumerate(lines):
        m = re.match(r"\|\s*\[([^\]]+)\]", line)
        if not m or m.group(1).lower() != name:
            continue
        cells = line.split("|")
        for o, n in ((old, new), (numeric_prefix(old), numeric_prefix(new))):
            if o and n and o in cells[2]:
                cells[2] = cells[2].replace(o, n, 1)
                lines[i] = "|".join(cells)
                return "".join(lines), True
        return readme_text, False
    return readme_text, False


def verify_download(client: Client, update: Update) -> None:
    algo, expected = update.checksum.split(":", 1)
    actual = hashlib.new(algo, client.fetch(update.url)).hexdigest()
    if actual != expected:
        raise SystemExit(f"{update.url}: upstream says {algo} {expected}, download is {actual}")


def write_output(name: str, value: str) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with open(path, "a") as f:
        if "\n" in value:
            f.write(f"{name}<<__EOF__\n{value}\n__EOF__\n")
        else:
            f.write(f"{name}={value}\n")


def write_summary(text: str) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a") as f:
            f.write(text + "\n")


def cmd_check(client: Client, pins: list[Pin]) -> int:
    game_version = paper_game_version(pins)
    updates, failed = [], False
    summary = ["| Artifact | Pinned | Available |", "|---|---|---|"]
    for pin in pins:
        try:
            update = resolve(client, pin, game_version)
        except Exception as e:  # keep checking the rest; fail the job at the end
            print(f"::error title={pin.key}::update check failed: {e}")
            summary.append(f"| `{pin.key}` | | check failed: {e} |")
            failed = True
            continue
        if update:
            updates.append({"key": pin.key, "slug": slug(pin.key)})
            summary.append(f"| `{pin.key}` | {update.old} | **{update.new}** |")
            print(f"{pin.key}: {update.old} -> {update.new}")
        else:
            summary.append(f"| `{pin.key}` | up to date | |")
            print(f"{pin.key}: up to date")
    write_summary(f"### Minecraft artifacts (game version {game_version})\n\n" + "\n".join(summary))
    write_output("updates", json.dumps(updates))
    print(json.dumps(updates))
    return 1 if failed else 0


def cmd_apply(client: Client, pins: list[Pin], key: str, hcl_path: Path, readme_path: Path) -> int:
    pin = next((p for p in pins if p.key == key), None)
    if pin is None:
        raise SystemExit(f"no entry {key!r} in locals.artifacts")

    update = resolve(client, pin, paper_game_version(pins))
    if update is None:
        print(f"{key}: already up to date")
        write_output("changed", "false")
        return 0

    verify_download(client, update)

    hcl_path.write_text(apply_to_hcl(hcl_path.read_text(), pin, update))
    readme, readme_updated = apply_to_readme(readme_path.read_text(), key, update.old, update.new)
    readme_path.write_text(readme)

    name = display_name(key)
    title = f"minecraft: bump {name} {update.old} -> {update.new}"
    body = [
        f"Bumps `{key}` in `minecraft/minecraft.nomad.hcl` from **{update.old}** to **{update.new}**.",
        "",
        f"- Release: {update.link}",
        f"- Checksum: `{update.checksum}`, from the upstream API and re-verified against a fresh "
        "download. Nomad verifies it again when the task starts.",
    ]
    if not readme_updated:
        body.append(
            f"- :warning: Couldn't find the version in `minecraft/README.md`'s row for {name}, "
            "so the README still shows the old one. Fix it by hand before merging."
        )
    if key.startswith("world/datapacks/"):
        body.append("- Terrain datapack: changes only affect chunks generated after the deploy.")
    body += ["", "Opened by `.github/workflows/minecraft-updates.yml`. Merging does not deploy."]

    write_output("changed", "true")
    write_output("title", title)
    write_output("branch", f"minecraft-artifacts/{slug(key)}")
    write_output("body", "\n".join(body))
    print(title)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--hcl", type=Path, default=DEFAULT_HCL)
    parser.add_argument("--readme", type=Path, default=DEFAULT_README)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("check")
    apply = sub.add_parser("apply")
    apply.add_argument("--key", required=True)
    args = parser.parse_args()

    hcl_text = args.hcl.read_text()
    ua = USER_AGENT_RE.search(hcl_text)
    client = Client(ua.group(1) if ua else "cosmonautical-nomad-jobs/1.0")
    pins = parse_pins(hcl_text)

    if args.command == "check":
        return cmd_check(client, pins)
    return cmd_apply(client, pins, args.key, args.hcl, args.readme)


if __name__ == "__main__":
    sys.exit(main())
