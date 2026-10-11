#!/usr/bin/env python3
"""改前 | 改后 同机位对比图 + 数字汇总。用法：贴图_对比.py <改前标签> <改后标签> <输出目录>"""
import json, os, sys
from PIL import Image, ImageDraw, ImageFont
b, a, out = sys.argv[1], sys.argv[2], os.path.expanduser(sys.argv[3]); os.makedirs(out, exist_ok=True)
O = os.path.expanduser("~/贴图/out")
FONT = "/home/user/.local/share/fonts/sarasa-mono/SarasaMonoSC-Light.ttf"
def f(n):
    try: return ImageFont.truetype(FONT, n)
    except Exception: return ImageFont.load_default()
meta = json.load(open(f"{O}/{b}/meta.json"))
nb = json.load(open(f"{O}/{b}/分析/alb_数字.json")); na = json.load(open(f"{O}/{a}/分析/alb_数字.json"))
def pair(spot, cam, mode, w=1100, crop=None):
    names = [c["name"] for c in meta[spot]]; i = names.index(cam)
    ims = []
    for tag, lab in ((b, "改前"), (a, "改后")):
        im = Image.open(f"{O}/{tag}/{spot}_{mode}/斜视{i}_1307.png").convert("RGB")
        if crop: im = im.crop(crop)
        im = im.resize((w, int(w * im.height / im.width)), Image.LANCZOS)
        d = ImageDraw.Draw(im); d.rectangle([0, 0, 420, 30], fill=(0, 0, 0)); d.text((6, 3), f"{lab}  {spot} {cam}", fill=(255, 255, 255), font=f(20))
        ims.append(im)
    s = Image.new("RGB", (w * 2 + 6, ims[0].height), (255, 255, 255)); s.paste(ims[0], (0, 0)); s.paste(ims[1], (w + 6, 0)); return s
for spot in meta:
    for cam, mode, crop in (("top30", "alb", (480, 270, 2080, 1170)), ("top8", "alb", (480, 270, 2080, 1170)), ("obl10_20", "alb", None), ("obl25_20", "alb", None), ("obl10_20", "lit", None), ("top30", "lit", (480, 270, 2080, 1170))):
        pair(spot, cam, mode, crop=crop).convert("RGB").save(f"{out}/{spot}_{cam}_{mode}_前后.jpg", quality=88)
# 数字表
rows = []
for spot in nb:
    for k in nb[spot]["pairs"]:
        if not k.endswith("|top8"): continue
        rb = nb[spot]["pairs"][k]; ra = na[spot]["pairs"][k]
        rows.append((spot, k.split("|")[0], rb, ra))
bands = ["0.04", "0.08", "0.16"]
H = 36 + 26 * (len(rows) + 1); W = 1500
im = Image.new("RGB", (W, H), (255, 255, 255)); d = ImageDraw.Draw(im)
d.text((8, 6), "同一地块 斜视/俯视(30 m) 对 正下方 8 m 俯拍：带通 NCC，改前 → 改后（频带 σ = 4 / 8 / 16 cm；— = 像素足迹太大不报）", fill=(0, 0, 0), font=f(18))
y = 36
for r in [("点", "机位", {}, {})] + rows:
    d.text((8, y), r[0], fill=(0, 0, 0), font=f(17)); d.text((110, y), r[1], fill=(0, 0, 0), font=f(17))
    if isinstance(r[2], dict) and r[2]:
        d.text((300, y), f"足迹 {r[2]['foot']*1000:.0f} mm", fill=(90, 90, 90), font=f(17))
        for j, bd in enumerate(bands):
            vb, va = r[2].get(bd), r[3].get(bd)
            t = "—" if vb is None else f"{vb:.2f} → {va:.2f}"
            col = (0, 0, 0) if vb is None else ((0, 120, 0) if va - vb > 0.1 else (0, 0, 0))
            d.text((520 + j * 300, y), t, fill=col, font=f(17))
    else:
        for j, bd in enumerate(bands): d.text((520 + j * 300, y), f"σ {bd} m", fill=(0, 0, 0), font=f(17))
    y += 26
im.save(f"{out}/数字汇总.png")
