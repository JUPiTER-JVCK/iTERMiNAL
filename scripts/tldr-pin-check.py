#!/usr/bin/env python3
"""Checks what decides whether scripts/fetch-tldr.sh may use the tldr-pages data:
the hash of the pages (`content_digest` in scripts/tldr-convert.py) that
scripts/tools.env pins, and the way the converter refuses what is not them.

    python3 scripts/tldr-pin-check.py

The hash has two jobs that pull against each other. It has to stay the same
when GitHub packs the same commit differently — another folder name, another
order, other dates, other compression — since a pin that went stale on that
would fail every build for no reason, which is what pinning the release's
tldr.zip did. And it has to change when any page the conversion reads does.
Both are held here, on archives made for the purpose: nothing is downloaded.

Standard library only, so CI runs it on the macOS runner as it is.
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
CONVERT = os.path.join(HERE, "tldr-convert.py")

spec = importlib.util.spec_from_file_location("tldr_convert", CONVERT)
convert = importlib.util.module_from_spec(spec)
spec.loader.exec_module(convert)

failures = 0
checks = 0


def check(condition, message):
    global failures, checks
    checks += 1
    if not condition:
        failures += 1
        print("FAIL  " + message)


LICENCE = "Creative Commons Attribution 4.0 International\n"


def page(name, tag=""):
    """A page the conversion accepts: seven examples, nothing left to clean."""
    lines = [f"# {name}", "", f"> Does {name}{tag}.", "> More information: <https://example.com/" + name + ">.", ""]
    for number in range(7):
        lines += [f"- Example {number}{tag}:", "", f"`{name} --flag{number} {{{{path/to/file}}}}`", ""]
    return "\n".join(lines)


def files(count=3100, tag=""):
    """The pages of a tldr-pages checkout, big enough to clear the converter's floors."""
    found = {"LICENSE.md": LICENCE, "README.md": "# tldr\n"}
    for number in range(count):
        found[f"pages/common/tool{number}.md"] = page(f"tool{number}", tag)
    found["pages/osx/caffeinate.md"] = page("caffeinate", tag)
    # Read by nothing.
    found["pages/linux/ip.md"] = page("ip")
    found["pages.fr/common/tool0.md"] = page("tool0", " en français")
    found["index.json"] = "{}"
    return found


def pack(path, contents, root="", compression=zipfile.ZIP_DEFLATED, date=(2026, 1, 1, 0, 0, 0), reverse=False):
    names = sorted(contents, reverse=reverse)
    with zipfile.ZipFile(path, "w", compression) as archive:
        if root:
            archive.writestr(zipfile.ZipInfo(root, date), b"")
        for name in names:
            info = zipfile.ZipInfo(root + name, date)
            info.compress_type = compression
            archive.writestr(info, contents[name])


def digest(path):
    with zipfile.ZipFile(path) as archive:
        return convert.content_digest(archive, convert.archive_root(archive.namelist()))


def run(archive, out, expected=None):
    command = [sys.executable, CONVERT, archive, out, "2.3"] + ([expected] if expected else [])
    return subprocess.run(command, capture_output=True, text=True)


