#!/usr/bin/env python3
# Noise comparison figure: 30 ms of PSG white noise (rate /512) from several
# recordings, each with the shift-register recurrence its decoded bits fit.
#   noise_panel.py OUT.png "LABEL=FILE.wav@START" ...
import sys, wave, numpy as np
from PIL import Image, ImageDraw, ImageFont
import os
def font(size, bold=False):
    for f in (["/System/Library/Fonts/Supplemental/Arial Bold.ttf"] if bold else []) + ["/System/Library/Fonts/Supplemental/Arial.ttf"]:
        if os.path.exists(f): return ImageFont.truetype(f, size)
    return ImageFont.load_default()

def load(f, t0, dur):
    w = wave.open(f); r = w.getframerate(); ch = w.getnchannels()
    a = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(float)[::ch]
    x = a[int(t0 * r):int((t0 + dur) * r)]
    return x - x.mean(), r

def fit(x, r, div=512):
    s = x > 0; e = np.flatnonzero(s[1:] != s[:-1]); runs = np.diff(e)
    u = r / (3579545 / div); bits = []; lvl = int(s[e[0] + 1])
    for n in runs:
        bits += [lvl] * max(1, int(round(n / u))); lvl ^= 1
    b = np.array(bits)
    best = max((max(m, 1 - m), p, q) for p in range(1, 18) for q in range(p + 1, 19)
               for m in [np.mean(b[q:] == (b[q - p:len(b) - p] ^ b[:len(b) - q]))])
    return best, len(b)

out = sys.argv[1]
rows = [a.split("=", 1) for a in sys.argv[2:]]
W, RH, L = 1400, 170, 20
img = Image.new("RGB", (W, 70 + RH * len(rows) + 30), (245, 245, 245))
d = ImageDraw.Draw(img)
d.text((L, 16), "PSG white noise, OUT 127,228 (shift rate /512): 30 ms of each recording", fill=(0, 0, 0), font=font(28, True))
for k, (label, spec) in enumerate(rows):
    f, t0 = spec.rsplit("@", 1)
    x, r = load(f, float(t0), 3.0)
    (m, p, q), n = fit(x, r)
    good = m > 0.99 and (p, q) == (14, 15)
    y0 = 70 + k * RH
    col = (40, 140, 60) if good else (190, 40, 40)
    d.text((L, y0), label, fill=col, font=font(22, True))
    d.text((L, y0 + 28), f"{n} bits decoded: each bit = bit n-{p} XOR bit n-{q} on {m*100:.1f}% of bits"
           + ("  -> SN76489AN noise register, as MAME" if good else "  -> a different sequence"), fill=(40, 40, 40), font=font(18))
    seg = x[:int(0.03 * r)]; seg = seg / (np.abs(seg).max() or 1)
    top, h = y0 + 58, RH - 70
    pts = [(L + i * (W - 2 * L) / len(seg), top + h / 2 - v * h / 2 * 0.9) for i, v in enumerate(seg)]
    d.rectangle([L, top, W - L, top + h], fill=(255, 255, 255), outline=(200, 200, 200))
    d.line(pts, fill=(31, 95, 168), width=2)
d.text((L, img.height - 28), "0 ms" + " " * 8, fill=(80, 80, 80), font=font(16))
d.text((W - L - 60, img.height - 28), "30 ms", fill=(80, 80, 80), font=font(16))
img.save(out)
print(out)
