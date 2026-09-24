#!/usr/bin/env bash
# Downloads the pinned superfile release for both Mac architectures, verifies
# each against the hash in tools.env, and merges them into one universal `spf`.
#
#   scripts/fetch-superfile.sh [--verify-only] [OUTPUT_DIR]
#
# OUTPUT_DIR defaults to Vendor/Tools. Writes:
#   OUTPUT_DIR/spf                              universal, ad-hoc signed
#   OUTPUT_DIR/licenses/superfile-LICENSE.txt   MIT notice, required to ship
#
# --verify-only downloads, verifies and extracts both slices, then stops before
# lipo/codesign. That half is portable, so it can be proven off a Mac; the
# merge needs macOS tools and runs in CI.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools.env
. "$root/scripts/tools.env"

verify_only=false
if [ "${1:-}" = "--verify-only" ]; then
  verify_only=true
  shift
fi
out="${1:-$root/Vendor/Tools}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# macOS ships shasum; most Linux images ship sha256sum.
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

base="https://github.com/yorukot/superfile/releases/download/v${SUPERFILE_VERSION}"
slices=()

for pair in "arm64:${SUPERFILE_SHA256_ARM64}" "amd64:${SUPERFILE_SHA256_AMD64}"; do
  arch="${pair%%:*}"
  want="${pair#*:}"
  name="superfile-darwin-v${SUPERFILE_VERSION}-${arch}.tar.gz"

  curl -fsSL --retry 3 -o "$work/$name" "$base/$name"
  got="$(sha256 "$work/$name")"
  if [ "$got" != "$want" ]; then
    echo "error: $name hash mismatch" >&2
    echo "  expected $want" >&2
    echo "  got      $got" >&2
    exit 1
  fi
  echo "verified $name"

  mkdir -p "$work/$arch"
  # Upstream archives carry macOS provenance xattrs in pax headers; GNU tar
  # warns about them on every entry and they are of no use here.
  tar -xzf "$work/$name" -C "$work/$arch" 2>/dev/null
  binary="$work/$arch/dist/superfile-darwin-v${SUPERFILE_VERSION}-${arch}/spf"
  if [ ! -f "$binary" ]; then
    echo "error: $name does not contain spf where expected" >&2
    find "$work/$arch" -maxdepth 4 >&2
    exit 1
  fi
  slices+=("$binary")
done

if $verify_only; then
  echo "verified and extracted ${#slices[@]} slices; stopping before merge (--verify-only)"
  exit 0
fi

for tool in lipo codesign; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: $tool is required to merge slices (macOS only); use --verify-only elsewhere" >&2
    exit 1
  fi
done

mkdir -p "$out/licenses"
lipo -create -output "$out/spf" "${slices[@]}"
# Each slice arrives ad-hoc signed by Go's linker, but re-sign the merged file
# rather than rely on that: an arm64 binary without a valid signature is
# killed on launch.
codesign --force --sign - "$out/spf"
xattr -c "$out/spf" 2>/dev/null || true
chmod 755 "$out/spf"

curl -fsSL --retry 3 \
  -o "$out/licenses/superfile-LICENSE.txt" \
  "https://raw.githubusercontent.com/yorukot/superfile/v${SUPERFILE_VERSION}/LICENSE"
if ! grep -q "MIT" "$out/licenses/superfile-LICENSE.txt"; then
  echo "error: fetched superfile LICENSE does not look like the MIT licence" >&2
  exit 1
fi

echo "superfile $SUPERFILE_VERSION -> $out/spf ($(lipo -archs "$out/spf"))"
