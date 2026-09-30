module "discord_bot" {
  source       = "../modules/nomad-job"
  jobspec_path = "${path.module}/jellify.nomad.hcl"
}
