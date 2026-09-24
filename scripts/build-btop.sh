#!/usr/bin/env bash
# Builds the pinned btop for this machine's architecture, and refuses to hand
# back a binary that would not run on a Mac without Homebrew.
#
#   scripts/build-btop.sh OUTPUT_DIR
#
# Writes OUTPUT_DIR/btop (thin, for the host architecture) and
# OUTPUT_DIR/licenses/btop-LICENSE.txt. CI runs it once on an Apple Silicon runner and
# once on an Intel one, then lipo merges the two: GCC, unlike clang, cannot
# cross-compile between them.
#
# Why GCC at all: btop needs GCC 14+ or Clang 19+ and does not support Xcode's
# clang, and upstream publishes no macOS binaries. Homebrew's gcc@15 is what
# btop's own README uses on macOS.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools.env
. "$root/scripts/tools.env"

out="${1:?usage: build-btop.sh OUTPUT_DIR}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"

CXX="${CXX:-g++-15}"
if ! command -v "$CXX" >/dev/null 2>&1; then
  echo "error: $CXX not found (brew install gcc@15)" >&2
  exit 1
fi
# btop's Makefile needs GNU make 4; macOS ships 3.81 as `make`.
MAKE_BIN="${MAKE_BIN:-gmake}"
if ! command -v "$MAKE_BIN" >/dev/null 2>&1; then
  echo "error: $MAKE_BIN not found (brew install make)" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

git clone --quiet --depth 1 --branch "v${BTOP_VERSION}" \
  https://github.com/aristocratos/btop "$work/btop"
head="$(git -C "$work/btop" rev-parse HEAD)"
if [ "$head" != "$BTOP_COMMIT" ]; then
  # A tag is movable; the commit is what was reviewed.
  echo "error: v${BTOP_VERSION} resolves to $head, pinned $BTOP_COMMIT" >&2
  exit 1
fi

# STATIC=true on macOS with GCC links libgcc and libstdc++ statically — the
# fully static `-static` branch in btop's Makefile is Linux/BSD only. Without
# it the binary would load libstdc++ from Homebrew's Cellar at runtime.
# GPU_SUPPORT is Linux-only upstream; stated so the build cannot drift.
# No lowdown is installed, so the man page is skipped, which is fine: nothing
# in the app bundle would ever read it.
#
# CXX_IS_CLANG=false works around an upstream Makefile bug: it sets that
# variable to `true` for clang and never to `false`, so with GCC it is empty
# and the `ifeq ($(CXX_IS_CLANG),false)` guarding -static-libgcc and
# -static-libstdc++ on macOS can never fire. STATIC=true alone is a silent
# no-op here — the first CI run built a binary linking Homebrew's libstdc++
# and libgcc_s, which the otool check below refused. The Makefile's only
# assignment is an override that fires for clang, so this cannot mislabel
# a clang build.
"$MAKE_BIN" -C "$work/btop" \
  CXX="$CXX" \
  CXX_IS_CLANG=false \
  STATIC=true \
  GPU_SUPPORT=false \
  QUIET=true \
  -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"

binary="$work/btop/bin/btop"
if [ ! -x "$binary" ]; then
  echo "error: build finished without producing bin/btop" >&2
  exit 1
fi

# The check that makes bundling safe. Anything outside /usr/lib and
# /System/Library would come from Homebrew, and would be missing on the Mac of
# anyone who has not installed it — a binary that runs in CI and nowhere else.
# awk rather than grep for the filter: under pipefail a grep that matches
# nothing exits 1 and would abort here on the success path.
foreign="$(otool -L "$binary" | awk '/^\t/ { print $1 }' \
  | awk '!/^\/usr\/lib\// && !/^\/System\/Library\//')"
if [ -n "$foreign" ]; then
  echo "error: btop links libraries a stock Mac does not have:" >&2
  echo "$foreign" >&2
  exit 1
fi

# --version is parsed before btop looks for a TTY, so this runs headless.
"$binary" --version

cp "$binary" "$out/btop"
chmod 755 "$out/btop"
# Same layout as the bundle, so a local `build-btop.sh Vendor/Tools` puts the
# notice where Settings → Advanced looks for it.
mkdir -p "$out/licenses"
cp "$work/btop/LICENSE" "$out/licenses/btop-LICENSE.txt"
echo "btop $BTOP_VERSION ($(uname -m)) -> $out/btop"
