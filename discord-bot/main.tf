resource "nomad_job" "jellify" {
  jobspec = file("${path.module}/jellify.nomad.hcl")
}
