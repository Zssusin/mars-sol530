#!/usr/bin/env python3
"""
72 近景细化：用 PDS 全分辨率 Navcam 立体产品（XYZ / RAS / UVW）重建车旁地面的「细」层，代替抽稀过的 OBJ 网格。
报告见 docs/地面材质/近景细化.md；数据约定同 scripts/Blender/实景地形系统.md §2–§3，相机模型、配准、去光影沿用 71_地面样块.py。

子命令（.venv/bin/python scripts/Godot/72_近景细化.py <子命令> [选项]）：
  下载    列出并下载站点 26 / drive 1222（sol 502–534）全部 Navcam 立体帧的 XYZ + RAS 左（+ 半分辨率帧的 UVW），
          批1 已有的工作区帧不重下。写 资料/地面材质/PDS/批4/、清单_批4.json、下载_批4.log。69 的下载函数原样复用。
  测量    现状：albedo_near / albedo_mid、CDLOD 第 0 层高度对 71 的 2 mm 正射（XYZ）的传递函数与相干，给出有效分辨率；
          写 资料/地面材质/近景细化/测量/。
  正射    每帧 XYZ → 公共细格（ENU，原点 = 毅力号导航点，第 0 行在南），存高度、RAS 左、点距（每格的真实足迹）、太阳、相机。
  配准    各帧对参考帧（71 的 sol 531 正午，工作区内）和彼此做分块互相关 → 仿射位移 + 高度平面，同 71。
  融合    多帧合成：高度（按点距/噪声加权中值）、去光影反照率（立体法线 + 每帧太阳 + 投射阴影 + 天光，逐帧增益）、
          每格真实分辨率；嵌入 71 的 2 mm 工作区基线；分半一致性（FRC）测新层的有效分辨率。
  导出    游戏格式：godot/数据/sol0530/fine_*（反照率 RGBA8、分辨率 R8、细高度 RF、CDLOD 高度改正），scene.json 的 near_fine 段。
  全部    依次跑 正射 配准 融合 导出。

数据：NASA/JPL-Caltech（PDS Imaging Node：mars2020_navcam_ops_stereo、mars2020_navcam_ops_calibrated）。
"""
import importlib.util, json, math, os, re, sys, time, pathlib
import numpy as np

HERE = pathlib.Path(__file__).resolve().parent


def find_map():
    for p in (HERE, *HERE.parents):
        if (p/"资料"/"地面材质").is_dir() and (p/"godot").is_dir():
            return p
    raise SystemExit("找不到 地图/ 根目录（要有 资料/地面材质 和 godot/）")


MAP = find_map()
PDS = MAP/"资料"/"地面材质"/"PDS"
OUT = MAP/"资料"/"地面材质"/"近景细化"
GD = MAP/"godot"/"数据"/"sol0530"
_t0 = time.time()


def load_mod(name, fn):
    spec = importlib.util.spec_from_file_location(name, HERE/fn)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m


def log(*a):
    s = f"[{time.time() - _t0:7.1f} s] " + " ".join(str(x) for x in a)
    print(s, flush=True)
    OUT.mkdir(parents=True, exist_ok=True)
    with open(OUT/"日志.txt", "a", encoding="utf-8") as f:
        f.write(time.strftime("%m-%d %H:%M:%S ") + s + "\n")


# ── 下载 ─────────────────────────────────────────────────────────────────────────────────
SOLS = range(502, 535)
SITE_TAG = "N0261222"


def cmd_download(args):
    """站点 26/1222 的全部 Navcam 左眼 XYZ 帧（sol 502–534）。每帧：XYZ、RAS 左（标定包，取最新版本）；
    半分辨率帧（全景 NCAM02xxx–04xxx、NCAM00347）另加 UVW（小）。NCAM00215（全幅、近地平线）只要 XYZ + RAS，省 0.9 GB。"""
    D = load_mod("dl69", "69_地面材质下载.py")
    out = str(PDS)
    have = {p.name for p in PDS.glob("批1/sol*/*.IMG")}
    items = []
    for sol in SOLS:
        st, ca = D.nav_dir("stereo", sol), D.nav_dir("calibrated", sol)
        try:
            sf = D.listing(st)
        except Exception:                                                  # noqa: BLE001 —— 那天没有立体产品
            continue
        xyz = [f for f in sf if f.startswith("NLF_") and f[23:26] == "XYZ" and SITE_TAG in f and f.endswith(".IMG")]
        if not xyz: continue
        cf = D.listing(ca)
        frames = sorted({f[:23] for f in xyz})
        for fr in frames:
            pick = lambda fs, kind: (sorted(f for f in fs if f.startswith(fr) and f[23:26] == kind and f.endswith(".IMG")) or [None])[-1]
            fx, fr_ras = pick(sf, "XYZ"), pick(cf, "RAS")
            seq = re.search(r"NCAM\d{5}", fx).group()
            if fx in have: continue                                        # 批1 的工作区帧
            items.append((4, sol, st + fx))
            if fr_ras: items.append((4, sol, ca + fr_ras))
            if seq != "NCAM00215":
                fu = pick(sf, "UVW")
                if fu: items.append((4, sol, st + fu))
    items += [(b, s, u[:-4] + ".xml") for b, s, u in items if u.endswith(".IMG")]
    seen, uniq = set(), []
    for b, s, u in items:
        if u not in seen:
            seen.add(u); uniq.append({"批": b, "sol": s, "url": u, "本地": f"批4/sol{s:04d}/{os.path.basename(u)}"})
    (PDS/"清单_批4.json").write_text(json.dumps(uniq, ensure_ascii=False, indent=1))
    nimg = sum(u["url"].endswith(".IMG") for u in uniq)
    log(f"下载：批4 清单 {len(uniq)} 个文件（{nimg} 个 IMG，{len({u['本地'][:13] + os.path.basename(u['url'])[:23] for u in uniq})} 帧）→ 清单_批4.json")
    if "--只列" in args: return
    order = sorted(uniq, key=lambda it: (not it["url"].endswith(".xml"), it["sol"]))
    ok = bad = tot = 0
    for k, it in enumerate(order):
        dst = os.path.join(out, it["本地"]); name = os.path.basename(dst)
        if os.path.exists(dst + ".ok"):
            ok += 1; tot += os.path.getsize(dst); continue
        for _ in range(2):
            if not D.fetch(it["url"], dst):
                log(f"失败 {name}"); continue
            if name.endswith(".IMG"):
                want = D.label_md5(dst[:-4] + ".xml", name) if os.path.exists(dst[:-4] + ".xml") else None
                if want and D.md5_of(dst) != want:
                    log(f"md5 不符，重下 {name}"); os.remove(dst); continue
            open(dst + ".ok", "w").close(); break
        if os.path.exists(dst + ".ok"):
            ok += 1; tot += os.path.getsize(dst)
            if name.endswith(".IMG"): log(f"[{k + 1}/{len(order)}] sol {it['sol']} {name}（{os.path.getsize(dst)/1e6:.0f} MB）")
        else:
            bad += 1
    log(f"下载完成：成功 {ok}，失败 {bad}，共 {tot/1e9:.2f} GB")
    sys.exit(1 if bad else 0)


# ── 公共：读图、取样、谱 ──────────────────────────────────────────────────────────────────────
MAST_ENU = np.array([-0.875698, -0.255576, 2.03704])                     # 57 的 MAST（LOCAL_LEVEL 北东下）→ ENU
REF71 = MAP/"资料"/"地面材质"/"样块"


def srgb_to_lin(c):
    c = np.asarray(c, np.float32)
    return np.where(c <= 0.04045, c/12.92, ((c + 0.055)/1.055)**2.4).astype(np.float32)


def read_rgba_lin(path):
    """8 位 RGBA PNG（第 0 行在北，同 57 导出）→ 线性 RGB (H, W, 3)、alpha (H, W)。"""
    from PIL import Image
    Image.MAX_IMAGE_PIXELS = None
    a = np.asarray(Image.open(path).convert("RGBA")).astype(np.float32)/255.0
    return srgb_to_lin(a[..., :3]), a[..., 3]


def bilinear(img, r, c):
    """img (H, W[, C]) 在小数行列 (r, c) 处双线性取样（越界夹边）。"""
    H, W = img.shape[:2]
    r = np.clip(r, 0, H - 1.001); c = np.clip(c, 0, W - 1.001)
    r0 = np.floor(r).astype(np.int64); c0 = np.floor(c).astype(np.int64); fr = r - r0; fc = c - c0
    if img.ndim == 3: fr = fr[..., None]; fc = fc[..., None]
    return (img[r0, c0]*(1 - fr)*(1 - fc) + img[r0, c0 + 1]*(1 - fr)*fc + img[r0 + 1, c0]*fr*(1 - fc) + img[r0 + 1, c0 + 1]*fr*fc).astype(np.float32)


def sample_tex(img, half, X, Y):
    """游戏贴图（第 0 行在北，纹素中心在 (k + 0.5)·cs）在 ENU (X, Y) 处的双线性值，同 GPU 放大过滤。"""
    n = img.shape[0]; cs = 2*half/n
    return bilinear(img, (half - Y)/cs - 0.5, (X + half)/cs - 0.5)


def read_heights(path=None):
    """godot/数据/sol0530/heights.bin：头 int32 L、N，再 float32 L×N×N；第 k 层 H[k][j][i] ↔ ENU (−h + i·c, h − j·c)。"""
    path = path or GD/"heights.bin"
    b = np.fromfile(path, np.int32, 2); L, N = int(b[0]), int(b[1])
    return np.fromfile(path, np.float32, L*N*N, offset=8).reshape(L, N, N)


def sample_layer(H0, c, half, X, Y):
    return bilinear(H0, (half - Y)/c, (X + half)/c)


def grid71():
    return json.loads((REF71/"正射"/"格.json").read_text())


def band_edges(cs, lam_max=0.5):
    """按 1/4 倍频程的波长分档：2 cs … lam_max。"""
    lam = 2*cs*2**(np.arange(0, 40)/4.0); return lam[lam <= lam_max]


def xshift(a, b, rmax):
    """b 相对 a 的整格+亚格平移（互相关峰，二次曲面插值）。"""
    F = np.fft.fft2(a)*np.conj(np.fft.fft2(b))
    c = np.fft.fftshift(np.real(np.fft.ifft2(F))); cy, cx = c.shape[0]//2, c.shape[1]//2
    w = c[cy - rmax:cy + rmax + 1, cx - rmax:cx + rmax + 1]
    i, j = np.unravel_index(np.argmax(w), w.shape); i = min(max(i, 1), w.shape[0] - 2); j = min(max(j, 1), w.shape[1] - 2)
    sub = lambda m1, m0, p1: 0.0 if (m1 - 2*m0 + p1) == 0 else 0.5*(m1 - p1)/(m1 - 2*m0 + p1)
    return i + sub(w[i - 1, j], w[i, j], w[i + 1, j]) - rmax, j + sub(w[i, j - 1], w[i, j], w[i, j + 1]) - rmax


def cross_lam(lam, y, t=0.5):
    """从长波往短波走，第一次掉到 t 以下的波长（对数插值）；一直不掉 → 最短档；最长档就不到 → nan。"""
    y = np.nan_to_num(np.asarray(y, float), nan=-1)
    for k in range(len(lam) - 1, 0, -1):
        if y[k] >= t > y[k - 1]:
            u = (y[k] - t)/max(y[k] - y[k - 1], 1e-9)
            return float(lam[k]*(lam[k - 1]/lam[k])**u)
        if y[k] < t: break
    return float(lam[0]) if np.all(y >= t) else float("nan")


class Spectra:
    """分窗累加的径向谱：参考 a、被测 b → 传递函数 T(λ) = Re(S_ab)/S_aa、相干 γ²(λ) = |⟨S_ab⟩|²/(⟨S_aa⟩⟨S_bb⟩)。
    每窗：去平面、Hann 窗、b 按互相关对齐到 a（亚格，频域相位改正），只统计 a、b 都有值的窗。"""
    def __init__(self, cs, win, lam_max=0.5):
        self.cs, self.win = cs, win
        self.lam = band_edges(cs, min(lam_max, win*cs/2))
        f = np.fft.fftfreq(win, cs); FX, FY = np.meshgrid(f, f)
        fr = np.hypot(FX, FY); lam = 1/np.maximum(fr, 1e-9)
        self.bin = np.digitize(lam, self.lam*2**(1/8)) ; self.bin[fr == 0] = -1   # 档 k：λ ∈ [λk·2^-1/8, λk·2^1/8)
        self.FX, self.FY = FX, FY
        self.Saa = np.zeros(len(self.lam)); self.Sbb = np.zeros(len(self.lam)); self.Sab = np.zeros(len(self.lam), complex)
        self.n = 0; self.shifts = []
        self.hann = np.outer(np.hanning(win), np.hanning(win)).astype(np.float32)

    def add(self, a, b, register=True, rmax=12):
        """先求梯度（x、y 两个分量各算一遍谱再相加）：高度谱很红，直接加窗时低频泄漏会盖住高频，T 假高。
        梯度是线性算子，两边同乘 |f|²，传递函数和相干不变。"""
        n = self.win
        def prep(x):
            gy, gx = np.gradient(x.astype(np.float64))
            return [(g - g.mean())*self.hann for g in (gx, gy)]
        pa, pb = prep(a), prep(b)
        if register:
            di, dj = xshift(pa[0] + pa[1], pb[0] + pb[1], rmax)
            self.shifts.append((di*self.cs, dj*self.cs))
        m = self.bin >= 0; k = self.bin[m]; nb = len(self.lam)
        for xa, xb in zip(pa, pb):
            Fa, Fb = np.fft.fft2(xa), np.fft.fft2(xb)
            if register: Fb = Fb*np.exp(-2j*np.pi*(self.FY*di + self.FX*dj)*self.cs)   # b 往回移 (di, dj) 格
            cr = Fa*np.conj(Fb)
            self.Saa += np.bincount(k, (np.abs(Fa)**2)[m], nb)[:nb]
            self.Sbb += np.bincount(k, (np.abs(Fb)**2)[m], nb)[:nb]
            self.Sab += np.bincount(k, cr.real[m], nb)[:nb] + 1j*np.bincount(k, cr.imag[m], nb)[:nb]
        self.n += 1

    def result(self):
        with np.errstate(invalid="ignore", divide="ignore"):
            T = self.Sab.real/self.Saa; coh = np.abs(self.Sab)**2/(self.Saa*self.Sbb); P = self.Sbb/self.Saa
        cross = lambda y, t=0.5: cross_lam(self.lam, y, t)
        sh = np.array(self.shifts) if self.shifts else np.zeros((1, 2))
        return dict(n=self.n, lam_mm=(self.lam*1e3).round(2).tolist(), T=np.round(T, 3).tolist(), coh=np.round(coh, 3).tolist(),
                    power_ratio=np.round(P, 3).tolist(), lam50_T_mm=round(cross(T)*1e3, 1), lam50_coh_mm=round(cross(coh)*1e3, 1),
                    shift_med_mm=(np.median(sh, 0)*1e3).round(2).tolist(), shift_mad_mm=(np.median(np.abs(sh - np.median(sh, 0)), 0)*1e3).round(2).tolist())


