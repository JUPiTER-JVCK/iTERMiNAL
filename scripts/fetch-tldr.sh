#!/usr/bin/env bash
# Downloads the pinned tldr-pages commit, checks the pages in it against the hash
# in tools.env, and converts the English common and macOS pages into the one file
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

# GitHub's source archive of one commit, not the release's tldr.zip: a commit
# cannot change, and tldr-pages re-uploads that file to its latest release every
# time it merges something, so a hash of it stopped matching within hours. The
# archive's bytes are not pinned either, since GitHub does not promise to pack a
# commit into the same bytes twice. What is pinned is the pages in it, and
# tldr-convert.py refuses the archive, before it writes anything, unless they
# hash to TLDR_CONTENT_SHA256.
url="https://github.com/tldr-pages/tldr/archive/${TLDR_COMMIT}.zip"
curl -fsSL --retry 3 -o "$work/tldr.zip" "$url"

mkdir -p "$out"
python3 "$root/scripts/tldr-convert.py" "$work/tldr.zip" "$out" "$TLDR_VERSION" "$TLDR_CONTENT_SHA256"
chmod 644 "$out/tldr.json" "$out/manifest.json" "$out/licenses/"*

echo "tldr-pages $TLDR_VERSION (${TLDR_COMMIT:0:12}) -> $out/tldr.json"
