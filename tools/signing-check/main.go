// Command signing-check mints a Zscaler OneAPI client assertion against a real
// signing service and, when the key's public half can be read back, verifies the
// signature locally. It never talks to Zscaler, so it can be run against a
// production Vault cluster without touching a Zidentity tenant.
//
//	scripts/signing-check.sh
//
// Configuration comes from the same environment variables the provider reads:
//
//	ZSCALER_SIGNING_URL       (required) e.g. https://vault:8200/v1/transit/sign/zscaler-oneapi
//	ZSCALER_CLIENT_ID         (optional) defaults to a placeholder
//	VAULT_TOKEN / ZSCALER_SIGNING_TOKEN
//	VAULT_NAMESPACE / ZSCALER_SIGNING_NAMESPACE
//	VAULT_ROLE / ZSCALER_SIGNING_ROLE, VAULT_JWT_TOKEN_FILE / ZSCALER_SIGNING_JWT_TOKEN_FILE
//	VAULT_ROLE_ID / VAULT_SECRET_ID
//	ZSCALER_SIGNING_MODE, ZSCALER_SIGNING_KEY_ID, ZSCALER_SIGNING_KEY_VERSION
package main

import (
	"context"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/zscaler/zscaler-sdk-go/v3/zscaler/remotesign"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "\nFAILED: %v\n", err)
		os.Exit(1)
	}
}

func env(names ...string) string {
	for _, name := range names {
		if value := os.Getenv(name); value != "" {
			return value
		}
	}
	return ""
}

func run() error {
	config := remotesign.Config{
		URL:          env("ZSCALER_SIGNING_URL"),
		Mode:         env("ZSCALER_SIGNING_MODE"),
		KeyID:        env("ZSCALER_SIGNING_KEY_ID"),
		Token:        env("ZSCALER_SIGNING_TOKEN", "VAULT_TOKEN"),
		AuthMethod:   env("ZSCALER_SIGNING_AUTH_METHOD"),
		AuthMount:    env("ZSCALER_SIGNING_AUTH_MOUNT"),
		Role:         env("ZSCALER_SIGNING_ROLE", "VAULT_ROLE"),
		JWT:          env("ZSCALER_SIGNING_JWT"),
		JWTTokenFile: env("ZSCALER_SIGNING_JWT_TOKEN_FILE", "VAULT_JWT_TOKEN_FILE"),
		RoleID:       env("ZSCALER_SIGNING_ROLE_ID", "VAULT_ROLE_ID"),
		SecretID:     env("ZSCALER_SIGNING_SECRET_ID", "VAULT_SECRET_ID"),
		Namespace:    env("ZSCALER_SIGNING_NAMESPACE", "VAULT_NAMESPACE"),
		VaultAddress: env("ZSCALER_SIGNING_VAULT_ADDRESS", "VAULT_ADDR"),
	}
	if config.URL == "" {
		return fmt.Errorf("set ZSCALER_SIGNING_URL to the signing endpoint")
	}
	if raw := env("ZSCALER_SIGNING_KEY_VERSION"); raw != "" {
		version, err := strconv.Atoi(raw)
		if err != nil {
			return fmt.Errorf("ZSCALER_SIGNING_KEY_VERSION: %w", err)
		}
		config.KeyVersion = version
	}

	clientID := env("ZSCALER_CLIENT_ID")
	if clientID == "" {
		clientID = "signing-check-client-id"
	}

	fmt.Printf("signing endpoint : %s\n", config.URL)
	fmt.Printf("auth method      : %s\n", config.AuthMethod)
	if config.Namespace != "" {
		fmt.Printf("vault namespace  : %s\n", config.Namespace)
	}

	signer, err := remotesign.New(config)
	if err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	start := time.Now()
	assertion, err := remotesign.BuildAssertion(ctx, signer, remotesign.AssertionParams{
		ClientID: clientID,
		Audience: "https://api.zscaler.com",
		KeyID:    config.KeyID,
	})
	if err != nil {
		return err
	}
	fmt.Printf("\nassertion minted in %s\n", time.Since(start).Round(time.Millisecond))

	segments := strings.Split(assertion, ".")
	if len(segments) != 3 {
		return fmt.Errorf("the assertion does not have three segments")
	}
	for label, segment := range map[string]string{"header": segments[0], "claims": segments[1]} {
		decoded, err := base64.RawURLEncoding.DecodeString(segment)
		if err != nil {
			return fmt.Errorf("decoding the %s: %w", label, err)
		}
		fmt.Printf("%-7s: %s\n", label, decoded)
	}
	signature, err := base64.RawURLEncoding.DecodeString(segments[2])
	if err != nil {
		return fmt.Errorf("decoding the signature: %w", err)
	}
	fmt.Printf("%-7s: %d bytes\n", "sig", len(signature))

	publicKey, source, err := vaultPublicKey(ctx, config)
	if err != nil {
		fmt.Printf("\nCould not read the public key back (%v).\n", err)
		fmt.Println("The assertion above was produced by the signing service; verify it against the")
		fmt.Println("public key registered on the Zscaler API client to complete the check.")
		return nil
	}

	digest := sha256.Sum256([]byte(segments[0] + "." + segments[1]))
	if err := rsa.VerifyPKCS1v15(publicKey, crypto.SHA256, digest[:], signature); err != nil {
		return fmt.Errorf("the signature does not verify against %s: %w", source, err)
	}
	fmt.Printf("\nOK: the signature verifies against %s.\n", source)
	fmt.Println("Register that public key on the Zscaler API client and the provider will authenticate.")
	return nil
}

