resource "nomad_job" "minecraft" {
  jobspec = file("${path.module}/minecraft/minecraft.nomad.hcl")
}

resource "nomad_job" "jellify" {
  jobspec = file("${path.module}/jerry/jerry.nomad.hcl")
}
