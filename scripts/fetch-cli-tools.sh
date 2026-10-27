#!/usr/bin/env bash
# Downloads the pinned ripgrep and bat releases for both Mac architectures,
# verifies each against the hash in tools.env, merges the slices into universal
# `rg` and `bat`, and adds the imgcat script — the command-line tools every
# terminal tab gets on its PATH (see BundledCommand).
#
#   scripts/fetch-cli-tools.sh [--verify-only] [OUTPUT_DIR]
#
# OUTPUT_DIR defaults to Vendor/Tools. Writes:
#   OUTPUT_DIR/bin/rg, bin/bat                universal, ad-hoc signed
#   OUTPUT_DIR/bin/imgcat                     scripts/imgcat, as it is
#   OUTPUT_DIR/licenses/ripgrep-LICENSE.txt   MIT and the Unlicense, required to ship
#   OUTPUT_DIR/licenses/bat-LICENSE.txt       MIT and Apache-2.0, required to ship
#
# --verify-only downloads, verifies and extracts every slice, checks that the
# licences are what they claim to be, and stops before lipo/codesign. That half
# is portable, so it can be proven off a Mac; the merge needs macOS tools and
# runs in CI.
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

# fetch_slice URL EXPECTED_SHA256 DEST — downloads, refuses anything that is not
# the pinned file, and unpacks it into DEST.
fetch_slice() {
  local url="$1" want="$2" dest="$3" name got
  name="$(basename "$url")"
  curl -fsSL --retry 3 -o "$work/$name" "$url"
  got="$(sha256 "$work/$name")"
  if [ "$got" != "$want" ]; then
    echo "error: $name hash mismatch" >&2
    echo "  expected $want" >&2
    echo "  got      $got" >&2
    exit 1
  fi
  echo "verified $name"
  mkdir -p "$dest"
  tar -xzf "$work/$name" -C "$dest" 2>/dev/null
}

# require_file PATH WHAT — a layout change upstream fails here, by name, rather
# than as a missing file somewhere downstream.
require_file() {
  if [ ! -f "$1" ]; then
    echo "error: $2 is not where expected: $1" >&2
    find "$(dirname "$1")" -maxdepth 3 >&2 || true
    exit 1
  fi
}

# --- ripgrep ----------------------------------------------------------------
rg_base="https://github.com/BurntSushi/ripgrep/releases/download/${RIPGREP_VERSION}"
rg_slices=()
for pair in "aarch64:${RIPGREP_SHA256_ARM64}" "x86_64:${RIPGREP_SHA256_X86_64}"; do
  arch="${pair%%:*}"
  stem="ripgrep-${RIPGREP_VERSION}-${arch}-apple-darwin"
  fetch_slice "$rg_base/$stem.tar.gz" "${pair#*:}" "$work/rg-$arch"
  require_file "$work/rg-$arch/$stem/rg" "rg in the ripgrep $arch archive"
  rg_slices+=("$work/rg-$arch/$stem/rg")
done
rg_stem="ripgrep-${RIPGREP_VERSION}-aarch64-apple-darwin"
for file in LICENSE-MIT UNLICENSE; do
  require_file "$work/rg-aarch64/$rg_stem/$file" "$file in the ripgrep archive"
done

# --- bat --------------------------------------------------------------------
bat_base="https://github.com/sharkdp/bat/releases/download/v${BAT_VERSION}"
bat_slices=()
for pair in "aarch64:${BAT_SHA256_ARM64}" "x86_64:${BAT_SHA256_X86_64}"; do
  arch="${pair%%:*}"
  stem="bat-v${BAT_VERSION}-${arch}-apple-darwin"
  fetch_slice "$bat_base/$stem.tar.gz" "${pair#*:}" "$work/bat-$arch"
  require_file "$work/bat-$arch/$stem/bat" "bat in the bat $arch archive"
  bat_slices+=("$work/bat-$arch/$stem/bat")
done
bat_stem="bat-v${BAT_VERSION}-aarch64-apple-darwin"
for file in LICENSE-MIT LICENSE-APACHE; do
  require_file "$work/bat-aarch64/$bat_stem/$file" "$file in the bat archive"
done

# --- licences ---------------------------------------------------------------
# Each notice is what the project ships in its own archive. Checked for what it
# says, so a file that was swapped for something else, or emptied, fails here.
join_licence() {
  local dest="$1" title="$2"; shift 2
  {
    echo "$title"
    echo
    for file in "$@"; do
      echo "=== $(basename "$file") ==="
      cat "$file"
      echo
    done
  } > "$dest"
}
mkdir -p "$out/licenses"
join_licence "$out/licenses/ripgrep-LICENSE.txt" \
  "ripgrep ${RIPGREP_VERSION} — MIT or the Unlicense, at your option." \
  "$work/rg-aarch64/$rg_stem/LICENSE-MIT" "$work/rg-aarch64/$rg_stem/UNLICENSE"
join_licence "$out/licenses/bat-LICENSE.txt" \
  "bat ${BAT_VERSION} — MIT or Apache-2.0, at your option." \
  "$work/bat-aarch64/$bat_stem/LICENSE-MIT" "$work/bat-aarch64/$bat_stem/LICENSE-APACHE"
grep -q "Permission is hereby granted" "$out/licenses/ripgrep-LICENSE.txt" \
  && grep -q "unencumbered" "$out/licenses/ripgrep-LICENSE.txt" \
  || { echo "error: the ripgrep licences do not look like MIT and the Unlicense" >&2; exit 1; }
grep -q "Permission is hereby granted" "$out/licenses/bat-LICENSE.txt" \
  && grep -qi "Apache License" "$out/licenses/bat-LICENSE.txt" \
  || { echo "error: the bat licences do not look like MIT and Apache-2.0" >&2; exit 1; }

if $verify_only; then
  echo "verified and extracted $(( ${#rg_slices[@]} + ${#bat_slices[@]} )) slices; stopping before merge (--verify-only)"
  exit 0
fi

for tool in lipo codesign; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: $tool is required to merge slices (macOS only); use --verify-only elsewhere" >&2
    exit 1
  fi
done

mkdir -p "$out/bin"
lipo -create -output "$out/bin/rg" "${rg_slices[@]}"
lipo -create -output "$out/bin/bat" "${bat_slices[@]}"
# Re-signed after the merge rather than trusting the slices' own signatures: an
# arm64 binary without a valid one is killed on launch.
for tool in rg bat; do
  codesign --force --sign - "$out/bin/$tool"
  xattr -c "$out/bin/$tool" 2>/dev/null || true
  chmod 755 "$out/bin/$tool"
done

install -m 755 "$root/scripts/imgcat" "$out/bin/imgcat"

echo "ripgrep $RIPGREP_VERSION -> $out/bin/rg ($(lipo -archs "$out/bin/rg"))"
echo "bat $BAT_VERSION -> $out/bin/bat ($(lipo -archs "$out/bin/bat"))"
