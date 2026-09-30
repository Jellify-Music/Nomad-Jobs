resource "nomad_job" "minecraft" {
  jobspec = file("${path.module}/minecraft.nomad.hcl")
}