def smooth_holes(x, m, sigmas=(3, 8, 24, 64)):
    """空洞（~m）用逐级放大的归一化高斯补平滑值；不引入高频。"""
    from scipy.ndimage import gaussian_filter
    y = np.where(m, x, 0).astype(np.float64); out = y.copy(); done = m.copy()
    for s_ in sigmas:
        w = gaussian_filter(m.astype(np.float64), s_); v = gaussian_filter(y, s_)
        fill = ~done & (w > 1e-3); out[fill] = v[fill]/w[fill]; done |= fill
        if done.all(): break
    out[~done] = np.median(x[m]) if m.any() else 0.0
    return out


def windows(ok, win, step):
    ny, nx = ok.shape
    for a0 in range(0, ny - win + 1, step):
        for b0 in range(0, nx - win + 1, step):
            yield (slice(a0, a0 + win), slice(b0, b0 + win))


# ── 测量（现状）──────────────────────────────────────────────────────────────────────────────
def cmd_measure(args):
    """71 的 2 mm 正射（9 帧基线反照率 A、跨帧中值高度 H）作参考，量现有近层、中层反照率和 CDLOD 第 0 层高度的有效分辨率。"""
    from scipy.ndimage import gaussian_filter
    od = OUT/"测量"; od.mkdir(parents=True, exist_ok=True)
    g = grid71(); cs = g["cs"]; nx, ny = g["nx"], g["ny"]
    Xg = g["x0"] + (np.arange(nx) + 0.5)*cs; Yg = g["y0"] + (np.arange(ny) + 0.5)*cs
    X, Y = np.meshgrid(Xg, Yg)                                            # 第 0 行在南
    B = np.load(REF71/"分离"/"基线.npz")
    Aref = B["A"].mean(0); Href = B["H"]; nH = B["nH"]
    okref = np.isfinite(Aref) & (Aref > 0) & np.isfinite(Href) & (nH >= 5)
    Lref = np.log(np.where(okref, Aref, 1.0))
    T = json.loads((GD/"scene.json").read_text())["tex"]
    near, an = read_rgba_lin(GD/"albedo_near.png"); mid, am = read_rgba_lin(GD/"albedo_mid.png")
    Ln = np.log(np.maximum(sample_tex(near, T["albedo_near"]["half"], X, Y).mean(-1), 1e-5))
    An = sample_tex(an, T["albedo_near"]["half"], X, Y)
    Lm = np.log(np.maximum(sample_tex(mid, T["albedo_mid"]["half"], X, Y).mean(-1), 1e-5))
    Am = sample_tex(am, T["albedo_mid"]["half"], X, Y)
    del near, mid
    HL = read_heights(); H0 = sample_layer(HL[0], 0.02, 6.0, X, Y)
    TR = np.load(MAP/"DEM"/"Blender缓存"/"_素材"/"PDS"/"站26_1222"/"重建"/"地形.npz")
    Hraw = sample_layer(TR["near"].astype(np.float32)[::-1], 0.02, 10.0 - 0.01, X, Y)  # 57 融合后、去噪前（第 0 行在南 → 翻成北在上；格心 ±(10 − 0.01)）
    dist = np.hypot(X - MAST_ENU[0], Y - MAST_ENU[1])
    win, step = 256, 160
    groups = [("2.5–3.5 m", 2.5, 3.5), ("3.5–4.5 m", 3.5, 4.5), ("4.5–5.5 m", 4.5, 5.5), ("全部", 0, 99)]
    res = {}
    for name, ref, test, okt in (("反照率_近", Lref, Ln, An > 0.99), ("反照率_中", Lref, Lm, Am > 0.99),
                                 ("高度_CDLOD第0层", Href, H0, np.isfinite(H0)), ("高度_57融合未去噪", Href, Hraw, np.isfinite(Hraw))):
        res[name] = {}
        for gname, d0, d1 in groups:
            S = Spectra(cs, win)
            for sl in windows(okref, win, step):
                m = okref[sl] & okt[sl]
                if m.mean() < 0.97 or not (d0 <= np.median(dist[sl]) < d1): continue
                a = smooth_holes(ref[sl], m); b = test[sl]                     # 参考的空洞用平滑插值补（两边补同一个常数会造出共同的台阶，假相干）
                S.add(a, b)
            if S.n: res[name][gname] = S.result()
        r = res[name].get("全部", {})
        log(f"测量 {name}：{r.get('n', 0)} 窗，T=0.5 处波长 {r.get('lam50_T_mm')} mm，相干 0.5 处 {r.get('lam50_coh_mm')} mm，"
            f"对齐位移 中值 {r.get('shift_med_mm')} mm；分距离 " +
            "，".join(f"{k} {v['lam50_T_mm']}/{v['lam50_coh_mm']} mm" for k, v in res[name].items() if k != "全部"))
    # 片元法线：CDLOD 第 0 层、中心差分步长 2 cm → 再乘 sin(2πfe)/(2πfe)
    r = res["高度_CDLOD第0层"]["全部"]; lam = np.array(r["lam_mm"])/1e3; e = 0.02
    sinc = np.sin(2*np.pi*e/lam)/(2*np.pi*e/lam)
    Tn = np.array(r["T"])*np.where(lam > 2*e, sinc, 0)
    res["法线_片元"] = dict(lam_mm=r["lam_mm"], T=np.round(Tn, 3).tolist(),
                          lam50_T_mm=round(cross_lam(lam, Tn)*1e3, 1))
    log(f"测量 片元法线（第 0 层 + 2 cm 中心差分）：T=0.5 处波长 {res['法线_片元']['lam50_T_mm']} mm")
    # 参考自身：高度功率谱的噪声底（谱斜率变平处）、反照率谱
    (od/"测量.json").write_text(json.dumps(res, ensure_ascii=False, indent=1))
    plot_measure(res, od)
    crops_measure(od, X, Y, Aref, Href, okref, Ln, Lm, H0, B)


def plot_measure(res, od, extra=None):
    import matplotlib; matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    plt.rcParams["font.sans-serif"] = ["Noto Sans CJK SC", "Noto Sans SC", "WenQuanYi Zen Hei", "DejaVu Sans"]
    fig, ax = plt.subplots(1, 2, figsize=(12, 4.2), dpi=110)
    sets = dict(res); sets.update(extra or {})
    for name, d in sets.items():
        r = d.get("全部", d)
        if "T" not in r: continue
        ls = "--" if "法线" in name else "-"
        ax[0].semilogx(r["lam_mm"], r["T"], ls, label=f"{name}（{r.get('lam50_T_mm')} mm）")
        if "coh" in r: ax[1].semilogx(r["lam_mm"], r["coh"], ls, label=name)
    for a, t in zip(ax, ("传递函数 T(λ) = Re(S_ab)/S_aa", "相干 γ²(λ)")):
        a.axhline(0.5, color="gray", lw=0.6); a.set_xlabel("波长 mm"); a.set_title(t); a.set_ylim(-0.05, 1.1); a.grid(alpha=0.3); a.legend(fontsize=7)
    fig.tight_layout(); fig.savefig(od/"传递函数.png"); plt.close(fig)


def crops_measure(od, X, Y, Aref, Href, okref, Ln, Lm, H0, B):
    """同一块 50 cm 地：参考（71，2 mm）/ 近层 1 cm / 中层 2 cm 的反照率，参考高度 / CDLOD 第 0 层的晕渲。"""
    from PIL import Image
    g = grid71(); cs = g["cs"]
    out = []
    for (cx, cy) in ((-2.3, -0.6), (-3.2, -1.7), (-4.3, -3.2)):
        j = int((cx - g["x0"])/cs); i = int((cy - g["y0"])/cs); s = (slice(i - 125, i + 125), slice(j - 125, j + 125))
        La = np.log(np.maximum(Aref[s], 1e-6)); lo, hi = np.nanpercentile(La[okref[s]], [1, 99])
        n = lambda x: np.clip((x - lo)/(hi - lo), 0, 1)
        sh = lambda h: hill(h, cs)
        row = [n(La), n(Ln[s] - np.nanmedian(Ln[s]) + np.nanmedian(La)), n(Lm[s] - np.nanmedian(Lm[s]) + np.nanmedian(La)), sh(Href[s]), sh(H0[s])]
        out.append(np.concatenate([np.pad(np.nan_to_num(r)[::-1], 3, constant_values=1) for r in row], 1))
    img = np.concatenate(out, 0)
    Image.fromarray((img*255).astype(np.uint8)).resize((img.shape[1]*2, img.shape[0]*2), Image.NEAREST).save(od/"对比_现状.png")


def hill(h, cs, az=225.0, el=25.0):
    h = np.nan_to_num(h, nan=np.nanmedian(h))
    gy, gx = np.gradient(h, cs)
    a, e = math.radians(az), math.radians(el); s = np.array([math.cos(e)*math.sin(a), math.cos(e)*math.cos(a), math.sin(e)])
    n = np.stack([-gx, -gy, np.ones_like(gx)]); n /= np.linalg.norm(n, axis=0)
    return np.clip(np.tensordot(s, n, 1)/s[2]*0.5, 0, 1)


# ── 正射 ─────────────────────────────────────────────────────────────────────────────────
FINE = dict(cs=0.004, n=4096)                                            # 细层：4 mm、±8.192 m（以导航点为心）
FINE["half"] = FINE["cs"]*FINE["n"]/2
R_MAX = 9.0                                                             # 离桅杆水平距离上限（m）
_M71 = _M57 = None


def m71():
    global _M71
    if _M71 is None: _M71 = load_mod("m71", "71_地面样块.py")
    return _M71


def m57():
    global _M57
    if _M57 is None: _M57 = load_mod("m57", "../Blender/57_实景重建.py")
    return _M57


def all_frames():
    """批1（工作区全分辨率）+ 批4（全景、NCAM00215、NCAM00347）的左眼帧。"""
    out = []
    for xyz in sorted(PDS.glob("批[14]/sol*/NLF_*XYZ_*.IMG")):
        key = xyz.name[:23]; d = xyz.parent
        pick = lambda pat: (sorted(d.glob(pat)) or [None])[-1]
        out.append(dict(xyz=xyz, ras=pick(f"{key}RAS_*.IMG"), uvw=pick(f"{key}UVW_*.IMG"),
                        seq=re.search(r"NCAM\d{5}", xyz.name).group(), sol=int(key[4:8]), batch=d.parent.name))
    return out


def frame_kind(seq):
    return {"NCAM00712": "工作区全幅", "NCAM00708": "工作区全幅", "NCAM00709": "工作区全幅", "NCAM00215": "前方全幅",
            "NCAM00347": "工作区半幅"}.get(seq, "到站全景半幅")


def rover_body_mask(E, N, U):
    """点在车体盒（57 ROVER_BOXES_TIGHT + 桅杆、六轮）里，或在车身投影下且高出地面 > 15 cm（相机拍到的车体）。"""
    M = m57()
    Q = (np.stack([E, N, U], -1).astype(np.float64) @ M.M_SB) @ M.rover_R()   # ENU → 北东下 → 车体系
    x, y, z = Q[..., 0], Q[..., 1], -Q[..., 2]
    hit = np.zeros(E.shape, bool)
    for (xa, xb), (ya, yb), (za, zb) in list(M.ROVER_BOXES_TIGHT) + [((0.70, 1.00), (0.35, 0.75), (1.25, 2.25))]:
        hit |= (x > xa - 0.03) & (x < xb + 0.03) & (y > ya - 0.03) & (y < yb + 0.03) & (z > za - 0.03) & (z < zb + 0.03)
    under = (x > -1.85) & (x < 2.5) & (np.abs(y) < 1.45)
    for x0 in (-1.05, 0.0, 1.05):                                        # 六个轮子
        for sy in (-1, 1): hit |= (np.abs(x - x0) < 0.32) & (np.abs(y - sy*1.15) < 0.25) & (z < 0.6)
    return hit | (under & (z > 0.15))


