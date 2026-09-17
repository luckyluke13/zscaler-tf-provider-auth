# ZIA provider authenticating with a client assertion signed by HCP Vault Transit.
# No private key material is present in the configuration, the state, or the
# environment of the process running Terraform.

terraform {
  required_providers {
    zia = {
      source  = "zscaler/zia"
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

provider "zia" {
  client_id     = var.zscaler_client_id
  vanity_domain = var.zscaler_vanity_domain

  # The Transit sign endpoint of the RSA key whose public half is registered
  # on the Zscaler API client.
  signing_url             = "https://my-cluster.vault.11eb4b5f.hashicorp.cloud:8200/v1/transit/sign/zscaler-oneapi"
  signing_vault_namespace = "admin"

  # Workload identity: the pod's projected service account token is exchanged
  # for a short-lived Vault token. Nothing static is stored.
  signing_auth_method    = "vault_jwt"
  signing_vault_role     = "zscaler-terraform"
  signing_jwt_token_file = "/var/run/secrets/tokens/vault-token"
}

resource "zia_url_categories" "example" {
  super_category    = "USER_DEFINED"
  configured_name   = "Example"
  custom_category   = true
  keywords          = ["example"]
  db_categorized_urls = ["example.com"]
  type              = "URL_CATEGORY"
}
