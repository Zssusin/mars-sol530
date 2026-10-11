#!/usr/bin/env python3
"""
80 沙纹场：从 HiRISE 正射里取出真实的米级风成波纹（次级波纹 / 大波纹），烘成运行时用的相量场（docs/地面材质/沙纹.md）。

取代 地貌.gdshaderinc 里 λ≈2.7 m 那组程序化沙纹：哪里有、波脊方向、波长、波脊位置（相位）、分叉和断头都来自影像。

步骤（fedora，仓库根运行；大的都在 systemd-run MemoryMax 下）：
  滤波    log-Gabor 方向滤波组（16 方向 × 14 尺度，λ 0.95–13.8 m），0.25 m 正射分 256 m 块做 FFT，
          每个 2 m 格存局部能量（高斯 σ = λ 平滑）→ 资料/沙纹/能量.npy（约 450 MB，float16）
  检出    能量白化（除以全区每个 方向×尺度 的中位数，去掉 1/f 谱和光照方向偏置），在 λ 1.2–4 m 找径向谱峰：
          径向峰（比 ×1.5、÷1.5 两侧都高）、方向选择性、超额能量、不是大床面（λ 6–14 m）的谐波 / 边缘、在沙类上；
          邻格方向一致性清理 → 资料/沙纹/场.npz（方向、波长、置信度）
  相位    每格中心按本格波矢做局部解调（高斯窗 σ = 0.45 λ）：c = Σ g·f·e^{−ik·(x−x_j)}，f 是 1–5 m 带通、去 1.12 m 伪影的
          log 亮度；再按光照模型 I = a·h + b·∇h 把亮度相位换成高度相位（见 标定）→ 场.npz 加 c
  标定    振幅–方向回归：|c|² = H²(a² + (b·k)²)，b 来自 资料/地貌参数/pc_calib.json（DTM 定标的光度测斜增益）→ 波高 H、反照率耦合 a
  烘焙    godot/数据/sol0530/ripple_field.bin：头 16 字节 + 1000×1000 RGBA8（2 m 格，±1000 m）：
          R = 波矢方位（0–360°，指向下风）、G = 波长（log，1.0–5.0 m）、B = 波脊相位、A = 振幅权重（0 = 没有沙纹）
  图      检出叠加图、场图（docs/地面材质/图/沙纹_*.jpg）
  核对    重建 Re(z) 与带通影像的相关、方向误差、覆盖率

数据：资料/地貌参数/ortho_enu_25cm.npy（prep.py：JEZ_hirise_soc_007 正射镶嵌 25 cm 原图双线性重采样到站心 ENU，行 0 = 南）。
"""
import sys, json, time, math, pathlib
import numpy as np

ROOT = pathlib.Path(__file__).resolve().parents[2]
ZL = ROOT/"资料/沙纹"
ORTHO = ROOT/"资料/地貌参数/ortho_enu_25cm.npy"
PC = ROOT/"资料/地貌参数/pc_calib.json"
GD = ROOT/"godot/数据/sol0530"
CS = 0.25; NPX = 8000; HALF = 1000.0
NO = 16
LAM = np.array([0.95, 1.2, 1.5, 1.8, 2.2, 2.7, 3.3, 4.0, 4.9, 6.0, 7.5, 9.2, 11.3, 13.8])
CAND = range(1, 8)                       # 候选 λ 1.2–4.0 m
BIG = range(9, 14)                       # 大床面 λ 6–13.8 m（谐波 / 边缘判据）
CELL = 2.0; NC = int(2*HALF/CELL)        # 2 m 格，1000²
ART = (0.883, 0.109)                     # 正射里的固定伪影：波矢 (0.883, 0.109) 周/m（λ 1.12 m，资料/地貌参数/说明.md §0）
P = dict(W_min=5.0, pk_min=1.3, sel_min=2.0, W_weak=3.0, pk_weak=1.15, sel_weak=1.6, g_min=1.5, ang_big=45.0, selb=1.3, sand_min=0.3, nb_min=3, min_cells=5,
         lam_lo=1.0, lam_hi=5.0, wind_az=200.0, lee=0.3, ku0=3.6, ku1=4.8, amin=20)


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def opt(a, k, d):
    for x in a:
        if x.startswith(f"--{k}="): return x.split("=", 1)[1]
    return d


def ortho():
    return np.load(ORTHO, mmap_mode="r")         # float16，行 0 = 南（y = −1000），列 0 = 西


# ———————————————— 滤波
def bank_filters(T):
    from scipy import fft as sfft
    k = sfft.fftfreq(T, CS); KX, KY = np.meshgrid(k, k)    # 列 = x（东），行 = y（北）
    K = np.hypot(KX, KY) + 1e-9; AZ = np.arctan2(KX, KY)   # 波矢方位，自北顺时针
    notch = np.ones((T, T), np.float32)
    for s in (1, -1):
        notch *= 1 - np.exp(-((KX - s*ART[0])**2 + (KY - s*ART[1])**2)/(2*0.025**2))
    TH = np.arange(NO)*np.pi/NO
    def G(lam, th):                                # 单边（解析）log-Gabor：径向 σ_ln f = 0.35，方向 σ = 12°
        r = np.exp(-np.log(K*lam)**2/(2*0.35**2))
        d = np.angle(np.exp(1j*(AZ - th)))
        return (r*np.exp(-d**2/(2*np.radians(12)**2))).astype(np.float32)
    return notch, [[G(l, t) for t in TH] for l in LAM]


