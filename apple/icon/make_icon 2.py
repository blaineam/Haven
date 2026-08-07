#!/usr/bin/env python3
"""Generate the Haven app icon: a warm sunset gradient with a glowing constellation
of connected 'kin' nodes. Renders at 4x and downsamples for crisp anti-aliasing."""
import os
from PIL import Image, ImageDraw, ImageFilter

OUT = os.path.join(os.path.dirname(__file__), "..", "HavenApp", "Assets.xcassets",
                   "AppIcon.appiconset", "icon_1024.png")
SIZE = 1024
SS = 4
S = SIZE * SS

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def gradient(size, stops):
    """True corner-to-corner diagonal multi-stop gradient (top-left → bottom-right),
    built small and scaled up so it's smooth and cheap."""
    n = 180
    small = Image.new("RGB", (n, n))
    px = small.load()
    seg = len(stops) - 1
    for y in range(n):
        for x in range(n):
            t = (x + y) / (2 * (n - 1))
            i = min(int(t * seg), seg - 1)
            lt = t * seg - i
            px[x, y] = lerp(stops[i], stops[i + 1], lt)
    return small.resize((size, size), Image.BILINEAR)

def main():
    # Warm sunset: violet -> pink -> amber.
    bg = gradient(S, [(124, 58, 237), (236, 72, 153), (245, 158, 11)])

    # Node layout (in 1024 space): a friendly cluster with a central "you" node.
    nodes = [
        (512, 516, 78),   # center (you)
        (512, 286, 50),   # top
        (286, 470, 54),   # left
        (738, 470, 54),   # right
        (372, 736, 48),   # bottom-left
        (652, 736, 48),   # bottom-right
    ]
    edges = [(0, 1), (0, 2), (0, 3), (0, 4), (0, 5),
             (1, 2), (1, 3), (2, 4), (3, 5)]

    def scale(p):
        return tuple(v * SS for v in p)

    # Lines layer (soft white links).
    lines = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ld = ImageDraw.Draw(lines)
    for a, b in edges:
        x1, y1, _ = nodes[a]
        x2, y2, _ = nodes[b]
        ld.line([scale((x1, y1)), scale((x2, y2))], fill=(255, 255, 255, 150),
                width=11 * SS)

    # Nodes layer (solid white discs).
    discs = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    dd = ImageDraw.Draw(discs)
    for x, y, r in nodes:
        cx, cy, rr = x * SS, y * SS, r * SS
        dd.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], fill=(255, 255, 255, 255))

    # Glow = heavily blurred copy of the discs+lines.
    glow_src = Image.alpha_composite(lines, discs)
    glow = glow_src.filter(ImageFilter.GaussianBlur(radius=26 * SS))

    canvas = bg.convert("RGBA")
    canvas = Image.alpha_composite(canvas, glow)
    canvas = Image.alpha_composite(canvas, lines)
    canvas = Image.alpha_composite(canvas, discs)

    out = canvas.convert("RGB").resize((SIZE, SIZE), Image.LANCZOS)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    out.save(OUT, "PNG")
    print("wrote", os.path.normpath(OUT))

if __name__ == "__main__":
    main()
