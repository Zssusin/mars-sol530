"""补丁验收出图对比：每个变体 vs 基准（自编），并以 自编b（同配置重跑）作噪声底。
用法：python 补丁对比.py 产出/Godot/补丁验收
输出：终端表格 + 各变体目录下 差_<相机>.png（|差|×8，暗化=蓝 亮化=红）。"""
import sys, pathlib, numpy as np
from PIL import Image

D = pathlib.Path(sys.argv[1])
PAIRS = [("自编b", "自编"), ("接触阴影", "自编"), ("接触阴影_补光", "自编_补光"),
         ("自编_补光", "自编"), ("预通道简化", "自编"), ("多次反弹AO", "自编")]

def load(p):
    return np.asarray(Image.open(p).convert("RGB"), dtype=np.float32)

print(f"{'变体':<14}{'基准':<10}{'相机':<22}{'平均|差|':>8}{'p99':>6}{'>4DN%':>7}{'>16DN%':>8}{'暗化>8%':>8}{'亮度差':>8}{'ΔR':>7}{'ΔG':>7}{'ΔB':>7}")
for var, base in PAIRS:
    vd, bd = D / var, D / base
    if not vd.is_dir() or not bd.is_dir():
        print(f"{var:<14}缺目录"); continue
    for bp in sorted(bd.glob("*.png")):
        if bp.name.startswith("差_"): continue
        vp = vd / bp.name
        if not vp.exists(): print(f"{var:<14}{base:<10}{bp.stem:<22}缺图"); continue
        a, b = load(vp), load(bp)
        d = a - b
        ad = np.abs(d).max(axis=2)
        lum = (d * [0.2126, 0.7152, 0.0722]).sum(axis=2)
        print(f"{var:<14}{base:<10}{bp.stem:<22}{ad.mean():8.3f}{np.percentile(ad,99):6.0f}"
              f"{(ad>4).mean()*100:7.2f}{(ad>16).mean()*100:8.3f}{(lum<-8).mean()*100:8.3f}"
              f"{lum.mean():8.3f}{d[...,0].mean():7.3f}{d[...,1].mean():7.3f}{d[...,2].mean():7.3f}")
        if var != "自编b":
            h = np.zeros_like(a)
            h[..., 0] = np.clip(lum, 0, None) * 8
            h[..., 2] = np.clip(-lum, 0, None) * 8
            Image.fromarray(np.clip(h, 0, 255).astype(np.uint8)).save(vd / f"差_{bp.name}")
