"""Shared fixtures for validating this repo's Terraform config and Nomad job specs."""
import shutil
import socket
import subprocess
import time
import urllib.request
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent


@pytest.fixture(scope="session")
def repo_root() -> Path:
    return REPO_ROOT


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture(scope="session")
def nomad_addr(tmp_path_factory):
    """Starts a throwaway `nomad agent -dev` for the test session.

    `nomad job validate` checks a jobspec's syntax/schema by asking a running
    agent's API, even though nothing here actually gets scheduled - so this
    spins up a disposable local dev agent rather than pointing at the real
    cluster (which isn't reachable from outside it anyway).
    """
    nomad_bin = shutil.which("nomad")
    if nomad_bin is None:
        pytest.skip("nomad binary not found on PATH")

    # Nomad's agent has no `-http-port`-style CLI flag - custom ports only
    # come from a config file's `ports` stanza. Randomizing them (rather than
    # trusting the 4646/4647/4648 dev-mode defaults) avoids colliding with a
    # real Nomad agent that might already be running on the machine this
    # runs on (every cluster host binds those same default ports).
    http_port, rpc_port, serf_port = _free_port(), _free_port(), _free_port()
    addr = f"http://127.0.0.1:{http_port}"
    data_dir = tmp_path_factory.mktemp("nomad-dev")
    config_file = data_dir / "agent.hcl"
    config_file.write_text(
        f"""
        data_dir  = "{data_dir}"
        bind_addr = "127.0.0.1"
        ports {{
          http = {http_port}
          rpc  = {rpc_port}
          serf = {serf_port}
        }}
        """
    )

    proc = subprocess.Popen(
        [nomad_bin, "agent", "-dev", f"-config={config_file}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        deadline = time.monotonic() + 30
        ready = False
        while time.monotonic() < deadline:
            try:
                urllib.request.urlopen(f"{addr}/v1/status/leader", timeout=2)
                ready = True
                break
            except Exception:
                time.sleep(0.5)
        if not ready:
            proc.terminate()
            pytest.fail("nomad agent -dev did not become ready within 30s")
        yield addr
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
