#!/usr/bin/env python3
"""界面配色的对比度（docs/界面/UI体系.md §3「可读性」）：在一张游戏截图的地面区域上量亮度分位数，
算每套色板各角色（芯色、描边色）对「最亮的地面」的 WCAG 2.x 对比度，以及芯色对自己描边的对比度。

界面 6（规范 §5，2026-10-10 更正）：压在 3D 画面上的字和图标有两种量法——
  旧法：字所在区域背景的 p95 亮度（白字压亮沙地最多约 2:1，只适用于整屏页，有整屏暗底的设置、图鉴、地图）；
  新法：字对紧贴笔画外 1–3 px 那一圈（它自己的描边）的 p95 亮度，描边宽要 ≥ max(2 px, 字高 × 8 %)。
  新法用法：工具/界面对比度.py <截图.png> --描边=x0,y0,x1,y1（字的像素矩形）[--字色=#FFFFFF] [--描边色=#140E0A]，同时打印旧法数字。
  （和 件.gd 的 描边测 同一算法：字芯 = 亮度离描边色 > 15 % 字色距离的像素；带 = 离字芯 1–3 px；宽 = 向外连续深色像素数的中位数。）

用法：工具/界面对比度.py <截图.png> [--区域=x0,y0,x1,y1（0–1 比例）] [--分位=95]
  截图用 13:07 跟车（最亮的地面，界面/测试.sh 的 1_直行.png）。区域默认取左下一块纯地面（避开车和 HUD）。
色板从 godot/界面/令牌.gd 里读（只认 "#RRGGBB[AA]" 字面量），不在这里重抄。
WCAG：相对亮度 L = 0.2126 R + 0.7152 G + 0.0722 B（sRGB 线性化），对比度 (L1 + 0.05) / (L2 + 0.05)。
  文字 / 细线建议 ≥ 3:1（WCAG 1.4.11 非文字对比、1.4.3 大字）；有描边时「描边对地面」和「芯对描边」都要过 3:1。
"""
import re, sys, pathlib
import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent


def lin(c):
    c = np.asarray(c, dtype=np.float64)
    return np.where(c <= 0.04045, c/12.92, ((c + 0.055)/1.055)**2.4)


def L(rgb):
    r, g, b = lin(np.asarray(rgb)/255.0) if np.max(rgb) > 1 else lin(rgb)
    return 0.2126*r + 0.7152*g + 0.0722*b


def cr(a, b):
    hi, lo = max(a, b), min(a, b)
    return (hi + 0.05)/(lo + 0.05)


def hexrgb(h):
    h = h.lstrip("#"); return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def 读色板():
    t = (ROOT/"godot/界面/令牌.gd").read_text(encoding="utf-8")
    out = {}
    for m in re.finditer(r'^\t"([^"]+)": \{(.*?)\},?$', t, re.S | re.M):
        d = dict(re.findall(r'"([^"]+)": "([^"]*)"', m.group(2)))
        if "主" in d: out[m.group(1)] = d
    return out


