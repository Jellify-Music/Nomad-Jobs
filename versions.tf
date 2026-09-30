terraform {
  required_version = ">= 1.5.0"

  required_providers {
    nomad = {
      source  = "hashicorp/nomad"
      version = "~> 2.0"
    }
  }

  # Consul is shared cluster-wide (ACLs disabled), so it doubles as state
  # storage here too, with no new infra. Every job's resource lives in this
  # one state under a single key - see the README for why this repo runs as
  # a single root module instead of one per job.
  backend "consul" {
    address = "127.0.0.1:8500"
    path    = "nomad-jobs"
  }
}

# Every datacenter in the cluster is part of the same single Nomad
# region, so 127.0.0.1:4646 resolves correctly wherever Semaphore's
# Terraform task actually lands, and reaches every datacenter's jobs
# through that same API - no per-datacenter address needed.
provider "nomad" {
  address = "http://127.0.0.1:4646"
}
