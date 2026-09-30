resource "nomad_job" "minecraft" {
  jobspec = file("${path.module}/minecraft/minecraft.nomad.hcl")
}

resource "nomad_job" "jellify" {
  jobspec = file("${path.module}/jerry/jerry.nomad.hcl")
}

resource "nomad_job" "valheim" {
  jobspec = file("${path.module}/valheim/valheim.nomad.hcl")
}

resource "nomad_job" "actions-runner" {
  jobspec = file("${path.module}/actions-runner/actions-runner.nomad.hcl")
}
