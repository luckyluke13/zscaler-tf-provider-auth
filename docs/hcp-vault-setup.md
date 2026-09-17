# HCP Vault setup

What has to exist on the Vault side for the provider to authenticate to Zscaler. Commands assume
`VAULT_ADDR` and `VAULT_NAMESPACE=admin` (HCP Vault Dedicated) are exported and that you are logged
in with enough privilege to configure the cluster.

## 1. Transit key

Zscaler accepts RS256 client assertions, so the key must be RSA.

```bash
vault secrets enable transit          # if not already enabled

vault write -f transit/keys/zscaler-oneapi type=rsa-2048
# exportable stays false - that is the entire point
```

Export the **public** key and register it on the Zscaler API client (Zidentity -> API clients ->
add public key):

```bash
vault read -field=public_key transit/keys/zscaler-oneapi | jq -r '.["1"].public_key'
# or:
vault read -format=json transit/keys/zscaler-oneapi | jq -r '.data.keys["1"].public_key'
```

If you rotate the key (`vault write -f transit/keys/zscaler-oneapi/rotate`), register the new public
key with Zscaler before letting Terraform use the new version, or pin the old one with
`signing_vault_key_version` until you have.

## 2. Policy

The provider needs exactly one capability:

```bash
vault policy write zscaler-terraform - <<'POLICY'
path "transit/sign/zscaler-oneapi" {
  capabilities = ["update"]
}
POLICY
```

## 3. Workload identity login

For Terraform running in Kubernetes (including HCP Terraform agents and CI runners with a projected
token), the JWT auth method turns the workload's identity token into a Vault token:

```bash
vault auth enable jwt

vault write auth/jwt/config \
    oidc_discovery_url="https://kubernetes.default.svc.cluster.local" \
    oidc_discovery_ca_pem=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

vault write auth/jwt/role/zscaler-terraform \
    role_type="jwt" \
    bound_audiences="vault" \
    user_claim="sub" \
    bound_subject="system:serviceaccount:terraform:terraform-runner" \
    policies="zscaler-terraform" \
    ttl="1h"
```

Provider configuration:

```hcl
signing_url             = "https://<cluster>.vault.<id>.hashicorp.cloud:8200/v1/transit/sign/zscaler-oneapi"
signing_vault_namespace = "admin"
signing_auth_method     = "vault_jwt"
signing_vault_role      = "zscaler-terraform"
signing_jwt_token_file  = "/var/run/secrets/tokens/vault-token"
```

The token file is re-read on every login, so a projected token that the kubelet rotates keeps
working across long applies.

For the Kubernetes auth method instead of JWT, the login request is identical - just point at it:

```hcl
signing_auth_method = "vault_jwt"
signing_auth_mount  = "kubernetes"
```

Where no workload identity exists (a laptop, a runner with a static credential), use AppRole:

```hcl
signing_auth_method = "vault_approle"
signing_role_id     = var.vault_role_id
signing_secret_id   = var.vault_secret_id
```

or a plain token via `VAULT_TOKEN`.

## 4. Check it by hand

The exact call the provider makes:

```bash
vault write transit/sign/zscaler-oneapi \
    input="$(printf 'header.claims' | base64)" \
    hash_algorithm=sha2-256 \
    signature_algorithm=pkcs1v15 \
    prehashed=false
```

A `signature` of the form `vault:v1:...` means the Vault side is ready.