def 描边测(img, rect, 字色, 描色):
    """img：H×W×3 float 0–255；rect：像素 (x0,y0,x1,y1)。返回 (新法对比, 旧法对比, 描边宽 px)。"""
    x0, y0, x1, y1 = rect; g = 16
    X0, Y0, X1, Y1 = max(0, x0 - g), max(0, y0 - g), min(img.shape[1], x1 + g), min(img.shape[0], y1 + g)
    sub = img[Y0:Y1, X0:X1]/255.0
    Ls = 0.2126*lin(sub[..., 0]) + 0.7152*lin(sub[..., 1]) + 0.0722*lin(sub[..., 2])
    Lf, Lo = L(hexrgb(字色)), L(hexrgb(描色)); 阈 = 0.15*abs(Lf - Lo)
    芯 = np.zeros(Ls.shape, bool)
    芯[y0 - Y0:y1 - Y0, x0 - X0:x1 - X0] = np.abs(Ls[y0 - Y0:y1 - Y0, x0 - X0:x1 - X0] - Lo) > 阈
    d = np.where(芯, 0, 99)
    for k in (1, 2, 3):
        pad = np.pad(d, 1, constant_values=99); near = np.zeros(d.shape, bool)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                near |= pad[1 + dy:1 + dy + d.shape[0], 1 + dx:1 + dx + d.shape[1]] == k - 1
        d = np.where((d == 99) & near, k, d)
    带 = Ls[(d >= 1) & (d <= 3)]
    新 = cr(Lf, float(np.percentile(带, 95))) if 带.size else 0.0
    yy, xx = np.mgrid[Y0:Y1, X0:X1]
    外 = (np.maximum(np.maximum(x0 - 14 - xx, xx - (x1 + 14)), np.maximum(y0 - 14 - yy, yy - (y1 + 14))) < 0) & ~((xx >= x0 - 3) & (xx < x1 + 3) & (yy >= y0 - 3) & (yy < y1 + 3))
    旧 = cr(Lf, float(np.percentile(Ls[外], 95)))
    宽s = []
    for y, x in zip(*np.nonzero(d == 0)):
        if y < 2 or x < 2 or y >= d.shape[0] - 2 or x >= d.shape[1] - 2: continue
        if not any(d[y + dy, x + dx] != 0 for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0))): continue
        best = 0
        for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0)):
            n, yy2, xx2 = 0, y + dy, x + dx
            while n < 10 and 0 <= yy2 < d.shape[0] and 0 <= xx2 < d.shape[1] and d[yy2, xx2] != 0 and Ls[yy2, xx2] < Lo + 0.12*abs(Lf - Lo) + 0.02:
                n += 1; yy2 += dy; xx2 += dx
            best = max(best, n)
        宽s.append(best)
    return 新, 旧, float(np.median(宽s)) if 宽s else 0.0


def main():
    a = [x for x in sys.argv[1:] if not x.startswith("--")]
    opt = dict(x[2:].split("=", 1) for x in sys.argv[1:] if x.startswith("--") and "=" in x)
    if not a: print(__doc__); sys.exit(2)
    img = np.asarray(Image.open(a[0]).convert("RGB")).astype(np.float64)
    if "描边" in opt:
        r = [int(v) for v in opt["描边"].split(",")]
        新, 旧, 宽 = 描边测(img, r, opt.get("字色", "#FFFFFF"), opt.get("描边色", "#140E0A"))
        print(f"新法（对自己的描边）{新:.1f}:1，描边宽 {宽:.0f} px；旧法（背景 p95）{旧:.1f}:1"); return
    H, W, _ = img.shape
    x0, y0, x1, y1 = [float(v) for v in opt.get("区域", "0.02,0.62,0.30,0.98").split(",")]
    reg = img[int(y0*H):int(y1*H), int(x0*W):int(x1*W)].reshape(-1, 3)
    lum = 0.2126*lin(reg[:, 0]/255) + 0.7152*lin(reg[:, 1]/255) + 0.0722*lin(reg[:, 2]/255)
    q = float(opt.get("分位", "95"))
    Lg = float(np.percentile(lum, q)); Lm = float(np.median(lum))
    i = int(np.argmin(np.abs(lum - Lg))); g = reg[i]
    print(f"地面（{a[0]}，区域 {x0},{y0}–{x1},{y1}）：亮度 p{q:.0f} = {Lg:.3f}（像素约 #{int(g[0]):02X}{int(g[1]):02X}{int(g[2]):02X}），中位 {Lm:.3f}")
    print(f"{'色板':<8}{'角色':<6}{'芯':<9}{'边':<9}{'芯/地':>7}{'边/地':>7}{'芯/边':>7}  判定（芯/地 或 边/地 与 芯/边 ≥ 3）")
    for 名, d in 读色板().items():
        暗 = d["暗"]
        for 角 in ["主", "次", "活", "注意", "警告"]:
            芯 = d[角][:7]
            边 = d["活边"] if (角 == "活" and d.get("活边")) else 暗
            Lc, Le = L(hexrgb(芯)), L(hexrgb(边[:7]))
            a1, a2, a3 = cr(Lc, Lg), cr(Le, Lg), cr(Lc, Le)
            ok = a1 >= 3 or (a2 >= 3 and a3 >= 3)
            print(f"{名:<8}{角:<6}{芯:<9}{边[:7]:<9}{a1:7.2f}{a2:7.2f}{a3:7.2f}  {'过' if ok else '不过'}")


if __name__ == "__main__":
    main()
