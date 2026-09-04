#!/usr/bin/env python3
"""Export the app's terminal palettes as Ghostty themes and companion configs.

TerminalTheme.swift is the single source of truth for iTERMiNAL's twenty
colour schemes. Ghostty wants the same data as one file per theme, so this
reads the Swift literals and writes `themes/iterminal-<id>`.

    ./export-themes.py                              # regenerate themes/
    ./export-themes.py --check                      # exit 1 if themes/ drifted
    ./export-themes.py --extras <id> --out <dir>    # companion configs

The --check mode is what keeps the two honest: change a colour in Swift
without re-running this and it reports exactly which files are stale.

The --extras mode is why btop and starship follow the terminal instead of
staying Everforest green under every theme. It never touches themes/.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Sources/iTERMiNAL/Chrome/TerminalTheme.swift"
HERE = Path(__file__).resolve().parent
THEMES = HERE / "themes"

# The app's own two schemes carry the project's old internal codename in their
# id. Everything else exports under its own id, so `everforest-dark` becomes
# `iterminal-everforest-dark` and stays clear of Ghostty's built-in of the
# same name.
FILENAME_ALIASES = {"codex-dark": "dark", "codex-light": "light"}

THEME_RE = re.compile(
    r"""TerminalTheme\(\s*
        id:\s*"(?P<id>[^"]+)",\s*
        name:\s*"(?P<name>[^"]+)",\s*
        isDark:\s*(?P<dark>true|false),\s*
        background:\s*0x(?P<bg>[0-9A-Fa-f]{6}),\s*
        foreground:\s*0x(?P<fg>[0-9A-Fa-f]{6}),\s*
        ansi:\s*\[(?P<ansi>[^\]]*)\]""",
    re.VERBOSE,
)

ANSI_RE = re.compile(r"0x([0-9A-Fa-f]{6})")

# Deliberately loose: it only spots "static let x = TerminalTheme(", so it
# still counts a declaration whose fields THEME_RE can no longer read.
DECL_RE = re.compile(r"static\s+let\s+\w+\s*=\s*TerminalTheme\(")

# neohtop-cli ships 15 built-in themes and has no custom-theme format, so the
# best we can do is name one. Nine of its built-ins happen to be spelled
# exactly like our ids, so membership is the whole mapping — no translation
# table to drift. Everything else (Everforest included) gets no config at all
# rather than a wrong-looking one.
NEOHTOP_BUILTINS = {
    "catppuccin-latte",
    "catppuccin-mocha",
    "dracula",
    "gruvbox-dark",
    "nord",
    "one-dark",
    "rose-pine",
    "solarized-dark",
    "tokyo-night",
}


def ascii_fold(text: str) -> str:
    """Drop accents so generated comments can stay pure ASCII.

    starship.toml has to be ASCII end to end — that is what stops a transport
    that mangles non-ASCII from blanking the glyph escapes — and theme names
    like "Catppuccin Frappe" would otherwise smuggle a non-ASCII byte in
    through a comment.
    """
    return (
        unicodedata.normalize("NFKD", text)
        .encode("ascii", "ignore")
        .decode("ascii")
    )


def mix(a: str, b: str, t: float = 0.5) -> str:
    """Blend two "rrggbb" strings, t=0 giving a and t=1 giving b."""
    left = [int(a[i : i + 2], 16) for i in (0, 2, 4)]
    right = [int(b[i : i + 2], 16) for i in (0, 2, 4)]
    return "".join(f"{round(x + (y - x) * t):02x}" for x, y in zip(left, right))


class Theme:
    def __init__(self, ident: str, name: str, dark: bool, bg: str, fg: str, ansi: list[str]):
        self.id, self.name, self.dark = ident, name, dark
        self.bg, self.fg, self.ansi = bg, fg, ansi

    @property
    def filename(self) -> str:
        return "iterminal-" + FILENAME_ALIASES.get(self.id, self.id)

    # ---- derived colours ------------------------------------------------
    #
    # A 16-colour palette has no "surface" or "orange", but the companion
    # tools want both. Derive them from bg/fg rather than hard-coding, so the
    # same rules hold for the light themes: mixing towards fg lightens a dark
    # background and darkens a light one, which picking ansi[0] would not.

    @property
    def surface(self) -> str:
        """Panel fills, meter troughs, dividers — just off the background."""
        return mix(self.bg, self.fg, 0.12)

    @property
    def muted(self) -> str:
        """De-emphasised text that still has to be readable."""
        return mix(self.bg, self.fg, 0.55)

    @property
    def orange(self) -> str:
        """No ANSI slot for it; halfway between red and yellow is close."""
        return mix(self.ansi[1], self.ansi[3])

    def segment(self, accent: str) -> str:
        """A prompt segment background: the accent, dimmed into the bg."""
        return mix(self.bg, accent, 0.20)

    def render(self) -> str:
        lines = [
            f"# {self.name} — {'dark' if self.dark else 'light'}",
            "#",
            "# Generated from Sources/iTERMiNAL/Chrome/TerminalTheme.swift by",
            "# contrib/ghostty/export-themes.py. Edit the Swift source and re-run the",
            "# script rather than editing this file, or the two drift apart.",
            "",
            f"background = #{self.bg}",
            f"foreground = #{self.fg}",
            f"cursor-color = #{self.fg}",
            "",
        ]
        lines += [f"palette = {i}=#{c}" for i, c in enumerate(self.ansi)]
        return "\n".join(lines) + "\n"


def parse(source: Path) -> list[Theme]:
    text = source.read_text(encoding="utf-8")
    themes = []
    for match in THEME_RE.finditer(text):
        ansi = ANSI_RE.findall(match.group("ansi"))
        if len(ansi) != 16:
            raise SystemExit(
                f"{match.group('id')}: expected 16 ANSI colours, found {len(ansi)}"
            )
        themes.append(
            Theme(
                match.group("id"),
                match.group("name"),
                match.group("dark") == "true",
                match.group("bg").lower(),
                match.group("fg").lower(),
                [c.lower() for c in ansi],
            )
        )
    # A partial parse is the dangerous case: THEME_RE wants an exact field
    # order, so reformatting one literal drops just that theme, and a plain
    # regenerate would then delete its file as "no longer in the Swift
    # source". Count the declarations independently and refuse to write
    # anything unless every one of them parsed.
    declared = len(DECL_RE.findall(text))
    if len(themes) != declared:
        parsed = {t.id for t in themes}
        raise SystemExit(
            f"parsed {len(themes)} of {declared} themes in {source.name}.\n"
            "THEME_RE matches a fixed field order, so a reformatted literal "
            "silently drops out — refusing to write or delete anything.\n"
            "Check the declarations that did not parse, or update THEME_RE.\n"
            f"Parsed: {', '.join(sorted(parsed)) or '(none)'}"
        )
    return themes


# ---------------------------------------------------------------------------
# Companion emitters. Each takes a Theme and returns the file text, or None
# when that tool cannot represent the palette at all.
# ---------------------------------------------------------------------------

GENERATED_BY = "contrib/ghostty/export-themes.py --extras"


def emit_btop(t: Theme) -> str:
    a = t.ansi
    return f"""# {t.name} — btop theme
