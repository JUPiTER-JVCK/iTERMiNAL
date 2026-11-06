#!/usr/bin/env bash
# Downloads the pinned tldr-pages release, verifies it against the hash in
# tools.env, and converts the English common and macOS pages into the one file
# the Cheatsheet page reads.
#
#   scripts/fetch-tldr.sh [OUTPUT_DIR]
#
# OUTPUT_DIR defaults to Vendor/Cheatsheets, which project.yml's copy phase puts
# into Contents/Resources/Cheatsheets. Writes:
#   OUTPUT_DIR/tldr.json                          the pages (see tldr-convert.py)
#   OUTPUT_DIR/licenses/tldr-pages-LICENSE.md     the CC BY 4.0 notice, which
#                                                 asks that credit travel with it
#   OUTPUT_DIR/manifest.json                      the version
#
# Nothing here needs macOS, so the whole script can be proven off a Mac.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools.env
. "$root/scripts/tools.env"

out="${1:-$root/Vendor/Cheatsheets}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

url="https://github.com/tldr-pages/tldr/releases/download/v${TLDR_VERSION}/tldr.zip"
curl -fsSL --retry 3 -o "$work/tldr.zip" "$url"
got="$(sha256 "$work/tldr.zip")"
if [ "$got" != "$TLDR_SHA256" ]; then
  echo "error: tldr.zip hash mismatch" >&2
  echo "  expected $TLDR_SHA256" >&2
  echo "  got      $got" >&2
  exit 1
fi
echo "verified tldr.zip"

mkdir -p "$out"
python3 "$root/scripts/tldr-convert.py" "$work/tldr.zip" "$out" "$TLDR_VERSION"
chmod 644 "$out/tldr.json" "$out/manifest.json" "$out/licenses/"*

echo "tldr-pages $TLDR_VERSION -> $out/tldr.json"
