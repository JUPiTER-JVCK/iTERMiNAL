#!/usr/bin/env python3
"""Assert the invariants of a built iTERMiNAL.app, from Linux.

The macOS tools this would normally use (lipo, plutil) do not exist here, so
the arch slices are read straight out of the Mach-O fat header and Info.plist
is parsed with plistlib, which handles the binary format CI produces.

Usage: verify_bundle.py <path to iTERMiNAL.app> [expected-version]
Exits non-zero and prints one ::error:: line per failed invariant.
"""
# Annotations like `int | None` are only valid at definition time from Python
# 3.10, and the Python that ships with Apple's command line tools is 3.9.
from __future__ import annotations

import os
import plistlib
import struct
import sys
from pathlib import Path

# cpu_type values from <mach/machine.h>; the 0x0100_0000 bit means 64-bit.
CPU_TYPES = {7: "x86_64", 12: "arm64"}
FAT_MAGICS = {0xCAFEBABE, 0xCAFEBABF}  # 32- and 64-bit fat headers, big-endian


def arch_slices(binary: Path) -> set[str]:
    """The architectures present in a Mach-O binary, fat or thin."""
    data = binary.read_bytes()
    magic = struct.unpack(">I", data[:4])[0]
    if magic not in FAT_MAGICS:
        return set()  # thin binary: no fat header to walk
    count = struct.unpack(">I", data[4:8])[0]
    width = 32 if magic == 0xCAFEBABF else 20  # fat_arch_64 vs fat_arch
    found = set()
    for i in range(count):
        off = 8 + i * width
        cpu_type = struct.unpack(">i", data[off:off + 4])[0]
        found.add(CPU_TYPES.get(cpu_type & ~0x01000000, f"cpu:{cpu_type}"))
    return found


MACHO_64 = 0xFEEDFACF  # little-endian on disk, as every Mac slice is
LC_CODE_SIGNATURE = 0x1D
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0  # signature SuperBlob, big-endian
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
CSSLOT_CODEDIRECTORY = 0
CS_ADHOC = 0x2
CS_RUNTIME = 0x10000  # Hardened Runtime


def macho_slices(data: bytes) -> dict[str, bytes]:
    """Each architecture's own bytes from a Mach-O file, fat or thin."""
    magic = struct.unpack(">I", data[:4])[0]
    if magic in FAT_MAGICS:
        wide = magic == 0xCAFEBABF
        count = struct.unpack(">I", data[4:8])[0]
        width = 32 if wide else 20
        found = {}
        for i in range(count):
            off = 8 + i * width
            cpu_type = struct.unpack(">i", data[off:off + 4])[0]
            if wide:
                start, size = struct.unpack(">QQ", data[off + 8:off + 24])
            else:
                start, size = struct.unpack(">II", data[off + 8:off + 16])
            name = CPU_TYPES.get(cpu_type & ~0x01000000, f"cpu:{cpu_type}")
            found[name] = data[start:start + size]
        return found
    if struct.unpack("<I", data[:4])[0] == MACHO_64:
        cpu_type = struct.unpack("<i", data[4:8])[0]
        return {CPU_TYPES.get(cpu_type & ~0x01000000, f"cpu:{cpu_type}"): data}
    return {}


def signature_flags(thin: bytes) -> int | None:
    """The CodeDirectory flags in one slice's embedded signature.

    None when the slice has no signature, or one that cannot be read — either
    way it is not a signature this check can vouch for. Offsets in a slice's
    load commands are relative to the start of that slice.
    """
    if len(thin) < 32 or struct.unpack("<I", thin[:4])[0] != MACHO_64:
        return None
    ncmds = struct.unpack("<I", thin[16:20])[0]
    off = 32
    for _ in range(ncmds):
        if off + 16 > len(thin):
            return None
        cmd, size = struct.unpack("<II", thin[off:off + 8])
        if cmd == LC_CODE_SIGNATURE:
            data_off, data_size = struct.unpack("<II", thin[off + 8:off + 16])
            blob = thin[data_off:data_off + data_size]
            if len(blob) < 12 or struct.unpack(">I", blob[:4])[0] != CSMAGIC_EMBEDDED_SIGNATURE:
                return None
            count = struct.unpack(">I", blob[8:12])[0]
            for i in range(count):
                entry = 12 + i * 8
                if entry + 8 > len(blob):
                    return None
                slot, offset = struct.unpack(">II", blob[entry:entry + 8])
                directory = blob[offset:offset + 16]
                if (slot == CSSLOT_CODEDIRECTORY and len(directory) == 16
                        and struct.unpack(">I", directory[:4])[0] == CSMAGIC_CODEDIRECTORY):
                    return struct.unpack(">I", directory[12:16])[0]
            return None
        if size < 8:
            return None
        off += size
    return None


