"""量 HUD 文字的对比度：在界面自测截图里找出白 / 浅灰字（填充色 ±0.06），取每个字像素外 2–4 px 的一圈「紧邻背景」
（跳过紧贴的 1 px 抗锯齿边，也去掉圈里本身是界面颜色的像素），
算 WCAG 对比度 (L字+0.05)/(L圈+0.05)。紧邻背景里包含描边，所以量的是「描边之后读者实际看到的反差」。
  报中位数和最不利的 10%（紧邻背景亮度取 90 分位数）。区域取自日志里的「[界面] 区域」。
用法：python3 godot/界面/对比度.py <改前截图目录> <改后截图目录>   → 打印 Markdown 表
"""
import json, pathlib, re, sys
import numpy as np
from PIL import Image

白 = np.array([0.97, 0.95, 0.91]); 灰 = np.array([0.84, 0.81, 0.76])
色板 = [白, 灰, np.array([0.70, 0.67, 0.63]), np.array([1.0, 0.72, 0.22]), np.array([0.93, 0.25, 0.20])]   # 界面.gd 的白、灰、淡、琥珀、红


def lum(a):
    a = np.where(a <= 0.04045, a/12.92, ((a + 0.055)/1.055)**2.4)
    return a @ np.array([0.2126, 0.7152, 0.0722])


def dil(m, r):
    o = m.copy()
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            o |= np.roll(np.roll(m, dy, 0), dx, 1)
    return o


def 量(png, rect):
    x, y, w, h = rect
    a = np.asarray(Image.open(png).convert("RGB")).astype(np.float64)[y:y + h, x:x + w]/255.0
    L = lum(a)
    字 = (np.abs(a - 白).max(-1) < 0.06) | (np.abs(a - 灰).max(-1) < 0.06)
    if 字.sum() < 30: return None
    界 = np.zeros_like(字)
    for c in 色板: 界 |= np.abs(a - c).max(-1) < 0.10
    圈 = dil(字, 4) & ~dil(字, 1) & ~界
    lg = np.median(L[字]); lr50 = np.median(L[圈]); lr90 = np.percentile(L[圈], 90)
    return (lg + 0.05)/(lr50 + 0.05), (lg + 0.05)/(lr90 + 0.05), lr50, lr90


前, 后 = map(pathlib.Path, sys.argv[1:3])
区域 = json.loads(re.search(r"\[界面\] 区域 (\{.*\})", (后/"日志.txt").read_text()).group(1))
x, y, w, h = 区域["航向带"]; 区域["航向带左段"] = [x, y, w//3, h]
图 = {"1": "1_直行", "4": "4_斜坡倾角", "5": "5_桅杆_右弧", "7": "7_俯视_远图_上午"}
项 = [("1", "航向带"), ("1", "小地图"), ("1", "图注"), ("4", "车轮速度"), ("4", "姿态仪"), ("4", "角标"), ("5", "车轮速度"), ("5", "航向带左段"), ("5", "太阳表"), ("7", "航向带")]
print("| 截图 · 区域 | 白 / 灰字对紧邻背景 中位 改前 → 改后 | 最不利 10% 改前 → 改后 | 紧邻背景 L 90% 改前 → 改后 |")
print("|---|---|---|---|")
for k, r in 项:
    a = 量(前/f"{图[k]}.png", 区域[r]); b = 量(后/f"{图[k]}.png", 区域[r])
    f = lambda v, i, fmt="{:.1f}": "—" if v is None else fmt.format(v[i])
    print(f"| {k} · {r} | {f(a, 0)} → {f(b, 0)} | {f(a, 1)} → {f(b, 1)} | {f(a, 3, '{:.2f}')} → {f(b, 3, '{:.2f}')} |")