#
# Generated for the {t.filename} palette by {GENERATED_BY}.
# Install to ~/.config/btop/themes/iterminal.theme and set
# `color_theme = "iterminal"` in ~/.config/btop/btop.conf, or pick it from
# Esc -> Options -> Color theme.
#
# Each box gets its own accent so the panels read as separate cards rather
# than one grey grid.

theme[main_bg]="#{t.bg}"
theme[main_fg]="#{t.fg}"
theme[title]="#{t.fg}"
theme[hi_fg]="#{a[2]}"
theme[selected_bg]="#{t.surface}"
theme[selected_fg]="#{a[3]}"
theme[inactive_fg]="#{a[8]}"
theme[graph_text]="#{t.muted}"
theme[meter_bg]="#{t.surface}"
theme[proc_misc]="#{a[6]}"

# Box borders — one accent each.
theme[cpu_box]="#{a[2]}"
theme[mem_box]="#{a[4]}"
theme[net_box]="#{a[5]}"
theme[proc_box]="#{t.orange}"
theme[div_line]="#{t.surface}"

# Temperature: green -> yellow -> red.
theme[temp_start]="#{a[2]}"
theme[temp_mid]="#{a[3]}"
theme[temp_end]="#{a[1]}"

# CPU load.
theme[cpu_start]="#{a[2]}"
theme[cpu_mid]="#{a[3]}"
theme[cpu_end]="#{a[1]}"

