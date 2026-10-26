#!/usr/bin/env python3
"""Render the Haven app icon once per palette in docs/PALETTES.md ->
packaging/palette-icons/<id>.png (1024 px, opaque). Every platform derives its own
sizes/formats from these, so the icon always matches the in-app palette exactly."""
import os, re
from make_icon import render

HERE = os.path.dirname(__file__)
ROOT = os.path.normpath(os.path.join(HERE, ".."))
SPEC = os.path.join(ROOT, "..", "docs", "PALETTES.md")
OUT = os.path.normpath(os.path.join(ROOT, "..", "packaging", "palette-icons"))

def palettes():
    rows = re.findall(r"^\| `(\w+)` \|[^|]*\| #([0-9A-Fa-f]{6}) \| #([0-9A-Fa-f]{6}) \| #([0-9A-Fa-f]{6}) \|",
                      open(SPEC).read(), re.M)
    return [(i, [tuple(int(h[k:k + 2], 16) for k in (0, 2, 4)) for h in hs]) for i, *hs in rows]

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for pid, stops in palettes():
        render(stops).save(os.path.join(OUT, f"{pid}.png"), "PNG")
        print("wrote", pid)
