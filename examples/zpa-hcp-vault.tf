# ZPA provider authenticating with a client assertion signed by HCP Vault Transit.

terraform {
  required_providers {
    zpa = {
      source  = "zscaler/zpa"
      version = "~> 4.0"
    }
  }
}

variable "zscaler_client_id" {
  type = string
}

variable "zscaler_vanity_domain" {
  type = string
}

variable "zpa_customer_id" {
  type = string
}

provider "zpa" {
  client_id     = var.zscaler_client_id
  vanity_domain = var.zscaler_vanity_domain
  customer_id   = var.zpa_customer_id

  signing_url             = "https://my-cluster.vault.11eb4b5f.hashicorp.cloud:8200/v1/transit/sign/zscaler-oneapi"
  signing_vault_namespace = "admin"

  signing_auth_method    = "vault_jwt"
  signing_vault_role     = "zscaler-terraform"
  signing_jwt_token_file = "/var/run/secrets/tokens/vault-token"
}

resource "zpa_segment_group" "example" {
  name        = "Example Segment Group"
  description = "Example Segment Group"
  enabled     = true
}