def main() -> int:
    app = Path(sys.argv[1])
    expected_version = sys.argv[2] if len(sys.argv) > 2 else None
    failures = []

    # The three files the app promises. iterminalctl went missing for weeks
    # once because nothing checked for it.
    required = [
        app / "Contents/MacOS/iTERMiNAL",
        app / "Contents/Resources/iterminalctl",
        app / "Contents/Resources/AppIcon.icns",
        app / "Contents/Info.plist",
    ]
    for path in required:
        if not path.exists():
            failures.append(f"missing from the bundle: {path.relative_to(app)}")

    binary = app / "Contents/MacOS/iTERMiNAL"
    if binary.exists():
        slices = arch_slices(binary)
        for arch in ("x86_64", "arm64"):
            if arch not in slices:
                failures.append(
                    f"main binary has no {arch} slice (found: "
                    f"{', '.join(sorted(slices)) or 'thin binary'})"
                )

    # Signed, not merely present. An unsigned bundle has no seal, and macOS
    # ties per-app permissions (Local Network among them) to a signature. This
    # reads the signature out of the files rather than asking codesign, which
    # does not exist here: it can say a signature is there and what it was made
    # with, but not that it verifies — CI runs `codesign --verify` for that.
    seal = app / "Contents/_CodeSignature/CodeResources"
    if not seal.exists():
        failures.append(
            "the bundle is not sealed: Contents/_CodeSignature/CodeResources "
            "is missing, so it was shipped unsigned"
        )
    if binary.exists():
        for arch, thin in sorted(macho_slices(binary.read_bytes()).items()):
            flags = signature_flags(thin)
            if flags is None:
                failures.append(f"main binary's {arch} slice carries no readable code signature")
                continue
            kinds = ["ad-hoc" if flags & CS_ADHOC else "identity-signed"]
            if flags & CS_RUNTIME:
                kinds.append("hardened runtime")
            else:
                failures.append(
                    f"main binary's {arch} signature lacks Hardened Runtime "
                    f"(flags 0x{flags:x}); project.yml declares it on"
                )
            print(f"signature ({arch:<6})       = {', '.join(kinds)}")

    # The bundled tools: each present and universal, and imgcat — a script,
    # not a binary — present and executable. superfile and btop open as panels;
    # ripgrep, bat and imgcat are on every tab's PATH.
    tools = app / "Contents/Resources/Tools"
    for relative in ("spf", "btop", "bin/rg", "bin/bat"):
        tool = tools / relative
        if not tool.exists():
            failures.append(f"missing from the bundled tools: {relative}")
            continue
        found = arch_slices(tool)
        for arch in ("x86_64", "arm64"):
            if arch not in found:
                failures.append(f"bundled {relative} has no {arch} slice")
    imgcat = tools / "bin/imgcat"
    if not imgcat.exists():
        failures.append("missing from the bundled tools: bin/imgcat")
    elif not os.access(imgcat, os.X_OK):
        failures.append("bundled bin/imgcat is not executable")

    plist_path = app / "Contents/Info.plist"
    if plist_path.exists():
        plist = plistlib.loads(plist_path.read_bytes())
        version = plist.get("CFBundleShortVersionString")
        print(f"CFBundleShortVersionString = {version}")
        print(f"CFBundleVersion            = {plist.get('CFBundleVersion')}")
        print(f"CFBundleIconName           = {plist.get('CFBundleIconName')}")
        print(f"LSMinimumSystemVersion     = {plist.get('LSMinimumSystemVersion')}")
        if plist.get("CFBundleIconName") != "AppIcon":
            failures.append("CFBundleIconName is not AppIcon; the icon will not load")
        # The whole point of the tag build: the tag must reach the About box.
        if expected_version and version != expected_version:
            failures.append(
                f"CFBundleShortVersionString is {version!r}, expected "
                f"{expected_version!r} — the tag did not reach MARKETING_VERSION"
            )

    if binary.exists():
        print(f"arch slices                = {', '.join(sorted(arch_slices(binary)))}")

    for message in failures:
        print(f"::error::{message}")
    print("FAIL" if failures else "OK: every bundle invariant holds")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