def pyramid(img, levels=4):
    """(C, H, W)，NaN 为空 → 逐级 2×2 平均（NaN 不参与）。"""
    out = [img]
    for _ in range(levels):
        a = out[-1]; C, H, W = a.shape; a = a[:, :H//2*2, :W//2*2]
        m = np.isfinite(a); v = np.where(m, a, 0).reshape(C, H//2, 2, W//2, 2).sum((2, 4)); c = m.reshape(C, H//2, 2, W//2, 2).sum((2, 4))
        with np.errstate(invalid="ignore", divide="ignore"): out.append((v/c).astype(np.float32))
    return out


def sample_img(img, u, v):
    """(C, H, W) 在像素坐标 (u = 列, v = 行；像素中心 = 整数) 双线性取样；四邻有 NaN → NaN。"""
    C, H, W = img.shape
    ok = np.isfinite(u) & np.isfinite(v) & (u >= 0) & (v >= 0) & (u < W - 1) & (v < H - 1)
    out = np.full((C, len(u)), np.nan, np.float32)
    u0 = np.floor(u[ok]).astype(np.int64); v0 = np.floor(v[ok]).astype(np.int64); fu = (u[ok] - u0).astype(np.float32); fv = (v[ok] - v0).astype(np.float32)
    for c in range(C):
        a = img[c]
        out[c, ok] = a[v0, u0]*(1 - fu)*(1 - fv) + a[v0, u0 + 1]*fu*(1 - fv) + a[v0 + 1, u0]*(1 - fu)*fv + a[v0 + 1, u0 + 1]*fu*fv
    return out


def ortho_frame(fr):
    """一帧 → 细格，正向溅射：每个像素四边形按自己的足迹在像面里双线性加密 k×k 倍（k 让子样点距 ≤ 格距/1.5），
    子样点按水平位置落格求平均（近处像素比格小 → 一格多个像素，等于盒式预滤波；远处 → 加密后不漏格）。
    跨深度跳变的四边形（石块背后）不加密、不连，留成真遮挡空洞。每格同时记像素足迹（点距几何平均、长轴）和视距。
    （先试过逐格反投影迭代：掠射时迭代增益 > 1，粗糙地面上不收敛，空洞很多。）"""
    M71 = m71(); t0 = time.time()
    cs, n, half = FINE["cs"], FINE["n"], FINE["half"]
    P, lab = M71.read_img(str(fr["xyz"]))
    meta = M71.label_meta(lab)
    tag = f"{meta['sol']:04d}_{meta['ltst'].replace(':', '')[:6]}_{fr['seq'][-5:]}"
    meta.update(tag=tag, xyz=fr["xyz"].name, seq=fr["seq"], kind=frame_kind(fr["seq"]), shape=list(P.shape[1:]))
    off = np.array(meta["rover_off"])
    valid = np.any(P != 0, axis=0)
    E = (P[1] - off[1]).astype(np.float32); N = (P[0] - off[0]).astype(np.float32); U = (-(P[2] - off[2])).astype(np.float32)
    cam = M71.camera_site(lab)
    C_enu = M71.M_SE @ (cam["C"] - off); meta["cam_C_enu"] = C_enu.tolist()
    rh = np.hypot(E - MAST_ENU[0], N - MAST_ENU[1])
    body = rover_body_mask(E, N, U) & valid
    meta["body_frac"] = float(body.mean())
    rr_, cc_ = np.nonzero(valid & ~body)
    if len(rr_):
        k = np.random.default_rng(0).choice(len(rr_), min(20000, len(rr_)), replace=False)
        xs, ys, _ = M71.cahvor(cam, P[:, rr_[k], cc_[k]].T.astype(np.float64))
        meta["proj_err_px"] = float(np.median(np.hypot(xs - cc_[k], ys - rr_[k])))
    del P
    valid &= ~body & (rh < R_MAX) & (np.abs(E) < half - 2*cs) & (np.abs(N) < half - 2*cs)
    if valid.sum() < 1000:
        log(f"正射 {tag}：{R_MAX:.0f} m 内没有地面点（{meta['kind']}），跳过"); return None
    rng = np.sqrt((E - C_enu[0])**2 + (N - C_enu[1])**2 + (U - C_enu[2])**2).astype(np.float32)
    # 每像素角、像素足迹（相邻点水平距离）
    def nb(a, ax):                                                       # a[+1] − a，末行/列 NaN
        d = np.full(a.shape, np.nan, np.float32)
        if ax == 1: d[:, :-1] = a[:, 1:] - a[:, :-1]
        else: d[:-1] = a[1:] - a[:-1]
        return d
    dEc, dNc, dUc = nb(E, 1), nb(N, 1), nb(U, 1); dEr, dNr = nb(E, 0), nb(N, 0)
    vv = valid & np.roll(valid, -1, 1) & np.roll(valid, -1, 0)
    ifov = float(np.nanmedian((np.sqrt(dEc**2 + dNc**2 + dUc**2)/rng)[vv]))
    meta["ifov_mrad"] = ifov*1e3
    dc = np.hypot(dEc, dNc); dr = np.hypot(dEr, dNr); del dEc, dNc, dUc, dEr, dNr
    hcam = np.maximum(C_enu[2] - U, 0.3)
    expect = ifov*rng*np.maximum(rng/hcam, 1.0)                          # 平地上沿视线的点距
    jump = lambda d: ~(d < 4*expect + 0.005)
    dc[jump(dc)] = np.nan; dr[jump(dr)] = np.nan
    foot = np.sqrt(dc*dr).astype(np.float32); flong = np.fmax(dc, dr).astype(np.float32)
    quad = vv & np.isfinite(dc) & np.isfinite(dr) & np.roll(np.isfinite(dc), -1, 0) & np.roll(np.isfinite(dr), -1, 1)   # 四个角都有效、四条边都不跳
    del dc, dr, expect, hcam
    ras, labR = M71.read_img(str(fr["ras"])); sR, oR = M71.rad_scale(labR)
    rgb = (ras.astype(np.float32)*sR + oR); good_px = np.nan_to_num(ras).min(0) > 0
    del ras
    valid &= good_px; quad &= valid & np.roll(valid, -1, 1) & np.roll(valid, -1, 0) & np.roll(np.roll(valid, -1, 0), -1, 1)
    # 累加器（整张细格太大：先按有效点外包框开）
    ii_all = np.floor((N[valid] + half)/cs).astype(np.int64); jj_all = np.floor((E[valid] + half)/cs).astype(np.int64)
    i0, i1, j0, j1 = int(ii_all.min()) - 1, int(ii_all.max()) + 2, int(jj_all.min()) - 1, int(jj_all.max()) + 2
    del ii_all, jj_all
    ny, nx = i1 - i0, j1 - j0
    acc = np.zeros((9, ny*nx), np.float64)                               # cnt, h, r, g, b, foot, flong, rng, h²
    chans = [U, rgb[0], rgb[1], rgb[2], foot, flong, rng]
    def splat(vals, Ev, Nv):
        ii = np.floor((Nv + half)/cs).astype(np.int64) - i0; jj = np.floor((Ev + half)/cs).astype(np.int64) - j0
        idx = ii*nx + jj
        acc[0] += np.bincount(idx, minlength=ny*nx)
        for c, v in enumerate(vals): acc[1 + c] += np.bincount(idx, v, ny*nx)
        acc[8] += np.bincount(idx, vals[0].astype(np.float64)**2, ny*nx)
    H, W = E.shape
    fl90 = np.nanpercentile(np.where(quad, flong, np.nan), 90, axis=1)   # 每行足迹长轴的 90 百分位
    kk = np.clip(np.ceil(1.5*np.nan_to_num(fl90, nan=0)/cs), 1, 8).astype(int)
    r = 0; nsub = 0
    while r < H - 1:
        k = int(kk[r]); rows = max(1, min(256, int(4e6/(W*k*k))))
        r1 = min(H - 1, r + rows)
        while r1 > r + 1 and kk[r:r1].max() > k: r1 -= 1              # 一段内 k 相同
        q = quad[r:r1, :-1]
        if q.any():
            qi, qj = np.nonzero(q); qi = qi + r
            for a in range(k):
                fa = np.float32((a + 0.5)/k)
                for b in range(k):
                    fb = np.float32((b + 0.5)/k)
                    w00, w01, w10, w11 = (1 - fa)*(1 - fb), (1 - fa)*fb, fa*(1 - fb), fa*fb
                    bil = lambda X: X[qi, qj]*w00 + X[qi, qj + 1]*w01 + X[qi + 1, qj]*w10 + X[qi + 1, qj + 1]*w11
                    splat([bil(X) for X in chans], bil(E), bil(N)); nsub += len(qi)
        r = r1
    with np.errstate(invalid="ignore", divide="ignore"):
        cnt = acc[0]; mean = acc[1:8]/cnt
        hstd = np.sqrt(np.maximum(acc[8]/cnt - mean[0]**2, 0))
    ok = (cnt > 0).reshape(ny, nx)
    F = lambda a, dt=np.float32: np.where(ok, a.reshape(ny, nx), np.nan).astype(dt)
    out = dict(h=F(mean[0]), rgb=np.stack([F(mean[1 + c]) for c in range(3)]), foot=F(mean[4], np.float16), flong=F(mean[5], np.float16),
               rng=F(mean[6], np.float16), hstd=F(hstd, np.float16), ok=ok)
    meta.update(bbox=[i0, i1, j0, j1], valid_cells=int(ok.sum()), foot_med_mm=float(np.nanmedian(out["foot"][ok].astype(np.float32))*1e3),
                area_m2=float(ok.sum()*cs*cs), subsamples=int(nsub), k_max=int(kk.max()), seconds=time.time() - t0)
    od = OUT/"正射"; od.mkdir(parents=True, exist_ok=True)
    np.savez(od/f"{tag}.npz", **out, meta=json.dumps(meta, ensure_ascii=False))
    log(f"正射 {tag}（{meta['kind']}，{meta['shape'][1]}×{meta['shape'][0]}，LTST {meta['ltst']}，太阳 {meta['sun_az']:.0f}°/{meta['sun_el']:.0f}°）："
        f"{meta['area_m2']:.1f} m²，足迹中值 {meta['foot_med_mm']:.1f} mm，每像素 {meta['ifov_mrad']:.3f} mrad，投影自检 {meta.get('proj_err_px', float('nan')):.2f} px，"
        f"车体点 {meta['body_frac']*100:.1f}%，加密最多 {meta['k_max']}×，{meta['seconds']:.0f} s")
    return meta


def _scatter(vals, iv, jv, ok, ny, nx, fill, dt):
    a = np.full((ny, nx), fill, dt); a[iv[ok], jv[ok]] = np.asarray(vals)[ok]; return a


def _ortho_job(fr):
    try:
        return ortho_frame(fr)
    except Exception as e:                                                 # noqa: BLE001
        import traceback; log(f"正射 失败 {fr['xyz'].name}：{e}\n{traceback.format_exc()}"); return None


def cmd_ortho(args):
    from multiprocessing import Pool
    procs = int(next((a.split("=")[1] for a in args if a.startswith("--进程=")), "4"))
    only = next((a.split("=")[1] for a in args if a.startswith("--只=")), None)
    frs = [f for f in all_frames() if f["ras"] is not None and (only is None or only in f["xyz"].name)]
    log(f"正射：{len(frs)} 帧，细格 {FINE['n']}² × {FINE['cs']*1e3:.0f} mm（±{FINE['half']:.3f} m），{procs} 进程")
    with Pool(procs) as p:
        metas = [m for m in p.map(_ortho_job, frs, chunksize=1) if m]
    old = json.loads((OUT/"正射"/"帧.json").read_text()) if (OUT/"正射"/"帧.json").exists() and only else {}
    (OUT/"正射"/"帧.json").write_text(json.dumps(old | {m["tag"]: m for m in metas}, ensure_ascii=False, indent=1))


def load_ortho(tag):
    D = np.load(OUT/"正射"/f"{tag}.npz"); meta = json.loads(str(D["meta"]))
    d = {k: D[k] for k in ("h", "rgb", "foot", "flong", "rng", "hstd", "ok")}; d["meta"] = meta
    return d


# ── 配准 ─────────────────────────────────────────────────────────────────────────────────
REF_TAG = "0531_120154_00712"                                           # 同 71 的参考帧（sol 531 正午）


def frames_meta():
    return json.loads((OUT/"正射"/"帧.json").read_text())


def coarse_ok(tag, f=16):
    D = np.load(OUT/"正射"/f"{tag}.npz"); meta = json.loads(str(D["meta"])); ok = D["ok"]
    i0, i1, j0, j1 = meta["bbox"]; n = FINE["n"]//f
    out = np.zeros((n, n), bool)
    ii, jj = np.nonzero(ok[::f, ::f]); out[(i0 + ii*f)//f, (j0 + jj*f)//f] = True
    return out


def plane_fit(dz, I, J, cs):
    A = np.c_[np.ones(len(dz)), J*cs, I*cs]
    k = slice(None, None, max(1, len(dz)//200000))
    return np.linalg.lstsq(A[k], dz[k], rcond=None)[0]


def tile_shifts(A, B, m, T=200, step=100, band=(1.0, 6.0), rmax=16, pk_min=0.3):
    """分块互相关（同 71 tile_shifts，搜索半径可调）：返回 [(块心 i, j, s_i, s_j, 峰)]，s = B 相对 A 的内容位移（格）。"""
    M71 = m71(); out = []
    ny, nx = A.shape; win = np.outer(np.hanning(T), np.hanning(T))
    for a0 in range(0, ny - T + 1, step):
        for b0 in range(0, nx - T + 1, step):
            sl = (slice(a0, a0 + T), slice(b0, b0 + T)); mm = m[sl]
            if mm.mean() < 0.5: continue
            w = win*mm
            di, dj, pk = M71.xcorr_shift(M71._bp(A[sl], *band)*w, M71._bp(B[sl], *band)*w, rmax=rmax)
            if not pk >= pk_min or max(abs(di), abs(dj)) >= rmax - 1: continue
            out.append((a0 + T/2, b0 + T/2, -di, -dj, pk))
    return np.array(out)


def hp_lum(rgb, ok, s=12):
    """log 亮度减去 σ s 格的局部均值：去掉逐帧增益和大尺度明暗，只留纹理（配准用）。"""
    L = np.log(np.maximum(np.nanmean(rgb, 0), 1e-12)); L[~ok] = np.nan
    lo, _ = nan_gauss_(L, ok, s)
    return np.where(ok, L - lo, np.nan).astype(np.float32)


def nan_gauss_(x, m, s):
    from scipy.ndimage import gaussian_filter
    w = gaussian_filter(m.astype(np.float32), s); v = gaussian_filter(np.where(m, x, 0).astype(np.float32), s)
    with np.errstate(invalid="ignore", divide="ignore"): return v/w, w


FIELD_SIGMA = 0.4                                                       # 残差场的高斯插值尺度（m）


def warp_field(arr, corr):
    """仿射 + 平滑残差场：在 (i + s_i, j + s_j) 处双线性取样。残差场 = 各块残差的归一化高斯插值（σ 0.4 m），
    没块的地方退回仿射（权重按块密度渐变）。指向误差投到掠射的地面上不是仿射（随距离变），只用仿射远处会留 7–10 mm。"""
    from scipy.ndimage import map_coordinates, gaussian_filter
    ny, nx = arr.shape[-2:]; cs = FINE["cs"]
    ci, cj = np.array(corr.get("ci", [0, 0, 0])), np.array(corr.get("cj", [0, 0, 0]))
    if not (np.any(ci) or np.any(cj)): return arr
    f = 8; gy, gx = (ny + f - 1)//f, (nx + f - 1)//f                    # 粗格上算场，再放大
    I, J = np.mgrid[0:gy, 0:gx].astype(np.float32)*f
    si = ci[0] + ci[1]*I + ci[2]*J; sj = cj[0] + cj[1]*I + cj[2]*J
    if corr.get("tiles_res"):
        T = np.array(corr["tiles_res"]); ii = np.clip((T[:, 0]/f).astype(int), 0, gy - 1); jj = np.clip((T[:, 1]/f).astype(int), 0, gx - 1)
        acc = np.zeros((3, gy, gx), np.float32)
        np.add.at(acc[0], (ii, jj), 1); np.add.at(acc[1], (ii, jj), T[:, 2]); np.add.at(acc[2], (ii, jj), T[:, 3])
        s_ = FIELD_SIGMA/(cs*f)
        w = gaussian_filter(acc[0], s_); vi = gaussian_filter(acc[1], s_); vj = gaussian_filter(acc[2], s_)
        wmax = gaussian_filter(np.ones_like(acc[0]), s_)*0 + w.max()
        a = np.clip(w/(0.15*wmax + 1e-9), 0, 1)                          # 块稀处渐退到仿射
        with np.errstate(invalid="ignore", divide="ignore"):
            si = si + a*np.nan_to_num(vi/w); sj = sj + a*np.nan_to_num(vj/w)
    from scipy.ndimage import zoom
    SI = zoom(si, (ny/gy, nx/gx), order=1)[:ny, :nx]; SJ = zoom(sj, (ny/gy, nx/gx), order=1)[:ny, :nx]
    Ii, Jj = np.mgrid[0:ny, 0:nx].astype(np.float32)
    co = np.stack([Ii + SI, Jj + SJ])
    if arr.ndim == 3: return np.stack([map_coordinates(x, co, order=1, mode="constant", cval=np.nan) for x in arr])
    return map_coordinates(arr, co, order=1, mode="constant", cval=np.nan)


def cmd_register(args):
    """各帧对「已配准帧的拼图」做分块互相关（0.8 m 块）→ 仿射位移场；高度差拟合平面（偏移 + 倾斜）。同 71，不同处：
    - 水平用 log 亮度纹理（去 5 cm 局部均值，4–24 mm 带通）：全部帧都在 11:43–16:00、太阳方位差多在 20° 内，亮度峰比远处
      高度峰尖得多（8 m 处单帧立体高度噪声 ~1 cm）。光照差最大的几帧（sol 509/516/520 下午、521 清晨）明暗随太阳移动约 1–3 mm。
    - 搜索 ±16 格（±64 mm）：sol 530 前方帧相对工作区帧有 2–4 cm 的指向差（桅杆指向知识误差，6 m 外 0.2° ≈ 2 cm）。
    - 位移大小只在有块的地方量（71 在外包框角上外推，会把仿射的小斜率放大成假的大位移）。
    从参考帧开始，每次挑与拼图重叠最多的帧；没重叠的帧不改。"""
    M71 = m71(); cs, n = FINE["cs"], FINE["n"]
    metas = frames_meta()
    Lm = np.full((n, n), np.nan, np.float32); Hm = np.full((n, n), np.nan, np.float32)
    def put(tag, L, h):
        i0, i1, j0, j1 = metas[tag]["bbox"]
        for M_, v in ((Lm, L), (Hm, h)):
            cur = M_[i0:i1, j0:j1]; M_[i0:i1, j0:j1] = np.where(np.isfinite(cur), cur, v)
    D = load_ortho(REF_TAG); okR = D["ok"]
    put(REF_TAG, hp_lum(D["rgb"], okR), np.where(okR, D["h"], np.nan))
    res = {REF_TAG: dict(ci=[0.0]*3, cj=[0.0]*3, dz=[0.0]*3, 方法="参考")}
    cok = {t: coarse_ok(t) for t in metas}; mos = cok[REF_TAG].copy()
    todo = [t for t in metas if t != REF_TAG]
    while todo:
        ov = {t: int((cok[t] & mos).sum()) for t in todo}
        t = max(todo, key=lambda x: ov[x]); todo.remove(t)
        D = load_ortho(t); i0, i1, j0, j1 = metas[t]["bbox"]; ok = D["ok"]
        h = np.where(ok, D["h"], np.nan).astype(np.float32); L = hp_lum(D["rgb"], ok)
        LR, hR = Lm[i0:i1, j0:j1], Hm[i0:i1, j0:j1]
        m = np.isfinite(L) & np.isfinite(LR)
        corr = dict(ci=[0.0]*3, cj=[0.0]*3, dz=[0.0]*3, 方法="无重叠")
        if m.sum() > 20000:
            S = tile_shifts(LR, L, m)
            how = "亮度"
            if len(S) < 4:
                S = tile_shifts(hR, h, np.isfinite(h) & np.isfinite(hR), band=(1.5, 10)); how = "高度"
            mag = lambda ci, cj: np.hypot(ci[0] + ci[1]*S[:, 0] + ci[2]*S[:, 1], cj[0] + cj[1]*S[:, 0] + cj[2]*S[:, 1])*cs
            if len(S) >= 8:
                ci, cj, rms, nk = M71.fit_affine(S)
                ri = S[:, 2] - (ci[0] + ci[1]*S[:, 0] + ci[2]*S[:, 1]); rj = S[:, 3] - (cj[0] + cj[1]*S[:, 0] + cj[2]*S[:, 1])
                rr = np.hypot(ri, rj); k_ = rr <= 3*1.4826*np.median(rr) + 0.25                 # 剔离群块，留下的做平滑残差场
                corr.update(ci=ci.tolist(), cj=cj.tolist(), tiles_res=np.c_[S[k_, :2], ri[k_], rj[k_]].round(3).tolist(),
                            方法=f"{how}仿射+残差场（{int(k_.sum())}/{len(S)} 块，仿射残差 {rms*cs*1e3:.2f} mm，峰 {np.median(S[:, 4]):.2f}）")
            elif len(S) >= 2:
                ci, cj = [float(np.median(S[:, 2])), 0.0, 0.0], [float(np.median(S[:, 3])), 0.0, 0.0]
                corr.update(ci=ci, cj=cj, 方法=f"{how}平移（{len(S)} 块）")
            if len(S) >= 2:
                corr["shift_med_mm"] = float(np.median(mag(corr["ci"], corr["cj"]))*1e3); corr["shift_max_mm"] = float(mag(corr["ci"], corr["cj"]).max()*1e3)
                corr["raw_shift_med_mm"] = float(np.median(np.hypot(S[:, 2], S[:, 3]))*cs*1e3)
            h2 = warp_field(h, corr); m2 = np.isfinite(h2) & np.isfinite(hR)
            if m2.sum() > 5000:
                I, J = np.nonzero(m2); dz = (h2 - hR)[m2]
                c = plane_fit(dz, I, J, cs); corr["dz"] = c.tolist()
                r = dz - (c[0] + c[1]*J*cs + c[2]*I*cs)
                corr.update(dz_med_mm=float(np.median(dz)*1e3), resid_mad_mm=float(np.median(np.abs(r - np.median(r)))*1e3))
                h = h2 - (c[0] + c[1]*np.arange(j1 - j0)[None]*cs + c[2]*np.arange(i1 - i0)[:, None]*cs)
            else:
                h = h2
            L = warp_field(L, corr); corr.update(overlap_cells=int(m.sum()), tiles=int(len(S)))
            if "tiles_res" in corr:                                         # 改正后再量一次（同一方法）
                S2 = tile_shifts(LR, L, np.isfinite(L) & np.isfinite(LR))
                if len(S2): corr["after_med_mm"] = float(np.median(np.hypot(S2[:, 2], S2[:, 3]))*cs*1e3)
        res[t] = corr; put(t, L, h); mos |= cok[t]
        log(f"配准 {t}：{corr['方法']}，重叠 {corr.get('overlap_cells', 0)*cs*cs:.1f} m²，位移 中值 {corr.get('shift_med_mm', 0):.1f} / 最大 {corr.get('shift_max_mm', 0):.1f} mm，"
            f"高度偏移 {corr.get('dz_med_mm', 0):+.1f} mm，残差 MAD {corr.get('resid_mad_mm', float('nan')):.1f} mm；改正后再量 {corr.get('after_med_mm', float('nan')):.2f} mm")
    (OUT/"正射"/"配准.json").write_text(json.dumps(res, ensure_ascii=False, indent=1))


def load_aligned(tag, corr):
    """正射 + 配准改正（仿射位移、减高度平面）。返回 bbox 内的数组（float32）。"""
    M71 = m71(); cs = FINE["cs"]
    D = load_ortho(tag); c = corr.get(tag, {})
    h = np.where(D["ok"], D["h"], np.nan).astype(np.float32)
    rgb = D["rgb"].astype(np.float32); ext = np.stack([D["foot"], D["flong"], D["rng"]]).astype(np.float32)
    if c and (any(c["ci"]) or any(c["cj"])):
        h = warp_field(h, c); rgb = warp_field(rgb, c); ext = warp_field(ext, c)
    if c:
        ny, nx = h.shape
        h = h - (c["dz"][0] + c["dz"][1]*np.arange(nx)[None]*cs + c["dz"][2]*np.arange(ny)[:, None]*cs)
    ok = np.isfinite(h) & np.all(np.isfinite(rgb), 0) & np.all(np.isfinite(ext), 0)
    return dict(h=h, rgb=rgb, foot=ext[0], flong=ext[1], rng=ext[2], ok=ok, meta=D["meta"])


# ── 融合 ─────────────────────────────────────────────────────────────────────────────────
def horizon_tan(Hf, az, dmax, cs, device=None):
    """沿方位 az（从北顺时针）看，每格 dmax 米内的最大仰角正切。Hf 不能有 NaN。torch，显卡上跑（同 71，格距可变）。"""
    import torch
    dev = device or ("cuda" if torch.cuda.is_available() else "cpu")
    H = torch.from_numpy(np.ascontiguousarray(Hf, np.float32)).to(dev)
    ny, nx = H.shape
    de, dn = math.sin(math.radians(az)), math.cos(math.radians(az))
    best = torch.full_like(H, -10.0); seen = set()
    for k in range(1, int(dmax/cs) + 1):
        di, dj = int(round(k*dn)), int(round(k*de))
        if (di, dj) in seen: continue
        seen.add((di, dj))
        src = H[max(di, 0):ny + min(di, 0), max(dj, 0):nx + min(dj, 0)]
        ds = (slice(max(-di, 0), ny + min(-di, 0)), slice(max(-dj, 0), nx + min(-dj, 0)))
        best[ds] = torch.maximum(best[ds], (src - H[ds])/(math.hypot(di, dj)*cs))
    out = best.cpu().numpy(); del H, best
    return out


def fill_smooth(x, m, sigmas=(2, 6, 18, 54, 160)):
    """空洞用逐级放大的归一化高斯补（大图版）。"""
    from scipy.ndimage import gaussian_filter
    y = np.where(m, x, 0).astype(np.float32); out = np.where(m, x, np.nan).astype(np.float32); done = m.copy()
    for s_ in sigmas:
        w = gaussian_filter(m.astype(np.float32), s_); v = gaussian_filter(y, s_)
        f = ~done & (w > 1e-3)
        out[f] = v[f]/w[f]; done |= f
        if done.all(): break
    out[~done] = np.nanmedian(x[m]) if m.any() else 0
    return out


def blend_dist(arrs, d, edges):
    """按离桅杆距离 d 在几种平滑程度之间线性过渡：edges[k] 处取 arrs[k]。"""
    out = arrs[0].copy()
    for k in range(1, len(arrs)):
        t = np.clip((d - edges[k - 1])/(edges[k] - edges[k - 1]), 0, 1)
        out = out*(1 - t) + arrs[k]*t
    return out


def grid_xy():
    cs, n, half = FINE["cs"], FINE["n"], FINE["half"]
    c = -half + (np.arange(n) + 0.5)*cs
    return c                                                               # x 与 y 相同；行 i ↔ y = c[i]（第 0 行在南）


R71_MAX = 4.6                                                           # 71 基线只用离桅杆 4.6 m 内：再往外有效帧少，有亮边（亮线伪影，见报告）
R71 = 0.003                                                             # 71 的 2 mm、9 帧多光照基线：反照率谱到 4 mm 仍是幂律（样块_第一批 §2）
LEVELS_S = [0.5, 1, 2, 4, 8, 16, 32]                                     # 金字塔各级高斯 σ（格）；最后一级以下是低频残差
C_RES = 1.8                                                             # 有效分辨率 = C_RES × 像素足迹：分半一致性（FRC，评估 ②）在 4.5–8 m 量到 1.66–1.85


def frame_quality(meta):
    return {"工作区全幅": 1.0, "前方全幅": 1.0, "工作区半幅": 0.7, "到站全景半幅": 0.8}[meta["kind"]]


def height_sigma(meta, rng):
    k = 1.0 if "全幅" in meta["kind"] else 2.0                           # 半分辨率：像素角大一倍，视差误差大一倍
    return k*(0.5e-3 + 1.0e-4*rng**2)


def sky_prior(els):
    """天光/直射比 a 的先验（每通道）：71 的 9 帧多光照分离在工作区拟合的值，按太阳高度线性插值。"""
    T = np.array([[19.2, 3.33, 4.19, 5.97], [33.3, 1.52, 1.54, 1.64], [46.4, 1.92, 1.90, 1.95], [47.3, 1.91, 1.85, 1.88]])
    return np.stack([np.interp(els, T[:, 0], T[:, k]) for k in (1, 2, 3)], 1)


def solve_gains(I, D, SV, valid, a0, iters=6):
    """I_f = g_f·A·(D_f + a_f·SV)：每帧每通道一个增益 g（> 0）和天光比 a。交替：A = 跨帧中值；g、g·a 稳健最小二乘，
    拟合出 g ≤ 0 或 a 不在先验的 0.5–2 倍内（平地上直射、天光两项几乎共线）→ a 用先验，只解 g。增益规范到中值 1。"""
    nf = len(I); a = a0.copy(); g = np.ones((nf, 3))
    def albedo():
        A = np.empty((3,) + SV.shape, np.float32)
        for c in range(3):
            st = []
            for f in range(nf):
                den = g[f, c]*(D[f] + a[f, c]*SV)
                ok = valid[f] & (den > 0.25*np.median(den[valid[f]]))
                st.append(np.where(ok, I[f][c]/np.maximum(den, 1e-12), np.nan))
            with np.errstate(all="ignore"): A[c] = np.nanmedian(np.stack(st), 0)
        return A
    A = albedo(); nfix = 0
    for it in range(iters):
        nfix = 0
        for f in range(nf):
            m = valid[f] & np.all(np.isfinite(A), 0) & np.all(np.isfinite(I[f]), 0) & np.isfinite(D[f])
            if m.sum() < 200: continue
            for c in range(3):
                X = np.c_[A[c][m]*D[f][m], A[c][m]*SV[m]]; y = I[f][c][m]
                try: cf = m71().robust_lstsq(X, y)
                except np.linalg.LinAlgError: cf = np.array([-1.0, 0.0])
                if cf[0] > 0 and 0.5*a0[f, c] <= cf[1]/cf[0] <= 2*a0[f, c]:
                    g[f, c], a[f, c] = cf[0], cf[1]/cf[0]
                else:
                    a[f, c] = a0[f, c]; g[f, c] = np.median(y/np.maximum(A[c][m]*(D[f][m] + a0[f, c]*SV[m]), 1e-12)); nfix += 1
        g /= np.median(g, 0, keepdims=True)
        A = albedo()
    return A, g, g*a, nfix


SH_IN = 0.06                                                            # 照片核车影：影内平均尺度（m）
SH_REF = (0.25, 0.5, 1.0, 2.0)                                           # 亮处参照的尺度（m），由近到远逐级补


def verify_rover_shadow(rgb, ok, lr, lit_t, mu0, SVs, a):
    """车体盒（57 ROVER_BOXES_TIGHT + 车体盒.json，逐件轴对齐包围盒）算出的车影按这帧照片核对，只做「盒说有影、照片说没有」这一边。
    盒子比真车胖（逐件包围盒、桅杆头、线缆），影子边是直线：照片里本来晒着太阳的地被当成影子去光影，除以只有天光的分母，
    反照率被抬高 1/k 倍（k = 天光 /（直射 + 天光）≈ 0.7，即 +43%）。sol 502 到站全景 12:57 那帧在车右后方（东北）留下一条
    直边浅带（docs/地面材质/近景细化.md §7.1，浅块.md）。
    做法：设没有车影时的反照率 L = log I − log(μ0·lit + a·SV)；盒影内 σ 6 cm 平均的 L 和盒影外 3–60 cm 亮处的参照（σ 0.25 m 起逐级放大）比，
    差 ρ。全影时 ρ ≈ k（对数），晒着时 ρ ≈ 0：ρ ≤ 0.75k 记影，≥ 0.25k 记亮，中间线性。地形影里（直射项小，k > −0.1）不核。
    返回新的 lr（1 = 亮）和统计。"""
    from scipy.ndimage import distance_transform_edt, zoom
    cs = FINE["cs"]; f = 4
    sh = ok & (lr < 0.5)
    rep = dict(盒影_m2=round(float(sh.sum()*cs*cs), 3), 改亮_m2=0.0)
    if sh.sum()*cs*cs < 0.005: return lr, rep
    den = np.maximum(mu0*lit_t + a*SVs, 1e-6)
    lum = np.where(ok, 0.2126*rgb[0] + 0.7152*rgb[1] + 0.0722*rgb[2], np.nan)
    L = np.where(ok, np.log(np.maximum(np.nan_to_num(lum), 1e-9)) - np.log(den), 0).astype(np.float32)
    k = np.log(np.maximum(a*SVs, 1e-6)/den).astype(np.float32)
    dsh = distance_transform_edt(~sh)*cs
    refm = ok & (lr >= 0.5) & (dsh > 0.03) & (dsh < 0.6) & (lit_t > 0.9)
    if refm.sum()*cs*cs < 0.02: rep["说明"] = "盒影外亮处太少，不核"; return lr, rep
    ny, nx = L.shape; py, px = (-ny) % f, (-nx) % f                       # 参照在 16 mm 格上算（σ 到 2 m）
    Lc = np.pad(L, ((0, py), (0, px))).reshape((ny + py)//f, f, (nx + px)//f, f)
    mc = np.pad(refm, ((0, py), (0, px))).reshape((ny + py)//f, f, (nx + px)//f, f)
    cnt = mc.sum((1, 3)); Lc = np.where(cnt > 0, (Lc*mc).sum((1, 3))/np.maximum(cnt, 1), 0); mc = cnt > 0
    ref_c = np.full(Lc.shape, np.nan, np.float32)
    for s_ in SH_REF:
        v, w = norm_gauss(Lc, mc, s_/(cs*f))
        fl = np.isnan(ref_c) & (w > 0.02); ref_c[fl] = v[fl]
    ref = zoom(np.nan_to_num(ref_c), f, order=1)[:ny, :nx]; okr = zoom(np.isfinite(ref_c).astype(np.float32), f, order=0)[:ny, :nx] > 0.5
    Ls, ws = norm_gauss(L, sh, SH_IN/cs)
    rho = Ls - ref
    s_lit = np.clip((rho - 0.75*k)/np.maximum(-0.5*k, 1e-3), 0, 1)
    use = sh & okr & (ws > 0.05) & (k < -0.1)
    lr2 = np.where(use, s_lit, lr).astype(np.float32)
    rep.update(改亮_m2=round(float((use & (s_lit > 0.5)).sum()*cs*cs), 3), 核对_m2=round(float(use.sum()*cs*cs), 3),
               影内ρ中位=round(float(np.median(rho[use])), 3) if use.any() else None, k中位=round(float(np.median(k[use])), 3) if use.any() else None)
    return lr2, rep


def cmd_fuse(args):
    from scipy.ndimage import gaussian_filter, distance_transform_edt, zoom
    M71 = m71(); cs, n, half = FINE["cs"], FINE["n"], FINE["half"]
    od = OUT/next((a.split("=")[1] for a in args if a.startswith("--输出=")), "融合"); od.mkdir(parents=True, exist_ok=True); t0 = time.time()
    use71 = "--无71" not in args
    verify_sh = "--不核车影" not in args                                   # 车影按照片核对（verify_rover_shadow）；--不核车影 = 旧做法（只信车体盒）
    metas = frames_meta(); corr = json.loads((OUT/"正射"/"配准.json").read_text()) if (OUT/"正射"/"配准.json").exists() else {}
    only = next((a.split("=")[1] for a in args if a.startswith("--帧组=")), None)   # 分半一致性用：只用部分帧
    tags = sorted(metas)
    if only: tags = [t for t in tags if any(t.startswith(p) for p in only.split(","))]
    exclude = {"0521_064113_00712"}                                       # 太阳高 10°，几乎全是天光（71 也不用）
    tags = [t for t in tags if t not in exclude]
    F = {t: load_aligned(t, corr) for t in tags}
    log(f"融合：{len(tags)} 帧（{time.time() - t0:.0f} s 读完）")
    c = grid_xy(); dist = np.hypot(c[None, :] - MAST_ENU[0], c[:, None] - MAST_ENU[1]).astype(np.float32)
    # ① 高度：逐格稳健加权平均（σ 按距离²），先剔离中值 3σ + 5 mm 以外的
    Hf = np.full((n, n), np.nan, np.float32); Hs = np.full((n, n), np.nan, np.float32); nH = np.zeros((n, n), np.uint8)
    T = 512
    for a0 in range(0, n, T):
        for b0 in range(0, n, T):
            hs, ws = [], []
            for t, d in F.items():
                i0, i1, j0, j1 = d["meta"]["bbox"]
                ia, ib, ja, jb = max(a0, i0), min(a0 + T, i1), max(b0, j0), min(b0 + T, j1)
                if ia >= ib or ja >= jb: continue
                hh = np.full((T, T), np.nan, np.float32); ss = np.full((T, T), np.nan, np.float32)
                sl = (slice(ia - i0, ib - i0), slice(ja - j0, jb - j0)); dl = (slice(ia - a0, ib - a0), slice(ja - b0, jb - b0))
                hh[dl] = np.where(d["ok"][sl], d["h"][sl], np.nan); ss[dl] = height_sigma(d["meta"], d["rng"][sl])
                hs.append(hh); ws.append(ss)
            if not hs: continue
            hs = np.stack(hs); ss = np.stack(ws)
            with np.errstate(invalid="ignore"):
                med = np.nanmedian(hs, 0)
                keep = np.abs(hs - med) < 3*ss + 0.005
            w = np.where(keep & np.isfinite(hs), 1/ss**2, 0)
            sw = w.sum(0)
            with np.errstate(invalid="ignore", divide="ignore"):
                Hf[a0:a0 + T, b0:b0 + T] = np.where(sw > 0, (w*np.nan_to_num(hs)).sum(0)/sw, np.nan)
                Hs[a0:a0 + T, b0:b0 + T] = np.where(sw > 0, 1/np.sqrt(sw), np.nan)
            nH[a0:a0 + T, b0:b0 + T] = (w > 0).sum(0)
    okH = np.isfinite(Hf)
    log(f"  高度：覆盖 {okH.sum()*cs*cs:.1f} m²（细格 {okH.mean()*100:.1f}%），每格帧数中值 {np.median(nH[okH]):.0f}，"
        f"融合 σ 中值 {np.nanmedian(Hs)*1e3:.2f} mm（{time.time() - t0:.0f} s）")
    # ② 明暗用的高度、法线（平滑随距离变大：3 m 内 σ 6 mm，8 m 处 16 mm）、天空可见度
    Hfill = fill_smooth(Hf, okH)
    nrm = []
    for s_ in (1.5, 4.0):
        gy, gx = np.gradient(gaussian_filter(Hfill, s_), cs)
        nrm.append(np.stack([-gx, -gy, np.ones_like(gx)]).astype(np.float32))
    nv = blend_dist(nrm, dist[None], (3.0, 8.0)); nv /= np.linalg.norm(nv, axis=0); del nrm
    sh = np.zeros((n, n), np.float32)
    for az in range(0, 360, 45):
        tt = horizon_tan(Hfill, az, 0.3, cs); sh += np.sin(np.arctan(np.maximum(tt, 0)))**2/8
    SV = ((1 - sh)*(1 + nv[2])/2).astype(np.float32); del sh
    log(f"  法线、天空可见度（{time.time() - t0:.0f} s）")
    # ③ 每帧：投射阴影（地形 1.5 m 内 + 车体盒）、直射 μ0、去光影的分母；粗格上解每帧增益和天光比
    M57 = m57(); X, Y = np.meshgrid(c, c)
    for t, d in F.items():
        m_ = d["meta"]; s = M71.sun_enu(m_["sun_az"], m_["sun_el"])
        i0, i1, j0, j1 = m_["bbox"]; sl = (slice(i0, i1), slice(j0, j1))
        tt = horizon_tan(Hfill[sl], m_["sun_az"], 1.5, cs)
        lit = np.clip((math.tan(math.radians(m_["sun_el"])) - tt)/0.035 + 0.5, 0, 1).astype(np.float32)
        P0 = np.stack([X[sl][d["ok"]], Y[sl][d["ok"]], Hfill[sl][d["ok"]] + 0.01], 1)
        near_ = np.hypot(P0[:, 0], P0[:, 1]) < 2.4/max(math.tan(math.radians(m_["sun_el"])), 0.1) + 3.0
        hit = np.zeros(len(P0), bool)
        if near_.any(): hit[near_] = M57.rays_hit_rover(P0[near_], P0[near_] + 8.0*s)
        lr = np.ones(d["ok"].shape, np.float32); lr[d["ok"]] = np.where(hit, 0.0, 1.0)
        d["mu0"] = np.clip(np.tensordot(s, nv[:, sl[0], sl[1]], 1), 0, 1).astype(np.float32)
        d["rover_shadow_box"] = float(1 - lr[d["ok"]].mean())
        if verify_sh:
            lr, d["shadow_check"] = verify_rover_shadow(d["rgb"], d["ok"], lr, lit, d["mu0"], SV[sl], float(sky_prior([m_["sun_el"]])[0].mean()))
        d["lit"] = lit*gaussian_filter(lr, 1.0)
        d["rover_shadow"] = float(1 - lr[d["ok"]].mean())
    f = 4; nc = n//f
    def coarse(a, ok):
        v = np.where(ok, a, 0).reshape(-1, nc, f, nc, f).sum((2, 4)) if a.ndim == 3 else np.where(ok, a, 0).reshape(nc, f, nc, f).sum((1, 3))
        k = ok.reshape(nc, f, nc, f).sum((1, 3))
        with np.errstate(invalid="ignore", divide="ignore"): return v/k, k > f*f*0.7
    I_c, D_c, V_c = [], [], []
    for t, d in F.items():
        i0, i1, j0, j1 = d["meta"]["bbox"]
        full = lambda a, fill=0: _embed(a, i0, i1, j0, j1, n, fill)
        okf = full(d["ok"], False)                                       # 影子里的格要留着：只有它们分得开直射和天光
        rgb_c, vk = coarse(np.stack([full(d["rgb"][k]) for k in range(3)]), okf)
        Dc, _ = coarse(full(d["mu0"]*d["lit"]), okf)
        I_c.append(rgb_c.astype(np.float32)); D_c.append(Dc.astype(np.float32)); V_c.append(vk)
    SVc = SV.reshape(nc, f, nc, f).mean((1, 3))
    a0 = sky_prior([F[t]["meta"]["sun_el"] for t in F])
    Ac, G, Ga, nfix = solve_gains(I_c, D_c, SVc, V_c, a0)
    log(f"  天光/直射：先验（71 按太阳高度插值）{np.round(a0[:, 0], 2).tolist()}；拟合越界改用先验 {nfix} 个")
    del I_c, D_c
    log(f"  每帧增益（粗格 {cs*f*1e3:.0f} mm）：增益 R {np.round(G[:, 0], 3).tolist()}；天光/直射 {np.round(Ga.mean(1)/G.mean(1), 2).tolist()}（{time.time() - t0:.0f} s）")
    LAc = np.log(np.maximum(Ac.mean(0), 1e-9)); okAc = np.isfinite(LAc)
    LAc_full = zoom(fill_smooth(LAc, okAc), f, order=1)
    # ④ 细格：每帧去光影反照率 → 金字塔分频，按各帧在该频段的 MTF（由像素足迹）加权累加
    NL = len(LEVELS_S); Sacc = np.zeros((NL + 1, 3, n, n), np.float32); Wacc = np.zeros((NL + 1, n, n), np.float32)
    rmin = np.full((n, n), np.inf, np.float32); stats = {}
    def add_frame(t, LA, okA, r_f, q, sl, okA_lo=None):
        """LA：(3, h, w) log 反照率（bbox 内），okA：权重 0–1，r_f：有效分辨率（米）；okA_lo：低频残差级的权重（羽化更宽，帧缝不成台阶）。"""
        Lf = np.stack([fill_smooth(LA[k], okA > 0) for k in range(3)])
        prev = Lf
        sig_f = 0.5*r_f                                                 # 像素足迹 r 的盒式 + 光学模糊 ≈ 高斯 σ 0.5 r
        for l, s_ in enumerate(LEVELS_S):
            lo = np.stack([gaussian_filter(Lf[k], s_) for k in range(3)])
            band = prev - lo; prev = lo
            fc = 1/(2*math.pi*0.7*s_*cs)                                # 该级中心频率
            Tm = np.exp(-2*math.pi**2*(sig_f*fc)**2)
            wl = (q*okA*Tm**2).astype(np.float32)
            Sacc[l][:, sl[0], sl[1]] += wl*band; Wacc[l][sl] += wl
        wl = (q*(okA if okA_lo is None else okA_lo)).astype(np.float32)
        Sacc[NL][:, sl[0], sl[1]] += wl*prev; Wacc[NL][sl] += wl
    for fi, (t, d) in enumerate(F.items()):
        m_ = d["meta"]; i0, i1, j0, j1 = m_["bbox"]; sl = (slice(i0, i1), slice(j0, j1))
        den = np.stack([G[fi, k]*d["mu0"]*d["lit"] + Ga[fi, k]*SV[sl] for k in range(3)])
        dm = np.median(den[0][d["ok"]])
        with np.errstate(invalid="ignore", divide="ignore"):
            LA = np.log(np.maximum(d["rgb"], 1e-9)/np.maximum(den, 1e-9))
        # 稳健：和多帧粗格中值比（8 mm 平滑），偏离 > 0.35（log）的格不要（机械臂、没模型的影子、反光）
        dev = gaussian_filter(np.where(d["ok"], LA.mean(0), 0), 2)/np.maximum(gaussian_filter(d["ok"].astype(np.float32), 2), 1e-3) - LAc_full[sl]
        okA = d["ok"] & (den[0] > 0.25*dm) & (np.abs(dev) < 0.35)
        # 权重：俯角（掠射时去光影误差大）、帧内边缘羽化 2 cm、深阴影降权
        Cz = m_["cam_C_enu"][2]
        dep = np.clip((Cz - np.nan_to_num(d["h"]))/np.maximum(d["rng"], 0.1), 0, 1)
        edt = distance_transform_edt(okA)*cs
        core = np.where(okA, np.nan_to_num(np.clip(dep/0.25, 0.2, 1)*np.clip(den[0]/dm, 0, 1)**2), 0)   # 帧外是 NaN：NaN×0 仍是 NaN，会把整个外包框的累加弄成 NaN
        wA = (core*np.clip(edt/0.02, 0, 1)).astype(np.float32)
        r_f = C_RES*np.where(d["ok"], d["foot"], 1.0)
        add_frame(t, LA, wA, r_f, frame_quality(m_), sl, (core*np.clip(edt/0.15, 0, 1)).astype(np.float32))
        rmin[sl] = np.where(wA > 0.3, np.fmin(rmin[sl], r_f), rmin[sl])
        stats[t] = dict(kind=m_["kind"], gain=G[fi].tolist(), sky=Ga[fi].tolist(), used_m2=float((wA > 0).sum()*cs*cs),
                        outlier_frac=float(1 - okA.sum()/max(d["ok"].sum(), 1)), rover_shadow=d["rover_shadow"],
                        rover_shadow_box=d["rover_shadow_box"], shadow_check=d.get("shadow_check"))
        F[t] = None
        log(f"  {t}（{m_['kind']}）：用 {stats[t]['used_m2']:.1f} m²，剔除 {stats[t]['outlier_frac']*100:.1f}%，车影 {stats[t]['rover_shadow']*100:.1f}%"
            + (f"（盒 {stats[t]['rover_shadow_box']*100:.1f}%，照片核对 {stats[t]['shadow_check']}）" if stats[t]["shadow_check"] else "") + f"（{time.time() - t0:.0f} s）")
    # ⑤ 71 的 2 mm 工作区基线（9 帧多光照分离）当一帧高权重：增益按 8 cm 尺度和本层对齐
    if use71: _add71(Sacc, Wacc, rmin, stats, add_frame, NL, t0)
    _finish_fuse(od, Sacc, Wacc, rmin, Hf, Hs, nH, SV, nv, G, Ga, F, stats, NL, t0)


def _add71(Sacc, Wacc, rmin, stats, add_frame, NL, t0):
    from scipy.ndimage import distance_transform_edt
    cs, n, half = FINE["cs"], FINE["n"], FINE["half"]
    g71 = grid71(); B = np.load(REF71/"分离"/"基线.npz"); A71 = B["A"]; ok71 = np.all(np.isfinite(A71), 0) & (A71.min(0) > 0) & (B["nH"] >= 5)
    d71 = np.hypot(g71["x0"] + (np.arange(g71["nx"]) + 0.5)*g71["cs"] - MAST_ENU[0], (g71["y0"] + (np.arange(g71["ny"]) + 0.5)*g71["cs"])[:, None] - MAST_ENU[1])
    ok71 &= d71 < R71_MAX                                                # 71：工作区边缘（> 5 m、有效帧少）有亮边伪影
    i0 = int(round((g71["y0"] + half)/cs)); j0 = int(round((g71["x0"] + half)/cs))
    ny2, nx2 = g71["ny"]//2, g71["nx"]//2
    A4 = A71[:, :ny2*2, :nx2*2].reshape(3, ny2, 2, nx2, 2); o4 = ok71[:ny2*2, :nx2*2].reshape(ny2, 2, nx2, 2)
    with np.errstate(invalid="ignore", divide="ignore"):
        A4 = np.where(o4[None], A4, 0).sum((2, 4))/o4.sum((1, 3))[None]
    ok4 = o4.sum((1, 3)) >= 3
    sl71 = (slice(i0, i0 + ny2), slice(j0, j0 + nx2))
    with np.errstate(invalid="ignore", divide="ignore"):
        Lcur = Sacc[NL][:, sl71[0], sl71[1]]/Wacc[NL][sl71][None]
    LA71 = np.log(np.maximum(A4, 1e-9))
    mm = ok4 & np.all(np.isfinite(Lcur), 0) & (Wacc[NL][sl71] > 0.5)
    g71c = np.array([np.median((Lcur[k] - LA71[k])[mm]) for k in range(3)])
    e71 = np.clip(distance_transform_edt(ok4)*cs/0.15, 0, 1)
    add_frame("71基线", LA71 + g71c[:, None, None], (ok4*e71).astype(np.float32), np.full(ok4.shape, R71, np.float32), 3.0, sl71)
    rmin[sl71] = np.where(ok4 & (e71 > 0.3), np.minimum(rmin[sl71], R71), rmin[sl71])
    stats["71基线"] = dict(gain_log=g71c.tolist(), m2=float(ok4.sum()*cs*cs))
    log(f"  71 基线：{stats['71基线']['m2']:.1f} m²，log 增益 {np.round(g71c, 3).tolist()}（{time.time() - t0:.0f} s）")


def _finish_fuse(od, Sacc, Wacc, rmin, Hf, Hs, nH, SV, nv, G, Ga, F, stats, NL, t0):
    cs, n = FINE["cs"], FINE["n"]
    # ⑥ 合成
    LA = np.zeros((3, n, n), np.float32)
    with np.errstate(invalid="ignore", divide="ignore"):
        for l in range(NL + 1):
            ok_l = Wacc[l] > 1e-4
            LA += np.where(ok_l[None], Sacc[l]/np.maximum(Wacc[l], 1e-12)[None], 0)
    cover = Wacc[NL]
    del Sacc
    np.savez(od/"融合.npz", LA=LA.astype(np.float32), cover=cover, W=Wacc[:NL].astype(np.float16), rmin=rmin, Hf=Hf, Hs=Hs, nH=nH, SV=SV.astype(np.float16),
             nv=nv.astype(np.float16), G=G, Ga=Ga, tags=np.array(list(F)), stats=json.dumps(stats, ensure_ascii=False))
    log(f"融合完成：反照率覆盖 {(cover > 0).sum()*cs*cs:.1f} m²，有效分辨率中值 {np.median(rmin[np.isfinite(rmin)])*1e3:.1f} mm（{time.time() - t0:.0f} s）")


def _embed(a, i0, i1, j0, j1, n, fill):
    out = np.full((n, n), fill, a.dtype if a.dtype != np.float16 else np.float32); out[i0:i1, j0:j1] = a; return out


# ── 导出 ─────────────────────────────────────────────────────────────────────────────────
EXP = OUT/"导出"                                                         # 导出、安装、图的目录；--导出=<名> 改（OUT 下）
FUSE = OUT/"融合"                                                        # 导出、评估读的融合结果；--融合=<名> 改（OUT 下）
CAL_SIGMA = 0.4                                                          # 低频颜色对齐到老近层的尺度（m）：保住照片回归验证过的大尺度色调
SLOPE_FADE = (0.01, 0.03)                                                # 着色器里细坡度按像素足迹淡出（m）


def norm_gauss(x, m, s):
    from scipy.ndimage import gaussian_filter
    w = gaussian_filter(m.astype(np.float32), s); v = gaussian_filter(np.where(m, x, 0).astype(np.float32), s)
    with np.errstate(invalid="ignore", divide="ignore"): return v/w, w


def rock_mask(n, cs, half, grow=0.02):
    """实测石块（57 ⑧，独立网格）的水平轮廓（顶点凸包外扩 grow）：这些地方的地面被石块网格盖住，高度改正和细坡度一律不加。"""
    from matplotlib.path import Path as MPath
    from scipy.spatial import ConvexHull
    S = json.loads((GD/"scene.json").read_text()); R = np.load(MAP/S["source"]/"石块.npz")
    inst = json.loads(str(R["inst"])); m = np.zeros((n, n), bool); c = -half + (np.arange(n) + 0.5)*cs
    for k, r in enumerate(inst):
        x, y = r["pos"][0], r["pos"][1]
        if max(abs(x), abs(y)) > half + r["D"]: continue
        V = R[f"V{k}"]; xy = V[:, :2].astype(np.float64)
        if np.ptp(xy[:, 0]) < 1e-6: continue
        hull = xy[ConvexHull(xy).vertices]; ctr = hull.mean(0)
        hull = ctr + (hull - ctr)*(1 + grow/np.maximum(np.linalg.norm(hull - ctr, axis=1, keepdims=True), 1e-3))
        j0, j1 = np.searchsorted(c, hull[:, 0].min()) - 1, np.searchsorted(c, hull[:, 0].max()) + 1
        i0, i1 = np.searchsorted(c, hull[:, 1].min()) - 1, np.searchsorted(c, hull[:, 1].max()) + 1
        j0, i0 = max(j0, 0), max(i0, 0); j1, i1 = min(j1, n), min(i1, n)
        if j0 >= j1 or i0 >= i1: continue
        X, Y = np.meshgrid(c[j0:j1], c[i0:i1])
        m[i0:i1, j0:j1] |= MPath(hull).contains_points(np.c_[X.ravel(), Y.ravel()]).reshape(X.shape)
    return m, len(inst)


class BaseHeights:
    """CDLOD 高度层（heights.bin，可叠加改正）在 ENU 点的取高和片元法线坡度，逐步照抄 地形.gdshader hl_level / hl_height / hl_normal（kmin = 0）。"""
    def __init__(self, HL, c0=0.02, half0=6.0):
        self.HL, self.c0, self.h0, self.L, self.N = HL, c0, half0, HL.shape[0], HL.shape[1]
    def level(self, x, z):
        e = np.maximum(np.abs(x), np.abs(z))
        k0 = np.maximum(0, np.ceil(np.log2(np.maximum(e, 1e-6)/(self.h0*0.98))))
        hk = self.h0*2**k0
        return np.minimum(k0 + np.clip((e - 0.9*hk)/(0.08*hk), 0, 1), self.L - 1)
    def at(self, x, z, k):                                               # 第 k 层（整数数组）双线性
        c = self.c0*2.0**k; h = self.h0*2.0**k
        fx = np.clip((x + h)/c, 0, self.N - 1.001); fz = np.clip((z + h)/c, 0, self.N - 1.001)
        i = np.floor(fx).astype(int); j = np.floor(fz).astype(int); tx = fx - i; tz = fz - j; kk = k.astype(int)
        A = self.HL
        return (A[kk, j, i]*(1 - tx) + A[kk, j, i + 1]*tx)*(1 - tz) + (A[kk, j + 1, i]*(1 - tx) + A[kk, j + 1, i + 1]*tx)*tz
    def height(self, x, z, kf):
        k = np.floor(kf); t = kf - k
        a = self.at(x, z, k); b = self.at(x, z, np.minimum(k + 1, self.L - 1))
        return np.where(t > 0, a*(1 - t) + b*t, a)
    def slope(self, x, z):
        """片元 hl_normal 的坡度 (∂h/∂E, ∂h/∂N)：中心差分，步长 = 该层格距。Godot z = −N。"""
        kf = self.level(x, z); e = self.c0*2.0**np.floor(kf)
        hx = self.height(x + e, z, kf) - self.height(x - e, z, kf); hz = self.height(x, z + e, kf) - self.height(x, z - e, kf)
        return hx/(2*e), -hz/(2*e)


def cmd_export(args):
    from scipy.ndimage import gaussian_filter, distance_transform_edt, zoom
    from PIL import Image
    Image.MAX_IMAGE_PIXELS = None
    M57 = m57(); cs, n, half = FINE["cs"], FINE["n"], FINE["half"]; t0 = time.time()
    EXP.mkdir(parents=True, exist_ok=True)
    Z = np.load(FUSE/"融合.npz"); LA = Z["LA"]; cover = Z["cover"]; rmin = Z["rmin"]; Hf = Z["Hf"]; Hs = Z["Hs"]
    c = grid_xy(); X, Y = np.meshgrid(c, c)
    dist = np.hypot(X - MAST_ENU[0], Y - MAST_ENU[1]).astype(np.float32)
    rep = {}
    # ① 反照率：小缝（≤ 3 cm）补平滑值；低频（σ 0.4 m）颜色对齐老近层
    have = cover > 0.05
    # 车身投影里高出局部下包络（30 cm 开运算）4 cm 以上的格不是地面：收起的机械臂 / 转塔低垂的部件。老管线（OBJ）和 71 的
    # 中值高度里也有它（每帧都拍到），老近层用合成纹理盖住了；新反照率会把转塔的深色金属照原样贴上去，所以这里让给老近层
    from scipy.ndimage import grey_opening
    Hfill_ = fill_smooth(Hf, np.isfinite(Hf), (2, 6, 18))
    env = grey_opening(Hfill_[::4, ::4], size=(19, 19)); env = zoom(env, 4, order=1)[:n, :n]
    ur = M57.under_rover(X, Y, 0.10)
    notground = ur & np.isfinite(Hf) & (Hf - env > 0.04)
    # 同一区域里车体遮挡边上 3 cm 的一圈、发灰的格（R/B < 1.55，火星地面 ≈ 2）：车体盒外漏进来的转塔、钻头像素
    from scipy.ndimage import label as cc_label
    lab_, nl_ = cc_label(~have); sz_ = np.bincount(lab_.ravel())
    bighole = (lab_ > 0) & (sz_[lab_] > 0.05/cs**2)                      # 大洞（> 0.05 m²）：车体挡住的扇区；石子背后的小影子不算
    edt_h = distance_transform_edt(~bighole)*cs                          # 到车体遮挡边的距离
    grey = ur & have & (LA[0] - LA[2] < math.log(1.55)) & (edt_h < 0.15)   # 只在遮挡边 15 cm 内：磨蚀斑、钻孔也发灰，不能一刀切
    fringe = ur & have & (edt_h < 0.03)
    notground |= fringe | (gaussian_filter(grey.astype(np.float32), 0.01/cs) > 0.02)
    notground = np.asarray(gaussian_filter(notground.astype(np.float32), 3) > 0.05)
    have &= ~notground
    rep["车前非地面"] = dict(面积_m2=float(notground.sum()*cs*cs))
    gap = ~have & ~notground & (distance_transform_edt(~have)*cs <= 0.015)
    LAf = np.stack([np.where(have, LA[k], fill_smooth(LA[k], have, (2, 6))) for k in range(3)])
    okA = have | gap
    S = json.loads((GD/"scene.json").read_text()); T = S["tex"]
    old, aold = read_rgba_lin(GD/T["albedo_near"]["file"])
    Lold = np.moveaxis(np.log(np.maximum(sample_tex(old, T["albedo_near"]["half"], X, Y), 1e-5)), -1, 0); aold = sample_tex(aold, T["albedo_near"]["half"], X, Y)
    del old
    mcal = okA & (aold > 0.99)
    cal = []
    for k in range(3):
        v, w = norm_gauss(Lold[k] - LAf[k], mcal, CAL_SIGMA/cs)
        v = np.where(w > 1e-3, v, np.nanmedian((Lold[k] - LAf[k])[mcal]))
        cal.append(v.astype(np.float32))
    cal = np.stack(cal)
    # 石块背后的遮挡空洞（相机都在桅杆头，各帧的影子在同一侧）：≤ 15 cm 远的用 57 的纹理合成补（低频平滑 × 搬来的细节，
    # 保方差混合），分辨率记 2 cm（着色器照常加微观）；更大的空洞（车底、车身挡住的扇区）渐隐到老近层
    fillz = ~okA & ~notground & (distance_transform_edt(~okA)*cs <= 0.15) & (np.maximum(np.abs(X), np.abs(Y)) < half - 0.1)
    Afill = M57.texture_fill(np.exp(LAf).transpose(1, 2, 0), okA, cs, seed=3, cell=0.12, sig_lo=0.1, rmin=0.25, rmax=1.5)
    LAf = np.where(fillz[None], np.log(np.maximum(Afill.transpose(2, 0, 1), 1e-6)), LAf); del Afill
    okA0 = okA; okA = okA | fillz
    rep["遮挡空洞补"] = dict(面积_m2=float(fillz.sum()*cs*cs))
    LAc = LAf + cal
    rep["颜色对齐_log"] = dict(中值=[float(np.median(cal[k][okA])) for k in range(3)], 起伏_p5_p95=[np.percentile(cal[k][okA], [5, 95]).round(3).tolist() for k in range(3)])
    # alpha：覆盖处 3 cm 羽化；网格边 10 cm 渐隐
    edge = np.clip((half - np.maximum(np.abs(X), np.abs(Y)))/0.10, 0, 1)
    alpha = np.clip(distance_transform_edt(okA)*cs/0.03, 0, 1)*edge
    A = np.exp(LAc).transpose(1, 2, 0)
    # alpha = 0 的格 RGB 不填 0，填邻近平滑值（补边）：双线性 / mipmap 会把透明格的颜色混进边上（着色器按 a 混合、不是预乘），
    # 填黑时遮挡边、掩膜洞边一圈发暗发灰
    rgba = np.concatenate([M57.srgb8(A), (alpha*255 + 0.5).astype(np.uint8)[..., None]], -1)
    Image.fromarray(np.flipud(rgba), "RGBA").save(EXP/"fine_albedo.png")
    rep["反照率"] = dict(格=f"{n}² × {cs*1e3:.0f} mm", 覆盖_m2=float(okA.sum()*cs*cs), 补缝_m2=float(gap.sum()*cs*cs),
                       中位RGB=np.median(A[okA], 0).round(4).tolist(), 老近层中位RGB=np.median(np.exp(Lold).transpose(1, 2, 0)[mcal], 0).round(4).tolist())
    log(f"导出 反照率 {rep['反照率']}；颜色对齐 {rep['颜色对齐_log']}（{time.time() - t0:.0f} s）")
    # ② 2 mm 工作区贴片（71 基线，同样的增益和低频对齐）
    g71 = grid71(); B = np.load(REF71/"分离"/"基线.npz"); A71 = B["A"]
    ok71 = np.all(np.isfinite(A71), 0) & (A71.min(0) > 0) & (B["nH"] >= 5)
    xs = g71["x0"] + (np.arange(g71["nx"]) + 0.5)*g71["cs"]; ys = g71["y0"] + (np.arange(g71["ny"]) + 0.5)*g71["cs"]
    X2, Y2 = np.meshgrid(xs, ys); ok71 &= np.hypot(X2 - MAST_ENU[0], Y2 - MAST_ENU[1]) < R71_MAX
    st = json.loads(str(Z["stats"])); g71c = np.array(st["71基线"]["gain_log"])
    rr, cc = (Y2 + half)/cs - 0.5, (X2 + half)/cs - 0.5
    calp = np.stack([bilinear(cal[k], rr, cc) for k in range(3)])
    LA71 = np.log(np.maximum(A71, 1e-9)) + g71c[:, None, None] + calp
    # 羽化：外边、大洞 15 cm；小洞（< 0.01 m²：石块顶、有效帧不足 5 的点）只羽化 1 cm——原来一律 15 cm，贴片在碎石地上大半被淡掉
    from scipy.ndimage import label as cc_label
    lab71, _ = cc_label(~ok71); sz71 = np.bincount(lab71.ravel())*g71["cs"]**2
    small71 = (lab71 > 0) & (sz71[lab71] < 0.01)
    a71 = np.minimum(np.clip(distance_transform_edt(ok71 | small71)*g71["cs"]/0.15, 0, 1),
                     np.clip(distance_transform_edt(~small71)*g71["cs"]/0.01, 0, 1))
    LA71 = np.stack([fill_smooth(LA71[k], ok71, (2, 6, 18)) for k in range(3)])                   # 补边（同 ①）
    rgba2 = np.concatenate([M57.srgb8(np.exp(LA71).transpose(1, 2, 0)), (a71*255 + 0.5).astype(np.uint8)[..., None]], -1)
    Image.fromarray(np.flipud(rgba2), "RGBA").save(EXP/"fine_patch.png")
    rect = [g71["x0"], g71["y0"], g71["x0"] + g71["nx"]*g71["cs"], g71["y0"] + g71["ny"]*g71["cs"]]
    rep["贴片"] = dict(格=f"{g71['nx']}×{g71['ny']} × {g71['cs']*1e3:.0f} mm", 范围ENU=rect, 覆盖_m2=float(ok71.sum()*g71["cs"]**2))
    # ③ 分辨率图（R8，1024²，log2(r/1 mm)·32；补的缝和 4 mm 格本身的极限都算进去）
    r = np.where(have, np.maximum(rmin, cs), np.where(gap | fillz, 0.02, np.nan)).astype(np.float32)
    # 没数据的格取最近有数据格的值（补边）：着色器按反照率的 a 混合 r，这些格本身不起作用；原来填 0.256 时，1024² 的分辨率图
    # 双线性插到洞边，r 被抬到几厘米，g_meso 打开，掩膜洞边冒出中观图块的凹凸（像一道翻起的褶）
    _, (ri, rj) = distance_transform_edt(~np.isfinite(r), return_indices=True); r = r[ri, rj]; del ri, rj
    f = n//1024; rl = np.log2(r/0.001).reshape(1024, f, 1024, f).mean((1, 3))
    Image.fromarray(np.flipud(np.clip(rl*32 + 0.5, 0, 255).astype(np.uint8)), "L").save(EXP/"fine_res.png")
    rq = r[okA]
    rep["分辨率"] = dict(分位_mm={p: float(np.percentile(rq, p)*1e3) for p in (5, 25, 50, 75, 95)},
                       面积_m2={f"≤{v} mm": float((rq <= v/1e3).sum()*cs*cs) for v in (3, 4, 6, 8, 12)})
    log(f"导出 分辨率 {rep['分辨率']}")
    # ④ 高度：CDLOD 改正（≥ 4 cm 波段进几何，GPU 顶点和 CPU h_cpu 同一份）+ 片元细坡度（< 4 cm 波段）
    HL = read_heights(); base = BaseHeights(HL)
    xg, zg = X, -Y
    B0 = base.height(xg, zg, base.level(xg, zg)).astype(np.float32)
    rk, nrock = rock_mask(n, cs, half, grow=0.05)                       # 外扩 5 cm：石块网格来自未配准的 OBJ，前方帧有 2–4 cm 的指向差
    under = M57.under_rover(X, Y, 0.10)                                   # 只除车身投影：57 的「虚构区」多边形（机械臂残影）是给老 OBJ 照片用的，
                                                                         # 工作区帧拍时臂已收起、多帧融合又剔了离群，那里的 XYZ 可信
    okH = np.isfinite(Hf) & ~rk & ~under & ~notground
    dif = np.where(okH, Hf - B0, 0)
    lo, _ = norm_gauss(dif, okH, 0.25/cs)
    hp = np.where(okH, dif - np.nan_to_num(lo), 0)
    hs_ = np.nan_to_num(Hs, nan=1.0).astype(np.float32)                # 融合高度的立体噪声 σ（每帧 σ ∝ 视距²，半分辨率 ×2）
    geo = [norm_gauss(hp, okH, s_/cs)[0] for s_ in (0.01, 0.025)]       # 几何：σ ≤ 2 mm 处平滑 1 cm，σ ≥ 6 mm 处 2.5 cm
    dg = np.nan_to_num(blend_dist(geo, hs_, (0.002, 0.006)))
    wt = np.clip(distance_transform_edt(okH)*cs/0.05, 0, 1)*np.clip((0.010 - hs_)/0.005, 0, 1)
    wt = gaussian_filter(wt, 2)*edge
    delta = (wt*dg).astype(np.float32)
    rep["高度改正"] = dict(石块=nrock, 改动_m2=float((np.abs(delta) > 1e-4).sum()*cs*cs), RMS_mm=float(np.sqrt(np.mean(delta[wt > 0.5]**2))*1e3),
                         p99_9_mm=float(np.percentile(np.abs(delta[wt > 0.5]), 99.9)*1e3))
    # CDLOD 各层改正：第 0 层节点取样；第 1 层内圈 = 第 0 层隔点、外圈取样（同 61 的约定）；更粗的层内圈继续隔点
    N = HL.shape[1]; layers = []
    for k in range(HL.shape[0]):
        ck, hk = 0.02*2**k, 6.0*2**k
        if hk/2 > half + 0.1 and k >= 2:                                 # 改正区（±8.2 m）全在内圈：只隔点继承
            prev = layers[-1][1]; a = (N - 1)//4; d = np.zeros((N, N), np.float32)
            d[a:a + (N - 1)//2 + 1, a:a + (N - 1)//2 + 1] = prev[::2, ::2]
        else:
            gx = -hk + np.arange(N)*ck; gn = hk - np.arange(N)*ck          # 节点 i ↔ x，j ↔ N（第 0 行在北）
            GX, GN = np.meshgrid(gx, gn)
            d = bilinear(delta, (GN + half)/cs - 0.5, (GX + half)/cs - 0.5)
            d[(np.abs(GX) > half - cs) | (np.abs(GN) > half - cs)] = 0
            if k >= 1:
                a = (N - 1)//4; d[a:a + (N - 1)//2 + 1, a:a + (N - 1)//2 + 1] = layers[-1][1][::2, ::2]
        nz = np.nonzero(np.abs(d) > 1e-6)
        if not len(nz[0]): break
        layers.append((k, d.astype(np.float32)))
    # 头 int32 层数、N、格式版本 2；每层 int32 k、j0、j1、i0、i1，再 float32 窗口两份：原高度、改后高度（float32 加法，和逐格加一致）。
    # 游戏里逐行比原高度（原生比较）、整行换成改后高度：GDScript 逐格相加 9 层 × 36 万格要 4 s 启动
    with open(EXP/"fine_dh.bin", "wb") as fo:
        np.array([len(layers), N, 2], np.int32).tofile(fo)
        for k, d in layers:
            jj, ii = np.nonzero(np.abs(d) > 1e-6); j0, j1, i0, i1 = jj.min(), jj.max() + 1, ii.min(), ii.max() + 1
            b0 = HL[k][j0:j1, i0:i1].astype(np.float32)
            np.array([k, j0, j1, i0, i1], np.int32).tofile(fo); b0.tofile(fo); (b0 + d[j0:j1, i0:i1]).astype(np.float32).tofile(fo)
    HLp = HL.copy()
    for k, d in layers: HLp[k] += d
    np.save(EXP/"heights_改后_预览.npy", HLp[:2])
    baseP = BaseHeights(HLp)
    # 片元：目标曲面 = 融合高度平滑到立体可信尺度（3 m 内 σ 4 mm，8 m 处 1 cm）；残差坡度 = 目标坡度 − 改后 CDLOD 片元坡度
    tgt = [norm_gauss(np.where(okH, Hf, 0), okH, s_/cs)[0] for s_ in (0.004, 0.010, 0.025)]   # σ 0.7 → 2.5 → 6 mm 依次换更平滑的
    Ht = blend_dist(tgt, hs_, (0.0007, 0.0025, 0.006))
    Ht = np.where(okH, Ht, np.nan)
    gyT, gxT = np.gradient(fill_smooth(Ht, okH, (2, 6, 18)), cs)
    sE, sN = baseP.slope(xg, zg)
    wS = np.clip(distance_transform_edt(okH)*cs/0.02, 0, 1)*np.clip((0.012 - hs_)/0.006, 0, 1)*edge
    # 残差坡度只留 < 0.25 m 的波段：更长波的坡度差（老底子与 XYZ 的整体倾斜、低频起伏）不该让光照和几何不一致
    rE = np.where(okH, gxT - sE, 0); rN = np.where(okH, gyT - sN, 0)
    rE = rE - np.nan_to_num(norm_gauss(rE, okH, 0.25/cs)[0]); rN = rN - np.nan_to_num(norm_gauss(rN, okH, 0.25/cs)[0])
    rs = np.clip(np.stack([rE*wS, rN*wS]).astype(np.float32), -1.5, 1.5)
    with open(EXP/"fine_slope.bin", "wb") as fo:                        # int32 宽、高 + float16 RG（第 0 行在北，同贴图）
        np.array([n, n], np.int32).tofile(fo); np.ascontiguousarray(np.flipud(np.moveaxis(rs, 0, -1))).astype(np.float16).tofile(fo)
    resid_h = np.where(okH, Ht - baseP.height(xg, zg, baseP.level(xg, zg)), 0)       # 片元那份（只进法线）隐含的高度差：同样只看 < 0.25 m 波段
    resid_h = resid_h - np.nan_to_num(norm_gauss(resid_h, okH, 0.25/cs)[0])
    rh = resid_h[okH & (wS > 0.5)]
    np.save(EXP/"诊断_改正与残差.npy", np.stack([delta, np.where(okH, resid_h, np.nan).astype(np.float32)]))
    rep["片元细坡度"] = dict(RMS=float(np.sqrt(np.mean(rs[:, wS > 0.5]**2))), 隐含高度差_RMS_mm=float(np.sqrt(np.nanmean(rh**2))*1e3),
                         隐含高度差_p99_mm=float(np.nanpercentile(np.abs(rh), 99)*1e3), 隐含高度差_p99_9_mm=float(np.nanpercentile(np.abs(rh), 99.9)*1e3))
    log(f"导出 高度改正 {rep['高度改正']}；片元细坡度 {rep['片元细坡度']}（{time.time() - t0:.0f} s）")
    J = dict(说明="72_近景细化.py 导出：细层（反照率 4 mm、工作区贴片 2 mm、每纹素数据分辨率、片元细坡度、CDLOD 高度改正）",
             albedo=dict(file="fine_albedo.png", half=half), patch=dict(file="fine_patch.png", rect=rect, res=R71),
             res=dict(file="fine_res.png", half=half, enc="r = 1 mm · 2^(v·255/32)"), slope=dict(file="fine_slope.bin", half=half),
             dh=dict(file="fine_dh.bin"), slope_fade=list(SLOPE_FADE), report=rep)
    (EXP/"near_fine.json").write_text(json.dumps(J, ensure_ascii=False, indent=1))
    log(f"导出完成 → {EXP}（{time.time() - t0:.0f} s）")


# ── 评估 ─────────────────────────────────────────────────────────────────────────────────
def cmd_evaluate(args):
    """① 老近层对新细层：分距离的传递函数和相干（全区，不只工作区）；② 分半一致性：两组互不相交的帧各自融合，
    两张反照率之间的相干掉到 0.5 处的波长 = 新层的有效分辨率（FRC 判据，同冷冻电镜），和每格像素足迹比 → C_RES。"""
    cs, n, half = FINE["cs"], FINE["n"], FINE["half"]
    od = OUT/"评估"; od.mkdir(parents=True, exist_ok=True)
    Z = np.load(FUSE/"融合.npz"); LA = Z["LA"]; cover = Z["cover"]; rmin = Z["rmin"]
    c = grid_xy(); X, Y = np.meshgrid(c, c); dist = np.hypot(X - MAST_ENU[0], Y - MAST_ENU[1])
    S = json.loads((GD/"scene.json").read_text()); T = S["tex"]
    old, aold = read_rgba_lin(GD/T["albedo_near"]["file"])
    Lold = np.log(np.maximum(sample_tex(old, T["albedo_near"]["half"], X, Y).mean(-1), 1e-5)); aold = sample_tex(aold, T["albedo_near"]["half"], X, Y)
    del old
    Lnew = np.log(np.maximum(np.exp(LA).mean(0), 1e-9))
    res = {}
    groups = [("1.5–3 m", 1.5, 3), ("3–4.5 m", 3, 4.5), ("4.5–6 m", 4.5, 6), ("6–8 m", 6, 8), ("全部", 0, 99)]
    def run(name, ref, test, okr, okt, win=128, step=96, extra=None):
        res[name] = {}
        for gname, d0, d1 in groups:
            Sp = Spectra(cs, win)
            for sl in windows(okr, win, step):
                m = okr[sl] & okt[sl]
                if m.mean() < 0.9 or not (d0 <= np.median(dist[sl]) < d1): continue
                Sp.add(smooth_holes(ref[sl], m), smooth_holes(test[sl], m))
            if Sp.n:
                r = Sp.result()
                if extra is not None: r["foot_med_mm"] = float(np.median(extra[sl_all(okr & okt, dist, d0, d1)])*1e3) if (okr & okt & (dist >= d0) & (dist < d1)).any() else None
                res[name][gname] = r
        log(f"评估 {name}：" + "，".join(f"{k} {v['n']} 窗 T50 {v['lam50_T_mm']} / 相干50 {v['lam50_coh_mm']} mm" for k, v in res[name].items()))
    run("老近层_对_新细层", Lnew, Lold, cover > 0.5, aold > 0.99)
    # 工作区里（71 的 2 mm 参考）：老 / 改后 CDLOD 第 0 层高度、新融合高度、新反照率的传递函数
    g = grid71(); cs2 = g["cs"]; X2, Y2 = np.meshgrid(g["x0"] + (np.arange(g["nx"]) + 0.5)*cs2, g["y0"] + (np.arange(g["ny"]) + 0.5)*cs2)
    B = np.load(REF71/"分离"/"基线.npz"); Href = B["H"]; okref = np.isfinite(Href) & (B["nH"] >= 5)
    HL = read_heights(); HLp = HL.copy(); HLp[:2] = np.load(EXP/"heights_改后_预览.npy")
    d2 = np.hypot(X2 - MAST_ENU[0], Y2 - MAST_ENU[1])
    Hf = Z["Hf"]; Hn = bilinear(Hf, (Y2 + half)/cs - 0.5, (X2 + half)/cs - 0.5)
    for name, test in (("高度_老第0层", sample_layer(HL[0], 0.02, 6.0, X2, Y2)), ("高度_改后第0层", sample_layer(HLp[0], 0.02, 6.0, X2, Y2)), ("高度_新融合4mm", Hn)):
        res[name] = {}
        for gname, d0, d1 in (("2.5–3.5 m", 2.5, 3.5), ("3.5–4.5 m", 3.5, 4.5), ("4.5–5.5 m", 4.5, 5.5), ("全部", 0, 99)):
            Sp = Spectra(cs2, 256)
            for sl in windows(okref, 256, 160):
                m = okref[sl] & np.isfinite(test[sl])
                if m.mean() < 0.97 or not (d0 <= np.median(d2[sl]) < d1): continue
                Sp.add(smooth_holes(Href[sl], m), smooth_holes(test[sl], m))
            if Sp.n: res[name][gname] = Sp.result()
        log(f"评估 {name}（对 71 参考高度）：" + "，".join(f"{k} T50 {v['lam50_T_mm']} / 相干50 {v['lam50_coh_mm']} mm" for k, v in res[name].items()))
    for sub in ("融合_A", "融合_B"):
        if not (OUT/sub/"融合.npz").exists(): break
    else:
        ZA = np.load(OUT/"融合_A"/"融合.npz"); ZB = np.load(OUT/"融合_B"/"融合.npz")
        LAa = np.log(np.maximum(np.exp(ZA["LA"]).mean(0), 1e-9)); LAb = np.log(np.maximum(np.exp(ZB["LA"]).mean(0), 1e-9))
        okab = (ZA["cover"] > 0.5) & (ZB["cover"] > 0.5)
        ra = np.maximum(ZA["rmin"], ZB["rmin"])
        run("分半一致性_A_对_B", LAa, LAb, okab, okab, extra=ra)
        for g, v in res["分半一致性_A_对_B"].items():
            fm = v.get("foot_med_mm")
            if fm and v["lam50_coh_mm"] == v["lam50_coh_mm"]:
                v["r_FRC_mm"] = v["lam50_coh_mm"]/2; v["C_RES"] = v["r_FRC_mm"]/fm
        log("评估 分半一致性：" + "，".join(f"{k} r={v.get('r_FRC_mm')} mm（足迹 {v.get('foot_med_mm')} mm，C={v.get('C_RES')}）" for k, v in res["分半一致性_A_对_B"].items()))
    # ③ 反照率对 71 的 2 mm 参考（同 测量 的做法，窗 0.5 m）：老近层 vs 不含 71 的两组半帧融合（融合_A/B，--无71）。
    #    导出的细层在工作区里就是 71 本身（贴片），拿它对 71 比是循环论证，所以用不含 71 的融合量「细层自己」的分辨率
    Bm = B["A"].mean(0); okA71 = np.isfinite(Bm) & (Bm > 0) & okref; Lref71 = np.log(np.where(okA71, Bm, 1.0))
    T_ = S["tex"]["albedo_near"]; old2, aold2 = read_rgba_lin(GD/T_["file"])
    tests = [("反照率_老近层", np.log(np.maximum(sample_tex(old2, T_["half"], X2, Y2).mean(-1), 1e-5)), sample_tex(aold2, T_["half"], X2, Y2) > 0.99)]
    del old2
    for sub in ("融合_A", "融合_B"):
        if (OUT/sub/"融合.npz").exists():
            Zs = np.load(OUT/sub/"融合.npz"); La = np.log(np.maximum(np.exp(Zs["LA"]).mean(0), 1e-9)); ca = Zs["cover"] > 0.05                 # 同 导出 的 have
            rr, cc = (Y2 + half)/cs - 0.5, (X2 + half)/cs - 0.5
            tests.append((f"反照率_新细层_{sub}（无71）", bilinear(La, rr, cc), bilinear(ca.astype(np.float32), rr, cc) > 0.99))
    for name, test, okt in tests:
        res[name] = {}
        for gname, d0, d1 in (("2.5–3.5 m", 2.5, 3.5), ("3.5–4.5 m", 3.5, 4.5), ("4.5–5.5 m", 4.5, 5.5), ("全部", 0, 99)):
            Sp = Spectra(cs2, 256)
            for sl in windows(okA71, 256, 160):
                m = okA71[sl] & okt[sl] & np.isfinite(test[sl])
                if m.mean() < 0.9 or not (d0 <= np.median(d2[sl]) < d1): continue
                Sp.add(smooth_holes(Lref71[sl], m), smooth_holes(test[sl], m))
            if Sp.n: res[name][gname] = Sp.result()
        log(f"评估 {name}（对 71 参考反照率）：" + "，".join(f"{k} {v['n']} 窗 T50 {v['lam50_T_mm']} / 相干50 {v['lam50_coh_mm']} mm" for k, v in res[name].items()))
    (od/"评估.json").write_text(json.dumps(res, ensure_ascii=False, indent=1))
    plot_measure({k: v for k, v in res.items()}, od)


def sl_all(m, dist, d0, d1):
    return m & (dist >= d0) & (dist < d1)


# ── 安装 ─────────────────────────────────────────────────────────────────────────────────
def cmd_install(args):
    """把 导出/ 拷进 godot/数据/sol0530/（PNG 配无损、带 mipmap 的 .import，同 61），scene.json 只加 / 换 near_fine 一个键。
    --卸载：删文件、去掉键。"""
    import shutil
    M61 = load_mod("m61", "61_Godot数据.py")
    files = ["fine_albedo.png", "fine_patch.png", "fine_res.png", "fine_slope.bin", "fine_dh.bin"]
    S = json.loads((GD/"scene.json").read_text())
    if "--卸载" in args:
        for f in files:
            (GD/f).unlink(missing_ok=True); (GD/(f + ".import")).unlink(missing_ok=True)
        S.pop("near_fine", None); (GD/"scene.json").write_text(json.dumps(S, ensure_ascii=False, indent=1)); log("安装：已卸载"); return
    J = json.loads((EXP/"near_fine.json").read_text())
    for f in files:
        dst = GD/f; dst.unlink(missing_ok=True); shutil.copyfile(EXP/f, dst)
        if f.endswith(".png"): (GD/(f + ".import")).write_text(M61.import_file(f, f != "fine_res.png"))
    S["near_fine"] = {k: v for k, v in J.items() if k != "report"}
    (GD/"scene.json").write_text(json.dumps(S, ensure_ascii=False, indent=1))
    log(f"安装：{len(files)} 个文件 → {GD.relative_to(MAP)}，scene.json near_fine（{sum((GD/f).stat().st_size for f in files)/1e6:.0f} MB）")


# ── 图 ───────────────────────────────────────────────────────────────────────────────────
def cmd_figs(args):
    """对比图（写到 资料/地面材质/近景细化/图/，小图另拷 docs/地面材质/图/近景细化_*.jpg）：
    俯视（新细层 | 老近层 | 每纹素分辨率 | 帧覆盖）、局部 60 cm（老近层反照率 | 新反照率 | 老高度晕渲 | 新高度晕渲）。"""
    from PIL import Image, ImageDraw, ImageFont
    Image.MAX_IMAGE_PIXELS = None
    cs, n, half = FINE["cs"], FINE["n"], FINE["half"]
    fd = OUT/"图"; fd.mkdir(parents=True, exist_ok=True); docs = MAP/"docs"/"地面材质"/"图"
    try: font = ImageFont.truetype("/usr/share/fonts/google-noto-sans-cjk-vf-fonts/NotoSansCJK-VF.ttc", 22)
    except Exception: font = ImageFont.load_default()
    new, anew = read_rgba_lin(EXP/"fine_albedo.png")                     # 第 0 行在北
    S = json.loads((GD/"scene.json").read_text()); T = S["tex"]
    old, aold = read_rgba_lin(GD/T["albedo_near"]["file"])
    c = -half + (np.arange(n) + 0.5)*cs; X, Y = np.meshgrid(c, c[::-1])   # 北在上
    to8 = lambda a: (np.clip(a, 0, 1)*255 + 0.5).astype(np.uint8)
    def tone(A, ref=None):
        L = np.log(np.maximum(A, 1e-4)); lo, hi = np.percentile(L[np.isfinite(L)], [1, 99.5]) if ref is None else ref
        return np.clip((L - lo)/(hi - lo), 0, 1), (lo, hi)
    def label(img, txt):
        im = Image.fromarray(img); d = ImageDraw.Draw(im); d.rectangle([0, 0, 12*len(txt) + 30, 30], fill=(0, 0, 0)); d.text((6, 3), txt, fill=(255, 255, 255), font=font); return np.asarray(im)
    # 俯视（1/4）
    f = 4
    Nw = new[::f, ::f]; Aw = anew[::f, ::f]
    Ow = sample_tex(old, T["albedo_near"]["half"], X[::f, ::f], Y[::f, ::f]); Ao = sample_tex(aold, T["albedo_near"]["half"], X[::f, ::f], Y[::f, ::f])
    tn, rg = tone(Nw[Aw > 0.5]); 
    nimg = np.clip((np.log(np.maximum(Nw, 1e-4)) - rg[0])/(rg[1] - rg[0]), 0, 1)*(Aw[..., None] > 0.02)
    oimg = np.clip((np.log(np.maximum(Ow, 1e-4)) - rg[0])/(rg[1] - rg[0]), 0, 1)
    R = np.asarray(Image.open(EXP/"fine_res.png")).astype(np.float32)
    r_mm = 2**(R/32.0); r_img = np.clip(np.log2(r_mm)/5, 0, 1)                        # 1 mm 黑 → 32 mm 白
    import matplotlib; matplotlib.use("Agg"); import matplotlib.cm as cm
    r_col = (cm.viridis(1 - r_img)[..., :3])*(np.asarray(Image.fromarray(to8(Aw)).resize((1024, 1024)))[..., None] > 5)
    r_col = np.asarray(Image.fromarray(to8(r_col)).resize((n//f, n//f), Image.NEAREST))/255.0
    top = np.concatenate([label(to8(nimg), "新细层 4 mm（72）"), label(to8(oimg), "老近层 1 cm（57）"), label(to8(r_col), "每纹素分辨率：黄 2 mm → 紫 32 mm")], 1)
    Image.fromarray(top).save(fd/"俯视.png")
    Image.fromarray(top).resize((top.shape[1]//2, top.shape[0]//2), Image.LANCZOS).save(docs/"近景细化_俯视.jpg", quality=88)
    # 局部：60 cm 见方（150 格），老 / 新反照率、老 / 新高度晕渲
    Z = np.load(FUSE/"融合.npz"); Hf = Z["Hf"]                         # 第 0 行在南
    HL = read_heights(); base = BaseHeights(HL)
    HLp = np.load(EXP/"heights_改后_预览.npy"); HLq = HL.copy(); HLq[:2] = HLp; basep = BaseHeights(HLq)
    spots = [("工作区 磨蚀斑/钻孔", -2.15, -0.55), ("工作区 岩板", -3.2, -1.6), ("前方 5 m", -4.4, -3.3), ("前方 7 m", -5.8, -4.0), ("车右后（全景半幅）", 2.2, 2.4), ("车左（全景半幅）", -1.5, 3.2)]
    rows = []
    W = 150; up = 3
    for name, ex, ny_ in spots:
        xs = ex - W*cs/2 + (np.arange(W) + 0.5)*cs; ys = ny_ + W*cs/2 - (np.arange(W) + 0.5)*cs   # 北在上
        XX, YY = np.meshgrid(xs, ys)
        Nn = sample_tex(new, half, XX, YY); On = sample_tex(old, T["albedo_near"]["half"], XX, YY)
        okn = sample_tex(anew, half, XX, YY) > 0.5
        L = np.log(np.maximum(Nn.mean(-1), 1e-4)); lo, hi = np.percentile(L[okn] if okn.any() else L, [1, 99])
        tt = lambda A: np.clip((np.log(np.maximum(A, 1e-4)) - lo)/(hi - lo), 0, 1)
        hn = bilinear(np.where(np.isfinite(Hf), Hf, np.nan)[::-1], (half - YY)/cs - 0.5, (XX + half)/cs - 0.5)
        ho = base.height(XX, -YY, base.level(XX, -YY)); hp_ = basep.height(XX, -YY, basep.level(XX, -YY))
        hs = lambda h: np.repeat(hill(h[::-1], cs)[::-1][..., None], 3, -1)
        cells = [tt(On), tt(Nn)*np.where(okn[..., None], 1, 0.25), hs(ho), hs(hp_), hs(hn)]
        row = np.concatenate([np.pad(np.kron(x, np.ones((up, up, 1))), ((4, 4), (4, 4), (0, 0)), constant_values=1) for x in cells], 1)
        rows.append(label(to8(row), name))
    head = ["老近层反照率", "新细层反照率", "老高度（CDLOD 第 0 层）", "新几何（改正后第 0 层）", "新融合高度（4 mm，进法线）"]
    img = np.concatenate(rows, 0)
    hd = Image.new("RGB", (img.shape[1], 34), (0, 0, 0)); dr = ImageDraw.Draw(hd)
    for k, h in enumerate(head): dr.text((k*(W*up + 8) + 8, 4), h, fill=(255, 255, 255), font=font)
    img = np.concatenate([np.asarray(hd), img], 0)
    Image.fromarray(img).save(fd/"局部.png")
    Image.fromarray(img).resize((img.shape[1]*2//3, img.shape[0]*2//3), Image.LANCZOS).save(docs/"近景细化_局部60cm.jpg", quality=88)
    log(f"图 → {fd}，docs/地面材质/图/近景细化_俯视.jpg、近景细化_局部60cm.jpg")


CMDS = {"下载": cmd_download, "测量": cmd_measure, "正射": cmd_ortho, "配准": cmd_register, "融合": cmd_fuse, "导出": cmd_export, "评估": cmd_evaluate, "安装": cmd_install, "图": cmd_figs}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in CMDS:
        raise SystemExit(__doc__)
    for a_ in sys.argv[2:]:
        if a_.startswith("--导出="): EXP = OUT/a_.split("=", 1)[1]
        if a_.startswith("--融合="): FUSE = OUT/a_.split("=", 1)[1]
    CMDS[sys.argv[1]](sys.argv[2:])
