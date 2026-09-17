# Zscaler Terraform providers: sign the OAuth2 client assertion remotely

This repository holds a proposed change to the Zscaler ZIA and ZPA Terraform providers (and the
Go SDK underneath them) that lets the provider authenticate to OneAPI **without ever holding the
raw private key**. Instead of `private_key`, you point the provider at a signing endpoint - an HCP
Vault Transit key, a cloud KMS, or any HTTP signing service - and the provider sends the assertion
there to be signed before presenting it to Zscaler.

The motivation: keys generated in a key vault have to be marked exportable today, purely because
the provider insists on the key material itself. Nothing about the protocol requires that.

## Why this works

OneAPI's private-key mode is the standard OAuth2 `client_credentials` flow with a JWT bearer client
assertion (RFC 7523). The assertion is a short-lived token that the *client* mints:

```
POST https://<vanity>.zslogin.net/oauth2/v1/token
  grant_type=client_credentials
  client_id=<client id>
  client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer
  client_assertion=<base64url(header)>.<base64url(claims)>.<signature>
```

Only the last segment needs the private key. The header and claims are assembled locally, so the
signature can be produced by whatever holds the key:

```
provider                     signing service (HCP Vault)        Zscaler Zidentity
   |                                   |                                |
   | build header.claims               |                                |
   |---- POST transit/sign/<key> ----->|                                |
   |     {input: base64(header.claims)}| signs with the non-exportable  |
   |<--- {signature: vault:v1:...} ----|  RSA key                       |
   | assemble the assertion            |                                |
   |------------- POST /oauth2/v1/token (client_assertion) ------------>|
   |<------------------------- access_token ----------------------------|
```

The assertion claims are byte-for-byte the ones the current local-key path produces
(`iss`, `sub`, `aud`, `exp`), so Zscaler sees no difference.

## What changed

Three repositories are involved. The signing happens in the shared SDK, so the SDK carries the
implementation and each provider only exposes the configuration.

### `zscaler-sdk-go` - `patches/zscaler-sdk-go.patch`

| File | Change |
|------|--------|
| `zscaler/remotesign/remotesign.go` | New package. `Signer` interface, configuration, assertion assembly, signature decoding. |
| `zscaler/remotesign/vault.go` | Vault Transit signing plus Vault login (static token, JWT/OIDC workload identity, AppRole), with token caching and re-login on a rejected token. |
| `zscaler/remotesign/http.go` | Generic JSON signing endpoint, including the Azure Key Vault request shape and a mode for services that return a whole assertion. |
| `zscaler/oneapisigning.go` | New. Wires the signer into the OAuth2 flow (`authenticateWithSigner`), merges yaml/env/programmatic settings, adds `WithSigningConfig`, `WithSigningURL` and `WithSigner`. |
| `zscaler/oneapiclient.go` | `Configuration.Zscaler.Client.Signing` settings, `Signer` field, and the branch in `Authenticate` that uses the signer. |

It also fixes a bug it would otherwise inherit: `authenticateWithCert` never set `AuthToken.Expiry`,
so the token-renewal ticker had nothing to schedule against and a private-key session kept using an
expired token. Both key paths now set the expiry from `expires_in`.

### `terraform-provider-zia` / `terraform-provider-zpa` - `patches/terraform-provider-z{ia,pa}.patch`

| File | Change |
|------|--------|
| `z{ia,pa}/signing.go` | New. The `signing_*` provider attributes, their environment fallbacks, and the mapping into the SDK configuration. |
| `z{ia,pa}/provider.go` | Registers those attributes; `signing_url` conflicts with `private_key` and `client_secret`. |
| `z{ia,pa}/config.go` | New authentication branch: `client_id` + `signing_url` + `vanity_domain` (+ `customer_id` for ZPA). |
| `docs/index.md` | Documents the new authentication mode and every attribute. |

Nothing changes for existing configurations: `client_secret` and `private_key` behave exactly as
before, and no attribute became required.

## Using it

```hcl
provider "zia" {
  client_id     = var.zscaler_client_id
  vanity_domain = var.zscaler_vanity_domain

  # HCP Vault Dedicated, Transit engine, RSA key
  signing_url             = "https://my-cluster.vault.11eb.hashicorp.cloud:8200/v1/transit/sign/zscaler-oneapi"
  signing_vault_namespace = "admin"

  # Workload identity - nothing static is stored
  signing_auth_method    = "vault_jwt"
  signing_vault_role     = "zscaler-terraform"
  signing_jwt_token_file = "/var/run/secrets/tokens/vault-token"
}
```

Everything can come from the environment instead (`ZSCALER_SIGNING_URL`, `VAULT_TOKEN`,
`VAULT_NAMESPACE`, `VAULT_ROLE`, ...). See `examples/` for ZIA and ZPA configurations and
`docs/hcp-vault-setup.md` for the Vault side: Transit key, policy, and JWT auth role.

Other signers are supported too - `docs/design.md` describes the generic HTTP contract, the Azure
Key Vault request shape, and the `remotesign.Signer` interface for plugging in a KMS SDK directly.

## Building and testing it

```bash
scripts/bootstrap.sh   # clone the three upstream repos at pinned commits and apply the patches
scripts/test.sh        # build everything and run the tests
```

`bootstrap.sh` adds a `go mod replace` so the providers build against the patched SDK; upstream
that would be a released SDK version instead, which is why the patches themselves leave `go.mod`
alone.

### What the tests cover

The tests are hermetic - they stand up a fake Vault Transit engine and a fake Zscaler OAuth2
provider, so no real credentials are needed:

- **`zscaler/remotesign`** - Vault Transit request shape (`pkcs1v15` / `sha2-256`, `prehashed:false`,
  pinned key version), namespace and token headers, workload-identity login with token caching and
  re-login after a `403`, AppRole login, short-lease handling, the generic HTTP contract, the Azure
  Key Vault request shape, signature decoding across `vault:v1:` prefixes / base64 / base64url / hex,
  response field discovery, custom headers, context cancellation, and the configuration validation
  errors.
- **`zscaler` (SDK)** - the full authentication path: the fake Zscaler endpoint verifies the RS256
  signature of the assertion against the public key and checks `iss`/`sub`/`aud`, then issues a
  token. Also covers no secret being sent, the expiry being set from `expires_in`, a caller-supplied
  signer winning over a stale private key, and signing failures surfacing as authentication errors.
- **providers** - the attributes are registered and mutually exclusive with `private_key` /
  `client_secret`, sensitive values are marked sensitive, attribute and environment precedence, the
  mapping into the SDK configuration, and that the produced configuration is accepted by the SDK.

### What I could not verify

- **No real Zscaler tenant and no real Vault cluster.** The protocol shapes come from the upstream
  code and from HashiCorp's and Microsoft's documented APIs, and are exercised against fakes. The
  end-to-end run against your HCP Vault cluster and your Zidentity tenant is the part left to you.
- **`TestProviderValidate/valid_client_id_+_client_secret`** already fails on unmodified upstream in
  both providers (it needs `ZSCALER_VANITY_DOMAIN` in the environment). It fails identically before
  and after the patch; `scripts/test.sh` runs the targeted tests to keep that noise out.

## Upstreaming

Three pull requests, in order: the SDK first, then each provider once a release containing the SDK
change exists. The provider patches only depend on the SDK's exported API
(`zscaler.WithSigningConfig` and the `remotesign` package).
