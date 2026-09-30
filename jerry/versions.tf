terraform {
  required_version = ">= 1.5.0"

  required_providers {
    nomad = {
      source  = "hashicorp/nomad"
      version = "~> 2.0"
    }
  }

  backend "consul" {
    address = "127.0.0.1:8500"
    path    = "nomad-jobs/discord-bot"
  }
}

provider "nomad" {
  address = "http://127.0.0.1:4646"
}
