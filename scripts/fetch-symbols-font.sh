#!/usr/bin/env bash
# Downloads the pinned Nerd Fonts "Symbols Only" release, verifies it against
# the hash in tools.env, and extracts the one face the app bundles.
#
#   scripts/fetch-symbols-font.sh [OUTPUT_DIR]
#
# OUTPUT_DIR defaults to Vendor/Fonts, which project.yml's copy phase puts
# into Contents/Resources/Fonts. Writes:
#   OUTPUT_DIR/SymbolsNerdFontMono-Regular.ttf
#   OUTPUT_DIR/licenses/nerd-fonts-symbols-LICENSE.txt   the MIT notice
#   OUTPUT_DIR/licenses/nerd-fonts-symbols-README.md     every icon set's
#                                                        upstream and licence
#   OUTPUT_DIR/manifest.json                             the version, for
#                                                        Settings to report
#
# The Mono face, not the proportional one: its icons are one cell wide, which
# is the width a terminal gives a Private Use Area character. The wider face
# would spill into the next cell.
#
# Nothing here needs macOS, so the whole script can be proven off a Mac.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools.env
. "$root/scripts/tools.env"

out="${1:-$root/Vendor/Fonts}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

name="NerdFontsSymbolsOnly.tar.xz"
url="https://github.com/ryanoasis/nerd-fonts/releases/download/v${NERD_FONTS_VERSION}/${name}"
curl -fsSL --retry 3 -o "$work/$name" "$url"
got="$(sha256 "$work/$name")"
if [ "$got" != "$NERD_FONTS_SYMBOLS_SHA256" ]; then
  echo "error: $name hash mismatch" >&2
  echo "  expected $NERD_FONTS_SYMBOLS_SHA256" >&2
  echo "  got      $got" >&2
  exit 1
fi
echo "verified $name"

tar -xJf "$work/$name" -C "$work"
for file in SymbolsNerdFontMono-Regular.ttf LICENSE README.md; do
  if [ ! -s "$work/$file" ]; then
    echo "error: $name does not contain $file" >&2
    ls -la "$work" >&2
    exit 1
  fi
done
if ! grep -q "MIT License" "$work/LICENSE"; then
  echo "error: the archive's LICENSE does not look like the MIT licence" >&2
  exit 1
fi

mkdir -p "$out/licenses"
cp "$work/SymbolsNerdFontMono-Regular.ttf" "$out/SymbolsNerdFontMono-Regular.ttf"
cp "$work/LICENSE" "$out/licenses/nerd-fonts-symbols-LICENSE.txt"
# The README is the icon sets' attribution: several are CC BY 4.0 or OFL,
# which require credit to travel with the glyphs, and this is where upstream
# gives it.
cp "$work/README.md" "$out/licenses/nerd-fonts-symbols-README.md"
printf '{"nerd-fonts-symbols":"%s"}\n' "$NERD_FONTS_VERSION" > "$out/manifest.json"
chmod 644 "$out/SymbolsNerdFontMono-Regular.ttf" "$out/manifest.json" "$out/licenses/"*

echo "Symbols Nerd Font Mono $NERD_FONTS_VERSION -> $out/SymbolsNerdFontMono-Regular.ttf"