# Memory: free, cached, available, used.
theme[free_start]="#{a[1]}"
theme[free_mid]="#{a[3]}"
theme[free_end]="#{a[2]}"
theme[cached_start]="#{a[4]}"
theme[cached_mid]="#{a[6]}"
theme[cached_end]="#{a[2]}"
theme[available_start]="#{a[1]}"
theme[available_mid]="#{a[3]}"
theme[available_end]="#{a[2]}"
theme[used_start]="#{a[2]}"
theme[used_mid]="#{a[3]}"
theme[used_end]="#{a[1]}"

# Network throughput.
theme[download_start]="#{a[2]}"
theme[download_mid]="#{a[6]}"
theme[download_end]="#{a[4]}"
theme[upload_start]="#{a[3]}"
theme[upload_mid]="#{t.orange}"
theme[upload_end]="#{a[1]}"

# Process list CPU column.
theme[process_start]="#{a[2]}"
theme[process_mid]="#{a[3]}"
theme[process_end]="#{a[1]}"
"""


# Everything in starship.toml except the palette is fixed, so keep it as one
# template with a single hole. The \\u escapes must survive verbatim: written
# as literal characters they get blanked out by anything that mangles
# private-use codepoints, which silently leaves a prompt of empty blocks.
STARSHIP_TEMPLATE = '''# Starship prompt, matching the {theme_name} palette.
#
# Generated for the {filename} palette by {generated_by}.
#
#   brew install starship
#   echo 'eval "$(starship init zsh)"' >> ~/.zshrc
#
# Install to ~/.config/starship.toml. Needs a Nerd Font for the powerline
# separators and icons - the same one Ghostty is configured with.
#
# Every glyph below is written as a TOML \\u escape rather than a literal
# character, so the file stays plain ASCII. Pasting it through an editor or
# terminal that mangles private-use codepoints can silently blank the icons
# out, which leaves a prompt of empty coloured blocks; escapes survive that.
# U+E0B0 is the powerline separator and U+E0A0 the git branch glyph.

"$schema" = 'https://starship.rs/config-schema.json'

format = """
$os\\
$username\\
[\\uE0B0](fg:bg_dim bg:bg_green)\\
$directory\\
[\\uE0B0](fg:bg_green bg:bg_blue)\\
$git_branch\\
$git_status\\
[\\uE0B0](fg:bg_blue bg:bg_purple)\\
$nodejs\\
$python\\
$rust\\
$golang\\
$swift\\
[\\uE0B0](fg:bg_purple bg:bg_dim)\\
$cmd_duration\\
[\\uE0B0](fg:bg_dim)\\
$line_break\\
$character"""

palette = 'iterminal'
add_newline = true

[palettes.iterminal]
{palette}

[os]
disabled = false
style = "bg:bg_dim fg:fg"
format = '[ $symbol ]($style)'

[os.symbols]
Macos = "\\U000F0035"
Arch = "\\U000F08C7"
Ubuntu = "\\U000F0548"
Debian = "\\U000F08DA"
Linux = "\\U000F033D"
Windows = "\\U000F0372"

[username]
show_always = false
style_user = "bg:bg_dim fg:fg"
style_root = "bg:bg_dim fg:red"
format = '[$user ]($style)'

[directory]
style = "bg:bg_green fg:green"
format = '[ $path ]($style)'
truncation_length = 3
truncation_symbol = "\\u2026/"
read_only = " \\uF023"

# No [directory.substitutions]: swapping a folder name for an icon hides the
# name, and gives you a blank segment outright if the font lacks that glyph.
# Real names cost a few columns and always render.

[git_branch]
symbol = "\\uE0A0"
style = "bg:bg_blue fg:blue"
format = '[ $symbol $branch ]($style)'

[git_status]
style = "bg:bg_blue fg:orange"
format = '[$all_status$ahead_behind ]($style)'

# The language modules keep starship's own symbols - it ships a sensible one
# per language, and they track upstream Nerd Font changes without help here.
[nodejs]
style = "bg:bg_purple fg:purple"
format = '[ $symbol( $version) ]($style)'

[python]
style = "bg:bg_purple fg:purple"
format = '[ $symbol( $version) ]($style)'

[rust]
style = "bg:bg_purple fg:purple"
format = '[ $symbol( $version) ]($style)'

[golang]
style = "bg:bg_purple fg:purple"
format = '[ $symbol( $version) ]($style)'

[swift]
style = "bg:bg_purple fg:purple"
format = '[ $symbol( $version) ]($style)'

[cmd_duration]
min_time = 2_000
style = "bg:bg_dim fg:yellow"
format = '[ took $duration ]($style)'

# Plain arrows rather than private-use glyphs: the prompt marker is the one
# thing that must render even when the font is wrong.
[character]
success_symbol = "[\\u276F](bold green)"
error_symbol = "[\\u276F](bold red)"
vimcmd_symbol = "[\\u276E](bold yellow)"
'''


def emit_starship(t: Theme) -> str:
    a = t.ansi
    palette = "\n".join(
        f"{k:<9} = '#{v}'"
        for k, v in (
            ("fg", t.fg),
            ("bg_dim", t.surface),
            ("bg_green", t.segment(a[2])),
            ("bg_blue", t.segment(a[4])),
            ("bg_purple", t.segment(a[5])),
            ("green", a[2]),
            ("blue", a[4]),
            ("aqua", a[6]),
            ("yellow", a[3]),
            ("orange", t.orange),
            ("red", a[1]),
            ("purple", a[5]),
            ("grey", t.muted),
        )
    )
    return STARSHIP_TEMPLATE.format(
        theme_name=ascii_fold(t.name),
        filename=t.filename,
        generated_by=GENERATED_BY,
        palette=palette,
    )


def emit_yazi(t: Theme) -> str:
    a = t.ansi
    # Only [mgr] and [filetype] — those key names are confirmed upstream.
    # Guessing at [pick]/[tabs] keys would buy very little.
    return f"""# {t.name} — yazi theme
