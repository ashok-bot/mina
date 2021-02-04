terraform {
  required_version = "~> 0.12.0"
  backend "s3" {
    key     = "terraform-ci-net.tfstate"
    encrypt = true
    region  = "us-west-2"
    bucket  = "o1labs-terraform-state"
    acl     = "bucket-owner-full-control"
  }
}

provider "aws" {
  region = "us-west-2"
}

provider "google" {
  alias   = "google-us-east4"
  project = "o1labs-192920"
  region  = "us-east4"
  zone    = "us-east4-b"
}

variable "coda_image" {
  type = string

  description = "Mina daemon image to use in provisioning a ci-net"
  default     = "gcr.io/o1labs-192920/coda-daemon:0.2.11-develop"
}

variable "coda_archive_image" {
  type = string

  description = "Mina archive node image to use in provisioning a ci-net"
  default     = "gcr.io/o1labs-192920/coda-archive:0.2.11-develop"
}

variable "whale_count" {
  type    = number
  default = 1
}

variable "fish_count" {
  type    = number
  default = 1
}

variable "archive_count" {
  type    = number
  default = 1
}

variable "snark_worker_count" {
  type    = number
  default = 1
}

variable "ci_cluster_region" {
  type    = string
  default = "us-west1"
}

variable "ci_k8s_ctx" {
  type    = string
  default = "gke_o1labs-192920_us-west1_mina-integration-west1"
}

variable "ci_artifact_path" {
  type    = string
  default = "/tmp"
}

locals {
  seed_region = "us-west1"
  seed_zone = "us-west1-b"
}


module "ci_testnet" {
  providers = { google = google.google-us-east4 }
  source    = "../../modules/kubernetes/testnet"

  # TODO: remove obsolete cluster_name var + cluster region
  cluster_name          = "mina-integration-west1"
  cluster_region        = var.ci_cluster_region
  k8s_context           = var.ci_k8s_ctx
  testnet_name          = "${terraform.workspace}-ci-net"

  coda_image            = var.coda_image
  coda_archive_image    = var.coda_archive_image
  coda_agent_image      = "codaprotocol/coda-user-agent:0.1.8"
  coda_bots_image       = "codaprotocol/bots:1.0.0"
  coda_points_image     = "codaprotocol/coda-points-hack:32b.4"

  coda_faucet_amount    = "10000000000"
  coda_faucet_fee       = "100000000"

  archive_node_count    = var.archive_count
  mina_archive_schema   = "https://raw.githubusercontent.com/MinaProtocol/mina/develop/src/app/archive/create_schema.sql"

  additional_seed_peers = []

  seed_zone = local.seed_zone
  seed_region = local.seed_region

  log_level              = "Info"
  log_txn_pool_gossip    = false

  block_producer_key_pass = "naughty blue worm"
  block_producer_starting_host_port = 10501

  whale_count = var.whale_count
  fish_count = var.fish_count

  block_producer_configs = concat(
    [
      for i in range(var.whale_count): {
        name                   = "whale-block-producer-${i + 1}"
        class                  = "whale"
        id                     = i + 1
        private_key_secret     = "online-whale-account-${i + 1}-key"
        libp2p_secret          = "online-whale-libp2p-${i + 1}-key"
        enable_gossip_flooding = false
        run_with_user_agent    = false
        run_with_bots          = false
        enable_peer_exchange   = true
        isolated               = false
      }
    ],
    [
      for i in range(var.fish_count): {
        name                   = "fish-block-producer-${i + 1}"
        class                  = "fish"
        id                     = i + 1
        private_key_secret     = "online-fish-account-${i + 1}-key"
        libp2p_secret          = "online-fish-libp2p-${i + 1}-key"
        enable_gossip_flooding = false
        run_with_user_agent    = true
        run_with_bots          = false
        enable_peer_exchange   = true
        isolated               = false
      }
    ]
  )

  snark_worker_replicas = var.snark_worker_count
  snark_worker_fee      = "0.025"
  snark_worker_public_key = "B62qk4nuKn2U5kb4dnZiUwXeRNtP1LncekdAKddnd1Ze8cWZnjWpmMU"
  snark_worker_host_port = 10401

  agent_min_fee = "0.05"
  agent_max_fee = "0.1"
  agent_min_tx = "0.0015"
  agent_max_tx = "0.0015"
  agent_send_every_mins = "1"

  artifact_path = var.ci_artifact_path
}
