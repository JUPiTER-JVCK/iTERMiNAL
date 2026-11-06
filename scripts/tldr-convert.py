#!/usr/bin/env python3
"""Turns the tldr-pages archive into the one JSON file the Cheatsheet page reads.

    scripts/tldr-convert.py tldr.zip OUTPUT_DIR VERSION

Reads the English `common` and `osx` pages out of the release's `tldr.zip` and
writes, into OUTPUT_DIR:

    tldr.json                         every page, in the shape TldrData reads
    licenses/tldr-pages-LICENSE.md    the licence, as the archive carries it
    manifest.json                     the version, for whoever wants to report it

tldr-pages is CC BY 4.0, which asks for credit and for changes to be marked.
The licence travels with the data and the page credits the source; the changes
are the ones listed below, and the page says the examples are reformatted.

What is changed, and nothing else:

  * `[c]reate` mnemonics lose their brackets, and the description's first
    letter is capitalised again.
  * `{{[-C|--directory]}}`, tldr's "short or long, as you prefer", becomes the
    long form, which says what it does. Any other `{{...}}` is left alone: it
    is a placeholder, and the page shows it as one.
  * Backticks in descriptions are dropped, since the page shows plain text.
  * A page for a subcommand (`git-reset`, whose title is "git reset") is filed
    under its program (`git`) as a section named "reset". The title is what
    decides, not the file name: `ssh-keygen` is a program of its own, and its
    title has no space in it.
  * Where macOS has its own page for a command, that one replaces the common
    one, as tldr's own clients do on a Mac.

Standard library only, and nothing here needs a Mac, so the whole script can be
proven anywhere.
"""
import json
import re
import sys
import zipfile
from pathlib import Path

FORMAT = 1
# Later wins: a page written for macOS replaces the common one of the same name.
PLATFORMS = ("common", "osx")
# A conversion that finds far less than this has gone wrong, and shipping the
# result would look like it had worked. v2.3 gives 3,556 programs and 22,567
# examples once subcommand pages are filed under their programs; these leave
# room for the collection to be tidied without the build failing, and not for
# half of it to go missing.
MIN_PAGES = 3000
MIN_EXAMPLES = 20000

MNEMONIC = re.compile(r"\[([A-Za-z0-9])\]")
# Either side may be a bare "-" (colcrt has {{[-|--no-underlining]}}).
FLAG_CHOICE = re.compile(r"\{\{\[(-[^|\]{}]*)\|(-[^|\]{}]*)\]\}\}")
# What the changes above should leave none of.
LEFTOVERS = re.compile(r"\{\{\[-|\[[A-Za-z0-9]\][A-Za-z]|`")


def clean_description(text: str) -> str:
    starts_with_mnemonic = text.startswith("[")
    text = MNEMONIC.sub(r"\1", text).replace("`", "")
    text = " ".join(text.split())
    if starts_with_mnemonic and text:
        text = text[0].upper() + text[1:]
    return text


def long_form(match: "re.Match[str]") -> str:
    first, second = match.group(1), match.group(2)
    if second.startswith("--"):
        return second
    if first.startswith("--"):
        return first
    return second


def clean_command(text: str) -> str:
    return FLAG_CHOICE.sub(long_form, text.strip())


def parse_page(text: str):
    """(title, summary, url, [(description, command)]) of one page."""
    lines = text.split("\n")
    title = lines[0][2:].strip() if lines and lines[0].startswith("# ") else ""
    summary, url, examples = [], None, []
    i = 1
    while i < len(lines):
        line = lines[i]
        if line.startswith("> "):
            body = line[2:].strip()
            if body.startswith("More information"):
                found = re.search(r"<(https?://[^>\s]+)>", body)
                if found:
                    url = found.group(1)
            elif not body.startswith("See also"):
                summary.append(body.replace("`", ""))
        elif line.startswith("- ") and line.rstrip().endswith(":"):
            j = i + 1
            while j < len(lines) and not lines[j].strip():
                j += 1
            if j < len(lines) and len(lines[j]) > 2 and lines[j].startswith("`") and lines[j].endswith("`"):
                description = clean_description(line[2:].rstrip()[:-1])
                command = clean_command(lines[j][1:-1])
                if description and command:
                    examples.append((description, command))
                i = j
        i += 1
    return title, " ".join(summary), url, examples


def read_pages(archive: zipfile.ZipFile):
    pages = {}
    for platform in PLATFORMS:
        prefix = f"pages/{platform}/"
        for name in archive.namelist():
            if name.startswith(prefix) and name.endswith(".md") and "/" not in name[len(prefix):]:
                stem = name[len(prefix):-3]
                pages[stem] = (platform, archive.read(name).decode("utf-8"))
    return pages


def convert(archive: zipfile.ZipFile):
    raw = read_pages(archive)
    parsed = {name: parse_page(text) for name, (_, text) in raw.items()}

    # A page whose title is "git reset" and whose file is git-reset belongs to
    # git, if git has a page of its own with a one-word title.
    def program_of(name):
        title = parsed[name][0]
        words = title.split()
        if len(words) < 2 or "-".join(words) != name:
            return None
        for k in range(1, len(words)):
            parent = "-".join(words[:k])
            if parent in parsed and parsed[parent][0] == parent:
                return parent, " ".join(words[k:])
        return None

    children = {}
    standalone = []
    for name in sorted(parsed):
        owner = program_of(name)
        if owner:
            children.setdefault(owner[0], []).append((owner[1], name))
        else:
            standalone.append(name)

    pages = []
    for name in standalone:
        title, summary, url, examples = parsed[name]
        entries = [[d, c] for d, c in examples]
        for section, child in sorted(children.get(name, [])):
            entries += [[d, c, section] for d, c in parsed[child][3]]
        if not entries:
            continue
        page = {"n": name, "p": raw[name][0], "s": summary, "x": entries}
        if url:
            page["u"] = url
        pages.append(page)
    return pages


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__.split("\n\n")[0], file=sys.stderr)
        return 2
    archive_path, out_dir, version = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
    with zipfile.ZipFile(archive_path) as archive:
        pages = convert(archive)
        licence = archive.read("LICENSE.md").decode("utf-8")

    if "Creative Commons Attribution 4.0" not in licence:
        print("error: the archive's LICENSE.md does not look like CC BY 4.0", file=sys.stderr)
        return 1
    examples = sum(len(p["x"]) for p in pages)
    leftovers = [(p["n"], e[1]) for p in pages for e in p["x"] if LEFTOVERS.search(e[0] + " " + e[1])]
    if leftovers:
        print(f"error: {len(leftovers)} examples still hold what the conversion should have removed, "
              f"e.g. {leftovers[:3]}", file=sys.stderr)
        return 1
    if len(pages) < MIN_PAGES or examples < MIN_EXAMPLES:
        print(f"error: converted only {len(pages)} pages and {examples} examples; "
              f"expected at least {MIN_PAGES} and {MIN_EXAMPLES}", file=sys.stderr)
        return 1

    (out_dir / "licenses").mkdir(parents=True, exist_ok=True)
    document = {"format": FORMAT, "source": "tldr-pages", "version": version,
                "license": "CC-BY-4.0", "pages": pages}
    (out_dir / "tldr.json").write_text(
        json.dumps(document, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    (out_dir / "licenses" / "tldr-pages-LICENSE.md").write_text(licence, encoding="utf-8")
    (out_dir / "manifest.json").write_text(json.dumps({"tldr-pages": version}) + "\n", encoding="utf-8")
    print(f"{len(pages)} pages, {examples} examples -> {out_dir / 'tldr.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
