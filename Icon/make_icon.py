#!/usr/bin/env python3
"""Draws the Plotter app icon and writes Resources/AppIcon.icns.

The artwork follows Apple's macOS icon grid: a 1024 x 1024 canvas with an
824 x 824 rounded-square ("squircle") body and a soft drop shadow. It shows a
graph-paper grid, axes and two curves on a deep blue glass tile.

Requirements: Python 3, Pillow, NumPy.  Usage: python3 Icon/make_icon.py
"""

import io
import math
import struct
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
PNG_OUT = ROOT / "Icon" / "AppIcon.png"
ICNS_OUT = ROOT / "Resources" / "AppIcon.icns"

SIZE = 1024
SS = 2
BODY = 824
MARGIN = (SIZE - BODY) // 2


def rgb(hex_color):
    hex_color = hex_color.lstrip("#")
    return np.array([int(hex_color[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.float64)


def squircle_mask(n, size):
    c = (np.arange(n) + 0.5) / n * 2 - 1
    x, y = np.meshgrid(c, c)
    inside = (np.abs(x) ** 5 + np.abs(y) ** 5) <= 1
    return Image.fromarray((inside * 255).astype(np.uint8)).resize((size, size), Image.LANCZOS)


def draw_body():
    n = BODY * SS
    v, u = np.mgrid[0:n, 0:n] / n

    # Diagonal gradient: deep navy at the bottom left to indigo at the top right,
    # plus a soft light bloom in the upper left (the "glass" highlight).
    t = np.clip(0.55 * u + 0.45 * (1 - v), 0, 1)[..., None]
    img = rgb("#0A1633") * (1 - t) + rgb("#2B2F8F") * t
    bloom = np.clip(1 - np.hypot(u - 0.25, v - 0.18) / 0.75, 0, 1) ** 2 * 0.35
    img = img * (1 - bloom[..., None]) + rgb("#7FB2FF") * bloom[..., None]
    body = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).convert("RGBA")

    overlay = Image.new("RGBA", body.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)

    # Grid.
    step = n / 8
    for k in range(1, 8):
        p = k * step
        alpha = 70 if k == 4 else 28
        width = int(0.006 * n) if k == 4 else int(0.003 * n)
        draw.line([(p, 0), (p, n)], fill=(255, 255, 255, alpha), width=width)
        draw.line([(0, p), (n, p)], fill=(255, 255, 255, alpha), width=width)

    def curve(fn, colour, width):
        pts = []
        for i in range(0, 801):
            x = -1 + 2 * i / 800
            y = fn(x)
            pts.append(((x + 1) / 2 * n, (1 - (y + 1) / 2) * n))
        draw.line(pts, fill=colour, width=width, joint="curve")

    # A Gaussian bell (warm) and a sine wave (cool), as in the sample document.
    curve(lambda x: 1.25 * math.exp(-(2.2 * x) ** 2) - 0.45, (255, 159, 67, 255), int(0.034 * n))
    curve(lambda x: 0.42 * math.sin(math.pi * 2.0 * x), (94, 234, 255, 255), int(0.034 * n))

    glow = overlay.filter(ImageFilter.GaussianBlur(0.02 * n))
    body = Image.alpha_composite(body, glow)
    body = Image.alpha_composite(body, overlay)

    # Glass rim: a thin bright edge along the top.
    rim = Image.new("RGBA", body.size, (0, 0, 0, 0))
    ImageDraw.Draw(rim).rectangle([0, 0, n, int(0.012 * n)], fill=(255, 255, 255, 60))
    body = Image.alpha_composite(body, rim.filter(ImageFilter.GaussianBlur(0.006 * n)))

    body.putalpha(squircle_mask(n, n))
    return body.resize((BODY, BODY), Image.LANCZOS)


def draw_icon():
    body = draw_body()
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    shadow_alpha = Image.new("L", (SIZE, SIZE), 0)
    shadow_alpha.paste(body.getchannel("A").point(lambda a: a * 0.3), (MARGIN, MARGIN + 10))
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    shadow.putalpha(shadow_alpha.filter(ImageFilter.GaussianBlur(14)))
    canvas = Image.alpha_composite(canvas, shadow)
    canvas.alpha_composite(body, (MARGIN, MARGIN))
    return canvas


ICNS_TYPES = [
    (b"icp4", 16), (b"icp5", 32), (b"ic11", 32), (b"ic12", 64), (b"ic07", 128),
    (b"ic13", 256), (b"ic08", 256), (b"ic14", 512), (b"ic09", 512), (b"ic10", 1024),
]


def write_icns(master, path):
    elements = b""
    for ostype, px in ICNS_TYPES:
        buf = io.BytesIO()
        master.resize((px, px), Image.LANCZOS).save(buf, format="PNG", optimize=True)
        data = buf.getvalue()
        elements += ostype + struct.pack(">I", 8 + len(data)) + data
    path.write_bytes(b"icns" + struct.pack(">I", 8 + len(elements)) + elements)


if __name__ == "__main__":
    icon = draw_icon()
    icon.save(PNG_OUT, optimize=True)
    write_icns(icon, ICNS_OUT)
    print(f"wrote {PNG_OUT.relative_to(ROOT)} and {ICNS_OUT.relative_to(ROOT)}")
