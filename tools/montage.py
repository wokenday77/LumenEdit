# -*- coding: utf-8 -*-
"""Lay several prototype screenshots side by side into one review image.

All panels are normalised to the same height so the bottom floating stacks line
up across states -- that makes "does the layout stay consistent between states"
answerable at a glance, which is the whole point of a review sheet.

Usage:
  python tools/montage.py shots/out.png "caption 1=shots/a.png" "caption 2=shots/b.png" ...
"""
import os
import sys
from PIL import Image, ImageDraw, ImageFont

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    out = sys.argv[1]
    if not os.path.isabs(out):
        out = os.path.join(BASE, out)

    items = []
    for arg in sys.argv[2:]:
        cap, _, path = arg.partition('=')
        if not os.path.isabs(path):
            path = os.path.join(BASE, path)
        items.append((cap, path))

    PANEL_H = 820
    GAP, TOP, BOTTOM = 14, 40, 12
    panels = []
    for cap, path in items:
        im = Image.open(path).convert("RGB")
        w, h = im.size
        panels.append((cap, im.resize((max(1, round(w * PANEL_H / h)), PANEL_H), Image.LANCZOS)))

    W = GAP + sum(p.width + GAP for _, p in panels)
    H = TOP + PANEL_H + BOTTOM
    canvas = Image.new("RGB", (W, H), (18, 20, 24))
    d = ImageDraw.Draw(canvas)
    try:
        f = ImageFont.truetype("C:/Windows/Fonts/arial.ttf", 16)
    except Exception:
        f = ImageFont.load_default()

    x = GAP
    for cap, p in panels:
        canvas.paste(p, (x, TOP))
        d.text((x + 2, 12), cap, fill=(255, 210, 120), font=f)
        x += p.width + GAP

    canvas.save(out)
    print("saved:", out, canvas.size)
    return 0

if __name__ == "__main__":
    sys.exit(main())
