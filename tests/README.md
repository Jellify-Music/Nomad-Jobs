# Tests

Validation for this repo's Terraform config and Nomad job specs - no live
cluster access needed, everything here is self-contained.

```sh
pip install -r tests/requirements.txt
pytest tests/ -v
```

Requires `terraform` and `nomad` on `PATH`. Either one missing just skips its
tests rather than failing the run (handy for a quick local check), but both
are installed in CI (see `../.github/workflows/validate.yml`) so nothing is
silently skipped there.

- **`test_terraform.py`** - `terraform fmt -check` and `terraform validate`
  (`-backend=false`, so it never touches the real Consul-backed state).
- **`test_job_validate.py`** - `nomad job validate` against every
  `*/*.nomad.hcl`, run against a throwaway `nomad agent -dev` that the
  `nomad_addr` fixture in `conftest.py` starts and tears down per test
  session. This is real schema validation (bad blocks, unknown attributes,
  etc.), not just HCL syntax - `terraform validate` can't do this since
  Terraform treats `jobspec` as an opaque string.
- **`test_conventions.py`** - the repo's own written rules that nothing else
  enforces: every job directory has a README, is linked from the top-level
  README, has a matching `main.tf` resource (labeled after the job ID, not
  the directory), has no hardcoded secret where a Consul KV reference
  belongs, and documents every `{{ key "..." }}` it references.
