# Any HTTP signing service, and Azure Key Vault, using the same attributes.

# 1. A generic signing endpoint. The provider POSTs
#    {"alg":"RS256","key_id":...,"signing_input":...,"digest":...,"digest_algorithm":"SHA-256"}
#    and reads the signature from "signature", "data.signature", "value" or "result".
provider "zia" {
  alias         = "generic"
  client_id     = var.zscaler_client_id
  vanity_domain = var.zscaler_vanity_domain

  signing_url         = "https://signing.internal.example.com/v1/zscaler/sign"
  signing_mode        = "http"
  signing_auth_method = "token"
  signing_token       = var.signing_service_token # sent as Authorization: Bearer
}

# 2. Azure Key Vault or Managed HSM. The AAD access token goes in signing_token;
#    the key stays non-exportable in the vault.
provider "zia" {
  alias         = "keyvault"
  client_id     = var.zscaler_client_id
  vanity_domain = var.zscaler_vanity_domain

  signing_url            = "https://my-vault.vault.azure.net/keys/zscaler-oneapi/9f8c/sign?api-version=7.4"
  signing_mode           = "http"
  signing_request_format = "azure_keyvault"
  signing_token          = var.entra_access_token
}

# 3. A service that mints the whole assertion: the provider posts the claims and
#    expects {"assertion": "<jwt>"} back.
provider "zia" {
  alias         = "assertion_service"
  client_id     = var.zscaler_client_id
  vanity_domain = var.zscaler_vanity_domain

  signing_url             = "https://signing.internal.example.com/v1/zscaler/assertion"
  signing_mode            = "http"
  signing_response_format = "jwt"
  signing_headers = {
    "X-Api-Key" = var.signing_service_api_key
  }
}
