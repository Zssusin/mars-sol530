#!/usr/bin/env python3
"""
78 平铺重复度：地面细节贴图平铺出来的周期性有多强（docs/地面材质/阶段1.md §9.6）。

输入是 实景.gd --俯机位=E,N,离地高,视场 渲出的正下方俯拍（北在上、等比例），或任意一张图里指定的矩形。
做法：
  1. 亮度取 log，减去 σ = 低频米数 的高斯平滑（去掉宏观反照率和大起伏，只留 cm–m 级纹理）；
  2. 加 Hann 窗，FFT 求归一化自相关 R(Δ)（R(0) = 1）；
  3. 去掉中心峰（|Δ| < 排除米数），剩下的最大值 = 重复度峰值；再给前 5 个峰（相互至少隔 排除米数）的均值。
  4. 去径向峰：R 减去同半径圆环均值后的最大峰。中心峰拖尾和纹理平滑是各向同性的，会抬高 3 的峰值（排除半径只有几个像素时
     尤其明显），周期平铺是孤立的峰。新旧对比以它为主（阶段 1 B 步）。
真随机的纹理峰值只有窗口大小决定的噪声底（约 0.05–0.15）；样块周期平铺会在 Δ = 样块边长处出现 0.3 以上的峰。
新旧对比用同一机位、同一时刻，只换 --材质=旧。

用法（fedora）：
  .venv/bin/python scripts/Godot/78_平铺重复度.py <png>… [--米每像素=0.018] [--低频=2.0] [--排除=0.25] [--图=<输出 jpg>]
  米每像素：俯拍时 = 2·离地高·tan(视场/2)/像素宽；不给就按文件名旁的 俯视.json（实景.gd 不写，手动给）。
"""
import sys, json, math, pathlib
import numpy as np


def score(img, mpp, low=2.0, excl=0.25, npk=5):
    from scipy.ndimage import gaussian_filter, maximum_filter
    a = np.asarray(img, np.float64)
    if a.ndim == 3: a = a[..., :3] @ np.array([0.2126, 0.7152, 0.0722])
    a = np.log(np.maximum(a, 1.0))
    a = a - gaussian_filter(a, low/mpp, mode="reflect")
    h, w = a.shape
    win = np.outer(np.hanning(h), np.hanning(w))
    a = (a - a.mean())*win
    F = np.fft.rfft2(a, s=(2*h, 2*w))                         # 补零：线性（非循环）自相关
    R = np.fft.irfft2(np.abs(F)**2, s=(2*h, 2*w))
    R = np.fft.fftshift(R)
    wc = np.fft.fftshift(np.fft.irfft2(np.abs(np.fft.rfft2(win, s=(2*h, 2*w)))**2, s=(2*h, 2*w)))
    R = R/np.maximum(wc, wc.max()*0.25)                       # 按重叠面积归一（大位移处重叠太少的不要）
    R = R/R[h, w]
    yy, xx = np.mgrid[-h:h, -w:w]
    rr = np.hypot(yy, xx)*mpp
    ok = (rr >= excl) & (wc >= wc.max()*0.25) & (yy >= 0)      # 自相关对称，只看一半
    Rm = np.where(ok, R, -np.inf)
    pk = (Rm == maximum_filter(Rm, size=max(3, int(excl/mpp)))) & ok
    vals = np.sort(R[pk])[::-1]
    idx = np.argwhere(pk); order = np.argsort(-R[pk])
    top = [(float(R[tuple(idx[i])]), float(rr[tuple(idx[i])])) for i in order[:npk]]
    # 去径向：R 减去同半径圆环上的均值（中心峰的拖尾、纹理本身的平滑都是各向同性的，周期平铺是孤立的峰）
    ri = np.round(np.hypot(yy, xx)).astype(int); okw = ok.astype(float)
    num = np.bincount(ri.ravel(), (np.where(ok, R, 0.0)).ravel()); den = np.bincount(ri.ravel(), okw.ravel())
    Rr = np.where(ok, R - (num/np.maximum(den, 1))[ri], -np.inf)
    pr = (Rr == maximum_filter(Rr, size=max(3, int(excl/mpp)))) & ok
    ir = np.argwhere(pr); orr = np.argsort(-Rr[pr])
    topr = [(float(Rr[tuple(ir[i])]), float(rr[tuple(ir[i])])) for i in orr[:npk]]
    return dict(峰值=float(vals[0]) if vals.size else 0.0, 前5均值=float(vals[:npk].mean()) if vals.size else 0.0,
                前5=[(round(v, 3), round(r, 2)) for v, r in top],
                去径向峰=topr[0][0] if topr else 0.0, 去径向前5=[(round(v, 3), round(r, 2)) for v, r in topr]), R


def main(a):
    from PIL import Image
    files = [x for x in a if not x.startswith("--")]
    opt = dict(x[2:].split("=", 1) for x in a if x.startswith("--") and "=" in x)
    mpp = float(opt.get("米每像素", "0.018")); low = float(opt.get("低频", "2.0")); excl = float(opt.get("排除", "0.25"))
    out = {}
    for f in files:
        s, R = score(Image.open(f).convert("RGB"), mpp, low, excl)
        out[f] = s
        print(f"{pathlib.Path(f).parent.name}/{pathlib.Path(f).name}：峰值 {s['峰值']:.3f}、前 5 峰均值 {s['前5均值']:.3f}；前 5 峰（R, 距离 m）{s['前5']}；去径向峰 {s['去径向峰']:.3f} {s['去径向前5'][:3]}")
        if "图" in opt:
            h, w = R.shape; c = R[h//2 - h//4:h//2 + h//4, w//2 - w//4:w//2 + w//4]
            Image.fromarray((np.clip(c*2 + 0.2, 0, 1)*255).astype(np.uint8)).resize((400, 400)).save(
                pathlib.Path(opt["图"]).with_name(pathlib.Path(opt["图"]).stem + "_" + pathlib.Path(f).parent.name + ".png"))
    if "json" in opt: pathlib.Path(opt["json"]).write_text(json.dumps(out, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main(sys.argv[1:])
