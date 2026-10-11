# 界面改动的前后对比：两套自测截图（界面/测试.sh、玩法/测试.sh 的产出目录，各有 界面/ 玩法/ 两个子目录）逐张比，
#   ① 打印每张的平均差（0–255，整张）和差 > 24 的像素比例（量「除了颜色没别的变化」：同色板时应该只剩渲染噪声）；
#   ② 拼前后对比图到 docs/界面/图/<名>_*.jpg（1600 宽，左前右后，每格左下角标签）。
#   用法：.venv/bin/python 工具/界面前后图.py <前目录> <后目录> <输出名前缀> [--只量]
import os, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont
R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = R + "/docs/界面/图"; os.makedirs(OUT, exist_ok=True)
F = ImageFont.truetype(R + "/godot/界面/素材/NotoSansSC-VF.ttf", 18)
前, 后, 名 = sys.argv[1], sys.argv[2], sys.argv[3]
只量 = "--只量" in sys.argv


def 差(a, b):
    A = np.asarray(Image.open(a).convert("RGB")).astype(np.int16); B = np.asarray(Image.open(b).convert("RGB")).astype(np.int16)
    if A.shape != B.shape: return None
    d = np.abs(A - B).max(axis=2)
    return float(d.mean()), float((d > 24).mean()*100)


for sub in ["界面", "玩法"]:
    for f in sorted(os.listdir(f"{前}/{sub}")) if os.path.isdir(f"{前}/{sub}") else []:
        if not f.endswith(".png") or not os.path.exists(f"{后}/{sub}/{f}"): continue
        r = 差(f"{前}/{sub}/{f}", f"{后}/{sub}/{f}")
        if r: print(f"{sub}/{f:<28} 平均差 {r[0]:5.2f}  差>24 的像素 {r[1]:5.2f} %")
if 只量: sys.exit(0)


def sheet(n, rows, w=1600):
    cw = w // 2; ch = cw*9//16
    S = Image.new("RGB", (w, ch*len(rows)), (16, 16, 16)); d = ImageDraw.Draw(S)
    for r, row in enumerate(rows):
        for c, (path, lab) in enumerate(row):
            if not os.path.exists(path): continue
            im = Image.open(path).convert("RGB").resize((cw, ch), Image.LANCZOS); S.paste(im, (c*cw, r*ch))
            tw = d.textlength(lab, font=F); y0 = r*ch + ch - 26; d.rectangle([c*cw, y0, c*cw + tw + 14, y0 + 26], fill=(0, 0, 0)); d.text((c*cw + 7, y0 + 2), lab, font=F, fill=(255, 255, 255))
        d.line([(cw, r*ch), (cw, r*ch + ch)], fill=(16, 16, 16), width=3)
    S.save(f"{OUT}/{n}.jpg", quality=82, optimize=True); print(n, S.size, os.path.getsize(f"{OUT}/{n}.jpg")//1024, "KB")


标前 = os.environ.get("LABEL_A", "前"); 标后 = os.environ.get("LABEL_B", "后")
组 = {"跟车": [("界面", "1_直行", "跟车直行"), ("界面", "2_阿克曼左弧", "阿克曼左弧"), ("界面", "4_斜坡倾角", "斜坡告警")],
     "桅杆俯视": [("界面", "5_桅杆_右弧", "桅杆"), ("界面", "7_俯视_远图_上午", "俯视"), ("界面", "9_兴趣点", "兴趣点小标")],
     "玩法": [("玩法", "兴趣点_2_导览卡", "导览卡"), ("玩法", "B_5_执行_HUD", "B 执行（跟车）"), ("玩法", "B_6_执行_桅杆", "B 执行（桅杆）")],
     "B页面": [("玩法", "B_1_下行卡", "下行卡"), ("玩法", "B_3_规划图_预演", "规划图"), ("玩法", "B_7_报告卡", "报告卡")]}
for k, rows in 组.items():
    sheet(f"{名}_{k}", [[(f"{前}/{s}/{n}.png", f"{标前} · {t}"), (f"{后}/{s}/{n}.png", f"{标后} · {t}")] for s, n, t in rows])
