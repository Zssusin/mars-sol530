"""全日联系表拼图：<帧目录>/{日出,日落}/%05d.png（90_全日延时.py --联系表 的路径渲出来的）→ 一张图，每格标时刻和太阳高度。
用法：91_联系表拼图.py <帧目录> <路径.json> <输出.png> [标题]"""
import json, pathlib, sys
from PIL import Image, ImageDraw, ImageFont
HERE = pathlib.Path(__file__).resolve().parent
D, PJ, OUT = pathlib.Path(sys.argv[1]), json.loads(pathlib.Path(sys.argv[2]).read_text()), sys.argv[3]
title = sys.argv[4] if len(sys.argv) > 4 else ""
S = json.loads((HERE.parent.parent/"godot"/"数据"/"sol0530"/"scene.json").read_text())["sky"]
tw, th, cols = 480, 270, 6
font = None
for p in ("/usr/share/fonts/google-noto-sans-cjk-vf-fonts/NotoSansCJK-VF.ttc", "/usr/share/fonts/google-noto-sans-mono-cjk-vf-fonts/NotoSansMonoCJK-VF.ttc"):
    try: font = ImageFont.truetype(p, 18); break
    except Exception: pass
rows = []
for shot in PJ["shots"]:
    fr = shot["frames"]; rows.append((shot["name"], fr))
H = sum(((len(fr) + cols - 1)//cols)*th + 30 for _, fr in rows) + 34
sheet = Image.new("RGB", (cols*tw, H), (12, 12, 14)); dr = ImageDraw.Draw(sheet)
dr.text((8, 6), title, fill=(230, 230, 230), font=font); y = 34
for name, fr in rows:
    dr.text((8, y + 4), name, fill=(255, 200, 120), font=font); y += 30
    for i, f in enumerate(fr):
        p = D/name/f"{i:05d}.png"
        if not p.exists(): continue
        im = Image.open(p).convert("RGB").resize((tw, th), Image.LANCZOS); x = (i % cols)*tw; yy = y + (i//cols)*th
        sheet.paste(im, (x, yy)); dr.rectangle((x, yy, x + 190, yy + 24), fill=(0, 0, 0))
        dr.text((x + 6, yy + 2), f"{f['t']}  太阳 {S[f['t']]['elev']:+.1f}°", fill=(255, 255, 255), font=font)
    y += ((len(fr) + cols - 1)//cols)*th
sheet.save(OUT); print("→", OUT)