def load_tile(I, r0, c0, T, M):
    rr = np.arange(r0 - M, r0 - M + T).clip(0, NPX - 1); cc = np.arange(c0 - M, c0 - M + T).clip(0, NPX - 1)
    a = np.asarray(I[np.ix_(rr, cc)], np.float32)
    bad = ~(a > 0)
    fill = float(np.median(a[~bad])) if (~bad).any() else 0.3
    return np.log(np.where(bad, fill, a)), bad


def stage_filter(a):
    from scipy import fft as sfft
    from scipy.ndimage import gaussian_filter
    ZL.mkdir(parents=True, exist_ok=True)
    I = ortho(); T = 1024; M = 64; C = T - 2*M; step = int(CELL/CS)
    notch, Gs = bank_filters(T)
    EE = np.lib.format.open_memmap(ZL/"能量.npy", "w+", np.float16, (len(LAM), NO, NC, NC))
    t0 = time.time(); n = 0
    for r0 in range(0, NPX, C):
        for c0 in range(0, NPX, C):
            a_, bad = load_tile(I, r0, c0, T, M)
            A = sfft.fft2(a_ - a_.mean(), workers=4)*notch
            nr = min(C, NPX - r0)//step; nc = min(C, NPX - c0)//step
            E = np.zeros((len(LAM), NO, nr, nc), np.float32)
            for si, row in enumerate(Gs):
                for oi, g in enumerate(row):
                    z = sfft.ifft2(A*g, workers=4)
                    e = gaussian_filter((z.real**2 + z.imag**2).astype(np.float32), LAM[si]/CS)
                    E[si, oi] = e[M + step//2:M + step//2 + nr*step:step, M + step//2:M + step//2 + nc*step:step]
            E[:, :, bad[M + step//2:M + step//2 + nr*step:step, M + step//2:M + step//2 + nc*step:step]] = np.nan
            EE[:, :, r0//step:r0//step + nr, c0//step:c0//step + nc] = np.minimum(E*1e4, 6e4).astype(np.float16)
            n += 1; log(f"滤波块 {n}/81  {time.time() - t0:.0f} s")
    EE.flush(); log("滤波完成")




# ———————————————— 检出
def sand_weight():
    cls = np.fromfile(GD/"geo_class.bin", np.uint8).reshape(2000, 2000, 4)[..., 0].astype(np.float32)/255.0   # 行 0 = 北
    s = np.flipud(cls).reshape(NC, 2, NC, 2).mean((1, 3))           # → 行 0 = 南，2 m 格
    return s


def detect(E, sand=None, ref=None):
    """E: (尺度, 方向, ny, nx)。返回 dict：det、θ（波矢方位，弧度，0–π）、λ、score、W*、pk、sel。"""
    from scipy.ndimage import gaussian_filter
    ns = len(LAM)
    E = np.nan_to_num(E, nan=0.0) + 1e-9
    R, Bo = ref                                                      # 全区：每 方向×尺度 中位能量；方向偏置（光照）
    Wg = E/R[:, :, None, None]                                       # 相对全区（绝对对比度门槛用）
    iso = E.mean(1)                                                  # 各尺度方向平均
    Rl = gaussian_filter(iso, (0, 5, 5))                             # 局部 10 m 的各向同性谱
    W = E/(Rl[:, None]*Bo[:, :, None, None]) + 1e-6                  # 局部、去光照方向偏置的方向超额
    lW = np.log(W)
    from scipy.ndimage import gaussian_filter
    Wb = gaussian_filter(W[list(BIG)].sum(0), (0, 3, 3))             # 大床面能量（方向），6 m 平滑
    ob = np.argmax(Wb, 0); selb = Wb.max(0)/Wb.mean(0)
    best = None
    oo = np.arange(NO)[:, None, None]
    for s in CAND:
        lo = max(s - 2, 0); hi = s + 2
        pk = np.minimum(W[s]/W[lo], W[s]/W[hi])
        sel = W[s]/W[s].mean(0, keepdims=True)
        # 谐波：同方向 2λ、3λ 处的能量（按 log λ 插值）
        def at(lam):
            t = np.interp(np.log(lam), np.log(LAM), np.arange(ns)); i = int(min(t, ns - 2)); f = t - i
            return np.exp((1 - f)*lW[i] + f*lW[i + 1])
        har = W[s]/np.maximum(at(2*LAM[s]), at(3*LAM[s]))
        dang = np.abs(((oo - ob[None]) + NO/2) % NO - NO/2)*180.0/NO   # 与大床面波矢的夹角（°，0–90）
        angok = ((dang >= P["ang_big"]) | (selb[None] < P["selb"])) & (Wb/Wb.mean(0, keepdims=True) < 1.25)   # 不是大床面（TAR）的方向
        ok = (W[s] > P["W_weak"]) & (pk > P["pk_weak"]) & (Wg[s] > P["g_min"]) & (har > 0.8) & angok
        strong = ok & (W[s] > P["W_min"]) & (pk > P["pk_min"])
        sc = np.where(ok, np.log(W[s]) + np.log(pk), -9.0)
        v = [sc, np.full(sc.shape, s, np.int16), pk, sel, W[s], strong]
        if best is None: best = v
        else:
            m = sc > best[0]; best = [np.where(m, a, b) for a, b in zip(v, best)]
    sc, si, pk, sel, ws, strong = best
    o = np.argmax(sc, 0); ii, jj = np.indices(o.shape)
    strong = strong[o, ii, jj]
    S = sc[o, ii, jj]; s_ = si[o, ii, jj].astype(int)
    det = S > -9
    # 亚格：方向（圆周抛物线，用 W[s*]）、尺度（log λ 抛物线）
    w0 = W[s_, o, ii, jj]; wm = W[s_, (o - 1) % NO, ii, jj]; wp = W[s_, (o + 1) % NO, ii, jj]
    lo_, l0, lp = np.log(wm), np.log(w0), np.log(wp)
    d = np.clip(0.5*(lo_ - lp)/np.minimum(lo_ - 2*l0 + lp, -1e-6), -0.5, 0.5)
    th = ((o + d)*np.pi/NO) % np.pi
    sm = np.log(W[np.maximum(s_ - 1, 0), o, ii, jj]); sp = np.log(W[s_ + 1, o, ii, jj])
    ds = np.clip(0.5*(sm - sp)/np.minimum(sm - 2*l0 + sp, -1e-6), -0.5, 0.5)
    lam = np.exp(np.interp(s_ + ds, np.arange(ns), np.log(LAM)))
    if sand is not None: det &= sand > P["sand_min"]
    # 邻格一致性：8 邻里方向差 < 25°、波长比 < 1.4 的检出数
    nb = np.zeros(det.shape, np.int16)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if dx == 0 and dy == 0: continue
            dt = np.roll(det, (dy, dx), (0, 1)); tt = np.roll(th, (dy, dx), (0, 1)); ll = np.roll(lam, (dy, dx), (0, 1))
            dth = np.abs(((th - tt) + np.pi/2) % np.pi - np.pi/2)
            nb += (dt & (dth < np.radians(25)) & (np.abs(np.log(lam/ll)) < np.log(1.4))).astype(np.int16)
    det2 = det & (nb >= P["nb_min"])
    # 滞后阈值：弱检出连通块里至少有一个强检出（同 Canny），去掉孤立的噪声块
    from scipy.ndimage import label
    lb, n = label(det2, np.ones((3, 3)))
    keep = np.zeros(n + 1, bool); keep[np.unique(lb[det2 & strong])] = True
    keep &= np.bincount(lb.ravel(), minlength=n + 1) >= P["min_cells"]     # 太小的块（< 5 格 = 20 m²）不算波列
    keep[0] = False
    det2 = keep[lb]
    return dict(det=det2, det0=det, th=th, lam=lam, S=np.where(det2, S, -9.0), W=ws[o, ii, jj], pk=pk[o, ii, jj], sel=sel[o, ii, jj], ref=R)


def smooth_field(F):
    """方向（倍角）、波长（log）按置信度加权平滑；置信度 a ∈ [0, 1]。"""
    from scipy.ndimage import gaussian_filter
    det = F["det"]; S = F["S"]
    a = np.where(det, np.clip((S - 1.2)/1.5, 0.0, 1.0), 0.0)
    w = a + 1e-6
    c2 = gaussian_filter(w*np.cos(2*F["th"]), 1.0); s2 = gaussian_filter(w*np.sin(2*F["th"]), 1.0)
    th = (0.5*np.arctan2(s2, c2)) % np.pi
    ll = gaussian_filter(w*np.log(F["lam"]), 1.0)/gaussian_filter(w, 1.0)
    aa = np.clip(gaussian_filter(a, 0.7)*1.4, 0, 1)                    # 边缘软化，孤立格变弱
    # 波矢定号：指向下风（与 wind_az 夹角 < 90°）
    wa = math.radians(P["wind_az"])
    flip = np.cos(th - wa) < 0
    az = np.where(flip, th + np.pi, th) % (2*np.pi)
    return dict(az=az, lam=np.exp(ll), a=aa)


def stage_detect(a):
    from scipy.ndimage import gaussian_filter
    for k_ in list(P):
        v = opt(a, k_, None)
        if v is not None: P[k_] = float(v)
    E = np.load(opt(a, "能量", str(ZL/"能量.npy")), mmap_mode="r")
    sand = sand_weight()
    # 白化基准：全区中位数（每 方向 × 尺度），只用沙类格
    ns = len(LAM)
    msk = sand > P["sand_min"]
    sub = (slice(None), slice(None), slice(None, None, 4), slice(None, None, 4))
    Es = np.nan_to_num(np.asarray(E[sub], np.float32), nan=0.0) + 1e-9; mm = msk[::4, ::4]
    Rg = np.median(Es[:, :, mm], axis=2)
    Bo = np.median((Es/Es.mean(1, keepdims=True))[:, :, mm], axis=2)
    ref = (Rg, Bo)
    out = {k: np.zeros((NC, NC), np.float32) for k in ("th", "lam", "S", "W")}; det = np.zeros((NC, NC), bool)
    B = 250; M = 16
    for r0 in range(0, NC, B):
        for c0 in range(0, NC, B):
            rs = slice(max(r0 - M, 0), min(r0 + B + M, NC)); cs = slice(max(c0 - M, 0), min(c0 + B + M, NC))
            F = detect(np.asarray(E[:, :, rs, cs], np.float32), sand[rs, cs], ref)
            ir = slice(r0 - rs.start, r0 - rs.start + B); ic = slice(c0 - cs.start, c0 - cs.start + B)
            for k in out: out[k][r0:r0 + B, c0:c0 + B] = F[k][ir, ic]
            det[r0:r0 + B, c0:c0 + B] = F["det"][ir, ic]
        log(f"检出 行 {r0}")
    F = dict(det=det, **out)
    G = smooth_field(F)
    np.savez_compressed(ZL/"场.npz", ref=ref[0], bias=ref[1], sand=sand, **F, **{"s_" + k: v for k, v in G.items()})
    log(f"检出：沙类格 {msk.mean():.3f}，检出 {det.mean():.4f}（占沙类 {det[msk].mean():.4f}），a>0.05 占沙类 {(G['a'][msk] > 0.05).mean():.4f}")


# ———————————————— 相位
def phase_coherence(c, az, lam, cell=CELL):
    """3×3 邻格把各自的平面波外推到本格中心，与本格同相的程度：ρ = |Σ c_n e^{ik_j·(x_j − x_n)}| / Σ|c_n|。
    真波列在 4–6 m（2–4 个波长）内相位连贯，ρ ≈ 0.8–1；噪声 ≈ 1/3。"""
    kx = 2*np.pi/np.maximum(lam, 1e-3)*np.sin(az); ky = 2*np.pi/np.maximum(lam, 1e-3)*np.cos(az)
    num = np.zeros(c.shape, np.complex64); den = np.zeros(c.shape, np.float32)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            cn = np.roll(c, (-dy, -dx), (0, 1))                      # 邻格 (j+dy, i+dx)
            num += cn*np.exp(-1j*(kx*dx*cell + ky*dy*cell))           # 邻格在 x_j + Δ 处的相位 → 外推回 x_j
            den += np.abs(cn)
    return np.abs(num)/np.maximum(den, 1e-9)


def bp_gain(lam):
    """1–5 m 带通的径向增益（log-Gauss，峰在 2.2 m）；解调结果除以它，振幅不随 λ 偏。"""
    return np.exp(-np.log(2.2/lam)**2/(2*0.55**2))


def bandpass_tile(a_):
    """1–5 m 各向同性带通（log 亮度），去 1.12 m 伪影。"""
    from scipy import fft as sfft
    T = a_.shape[0]
    k = sfft.fftfreq(T, CS); KX, KY = np.meshgrid(k, k); K = np.hypot(KX, KY) + 1e-9
    g = bp_gain(1/K)
    for s in (1, -1):
        g *= 1 - np.exp(-((KX - s*ART[0])**2 + (KY - s*ART[1])**2)/(2*0.025**2))
    return sfft.ifft2(sfft.fft2(a_ - a_.mean(), workers=4)*g, workers=4).real.astype(np.float32), g


def demod_tile(f, az, lam, rows, cols, r_px0, c_px0, cell, R=20, want_var=False):
    """f：带通瓦片（行 0 = 南）；对每个格 (rows, cols)（cell 米格）在格中心按波矢解调。返回复数 c（f ≈ Re(c·e^{ik·(x−x_j)})）。"""
    yy, xx = np.mgrid[-R:R + 1, -R:R + 1].astype(np.float32)*CS            # 行 = 北，列 = 东（米）
    out = np.zeros(len(rows), np.complex64); var = np.zeros(len(rows), np.float32)
    q = int(round(cell/CS))
    pr = (rows*q + q//2 - r_px0).astype(int); pc = (cols*q + q//2 - c_px0).astype(int)   # 格中心在像素 q·j + q/2 的左下角
    for i0 in range(0, len(rows), 2048):
        sl = slice(i0, i0 + 2048)
        P_ = np.stack([f[r - R:r + R + 1, c - R:c + R + 1] for r, c in zip(pr[sl], pc[sl])])
        kx = (2*np.pi/lam[sl]*np.sin(az[sl]))[:, None, None]; ky = (2*np.pi/lam[sl]*np.cos(az[sl]))[:, None, None]
        sg = (0.45*lam[sl])[:, None, None]
        g = np.exp(-((xx + 0.5*CS)**2 + (yy + 0.5*CS)**2)[None]/(2*sg**2))
        e = np.exp(-1j*(kx*(xx[None] + 0.5*CS) + ky*(yy[None] + 0.5*CS)))   # 像素中心相对格中心偏 +CS/2
        out[sl] = 2*(g*P_*e).sum((1, 2))/g.sum((1, 2))
        var[sl] = (g*P_*P_).sum((1, 2))/g.sum((1, 2))
    return (out, var) if want_var else out


def upsample_fields(Z, f):
    """2 m 场 → 输出格（f = 2/cell 倍）：方向按倍角向量、波长按 log、权重线性插值。"""
    from scipy.ndimage import zoom
    if f == 1: return Z["s_az"], Z["s_lam"], Z["s_a"]
    th = Z["s_az"]; a = Z["s_a"]
    c2 = zoom(np.cos(2*th)*(a + 1e-3), f, order=1); s2 = zoom(np.sin(2*th)*(a + 1e-3), f, order=1)
    th2 = (0.5*np.arctan2(s2, c2)) % np.pi
    c1 = zoom(np.cos(th), f, order=1); s1 = zoom(np.sin(th), f, order=1)            # 定号：沿用原来指向下风的那一侧
    az = np.where(np.cos(th2)*c1 + np.sin(th2)*s1 >= 0, th2, th2 + np.pi) % (2*np.pi)
    lam = np.exp(zoom(np.log(Z["s_lam"]), f, order=1))
    return az, lam, np.clip(zoom(a, f, order=1), 0, 1)


def stage_phase(a):
    Z = dict(np.load(ZL/"场.npz"))
    cell = float(opt(a, "格", "1.0")); f = int(round(CELL/cell)); n = NC*f
    az, lam, A = upsample_fields(Z, f)
    I = ortho(); T = 1024; M = 64; C = T - 2*M
    c = np.zeros((n, n), np.complex64); V = np.zeros((n, n), np.float32); KU = np.zeros((n, n), np.float32)
    q = int(round(cell/CS))
    for r0 in range(0, NPX, C):
        for c0 in range(0, NPX, C):
            j0, i0 = r0//q, c0//q; nj = min(C, NPX - r0)//q; ni = min(C, NPX - c0)//q
            sub = A[j0:j0 + nj, i0:i0 + ni] > 0.02
            if not sub.any(): continue
            a_, bad = load_tile(I, r0, c0, T, M)
            fb, _ = bandpass_tile(a_)
            jj, ii = np.nonzero(sub); jj = jj + j0; ii = ii + i0
            cc_, vv_ = demod_tile(fb, az[jj, ii], lam[jj, ii], jj, ii, r0 - M, c0 - M, cell, want_var=True)
            from scipy.ndimage import gaussian_filter as gf_
            m2 = gf_(fb*fb, 12.0); m4 = gf_(fb**4, 12.0)           # 局部峰度（σ = 3 m）：正弦 1.5、高斯 3、孤立团块 / 石块 ≫ 3
            pr = (jj*q + q//2 - (r0 - M)).astype(int); pc_ = (ii*q + q//2 - (c0 - M)).astype(int)
            KU[jj, ii] = m4[pr, pc_]/np.maximum(m2[pr, pc_]**2, 1e-12)
            c[jj, ii] = cc_/bp_gain(lam[jj, ii]); V[jj, ii] = vv_/bp_gain(lam[jj, ii])**2
        log(f"相位 行块 {r0}")
    rho = phase_coherence(c, az, lam, cell)
    np.savez_compressed(ZL/"相位.npz", cell=cell, az=az.astype(np.float32), lam=lam.astype(np.float32), a=A.astype(np.float32), c=c, rho=rho.astype(np.float32), var=V, kurt=KU)
    m = A > 0.3
    log(f"相位完成：{n}² × {cell} m；检出格相位连贯度 ρ 分位 10/50/90 % = {np.percentile(rho[m], [10, 50, 90]).round(2).tolist()}")


# ———————————————— 标定
def stage_calib(a):
    """振幅–方向回归：亮度一次谐波 |c| = A_h·|a + i·b·k|（log 亮度；b = 光度测斜增益 / 平均亮度，k = 波矢 rad/m）。
    同一类波纹的高度和方向无关时，|c|² 对 (b·k)² 是直线：斜率 = A_h²，截距 = (a·A_h)²。"""
    Z = dict(np.load(ZL/"相位.npz")); Zf = np.load(ZL/"场.npz"); pc = json.loads(PC.read_text())
    I = ortho()
    sand_px = np.repeat(np.repeat(Zf["sand"] > P["sand_min"], 8, 0), 8, 1)[::16, ::16]
    Is = np.asarray(I[::16, ::16], np.float32); Ibar = float(np.nanmean(Is[sand_px & (Is > 0)]))
    az, lam, A, c = Z["az"], Z["lam"], Z["a"], Z["c"]
    m = (A > 0.5) & (np.abs(c) > 0)
    k = 2*np.pi/lam[m]; bk = (pc["bx"]*k*np.sin(az[m]) + pc["by"]*k*np.cos(az[m]))/Ibar
    y = np.abs(c[m])**2; x = bk**2
    # 噪声底：同一批格，波矢转 90°（同 λ）解调出的 |c|² 中位数 —— 用相位阶段没检出的格近似：A ≤ 0.02 且 c = 0 不可用，
    # 这里用 a ∈ (0.02, 0.2] 的弱检出格的中位 |c|² 的一半作噪声上限
    weak = (A > 0.02) & (A <= 0.2) & (np.abs(c) > 0)
    noise = 0.5*float(np.median(np.abs(c[weak])**2)) if weak.any() else 0.0
    qs = np.quantile(x, np.linspace(0, 1, 11)); xb = []; yb = []
    for i in range(10):
        s_ = (x >= qs[i]) & (x <= qs[i + 1]); xb.append(float(np.median(x[s_]))); yb.append(float(np.median(y[s_])) - noise)
    xb = np.array(xb); yb = np.array(yb)
    sl, ic = np.polyfit(xb, yb, 1)
    Ah = math.sqrt(max(sl, 1e-12)); aa = math.sqrt(max(ic, 0))/Ah
    r = dict(Ibar=Ibar, bx_log=pc["bx"]/Ibar, by_log=pc["by"]/Ibar, n=int(m.sum()), noise=noise, A_h=Ah, H_pp=2*Ah, a=aa,
             bins_x=xb.tolist(), bins_y=yb.tolist(), slope=float(sl), intercept=float(ic),
             lam_med=float(np.median(lam[m])), bk_med=float(np.median(np.abs(bk))), c_med=float(np.median(np.abs(c[m]))))
    (ZL/"标定.json").write_text(json.dumps(r, ensure_ascii=False, indent=1))
    log("标定", json.dumps({k_: v for k_, v in r.items() if not k_.startswith("bins")}, ensure_ascii=False))


# ———————————————— 烘焙 + 运行时同款求值（Python 版，给核对和出图用；GDScript / C++ / 着色器 同一算法）
def height_model(Z, A_env, ropt):
    """文献波高模型（docs/地面材质/沙纹.md §3）：峰谷高 H_pp = clip(R(q)·λ, H_min, H_cap)，R(q) = R_lo + (R_hi − R_lo)·q，
    q = 本格 HiRISE 沙纹对比度（|c|，1–5 m 带通 log 亮度的一次谐波振幅）在检出格里的分位（p20 → 0，p90 → 1）。
    返回 H_pp 比 H_cap（0–1），乘进振幅权重；运行时 H = H_cap。HiRISE 1 m 格 DTM 在 λ 1–5 m 没有相干的沙纹信号
    （资料/沙纹/a5_sign.py：DTM 与亮度相位无关），实测高度只是噪声底，所以按文献 H/λ 取。"""
    R_lo, R_hi, H_cap, H_min = ropt
    c, lam = np.abs(Z["c"]), Z["lam"]
    m = (Z["a"] > 0.5) & (c > 0)
    p20, p90 = np.percentile(c[m], [20, 90])
    q = np.clip((c - p20)/(p90 - p20), 0, 1)
    Hpp = np.clip((R_lo + (R_hi - R_lo)*q)*lam, H_min, H_cap)
    return Hpp/H_cap


def bake_arrays(Z, cal, ropt=None, crest_dark=True):
    """返回 RGBA8（行 0 = 北，同 geo_class）。亮度相量按光照模型换成高度相量：c_h = c/(a + i·b·k)。
    crest_dark：a < 0（脊暗槽亮，Jezero 巨波纹冠部是深灰粗砂，Bell 2022；见 沙纹.md §4）。"""
    az, lam, A, c = Z["az"], Z["lam"], Z["a"], Z["c"]
    n = A.shape[0]
    k = 2*np.pi/lam; bk = cal["bx_log"]*k*np.sin(az) + cal["by_log"]*k*np.cos(az)
    hz = c/(cal["a"] + 1j*bk)*(-1 if crest_dark else 1)               # 脊暗 = 整个高度场反号（相位 + π）。不能把 a 换成 −a：光照相移 b·k 不反号，
                                                                      # 与亮度的相关会从 ±0.92 掉到 −0.26 / +0.2（a8_scan.py 扫相位偏移、a7_corr.py 核对）
    phi = np.angle(hz) % (2*np.pi)
    A = np.where(np.abs(c) > 0, A, 0.0)
    if "kurt" in Z:                                                      # 团块 / 石块 / 孤立小沙丘：1–5 m 带通的局部峰度高（正弦 1.5、高斯 3）→ 压低振幅
        t = np.clip((Z["kurt"] - P["ku0"])/(P["ku1"] - P["ku0"]), 0, 1); A = A*(1 - t*t*(3 - 2*t))
    A = np.clip((A - 0.05)/0.4, 0, 1); A = A*A*(3 - 2*A)                 # 置信度 → 包络：检出处 1，边缘软过渡
    if ropt is not None: A = A*height_model(Z, A, ropt)                  # 乘上本格 H_pp/H_cap
    A = np.where(A*255 < P["amin"], 0.0, A)                              # 振幅字节 < 20（H_pp < 2.4 cm）的格去掉：几乎看不见，但每个有沙纹的 4×4 块都让顶点着色器多算（远足 +0.3 ms 的主因）
    img = np.zeros((n, n, 4), np.uint8)
    img[..., 0] = np.round(az/(2*np.pi)*256).astype(int) % 256
    img[..., 1] = np.clip(np.round(np.log(np.clip(lam, P["lam_lo"], P["lam_hi"])/P["lam_lo"])/math.log(P["lam_hi"]/P["lam_lo"])*255), 0, 255)
    img[..., 2] = np.round(phi/(2*np.pi)*256).astype(int) % 256
    img[..., 3] = np.clip(np.round(A*255), 0, 255)
    img[img[..., 3] == 0] = 0                                           # 没有沙纹的格全 0（压缩后约 1/4）
    return np.flipud(img).copy()


def load_field():
    import zlib
    raw = (GD/"ripple_field.bin").read_bytes(); n = int(np.frombuffer(raw[4:8], np.int32)[0]); cell = float(np.frombuffer(raw[12:16], np.float32)[0])
    img = np.frombuffer(zlib.decompress(raw[16:]), np.uint8).reshape(n, n, 4)
    return img, cell, json.loads((GD/"ripple_field.json").read_text())


def rf_eval(img, cell, X, Zg, H, lee, rho0=0.15, rho1=0.6):
    """运行时算法（numpy 向量化，float64）。X、Zg：Godot 世界 x（东）、z（南）。返回 高度、Σw·a、ρ。"""
    N = img.shape[0]; half = N*cell/2
    fx = (X + half)/cell - 0.5; fz = (Zg + half)/cell - 0.5
    i0 = np.floor(fx).astype(int); j0 = np.floor(fz).astype(int); tx = fx - i0; tz = fz - j0
    zr = 0.0; zi = 0.0; As = 0.0
    for dj in (0, 1):
        for di in (0, 1):
            i = np.clip(i0 + di, 0, N - 1); j = np.clip(j0 + dj, 0, N - 1)
            w = (tx if di else 1 - tx)*(tz if dj else 1 - tz)
            t = img[j, i].astype(np.float64)
            a = t[..., 3]/255.0
            az = t[..., 0]/256.0*2*np.pi; lam = P["lam_lo"]*(P["lam_hi"]/P["lam_lo"])**(t[..., 1]/255.0); ph = t[..., 2]/256.0*2*np.pi
            cx = -half + (i + 0.5)*cell; cz = -half + (j + 0.5)*cell
            psi = ph + 2*np.pi/lam*(np.sin(az)*(X - cx) - np.cos(az)*(Zg - cz))
            zr = zr + w*a*np.cos(psi); zi = zi + w*a*np.sin(psi); As = As + w*a
    rho = np.hypot(zr, zi)/np.maximum(As, 1e-6)
    g = np.clip((rho - rho0)/(rho1 - rho0), 0, 1); g = g*g*(3 - 2*g)
    t = np.mod(np.arctan2(zi, zr)/(2*np.pi) + 1.0 - lee, 1.0)
    f = np.where(t < 1 - lee, np.sin(np.pi/2*t/(1 - lee))**2, np.cos(np.pi/2*(t - 1 + lee)/lee)**2)
    return H*As*g*(f - 0.5), As, rho


def stage_bake(a):
    Z = dict(np.load(ZL/"相位.npz")); cal = json.loads((ZL/"标定.json").read_text())
    cell = float(Z["cell"])
    if opt(a, "波高", None) is not None:                                   # 旧：全场一个峰谷高
        H = float(opt(a, "波高", None)); ropt = None; model = "常数"
    else:
        ropt = (float(opt(a, "比下限", 0.05)), float(opt(a, "比上限", 0.11)), float(opt(a, "高上限", 0.30)), float(opt(a, "高下限", 0.04)))
        H = ropt[2]; model = "文献 H/λ"
    img = bake_arrays(Z, cal, ropt, opt(a, "冠暗", "1") == "1"); n = img.shape[0]
    import zlib
    hdr = np.array([0x32465052, n], np.int32).tobytes() + np.array([HALF, cell], np.float32).tobytes()   # "RPF2"：头 16 字节 + zlib（Godot COMPRESSION_DEFLATE）
    (GD/"ripple_field.bin").write_bytes(hdr + zlib.compress(img.tobytes(), 9))
    meta = dict(file="ripple_field.bin", N=n, half=HALF, cell=cell, H=round(H, 4), 波高模型=model, 比=(list(ropt[:2]) if ropt else None), 冠暗=(opt(a, "冠暗", "1") == "1"), lee=P["lee"], lam_lo=P["lam_lo"], lam_hi=P["lam_hi"],
                rho=[0.15, 0.6], wind_az=P["wind_az"], 来源="scripts/Godot/80_沙纹场.py（HiRISE 正射 JEZ_hirise_soc_007）",
                覆盖=round(float((img[..., 3] > 12).mean()), 4))
    (GD/"ripple_field.json").write_text(json.dumps(meta, ensure_ascii=False, indent=1))
    log("烘焙", meta)



def stage_stripe(a):
    """反照率条纹贴图（运行时一次取样，替代逐像素相量；贴图 mip 让远处自然渐隐）：0.25 m 格 ±1000 m 的 R8，
    v = 127.5 + 127.5·s，s = 2·As·g(ρ)·(f − 0.5) ∈ [−1, 1]（和高度同一相位 / 相干度，= 2h/H）。着色器：albedo *= 1 − alb·s（脊暗槽亮）。
    Navcam 区（|e| < 47 m，几何同 geo_dem_l ≤ −3）和 ±1 km 边外为 0。"""
    import zlib
    img, cell, meta = load_field(); H = meta["H"]
    n = int(opt(a, "格数", 8000)); px = 2*HALF/n
    A = np.flipud(img[..., 3])                                             # 行 0 = 南
    out = np.full((n, n), 127.5, np.float32)
    B = 500; ncell = img.shape[0]
    for r0 in range(0, n, B):
        for c0 in range(0, n, B):
            x0 = -HALF + c0*px; y0 = -HALF + r0*px
            ci0 = max(int((x0 + HALF)/cell) - 2, 0); ci1 = min(int((x0 + B*px + HALF)/cell) + 3, ncell)
            cj0 = max(int((y0 + HALF)/cell) - 2, 0); cj1 = min(int((y0 + B*px + HALF)/cell) + 3, ncell)
            if not (A[cj0:cj1, ci0:ci1] > 0).any(): continue
            xs = x0 + (np.arange(B) + 0.5)*px; ys = y0 + (np.arange(B) + 0.5)*px; X, Y = np.meshgrid(xs, ys)
            h, As, rho = rf_eval(img, cell, X, -Y, H, meta["lee"])
            s = 2*h/H
            e = np.maximum(np.abs(X), np.abs(Y))
            fade = np.clip((e - 47.0)/3.0, 0, 1)*(1 - np.clip((e - 0.92*HALF)/(0.08*HALF), 0, 1)**2*(3 - 2*np.clip((e - 0.92*HALF)/(0.08*HALF), 0, 1)))
            out[r0:r0 + B, c0:c0 + B] = 127.5 + 127.5*np.clip(s*fade, -1, 1)
    u8 = np.flipud(np.round(out)).astype(np.uint8)                          # 行 0 = 北（同 ripple_field、geo_class）
    hdr = np.array([0x31535052, n], np.int32).tobytes() + np.array([HALF, px], np.float32).tobytes()   # "RPS1"
    (GD/"ripple_stripe.bin").write_bytes(hdr + zlib.compress(u8.tobytes(), 6))
    log("条纹贴图", n, "²，", round((GD/"ripple_stripe.bin").stat().st_size/1e6, 2), "MB，非中性格", float((u8 != 128).mean()))

# ———————————————— 核对
def st_orient(f, sig_px):
    """结构张量主方向（波矢方位，弧度 0–π，自北顺时针；f 行 0 = 北）和相干度。"""
    from scipy.ndimage import gaussian_filter
    gy, gx = np.gradient(f)                       # gy：行向（南）
    gN = -gy
    J11 = gaussian_filter(gx*gx, sig_px); J22 = gaussian_filter(gN*gN, sig_px); J12 = gaussian_filter(gx*gN, sig_px)
    th = 0.5*np.arctan2(2*J12, J22 - J11)          # 梯度主方向相对北（顺时针 = 东）
    coh = np.sqrt((J22 - J11)**2 + 4*J12**2)/(J11 + J22 + 1e-12)
    return th % np.pi, coh


def stage_check(a):
    """方向一致性（渲染算法重建的高度 vs HiRISE 带通亮度）、覆盖率、重建相关。随机取 60 个 40 m 窗（50–950 m，有沙纹处）。"""
    from scipy.ndimage import gaussian_filter
    img, cell, meta = load_field(); Zf = np.load(ZL/"场.npz")
    I = np.flipud(np.asarray(ortho(), np.float32))                       # 行 0 = 北
    rng = np.random.default_rng(1)
    A = np.flipud(img[..., 3])/255.0                                      # 行 0 = 南（同 场.npz）
    n = A.shape[0]; yy = (np.arange(n) + 0.5)*cell - HALF
    cand = np.argwhere(A > 0.3)
    d_new = []; d_old = []; cors = []; picked = 0; tries = 0
    old_th = math.radians(10.0)                                           # 旧程序化：波矢方位 10°（地貌参数.json）
    while picked < 60 and tries < 2000:
        tries += 1
        r, q = cand[rng.integers(len(cand))]; cx, cy = yy[q], yy[r]
        if max(abs(cx), abs(cy)) < 50 or max(abs(cx), abs(cy)) > 950: continue
        S = 40; npx = int(S/0.25)
        xs = cx - S/2 + (np.arange(npx) + 0.5)*0.25; ys = cy + S/2 - (np.arange(npx) + 0.5)*0.25; X, Y = np.meshgrid(xs, ys)
        h, As, rho = rf_eval(img, cell, X, -Y, meta["H"], meta["lee"])
        c0 = int((cx - S/2 + 1000)*4); r0 = int((1000 - (cy + S/2))*4)
        O = np.nan_to_num(I[r0 - 64:r0 + npx + 64, c0 - 64:c0 + npx + 64], nan=0.3)
        L = np.log(np.clip(O, 0.02, None)); fb, _ = bandpass_tile(np.pad(L, ((0, 1024 - L.shape[0]), (0, 1024 - L.shape[1])), mode="reflect"))
        fb = fb[64:64 + npx, 64:64 + npx]
        m = As > 0.15
        if m.mean() < 0.15: continue
        th_i, coh_i = st_orient(fb, 6); th_r, coh_r = st_orient(h, 6)
        mm = m & (coh_i > 0.3)
        if mm.sum() < 200: continue
        dn = np.abs(((th_r - th_i) + np.pi/2) % np.pi - np.pi/2)[mm]; do = np.abs(((old_th - th_i) + np.pi/2) % np.pi - np.pi/2)[mm]
        d_new.append(np.degrees(np.median(dn))); d_old.append(np.degrees(np.median(do)))
        # 重建相关：亮度相量（不换高度相位）→ 用 h 的 Hilbert 关系太绕，这里直接比高度与带通亮度的相关（|r|，光照相移会降低它）
        cors.append(abs(np.corrcoef(h[m], fb[m])[0, 1])); picked += 1
    sand = Zf["sand"]; zone = np.zeros_like(sand, bool); g = (np.arange(NC) + 0.5)*CELL - HALF; GX, GY = np.meshgrid(g, g)
    zone = (np.maximum(abs(GX), abs(GY)) > 50) & (np.maximum(abs(GX), abs(GY)) < 920)
    ws = np.clip((sand - 0.3)/0.4, 0, 1); ws = ws*ws*(3 - 2*ws)
    A2 = A.reshape(NC, 2, NC, 2).mean((1, 3)) if n == 2*NC else A
    r = dict(窗数=picked, 方向差中位_新=float(np.median(d_new)), 方向差中位_旧=float(np.median(d_old)),
             方向差_新_窗内中位的分位=np.percentile(d_new, [25, 50, 75]).round(1).tolist(), 方向差_旧_分位=np.percentile(d_old, [25, 50, 75]).round(1).tolist(),
             高度与带通亮度相关_中位=float(np.median(cors)),
             覆盖_旧_沙类加权=float(ws[zone].mean()), 覆盖_旧_有沙纹面积=float((ws[zone] > 0).mean()),
             覆盖_新_权重均值=float(A2[zone].mean()), 覆盖_新_有沙纹面积=float((A2[zone] > 0.05).mean()),
             覆盖_新_占沙类=float((A2[zone & (sand > 0.3)] > 0.05).mean()))
    (ZL/"核对.json").write_text(json.dumps(r, ensure_ascii=False, indent=1)); log("核对", json.dumps(r, ensure_ascii=False))


if __name__ == "__main__":
    st = {"滤波": stage_filter, "检出": stage_detect, "相位": stage_phase, "标定": stage_calib, "烘焙": stage_bake, "条纹": stage_stripe, "核对": stage_check}
    st[sys.argv[1]](sys.argv[2:])
