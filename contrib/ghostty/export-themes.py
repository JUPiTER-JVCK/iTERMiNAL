#!/usr/bin/env python3
"""Export the app's terminal palettes as Ghostty theme files.

TerminalTheme.swift is the single source of truth for iTERMiNAL's twenty
colour schemes. Ghostty wants the same data as one file per theme, so this
reads the Swift literals and writes `themes/iterminal-<id>`.

    ./export-themes.py            # regenerate themes/
    ./export-themes.py --check    # exit 1 if themes/ has drifted from Swift

The --check mode is what keeps the two honest: change a colour in Swift
without re-running this and it reports exactly which files are stale.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Sources/iTERMiNAL/Chrome/TerminalTheme.swift"
THEMES = Path(__file__).resolve().parent / "themes"

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


class Theme:
    def __init__(self, ident: str, name: str, dark: bool, bg: str, fg: str, ansi: list[str]):
        self.id, self.name, self.dark = ident, name, dark
        self.bg, self.fg, self.ansi = bg, fg, ansi

    @property
    def filename(self) -> str:
        return "iterminal-" + FILENAME_ALIASES.get(self.id, self.id)

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
    if not themes:
        raise SystemExit(f"no themes parsed out of {source} — has the literal format changed?")
    return themes


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify themes/ matches the Swift source instead of writing it",
    )
    args = parser.parse_args()

    if not SOURCE.exists():
        raise SystemExit(f"cannot find {SOURCE}")

    themes = parse(SOURCE)
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
