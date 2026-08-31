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

# Move an existing file or directory aside rather than clobbering it.
back_up() {
    local target="$1"
    [ -e "$target" ] || return 0
    say "backing up $(basename "$target") -> $(basename "$target").$STAMP.bak"
    run mv "$target" "$target.$STAMP.bak"
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
APP_SUPPORT="$HOME/Library/Application Support/com.mitchellh.ghostty"
if [ "$CONFIG_DIR" != "$APP_SUPPORT" ] && [ -f "$APP_SUPPORT/config" ]; then
    say ""
    say "note: you also have a config at"
    say "      $APP_SUPPORT/config"
    say "      Ghostty loads both. Move or delete that one, or re-run with"
    say "      --config-dir \"$APP_SUPPORT\" to install there instead."
    say ""
fi

step "Installing config and themes"
install_file "$SOURCE_DIR/config" "$CONFIG_DIR/config"

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
    if [ "$DRY_RUN" -eq 1 ]; then
        say "would run: ghostty +validate-config"
    elif ghostty +validate-config >/dev/null 2>&1; then
        say "ghostty +validate-config: OK"
    else
        say "ghostty +validate-config reported problems:"
        ghostty +validate-config 2>&1 | sed 's/^/    /' || true
    fi
else
    say "ghostty is not on PATH — skipping validation."
    say "On macOS the CLI lives inside the app bundle; you can run it as:"
    say "  /Applications/Ghostty.app/Contents/MacOS/ghostty +validate-config"
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
