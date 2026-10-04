"""Offline checks for .github/scripts/minecraft_artifacts.py, the script behind
the Minecraft artifact update workflow. Nothing here touches the network -
the upstream lookups were exercised by hand when the workflow was added.
"""
import importlib.util
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / ".github" / "scripts" / "minecraft_artifacts.py"
HCL = REPO_ROOT / "minecraft" / "minecraft.nomad.hcl"
README = REPO_ROOT / "minecraft" / "README.md"

spec = importlib.util.spec_from_file_location("minecraft_artifacts", SCRIPT)
ma = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ma)

PINS = ma.parse_pins(HCL.read_text())


def test_parses_every_artifact_entry():
    # Every `"<key>" = {` line inside locals.artifacts should parse as a pin;
    # if the table's shape drifts, the updater silently stops tracking entries.
    table = HCL.read_text().split("artifacts = {", 1)[1].split("\n  }\n", 1)[0]
    expected = {line.split('"')[1] for line in table.splitlines() if line.strip().endswith("= {")}
    assert {p.key for p in PINS} == expected
    assert len(PINS) == len(expected) > 0


@pytest.mark.parametrize("pin", PINS, ids=[p.key for p in PINS])
def test_every_pin_has_a_known_upstream(pin):
    assert any(r.match(pin.url) for r in (ma.PAPER_RE, ma.GEYSER_RE, ma.MODRINTH_RE)), (
        f"{pin.key}: the update workflow can't track {pin.url} - add a resolver "
        "to .github/scripts/minecraft_artifacts.py or use a supported source"
    )
    assert pin.checksum.split(":", 1)[0] in {"sha1", "sha256"}


@pytest.mark.parametrize("pin", PINS, ids=[p.key for p in PINS])
def test_every_pin_has_a_readme_row(pin):
    # apply_to_readme finds rows by display name; a bump PR for an entry
    # without one would always carry the "fix the README by hand" warning.
    name = ma.display_name(pin.key).lower()
    rows = [line for line in README.read_text().splitlines() if line.lower().startswith(f"| [{name}](")]
    assert len(rows) == 1, f"minecraft/README.md needs exactly one table row linking [{name}]"


def test_paper_game_version():
    assert ma.paper_game_version(PINS) == "26.2"


def test_file_shape_separates_release_lines():
    assert ma.file_shape("bluemap-5.28-paper.jar") == ma.file_shape("bluemap-5.29-paper.jar")
    assert ma.file_shape("bluemap-5.28-paper.jar") != ma.file_shape("bluemap-5.28-spigot.jar")
    assert ma.file_shape("ViaVersion-5.12.0.jar") != ma.file_shape("ViaVersion-5.12.1-SNAPSHOT.jar")


def test_apply_to_hcl_only_touches_the_target_entry():
    text = HCL.read_text()
    pin = next(p for p in PINS if p.key == "plugins/BlueMap.jar")
    update = ma.Update(url="https://example.invalid/new.jar", checksum="sha1:" + "0" * 40,
                       old="5.28-paper", new="5.29-paper", link="")
    new_text = ma.apply_to_hcl(text, pin, update)

    new_pins = {p.key: p for p in ma.parse_pins(new_text)}
    assert new_pins[pin.key].url == update.url
    assert new_pins[pin.key].checksum == update.checksum
    for other in PINS:
        if other.key != pin.key:
            assert (new_pins[other.key].url, new_pins[other.key].checksum) == (other.url, other.checksum)


@pytest.mark.parametrize(
    "key, old, new, expected",
    [
        ("paper.jar", "26.2 build 129", "26.2 build 130", "| 26.2 build 130 (pinned) |"),
        ("plugins/Geyser-Spigot.jar", "2.11.3 build 1248", "2.11.4 build 1260", "| 2.11.4 build 1260 (pinned) |"),
        ("plugins/BlueMap.jar", "5.28-paper", "5.29-paper", "| 5.29 (Paper build) |"),
        ("world/datapacks/Tectonic.zip", "3.0.25-datapack", "3.0.26-datapack", "| 3.0.26 |"),
    ],
)
def test_apply_to_readme(key, old, new, expected):
    text, updated = ma.apply_to_readme(README.read_text(), key, old, new)
    assert updated
    assert expected in text


def test_apply_to_readme_reports_a_miss():
    text = README.read_text()
    assert ma.apply_to_readme(text, "plugins/Chunky.jar", "9.9.9", "9.9.10") == (text, False)
