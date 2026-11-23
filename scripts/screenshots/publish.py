#!/usr/bin/env python3
"""Puts the Screenshots workflow's pictures where the README looks for them.

    publish.py ARTIFACT_DIR [OUTPUT_DIR]

ARTIFACT_DIR is the unpacked `screenshots` artifact of a run of the Screenshots
workflow; OUTPUT_DIR defaults to docs/images. Each picture the README uses is
read from the one and written to the other, and nothing else is: the artifact
holds everything the capture took, including pictures that are only there to
find out why another came out wrong, and one is not fit to publish at all
(see NOT_PUBLISHED).

The app draws every picture at twice the size it appears (a Retina display's
own resolution), and every picture is published at that size: a window is
about 2,200 pixels wide, a settings window about 2,000. Nothing is scaled
down here, so the text in a picture is as sharp as on the screen it was drawn
for, and GitHub scales it to fit on any display. The README sets each picture's
displayed width itself (the `width` on its `<img>`), which is how a small
sheet stays small and a window fills the page. Pictures were once halved to a
quarter of the pixels, and the interface text in them came out too small to
read once the page fitted them to a column.

Each picture is read and written again with every row filtered cheaply and
the whole compressed as hard as zlib goes, because AppKit's PNG writer does
not, and these are large files.

Standard library only. It reads and writes 8-bit RGBA PNGs, which is what
AppKit's PNG writer produces.
"""
import os
import struct
import sys
import zlib

# What the README shows, in the order it shows it. Each name is also the
# picture's file name in the artifact.
README_PICTURES = [
    "workspace",
    "split-panes",
    "dock",
    "tasks",
    "terminal-context-menu",
    "terminal-colors",
    "terminal-colors-man",
    "terminal-tools",
    "composer-history",
    "ai-assistant",
    "error-help",
    "http-client",
    "site-explorer",
    "extract-images",
    "extract-query",
    "extract-crawl-confirm",
    "extract-crawl",
    "extract-ask-confirm",
    "extract-ask",
    "extract-download-confirm",
    "extract-crawl-links",
    "browser",
    "files",
    "files-sftp-denied",
    "files-sftp-shared",
    "superfile",
    "btop",
    "command-palette",
    "keyboard-shortcuts",
    "light-theme",
    "custom-look",
    "settings-appearance",
    "settings-ai",
    "settings-security",
]
# Taken, and still not for the README. Settings -> Connections lists what
# Bonjour finds on the network, which on a runner is the runner's own name.
NOT_PUBLISHED = {"settings-connections"}


def read_png(path):
    with open(path, "rb") as handle:
        data = handle.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{path}: not a PNG")
    position = 8
    compressed = bytearray()
    header = None
    while position < len(data):
        (length,) = struct.unpack(">I", data[position:position + 4])
        kind = data[position + 4:position + 8]
        body = data[position + 8:position + 8 + length]
        position += 12 + length
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            compressed += body
        elif kind == b"IEND":
            break
    width, height, depth, color_type, _, _, interlace = header
    if depth != 8 or color_type != 6 or interlace != 0:
        raise SystemExit(f"{path}: expected an 8-bit RGBA PNG without interlacing")
    stride = width * 4
    raw = zlib.decompress(bytes(compressed))
    rows = []
    previous = bytearray(stride)
    offset = 0
    for _ in range(height):
        filter_type = raw[offset]
        line = bytearray(raw[offset + 1:offset + 1 + stride])
        offset += 1 + stride
        if filter_type == 1:
            for i in range(4, stride):
                line[i] = (line[i] + line[i - 4]) & 255
        elif filter_type == 2:
            for i in range(stride):
                line[i] = (line[i] + previous[i]) & 255
        elif filter_type == 3:
            for i in range(stride):
                left = line[i - 4] if i >= 4 else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 255
        elif filter_type == 4:
            for i in range(stride):
                a = line[i - 4] if i >= 4 else 0
                b = previous[i]
                c = previous[i - 4] if i >= 4 else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                predictor = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + predictor) & 255
        rows.append(line)
        previous = line
    return width, height, rows


def write_png(path, width, height, rows):
    """Each row takes whichever of None, Sub and Up is cheapest."""

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)

    def cost(data):
        return sum(b if b < 128 else 256 - b for b in data)

    raw = bytearray()
    previous = bytearray(width * 4)
    for row in rows:
        sub = bytearray((row[i] - (row[i - 4] if i >= 4 else 0)) & 255 for i in range(len(row)))
        up = bytearray((a - b) & 255 for a, b in zip(row, previous))
        choice = min(((cost(row), 0, row), (cost(sub), 1, sub), (cost(up), 2, up)), key=lambda option: option[0])
        raw.append(choice[1])
        raw += choice[2]
        previous = row
    with open(path, "wb") as handle:
        handle.write(b"\x89PNG\r\n\x1a\n")
        handle.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)))
        handle.write(chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
        handle.write(chunk(b"IEND", b""))


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    source = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(__file__), "..", "..", "docs", "images")
    os.makedirs(out, exist_ok=True)
    missing = [name for name in README_PICTURES if not os.path.exists(os.path.join(source, name + ".png"))]
    if missing:
        raise SystemExit(f"not in {source}: {', '.join(missing)}")
    assert not NOT_PUBLISHED.intersection(README_PICTURES)
    total = 0
    for name in README_PICTURES:
        width, height, rows = read_png(os.path.join(source, name + ".png"))
        path = os.path.join(out, name + ".png")
        write_png(path, width, height, rows)
        size = os.path.getsize(path)
        total += size
        print(f"{name:22s} {width}x{height}  {size / 1024:.0f} KB")
    print(f"{len(README_PICTURES)} pictures, {total / 1024:.0f} KB")


if __name__ == "__main__":
    main()
