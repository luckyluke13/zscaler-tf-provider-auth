#!/usr/bin/env bash
# Mints a client assertion against a real signing service and verifies it
# locally. Requires scripts/bootstrap.sh to have run first.
#
#   export ZSCALER_SIGNING_URL=https://vault.example.com/v1/transit/sign/zscaler-oneapi
#   export VAULT_TOKEN=... VAULT_NAMESPACE=admin
#   scripts/signing-check.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -d "$REPO_ROOT/build/zscaler-sdk-go" ]; then
  echo "Run scripts/bootstrap.sh first." >&2
  exit 1
fi

cd "$REPO_ROOT/tools/signing-check"
go mod tidy >/dev/null
exec go run .
