#!/usr/bin/env bash
# Clones the three upstream Zscaler repositories at the commits these patches
# were written against, applies the patches, and wires the providers to the
# patched SDK.
#
# Usage: scripts/bootstrap.sh [workdir]   (default: ./build)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${1:-$REPO_ROOT/build}"

# Upstream commits the patches were generated against.
SDK_REF="4b7101202cde25e1e60552f1cb215d2c70cdc3bd"   # zscaler-sdk-go, v3.8.48
ZIA_REF="38fd97d795537682434cd1d4ffbdd02d2f3b4576"   # terraform-provider-zia
ZPA_REF="5326dc43ff3c006369864de337d80b693574ca88"   # terraform-provider-zpa

clone_at() {
  local name="$1" ref="$2" dest="$WORKDIR/$1"
  if [ -d "$dest/.git" ]; then
    echo "==> $name already cloned, skipping"
    return
  fi
  echo "==> cloning $name"
  git clone --quiet "https://github.com/zscaler/$name.git" "$dest"
  git -C "$dest" checkout --quiet "$ref"
}

apply_patch() {
  local name="$1" dest="$WORKDIR/$1"
  if git -C "$dest" diff --quiet && git -C "$dest" diff --cached --quiet && [ -z "$(git -C "$dest" status --porcelain)" ]; then
    echo "==> patching $name"
    git -C "$dest" apply "$REPO_ROOT/patches/$name.patch"
  else
    echo "==> $name already patched, skipping"
  fi
}

mkdir -p "$WORKDIR"

clone_at zscaler-sdk-go        "$SDK_REF"
clone_at terraform-provider-zia "$ZIA_REF"
clone_at terraform-provider-zpa "$ZPA_REF"

apply_patch zscaler-sdk-go
apply_patch terraform-provider-zia
apply_patch terraform-provider-zpa

# The providers need the patched SDK. Upstream this is a released SDK version;
# here it is a local replace directive so everything builds together.
for provider in terraform-provider-zia terraform-provider-zpa; do
  echo "==> pointing $provider at the patched SDK"
  (cd "$WORKDIR/$provider" && go mod edit -replace github.com/zscaler/zscaler-sdk-go/v3=../zscaler-sdk-go && go mod tidy >/dev/null)
done

echo
echo "Ready. Run scripts/test.sh to build and test everything."