with tempfile.TemporaryDirectory() as folder:
    def at(name):
        return os.path.join(folder, name)

    base = files()

    # The same pages, packed differently, hash the same.
    pack(at("release.zip"), base)
    pack(at("source.zip"), base, root="tldr-0123456789abcdef0123456789abcdef01234567/")
    pack(at("stored.zip"), base, root="tldr-0123456789abcdef0123456789abcdef01234567/", compression=zipfile.ZIP_STORED)
    pack(at("reversed.zip"), base, root="tldr-fedcba9876543210fedcba9876543210fedcba98/", reverse=True, date=(2030, 6, 7, 8, 9, 10))
    pinned = digest(at("release.zip"))
    check(len(pinned) == 64 and all(c in "0123456789abcdef" for c in pinned), "the digest is a lower-case SHA-256")
    check(digest(at("source.zip")) == pinned, "a source archive, under its folder, hashes as the release's does from the top")
    check(digest(at("stored.zip")) == pinned, "compression does not matter")
    check(digest(at("reversed.zip")) == pinned, "neither do the folder's name, the order of entries or their dates")

    # What is not read does not count.
    quiet = dict(base)
    quiet["pages/linux/ip.md"] = "changed"
    quiet["pages.de/common/tool1.md"] = "added"
    quiet["README.md"] = "# something else\n"
    del quiet["index.json"]
    pack(at("quiet.zip"), quiet)
    check(digest(at("quiet.zip")) == pinned, "other platforms, translations and other files are not part of it")
    shallow = dict(base)
    shallow["pages/common/nested/extra.md"] = page("extra")
    pack(at("shallow.zip"), shallow)
    check(digest(at("shallow.zip")) == pinned, "nor is a page in a folder below common, which the conversion does not read")
    notes = dict(base)
    notes["pages/common/notes.txt"] = "not a page"
    pack(at("notes.zip"), notes)
    check(digest(at("notes.zip")) == pinned, "nor a file there that is not markdown")

    # What is read does.
    def differs(change, why):
        edited = dict(base)
        change(edited)
        pack(at("edited.zip"), edited)
        check(digest(at("edited.zip")) != pinned, why)

    def edit_byte(found):
        found["pages/common/tool5.md"] += " "
    differs(edit_byte, "one byte changed in a page changes it")

    def add_page(found):
        found["pages/common/brandnew.md"] = page("brandnew")
    differs(add_page, "a page added changes it")

    def drop_page(found):
        del found["pages/common/tool7.md"]
    differs(drop_page, "a page removed changes it")

    def rename_page(found):
        found["pages/common/tool8-renamed.md"] = found.pop("pages/common/tool8.md")
    differs(rename_page, "a page renamed changes it")

    def move_page(found):
        found["pages/osx/tool9.md"] = found.pop("pages/common/tool9.md")
    differs(move_page, "a page moved from common to osx changes it")

    def swap_pages(found):
        found["pages/common/tool10.md"], found["pages/common/tool11.md"] = found["pages/common/tool11.md"], found["pages/common/tool10.md"]
    differs(swap_pages, "two pages' contents swapped between their names changes it")

    def edit_macos(found):
        found["pages/osx/caffeinate.md"] += "\n"
    differs(edit_macos, "a macOS page changed changes it")

    def edit_licence(found):
        found["LICENSE.md"] += " "
    differs(edit_licence, "the licence changed changes it")

    # Where one file ends and the next begins is not up to the content: a page
    # that holds the next page's name and text is not the two pages. Hashing the
    # paths and bytes one after another would see no difference.
    two = dict(base)
    two["pages/common/zz1.md"] = "X"
    two["pages/common/zz2.md"] = "Y"
    fused = dict(base)
    fused["pages/common/zz1.md"] = "Xpages/common/zz2.mdY"
    pack(at("two.zip"), two)
    pack(at("fused.zip"), fused)
    check(digest(at("two.zip")) != digest(at("fused.zip")), "one page holding the next page's name and text is not the two pages")

    # Which archives are understood.
    check(convert.archive_root(["pages/common/a.md", "LICENSE.md"]) == "", "an archive with pages at the top has no folder")
    check(convert.archive_root(["tldr-abc/", "tldr-abc/pages/common/a.md"]) == "tldr-abc/", "a source archive's folder is found")
    refused = 0
    for odd in (["a.txt"], ["one/pages/a.md", "two/pages/b.md"], []):
        try:
            convert.archive_root(odd)
        except ValueError:
            refused += 1
    check(refused == 3, "an archive with no pages, or with two folders and none of them the pages', is refused")

    # What the converter does with the pin.
    def read(path):
        try:
            with open(path, encoding="utf-8") as handle:
                return handle.read()
        except OSError:
            return None

    out_ok = at("out-ok")
    result = run(at("source.zip"), out_ok, pinned)
    check(result.returncode == 0 and "content sha256 " + pinned in result.stdout, "the pinned pages are converted, and the digest is printed")
    first = read(os.path.join(out_ok, "tldr.json"))
    written = json.loads(first) if first else {}
    check(len(written.get("pages", [])) == 3101 and written.get("version") == "2.3", "from a source archive, the same pages come out as from a release's")
    out_top = at("out-top")
    run(at("release.zip"), out_top, pinned)
    check(first is not None and read(os.path.join(out_top, "tldr.json")) == first, "and the file is the same, whichever way it was packed")
    check(os.path.isdir(out_ok) and sorted(os.listdir(out_ok)) == ["licenses", "manifest.json", "tldr.json"], "and it writes the three files the app and the bundle check read")

    out_none = at("out-none")
    result = run(at("source.zip"), out_none)
    check(result.returncode == 0 and "content sha256 " + pinned in result.stdout,
          "with no hash it prints the digest and converts, which is how a new pin is found")

    wrong = "0" * 64
    out_bad = at("out-bad")
    result = run(at("source.zip"), out_bad, wrong)
    check(result.returncode == 1 and "not the pinned ones" in result.stderr and wrong in result.stderr and pinned in result.stderr,
          "pages that are not the pinned ones are refused, naming both hashes")
    check(not os.path.exists(out_bad), "and nothing is written for them")
    result = run(at("edited.zip"), at("out-edited"), pinned)
    check(result.returncode == 1 and not os.path.exists(at("out-edited")), "a changed licence is not the pinned pages either")
    result = run(at("source.zip"), at("out-upper"), pinned.upper())
    check(result.returncode == 0, "the hash may be given in capitals")

    nolicence = dict(base)
    del nolicence["LICENSE.md"]
    pack(at("nolicence.zip"), nolicence)
    result = run(at("nolicence.zip"), at("out-nolicence"))
    check(result.returncode == 1 and "LICENSE.md" in result.stderr and not os.path.exists(at("out-nolicence")),
          "an archive without the licence is refused, since the licence has to travel with the pages")
    pack(at("small.zip"), files(count=10))
    result = run(at("small.zip"), at("out-small"))
    check(result.returncode == 1 and "converted only" in result.stderr, "far fewer pages than expected is still an error")
    result = subprocess.run([sys.executable, CONVERT], capture_output=True, text=True)
    check(result.returncode == 2 and "usage: tldr-convert.py" in result.stderr, "with the wrong number of arguments it says how it is used")

# The pin itself is well-formed, so a typo in tools.env fails here and not on the Mac.
pin = {}
for line in open(os.path.join(HERE, "tools.env"), encoding="utf-8"):
    if line.startswith(("TLDR_COMMIT=", "TLDR_CONTENT_SHA256=", "TLDR_VERSION=")):
        key, _, value = line.strip().partition("=")
        pin[key] = value
check(len(pin.get("TLDR_COMMIT", "")) == 40 and all(c in "0123456789abcdef" for c in pin["TLDR_COMMIT"]),
      "tools.env pins a full 40-character commit")
check(len(pin.get("TLDR_CONTENT_SHA256", "")) == 64 and all(c in "0123456789abcdef" for c in pin["TLDR_CONTENT_SHA256"]),
      "and a SHA-256 of its pages")
check(pin.get("TLDR_VERSION", "").replace(".", "").isdigit(), "and the release it belongs to")

print("%d/%d tldr pin checks passed" % (checks - failures, checks))
sys.exit(0 if failures == 0 else 1)
