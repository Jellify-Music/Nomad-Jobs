resource "nomad_job" "this" {
  jobspec = file(var.jobspec_path)
}