// vaultPublicKey reads the public half of a Transit key so the signature can be
// checked locally. It only works in Vault mode and only when the token is
// allowed to read the key.
func vaultPublicKey(ctx context.Context, config remotesign.Config) (*rsa.PublicKey, string, error) {
	index := strings.Index(config.URL, "/v1/")
	if index < 0 || !strings.Contains(config.URL, "/sign/") {
		return nil, "", fmt.Errorf("not a Vault Transit sign URL")
	}
	path := config.URL[index+len("/v1/"):]
	parts := strings.SplitN(path, "/sign/", 2)
	if len(parts) != 2 {
		return nil, "", fmt.Errorf("not a Vault Transit sign URL")
	}
	keyURL := fmt.Sprintf("%s/v1/%s/keys/%s", config.URL[:index], parts[0], strings.SplitN(parts[1], "?", 2)[0])

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, keyURL, nil)
	if err != nil {
		return nil, "", err
	}
	if config.Token != "" {
		request.Header.Set("X-Vault-Token", config.Token)
	}
	if config.Namespace != "" {
		request.Header.Set("X-Vault-Namespace", config.Namespace)
	}

	response, err := (&http.Client{Timeout: 30 * time.Second}).Do(request)
	if err != nil {
		return nil, "", err
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		return nil, "", err
	}
	if response.StatusCode > 299 {
		return nil, "", fmt.Errorf("reading %s returned HTTP %d", keyURL, response.StatusCode)
	}

	var parsed struct {
		Data struct {
			LatestVersion int `json:"latest_version"`
			Keys          map[string]struct {
				PublicKey string `json:"public_key"`
			} `json:"keys"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return nil, "", err
	}

	version := strconv.Itoa(parsed.Data.LatestVersion)
	if config.KeyVersion > 0 {
		version = strconv.Itoa(config.KeyVersion)
	}
	entry, ok := parsed.Data.Keys[version]
	if !ok || entry.PublicKey == "" {
		return nil, "", fmt.Errorf("key version %s has no public key", version)
	}

	block, _ := pem.Decode([]byte(entry.PublicKey))
	if block == nil {
		return nil, "", fmt.Errorf("the public key is not PEM encoded")
	}
	key, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return nil, "", err
	}
	rsaKey, ok := key.(*rsa.PublicKey)
	if !ok {
		return nil, "", fmt.Errorf("the Transit key is not an RSA key; Zscaler requires RS256")
	}
	return rsaKey, fmt.Sprintf("%s (version %s)", keyURL, version), nil
}
