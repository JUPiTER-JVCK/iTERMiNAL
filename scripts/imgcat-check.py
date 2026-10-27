#!/usr/bin/env python3
"""Checks scripts/imgcat from the other side: what it prints is read the way
iTERMiNAL's terminal engine (SwiftTerm) reads an inline image, and what it does
with bad input is held to its exit codes.

    python3 scripts/imgcat-check.py

Runs anywhere with a POSIX sh, base64 and python3 - CI runs it on the macOS
runner, where the tools are the ones a user's Mac has.
"""
import base64
import os
import re
import struct
import subprocess
import sys
import tempfile
import zlib

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "imgcat")

failures = 0
checks = 0


def check(condition, message):
    global failures, checks
    checks += 1
    if not condition:
        failures += 1
        print("FAIL  " + message)


def png(width, height):
    raw = b"".join(b"\x00" + bytes([200, 40, 40, 255]) * width for _ in range(height))

    def chunk(kind, data):
        body = struct.pack(">I", len(data)) + kind + data
        return body + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw))
            + chunk(b"IEND", b""))


def run(args, stdin=None):
    return subprocess.run(["sh", SCRIPT] + args, input=stdin, capture_output=True)


def key_values(arguments):
    """SwiftTerm's parseKeyValues: split on ';', each on its first '='."""
    result = {}
    for part in arguments.split(";"):
        if "=" not in part:
            break
        key, value = part.split("=", 1)
        result[key] = value
    return result


def dimension_ok(value):
    """SwiftTerm's parseDimension: what it accepts rather than falling back to auto."""
    if value == "auto":
        return True
    if value.endswith("%"):
        return value[:-1].isdigit() and 0 < int(value[:-1]) <= 100
    if value.endswith("px"):
        return value[:-2].isdigit() and 0 < int(value[:-2]) < 4 * 1024
    return value.isdigit() and 0 < int(value) < 200


SEQUENCE = re.compile(rb"\x1b\]1337;File=([^:\x07]*):([A-Za-z0-9+/=]*)\x07\n")


def sequences(output):
    """Every inline image in `output`, and whether anything else was printed."""
    found = []
    position = 0
    for match in SEQUENCE.finditer(output):
        if match.start() != position:
            return found, False
        arguments = key_values(match.group(1).decode())
        found.append((arguments, base64.b64decode(match.group(2))))
        position = match.end()
    return found, position == len(output)


with tempfile.TemporaryDirectory() as folder:
    image = png(8, 6)
    path = os.path.join(folder, "photo.png")
    with open(path, "wb") as handle:
        handle.write(image)

    # One image, the defaults.
    result = run([path])
    found, clean = sequences(result.stdout)
    check(result.returncode == 0 and result.stderr == b"", "a PNG is shown without complaint")
    check(clean and len(found) == 1, "one image is one sequence and nothing else")
    arguments, payload = found[0] if found else ({}, b"")
    check(payload == image, "the payload is the file, byte for byte")
    check(arguments.get("inline") == "1", "it is inline: SwiftTerm draws nothing else")
    check(arguments.get("size") == str(len(image)), "size is the file's size")
    check(base64.b64decode(arguments.get("name", "")) == b"photo.png", "name is the file's name, base64")
    check(arguments.get("width") == "auto" and arguments.get("height") == "auto", "the size defaults to auto")
    check(arguments.get("preserveAspectRatio") == "1", "the proportions are kept by default")

    # Sizes.
    found, clean = sequences(run(["-W", "40", "-H", "50%", path]).stdout)
    check(clean and found and found[0][0].get("width") == "40" and found[0][0].get("height") == "50%", "-W and -H are passed on")
    found, clean = sequences(run(["--width=300px", "--height=auto", path]).stdout)
    check(clean and found and found[0][0].get("width") == "300px", "--width=N is read")
    found, clean = sequences(run(["--stretch", path]).stdout)
    check(clean and found and found[0][0].get("preserveAspectRatio") == "0", "--stretch drops the proportions")
    for value in ["40", "50%", "300px", "auto", "100%", "199"]:
        found, _ = sequences(run(["-W", value, path]).stdout)
        check(found and dimension_ok(found[0][0].get("width", "")), "SwiftTerm accepts the width %r" % value)

    # Standard input and several files.
    found, clean = sequences(run([], stdin=image).stdout)
    check(clean and len(found) == 1 and found[0][1] == image, "an image on standard input is shown")
    check(found and base64.b64decode(found[0][0].get("name", "")) == b"stdin", "…named stdin")
    found, clean = sequences(run(["-"], stdin=image).stdout)
    check(clean and len(found) == 1, "- reads standard input")
    second = os.path.join(folder, "second one.png")
    with open(second, "wb") as handle:
        handle.write(png(2, 2))
    found, clean = sequences(run([path, second]).stdout)
    check(clean and len(found) == 2, "two files are two sequences")
    check(found and base64.b64decode(found[1][0]["name"]) == b"second one.png", "a name with a space survives")

    # A name that would confuse the argument list if it were not encoded.
    odd = os.path.join(folder, "a;b=c:d.png")
    with open(odd, "wb") as handle:
        handle.write(image)
    found, clean = sequences(run([odd]).stdout)
    check(clean and len(found) == 1 and base64.b64decode(found[0][0]["name"]) == b"a;b=c:d.png",
          "; = and : in a name do not break the sequence")

    # Refusals.
    for args, code, why in [
        ([os.path.join(folder, "missing.png")], 1, "a missing file"),
        (["-W", "bad", path], 1, "a bad width"),
        (["-H", "5%5", path], 1, "a malformed height"),
        (["-W", "-5", path], 1, "a negative width"),
        (["--bogus", path], 2, "an unknown option"),
        (["-W"], 2, "a width with no value"),
    ]:
        result = run(args)
        check(result.returncode == code and result.stdout == b"", "%s: exit %d, nothing printed" % (why, code))
    empty = os.path.join(folder, "empty.png")
    open(empty, "wb").close()
    result = run([empty])
    check(result.returncode == 1 and result.stdout == b"", "an empty file is refused")
    big = os.path.join(folder, "big.png")
    with open(big, "wb") as handle:
        handle.truncate(26 * 1024 * 1024)
    result = run([big])
    check(result.returncode == 1 and result.stdout == b"" and b"MB" in result.stderr, "a file over the limit is refused, saying so")
    result = run([folder])
    check(result.returncode == 1 and result.stdout == b"", "a folder is not an image")

    # Information.
    result = run(["--version"])
    check(result.returncode == 0 and re.fullmatch(rb"imgcat \d+\n", result.stdout) is not None, "--version prints the version")
    result = run(["-h"])
    check(result.returncode == 0 and b"usage:" in result.stderr, "-h prints how to use it")

print("%d/%d imgcat checks passed" % (checks - failures, checks))
sys.exit(0 if failures == 0 else 1)
