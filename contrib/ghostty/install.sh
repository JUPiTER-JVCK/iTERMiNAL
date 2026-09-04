#!/usr/bin/env bash
#
# Install the iTERMiNAL Ghostty configuration.
#
#   ./install.sh              # Ghostty config + all twenty themes
#   ./install.sh --extras     # also starship, btop and fastfetch configs
#   ./install.sh --dry-run    # print what would happen, touch nothing
#
# Anything already in place is backed up next to itself with a timestamp
# before being replaced; nothing is deleted.

set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"

DRY_RUN=0
EXTRAS=0
CONFIG_DIR="${GHOSTTY_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/ghostty}"

usage() {
    sed -n '3,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --extras)     EXTRAS=1 ;;
        --dry-run|-n) DRY_RUN=1 ;;
        --config-dir) shift; CONFIG_DIR="${1:?--config-dir needs a path}" ;;
        -h|--help)    usage 0 ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
    shift
done

say()  { printf '  %s\n' "$*"; }
step() { printf '\n%s\n' "$*"; }

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        say "would run: $*"
    else
        "$@"
    fi
}

# Move an existing file or directory aside rather than clobbering it. The
# stamp is only second-precision, so two runs in the same second would
# otherwise have the second `mv` overwrite the first run's backup — find an
# unused name instead, since the whole promise here is that nothing is lost.
back_up() {
    local target="$1"
    [ -e "$target" ] || return 0

    local backup="$target.$STAMP.bak" n=2
    while [ -e "$backup" ]; do
        backup="$target.$STAMP-$n.bak"
        n=$((n + 1))
    done

    say "backing up $(basename "$target") -> $(basename "$backup")"
    run mv "$target" "$backup"
}

install_file() {
    local src="$1" dest="$2"
    back_up "$dest"
    run mkdir -p "$(dirname "$dest")"
    run cp "$src" "$dest"
    if [ "$DRY_RUN" -eq 1 ]; then
        say "would install $dest"
    else
        say "installed $dest"
    fi
}

step "Ghostty configuration directory: $CONFIG_DIR"
[ "$DRY_RUN" -eq 1 ] && say "(dry run — nothing will be written)"

# On macOS Ghostty reads BOTH the XDG path and Application Support. Having a
# config in each means two configs load and the later one silently wins parts
# of the first, which is a miserable thing to debug — so say so up front.
# Ghostty reads four paths and loads *every* one that exists, later files
# overriding earlier, in this order:
#
#   1. <xdg>/ghostty/config.ghostty     3. <app support>/config.ghostty
#   2. <xdg>/ghostty/config             4. <app support>/config
#
# So a leftover file can quietly override what we install and make the whole
# thing look like it did nothing. List any we are not writing.
APP_SUPPORT="$HOME/Library/Application Support/com.mitchellh.ghostty"
CONFIG_NAME="config.ghostty"
DEST="$CONFIG_DIR/$CONFIG_NAME"

others=""
for candidate in \
    "$CONFIG_DIR/config.ghostty" "$CONFIG_DIR/config" \
    "$APP_SUPPORT/config.ghostty" "$APP_SUPPORT/config"
do
    [ "$candidate" = "$DEST" ] && continue
    [ -f "$candidate" ] && others="$others$candidate"$'\n'
done

if [ -n "$others" ]; then
    say ""
    say "note: Ghostty will also load these existing config files:"
    printf '%s' "$others" | while IFS= read -r f; do
        [ -n "$f" ] && say "        $f"
    done
    say "      Files later in Ghostty's search order win, and the macOS"
    say "      Application Support pair is read after the XDG pair. Move or"
    say "      delete them if this install appears to have no effect."
    say ""
fi

step "Installing config and themes"
# config.ghostty is the current name; plain `config` is the pre-1.2.3 spelling
# and still loads, which is exactly why we warn about it above.
install_file "$SOURCE_DIR/config" "$DEST"

back_up "$CONFIG_DIR/themes"
run mkdir -p "$CONFIG_DIR/themes"
if [ "$DRY_RUN" -eq 1 ]; then
    say "would copy $(find "$SOURCE_DIR/themes" -type f | wc -l | tr -d ' ') themes to $CONFIG_DIR/themes"
else
    cp "$SOURCE_DIR"/themes/* "$CONFIG_DIR/themes/"
    say "installed $(find "$CONFIG_DIR/themes" -type f | wc -l | tr -d ' ') themes to $CONFIG_DIR/themes"
fi

if [ "$EXTRAS" -eq 1 ]; then
    step "Installing companion configs"
    CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
    install_file "$SOURCE_DIR/extras/starship.toml"  "$CONFIG_HOME/starship.toml"
    install_file "$SOURCE_DIR/extras/fastfetch.jsonc" "$CONFIG_HOME/fastfetch/config.jsonc"
    install_file "$SOURCE_DIR/extras/btop.theme"      "$CONFIG_HOME/btop/themes/iterminal-everforest.theme"
    say ""
    say "btop needs telling which theme to use — either set"
    say "  color_theme = \"iterminal-everforest\""
    say "in $CONFIG_HOME/btop/btop.conf, or pick it in btop under Esc -> Options."
fi

step "Checking the result"
if command -v ghostty >/dev/null 2>&1; then
    # Point it at the file we just wrote. Bare +validate-config checks the
    # live user config, which with --config-dir is a different file entirely
    # — it would happily report OK while the installed one is broken.
    if [ "$DRY_RUN" -eq 1 ]; then
        say "would run: ghostty +validate-config --config-file=\"$DEST\""
    elif ghostty +validate-config --config-file="$DEST" >/dev/null 2>&1; then
        say "ghostty +validate-config: OK"
    else
        say "ghostty +validate-config reported problems:"
        ghostty +validate-config --config-file="$DEST" 2>&1 | sed 's/^/    /' || true
    fi
else
    say "ghostty is not on PATH — skipping validation."
    say "On macOS the CLI lives inside the app bundle; you can run it as:"
    say "  /Applications/Ghostty.app/Contents/MacOS/ghostty \\"
    say "    +validate-config --config-file=\"$DEST\""
fi

step "Done."
cat <<'NOTES'
  Next:
    1. Install a Nerd Font, or the icons in btop/starship/fastfetch will
       render as empty boxes:
         brew install --cask font-jetbrains-mono-nerd-font
    2. Restart Ghostty (or press cmd+shift+r to reload the config).
    3. To try another theme, edit the `theme =` line in the config —
       `ls ~/.config/ghostty/themes` lists all twenty.
NOTES
