#!/usr/bin/env python3
"""Renders the app icon's PNGs from its two SVG sources.

    python3 scripts/make-app-icon.py

Reads, as the sources:

  Resources/AppIcon/AppIcon-dark.svg, AppIcon-light.svg
  Resources/AppIcon/AppIcon-dark-cursor-off.svg, AppIcon-light-cursor-off.svg
      the same two icons with the cursor hidden: the "off" frame of the Dock blink

and writes:

  Resources/Assets.xcassets/AppIcon.appiconset/            the bundle icon (dark)
  Resources/Assets.xcassets/DockIconLight.imageset/        the Dock's icon while the app is light
  Resources/Assets.xcassets/DockCursorOff.imageset/        the Dock's blink frame, dark
  Resources/Assets.xcassets/DockCursorOffLight.imageset/   the Dock's blink frame, light

The icon (M9, "Status Line") is one terminal window on a charcoal (dark) or
slate-grey (light) tile: phosphor-green output bars, a `$_` prompt, and a status
line with `~/` and the exit code. No layer is pure black, which clips on XDR
screens. The SVGs are 1024x1024 masters on Apple's macOS icon grid (824pt body,
100pt margin, shadow built in) with the text outlined, so rendering needs no
font.

Rendering needs Node with `playwright` (Chromium).
"""

import json
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Every file the AppIcon set's Contents.json names: (file name, pixels).
APPICON = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


def render(jobs):
    """jobs: [(svg_path, [(png_path, pixels), ...])]. One Chromium for all."""
    script = """
const { chromium } = require('playwright');
const fs = require('fs');
(async () => {
  const jobs = JSON.parse(process.argv[2]);
  const browser = await chromium.launch();
  for (const [svgPath, outs] of jobs) {
    const svg = fs.readFileSync(svgPath, 'utf8');
    for (const [png, px] of outs) {
      const page = await browser.newPage({ viewport: { width: px, height: px } });
      await page.setContent(
        '<style>html,body{margin:0;background:transparent}svg{display:block;width:' + px + 'px;height:' + px + 'px}</style>' + svg);
      await page.screenshot({ path: png, omitBackground: true });
      await page.close();
    }
  }
  await browser.close();
})();
"""
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as f:
        f.write(script)
    subprocess.run(["node", f.name, json.dumps(jobs)], check=True)


def main():
    sources = ROOT / "Resources" / "AppIcon"
    catalog = ROOT / "Resources" / "Assets.xcassets"
    appicon = catalog / "AppIcon.appiconset"

    jobs = [
        (str(sources / "AppIcon-dark.svg"), [(str(appicon / name), px) for name, px in APPICON]),
    ]
    # The Dock's own pictures (see DockIcon.swift): the light icon while the app
    # is light, and a cursor-less frame of each for the blink. 512pt at 1x and 2x.
    for name, svg in [
        ("DockIconLight", "AppIcon-light.svg"),
        ("DockCursorOff", "AppIcon-dark-cursor-off.svg"),
        ("DockCursorOffLight", "AppIcon-light-cursor-off.svg"),
    ]:
        d = catalog / f"{name}.imageset"
        d.mkdir(exist_ok=True)
        (d / "Contents.json").write_text(json.dumps({
            "images": [
                {"filename": f"{name}_512.png", "idiom": "universal", "scale": "1x"},
                {"filename": f"{name}_1024.png", "idiom": "universal", "scale": "2x"},
            ],
            "info": {"author": "xcode", "version": 1},
        }, indent=2) + "\n")
        jobs.append((str(sources / svg), [
            (str(d / f"{name}_512.png"), 512),
            (str(d / f"{name}_1024.png"), 1024),
        ]))
    render(jobs)


if __name__ == "__main__":
    main()
