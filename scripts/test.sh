#!/usr/bin/env bash
# Builds and tests the patched repositories. Run scripts/bootstrap.sh first.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${1:-$REPO_ROOT/build}"
STATUS=0

run() {
  local label="$1"; shift
  echo
  echo "=============================================================="
  echo "== $label"
  echo "=============================================================="
  if "$@"; then
    echo "-- OK: $label"
  else
    echo "-- FAILED: $label"
    STATUS=1
  fi
}

if [ ! -d "$WORKDIR/zscaler-sdk-go" ]; then
  echo "No build directory at $WORKDIR - run scripts/bootstrap.sh first." >&2
  exit 1
fi

cd "$WORKDIR/zscaler-sdk-go"
run "SDK: signing package tests"   go test ./zscaler/remotesign/...
run "SDK: OneAPI client tests"     go test ./zscaler/
run "SDK: vet"                     go vet ./zscaler/ ./zscaler/remotesign/

cd "$WORKDIR/terraform-provider-zia"
run "ZIA provider: build"          go build ./...
run "ZIA provider: signing tests"  go test -run 'Signing|TestProvider$|TestAuthenticationConfiguration|TestNoSigning' ./zia/

cd "$WORKDIR/terraform-provider-zpa"
run "ZPA provider: build"          go build ./...
run "ZPA provider: signing tests"  go test -run 'Signing|TestProvider$|TestAuthenticationConfiguration|TestNoSigning' ./zpa/

echo
if [ "$STATUS" -eq 0 ]; then
  echo "All checks passed."
else
  echo "Some checks failed (see above)."
fi
exit "$STATUS"
