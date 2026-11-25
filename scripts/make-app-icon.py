#!/usr/bin/env python3
"""Draws the app icon, in a dark and a light version, and renders the PNGs.

    python3 scripts/make-app-icon.py

Writes, all from the one drawing below:

  Resources/AppIcon/AppIcon-dark.svg, AppIcon-light.svg   the sources
  Resources/Assets.xcassets/AppIcon.appiconset/            the bundle icon (dark)
  Resources/Assets.xcassets/DockIconLight.imageset/        the Dock's icon while the app is light

Rendering needs Node with `playwright` (Chromium); the SVGs themselves need
nothing. Pass --svg-only to write just those.

The shape is a keycap: a face standing on a darker base, so the bottom edge
shows a step, the way a key does. Both layers are the same macOS-style
squircle, 824pt wide on the 1024pt canvas — the margin Apple's icon grid
leaves for the shadow.
"""

import json
import math
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
CANVAS = 1024
BODY = 824  # the icon's width on the 1024 canvas
LEFT = (CANVAS - BODY) / 2
STEP = 46  # how much of the base shows beneath the face

# The cursor keeps the accent the previous icon used, so the app's icon and
# its default accent stay one colour.
PALETTES = {
    "dark": {
        "base": ("#17181c", "#0d0e10"),
        "face": ("#303139", "#1d1e24"),
        "rim": "#ffffff",
        "rim_opacity": 0.22,
        "chevron": "#f2f2f4",
        "cursor": ("#6f9cf5", "#4a7fe6"),
        "glyph_shadow": 0.45,
        "drop_shadow": 0.38,
    },
    "light": {
        "base": ("#c4c6d0", "#aeb0bc"),
        "face": ("#ffffff", "#eceef3"),
        "rim": "#ffffff",
        "rim_opacity": 0.95,
        "chevron": "#202127",
        "cursor": ("#4f8df7", "#2f6ee8"),
        "glyph_shadow": 0.18,
        "drop_shadow": 0.30,
    },
}


def squircle(x, y, w, h, n=5.0, steps=720):
    """A superellipse path: the smooth-cornered shape macOS icons use."""
    cx, cy, a, b = x + w / 2, y + h / 2, w / 2, h / 2
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        px = cx + a * math.copysign(abs(c) ** (2 / n), c)
        py = cy + b * math.copysign(abs(s) ** (2 / n), s)
        pts.append(f"{px:.2f},{py:.2f}")
    return "M" + " L".join(pts) + " Z"


def svg(mode):
    p = PALETTES[mode]
    top = 100
    base_path = squircle(LEFT, top, BODY, BODY)
    face_h = BODY - STEP
    face_path = squircle(LEFT, top, BODY, face_h)
    cx = CANVAS / 2
    cy = top + face_h / 2  # centre of the face: the glyphs sit here

    # Prompt glyph: a chevron and a cursor bar, both with round ends.
    chevron = f"M{cx - 150:.1f},{cy - 142:.1f} L{cx + 10:.1f},{cy - 2:.1f} L{cx - 150:.1f},{cy + 138:.1f}"
    bar_x, bar_w, bar_h = cx + 22, 196, 62
    bar_y = cy + 80

    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" viewBox="0 0 {CANVAS} {CANVAS}">
  <defs>
    <linearGradient id="base" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{p['base'][0]}"/><stop offset="1" stop-color="{p['base'][1]}"/>
    </linearGradient>
    <linearGradient id="face" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{p['face'][0]}"/><stop offset="1" stop-color="{p['face'][1]}"/>
    </linearGradient>
    <linearGradient id="cursor" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{p['cursor'][0]}"/><stop offset="1" stop-color="{p['cursor'][1]}"/>
    </linearGradient>
    <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{p['rim']}" stop-opacity="{p['rim_opacity']}"/>
      <stop offset="0.35" stop-color="{p['rim']}" stop-opacity="0"/>
    </linearGradient>
    <filter id="drop" x="-10%" y="-10%" width="120%" height="125%">
      <feDropShadow dx="0" dy="14" stdDeviation="16" flood-color="#000" flood-opacity="{p['drop_shadow']}"/>
    </filter>
    <filter id="glyph" x="-20%" y="-20%" width="140%" height="150%">
      <feDropShadow dx="0" dy="6" stdDeviation="7" flood-color="#000" flood-opacity="{p['glyph_shadow']}"/>
    </filter>
    <filter id="faceShadow" x="-5%" y="-5%" width="110%" height="115%">
      <feDropShadow dx="0" dy="8" stdDeviation="9" flood-color="#000" flood-opacity="0.35"/>
    </filter>
    <clipPath id="body"><path d="{base_path}"/></clipPath>
  </defs>
  <path d="{base_path}" fill="url(#base)" filter="url(#drop)"/>
  <g clip-path="url(#body)">
    <path d="{face_path}" fill="url(#face)" filter="url(#faceShadow)"/>
  </g>
  <path d="{face_path}" fill="none" stroke="url(#rim)" stroke-width="3"/>
  <g filter="url(#glyph)">
    <path d="{chevron}" fill="none" stroke="{p['chevron']}" stroke-width="62" stroke-linecap="round" stroke-linejoin="round"/>
    <rect x="{bar_x:.1f}" y="{bar_y:.1f}" width="{bar_w}" height="{bar_h}" rx="{bar_h / 2}" fill="url(#cursor)"/>
  </g>
</svg>
"""


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
    for mode, name in (("light", "DockIconLight"),):
        d = catalog / f"{name}.imageset"
        d.mkdir(exist_ok=True)
        (d / "Contents.json").write_text(json.dumps({
            "images": [
                {"filename": f"{name}_512.png", "idiom": "universal", "scale": "1x"},
                {"filename": f"{name}_1024.png", "idiom": "universal", "scale": "2x"},
            ],
            "info": {"author": "xcode", "version": 1},
        }, indent=2) + "\n")
        jobs.append((str(paths[mode]), [
            (str(d / f"{name}_512.png"), 512),
            (str(d / f"{name}_1024.png"), 1024),
        ]))
    render(jobs)


if __name__ == "__main__":
    main()
