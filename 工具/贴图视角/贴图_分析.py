#!/usr/bin/env python3
"""贴图随视角变化：把斜视图矫正到俯视，和正下方俯拍比（带通后的归一化互相关 NCC）。
用法：贴图_分析.py <标签> [<对比标签>]   读 ~/贴图/out/<标签>/，写 ~/贴图/out/<标签>/分析/（拼图 + 数字 json）。
矫正：地面按 点.json 里 5×5 高度格（±1.5 m，0.75 m 格）拟合的局部平面；相机按 实景.gd 的 use_cam / 斜机位 约定（Godot：x 东、y 上、z = −北）。"""
import json, math, os, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy.ndimage import gaussian_filter, map_coordinates
HERE = os.path.dirname(os.path.abspath(__file__))
P = json.load(open(os.path.join(HERE, "点.json")))
W, H, HFOV = 2560, 1440, 60.0
PATCH, RES = 1.2, 0.002                      # 比较的地块边长 m、矫正后每像素 m
NG = int(PATCH / RES)
FONT = None
for fp in ("/home/user/.local/share/fonts/sarasa-mono/SarasaMonoSC-Light.ttf", "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"):
    if os.path.exists(fp): FONT = fp; break
def font(n):
    try: return ImageFont.truetype(FONT, n)
    except Exception: return ImageFont.load_default()

def plane(sp):
    g = np.array(sp["grid"]).reshape(5, 5)           # g[j, i]：j 北向（−1.5…+1.5），i 东向
    ii, jj = np.meshgrid((np.arange(5) - 2) * 0.75, (np.arange(5) - 2) * 0.75)
    A = np.c_[np.ones(25), ii.ravel(), jj.ravel()]
    c, *_ = np.linalg.lstsq(A, g.ravel(), rcond=None)
    return c                                           # y = c0 + c1 (E − E0) + c2 (N − N0)

def camera(c, sp):
    """c：meta 里的一条。返回 pos, fw, r, up（Godot 世界）"""
    E, N = sp["E"], sp["N"]
    if c["kind"] == "top":
        yc = sp["y0"] + c["h"]; pos = np.array([E, yc, -N]); pitch = 89.9; az = 0.0
    else:
        d = c["D"]; hc = sp["y0"] + d * math.tan(math.radians(c["el"])); pos = np.array([E, hc, -(N - d)])
        pitch = math.degrees(math.atan2(hc - sp["y0"], d)); az = 0.0
    pt = math.radians(-pitch); a = math.radians(az)
    fw = np.array([math.sin(a) * math.cos(pt), math.sin(pt), -math.cos(a) * math.cos(pt)])
    r = np.cross(fw, [0, 1, 0]); r /= np.linalg.norm(r); up = np.cross(r, fw)
    return pos, fw, r, up

def rectify(img, c, sp, pl):
    """img：H×W×3 float。返回 NG×NG×3（北在上）、该相机在地块中心的足迹（横向、沿视线，米）。"""
    E, N = sp["E"], sp["N"]
    xs = (np.arange(NG) + 0.5) * RES - PATCH / 2
    e, n = np.meshgrid(xs, xs[::-1])
    y = pl[0] + pl[1] * e + pl[2] * n
    X = np.stack([E + e, y, -(N + n)], -1)
    pos, fw, r, up = camera(c, sp)
    v = X - pos
    d = v @ fw; xc = v @ r; yc = v @ up
    f = (W / 2) / math.tan(math.radians(HFOV / 2))
    u = W / 2 + f * xc / d - 0.5; vv = H / 2 - f * yc / d - 0.5
    out = np.stack([map_coordinates(img[..., k], [vv, u], order=1, mode="nearest") for k in range(3)], -1)
    # 足迹：中心点
    X0 = np.array([E, sp["y0"], -N]); v0 = X0 - pos; d0 = v0 @ fw; pa = math.radians(HFOV) / W
    nrm = np.array([-pl[1], 1.0, pl[2]]); nrm /= np.linalg.norm(nrm)     # 平面法线（Godot：x = E，z = −N → dy/dz = −c2）
    nrm = np.array([-pl[1], 1.0, pl[2]]); nrm /= np.linalg.norm(nrm)
    cosg = abs(float(v0 @ nrm)) / np.linalg.norm(v0)                    # 视线与地面夹角的正弦
    cosg = max(cosg, 0.03)
    lat = np.linalg.norm(v0) * pa; along = lat / cosg
    return out, lat, along

def lum(a): return 0.2126 * a[..., 0] + 0.7152 * a[..., 1] + 0.0722 * a[..., 2]
def dog(x, s1, s2): return gaussian_filter(x, s1 / RES) - gaussian_filter(x, s2 / RES)
def ncc(a, b):
    m = int(0.15 * NG); a = a[m:-m, m:-m]; b = b[m:-m, m:-m]
    a = a - a.mean(); b = b - b.mean()
    return float((a * b).sum() / (np.sqrt((a * a).sum() * (b * b).sum()) + 1e-12))