#
# Generated for the {t.filename} palette by {GENERATED_BY}.
# Install to ~/.config/yazi/theme.toml.

[mgr]
cwd = {{ fg = "#{a[6]}" }}

find_keyword  = {{ fg = "#{a[3]}", bold = true, italic = true }}
find_position = {{ fg = "#{a[5]}", bg = "reset", bold = true, italic = true }}

marker_copied   = {{ fg = "#{a[2]}", bg = "#{a[2]}" }}
marker_cut      = {{ fg = "#{a[1]}", bg = "#{a[1]}" }}
marker_marked   = {{ fg = "#{a[6]}", bg = "#{a[6]}" }}
marker_selected = {{ fg = "#{a[3]}", bg = "#{a[3]}" }}

count_copied   = {{ fg = "#{t.bg}", bg = "#{a[2]}" }}
count_cut      = {{ fg = "#{t.bg}", bg = "#{a[1]}" }}
count_selected = {{ fg = "#{t.bg}", bg = "#{a[3]}" }}

border_symbol = "│"
border_style  = {{ fg = "#{t.surface}" }}

symlink_target = {{ fg = "#{t.muted}", italic = true }}

[filetype]
rules = [
    {{ mime = "image/*", fg = "#{a[3]}" }},
    {{ mime = "{{audio,video}}/*", fg = "#{a[5]}" }},
    {{ mime = "application/{{zip,rar,7z-compressed,xz,zstd,tar,gzip,bzip}}*", fg = "#{a[1]}" }},
    {{ mime = "application/{{pdf,doc,rtf}}", fg = "#{a[6]}" }},
    {{ name = "*", is = "orphan", fg = "#{a[1]}" }},
    {{ name = "*", is = "exec", fg = "#{a[2]}" }},
    {{ name = "*/", fg = "#{a[4]}" }},
]
"""


def emit_fzf(t: Theme) -> str:
    a = t.ansi
    # Only element names confirmed in fzf's man page — an unrecognised one is
    # a hard error at startup, which would take the user's shell with it.
    pairs = [
        ("fg", t.fg),
        ("bg", t.bg),
        ("hl", a[2]),
        ("fg+", t.fg),
        ("bg+", t.surface),
        ("hl+", a[2]),
        ("gutter", t.bg),
        ("info", a[5]),
        ("border", t.surface),
        ("prompt", a[4]),
        ("pointer", a[1]),
        ("marker", a[3]),
        ("spinner", a[5]),
        ("header", a[6]),
    ]
    colours = ",".join(f"{k}:#{v}" for k, v in pairs)
    return f"""# {t.name} — fzf colours
