#!/usr/bin/env python3
# Labelled side-by-side comparison panels: SC3000 core vs SMS core (vs MAME).
#   compare_panels.py SPEC.json OUTDIR
# SPEC: [{"name": "...", "title": "...", "note": "...",
#         "cells": [{"img": "path", "label": "...", "verdict": "ok|bad|info", "caption": "..."}]}]
import json, sys, os
from PIL import Image, ImageDraw, ImageFont

W, H = 640, 480                 # each screenshot is fitted into this box
PAD, HEAD, CAP = 16, 64, 74
COL = {"ok": (40, 150, 60), "bad": (190, 40, 40), "info": (90, 90, 90)}

def font(size, bold=False):
    for p in (["/System/Library/Fonts/Supplemental/Arial Bold.ttf"] if bold else []) + \
             ["/System/Library/Fonts/Supplemental/Arial.ttf", "/System/Library/Fonts/Helvetica.ttc",
              "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]:
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()

def fit(img):
    im = Image.open(img).convert("RGB")
    s = min(W / im.width, H / im.height)
    im = im.resize((max(1, int(im.width * s)), max(1, int(im.height * s))), Image.NEAREST)
    box = Image.new("RGB", (W, H), (24, 24, 24))
    box.paste(im, ((W - im.width) // 2, (H - im.height) // 2))
    return box

def wrap(d, text, f, width):
    lines, cur = [], ""
    for word in text.split():
        t = (cur + " " + word).strip()
        if d.textlength(t, font=f) > width and cur:
            lines.append(cur); cur = word
        else:
            cur = t
    if cur: lines.append(cur)
    return lines

def panel(p, outdir):
    n = len(p["cells"])
    note_lines = 2 if p.get("note") else 0
    tw = n * W + (n + 1) * PAD
    th = HEAD + H + CAP + PAD + note_lines * 22 + PAD
    out = Image.new("RGB", (tw, th), (245, 245, 245))
    d = ImageDraw.Draw(out)
    d.text((PAD, 14), p["title"], fill=(0, 0, 0), font=font(30, True))
    for i, c in enumerate(p["cells"]):
        x = PAD + i * (W + PAD); y = HEAD
        out.paste(fit(c["img"]), (x, y))
        col = COL.get(c.get("verdict", "info"))
        d.rectangle([x - 3, y - 3, x + W + 2, y + H + 2], outline=col, width=4)
        d.rectangle([x, y + H + 6, x + W, y + H + 36], fill=col)
        d.text((x + 10, y + H + 9), c["label"], fill=(255, 255, 255), font=font(20, True))
        for k, line in enumerate(wrap(d, c.get("caption", ""), font(17), W - 10)[:2]):
            d.text((x + 4, y + H + 40 + k * 20), line, fill=(30, 30, 30), font=font(17))
    if p.get("note"):
        for k, line in enumerate(wrap(d, p["note"], font(17), tw - 2 * PAD)[:2]):
            d.text((PAD, HEAD + H + CAP + PAD + k * 22), line, fill=(60, 60, 60), font=font(17))
    path = os.path.join(outdir, p["name"] + ".png")
    out.save(path)
    return path

if __name__ == "__main__":
    spec = json.load(open(sys.argv[1]))
    os.makedirs(sys.argv[2], exist_ok=True)
    for p in spec:
        print(panel(p, sys.argv[2]))
