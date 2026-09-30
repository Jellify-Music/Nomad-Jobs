"""Repo-convention checks from README.md / .agents/AGENTS.md that nothing else
enforces: every job needs a README, needs to be linked from the top-level
README, needs a matching `main.tf` resource, and must never commit a literal
secret instead of a Consul KV reference.
"""
import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent

# Jobs intentionally exempt from the "must have a main.tf resource" check,
# keyed by job directory name, with why. Keep empty unless a job has a
# documented, deliberate exception (see that job's own README/CHANGELOG).
NO_MAIN_TF_RESOURCE_EXEMPT: dict[str, str] = {}

JOB_HCL_FILES = sorted(REPO_ROOT.glob("*/*.nomad.hcl"))
JOB_DIRS = [p.parent for p in JOB_HCL_FILES]
JOB_DIR_IDS = [d.name for d in JOB_DIRS]


@pytest.mark.parametrize("job_dir", JOB_DIRS, ids=JOB_DIR_IDS)
def test_job_has_readme(job_dir):
    assert (job_dir / "README.md").is_file(), (
        f"{job_dir.name}/ has no README.md - every job directory needs one, "
        "per .agents/AGENTS.md's 'Adding a new job' checklist"
    )


def test_top_level_readme_lists_every_job():
    top_readme = (REPO_ROOT / "README.md").read_text()
    missing = [d.name for d in JOB_DIRS if f"]({d.name})" not in top_readme]
    assert not missing, (
        f"README.md's Jobs section doesn't link to: {missing} - add a bullet "
        "pointing at each job's directory"
    )


JOB_ID_RE = re.compile(r'^job\s+"([^"]+)"\s*\{', re.MULTILINE)


def _job_id(hcl_path: Path) -> str:
    match = JOB_ID_RE.search(hcl_path.read_text())
    assert match, f"couldn't find a top-level `job \"...\" {{` block in {hcl_path}"
    return match.group(1)


MAIN_TF_RESOURCE_RE = re.compile(
    r'resource\s+"nomad_job"\s+"([^"]+)"\s*\{\s*jobspec\s*=\s*file\("\$\{path\.module\}/([^"]+)"\)'
)


def _main_tf_resources() -> dict[str, str]:
    """Returns {relative jobspec path: resource label} parsed from main.tf."""
    text = (REPO_ROOT / "main.tf").read_text()
    return {path: label for label, path in MAIN_TF_RESOURCE_RE.findall(text)}


@pytest.mark.parametrize("hcl_path", JOB_HCL_FILES, ids=JOB_DIR_IDS)
def test_job_wired_into_main_tf(hcl_path):
    job_dir_name = hcl_path.parent.name
    if job_dir_name in NO_MAIN_TF_RESOURCE_EXEMPT:
        pytest.skip(NO_MAIN_TF_RESOURCE_EXEMPT[job_dir_name])

    resources = _main_tf_resources()
    rel_path = str(hcl_path.relative_to(REPO_ROOT))
    assert rel_path in resources, (
        f"main.tf has no `nomad_job` resource loading {rel_path} - see "
        "README's 'Adding a new job' snippet"
    )

    job_id = _job_id(hcl_path)
    label = resources[rel_path]
    assert label == job_id, (
        f'main.tf\'s resource label "{label}" for {rel_path} doesn\'t match '
        f'the job\'s actual Nomad job ID "{job_id}" - README says the resource '
        "should be named to match the job ID, not the directory"
    )


def test_main_tf_has_no_orphan_resources():
    """Every resource in main.tf should point at a file that actually exists."""
    resources = _main_tf_resources()
    missing = [path for path in resources if not (REPO_ROOT / path).is_file()]
    assert not missing, f"main.tf references jobspec file(s) that don't exist: {missing}"


TEMPLATE_EXPR_RE = re.compile(r"\{\{.*?\}\}")
SECRET_LITERAL_RE = re.compile(
    r'(PASSWORD|SECRET|TOKEN|API_KEY|ACCESS_KEY|PRIVATE_KEY)\s*[:=]\s*"([^"]{3,})"',
    re.IGNORECASE,
)


@pytest.mark.parametrize("hcl_path", JOB_HCL_FILES, ids=JOB_DIR_IDS)
def test_no_hardcoded_secrets(hcl_path):
    """Both Nomad-Jobs repos are public - a credential must be a Consul KV
    reference (`{{ key "..." }}`), never a literal value in the job spec.

    Strips `{{ ... }}` template expressions before matching, so a legitimate
    `TOKEN="{{ key "..." }}"` reference doesn't trip this - the naive grep
    documented in .agents/AGENTS.md does, on every such line in this repo.
    """
    offenders = []
    for lineno, line in enumerate(hcl_path.read_text().splitlines(), start=1):
        stripped = TEMPLATE_EXPR_RE.sub("", line)
        if SECRET_LITERAL_RE.search(stripped):
            offenders.append(f"{hcl_path}:{lineno}: {line.strip()}")
    assert not offenders, "hardcoded secret-shaped literal(s) found:\n" + "\n".join(offenders)


CONSUL_KEY_RE = re.compile(r'\{\{\s*key\s+"([^"]+)"\s*\}\}')


@pytest.mark.parametrize("hcl_path", JOB_HCL_FILES, ids=JOB_DIR_IDS)
def test_consul_kv_keys_documented_in_readme(hcl_path):
    """Every `{{ key "..." }}` reference should be documented in that job's
    README (its 'Consul KV keys' table, by convention) - just needs to appear
    somewhere in the README, not match an exact table row.
    """
    keys = sorted(set(CONSUL_KEY_RE.findall(hcl_path.read_text())))
    if not keys:
        return

    readme_path = hcl_path.parent / "README.md"
    assert readme_path.is_file(), f"{hcl_path} references Consul KV keys but has no README.md"

    readme_text = readme_path.read_text()
    missing = [k for k in keys if k not in readme_text]
    assert not missing, (
        f"{readme_path} doesn't document these Consul KV keys referenced in "
        f"{hcl_path.name}: {missing}"
    )
