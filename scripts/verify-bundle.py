#!/usr/bin/env python3
"""Assert the invariants of a built iTERMiNAL.app, from Linux.

The macOS tools this would normally use (lipo, plutil) do not exist here, so
the arch slices are read straight out of the Mach-O fat header and Info.plist
is parsed with plistlib, which handles the binary format CI produces.

Usage: verify_bundle.py <path to iTERMiNAL.app> [expected-version]
Exits non-zero and prints one ::error:: line per failed invariant.
"""
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
