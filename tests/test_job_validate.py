"""`nomad job validate` against every `.nomad.hcl` in the repo.

Catches real HCL2/jobspec schema errors (bad block nesting, unknown
attributes, invalid `constraint`/`template`/`resources` shapes, etc.) that
`terraform validate` never looks at, since Terraform treats `jobspec` as an
opaque string.
"""
import os
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
JOB_SPECS = sorted(REPO_ROOT.glob("*/*.nomad.hcl"))


@pytest.mark.parametrize(
    "job_spec", JOB_SPECS, ids=[str(p.relative_to(REPO_ROOT)) for p in JOB_SPECS]
)
def test_job_spec_is_valid(job_spec, nomad_addr):
    result = subprocess.run(
        ["nomad", "job", "validate", str(job_spec)],
        env={**os.environ, "NOMAD_ADDR": nomad_addr},
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, (
        f"`nomad job validate {job_spec}` failed:\n{result.stdout}{result.stderr}"
    )
