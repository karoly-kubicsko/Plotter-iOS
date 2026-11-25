#!/usr/bin/env python3
"""Draws the Plotter iOS app icon and writes Icon/AppIcon.png.

iOS icons are a full-bleed, opaque 1024 x 1024 square: the system applies the rounded
corners itself, and an icon with a transparent margin, a pre-drawn rounded shape or a drop
shadow shows up with black edges. The artwork is a graph-paper grid, axes and two curves on a
deep blue tile. The curves stay inside the area that the system's rounded mask leaves visible.

Requirements: Python 3, Pillow, NumPy.  Usage: python3 Icon/make_icon.py [--preview]
  --preview  also writes Icon/AppIcon-preview.png: the icon with the system's rounded
             mask applied, as the Home Screen shows it (not part of the app)
"""

import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
PNG_OUT = ROOT / "Icon" / "AppIcon.png"
PREVIEW_OUT = ROOT / "Icon" / "AppIcon-preview.png"

SIZE = 1024
SS = 2  # supersampling factor


def rgb(hex_color):
    hex_color = hex_color.lstrip("#")
    return np.array([int(hex_color[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.float64)


def draw_icon():
    n = SIZE * SS
    v, u = np.mgrid[0:n, 0:n] / n

    # Diagonal gradient: deep navy at the bottom left to indigo at the top right,
    # plus a soft light bloom in the upper left.
    t = np.clip(0.55 * u + 0.45 * (1 - v), 0, 1)[..., None]
    img = rgb("#0A1633") * (1 - t) + rgb("#2B2F8F") * t
    bloom = np.clip(1 - np.hypot(u - 0.25, v - 0.18) / 0.75, 0, 1) ** 2 * 0.35
    img = img * (1 - bloom[..., None]) + rgb("#7FB2FF") * bloom[..., None]
    base = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).convert("RGBA")

    overlay = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)

    # Grid: eight cells across, the middle lines (the axes) brighter.
    step = n / 8
    for k in range(1, 8):
        p = k * step
        alpha = 70 if k == 4 else 28
        width = int(0.006 * n) if k == 4 else int(0.003 * n)
        draw.line([(p, 0), (p, n)], fill=(255, 255, 255, alpha), width=width)
        draw.line([(0, p), (n, p)], fill=(255, 255, 255, alpha), width=width)

    def curve(fn, colour, width):
        # Round dots along the path: a smooth stroke without the ragged edges of a wide polyline.
        r = width / 2
        for i in range(0, 4401):
            x = -1.1 + 2.2 * i / 4400  # a little beyond the edges, so the strokes run off the icon
            y = fn(x)
            px, py = (x + 1) / 2 * n, (1 - (y + 1) / 2) * n
            draw.ellipse([px - r, py - r, px + r, py + r], fill=colour)

    # A Gaussian bell (warm) and a sine wave (cool), as in the sample document.
    curve(lambda x: 1.25 * math.exp(-(2.2 * x) ** 2) - 0.45, (255, 159, 67, 255), int(0.034 * n))
    curve(lambda x: 0.42 * math.sin(math.pi * 2.0 * x), (94, 234, 255, 255), int(0.034 * n))

    glow = overlay.filter(ImageFilter.GaussianBlur(0.02 * n))
    icon = Image.alpha_composite(base, glow)
    icon = Image.alpha_composite(icon, overlay)

    # Opaque RGB, no alpha channel (the App Store rejects icons with transparency).
    return icon.convert("RGB").resize((SIZE, SIZE), Image.LANCZOS)


def home_screen_preview(icon):
    """The icon as the Home Screen draws it: iOS's rounded mask (about 22.4 % corner radius)."""
    n = SIZE * 2
    mask = Image.new("L", (n, n), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, n - 1, n - 1], radius=int(0.2237 * n), fill=255)
    mask = mask.resize((SIZE, SIZE), Image.LANCZOS)
    canvas = Image.new("RGB", (SIZE + 200, SIZE + 200), (235, 235, 240))
    canvas.paste(icon, (100, 100), mask)
    return canvas


if __name__ == "__main__":
    icon = draw_icon()
    icon.save(PNG_OUT, optimize=True)
    print(f"wrote {PNG_OUT.relative_to(ROOT)} ({icon.mode}, {icon.size[0]}x{icon.size[1]})")
    if "--preview" in sys.argv[1:]:
        home_screen_preview(icon).save(PREVIEW_OUT)
        print(f"wrote {PREVIEW_OUT.relative_to(ROOT)}")
