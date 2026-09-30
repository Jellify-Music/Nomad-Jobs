resource "nomad_job" "jellify" {
  jobspec = file("${path.module}/jerry.nomad.hcl")
}
