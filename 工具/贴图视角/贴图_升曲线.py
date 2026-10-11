#!/usr/bin/env python3
"""升镜头序列：每帧矫正到 0.9 m 地块，和参考帧（h≈8 m）比带通 NCC，画成曲线（改前 / 改后）。用法：贴图_升曲线.py 输出png"""
import json, math, os, sys
import numpy as np
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager
font_manager.fontManager.addfont("/home/user/.local/share/fonts/sarasa-mono/SarasaMonoSC-Light.ttf"); plt.rcParams["font.family"] = "Sarasa Mono SC"
import 贴图_分析 as A
A.W, A.H, A.HFOV = 1280, 720, 60.0; A.PATCH = 0.9; A.NG = int(A.PATCH / A.RES)
sp = A.P["C远"]; pl = A.plane(sp)
N = 360; hs = [1.6 * (40 / 1.6) ** (i / (N - 1)) for i in range(N)]
ref_i = int(round((N - 1) * math.log(8 / 1.6) / math.log(25)))
def rect(tag, i):
    img = A.load(os.path.expanduser(f"~/贴图/seq/{tag}/升/{i:05d}.png"))
    return A.rectify(img, dict(kind="top", h=hs[i]), sp, pl)
res = {}
for tag in ("before", "after"):
    R, lat, _ = rect(tag, ref_i); Lr = A.lum(R); curves = {b: [] for b in (0.04, 0.08, 0.16)}
    for i in range(0, N, 6):
        Ri, la, _ = rect(tag, i); Li = A.lum(Ri); foot = max(la, lat)
        a = A.gaussian_filter(Lr, 0.5 * foot / A.RES); b = A.gaussian_filter(Li, 0.5 * foot / A.RES)
        for s1 in curves:
            curves[s1].append(A.ncc(A.dog(a, s1, 2 * s1), A.dog(b, s1, 2 * s1)) if s1 >= 0.75 * foot else float("nan"))
    res[tag] = curves
x = [hs[i] for i in range(0, N, 6)]
fig, ax = plt.subplots(1, 3, figsize=(15, 4), sharey=True)
for k, s1 in enumerate((0.04, 0.08, 0.16)):
    for tag, c in (("before", "tab:red"), ("after", "tab:green")):
        ax[k].plot(x, res[tag][s1], c, label={"before": "改前", "after": "改后"}[tag])
    ax[k].set_xscale("log"); ax[k].set_title(f"频带 σ = {int(s1*100)} cm"); ax[k].set_xlabel("相机离地高度 m"); ax[k].grid(alpha=.3); ax[k].set_ylim(-0.2, 1.02)
ax[0].set_ylabel("与 8 m 高度那帧的 NCC（C 远 点，正下方升镜头）"); ax[0].legend()
plt.tight_layout(); plt.savefig(os.path.expanduser(sys.argv[1]), dpi=110)
json.dump(res, open(os.path.expanduser(sys.argv[1]).replace(".png", ".json"), "w"))
