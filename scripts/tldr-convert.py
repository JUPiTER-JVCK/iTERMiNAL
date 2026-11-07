#!/usr/bin/env python3
"""Turns the tldr-pages archive into the one JSON file the Cheatsheet page reads.

    scripts/tldr-convert.py ARCHIVE OUTPUT_DIR VERSION [CONTENT_SHA256]

Reads the English `common` and `osx` pages out of a tldr-pages archive — GitHub's
source archive of one commit (`tldr-<commit>/pages/...`), or the release's own
`tldr.zip` (`pages/...`) — and writes, into OUTPUT_DIR:

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

With a CONTENT_SHA256 the pages are checked against it before anything is
converted or written, and a mismatch is an error. It is a hash of the pages this
script reads (see `content_digest`), not of the archive: the same commit comes
back in a zip that differs byte for byte whenever GitHub packs it differently,
and a hash of the file would then refuse data that has not changed. Without one
the digest is printed and the conversion goes ahead, which is how the digest for
a new commit is found.

Standard library only, and nothing here needs a Mac, so the whole script can be
proven anywhere.
"""
import hashlib
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


def archive_root(names) -> str:
    """The folder every entry sits in, with its trailing slash — "tldr-<commit>/"
    for GitHub's source archive of a commit — or "" for an archive laid out from
    the top, as the release's own tldr.zip is."""
    if any(name.startswith("pages/") for name in names):
        return ""
    tops = {name.split("/", 1)[0] for name in names if "/" in name}
    if len(tops) != 1:
        raise ValueError("this does not look like a tldr-pages archive: there is no pages/ folder, "
                         "and no single folder that holds one")
    return tops.pop() + "/"


def page_names(archive: zipfile.ZipFile, root: str):
    """(platform, entry name) of every page the conversion reads, in a fixed order."""
    found = []
    for platform in PLATFORMS:
        prefix = f"{root}pages/{platform}/"
        for name in sorted(archive.namelist()):
            if name.startswith(prefix) and name.endswith(".md") and "/" not in name[len(prefix):]:
                found.append((platform, name))
    return found


def content_digest(archive: zipfile.ZipFile, root: str) -> str:
    """SHA-256 of what this script reads, and of nothing about how it was packed.

    Every page it converts, by its path from the top of the archive and its
    bytes, and the licence that travels with them. The archive's own folder, the
    order of its entries, their dates and how they are compressed do not count,
    and neither do the other platforms, the translations and everything else in
    the archive, which are never read. A page changed, added, removed, renamed or
    moved between `common` and `osx` does count.

    Each file contributes its path, a zero byte and the 32 bytes of its own
    SHA-256, so where one file ends and the next begins cannot be mistaken.
    """
    files = [(name[len(root):], archive.read(name)) for _, name in page_names(archive, root)]
    files.append(("LICENSE.md", archive.read(f"{root}LICENSE.md")))
    digest = hashlib.sha256()
    for path, data in sorted(files):
        digest.update(path.encode("utf-8"))
        digest.update(b"\0")
        digest.update(hashlib.sha256(data).digest())
    return digest.hexdigest()


def read_pages(archive: zipfile.ZipFile, root: str):
    pages = {}
    for platform, name in page_names(archive, root):
        stem = name[len(f"{root}pages/{platform}/"):-3]
        pages[stem] = (platform, archive.read(name).decode("utf-8"))
    return pages


def convert(archive: zipfile.ZipFile, root: str = ""):
    raw = read_pages(archive, root)
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
    if len(sys.argv) not in (4, 5):
        print("usage: tldr-convert.py ARCHIVE OUTPUT_DIR VERSION [CONTENT_SHA256]", file=sys.stderr)
        return 2
    archive_path, out_dir, version = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
    expected = sys.argv[4].strip().lower() if len(sys.argv) == 5 else None
    with zipfile.ZipFile(archive_path) as archive:
        try:
            root = archive_root(archive.namelist())
            if f"{root}LICENSE.md" not in archive.namelist():
                raise ValueError("the archive has no LICENSE.md, which has to travel with the pages")
        except ValueError as error:
            print(f"error: {error}", file=sys.stderr)
            return 1
        got = content_digest(archive, root)
        print(f"content sha256 {got}")
        if expected is not None and got != expected:
            print("error: the pages in the archive are not the pinned ones", file=sys.stderr)
            print(f"  expected {expected}", file=sys.stderr)
            print(f"  got      {got}", file=sys.stderr)
            return 1
        pages = convert(archive, root)
        licence = archive.read(f"{root}LICENSE.md").decode("utf-8")

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
