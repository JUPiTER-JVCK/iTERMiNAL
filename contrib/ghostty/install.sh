#!/usr/bin/env bash
#
# Install the iTERMiNAL Ghostty configuration.
#
#   ./install.sh                         # Ghostty config + all twenty themes
#   ./install.sh --extras                # also btop, starship, yazi, fzf
#   ./install.sh --theme iterminal-nord  # pick a palette
#   ./install.sh --dry-run               # print what would happen, touch nothing
#
# --theme re-themes the companion configs as well, so btop and starship follow
# the terminal instead of staying Everforest green under every scheme. Any
# theme other than the default needs python3 to generate them.
#
# Anything already in place is backed up next to itself with a timestamp
# before being replaced; nothing is deleted.

set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"

DRY_RUN=0
EXTRAS=0
# The committed extras/ are generated for this palette, which is what lets the
# default install work without python3.
DEFAULT_THEME="iterminal-everforest-dark"
THEME="$DEFAULT_THEME"
CONFIG_DIR="${GHOSTTY_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/ghostty}"

usage() {
    # Print the header block rather than a fixed line range, so editing the
    # comment above cannot silently truncate --help.
    awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' \
        "${BASH_SOURCE[0]}"
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --extras)     EXTRAS=1 ;;
        --dry-run|-n) DRY_RUN=1 ;;
        --config-dir) shift; CONFIG_DIR="${1:?--config-dir needs a path}" ;;
        --theme)      shift; THEME="${1:?--theme needs a theme name}" ;;
        -h|--help)    usage 0 ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
    shift
done

# A typo must not quietly install the default — the user would be left
# wondering why nothing changed colour.
if [ ! -f "$SOURCE_DIR/themes/$THEME" ]; then
    printf 'unknown theme: %s\n\nValid names:\n' "$THEME" >&2
    (cd "$SOURCE_DIR/themes" && ls) | sed 's/^/  /' >&2
    exit 1
fi

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

# The shipped config names the default palette; point it at whatever --theme
# asked for. split-divider-color has to move with it — left alone it stays
# Everforest green while the rest of the window turns Tokyo Night. Take the
# green from the chosen palette (ANSI 2). Written via a temp file because
# `sed -i` takes different arguments on BSD and GNU.
DIVIDER="$(sed -n 's/^palette = 2=#\(.*\)$/\1/p' "$SOURCE_DIR/themes/$THEME")"
if [ "$DRY_RUN" -eq 1 ]; then
    say "would set theme = $THEME (divider #$DIVIDER) in $(basename "$DEST")"
else
    theme_tmp="$DEST.theme.$$"
    sed -e "s|^theme = .*|theme = $THEME|" \
        -e "s|^split-divider-color = .*|split-divider-color = #$DIVIDER|" \
        "$DEST" > "$theme_tmp"
    mv "$theme_tmp" "$DEST"
    say "set theme = $THEME, split-divider-color = #$DIVIDER"
fi

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

    # extras/ is committed pre-generated for the default palette, so the common
    # path needs nothing but cp. Any other palette has to be generated, which
    # is the only thing here that wants python3.
    EXTRAS_SRC="$SOURCE_DIR/extras"
    if [ "$THEME" != "$DEFAULT_THEME" ]; then
        if ! command -v python3 >/dev/null 2>&1; then
            echo "python3 is needed to generate companion configs for $THEME" >&2
            echo "(the committed extras/ only cover $DEFAULT_THEME)" >&2
            exit 1
        fi
        EXTRAS_SRC="$(mktemp -d)"
        trap 'rm -rf "$EXTRAS_SRC"' EXIT
        say "generating companion configs for $THEME"
        "$SOURCE_DIR/export-themes.py" --extras "$THEME" --out "$EXTRAS_SRC" \
            | sed 's/^/  /'
    fi

    install_file "$EXTRAS_SRC/starship.toml"          "$CONFIG_HOME/starship.toml"
    install_file "$EXTRAS_SRC/btop.theme"             "$CONFIG_HOME/btop/themes/iterminal.theme"
    install_file "$EXTRAS_SRC/theme.toml"             "$CONFIG_HOME/yazi/theme.toml"
    install_file "$EXTRAS_SRC/fzf.sh"                 "$CONFIG_DIR/fzf.sh"
    # fastfetch is palette-agnostic on purpose — it uses ANSI colour *names*,
    # so it follows whatever theme is active without being regenerated.
    install_file "$SOURCE_DIR/extras/fastfetch.jsonc" "$CONFIG_HOME/fastfetch/config.jsonc"

    if [ -f "$EXTRAS_SRC/config.json" ]; then
        install_file "$EXTRAS_SRC/config.json" "$CONFIG_HOME/neohtop-cli/config.json"
    else
        say "no neohtop-cli config: it has no built-in theme matching $THEME"
    fi

    say ""
    say "btop needs telling which theme to use — either set"
    say "  color_theme = \"iterminal\""
    say "in $CONFIG_HOME/btop/btop.conf, or pick it in btop under Esc -> Options."
    say ""
    say "fzf reads its colours from a sourced file; add this to your shell rc:"
    say "  [ -f $CONFIG_DIR/fzf.sh ] && . $CONFIG_DIR/fzf.sh"
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
    3. To try another palette, re-run with --theme; it re-themes btop,
       starship and yazi to match, not just the terminal:
         ./install.sh --extras --theme iterminal-tokyo-night
       `ls ~/.config/ghostty/themes` lists all twenty.
NOTES
