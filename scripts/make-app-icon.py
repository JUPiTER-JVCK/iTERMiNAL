#!/usr/bin/env python3
"""Draws the app icon, in a dark and a light version, and renders the PNGs.

    python3 scripts/make-app-icon.py

Writes, all from the one drawing below:

  Resources/AppIcon/AppIcon-dark.svg, AppIcon-light.svg   the sources
  Resources/Assets.xcassets/AppIcon.appiconset/            the bundle icon (dark)
  Resources/Assets.xcassets/DockIconLight.imageset/        the Dock's icon while the app is light

Rendering needs Node with `playwright` (Chromium); the SVGs themselves need
nothing. Pass --svg-only to write just those.

The icon is a keycap: a face standing on two darker steps, with the prompt
printed in its top-left corner the way a legend is on a real key. The
measurements below are the original drawing's, on its 1024pt canvas; the whole
thing is scaled into the 824pt-wide area Apple's icon grid leaves for the
shadow, so it sits at the same size as its neighbours in the Dock.
"""

import json
import math
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
GRID = 824  # the icon's width on the 1024 canvas, per Apple's icon grid
SRC = 900   # the original drawing's width, which these measurements are in
K = GRID / SRC
ORIGIN = 62  # where the original drawing started on its canvas
EDGE = (1024 - GRID) / 2  # where the scaled drawing starts

# Face, then the two steps beneath it, each lighter at the top.
PALETTES = {
    "dark": dict(top=("#505054", "#3f3f43"), step1=("#3a3a3e", "#303034"), step2=("#222225", "#141416"),
                 glyph="#ffffff", glyph_shadow=0.5, rim=0.20),
    "light": dict(top=("#ffffff", "#ececf0"), step1=("#d6d6dd", "#c6c6ce"), step2=("#b4b4bf", "#a2a2ae"),
                  glyph="#26262b", glyph_shadow=0.18, rim=0.95),
}


def squircle(x, y, w, h, n=5.0, steps=360):
    """A superellipse path: the smooth-cornered shape macOS icons use."""
    cx, cy, a, b = x + w / 2, y + h / 2, w / 2, h / 2
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        pts.append(f"{cx + a * math.copysign(abs(c) ** (2 / n), c):.1f},{cy + b * math.copysign(abs(s) ** (2 / n), s):.1f}")
    return "M" + " L".join(pts) + " Z"


def svg(mode):
    p = PALETTES[mode]
    # Three layers, same width, each a little taller than the one above, so the
    # lower two show as bands under the face.
    step2 = squircle(ORIGIN, ORIGIN, SRC, 900)
    step1 = squircle(ORIGIN, ORIGIN, SRC, 840)
    face = squircle(ORIGIN, ORIGIN, SRC, 780)
    # The legend: a chevron with flat-cut ends and a clipped apex, then the
    # cursor. Four units heavier than the original so it holds up when small.
    chevron = "M198,191 L378,263 L378,302 L198,378 L198,345 L318,283 L198,224 Z"
    cursor = '<rect x="391" y="395" width="173" height="21"/>'
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
<linearGradient id="step2" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{p['step2'][0]}"/><stop offset="1" stop-color="{p['step2'][1]}"/></linearGradient>
<linearGradient id="step1" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{p['step1'][0]}"/><stop offset="1" stop-color="{p['step1'][1]}"/></linearGradient>
<linearGradient id="face" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{p['top'][0]}"/><stop offset="1" stop-color="{p['top'][1]}"/></linearGradient>
<linearGradient id="rim" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity="{p['rim']}"/><stop offset=".3" stop-color="#fff" stop-opacity="0"/></linearGradient>
<filter id="drop" x="-10%" y="-10%" width="120%" height="130%"><feDropShadow dx="0" dy="16" stdDeviation="18" flood-color="#000" flood-opacity=".4"/></filter>
<filter id="lift" x="-5%" y="-5%" width="110%" height="120%"><feDropShadow dx="0" dy="9" stdDeviation="9" flood-color="#000" flood-opacity=".38"/></filter>
<filter id="legend" x="-20%" y="-20%" width="140%" height="160%"><feDropShadow dx="0" dy="4" stdDeviation="3" flood-color="#000" flood-opacity="{p['glyph_shadow']}"/></filter>
<clipPath id="body"><path d="{step2}"/></clipPath>
</defs>
<g transform="translate({EDGE} {EDGE}) scale({K}) translate(-{ORIGIN} -{ORIGIN})">
<path d="{step2}" fill="url(#step2)" filter="url(#drop)"/>
<g clip-path="url(#body)">
  <path d="{step1}" fill="url(#step1)" filter="url(#lift)"/>
  <path d="{face}" fill="url(#face)" filter="url(#lift)"/>
</g>
<path d="{face}" fill="none" stroke="url(#rim)" stroke-width="4"/>
<g filter="url(#legend)" fill="{p['glyph']}"><path d="{chevron}"/>{cursor}</g>
</g>
</svg>
'''


# Every size the asset catalog's Contents.json names.
SIZES = [16, 32, 64, 128, 256, 512, 1024]


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
    svg_only = "--svg-only" in sys.argv
    sources = ROOT / "Resources" / "AppIcon"
    sources.mkdir(parents=True, exist_ok=True)
    paths = {}
    for mode in PALETTES:
        paths[mode] = sources / f"AppIcon-{mode}.svg"
        paths[mode].write_text(svg(mode))
    if svg_only:
        return

    catalog = ROOT / "Resources" / "Assets.xcassets"
    appicon = catalog / "AppIcon.appiconset"
    jobs = [
        (str(paths["dark"]), [(str(appicon / f"icon_{s}.png"), s) for s in SIZES]),
    ]
    # While the app is light the Dock shows this one (see DockIcon.swift); when
    # it is dark the Dock shows the bundle icon above. 512pt at 1x and 2x.
    name = "DockIconLight"
    d = catalog / f"{name}.imageset"
    d.mkdir(exist_ok=True)
    (d / "Contents.json").write_text(json.dumps({
        "images": [
            {"filename": f"{name}_512.png", "idiom": "universal", "scale": "1x"},
            {"filename": f"{name}_1024.png", "idiom": "universal", "scale": "2x"},
        ],
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n")
    jobs.append((str(paths["light"]), [
        (str(d / f"{name}_512.png"), 512),
        (str(d / f"{name}_1024.png"), 1024),
    ]))
    render(jobs)


if __name__ == "__main__":
    main()