BANDS = [(0.02, 0.04), (0.04, 0.08), (0.08, 0.16), (0.16, 0.32)]       # 米：DoG 的 σ1、σ2

def pair_metrics(Lt, ft, Lo, fo):
    """两张矫正图：先都磨到共同的分辨率（σ = 0.5 × 较粗的足迹），再算各频带 NCC；足迹大于频带 σ1 的频带不报（写 None）。"""
    foot = max(ft, fo); res = {}
    s0 = 0.5 * foot
    A = gaussian_filter(Lt, s0 / RES); B = gaussian_filter(Lo, s0 / RES)
    for (s1, s2) in BANDS:
        if s1 < 1.5 * foot * 0.5 + 0.0 or s1 < 0.75 * foot: res[f"{s1:.2f}"] = None; continue
        res[f"{s1:.2f}"] = ncc(dog(A, s1, s2), dog(B, s1, s2))
    res["foot"] = foot
    return res

def load(path): return np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) / 255.0

def tile(a, size=300, label=None, sub=None):
    im = Image.fromarray((np.clip(a, 0, 1) * 255).astype(np.uint8)).resize((size, size), Image.LANCZOS)
    dr = ImageDraw.Draw(im)
    if label: dr.rectangle([0, 0, size, 18], fill=(0, 0, 0)); dr.text((3, 1), label, fill=(255, 255, 255), font=font(13))
    if sub: dr.rectangle([0, size - 18, size, size], fill=(0, 0, 0)); dr.text((3, size - 17), sub, fill=(255, 220, 120), font=font(13))
    return im

def run(tag, mode, outdir, meta):
    allres = {}
    for sname, cl in meta.items():
        sp = P[sname]; pl = plane(sp)
        d = os.path.expanduser(f"~/贴图/out/{tag}/{sname}_{mode}")
        if not os.path.isdir(d): continue
        files = sorted(f for f in os.listdir(d) if f.endswith(".png"))
        rect = {}
        for i, c in enumerate(cl):
            fn = [f for f in files if f.startswith(f"斜视{i}_")]
            if not fn: continue
            img = load(os.path.join(d, fn[0]))
            rimg, lat, along = rectify(img, c, sp, pl)
            rect[c["name"]] = (rimg, lat, along)
        tops = [k for k in rect if k.startswith("top")]
        res = {}
        for ko in rect:
            for kt in tops:
                if ko == kt: continue
                res[f"{ko}|{kt}"] = pair_metrics(lum(rect[kt][0]), rect[kt][1], lum(rect[ko][0]), rect[ko][2])
        for a in range(len(tops)):
            for b in range(a + 1, len(tops)): pass
        allres[sname] = dict(pairs=res, foot={k: dict(lat=v[1], along=v[2]) for k, v in rect.items()})
        # 拼图：每行 = 一台斜视；列 = top2 top8 top30 | 斜视矫正
        names = [k for k in rect if k.startswith("obl")]
        rows = []
        for ko in names:
            ims = []
            for kt in tops:
                ims.append(tile(rect[kt][0], label=f"{kt} (足迹 {rect[kt][1]*1000:.0f} mm)"))
            r = rect[ko]
            bandtxt = "  ".join(f"{k}:{(v if v is not None else float('nan')):.2f}" for k, v in res[f"{ko}|top8"].items() if k != "foot")
            ims.append(tile(r[0], label=f"{ko}  横 {r[1]*1000:.0f} / 沿 {r[2]*1000:.0f} mm", sub=f"vs top8 {bandtxt}"))
            rows.append(ims)
        if rows:
            sheet = Image.new("RGB", (300 * 4, 300 * len(rows)))
            for y, ims in enumerate(rows):
                for x, im in enumerate(ims): sheet.paste(im, (x * 300, y * 300))
            sheet.save(os.path.join(outdir, f"{sname}_{mode}_拼图.jpg"), quality=90)
    json.dump(allres, open(os.path.join(outdir, f"{mode}_数字.json"), "w"), ensure_ascii=False, indent=1)
    return allres

if __name__ == "__main__":
    tag = sys.argv[1]
    base = os.path.expanduser(f"~/贴图/out/{tag}")
    meta = json.load(open(os.path.join(base, "meta.json")))
    outdir = os.path.join(base, "分析"); os.makedirs(outdir, exist_ok=True)
    for mode in ("alb", "lit"):
        r = run(tag, mode, outdir, meta)
        print("==", tag, mode)
        for s, v in r.items():
            for k, m in v["pairs"].items():
                if k.endswith("|top8"):
                    print(f"  {s} {k}: " + " ".join(f"{b}={x:.2f}" if x is not None else f"{b}=--" for b, x in m.items() if b != "foot"), f"foot={m['foot']*1000:.0f}mm")
