#!/usr/bin/env python3
"""Builds Resources/AppIcon.icns from Resources/icon-source.png.

The source art is a white rounded card on a black background without alpha. The card is
cut out, re-masked with the macOS icon corner radius on the standard 1024 grid
(824 px body, 100 px margin) and given a soft drop shadow.
"""
import subprocess, shutil
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

root = Path(__file__).resolve().parent.parent
src = Image.open(root / "Resources/icon-source.png").convert("RGB")

# Locate the card: first/last bright pixels through the centre lines.
w, h = src.size
px = src.load()
bright = lambda p: sum(p) / 3 > 200
xs = [x for x in range(w) if bright(px[x, h // 2])]
ys = [y for y in range(h) if bright(px[w // 2, y])]
inset = 6  # trim the anti-aliased edge and baked-in shadow
card = src.crop((xs[0] + inset, ys[0] + inset, xs[-1] - inset + 1, ys[-1] - inset + 1))

S, BODY, M = 1024, 824, 100
SS = 4  # supersampling for a smooth mask edge
card = card.resize((BODY, BODY), Image.LANCZOS)
mask = Image.new("L", (BODY * SS, BODY * SS), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, BODY * SS - 1, BODY * SS - 1), radius=186 * SS, fill=255)
mask = mask.resize((BODY, BODY), Image.LANCZOS)

canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sm = Image.new("L", (S, S), 0)
sm.paste(mask, (M, M + 12))
shadow.putalpha(sm.point(lambda a: int(a * 0.30)))
shadow = shadow.filter(ImageFilter.GaussianBlur(18))
canvas = Image.alpha_composite(canvas, shadow)
body = card.convert("RGBA")
body.putalpha(mask)
canvas.alpha_composite(body, (M, M))
canvas.save(root / "Resources/AppIcon-1024.png")

iconset = root / "Resources/AppIcon.iconset"
shutil.rmtree(iconset, ignore_errors=True)
iconset.mkdir()
for size in [16, 32, 128, 256, 512]:
    for scale in [1, 2]:
        px_ = size * scale
        name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
        canvas.resize((px_, px_), Image.LANCZOS).save(iconset / name)
subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(root / "Resources/AppIcon.icns")], check=True)
shutil.rmtree(iconset)
print("icon written")
