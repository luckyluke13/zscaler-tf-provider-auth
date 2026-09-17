# Design notes

## Where the change belongs

The ZIA and ZPA providers do not sign anything themselves - they hand credentials to
`zscaler-sdk-go`, which performs the OAuth2 handshake inside `zscaler.NewOneAPIClient`. The signing
happens in `Authenticate` -> `authenticateWithCert`, which parses the PEM private key and calls
`token.SignedString(privateKey)`.

So a provider-only change is impossible: the SDK carries the new signing path, and the providers
only translate provider attributes into SDK configuration. That also means every other consumer of
the SDK (ZCC, ZDX, ZTW, ZWA, the `zscaler.yaml` file, direct SDK users) gets the feature for free.

## Trust boundary

The signing service sees the assertion header and claims - `iss`, `sub`, `aud`, `exp`, all of which
are public knowledge about the API client - and returns a signature. It never sees a Zscaler
credential, and the provider never sees the private key. A compromised signing endpoint can mint
assertions for the client it holds the key for, which is exactly the authority the key itself has;
that is the property that makes the key non-exportable worthwhile.

The assertion lifetime stays at 10 minutes, matching the local-key path, and one assertion is minted
per token acquisition (roughly once an hour, plus once per renewal), so the signing service is on a
cold path.

## Interfaces

```go
// The only thing a signing backend has to do.
type Signer interface {
    Sign(ctx context.Context, signingInput []byte) (signature []byte, err error)
}

// Optional: for services that mint the whole assertion themselves.
type AssertionSigner interface {
    SignAssertion(ctx context.Context, claims map[string]interface{}, keyID string) (string, error)
}
```

`remotesign.BuildAssertion` assembles `header.claims`, calls `Sign`, and appends the base64url
signature. `zscaler.WithSigner` accepts any `Signer`, so a caller who wants to sign through, say,
the AWS KMS or Azure Key Vault SDK can do so without this module depending on those SDKs.

Only RS256 is implemented, because that is the only algorithm the Zscaler token endpoint accepts
for a client assertion today. Adding PS256 or ES256 later is a matter of extending the request the
Vault/HTTP signer sends and the JOSE header it writes.

## Transports

### Vault Transit (`signing_mode = "vault_transit"`, inferred from a `/v1/<mount>/sign/<key>` URL)

```
POST {signing_url}
X-Vault-Token: <token>
X-Vault-Namespace: admin            # HCP Vault Dedicated
{
  "input": "<base64(header.claims)>",
  "hash_algorithm": "sha2-256",
  "signature_algorithm": "pkcs1v15",
  "prehashed": false,
  "key_version": 2                  # only when pinned
}
-> {"data": {"signature": "vault:v1:<base64 signature>"}}
```

Vault hashes the input itself (`prehashed: false`), so the provider sends the signing input rather
than a digest and Vault's audit log records exactly what was signed.

Authentication to Vault is one of:

| `signing_auth_method` | Flow |
|---|---|
| `token` | `X-Vault-Token` from `signing_token` / `VAULT_TOKEN`. |
| `vault_jwt` | `POST /v1/auth/<mount>/login {role, jwt}`. The JWT is read from `signing_jwt_token_file` on every login, so rotated projected tokens keep working. Use `signing_auth_mount = "kubernetes"` for the Kubernetes auth method - same request shape. |
| `vault_approle` | `POST /v1/auth/approle/login {role_id, secret_id}`. |
| `none` | No credential, for endpoints protected by mTLS or network policy. |

The Vault token is cached until `lease_duration` minus a 60 second skew. A `401`/`403` from the sign
endpoint triggers exactly one re-login and retry, which covers a lease revoked between two token
renewals. The Vault base address for login calls is derived from the signing URL by cutting at
`/v1/`, or set explicitly with `signing_vault_address`.

### Generic HTTP (`signing_mode = "http"`)

```
POST {signing_url}
Authorization: Bearer <signing_token>          # unless overridden by signing_headers
{
  "alg": "RS256",
  "key_id": "...",
  "signing_input": "<base64url(header.claims)>",
  "digest": "<base64url(sha256(header.claims))>",
  "digest_algorithm": "SHA-256"
}
```

Both the input and its digest are sent so the endpoint can sign whichever it expects, and can log or
inspect what it is being asked to sign. The signature is read from `signature`, `data.signature`,
`value` or `result` (or from `signing_signature_field` when given), and decoded from base64,
base64url or hex, with a `vault:vN:` prefix stripped if present. A non-JSON body is taken verbatim.

`signing_request_format = "azure_keyvault"` sends `{"alg":"RS256","value":"<base64url digest>"}`
instead, which is what `POST {vault}/keys/{name}/{version}/sign?api-version=7.4` expects; the
response's `value` field is picked up by the same lookup. Key Vault needs an Entra ID bearer token,
which goes in `signing_token` or `signing_headers`.

`signing_response_format = "jwt"` is for a service that mints the entire assertion: the provider
posts the claims and expects `{"assertion": "<jwt>"}` (or `client_assertion`, `jwt`, `token`).

## Configuration precedence

1. Provider attributes (`signing_url`, ...).
2. `ZSCALER_SIGNING_*` environment variables, then the Vault-native ones (`VAULT_TOKEN`,
   `VAULT_NAMESPACE`, `VAULT_ADDR`, `VAULT_ROLE`, `VAULT_ROLE_ID`, `VAULT_SECRET_ID`,
   `VAULT_JWT_TOKEN_FILE`).
3. Inside the SDK: programmatic `WithSigningConfig` values, then `zscaler.yaml` / `ZSCALER_SIGNING_*`
   values, merged field by field.

A signer configured explicitly wins over a private key that happens to be in the environment, and
the SDK logs a warning when both are present. At the provider level the two are mutually exclusive
by schema (`ConflictsWith`).

## Failure behaviour

Configuration problems (relative URL, unknown mode, a Vault role without a token) fail in
`NewConfiguration`, before any network call, so `terraform plan` reports them immediately rather
than as an authentication failure. Runtime failures keep the signing service's own message: a Vault
`permission denied` reaches the user as part of the authentication error.
