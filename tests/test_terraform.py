"""`terraform fmt`/`validate` checks - no state, no provider credentials needed."""
import shutil
import subprocess

import pytest

pytestmark = pytest.mark.skipif(
    shutil.which("terraform") is None, reason="terraform binary not found on PATH"
)


def test_fmt_is_clean(repo_root):
    result = subprocess.run(
        ["terraform", "fmt", "-check", "-recursive"],
        cwd=repo_root,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, (
        "terraform fmt found unformatted file(s) - run `terraform fmt -recursive` "
        f"and commit the result:\n{result.stdout}{result.stderr}"
    )


def test_validate(repo_root, tmp_path):
    # Copy the module into a scratch dir so `-backend=false` init doesn't touch
    # the real Consul-backed state or leave a .terraform/ dir in the working tree.
    workdir = tmp_path / "tf"
    shutil.copytree(
        repo_root,
        workdir,
        ignore=shutil.ignore_patterns(".git", ".terraform", "tests"),
    )

    init = subprocess.run(
        ["terraform", "init", "-backend=false", "-input=false"],
        cwd=workdir,
        capture_output=True,
        text=True,
    )
    assert init.returncode == 0, f"terraform init failed:\n{init.stdout}{init.stderr}"

    result = subprocess.run(
        ["terraform", "validate"],
        cwd=workdir,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, f"terraform validate failed:\n{result.stdout}{result.stderr}"
