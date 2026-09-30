terraform {
  required_version = ">= 1.5.0"

  required_providers {
    nomad = {
      source  = "hashicorp/nomad"
      version = "~> 2.0"
    }
  }

  # Consul is shared cluster-wide (ACLs disabled) - jellify's own Consul
  # agents retry_join the same datacenter, confirmed in this job's own
  # operational history - so it doubles as state storage here too, with no
  # new infra. State for this job lives under its own key prefix, separate
  # from every other job's state.
  backend "consul" {
    address = "127.0.0.1:8500"
    path    = "nomad-jobs/minecraft"
  }
}

# minecraft's "jellify" datacenter and Semaphore's own datacenter are both
# part of the same single Nomad region/cluster - so 127.0.0.1:4646 resolves
# correctly wherever Semaphore's Terraform task actually lands, and reaches
# every datacenter's jobs through that same API, no per-datacenter address
# needed.
provider "nomad" {
  address = "http://127.0.0.1:4646"
}
