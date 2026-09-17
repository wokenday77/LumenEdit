# -*- coding: utf-8 -*-
"""Side-by-side comparison of the reference frame and the prototype shot.

Both screens are normalised to the same height and share ONE percentage ruler,
so a difference in the dial's vertical position shows up as a visible offset
against the gridlines instead of having to be eyeballed across two images.

The measured reference dial and the prototype dial are both drawn as circles,
which makes "same size? same height?" answerable at a glance.

Usage:
  python tools/compare_dial.py          ->  shots/compare-dial.png
"""
import os
from PIL import Image, ImageDraw, ImageFont

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REF = os.path.join(BASE, "reference", "video-frames-2026-09-16", "frames", "f012_t012.06s.jpg")
MINE = os.path.join(BASE, "shots", "02-dial.png")
OUT = os.path.join(BASE, "shots", "compare-dial.png")

PAD = 9                 # .phone carries 9px padding around the screen
PANEL_H = 900           # both screens are normalised to this height
KEEP_FROM = 0.40        # only the lower part is interesting
GAP, LABEL_W = 16, 58

# Reference dial, measured off f012 (settled state: identical within 1-2px across
# frames f008-f016). Two independent reads agree -- the hub glyph + the disc edge
# scanned along the centre row/column, and a least-squares fit that was then drawn
# back over the frame and visually confirmed to sit on the rim.
REF_CX, REF_CY, REF_R = 128.0, 1066.6, 220.0
# Prototype dial, mirrors --fd-center-x / --fd-center-y / --fd-size in
# prototype/index.html (i.e. it is pinned to the bottom "对焦" button's centre).
MY_CX, MY_CY, MY_R = 83.1, 662.0, 123.0

def load_ref():
    im = Image.open(REF).convert("RGB")
    return im, "REFERENCE  f012 (video frame)"

def load_mine():
    im = Image.open(MINE).convert("RGB")
    w, h = im.size
    return im.crop((PAD, PAD, w - PAD, h - PAD)), "PROTOTYPE  shots/02-dial.png"

ref, ref_cap = load_ref()
mine, mine_cap = load_mine()

def prep(im):
    """scale to PANEL_H, then keep the lower (1-KEEP_FROM) part.
    Returns (image, sx, sy) where sx/sy map screen px -> panel px."""
    w, h = im.size
    s = PANEL_H / h
    im = im.resize((max(1, round(w * s)), PANEL_H), Image.LANCZOS)
    top = round(PANEL_H * KEEP_FROM)
    return im.crop((0, top, im.width, PANEL_H)), w, h

ref_p, ref_w, ref_h = prep(ref)
mine_p, my_w, my_h = prep(mine)

W = LABEL_W + ref_p.width + GAP + mine_p.width
H = ref_p.height + 52
canvas = Image.new("RGB", (W, H), (18, 20, 24))
d = ImageDraw.Draw(canvas)

try:
    f = ImageFont.truetype("C:/Windows/Fonts/arial.ttf", 14)
    fb = ImageFont.truetype("C:/Windows/Fonts/arial.ttf", 16)
except Exception:
    f = fb = ImageFont.load_default()

x_ref, x_mine, y0 = LABEL_W, LABEL_W + ref_p.width + GAP, 50
canvas.paste(ref_p, (x_ref, y0))
canvas.paste(mine_p, (x_mine, y0))
d.text((x_ref, 8), ref_cap, fill=(255, 210, 120), font=fb)
d.text((x_mine, 8), mine_cap, fill=(120, 210, 255), font=fb)

# ---- circle overlay, screen px -> panel px ----
def draw_circle(im_wh, panel_w, panel_h, ox, cx, cy, r, colour, tag):
    s = panel_w / im_wh[0]
    px = ox + cx * s
    py = y0 + cy * (panel_h / im_wh[1] * (1 / (1 - KEEP_FROM))) - 0  # placeholder
    # vertical: panel shows the lower (1-KEEP_FROM) of a PANEL_H-tall screen
    py = y0 + (cy / im_wh[1] * PANEL_H) - PANEL_H * KEEP_FROM
    pr = r * s
    d.ellipse([px - pr, py - pr, px + pr, py + pr], outline=colour, width=2)
    d.line([(px - 10, py), (px + 10, py)], fill=colour, width=2)
    d.line([(px, py - 10), (px, py + 10)], fill=colour, width=2)
    d.text((px + pr + 6, py - 20), tag, fill=colour, font=f)

draw_circle((ref_w, ref_h), ref_p.width, ref_p.height, x_ref,
            REF_CX, REF_CY, REF_R, (255, 80, 80),
            "ref D=%.0f%%W" % (2 * REF_R / ref_w * 100))
draw_circle((my_w, my_h), mine_p.width, mine_p.height, x_mine,
            MY_CX, MY_CY, MY_R, (80, 200, 255),
            "mine D=%.0f%%W" % (2 * MY_R / my_w * 100))

# ---- shared percentage ruler ----
for pct in range(40, 101, 2):
    y = y0 + pct / 100 * PANEL_H - PANEL_H * KEEP_FROM
    if y < y0 or y > H:
        continue
    hot = pct in (63, 77, 83, 101)
    d.line([(LABEL_W - 6, y), (W, y)],
           fill=(255, 90, 90) if hot else ((215, 218, 224) if pct % 10 == 0 else (92, 97, 104)),
           width=2 if hot else 1)
    if pct % 10 == 0 or hot:
        d.text((4, y - 7), "%d%%" % pct,
               fill=(255, 90, 90) if hot else (200, 205, 212), font=f)

d.line([(x_mine - GAP // 2, y0), (x_mine - GAP // 2, H)], fill=(70, 74, 80), width=1)
d.text((x_ref, H - 20),
       "ref: centre %.1f%%H  D=%.0f%%W  left cut %.0f%%W   |   "
       "mine: centre %.1f%%H  D=%.0f%%W  left cut %.0f%%W"
       % (REF_CY / ref_h * 100, 2 * REF_R / ref_w * 100, (REF_R - REF_CX) / ref_w * 100,
          MY_CY / my_h * 100, 2 * MY_R / my_w * 100, (MY_R - MY_CX) / my_w * 100),
       fill=(220, 224, 230), font=f)

canvas.save(OUT)
print("saved:", OUT, canvas.size)
print("  ref  centre %.1f%%H  D=%.0f%%W  left cut %.0f%%W" %
      (REF_CY / ref_h * 100, 2 * REF_R / ref_w * 100, (REF_R - REF_CX) / ref_w * 100))
print("  mine centre %.1f%%H  D=%.0f%%W  left cut %.0f%%W" %
      (MY_CY / my_h * 100, 2 * MY_R / my_w * 100, (MY_R - MY_CX) / my_w * 100))
