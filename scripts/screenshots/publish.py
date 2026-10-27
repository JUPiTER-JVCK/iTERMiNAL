#!/usr/bin/env python3
"""Puts the Screenshots workflow's pictures where the README looks for them.

    publish.py ARTIFACT_DIR [OUTPUT_DIR]

ARTIFACT_DIR is the unpacked `screenshots` artifact of a run of the Screenshots
workflow; OUTPUT_DIR defaults to docs/images. Each picture the README uses is
read from the one and written to the other, and nothing else is: the artifact
holds everything the capture took, including pictures that are only there to
find out why another came out wrong, and one is not fit to publish at all
(see NOT_PUBLISHED).

The app draws every picture at twice the size it appears. The README shows
all but the first at half that — the exact 2x2 average, so the anti-aliasing
the app drew survives — which is sharp where it is shown and a fraction of
the size in the repository. The first is kept whole, because it is shown wide.

Standard library only. It writes 8-bit RGBA PNGs, and reads the same: what
AppKit's PNG writer produces.
"""
import os
import struct
import sys
import zlib

# What the README shows, in the order it shows it. Each name is also the
# picture's file name in the artifact.
README_PICTURES = [
    # The whole window, kept at the size it was drawn.
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
WHOLE_SIZE = {"workspace"}

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


def halve(width, height, rows):
    """Half the size each way: the average of each 2x2 block, weighted by alpha."""
    out_width, out_height = width // 2, height // 2
    out = []
    for y in range(out_height):
        blocks = []
        for row in (rows[2 * y], rows[2 * y + 1]):
            for offset in (0, 4):
                blocks.append((row[offset::8], row[offset + 1::8], row[offset + 2::8], row[offset + 3::8]))
        line = bytearray(out_width * 4)
        for x in range(out_width):
            alphas = [block[3][x] for block in blocks]
            total = sum(alphas)
            if not total:
                continue
            for channel in range(3):
                mixed = sum(block[channel][x] * alpha for block, alpha in zip(blocks, alphas))
                line[4 * x + channel] = (mixed + total // 2) // total
            line[4 * x + 3] = (total + 2) // 4
        out.append(line)
    return out_width, out_height, out


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
        if name not in WHOLE_SIZE:
            width, height, rows = halve(width, height, rows)
        path = os.path.join(out, name + ".png")
        write_png(path, width, height, rows)
        size = os.path.getsize(path)
        total += size
        print(f"{name:22s} {width}x{height}  {size / 1024:.0f} KB")
    print(f"{len(README_PICTURES)} pictures, {total / 1024:.0f} KB")


if __name__ == "__main__":
    main()