#
# Generated for the {t.filename} palette by {GENERATED_BY}.
# Source this from your shell rc:
#
#   [ -f ~/.config/ghostty/fzf.sh ] && . ~/.config/ghostty/fzf.sh

export FZF_DEFAULT_OPTS="${{FZF_DEFAULT_OPTS:-}} --color={colours}"
"""


def emit_neohtop(t: Theme) -> str | None:
    name = FILENAME_ALIASES.get(t.id, t.id)
    if name not in NEOHTOP_BUILTINS:
        return None
    # neohtop-cli has no custom-theme format, so this only selects one of its
    # built-ins. The names were read off the README's theme table rather than
    # a schema — `neohtop-cli` lists them if this one is ever rejected.
    return json.dumps(
        {
            "columns": ["pid", "name", "cpu", "memory", "status", "user", "command"],
            "refresh_rate_ms": 1000,
            "theme": name,
        },
        indent=2,
    ) + "\n"


# filename -> emitter. An emitter returning None writes nothing.
EXTRAS = {
    "btop.theme": emit_btop,
    "starship.toml": emit_starship,
    "theme.toml": emit_yazi,
    "fzf.sh": emit_fzf,
    "config.json": emit_neohtop,
}


def write_extras(theme: Theme, out: Path) -> list[str]:
    out.mkdir(parents=True, exist_ok=True)
    written = []
    for filename, emitter in EXTRAS.items():
        text = emitter(theme)
        if text is None:
            continue
        (out / filename).write_text(text, encoding="utf-8")
        written.append(filename)
    return written


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify themes/ matches the Swift source instead of writing it",
    )
    parser.add_argument(
        "--extras",
        metavar="THEME",
        help="emit companion configs for this theme (e.g. iterminal-nord)",
    )
    parser.add_argument(
        "--out",
        metavar="DIR",
        type=Path,
        help="where --extras writes its files",
    )
    args = parser.parse_args()

    if not SOURCE.exists():
        raise SystemExit(f"cannot find {SOURCE}")

    themes = parse(SOURCE)

    # --extras never touches themes/, so it returns before the regenerate and
    # delete pass below.
    if args.extras:
        if not args.out:
            raise SystemExit("--extras needs --out DIR")
        by_name = {t.filename: t for t in themes}
        theme = by_name.get(args.extras)
        if theme is None:
            raise SystemExit(
                f"unknown theme {args.extras!r}. Valid names:\n  "
                + "\n  ".join(sorted(by_name))
            )
        written = write_extras(theme, args.out)
        print(f"wrote {len(written)} companion configs for {theme.filename} to {args.out}")
        for name in written:
            print(f"  {name}")
        if "config.json" not in written:
            print("  (no neohtop-cli config: it has no built-in matching this palette)")
        return 0
    if args.out:
        raise SystemExit("--out only means something with --extras")

    THEMES.mkdir(parents=True, exist_ok=True)

    stale: list[str] = []
    for theme in themes:
        path = THEMES / theme.filename
        want = theme.render()
        if args.check:
            if not path.exists():
                stale.append(f"{theme.filename}: missing")
            elif path.read_text(encoding="utf-8") != want:
                stale.append(f"{theme.filename}: out of date")
        else:
            path.write_text(want, encoding="utf-8")

    expected = {t.filename for t in themes}
    for path in sorted(THEMES.iterdir()):
        if path.is_file() and path.name not in expected:
            if args.check:
                stale.append(f"{path.name}: no longer in the Swift source")
            else:
                path.unlink()

    if args.check:
        if stale:
            print("themes/ has drifted from TerminalTheme.swift:", file=sys.stderr)
            for line in stale:
                print(f"  {line}", file=sys.stderr)
            print("\nRun contrib/ghostty/export-themes.py to regenerate.", file=sys.stderr)
            return 1
        print(f"themes/ is up to date ({len(themes)} themes)")
        return 0

    print(f"wrote {len(themes)} themes to {THEMES}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
