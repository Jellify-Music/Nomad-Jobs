module "minecraft" {
  source       = "../modules/nomad-job"
  jobspec_path = "${path.module}/minecraft.nomad.hcl"
}
