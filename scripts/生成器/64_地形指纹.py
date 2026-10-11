"""
地形指纹（venv 里跑）：真实火星地形在各尺度上的统计「指纹」——地形生成器的目标统计量，也是它的验收指标。
  数据（只读）：57_实景重建.py 的缓存 站26_1222/重建/（地形.npz、地类.npz、反照率_*.npz）、原始 CTX DTM、
        以及 Navcam 立体网格（按 sol 奇偶分两组各自栅格化 → 两组相减，实测立体噪声）。不写 重建/ 与 封存_*/。
  核心 API（生成器验收直接调用）：
    指纹(高程, 像素_m, 掩膜=None, 噪声=None) → dict：结构函数（四方向 + 各向同性）、分段 Hurst 与断点、
        坡度分布（各基线）、高通残差的偏度/峰度、二维变差图的各向异性、功率谱（只用完全有数据的方块）。
    比较(指纹a, 指纹b) → dict：共同尺度上 ν 的对数比、H、坡度、峰度的差。
  方法：
    · 结构函数 ν(Δx) = sqrt(⟨(z(x+Δx) − z(x))²⟩)，只取两端都有数据的点对，所以空洞不参与（不做跨洞 FFT）；
      方向 0°＝东、90°＝北、45°、135°（行＝自南向北，与 57 的网格一致）。对 fBm，ν ∝ Δx^H。
    · 二维变差图：掩膜 FFT（Marcotte 1996）γ(h) = Σ m m′(z′ − z)² / Σ m m′，零填充、无环绕；按角度取出 ν(θ) 看各向异性。
    · 功率谱：只在完全有数据的方块里（去平面 + Hann 窗），径向平均 P(k) ∝ k^−(2+2H)，作交叉检验。
    · 噪声：① 模型 σ(r) = 3 mm + 2.4e-4·r²（单样本）；② 实测：奇/偶 sol 网格各自做格内平均，差场 d 的结构函数 ν_d(Δx)，
      全部数据融合后的噪声 ν_噪(Δx) ≈ ν_d/2（两组等量、独立时）。ν < 2·ν_噪 的尺度标为「噪声主导」。
运行：.venv/bin/python scripts/生成器/64_地形指纹.py 自检      （合成 fBm / 白噪声 / 波纹 / 泊松点 / Golombek，验证估计量）
     .venv/bin/python scripts/生成器/64_地形指纹.py 噪声      （解析全部 Navcam 网格，约 5 分钟，结果缓存）
     .venv/bin/python scripts/生成器/64_地形指纹.py 全部      （sol 530 全套测量 → 指纹.json + 图）
产出：产出/生成器/指纹_sol0530/
数据：NASA/JPL-Caltech/University of Arizona/USGS（Mars 2020 Navcam、HiRISE、CTX DTM；PDS Imaging Node、USGS Astrogeology）。
"""
import importlib.util, json, math, os, pathlib, sys, time, warnings

os.environ.setdefault("OMP_NUM_THREADS", "8"); os.environ.setdefault("OPENBLAS_NUM_THREADS", "8"); os.environ.setdefault("MKL_NUM_THREADS", "8")
import numpy as np
warnings.filterwarnings("ignore", category=RuntimeWarning)

HERE = pathlib.Path(__file__).resolve().parent
MAP = HERE.parent.parent
PDS = MAP/"DEM"/"Blender缓存"/"_素材"/"PDS"
DIR = PDS/"站26_1222"
REC = DIR/"重建"
OUT = MAP/"产出"/"生成器"/"指纹_sol0530"
CLASSES = ("沙", "砾石风化层", "基岩", "暗色岩块")
R_MARS = 3396190.0


def log(*a): print("[64]", *a, flush=True)


_M57 = None


def m57():
    """只读导入 57 的函数（网格坐标、车体判断、网格解析、迭代下包络）；不调用任何会写文件的步骤。"""
    global _M57
    if _M57 is None:
        spec = importlib.util.spec_from_file_location("m57", MAP/"scripts"/"Blender"/"57_实景重建.py")
        _M57 = importlib.util.module_from_spec(spec); spec.loader.exec_module(_M57)
    return _M57


def _json(o):
    if isinstance(o, dict): return {str(k): _json(v) for k, v in o.items()}
    if isinstance(o, (list, tuple)): return [_json(v) for v in o]
    if isinstance(o, np.ndarray): return _json(o.tolist())
    if isinstance(o, (bool, np.bool_)): return bool(o)
    if isinstance(o, (int, np.integer)): return int(o)
    if isinstance(o, (float, np.floating)):
        v = float(o); return None if not math.isfinite(v) else float(f"{v:.5g}")
    return o


# ── ① 基础估计量 ────────────────────────────────────────────────────
DIRS = {0: (0, 1), 90: (1, 0), 45: (1, 1), 135: (1, -1)}                  # 方向（度，自东逆时针）→（行步＝北、列步＝东）


def 滞后表(n_max, 每十倍=10, n_min=1):
    n_max = max(int(n_max), n_min)
    k = max(int(math.log10(n_max/n_min)*每十倍) + 2, 2)
    return np.unique(np.round(np.geomspace(n_min, n_max, k)).astype(int))


def _pair(shape, dy, dx):
    H, W = shape
    s0 = (slice(max(0, -dy), H - max(0, dy)), slice(max(0, -dx), W - max(0, dx)))
    s1 = (slice(max(0, dy), H + min(0, dy)), slice(max(0, dx), W + min(0, dx)))
    return s0, s1


def 去平面(z, m):
    """有效格上最小二乘平面，减掉（无效格置 0）。"""
    iy, ix = np.nonzero(m)
    if len(iy) > 2_000_000:
        sel = np.linspace(0, len(iy) - 1, 2_000_000).astype(np.int64); iy, ix = iy[sel], ix[sel]
    A = np.stack([np.ones(len(iy)), ix, iy], 1).astype(np.float64)
    c, *_ = np.linalg.lstsq(A, z[iy, ix].astype(np.float64), rcond=None)
    P = c[0] + c[1]*np.arange(z.shape[1])[None, :] + c[2]*np.arange(z.shape[0])[:, None]
    return np.where(m, z - P, 0.0), c


def 归一卷积(a, m, s_px):
    """掩膜归一化高斯卷积（空洞不拖低均值）。返回 (平滑值, 有效权重 0–1)。"""
    from scipy.ndimage import gaussian_filter
    w = gaussian_filter(m.astype(np.float64), s_px, mode="constant")
    v = gaussian_filter(np.where(m, a, 0.0), s_px, mode="constant")/np.maximum(w, 1e-12)
    return v, w


def 结构函数(z, 像素_m, 掩膜=None, 滞后px=None, 噪声=None):
    """四方向结构函数（只用两端都有效的点对）。噪声：每格 σ（m）图，给出白噪声底 ν_n² = ⟨σ²(x) + σ²(x+h)⟩。
    返回各向同性 ν（对角方向在对数坐标插值到轴向滞后再平均 MS）、各方向 ν、增量的偏度/超额峰度（轴向平均）、点对数。"""
    z = np.asarray(z, np.float64)
    m = np.isfinite(z) if 掩膜 is None else (np.asarray(掩膜, bool) & np.isfinite(z))
    z = np.where(m, z, 0.0)
    if 滞后px is None: 滞后px = 滞后表(min(z.shape)//4)
    s2 = None if 噪声 is None else np.where(m, np.asarray(噪声, np.float64)**2, 0.0)
    lag_ax = np.asarray(滞后px, float)*像素_m
    per = {}
    for ang, (uy, ux) in DIRS.items():
        diag = bool(uy and ux); seen = set(); rows = []
        for L in 滞后px:
            k = max(1, int(round(L/math.sqrt(2)))) if diag else int(L)
            if k in seen: continue
            seen.add(k); dy, dx = uy*k, ux*k
            if abs(dy) >= z.shape[0] or abs(dx) >= z.shape[1]: continue
            s0, s1 = _pair(z.shape, dy, dx)
            v = m[s0] & m[s1]; n = int(v.sum())
            if n < 50: continue
            d = (z[s1] - z[s0])[v]
            mu = d.mean(); c = d - mu; m2 = float((c*c).mean())
            ns = float((s2[s0] + s2[s1])[v].mean()) if s2 is not None else np.nan
            rows.append((k*像素_m*(math.sqrt(2) if diag else 1), float((d*d).mean()), n, mu, m2,
                         float((c**3).mean())/max(m2, 1e-300)**1.5, float((c**4).mean())/max(m2, 1e-300)**2 - 3, ns))
        per[ang] = np.array(rows, float).reshape(-1, 8)
    def on_axis(a, col):
        if len(a) < 2: return np.full(len(lag_ax), np.nan)
        ok = np.isfinite(a[:, col]) & (a[:, col] > 0)
        if ok.sum() < 2: return np.full(len(lag_ax), np.nan)
        return np.exp(np.interp(np.log(lag_ax), np.log(a[ok, 0]), np.log(a[ok, col]), left=np.nan, right=np.nan))
    ms = np.vstack([on_axis(per[a], 1) for a in DIRS])
    cnt = (np.isfinite(ms)).sum(0)
    iso = np.where(cnt >= 2, np.nanmean(ms, 0), np.nan)
    ax = [per[0], per[90]]
    def axis_col(col):
        vals = []
        for a in ax:
            d = {round(r[0]/像素_m): r[col] for r in a}
            vals.append([d.get(int(L), np.nan) for L in 滞后px])
        return np.nanmean(np.array(vals, float), 0)
    out = dict(lag=lag_ax, nu=np.sqrt(iso), n=axis_col(2), skew=axis_col(5), kurt=axis_col(6),
               nu_dir={a: np.sqrt(ms[i]) for i, a in enumerate(DIRS)}, mean_incr=axis_col(3))
    if s2 is not None:
        nn = np.vstack([on_axis(per[a], 7) for a in DIRS])
        out["nu_noise"] = np.sqrt(np.nanmean(nn, 0))
        out["nu_corr"] = np.sqrt(np.clip(iso - out["nu_noise"]**2, 0, None))
    return out


def 拟合H(x, y, lo, hi):
    x, y = np.asarray(x, float), np.asarray(y, float)
    s = (x >= lo*0.999) & (x <= hi*1.001) & np.isfinite(y) & (y > 0)
    if s.sum() < 3: return None
    lx, ly = np.log10(x[s]), np.log10(y[s])
    b, a = np.polyfit(lx, ly, 1); res = ly - (a + b*lx)
    return dict(H=float(b), nu_1m=float(10**a), lo=float(x[s].min()), hi=float(x[s].max()), n=int(s.sum()),
                rms_log=float(np.sqrt(np.mean(res**2))))


def 局部H(x, y, w=3):
    x, y = np.asarray(x, float), np.asarray(y, float); ok = np.isfinite(y) & (y > 0)
    h = np.full(len(x), np.nan)
    if ok.sum() < 3: return h
    g = np.gradient(np.log(y[ok]), np.log(x[ok]))
    if w > 1: g = np.convolve(np.pad(g, w//2, mode="edge"), np.ones(w)/w, mode="valid")
    h[ok] = g; return h


def 分段拟合(x, y, 最多段=3, 最短=5, 门槛=10.0):
    """对数坐标分段直线（各段独立），段数按 BIC 选（多一段要让 BIC 降 ≥ 门槛）。返回各段 H 与断点。"""
    x, y = np.asarray(x, float), np.asarray(y, float)
    s = np.isfinite(y) & (y > 0) & np.isfinite(x)
    o = np.argsort(x[s]); lx, ly = np.log10(x[s][o]), np.log10(y[s][o]); n = len(lx)
    if n < 最短: return None
    C = np.full((n + 1, n + 1), np.inf)
    for i in range(n):
        for j in range(i + 最短, n + 1):
            p = np.polyfit(lx[i:j], ly[i:j], 1); C[i, j] = float(np.sum((ly[i:j] - np.polyval(p, lx[i:j]))**2))
    D = [C[0].copy()]; arg = [None]
    for K in range(2, 最多段 + 1):
        prev = D[-1]; cur = np.full(n + 1, np.inf); a = np.zeros(n + 1, int)
        for j in range(n + 1):
            v = prev[:j] + C[:j, j] if j else np.array([np.inf])
            if len(v): a[j] = int(np.argmin(v)); cur[j] = v[a[j]]
        D.append(cur); arg.append(a)
    bic = [n*math.log(D[K - 1][n]/n + 1e-10) + (3*K - 1)*math.log(n) for K in range(1, 最多段 + 1)]
    K = 1
    for k in range(2, 最多段 + 1):
        if np.isfinite(bic[k - 1]) and bic[k - 1] < bic[K - 1] - 门槛: K = k
    cuts = [n]; j = n
    for k in range(K, 1, -1):
        j = arg[k - 1][j]; cuts.insert(0, j)
    cuts.insert(0, 0)
    X = 10**lx; segs = []
    for i, j in zip(cuts[:-1], cuts[1:]):
        p = np.polyfit(lx[i:j], ly[i:j], 1)
        segs.append(dict(H=float(p[0]), lo=float(X[i]), hi=float(X[j - 1]), nu_1m=float(10**p[1])))
    brk = [float(math.sqrt(X[j - 1]*X[j])) for j in cuts[1:-1]]
    return dict(段=segs, 断点=brk, BIC=bic)


def 噪声拟合(lag, nu, hi):
    """ν² = a·h^(2H) + 2σ²：同时估 Hurst 与白噪声 σ（只用 lag ≤ hi）。"""
    from scipy.optimize import least_squares
    lag, nu = np.asarray(lag, float), np.asarray(nu, float)
    s = (lag <= hi) & np.isfinite(nu) & (nu > 0)
    if s.sum() < 5: return None
    h, v = lag[s], nu[s]
    f = lambda p: 0.5*np.log(np.exp(p[0])*h**(2*p[1]) + 2*np.exp(2*p[2])) - np.log(v)
    p0 = [np.log(v[-1]**2/h[-1]**0.8), 0.4, np.log(v[0]/2)]
    r = least_squares(f, p0, bounds=([-50, 0.0, -30], [50, 1.5, 5]))
    return dict(H=float(r.x[1]), sigma=float(np.exp(r.x[2])), rms_log=float(np.sqrt(np.mean(r.fun**2))))


def 满块(m, 块, 步=None):
    步 = 步 or 块//2; bad = (~m).astype(np.int64)
    S = np.zeros((m.shape[0] + 1, m.shape[1] + 1), np.int64); S[1:, 1:] = bad.cumsum(0).cumsum(1)
    out = []
    for i in range(0, m.shape[0] - 块 + 1, 步):
        for j in range(0, m.shape[1] - 块 + 1, 步):
            if S[i + 块, j + 块] - S[i, j + 块] - S[i + 块, j] + S[i, j] == 0: out.append((i, j))
    return out


def 功率谱(z, 像素_m, 掩膜=None, 块=256, 最多块=400):
    """完全有数据的方块（半重叠）里的二维周期图（去平面 + Hann），归一到 Σ P Δk² ≈ 方差；径向对数分箱平均。"""
    z = np.asarray(z, np.float64); m = np.isfinite(z) if 掩膜 is None else (np.asarray(掩膜, bool) & np.isfinite(z))
    tiles = 满块(m, 块)
    if not tiles: return None
    if len(tiles) > 最多块: tiles = [tiles[i] for i in np.linspace(0, len(tiles) - 1, 最多块).astype(int)]
    w1 = np.hanning(块); w = np.outer(w1, w1)
    g = np.arange(块) - 块/2; A = np.stack([np.ones(块*块), np.tile(g, 块), np.repeat(g, 块)], 1); Ap = np.linalg.pinv(A)
    P2 = np.zeros((块, 块))
    for i, j in tiles:
        t = z[i:i + 块, j:j + 块]; c = Ap @ t.ravel(); t = t - (A @ c).reshape(块, 块)
        P2 += np.abs(np.fft.fft2(t*w))**2
    P2 *= 像素_m**2/np.sum(w**2)/len(tiles)
    k1 = np.fft.fftfreq(块, 像素_m); KX, KY = np.meshgrid(k1, k1); K = np.hypot(KX, KY)
    edges = np.geomspace(1/(块*像素_m), 0.5/像素_m, 30); kc, Pc = [], []
    for a, b in zip(edges[:-1], edges[1:]):
        s = (K >= a) & (K < b)
        if s.any(): kc.append(math.sqrt(a*b)); Pc.append(P2[s].mean())
    kc, Pc = np.array(kc), np.array(Pc)
    f = 拟合H(kc, Pc, 4/(块*像素_m), 0.25/像素_m)
    H = None if f is None else dict(beta=-f["H"], H=(-f["H"] - 2)/2, lo_k=f["lo"], hi_k=f["hi"])
    return dict(k=kc, P=Pc, 块=块, n块=len(tiles), 拟合=H, P2=np.fft.fftshift(P2), k1=np.fft.fftshift(k1))


def 波纹峰(谱):
    """二维谱除以同 |k| 的径向均值，找最突出的峰：波长 1/|k|，波矢方向 θk，波峰线方向 θk + 90°（自东逆时针，0–180°）。"""
    if 谱 is None: return None
    P2, k1 = 谱["P2"], 谱["k1"]; KX, KY = np.meshgrid(k1, k1); K = np.hypot(KX, KY)
    dk = k1[1] - k1[0]; kb = np.round(K/dk).astype(int)
    rad = np.bincount(kb.ravel(), P2.ravel())/np.maximum(np.bincount(kb.ravel()), 1)
    R = P2/np.maximum(rad[kb], 1e-300)
    s = (kb >= 3) & (K <= 0.3*k1.max()*2)
    i = np.argmax(np.where(s, R, -1))
    kx, ky = KX.ravel()[i], KY.ravel()[i]; th = math.degrees(math.atan2(ky, kx)) % 180
    # 方向性：同一 |k| 环上的最大/均值；以及峰附近 ±2 环的平均突出度
    return dict(突出度=float(R.ravel()[i]), 波长_m=float(1/max(K.ravel()[i], 1e-12)), 波矢方向_deg=th,
                波峰线方向_deg=(th + 90) % 180, 波峰线方位角_deg=(90 - (th + 90)) % 180)


def 变差图2D(z, 掩膜, 最大px):
    """掩膜 FFT 二维变差图（Marcotte 1996）：返回 (2L+1)² 的 ν²(dy, dx)（中心为 0 滞后；行＝北向位移、列＝东向位移）与点对数。"""
    from scipy.fft import rfft2, irfft2, next_fast_len
    m = np.asarray(掩膜, bool) & np.isfinite(z); L = int(最大px)
    z0 = np.where(m, z - np.nanmean(np.where(m, z, np.nan)), 0.0); mf = m.astype(np.float64)
    sh = (next_fast_len(z.shape[0] + L + 1), next_fast_len(z.shape[1] + L + 1))
    M = rfft2(mf, sh); F = rfft2(z0, sh); F2 = rfft2(z0*z0, sh)
    corr = lambda A_, B_: irfft2(np.conj(A_)*B_, sh)
    N = corr(M, M); S = corr(M, F2) + corr(F2, M) - 2*corr(F, F)
    iy = np.r_[sh[0] - L:sh[0], 0:L + 1]; ix = np.r_[sh[1] - L:sh[1], 0:L + 1]
    N = N[np.ix_(iy, ix)]; S = S[np.ix_(iy, ix)]
    g = np.where(N > 50, S/np.maximum(N, 1), np.nan)
    return g, N


def 径向切向(z, cs, m, X, Y, 中心, 滞后_m, 容差=22.5):
    """以 中心（桅杆）为原点：滞后方向与锚点径向夹角 < 容差 的点对算「径向」ν，> 90 − 容差 的算「切向」ν。
    立体测距误差沿视线（径向），若各向异性来自它，径向/切向比会 > 1 且与绝对方向无关。"""
    out = []
    phi = np.arctan2(Y - 中心[1], X - 中心[0])
    for l in 滞后_m:
        acc = {"径向": [0.0, 0], "切向": [0.0, 0]}
        for ang, (uy, ux) in DIRS.items():
            diag = bool(uy and ux); k = max(1, int(round(l/cs/(math.sqrt(2) if diag else 1))))
            s0, s1 = _pair(z.shape, uy*k, ux*k); v = m[s0] & m[s1]
            d2 = (z[s1] - z[s0])**2
            dl = np.abs(((math.radians(ang) - phi[s0] + np.pi/2) % np.pi) - np.pi/2)      # 0＝径向，π/2＝切向
            for nm_, sel in (("径向", dl < math.radians(容差)), ("切向", dl > math.radians(90 - 容差))):
                q = v & sel; acc[nm_][0] += float(d2[q].sum()); acc[nm_][1] += int(q.sum())
        nr, nt = math.sqrt(acc["径向"][0]/max(acc["径向"][1], 1)), math.sqrt(acc["切向"][0]/max(acc["切向"][1], 1))
        out.append(dict(滞后_m=l, 径向=nr, 切向=nt, 径向比切向=nr/max(nt, 1e-12), n=(acc["径向"][1], acc["切向"][1])))
    return out


def 方向谱(g2, 半径px, 角=None):
    from scipy.ndimage import map_coordinates
    角 = np.arange(0, 180, 7.5) if 角 is None else 角; L = (g2.shape[0] - 1)//2; t = np.radians(角)
    v = map_coordinates(np.nan_to_num(g2, nan=0.0), [L + 半径px*np.sin(t), L + 半径px*np.cos(t)], order=1)
    return 角, np.sqrt(np.maximum(v, 0))


def 坡度统计(z, 像素_m, 掩膜, 基线_m, 直方=True):
    """基线 B 上的坡度：同一锚点的东向、北向前向差分 / B。分量合并统计（RMS、超额峰度、偏度、广义高斯形状 β：2＝高斯、1＝拉普拉斯），
    以及坡度角（由两分量合成）的分位数。"""
    from scipy import stats
    L = max(1, int(round(基线_m/像素_m))); B = L*像素_m; H, W = z.shape
    if L >= min(H, W)//2: return None
    a = (slice(0, H - L), slice(0, W - L)); ex = (slice(0, H - L), slice(L, W)); ny = (slice(L, H), slice(0, W - L))
    v = 掩膜[a] & 掩膜[ex] & 掩膜[ny]
    if v.sum() < 200: return None
    sx = (z[ex] - z[a])[v]/B; sy = (z[ny] - z[a])[v]/B
    c = np.concatenate([sx - sx.mean(), sy - sy.mean()]); sd = c.std()
    ang = np.degrees(np.arctan(np.hypot(sx, sy)))
    sub = c[np.linspace(0, len(c) - 1, min(len(c), 60000)).astype(np.int64)]
    beta, _, sc = stats.gennorm.fit(sub/sd, floc=0)
    out = dict(基线_m=B, n=int(v.sum()), rms=float(np.sqrt(np.mean(c**2))), rms_deg=float(np.degrees(np.arctan(np.sqrt(np.mean(c**2))))),
               峰度=float(stats.kurtosis(c)), 偏度=float(stats.skew(c)), 广义高斯β=float(beta),
               角_中位=float(np.median(ang)), 角_均值=float(ang.mean()), 角_p90=float(np.percentile(ang, 90)), 角_p99=float(np.percentile(ang, 99)),
               超15度=float(np.mean(ang > 15)), 超30度=float(np.mean(ang > 30)))
    if 直方:
        e = np.linspace(-8, 8, 81); h, _ = np.histogram(c/sd, e, density=True); out["直方"] = dict(edges=e, pdf=h)
    return out


def 残差统计(z, 像素_m, 掩膜, 尺度_m):
    """高通残差 z − G_σ*z（掩膜归一化高斯，σ＝尺度）的分布形状；只用邻域有效权重 > 0.8 的格。"""
    from scipy import stats
    out = []
    for s in 尺度_m:
        lo, w = 归一卷积(z, 掩膜, s/像素_m); r = (z - lo); v = 掩膜 & (w > 0.8)
        if v.sum() < 500: continue
        x = r[v]
        out.append(dict(尺度_m=s, n=int(v.sum()), std=float(x.std()), 偏度=float(stats.skew(x)), 峰度=float(stats.kurtosis(x)),
                        p01=float(np.percentile(x, 1)), p99=float(np.percentile(x, 99))))
    return out


def 指纹(高程, 像素_m, 掩膜=None, 噪声=None, 去趋势=True, 滞后px=None, 坡度基线_m=(0.02, 0.1, 1.0, 5.0), 残差尺度_m=None,
       各向异性=True, 谱块=None):
    """一块高程的多尺度统计指纹。高程：二维数组（行＝自南向北、列＝自西向东，m）；像素_m：格距；掩膜：True＝有数据；
    噪声：每格 σ（m）或 None。生成器的输出与真实数据都过这个函数，再用 比较() 对照。"""
    z = np.asarray(高程, np.float64); m = np.isfinite(z) if 掩膜 is None else (np.asarray(掩膜, bool) & np.isfinite(z))
    if 去趋势: z, plane = 去平面(z, m)
    else: z = np.where(m, z, 0.0); plane = None
    ys, xs = np.nonzero(m); ext = min(ys.max() - ys.min() + 1, xs.max() - xs.min() + 1)
    sf = 结构函数(z, 像素_m, m, 滞后px if 滞后px is not None else 滞后表(max(ext//4, 2)), 噪声)
    nu = sf.get("nu_corr", sf["nu"])
    out = dict(像素_m=像素_m, 有效格=int(m.sum()), 范围_m=float(ext*像素_m), 平面=plane, 结构函数=sf,
               H_全段=拟合H(sf["lag"], nu, sf["lag"][0], sf["lag"][-1]), H_分段=分段拟合(sf["lag"], nu), 局部H=局部H(sf["lag"], nu))
    out["坡度"] = [s for s in (坡度统计(z, 像素_m, m, b) for b in 坡度基线_m if 像素_m*0.99 <= b <= ext*像素_m/8) if s]
    if 残差尺度_m is None: 残差尺度_m = [像素_m*k for k in (4, 16, 64) if 像素_m*k*8 <= ext*像素_m]
    out["残差"] = 残差统计(z, 像素_m, m, 残差尺度_m)
    if 各向异性:
        L = int(min(ext//4, 256)); g2, _ = 变差图2D(z, m, L); an = []
        for rp in sorted({max(2, L//16), max(3, L//4), L}):
            a, v = 方向谱(g2, rp)
            if np.all(v > 0):
                an.append(dict(滞后_m=rp*像素_m, 角_deg=a, nu=v, 比=float(v.max()/v.min()), 最小方向_deg=float(a[np.argmin(v)]),
                               最大方向_deg=float(a[np.argmax(v)])))
        out["各向异性"] = an; out["_g2"] = g2
    blk = 谱块 or next((b for b in (512, 256, 128, 64) if b <= ext//2 and 满块(m, b)), None)
    out["谱"] = 功率谱(z, 像素_m, m, blk) if blk else None
    return out


def 比较(a, b):
    """两份指纹的差异：共同滞后上 log10(ν_b/ν_a) 的均值/最大绝对值，各基线坡度 RMS 比、峰度差，全段 H 差。"""
    la, lb = np.asarray(a["结构函数"]["lag"]), np.asarray(b["结构函数"]["lag"])
    na = np.asarray(a["结构函数"].get("nu_corr", a["结构函数"]["nu"])); nb = np.asarray(b["结构函数"].get("nu_corr", b["结构函数"]["nu"]))
    lo, hi = max(la.min(), lb.min()), min(la.max(), lb.max()); g = np.geomspace(lo, hi, 20)
    ia = np.interp(np.log(g), np.log(la), np.log(np.maximum(na, 1e-12))); ib = np.interp(np.log(g), np.log(lb), np.log(np.maximum(nb, 1e-12)))
    d = (ib - ia)/math.log(10)
    sl = []
    for s in a["坡度"]:
        t = next((u for u in b["坡度"] if abs(u["基线_m"] - s["基线_m"]) < 1e-6), None)
        if t: sl.append(dict(基线_m=s["基线_m"], rms比=t["rms"]/s["rms"], 峰度差=t["峰度"] - s["峰度"]))
    return dict(滞后_m=g, log10比=d, 均值log10比=float(np.mean(d)), 最大abs=float(np.max(np.abs(d))),
                H差=(b["H_全段"]["H"] - a["H_全段"]["H"]) if a["H_全段"] and b["H_全段"] else None, 坡度=sl)


# ── ② 石块与点格局 ─────────────────────────────────────────────────
def golombek_F(D, k):
    """Golombek & Rapp 1997：直径 ≥ D 的石块累计覆盖率。"""
    return k*np.exp(-(1.79 + 0.152/k)*np.asarray(D, float))


def golombek_N(D, k, Dmax=5.0):
    """直径 ≥ D 的石块数 / m²（对 dF/dD ÷ 单块面积积分）。"""
    q = 1.79 + 0.152/k; out = []
    for d in np.atleast_1d(D):
        x = np.geomspace(d, Dmax, 400); f = k*q*np.exp(-q*x)/(math.pi*x*x/4)
        out.append(np.trapezoid(f, x))
    return np.array(out)


def 拟合k(D, 面积, Dmin, Dmax=1.5):
    """按累计覆盖率曲线拟合 Golombek k（对数残差最小二乘，k 网格搜索）。"""
    D = np.sort(np.asarray(D, float))[::-1]; F = np.cumsum(math.pi*D**2/4)/面积
    s = (D >= Dmin) & (D <= Dmax)
    if s.sum() < 3: return None
    ks = np.geomspace(1e-3, 0.5, 3000)
    err = [np.mean((np.log(F[s]) - np.log(golombek_F(D[s], k)))**2) for k in ks]
    i = int(np.argmin(err)); k = float(ks[i])
    return dict(k=k, rms_log=float(math.sqrt(err[i])), n=int(s.sum()), Dmin=Dmin, F_at_Dmin=float(F[s][-1]),
                k_单点=float(_k_from_F(F[s][-1], D[s][-1])))


def _k_from_F(F, D):
    ks = np.geomspace(1e-4, 0.8, 20000); return ks[np.argmin(np.abs(golombek_F(D, ks) - F))]


def 点格局(pts, 窗口, X, Y, cs, nsim=199, r_bins=None, seed=0, 强度=None):
    """最近邻比（Clark–Evans，用同一不规则窗口里的泊松模拟作参照，避免边缘偏差）与对相关 g(r)（数据 / 模拟均值）。
    强度：每格相对强度（非均匀泊松零假设，例如按地类的石块密度），None＝均匀。"""
    from scipy.spatial import cKDTree
    from scipy.spatial.distance import pdist
    rng = np.random.default_rng(seed); n = len(pts)
    if n < 10: return None
    r_bins = np.geomspace(0.05, 3.0, 16) if r_bins is None else r_bins
    def nn(p): d, _ = cKDTree(p).query(p, k=2); return d[:, 1].mean()
    def hist(p): return np.histogram(pdist(p), r_bins)[0].astype(float)
    cells = np.flatnonzero(窗口.ravel()); xs, ys = X.ravel()[cells], Y.ravel()[cells]
    obs_nn, obs_h = nn(pts), hist(pts); sim_nn, sim_h = [], []
    pr = None
    if 强度 is not None:
        pr = np.maximum(强度.ravel()[cells].astype(np.float64), 0); pr /= pr.sum()
    for _ in range(nsim):
        i = rng.integers(0, len(cells), n) if pr is None else rng.choice(len(cells), n, p=pr)
        p = np.stack([xs[i] + rng.uniform(-cs/2, cs/2, n), ys[i] + rng.uniform(-cs/2, cs/2, n)], 1)
        sim_nn.append(nn(p)); sim_h.append(hist(p))
    sim_nn = np.array(sim_nn); sim_h = np.array(sim_h); mh = sim_h.mean(0)
    g = obs_h/np.maximum(mh, 1e-9); lo, hi = np.percentile(sim_h/np.maximum(mh, 1e-9), [2.5, 97.5], 0)
    area = 窗口.sum()*cs*cs
    return dict(n=n, 面积_m2=area, 密度=n/area, 最近邻_均=obs_nn, 最近邻_泊松=float(sim_nn.mean()), R=float(obs_nn/sim_nn.mean()),
                R_经典=float(obs_nn/(0.5/math.sqrt(n/area))), p_聚集=float(np.mean(sim_nn <= obs_nn)),
                r=np.sqrt(r_bins[1:]*r_bins[:-1]), g=g, g_lo=lo, g_hi=hi)


# ── ③ 自检（合成数据）──────────────────────────────────────────────
def fBm(n, H, 像素_m, seed=0, nu1=0.01):
    """谱合成 fBm（周期）：|F| ∝ |k|^−(H+1)；缩放到 ν(1 m) ≈ nu1。"""
    rng = np.random.default_rng(seed); k1 = np.fft.fftfreq(n, 像素_m); K = np.hypot(*np.meshgrid(k1, k1)); K[0, 0] = np.inf
    z = np.real(np.fft.ifft2((rng.normal(size=(n, n)) + 1j*rng.normal(size=(n, n)))*K**-(H + 1)))
    L = max(1, int(round(min(1.0, n*像素_m/16)/像素_m))); v = np.sqrt(np.mean((z[:, L:] - z[:, :-L])**2))
    return z*nu1/v*(L*像素_m)**H


def 自检():
    t0 = time.time(); R = {}; rng = np.random.default_rng(1); n, px = 1024, 0.02
    from scipy.ndimage import gaussian_filter
    holes = gaussian_filter(rng.normal(size=(n, n)), 12) > 0.004                 # 约 40% 的成片空洞
    for H in (0.3, 0.5, 0.8):                                             # 4096² 周期 fBm 里切 1024²（不周期，含更低频，像真实窗口）
        z = fBm(4*n, H, px, seed=int(H*10))[:n, :n]
        a = 指纹(z, px, 各向异性=False); b = 指纹(z, px, ~holes, 各向异性=False)
        fa = 拟合H(a["结构函数"]["lag"], a["结构函数"]["nu"], 4*px, n*px/16); fb = 拟合H(b["结构函数"]["lag"], b["结构函数"]["nu"], 4*px, n*px/16)
        R[f"fBm_H{H}"] = dict(真H=H, 结构函数H=fa["H"], 结构函数H_挖洞40pct=fb["H"], 挖洞比例=float(holes.mean()),
                              谱H=a["谱"]["拟合"]["H"] if a["谱"] else None,
                              挖洞后ν偏差_最大pct=float(np.nanmax(np.abs(b["结构函数"]["nu"]/a["结构函数"]["nu"] - 1))*100),
                              坡度峰度_2cm=a["坡度"][0]["峰度"], 广义高斯β_2cm=a["坡度"][0]["广义高斯β"], 残差偏度=[r["偏度"] for r in a["残差"]])
        if H == 0.5: R["_曲线_fBm"] = dict(lag=a["结构函数"]["lag"], nu=a["结构函数"]["nu"], nu_holes=b["结构函数"]["nu"],
                                           k=a["谱"]["k"], P=a["谱"]["P"])
    # 白噪声：ν 应平坦 = √2·σ，H ≈ 0；带噪声图时 ν_corr ≈ 0
    sig = 0.005; w = rng.normal(0, sig, (n, n)); a = 指纹(w, px, 噪声=np.full((n, n), sig), 各向异性=False)
    R["白噪声"] = dict(sigma=sig, 期望nu=math.sqrt(2)*sig, nu_中位=float(np.nanmedian(a["结构函数"]["nu"])),
                    H=拟合H(a["结构函数"]["lag"], a["结构函数"]["nu"], px, n*px/8)["H"], nu_noise_中位=float(np.nanmedian(a["结构函数"]["nu_noise"])),
                    nu_corr_中位=float(np.nanmedian(a["结构函数"]["nu_corr"])), 谱β=a["谱"]["拟合"]["beta"])
    R["_曲线_白"] = dict(lag=a["结构函数"]["lag"], nu=a["结构函数"]["nu"])
    # fBm + 白噪声：噪声拟合要同时找回 H 与 σ
    z = fBm(n, 0.6, px, seed=5, nu1=0.02) + rng.normal(0, 0.003, (n, n)); a = 结构函数(去平面(z, np.ones_like(z, bool))[0], px)
    f = 噪声拟合(a["lag"], a["nu"], n*px/8); R["fBm加噪"] = dict(真H=0.6, 真sigma=0.003, 估H=f["H"], 估sigma=f["sigma"])
    R["_曲线_加噪"] = dict(lag=a["lag"], nu=a["nu"])
    # 斜面：去平面后 ν 不变
    yy, xx = np.mgrid[0:n, 0:n]*px; z = fBm(n, 0.5, px, seed=7); a = 指纹(z, px, 各向异性=False); b = 指纹(z + 0.2*xx - 0.1*yy, px, 各向异性=False)
    R["斜面"] = dict(最大ν偏差pct=float(np.nanmax(np.abs(b["结构函数"]["nu"]/a["结构函数"]["nu"] - 1))*100))
    # 掩膜 FFT 变差图与直接平移在轴向滞后上应一致
    g2, _ = 变差图2D(z, ~holes, 64); s = 结构函数(np.where(~holes, z, 0), px, ~holes, np.array([1, 4, 16, 64]))
    R["变差图FFT对直接"] = dict(最大相对差=float(max(abs(math.sqrt(g2[64, 64 + L]) / s["nu_dir"][0][i] - 1) for i, L in enumerate([1, 4, 16, 64]))))
    # 波纹：λ = 0.3 m、波峰线 30°（波矢 120°）+ 弱 fBm → 谱峰与变差图最小方向
    th = math.radians(120); zr = 0.01*np.sin(2*np.pi*(xx*math.cos(th) + yy*math.sin(th))/0.3) + fBm(n, 0.5, px, seed=9, nu1=0.003)
    a = 指纹(zr, px, 谱块=256, 各向异性=False); pk = 波纹峰(a["谱"])
    g2, _ = 变差图2D(zr, np.ones_like(zr, bool), 32); ang, v = 方向谱(g2, 0.15/px)                 # 半个波长处：沿波峰线最小、垂直最大
    R["波纹"] = dict(真波长=0.3, 真波峰线=30.0, 估=pk, 变差图最小方向_deg=float(ang[np.argmin(v)]), 变差图最大方向_deg=float(ang[np.argmax(v)]), 比=float(v.max()/v.min()))
    # 石块场（fBm + 稀疏凸起）：残差正偏、坡度重尾
    zb = fBm(n, 0.5, px, seed=11, nu1=0.005); cx, cy = rng.uniform(0, n*px, (2, 400))
    for x0, y0 in zip(cx, cy): zb += 0.05*np.clip(1 - ((xx - x0)**2 + (yy - y0)**2)/0.08**2, 0, None)**0.5
    a = 指纹(zb, px, 各向异性=False)
    R["石块场"] = dict(残差偏度=[r["偏度"] for r in a["残差"]], 坡度峰度=[(s["基线_m"], s["峰度"], s["广义高斯β"]) for s in a["坡度"]])
    # 点格局：同一不规则窗口里的泊松点 R ≈ 1；托马斯聚集过程 R < 1
    c = (np.arange(500) + 0.5)*0.02; X, Y = np.meshgrid(c, c); win = gaussian_filter(rng.normal(size=(500, 500)), 10) > -0.003
    cells = np.flatnonzero(win.ravel()); i = rng.integers(0, len(cells), 150)
    p = np.stack([X.ravel()[cells[i]], Y.ravel()[cells[i]]], 1); P1 = 点格局(p, win, X, Y, 0.02, nsim=99)
    Rs = []
    for sd in range(20):                                                  # 零假设下 R 的分布（20 次独立泊松样本）
        r2 = np.random.default_rng(100 + sd); i = r2.integers(0, len(cells), 150)
        q = np.stack([X.ravel()[cells[i]] + r2.uniform(-0.01, 0.01, 150), Y.ravel()[cells[i]] + r2.uniform(-0.01, 0.01, 150)], 1)
        Rs.append(点格局(q, win, X, Y, 0.02, nsim=49, seed=sd)["R"])
    par = rng.choice(len(cells), 15); ch = []
    for j in par:
        for _ in range(10): ch.append([X.ravel()[cells[j]] + rng.normal(0, 0.15), Y.ravel()[cells[j]] + rng.normal(0, 0.15)])
    ch = np.array(ch); ix_ = np.floor(ch/0.02).astype(int); inside = (ix_ >= 0).all(1) & (ix_ < 500).all(1)
    ch = ch[inside]; ch = ch[win[ix_[inside, 1], ix_[inside, 0]]]                 # 只留窗口里的子点
    P2 = 点格局(ch, win, X, Y, 0.02, nsim=99)
    R["点格局"] = dict(泊松_R=P1["R"], 泊松_p=P1["p_聚集"], 泊松20次_R均值=float(np.mean(Rs)), 泊松20次_R标准差=float(np.std(Rs)),
                     托马斯_R=P2["R"], 托马斯_p=P2["p_聚集"])
    # Golombek：按 k = 0.05 抽石块（≥ 5 cm），在 300 m² 上拟合
    kt = 0.05; A = 300.0; Dg = np.geomspace(0.05, 3, 2000); Nc = golombek_N(Dg, kt)
    nt = rng.poisson(Nc[0]*A); u = rng.random(nt); D = np.interp(u, (Nc/Nc[0])[::-1], Dg[::-1])
    f = 拟合k(D, A, 0.10)
    R["Golombek"] = dict(真k=kt, 估k=f["k"], 单点k=f["k_单点"], 石块数=int(nt))
    log(f"自检 ✓（{time.time() - t0:.0f} s）")
    return R


# ── ④ 噪声实测（奇/偶 sol 两组网格）────────────────────────────────────
NOISE_GRIDS = {"近": (0.02, 1000), "中": (0.10, 1000)}


def 噪声栅格():
    path = OUT/"缓存_噪声栅格.npz"
    if path.exists(): return dict(np.load(path))
    M = m57(); t0 = time.time(); R_ = M.rover_R()
    acc = {f"{lv}_{s}_{g}": np.zeros(n*n) for lv, (cs, n) in NOISE_GRIDS.items() for s in ("S", "N") for g in (0, 1)}
    files = M.objs(); nv = [0, 0]
    for fi, p in enumerate(files):
        sol = int(p.name.split("_")[1]); g = sol % 2
        P = M.to_enu(M.obj_vertices(p))
        r = np.linalg.norm(P - M.MAST_ENU, axis=1); P = P[(r > 1.0) & (r < 150)]
        Q = (P @ M.M_SB) @ R_; up = -Q[:, 2]
        body = (Q[:, 0] > -1.8) & (Q[:, 0] < 2.4) & (np.abs(Q[:, 1]) < 1.4) & (up > 0.20)
        arm = (Q[:, 0] >= 2.4) & (Q[:, 0] < 3.4) & (np.abs(Q[:, 1]) < 1.4) & (up > 0.45)
        P = P[~(body | arm)]; nv[g] += len(P)
        for lv, (cs, n) in NOISE_GRIDS.items():
            half = cs*n/2; s = (np.abs(P[:, 0]) < half) & (np.abs(P[:, 1]) < half)
            k = np.floor(P[s, 1]/cs + n/2).astype(np.int64)*n + np.floor(P[s, 0]/cs + n/2).astype(np.int64)
            acc[f"{lv}_S_{g}"] += np.bincount(k, P[s, 2], n*n); acc[f"{lv}_N_{g}"] += np.bincount(k, None, n*n)
        if fi % 10 == 0: log(f"  网格 {fi + 1}/{len(files)}（{time.time() - t0:.0f} s）")
    out = {k: v.reshape(NOISE_GRIDS[k.split("_")[0]][1], -1).astype(np.float64) for k, v in acc.items()}
    out["顶点数"] = np.array(nv); out["文件数"] = np.array(len(files))
    OUT.mkdir(parents=True, exist_ok=True); np.savez_compressed(path, **out)
    log(f"噪声栅格：{len(files)} 块网格，奇/偶 sol 顶点 {nv[1]:,}/{nv[0]:,}（{time.time() - t0:.0f} s）")
    return out


def 噪声差场(G, lv):
    """两组格内平均之差 d（两组都有数据的格）；剔 |d − 局部中位| > 6·MAD 的离群（石块边缘的混合格）。"""
    cs, n = NOISE_GRIDS[lv]
    za = G[f"{lv}_S_0"]/np.maximum(G[f"{lv}_N_0"], 1); zb = G[f"{lv}_S_1"]/np.maximum(G[f"{lv}_N_1"], 1)
    both = (G[f"{lv}_N_0"] > 0) & (G[f"{lv}_N_1"] > 0); d = np.where(both, za - zb, 0.0)
    mad = 1.4826*np.median(np.abs(d[both] - np.median(d[both])))
    ok = both & (np.abs(d - np.median(d[both])) < 6*max(mad, 1e-4) + 0.02)
    return d, ok, float(1 - ok.sum()/max(both.sum(), 1))


# ── ⑤ sol 530 数据 ─────────────────────────────────────────────────
def 网格坐标(cs, n, mast):
    c = (np.arange(n) + 0.5 - n/2)*cs; X, Y = np.meshgrid(c, c); return X, Y, np.hypot(X - mast[0], Y - mast[1])


def sig_m(r):
    """57 中层归一化卷积的平滑 σ（m），8 m 内为 0。"""
    return np.clip(0.004*np.maximum(np.asarray(r, float) - 8, 0)**1.5, 0, 1.5)


def ctx_窗口(半宽_m=20000):
    """原始 CTX DTM（eqc，lat_ts = 站点纬度，格距 20 m 等面积）以站点为中心的窗口；翻成第 0 行在南。"""
    M = m57(); a = np.load(DIR/"ctx_dtm_20m.npy", mmap_mode="r"); m = json.loads((DIR/"ctx_dtm_20m.json").read_text()); t = m["transform"]
    lat_ts = math.radians(18.4663)
    x = R_MARS*math.radians(M.LON)*math.cos(lat_ts); y = R_MARS*math.radians(M.LAT)
    col = int((x - t[2])/t[0]); row = int((y - t[5])/t[4]); h = int(半宽_m/20)
    z = np.asarray(a[row - h:row + h, col - h:col + h], np.float64)
    bad = ~np.isfinite(z) | (z < -1e30)
    return np.flipud(np.where(bad, np.nan, z)), np.flipud(~bad)


def 层_ν(z, cs, m, 噪声=None, 最大_m=None, 每十倍=10):
    ys, xs = np.nonzero(m); ext = min(ys.max() - ys.min() + 1, xs.max() - xs.min() + 1)
    Lmax = int((最大_m/cs) if 最大_m else ext//4)
    z0, _ = 去平面(z, m)
    return 结构函数(z0, cs, m, 滞后表(max(Lmax, 2), 每十倍), 噪声)


def 带通相关(A, Z, m, cs, 尺度_m):
    """反照率（取 log）与高程、坡度在同一频段的相关：DoG 带通 G_σ − G_2σ（掩膜归一化）。坡度＝|∇(G_σ*Z)|，也做同样带通。
    另给反照率与东向/北向坡度分量的相关（去光影残留会表现为有方向的相关）。"""
    from scipy.ndimage import gaussian_filter
    la = np.log(np.maximum(A, 1e-4)); out = []
    for s in 尺度_m:
        sp = s/cs
        a1, w1 = 归一卷积(la, m, sp); a2, w2 = 归一卷积(la, m, 2*sp); bA = a1 - a2
        z1, _ = 归一卷积(Z, m, sp); z2, _ = 归一卷积(Z, m, 2*sp); bZ = z1 - z2
        gy, gx = np.gradient(z1, cs); S = np.hypot(gx, gy)
        S2, _ = 归一卷积(S, m, 2*sp); bS = S - S2
        v = m & (w2 > 0.8) & (w1 > 0.8)
        if v.sum() < 1000: continue
        cc = lambda p, q: float(np.corrcoef(p[v], q[v])[0, 1])
        n_eff = v.sum()*cs*cs/(math.pi*(2*s)**2)                              # 带通场的相关面积 ≈ π(2σ)²
        out.append(dict(尺度_m=s, n=int(v.sum()), 有效样本=float(n_eff), 标准误=float(1/math.sqrt(max(n_eff - 3, 1))), 反照率_高程=cc(bA, bZ), 反照率_坡度=cc(bA, bS), 反照率_东坡=cc(bA, gx), 反照率_北坡=cc(bA, gy),
                        反照率带通rms=float(bA[v].std()), 高程带通rms=float(bZ[v].std())))
    return out


def 全部():
    from scipy.ndimage import binary_dilation
    t0 = time.time(); OUT.mkdir(parents=True, exist_ok=True); M = m57()
    T = np.load(REC/"地形.npz"); L = json.loads(str(T["levels"])); mast = T["mast"][:2]
    R = dict(数据=dict(levels=L, align_HiRISE=T["align"], mast=T["mast"], 说明="近/中/HiRISE 都是绝对高程（ENU，z=0 为海拔 −2523.168 m），"
                      "近/中＝先验（上一层）+ 立体残差的加权均值，无数据格是 push-pull 补的；近/中 _w＝格内样本权重和 Σ1/σ²（中层 8 m 外含归一化卷积扩散的权重）"))
    (csn, nn), (csm, nm), (csh, nh) = L["近"], L["中"], L["HiRISE"]
    Xn, Yn, rn = 网格坐标(csn, nn, mast); Xm, Ym, rm = 网格坐标(csm, nm, mast)
    rov_n = M.under_rover(Xn, Yn); rov_m = M.under_rover(Xm, Ym)
    near = T["near"].astype(np.float64); Wn = T["near_w"]; mid = T["mid"].astype(np.float64); Wm = T["mid_w"]
    # 噪声实测
    G = 噪声栅格(); NZ = {}
    for lv, rings in (("近", ((1, 3), (3, 6), (6, 9))), ("中", ((3, 8), (8, 15), (15, 25), (25, 45)))):
        cs, n = NOISE_GRIDS[lv]; X_, Y_, r_ = 网格坐标(cs, n, mast); d, ok, out_frac = 噪声差场(G, lv)
        for a, b in rings:
            s = ok & (r_ >= a) & (r_ < b) & ~M.under_rover(X_, Y_)
            if s.sum() < 2000: continue
            sf = 结构函数(np.where(s, d, 0), cs, s, 滞后表(int(min((b - a), 4.0)/cs), 8))
            NZ[f"{lv}_{a}-{b}m"] = dict(lag=sf["lag"], nu_d=sf["nu"], nu_噪=sf["nu"]/2, 格数=int(s.sum()), 离群比例=out_frac,
                                       点σ_组=float(np.std(d[s])/math.sqrt(2)), 模型σ_中点=0.003 + 2.4e-4*((a + b)/2)**2)
    R["噪声"] = NZ; log("噪声：" + "，".join(f"{k} ν噪(首滞后) {v['nu_噪'][0]*1000:.1f} mm" for k, v in NZ.items()))

    def noise_curve(key, lag):
        v = NZ.get(key)
        if v is None: return np.full(len(lag), np.nan)
        return np.exp(np.interp(np.log(lag), np.log(v["lag"]), np.log(v["nu_噪"])))       # 超出范围取端点（噪声在大滞后近似饱和）

    # ── 1 粗糙度 vs 尺度 ──
    # 可信段：ν > 2·ν_噪（实测），滞后 ≥ 3×该环外缘的融合平滑 σ（中层 8 m 外）或 ≥ 轨道 DTM 有效分辨率，
    #        且 ≤ 0.15×区域直径（环）或 ≤ 1/8 边长（方块）——自检里去平面在更大滞后上会把 ν 压低。
    lay = {}
    for a, b in ((1, 3), (3, 6), (0, 6)):
        s = (Wn > 0) & (rn >= a) & (rn < b) & ~rov_n
        sf = 层_ν(near, csn, s, 最大_m=min(2*(b - a), 4.0)); nz = noise_curve(f"近_{max(a, 1)}-{b}m" if a else "近_3-6m", sf["lag"])
        lay[f"近_{a}-{b}m"] = dict(层="近", 像素=csn, **sf, nu_噪=nz, 可信=(sf["nu"] > 2*nz) & (sf["lag"] >= csn) & (sf["lag"] <= 0.3*b))
    for a, b in ((2, 8), (8, 15), (15, 25), (25, 45)):
        s = (Wm > 0) & (rm >= a) & (rm < b) & ~rov_m
        sf = 层_ν(mid, csm, s, 最大_m=min(2*(b - a), 20.0)); nz = noise_curve(f"中_{max(a, 3)}-{b}m", sf["lag"])
        lag_min = max(3*float(sig_m(b)), csm)
        lay[f"中_{a}-{b}m"] = dict(层="中", 像素=csm, **sf, nu_噪=nz, 可信=(sf["nu"] > 2*nz) & (sf["lag"] >= lag_min) & (sf["lag"] <= 0.3*b),
                                  平滑σ_外缘=float(sig_m(b)))
    hi = T["hirise"].astype(np.float64); c0 = nh//2
    sf = 层_ν(hi[c0 - 50:c0 + 50, c0 - 50:c0 + 50], csh, np.ones((100, 100), bool), 最大_m=30)
    lay["HiRISE_±50m"] = dict(层="HiRISE", 像素=csh, **sf, 可信=(sf["lag"] >= 5.0) & (sf["lag"] <= 12.5))
    hs = hi[c0 - 100:c0 + 100, c0 - 100:c0 + 100]; Xh, Yh, rh = 网格坐标(csh, 200, mast)
    for a, b in ((2, 15), (15, 25), (25, 45)):                              # 与中层同一环带的 HiRISE（同地比较）
        s = (rh >= a) & (rh < b)
        sf = 层_ν(hs, csh, s, 最大_m=min(2*(b - a), 20.0))
        lay[f"HiRISE环_{a}-{b}m"] = dict(层="HiRISE环", 像素=csh, **sf, 可信=(sf["lag"] >= 5.0) & (sf["lag"] <= 0.3*b))
    w = 1600; sub = hi[c0 - w:c0 + w, c0 - w:c0 + w]                       # 外缘 200 m 与 CTX 渐变，不用
    sf = 层_ν(sub, csh, np.ones_like(sub, bool), 最大_m=800, 每十倍=8)
    lay["HiRISE_±1.6km"] = dict(层="HiRISE", 像素=csh, **sf, 可信=(sf["lag"] >= 5.0) & (sf["lag"] <= 400))
    zc, mc = ctx_窗口(20000); sf = 层_ν(np.nan_to_num(zc), 20.0, mc, 最大_m=8000, 每十倍=8)
    lay["CTX_±20km"] = dict(层="CTX", 像素=20.0, **sf, 可信=(sf["lag"] >= 100.0) & (sf["lag"] <= 5000))
    for k, v in lay.items():
        ok = v["可信"]
        v["H分段"] = 分段拟合(v["lag"][ok], v["nu"][ok], 最多段=2) if ok.sum() >= 10 else None
        v["H可信段"] = 拟合H(v["lag"][ok], v["nu"][ok], v["lag"][ok].min(), v["lag"][ok].max()) if ok.sum() >= 3 else None
        v["局部H"] = 局部H(v["lag"], v["nu"])
    R["粗糙度"] = {k: {kk: vv for kk, vv in v.items() if kk not in ("nu_dir",)} for k, v in lay.items()}
    nu_at = lambda k, l: float(np.exp(np.interp(math.log(l), np.log(lay[k]["lag"]), np.log(lay[k]["nu"]), left=np.nan, right=np.nan)))
    ok_at = lambda k, l: bool(np.interp(math.log(l), np.log(lay[k]["lag"]), lay[k]["可信"].astype(float)) > 0.5)
    # 各尺度段的 H（指定数据源）
    seg = {}
    for nm_, k, lo, hi_ in (("2–10 cm", "近_0-6m", 0.02, 0.1), ("10–50 cm", "近_0-6m", 0.1, 0.5), ("0.5–1.8 m", "近_0-6m", 0.5, 1.8),
                            ("0.3–2.4 m（中 2–8 m 环）", "中_2-8m", 0.3, 2.4), ("0.3–4.5 m（中 8–15 m 环）", "中_8-15m", 0.3, 4.5),
                            ("1–7.5 m（中 15–25 m 环）", "中_15-25m", 0.9, 7.5), ("3.4–13.5 m（中 25–45 m 环）", "中_25-45m", 3.4, 13.5),
                            ("5–50 m（HiRISE ±1.6 km）", "HiRISE_±1.6km", 5, 50), ("50–150 m（HiRISE）", "HiRISE_±1.6km", 50, 150),
                            ("200–400 m（HiRISE）", "HiRISE_±1.6km", 200, 400), ("120 m–1 km（CTX）", "CTX_±20km", 120, 1000),
                            ("1.4–5 km（CTX）", "CTX_±20km", 1400, 5000)):
        seg[nm_] = dict(源=k, **(拟合H(lay[k]["lag"], lay[k]["nu"], lo, hi_) or {}))
    R["H分段表"] = seg
    for k_, v_ in seg.items(): log(f"  H {k_}：{v_.get('H', float('nan')):.2f}，ν(1 m) 截距 {v_.get('nu_1m', float('nan'))*1000:.0f} mm")
    # HiRISE 与 Navcam 同地比较（同一环带、同一滞后）
    cmp_ = []
    for ring in ("15-25m", "25-45m"):
        for l in (3.0, 5.0, 8.0, 12.0):
            a_, b_ = nu_at(f"中_{ring}", l), nu_at(f"HiRISE环_{ring}", l)
            if np.isfinite(a_) and np.isfinite(b_): cmp_.append(dict(环=ring, 滞后_m=l, Navcam=a_, HiRISE=b_, HiRISE比Navcam=b_/a_, Navcam可信=ok_at(f"中_{ring}", l)))
    for l in (3.0, 5.0, 8.0):
        a_, b_ = nu_at("中_2-8m", l) if l <= 2.4 else nu_at("中_8-15m", l), nu_at("HiRISE环_2-15m", l)
        if np.isfinite(a_) and np.isfinite(b_): cmp_.append(dict(环="2-15m", 滞后_m=l, Navcam=a_, HiRISE=b_, HiRISE比Navcam=b_/a_, Navcam可信=ok_at("中_8-15m", l)))
    R["HiRISE对Navcam"] = cmp_
    # 振幅一致不等于分辨了同样的地物（平滑 + 噪声可以凑出同样的 ν）。同地逐格相关：中层 10 cm → 1 m 块平均，与 HiRISE 同格，DoG 带通后相关
    Zm1 = mid.reshape(100, 10, 100, 10).mean((1, 3)); Wm1 = (Wm > 0).reshape(100, 10, 100, 10).all((1, 3))
    H1 = hi[c0 - 50:c0 + 50, c0 - 50:c0 + 50]; X1_, Y1_, r1_ = 网格坐标(1.0, 100, mast); xc_ = []
    for lo, hi_ in ((2, 15), (15, 30)):
        mm = Wm1 & (r1_ >= lo) & (r1_ < hi_)
        for sg in (0.7, 1.5, 3.0, 6.0):
            a1, w1 = 归一卷积(Zm1, mm, sg); a2, w2 = 归一卷积(Zm1, mm, 2*sg); b1, _ = 归一卷积(H1, mm, sg); b2, _ = 归一卷积(H1, mm, 2*sg)
            v = mm & (w2 > 0.8)
            if v.sum() < 30: continue
            x_, y_ = (a1 - a2)[v], (b1 - b2)[v]
            xc_.append(dict(环=f"{lo}-{hi_}m", 带通σ_m=sg, n=int(v.sum()), 相关=float(np.corrcoef(x_, y_)[0, 1]), HiRISE比Navcam_rms=float(y_.std()/x_.std())))
    R["HiRISE对Navcam_逐格相关"] = xc_
    log("  HiRISE–Navcam 同格带通相关：" + "；".join(f"{c_['环']} σ{c_['带通σ_m']:g} m r={c_['相关']:+.2f} rms比 {c_['HiRISE比Navcam_rms']:.2f}" for c_ in xc_))
    for c_ in cmp_: log(f"  同地 {c_['环']} Δx={c_['滞后_m']:g} m：Navcam {c_['Navcam']*1000:.0f} mm，HiRISE {c_['HiRISE']*1000:.0f} mm，比 {c_['HiRISE比Navcam']:.2f}")
    # HiRISE 外推到地面尺度 vs 实测
    fits = {"HiRISE±1.6km_5-50m": 拟合H(lay["HiRISE_±1.6km"]["lag"], lay["HiRISE_±1.6km"]["nu"], 5, 50)}
    hr = np.concatenate([lay[f"HiRISE环_{r}"]["lag"] for r in ("15-25m", "25-45m")]); hv = np.concatenate([lay[f"HiRISE环_{r}"]["nu"] for r in ("15-25m", "25-45m")])
    fits["HiRISE环15-45m_5-13m"] = 拟合H(hr, hv, 5, 13.5)
    ex = []
    for src, ls_ in (("近_0-6m", (0.02, 0.05, 0.1, 0.3, 1.0)), ("近_1-3m", (0.02, 0.1, 0.3)), ("中_2-8m", (0.3, 1.0, 2.0)), ("中_8-15m", (0.3, 1.0, 3.0)),
                     ("中_15-25m", (1.0, 3.0, 5.0)), ("中_25-45m", (3.5, 5.0, 10.0))):
        for l in ls_:
            m_ = nu_at(src, l)
            if not np.isfinite(m_): continue
            row = dict(源=src, 滞后_m=l, 实测=m_, 可信=ok_at(src, l))
            for fk, f in fits.items():
                if f: row[f"外推_{fk}"] = f["nu_1m"]*l**f["H"]; row[f"实测比外推_{fk}"] = m_/(f["nu_1m"]*l**f["H"])
            ex.append(row)
    R["HiRISE外推"] = dict(拟合=fits, 对比=ex)
    fh = fits["HiRISE±1.6km_5-50m"]; log(f"  HiRISE 5–50 m：H={fh['H']:.2f}，ν(1 m)={fh['nu_1m']*1000:.0f} mm")
    for e in ex: log(f"  {e['源']} Δx={e['滞后_m']:g} m：实测 {e['实测']*1000:.1f} mm，比 HiRISE 外推 {e.get('实测比外推_HiRISE±1.6km_5-50m', np.nan):.2f}，"
                    f"比环带外推 {e.get('实测比外推_HiRISE环15-45m_5-13m', np.nan):.2f}{'' if e['可信'] else '（不可信段）'}")

    # ── 2 各地类（近层 r < 6 m，地类权重 > 0.7）──
    K = np.load(REC/"地类.npz"); Pm = K["mid"]; off = (int(K["n_mid"]) - nn)//2
    Pn = Pm[off:off + nn, off:off + nn].astype(np.float32)
    P10 = np.stack([Pm[..., i].astype(np.float32).reshape(nm, 5, nm, 5).mean((1, 3)) for i in range(4)], -1); del Pm   # 2 cm → 10 cm（与中层同格）
    base = (Wn > 0) & (rn < 6) & ~rov_n
    dN, okN, _ = 噪声差场(G, "近")
    cls = {}; z0, _ = 去平面(near, base)
    for i, nm_ in enumerate(CLASSES):
        s = base & (Pn[..., i] > 0.7)
        if s.sum() < 5000: cls[nm_] = dict(格数=int(s.sum())); continue
        sf = 结构函数(z0, csn, s, 滞后表(100, 10))
        sn = s & okN; nzs = 结构函数(np.where(sn, dN, 0), csn, sn, 滞后表(100, 10))
        nzc = nzs["nu"]/2
        f = 指纹(near, csn, s, 坡度基线_m=(0.02, 0.1, 0.5, 1.0), 残差尺度_m=(0.05, 0.1, 0.25), 谱块=None, 各向异性=True)
        cls[nm_] = dict(格数=int(s.sum()), 面积_m2=float(s.sum()*csn*csn), 平均r=float(rn[s].mean()), lag=sf["lag"], nu=sf["nu"], n=sf["n"], kurt=sf["kurt"],
                        nu_噪=nzc, 可信=(sf["nu"] > 2*nzc), H_2_20cm=拟合H(sf["lag"], sf["nu"], 0.02, 0.2), H_20_200cm=拟合H(sf["lag"], sf["nu"], 0.2, 2.0),
                        坡度=f["坡度"], 残差=f["残差"], 各向异性=f["各向异性"], 谱=None)
        log(f"  {nm_}：{s.sum()*csn*csn:.1f} m²，ν(2 cm) {sf['nu'][0]*1000:.1f} mm（噪 {nzc[0]*1000:.1f}），ν(1 m) {np.interp(1, sf['lag'], sf['nu'])*1000:.1f} mm")
    R["地类"] = cls
    # 中层 10 cm、r 2–15 m（无平滑、噪声 ≤ 4 mm）：各地类面积大得多，0.1–3 m 的地类差别以这里为准
    dM, okM, _ = 噪声差场(G, "中"); cls_m = {}
    base_m = (Wm > 0) & (rm >= 2) & (rm < 15) & ~rov_m & (P10.min(-1) >= 0)
    zm_, _ = 去平面(mid, base_m)
    for i, nm_ in enumerate(CLASSES):
        s = base_m & (P10[..., i] > 0.7)
        if s.sum() < 2000: cls_m[nm_] = dict(格数=int(s.sum())); continue
        sf = 结构函数(zm_, csm, s, 滞后表(30, 10)); sn = s & okM; nzc = 结构函数(np.where(sn, dM, 0), csm, sn, 滞后表(30, 10))["nu"]/2
        cls_m[nm_] = dict(格数=int(s.sum()), 面积_m2=float(s.sum()*csm*csm), 平均r=float(rm[s].mean()), lag=sf["lag"], nu=sf["nu"], n=sf["n"], kurt=sf["kurt"], nu_噪=nzc,
                          H_10_100cm=拟合H(sf["lag"], sf["nu"], 0.1, 1.0), H_1_3m=拟合H(sf["lag"], sf["nu"], 1.0, 3.0),
                          坡度=[x for x in (坡度统计(zm_, csm, s, b_, 直方=False) for b_ in (0.1, 0.5, 1.0)) if x], 残差=残差统计(zm_, csm, s, (0.2, 0.5)))
        log(f"  中层 {nm_}：{s.sum()*csm*csm:.0f} m²，ν(10 cm) {sf['nu'][0]*1000:.1f} mm，ν(1 m) {np.interp(1, sf['lag'], sf['nu'])*1000:.0f} mm，"
            f"H(0.1–1 m) {cls_m[nm_]['H_10_100cm']['H']:.2f}，残差偏度(0.2 m) {cls_m[nm_]['残差'][0]['偏度'] if cls_m[nm_]['残差'] else float('nan'):.2f}")
    R["地类_中层"] = cls_m
    R["地类比例_中层2-15m"] = {nm_: float(P10[..., i][base_m].mean()) for i, nm_ in enumerate(CLASSES)}
    # 地类比例（近层 r<6 m）
    has_c = base & (Pn.min(-1) >= 0)                                       # 地类图无数据处存的是 −1
    R["地类比例_近6m"] = {nm_: float(Pn[..., i][has_c].mean()) for i, nm_ in enumerate(CLASSES)}
    R["地类比例_近6m_权重>0.7"] = {nm_: float((Pn[..., i][has_c] > 0.7).mean()) for i, nm_ in enumerate(CLASSES)}

    # ── 2b 各向异性与波纹（近层整体 r<6；中层 2–15 m；沙地最大满块的二维谱）──
    an = {}
    for nm_, (z_, cs_, s_) in {"近_r<6m": (near, csn, base), "中_2-15m": (mid, csm, (Wm > 0) & (rm >= 2) & (rm < 15) & ~rov_m)}.items():
        zz, _ = 去平面(z_, s_); Lp = int(min(2.0/cs_, 150)); g2, _ = 变差图2D(zz, s_, Lp); rows = []
        for lag_m in ((0.05, 0.1, 0.25, 0.5, 1.0, 2.0) if cs_ < 0.05 else (0.2, 0.5, 1.0, 2.0, 5.0)):
            rp = lag_m/cs_
            if rp > Lp: continue
            a_, v_ = 方向谱(g2, rp); rows.append(dict(滞后_m=lag_m, 角_deg=a_, nu=v_, 比=float(v_.max()/v_.min()),
                                                    最小方向_deg=float(a_[np.argmin(v_)]), 最大方向_deg=float(a_[np.argmax(v_)])))
        an[nm_] = dict(行=rows, g2=g2, cs=cs_, L=Lp)
    for nm_, i in (("沙", 0), ("暗色岩块", 3), ("全部", None)):
        s = base if i is None else base & (Pn[..., i] > 0.5)
        sp = None
        for b in (256, 128, 64):
            if 满块(s, b): sp = 功率谱(near, csn, s, b); break
        an[f"谱_{nm_}"] = dict(谱=sp, 峰=波纹峰(sp))
    # 诊断：各向异性是地形本身还是立体视线方向的伪影？① 径向（沿视线）对切向；② 分扇区看东西/南北比是否随扇区转；
    #       ③ 0.5 m 高通残差（去掉坡面弯曲）；④ 噪声差场本身的径向/切向。
    diag_ = {}
    diag_["径向切向_近r<6"] = 径向切向(去平面(near, base)[0], csn, base, Xn, Yn, mast, (0.05, 0.1, 0.25, 0.5, 1.0))
    sN = okN & base; diag_["径向切向_噪声差场"] = 径向切向(np.where(sN, dN, 0), csn, sN, Xn, Yn, mast, (0.05, 0.1, 0.25, 0.5))
    az = np.degrees(np.arctan2(Xn - mast[0], Yn - mast[1])) % 360          # 自北顺时针的方位
    sec = {}
    for nm_, (a0, a1) in {"北": (315, 45), "东": (45, 135), "南": (135, 225), "西": (225, 315)}.items():
        ms_ = base & ((az >= a0) | (az < a1) if a0 > a1 else (az >= a0) & (az < a1))
        if ms_.sum() < 5000: continue
        sf_ = 结构函数(去平面(near, ms_)[0], csn, ms_, np.array([5, 12, 25, 50]))
        sec[nm_] = dict(格数=int(ms_.sum()), lag=sf_["lag"], 东西=sf_["nu_dir"][0], 南北=sf_["nu_dir"][90], 南北比东西=sf_["nu_dir"][90]/sf_["nu_dir"][0])
    diag_["分扇区_近r<6"] = sec
    lo_, w_ = 归一卷积(near, base, 0.5/csn); hp = base & (w_ > 0.8)
    g2h, _ = 变差图2D(np.where(hp, near - lo_, 0), hp, 30); diag_["高通0.5m"] = []
    for lag_m in (0.05, 0.1, 0.25, 0.5):
        a_, v_ = 方向谱(g2h, lag_m/csn); diag_["高通0.5m"].append(dict(滞后_m=lag_m, 比=float(v_.max()/v_.min()), 最小方向_deg=float(a_[np.argmin(v_)]), 最大方向_deg=float(a_[np.argmax(v_)])))
    g2H, _ = 变差图2D(去平面(sub, np.ones_like(sub, bool))[0], np.ones_like(sub, bool), 120); diag_["HiRISE_±1.6km"] = []
    for lag_m in (5, 10, 30, 100):
        a_, v_ = 方向谱(g2H, lag_m/csh); diag_["HiRISE_±1.6km"].append(dict(滞后_m=lag_m, 比=float(v_.max()/v_.min()), 最小方向_deg=float(a_[np.argmin(v_)]), 最大方向_deg=float(a_[np.argmax(v_)])))
    an["诊断"] = diag_
    log("  各向异性诊断：径向/切向 " + str([(r["滞后_m"], round(r["径向比切向"], 2)) for r in diag_["径向切向_近r<6"]]) +
        "；扇区 南北/东西(1 m) " + str({k: round(float(v["南北比东西"][-1]), 2) for k, v in sec.items()}) +
        "；高通 " + str([(r["滞后_m"], round(r["比"], 2), r["最小方向_deg"]) for r in diag_["高通0.5m"]]) +
        "；HiRISE " + str([(r["滞后_m"], round(r["比"], 2), r["最小方向_deg"]) for r in diag_["HiRISE_±1.6km"]]))
    R["各向异性"] = an

    # ── 3 坡度分布（2 cm、10 cm：近层 r<3/6 m；1 m：中层 r<15；5 m：中层 r<25 与 HiRISE）──
    sl = {}
    zn6, _ = 去平面(near, base); s3 = base & (rn < 3)
    sl["2cm_近r<3"] = 坡度统计(zn6, csn, s3, 0.02); sl["2cm_近r<6"] = 坡度统计(zn6, csn, base, 0.02)
    sl["10cm_近r<6"] = 坡度统计(zn6, csn, base, 0.10); sl["1m_近r<6"] = 坡度统计(zn6, csn, base, 1.0)
    for a, b in ((2, 15), (2, 30)):
        s = (Wm > 0) & (rm >= a) & (rm < b) & ~rov_m; zz, _ = 去平面(mid, s)
        sl[f"1m_中r<{b}"] = 坡度统计(zz, csm, s, 1.0); sl[f"5m_中r<{b}"] = 坡度统计(zz, csm, s, 5.0)
    hh, _ = 去平面(sub, np.ones_like(sub, bool))
    sl["1m_HiRISE"] = 坡度统计(hh, csh, np.ones_like(sub, bool), 1.0); sl["5m_HiRISE"] = 坡度统计(hh, csh, np.ones_like(sub, bool), 5.0)
    sl["20m_HiRISE"] = 坡度统计(hh, csh, np.ones_like(sub, bool), 20.0)
    R["坡度"] = sl
    for k, v in sl.items():
        if v: log(f"  坡度 {k}：RMS {v['rms_deg']:.1f}°，中位角 {v['角_中位']:.1f}°，峰度 {v['峰度']:.1f}，β {v['广义高斯β']:.2f}")

    # ── 4 高通残差分布（各地类）──
    R["残差"] = {nm_: v.get("残差") for nm_, v in cls.items()}
    R["残差_全部近r<6"] = 残差统计(zn6, csn, base, (0.05, 0.1, 0.25, 0.5))
    R["残差_HiRISE"] = 残差统计(hh, csh, np.ones_like(sub, bool), (5.0, 20.0, 80.0))

    # ── 5 石块 ──
    R["石块"] = 石块分析(M, T, L, mast, Pn, Xn, Yn, rn, rov_n)

    # ── 6 反照率 ──
    R["反照率"] = 反照率分析(M, T, L, mast, near, mid, Wn, Wm, Xn, Yn, rn, rov_n, Xm, Ym, rm, rov_m, hi, nh)
    R["耗时_s"] = time.time() - t0
    return R, lay


def 石块分析(M, T, L, mast, Pn, Xg, Yg, rg, rov):
    """复用 57 ⑧ 的分割与三关筛选（只读，不写文件）得到全部 ≥5 cm 石块的 D、H、位置；SFD 拟合 Golombek k；空间格局。"""
    from scipy.ndimage import label, find_objects, binary_dilation
    cs, n = L["近"]; Z = T["near"].astype(np.float64); W = T["near_w"]
    G = M.ground_of(Z, cs, 0.25); rel = Z - G
    noise = 0.003 + 2.4e-4*rg**2; mask = rel > np.maximum(0.03, 2.5*noise)
    nv = np.load(REC/"反照率_近.npz"); An = nv["A"].astype(np.float32).mean(-1); csa, na = float(nv["cs"]), int(nv["n"])
    alb = M.sample(np.where(nv["cov"] > 0, An, np.nan), csa, na, Xg.ravel(), Yg.ravel(), order=1).reshape(n, n)
    lab, nl = label(mask); rocks = []; why = dict(扁=0, 糊=0, 没反差=0, 露头=0, 小=0)
    for i, sl in enumerate(find_objects(lab), 1):
        if sl is None: continue
        sy, sx = sl; pad = 6
        sy = slice(max(sy.start - pad, 0), min(sy.stop + pad, n)); sx = slice(max(sx.start - pad, 0), min(sx.stop + pad, n))
        m = lab[sy, sx] == i
        if m.sum() < 6: why["小"] += 1; continue
        R_ = rel[sy, sx]; D = 2*math.sqrt(m.sum()*cs*cs/math.pi); H = float(R_[m].max())
        if D > 1.5: why["露头"] += 1; continue
        if H/D < 0.15: why["扁"] += 1; continue
        if H < 2.5*float(noise[sy, sx][m].mean()): why["糊"] += 1; continue
        ring_ = binary_dilation(m, iterations=4) & ~binary_dilation(m, iterations=1)
        a_in, a_out = alb[sy, sx][m], alb[sy, sx][ring_]
        ai = np.nanmedian(a_in) if np.isfinite(a_in).any() else np.nan; ao = np.nanmedian(a_out) if np.isfinite(a_out).any() else np.nan
        contrast = abs(ai/ao - 1) if np.isfinite(ai) and np.isfinite(ao) and ao > 0 else 0.0
        if contrast < 0.04 and H/D < 0.3: why["没反差"] += 1; continue
        x0, y0 = float(Xg[sy, sx][m].mean()), float(Yg[sy, sx][m].mean()); r0 = float(math.hypot(x0 - mast[0], y0 - mast[1]))
        iy, ix = int((y0/cs) + n/2), int((x0/cs) + n/2)
        rocks.append(dict(x=x0, y=y0, r=r0, D=D, H=H, HD=H/D, 反差=float(ai/ao - 1) if np.isfinite(ai) and np.isfinite(ao) else None,
                          地类=int(np.argmax(Pn[iy, ix])) if np.all(np.isfinite(Pn[iy, ix])) and Pn[iy, ix].max() >= 0 else -1))
    log(f"石块（复现 57 ⑧ 的筛选）：{len(rocks)} 块 ≥5 cm；剔 {why}")
    D = np.array([r["D"] for r in rocks]); rr = np.array([r["r"] for r in rocks])
    out = dict(块数=len(rocks), 剔除=why, 表=rocks)
    valid = (W > 0) & ~rov
    fits = {}
    for Rmax in (4.0, 6.0, 9.0):
        area = float((valid & (rg < Rmax)).sum()*cs*cs); sel = rr < Rmax
        # 完整性：高度门槛 max(3 cm, 2.5σ(r)) 且 H/D ≥ 0.15 → 在 r 处能检出的最小直径约 门槛/(典型 H/D≈0.35)
        Dc = max(0.03, 2.5*(0.003 + 2.4e-4*Rmax**2))/0.35
        for Dmin in (0.10, 0.15, 0.25):
            if Dmin < Dc*0.999: continue
            f = 拟合k(D[sel], area, Dmin)
            if f: fits[f"r<{Rmax:g}m_D≥{Dmin:g}m"] = dict(**f, 面积_m2=area, 完整下限D_m=Dc)
        ds = np.sort(D[sel])[::-1]
        out[f"累计_r<{Rmax:g}m"] = dict(D=ds, F=np.cumsum(math.pi*ds**2/4)/area, N=np.arange(1, len(ds) + 1)/area, 面积_m2=area, 完整下限D_m=Dc)
    out["拟合"] = fits
    out["H/D"] = dict(中位=float(np.median([r["HD"] for r in rocks])), p25=float(np.percentile([r["HD"] for r in rocks], 25)),
                      p75=float(np.percentile([r["HD"] for r in rocks], 75)))
    out["地类计数"] = {CLASSES[c] if c >= 0 else "无": int(sum(1 for r in rocks if r["地类"] == c)) for c in range(-1, 4)}
    for k, f in fits.items(): log(f"  Golombek {k}：k = {f['k']:.4f}（单点 {f['k_单点']:.4f}），n = {f['n']}，对数残差 {f['rms_log']:.2f}")
    # 空间格局：r < 6 m、D ≥ 8 cm（6 m 处门槛 ≈ 3 cm 高），窗口＝有数据（膨胀 10 cm）
    Rw = 6.0; sel = (rr < Rw) & (D >= 0.08)
    win = binary_dilation(valid, iterations=5) & (rg < Rw) & ~rov
    pts = np.array([[r["x"], r["y"]] for r, s in zip(rocks, sel) if s])
    out["格局_r<6m_D≥8cm"] = 点格局(pts, win, Xg, Yg, cs, nsim=199)
    sel2 = (rr < Rw) & (D >= 0.15); pts2 = np.array([[r["x"], r["y"]] for r, s in zip(rocks, sel2) if s])
    out["格局_r<6m_D≥15cm"] = 点格局(pts2, win, Xg, Yg, cs, nsim=199) if len(pts2) >= 10 else None
    # 非均匀零假设：强度 ∝ Σ_c P_c(x)·ρ_c，ρ_c＝该地类（软面积）上的石块密度——看聚集是不是只因石块偏爱砾石/岩块地类
    Pw = np.where(Pn.min(-1, keepdims=True) >= 0, Pn, 0).astype(np.float64)
    cl_ = np.array([r["地类"] for r, s_ in zip(rocks, sel) if s_]); rho = []
    for c in range(4):
        a_c = float((Pw[..., c]*win).sum()*cs*cs); rho.append(((cl_ == c).sum() + 0.5)/max(a_c, 1e-6))
    lam = (Pw*np.array(rho)).sum(-1)
    out["格局_r<6m_D≥8cm_按地类非均匀"] = 点格局(pts, win, Xg, Yg, cs, nsim=199, 强度=lam)
    out["格局_地类密度_每m2"] = {CLASSES[c]: rho[c] for c in range(4)}
    g = out["格局_r<6m_D≥8cm"]; g2_ = out["格局_r<6m_D≥8cm_按地类非均匀"]
    if g2_: log(f"  格局 非均匀（按地类）：R={g2_['R']:.2f}（p_聚集={g2_['p_聚集']:.3f}）；各地类密度 {[round(x, 2) for x in rho]} /m²")
    if g: log(f"  格局 D≥8 cm：n={g['n']}，R={g['R']:.2f}（p_聚集={g['p_聚集']:.3f}），经典 R={g['R_经典']:.2f}")
    return out


def 反照率分析(M, T, L, mast, near, mid, Wn, Wm, Xn, Yn, rn, rov_n, Xm, Ym, rm, rov_m, hi, nh):
    out = {}
    (csn, nn), (csm, nm) = L["近"], L["中"]
    # 近：1 cm → 2×2 块平均到 2 cm（与近层高程同格）
    a = np.load(REC/"反照率_近.npz"); A = a["A"].astype(np.float32).mean(-1); cov = a["cov"] > 0; n1 = int(a["n"])
    A2 = A.reshape(nn, 2, nn, 2).mean((1, 3)); c2 = cov.reshape(nn, 2, nn, 2).all((1, 3))
    _, _, r1 = 网格坐标(0.01, n1, mast); X1, Y1, _ = 网格坐标(0.01, n1, mast)
    s1 = cov & (r1 < 6) & ~M.under_rover(X1, Y1)
    out["ν_近1cm_r<6"] = 结构函数(np.where(s1, np.log(np.maximum(A, 1e-4)), 0), 0.01, s1, 滞后表(300, 10))
    # 中：4 cm，按环
    b = np.load(REC/"反照率_中.npz"); Am = b["A"].astype(np.float32).mean(-1); covm = b["cov"] > 0; n4 = int(b["n"]); cs4 = float(b["cs"])
    X4, Y4, r4 = 网格坐标(cs4, n4, mast); rov4 = M.under_rover(X4, Y4)
    for lo, hi_ in ((2, 8), (8, 20), (20, 45)):
        s = covm & (r4 >= lo) & (r4 < hi_) & ~rov4
        out[f"ν_中4cm_{lo}-{hi_}m"] = 结构函数(np.where(s, np.log(np.maximum(Am, 1e-4)), 0), cs4, s, 滞后表(int(min(2*(hi_ - lo), 20)/cs4), 10))
    # HiRISE 25 cm（±1 km，取中心 ±500 m 算 25 cm 滞后；4×4 块平均到 1 m 与 HiRISE 高程同格）
    h = np.load(REC/"反照率_HiRISE.npz"); Ah = h["A"].astype(np.float32).mean(-1); nH = int(h["n"])
    cc = nH//2; sub = Ah[cc - 2000:cc + 2000, cc - 2000:cc + 2000]; sv = np.isfinite(sub) & (sub > 0)
    out["ν_HiRISE25cm_±500m"] = 结构函数(np.where(sv, np.log(np.maximum(sub, 1e-4)), 0), 0.25, sv, 滞后表(1000, 8))
    s50 = Ah[cc - 200:cc + 200, cc - 200:cc + 200]; v50 = np.isfinite(s50) & (s50 > 0)
    out["ν_HiRISE25cm_±50m"] = 结构函数(np.where(v50, np.log(np.maximum(s50, 1e-4)), 0), 0.25, v50, 滞后表(100, 10))
    sp = 功率谱(np.log(np.maximum(np.nan_to_num(sub, nan=1e-4), 1e-4)), 0.25, sv, 512, 最多块=60)
    out["HiRISE反照率谱峰"] = 波纹峰(sp); out["HiRISE反照率谱"] = None if sp is None else {k: sp[k] for k in ("k", "P", "块", "n块", "拟合")}
    log(f"  HiRISE 反照率二维谱峰：{out['HiRISE反照率谱峰']}")
    # Navcam（中层 4 cm → 20 cm）与 HiRISE 反照率在同一地点的对比：相关与对比度增益（ln 反照率标准差之比）
    A20 = Am.reshape(500, 5, 500, 5).mean((1, 3)); c20 = covm.reshape(500, 5, 500, 5).all((1, 3))
    X20, Y20, r20 = 网格坐标(0.2, 500, mast); rov20 = M.under_rover(X20, Y20)
    Hs = M.sample(np.nan_to_num(Ah, nan=0.0), 0.25, nH, X20.ravel(), Y20.ravel(), order=1).reshape(500, 500)
    gain = []
    for lo, hi_ in ((3, 15), (15, 40)):
        for sg in (0.5, 2.0):
            mm = c20 & (Hs > 0) & (r20 >= lo) & (r20 < hi_) & ~rov20
            a1, w1 = 归一卷积(np.log(np.maximum(A20, 1e-4)), mm, sg/0.2); b1, _ = 归一卷积(np.log(np.maximum(Hs, 1e-4)), mm, sg/0.2)
            a2, _ = 归一卷积(np.log(np.maximum(A20, 1e-4)), mm, 4*sg/0.2); b2, _ = 归一卷积(np.log(np.maximum(Hs, 1e-4)), mm, 4*sg/0.2)
            v = mm & (w1 > 0.8); x_, y_ = (b1 - b2)[v], (a1 - a2)[v]
            if v.sum() < 500: continue
            gain.append(dict(环=f"{lo}-{hi_}m", 平滑σ_m=sg, n=int(v.sum()), 相关=float(np.corrcoef(x_, y_)[0, 1]), 对比度比_Navcam比HiRISE=float(y_.std()/x_.std())))
    out["Navcam对HiRISE反照率"] = gain
    log("  Navcam/HiRISE 反照率同地对比：" + "；".join(f"{g['环']} σ{g['平滑σ_m']:g} m 相关 {g['相关']:+.2f} 对比度比 {g['对比度比_Navcam比HiRISE']:.1f}" for g in gain))
    out["_HiRISE裁"] = np.nan_to_num(Ah[cc - 160:cc + 160, cc - 160:cc + 160], nan=float(np.nanmedian(sub)))
    A1 = Ah.reshape(nH//4, 4, nH//4, 4).mean((1, 3)); del Ah
    o = (nh - nH//4)//2; Z1 = hi[o:o + nH//4, o:o + nH//4]; v1 = np.isfinite(A1) & (A1 > 0)
    # 带通相关
    out["相关_近2cm_r<6"] = 带通相关(A2, near, c2 & (rn < 6) & ~rov_n & (Wn > 0), csn, (0.04, 0.08, 0.16, 0.32, 0.64))
    Z20 = mid.reshape(500, 2, 500, 2).mean((1, 3)); W20 = (Wm > 0).reshape(500, 2, 500, 2).all((1, 3))   # 中层 10 cm → 20 cm
    out["相关_中20cm_r<25"] = 带通相关(A20, Z20, c20 & W20 & (r20 < 25) & (r20 > 2) & ~M.under_rover(X20, Y20), 0.2, (0.4, 0.8, 1.6, 3.2))
    out["相关_HiRISE1m_±1km"] = 带通相关(A1, Z1, v1, 1.0, (2, 4, 8, 16, 32, 64, 128))
    # 反照率统计量
    out["分布"] = dict(近_中位=float(np.median(A[s1])), 近_相对std=float(np.std(np.log(A[s1]))),
                     HiRISE_中位=float(np.nanmedian(sub[sv])), HiRISE_相对std=float(np.std(np.log(sub[sv]))))
    for k, v in out.items():
        if k.startswith("相关"):
            log(f"  {k}：" + "；".join(f"{r['尺度_m']:g} m 高程 {r['反照率_高程']:+.2f} 坡度 {r['反照率_坡度']:+.2f} 东坡 {r['反照率_东坡']:+.2f} 北坡 {r['反照率_北坡']:+.2f}" for r in v))
    return out


# ── ⑥ 图 ───────────────────────────────────────────────────────────
C = dict(blue="#2a78d6", orange="#eb6834", aqua="#1baf7a", yellow="#eda100", magenta="#e87ba4", green="#008300", violet="#4a3aa7", red="#e34948",
         ink="#0b0b0b", ink2="#52514e", muted="#8a8984", grid="#e6e5e0", surf="#fcfcfb")


def _风格():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    plt.rcParams.update({"font.family": ["FandolHei", "Noto Sans CJK SC", "DejaVu Sans"], "axes.unicode_minus": False, "mathtext.fontset": "dejavusans", "figure.facecolor": C["surf"],
                         "axes.facecolor": C["surf"], "axes.edgecolor": C["muted"], "axes.labelcolor": C["ink"], "text.color": C["ink"],
                         "xtick.color": C["ink2"], "ytick.color": C["ink2"], "grid.color": C["grid"], "grid.linewidth": 0.6,
                         "axes.grid": True, "axes.spines.top": False, "axes.spines.right": False, "lines.linewidth": 2,
                         "legend.frameon": False, "font.size": 9, "axes.titlesize": 10, "savefig.dpi": 130})
    return plt


def 画图(R, lay, S):
    plt = _风格(); figs = []
    # 图1 粗糙度—尺度
    fig, (ax, bx) = plt.subplots(2, 1, figsize=(9.5, 9.5), height_ratios=[3, 1.3], sharex=True)
    col = {"近": C["blue"], "中": C["orange"], "HiRISE环": C["aqua"], "HiRISE_±50m": C["aqua"], "HiRISE_±1.6km": C["violet"], "CTX": C["green"]}
    labs = {"近": "Navcam 近层 2 cm（r 环带）", "中": "Navcam 中层 10 cm（r 环带）", "HiRISE环": "HiRISE 1 m，与中层同环带（虚线）",
            "HiRISE_±1.6km": "HiRISE 1 m，±1.6 km", "CTX": "CTX 20 m，±20 km"}
    done = set()
    for k, v in lay.items():
        if k in ("HiRISE_±50m", "近_0-6m"): continue
        key = k if k == "HiRISE_±1.6km" else v["层"]; c_ = col[key]; ls = "--" if v["层"] == "HiRISE环" else "-"
        ok = v["可信"]; ax.plot(v["lag"], v["nu"], color=c_, lw=0.8, alpha=0.3, ls=ls)
        ax.plot(v["lag"], np.where(ok, v["nu"], np.nan), color=c_, lw=2, ls=ls, label=None if key in done else labs.get(key, k)); done.add(key)
        if ok.any() and v["层"] in ("近", "中"):
            i = np.flatnonzero(ok)[-1]; ax.text(v["lag"][i]*1.08, v["nu"][i], k.split("_")[1], fontsize=6.5, color=C["ink2"], va="center")
        if "nu_噪" in v and np.isfinite(v["nu_噪"]).any(): ax.plot(v["lag"], v["nu_噪"], color=c_, lw=1, ls=":", alpha=0.8)
        h = np.where(ok, v["局部H"], np.nan); bx.plot(v["lag"], h, color=c_, lw=1.5, ls=ls)
    fh = R["HiRISE外推"]["拟合"]["HiRISE±1.6km_5-50m"]; xx = np.geomspace(0.01, 50, 50)
    ax.plot(xx, fh["nu_1m"]*xx**fh["H"], color=C["red"], ls="--", lw=1.2, label=f"HiRISE ±1.6 km 5–50 m 拟合外推（H={fh['H']:.2f}）")
    ax.plot([], [], color=C["muted"], ls=":", lw=1, label="实测立体噪声 ν_噪（同色＝同层同环）")
    ax.axvspan(1, 5, color=C["aqua"], alpha=0.07, lw=0); ax.text(2.2, 2e-4, "HiRISE DTM 有效\n分辨率以下", fontsize=7, color=C["ink2"], ha="center")
    ax.set_xscale("log"); ax.set_yscale("log"); ax.set_ylabel("ν(Δx)＝RMS 高差（m）"); ax.set_ylim(1e-4, 300)
    ax.set_title("sol 530 站：高程 RMS 起伏随尺度（粗线＝可信段；细线＝噪声/平滑/分辨率/窗口主导；行末标注＝离桅杆的环带）", loc="left", fontsize=9)
    ax.legend(fontsize=7.5, loc="upper left")
    bx.axhline(0.5, color=C["muted"], lw=0.6); bx.set_ylim(0, 1.2); bx.set_ylabel("局部 H＝dlogν/dlogΔx"); bx.set_xlabel("基线 Δx（m）")
    fig.tight_layout(); figs.append(("图1_粗糙度_尺度.png", fig))
    # 图2 地类
    fig, axs2 = plt.subplots(2, 2, figsize=(10.5, 8)); (ax, bx), (cx, dx) = axs2; cc = [C["yellow"], C["orange"], C["violet"], C["blue"]]
    for i, nm_ in enumerate(CLASSES):
        v = R.get("地类_中层", {}).get(nm_, {})
        if "lag" not in v: continue
        cx.plot(v["lag"], v["nu"], color=cc[i], label=f"{nm_}（{v['面积_m2']:.0f} m²）"); cx.plot(v["lag"], v["nu_噪"], color=cc[i], ls=":", lw=1)
        dx.plot(v["lag"], v["kurt"], color=cc[i], label=nm_)
    cx.set_xscale("log"); cx.set_yscale("log"); cx.set_xlabel("Δx（m）"); cx.set_ylabel("ν（m）"); cx.set_title("同上，中层 10 cm、r 2–15 m（面积大，0.1–3 m 以此为准）", loc="left"); cx.legend(fontsize=7.5)
    dx.set_xscale("log"); dx.axhline(0, color=C["muted"], lw=0.8); dx.set_xlabel("Δx（m）"); dx.set_ylabel("增量超额峰度"); dx.legend(fontsize=7.5)
    for i, nm_ in enumerate(CLASSES):
        v = R["地类"].get(nm_, {})
        if "lag" not in v: continue
        ax.plot(v["lag"], v["nu"], color=cc[i], label=f"{nm_}（{v['面积_m2']:.0f} m²）"); ax.plot(v["lag"], v["nu_噪"], color=cc[i], ls=":", lw=1)
        bx.plot(v["lag"], v["kurt"], color=cc[i], label=nm_)
    ax.set_xscale("log"); ax.set_yscale("log"); ax.set_xlabel("Δx（m）"); ax.set_ylabel("ν（m）"); ax.set_title("各地类粗糙度（近层 r<6 m，权重>0.7；点线＝实测噪声）", loc="left"); ax.legend(fontsize=7.5)
    bx.set_xscale("log"); bx.axhline(0, color=C["muted"], lw=0.8); bx.set_xlabel("Δx（m）"); bx.set_ylabel("增量超额峰度（0＝高斯）"); bx.set_title("高差分布的尾巴（间歇性）", loc="left"); bx.legend(fontsize=7.5)
    fig.tight_layout(); figs.append(("图2_地类粗糙度.png", fig))
    # 图7 HiRISE 反照率谱峰的目视核对：±40 m 原图与 0.5–3 m 带通
    if "_HiRISE裁" in R:
        fig, (ax, bx) = plt.subplots(1, 2, figsize=(10, 5)); im = R.pop("_HiRISE裁"); e = im.shape[0]*0.125
        ax.imshow(im, origin="lower", cmap="gray", extent=[-e, e, -e, e]); ax.set_title("HiRISE 反照率 ±40 m（北上）", loc="left"); ax.grid(False)
        from scipy.ndimage import gaussian_filter
        bp = gaussian_filter(im, 1) - gaussian_filter(im, 6)
        bx.imshow(bp, origin="lower", cmap="gray", extent=[-e, e, -e, e], vmin=np.percentile(bp, 1), vmax=np.percentile(bp, 99)); bx.grid(False)
        pk = R["反照率"].get("HiRISE反照率谱峰") or {}
        bx.set_title(f"带通 0.25–1.5 m（谱峰 λ={pk.get('波长_m', float('nan')):.2f} m，波峰线 {pk.get('波峰线方向_deg', float('nan')):.0f}°）", loc="left")
        for a_ in (ax, bx): a_.set_xlabel("东（m）"); a_.set_ylabel("北（m）")
        fig.tight_layout(); figs.append(("图7_HiRISE反照率核对.png", fig))
    # 图3 各向异性
    an = R["各向异性"]; fig, axs = plt.subplots(1, 3, figsize=(12, 4.2))
    for j, k in enumerate(("近_r<6m", "中_2-15m")):
        g = an[k]; L_ = g["L"]; e = L_*g["cs"]
        axs[j].imshow(np.sqrt(np.maximum(g["g2"], 0)), origin="lower", extent=[-e, e, -e, e], cmap="viridis", norm=plt.matplotlib.colors.LogNorm())
        axs[j].set_title(f"{k} 二维 ν(Δx, Δy)（m）", loc="left"); axs[j].set_xlabel("东向 Δx（m）"); axs[j].set_ylabel("北向 Δy（m）"); axs[j].grid(False)
    axs[2].remove(); ax = fig.add_subplot(1, 3, 3, projection="polar")
    seq = [C["blue"], C["aqua"], C["yellow"], C["orange"], C["violet"], C["red"]]
    for i, row in enumerate(an["近_r<6m"]["行"]):
        t = np.radians(np.r_[row["角_deg"], row["角_deg"] + 180, row["角_deg"][:1] + 360]); v = np.r_[row["nu"], row["nu"], row["nu"][:1]]
        ax.plot(t, v/v.mean(), color=seq[i % 6], lw=1.5, label=f"Δx={row['滞后_m']:g} m（比 {row['比']:.2f}）")
    ax.set_title("近层 ν(θ)/均值（0°＝东，逆时针）", fontsize=9, pad=18); ax.legend(fontsize=6.5, loc="lower left", bbox_to_anchor=(-0.25, -0.25))
    dg = an.get("诊断", {})
    if dg:
        t = "径向/切向 ν 比：" + "  ".join(f"{r['滞后_m']:g} m {r['径向比切向']:.2f}" for r in dg["径向切向_近r<6"])
        t += "\n分扇区 南北/东西 ν 比（0.5 m）：" + "  ".join(f"{k} {float(v['南北比东西'][-2]):.2f}" for k, v in dg["分扇区_近r<6"].items())
        t += "\n0.5 m 高通后 最大/最小：" + "  ".join(f"{r['滞后_m']:g} m {r['比']:.2f}" for r in dg["高通0.5m"])
        fig.text(0.01, 0.01, t, fontsize=7, color=C["ink2"], va="bottom")
    fig.tight_layout(rect=(0, 0.1, 1, 0.97)); figs.append(("图3_各向异性.png", fig))
    # 图4 坡度分布
    fig, ax = plt.subplots(figsize=(7.5, 4.6)); xs = np.linspace(-8, 8, 400)
    seq = [("2cm_近r<3", C["blue"]), ("10cm_近r<6", C["aqua"]), ("1m_中r<15", C["orange"]), ("5m_中r<30", C["violet"]), ("5m_HiRISE", C["green"])]
    for k, c_ in seq:
        v = R["坡度"].get(k)
        if not v: continue
        e = v["直方"]["edges"]; ax.plot(0.5*(e[1:] + e[:-1]), np.maximum(v["直方"]["pdf"], 1e-7), color=c_, label=f"{k}：RMS {v['rms_deg']:.1f}°，峰度 {v['峰度']:.1f}，β {v['广义高斯β']:.2f}")
    ax.plot(xs, np.exp(-xs**2/2)/math.sqrt(2*math.pi), color=C["muted"], ls="--", lw=1, label="高斯")
    ax.plot(xs, np.exp(-np.abs(xs)*math.sqrt(2))/math.sqrt(2), color=C["muted"], ls=":", lw=1, label="拉普拉斯（同方差）")
    ax.set_yscale("log"); ax.set_ylim(1e-5, 1); ax.set_xlabel("坡度分量 / 标准差"); ax.set_ylabel("概率密度"); ax.legend(fontsize=7)
    ax.set_title("坡度分量分布（各基线，标准化）", loc="left"); fig.tight_layout(); figs.append(("图4_坡度分布.png", fig))
    # 图5 石块
    rk = R["石块"]; fig, (ax, bx) = plt.subplots(1, 2, figsize=(10.5, 4.2))
    for k, c_ in (("累计_r<4m", C["blue"]), ("累计_r<6m", C["aqua"]), ("累计_r<9m", C["orange"])):
        v = rk.get(k)
        if v is None or not len(v["D"]): continue
        ax.step(v["D"], v["F"], where="post", color=c_, label=f"实测 {k[3:]}（完整 D≥{v['完整下限D_m']*100:.0f} cm）")
    Dg = np.geomspace(0.05, 1.5, 60)
    for kk, ls in ((0.005, ":"), (0.01, "--"), (0.02, "-."), (0.05, (0, (1, 3)))):
        ax.plot(Dg, golombek_F(Dg, kk), color=C["muted"], ls=ls, lw=1, label=f"Golombek k={kk}")
    best = rk["拟合"].get("r<6m_D≥0.15m") or next(iter(rk["拟合"].values()), None)
    if best: ax.plot(Dg, golombek_F(Dg, best["k"]), color=C["red"], lw=1.5, label=f"拟合 k={best['k']:.4f}（r<6 m，D≥15 cm）")
    ax.set_xscale("log"); ax.set_yscale("log"); ax.set_ylim(1e-4, 0.1); ax.set_xlabel("直径 D（m）"); ax.set_ylabel("累计覆盖率 F(≥D)"); ax.legend(fontsize=6.5); ax.set_title("石块尺寸—频率", loc="left")
    g = rk.get("格局_r<6m_D≥8cm")
    if g:
        bx.fill_between(g["r"], g["g_lo"], g["g_hi"], color=C["muted"], alpha=0.25, lw=0, label="泊松（同窗口）95% 包络")
        bx.plot(g["r"], g["g"], color=C["blue"], marker="o", ms=4, label=f"实测 D≥8 cm，n={g['n']}，R={g['R']:.2f}（均匀零假设）")
        gi = rk.get("格局_r<6m_D≥8cm_按地类非均匀")
        if gi: bx.plot(gi["r"], gi["g"], color=C["orange"], marker="s", ms=4, lw=1.2, label=f"同上，按地类非均匀零假设：R={gi['R']:.2f}")
        bx.axhline(1, color=C["muted"], lw=0.8); bx.set_xscale("log"); bx.set_xlabel("间距 r（m）"); bx.set_ylabel("对相关 g(r)"); bx.legend(fontsize=7); bx.set_title("石块空间格局", loc="left")
    fig.tight_layout(); figs.append(("图5_石块.png", fig))
    # 图6 反照率
    al = R["反照率"]; fig, (ax, bx) = plt.subplots(1, 2, figsize=(11, 4.4))
    for k, c_ in (("ν_近1cm_r<6", C["blue"]), ("ν_中4cm_2-8m", C["orange"]), ("ν_中4cm_8-20m", C["yellow"]), ("ν_中4cm_20-45m", C["magenta"]), ("ν_HiRISE25cm_±500m", C["violet"]), ("ν_HiRISE25cm_±50m", C["aqua"])):
        v = al.get(k)
        if v: ax.plot(v["lag"], v["nu"], color=c_, label=k[2:])
    ax.set_xscale("log"); ax.set_yscale("log"); ax.set_xlabel("Δx（m）"); ax.set_ylabel("ν[ln 反照率]（≈相对起伏）"); ax.legend(fontsize=7); ax.set_title("反照率结构函数", loc="left")
    for k, c_ in (("相关_近2cm_r<6", C["blue"]), ("相关_中20cm_r<25", C["orange"]), ("相关_HiRISE1m_±1km", C["violet"])):
        v = al.get(k)
        if not v: continue
        s_ = [r["尺度_m"] for r in v]
        bx.errorbar(s_, [r["反照率_高程"] for r in v], yerr=[r["标准误"] for r in v], color=c_, marker="o", ms=4, capsize=2, label=f"{k[3:]}：与高程（±1 标准误）")
        bx.plot(s_, [r["反照率_坡度"] for r in v], color=c_, marker="s", ms=4, ls="--", lw=1.2, label=f"{k[3:]}：与坡度")
    bx.axhline(0, color=C["muted"], lw=0.8); bx.set_xscale("log"); bx.set_ylim(-1, 1); bx.set_xlabel("带通尺度 σ（m）"); bx.set_ylabel("皮尔逊相关"); bx.legend(fontsize=6.5)
    bx.set_title("反照率 vs 高程/坡度（同频段带通）", loc="left"); fig.tight_layout(); figs.append(("图6_反照率.png", fig))
    # 图0 自检、噪声
    fig, (ax, bx) = plt.subplots(1, 2, figsize=(10.5, 4.2))
    v = S["_曲线_fBm"]; ax.plot(v["lag"], v["nu"], color=C["blue"], label="fBm H=0.5")
    ax.plot(v["lag"], v["nu_holes"], color=C["orange"], ls="--", label="同上挖洞 40%"); v = S["_曲线_白"]; ax.plot(v["lag"], v["nu"], color=C["muted"], label="白噪声 σ=5 mm")
    v = S["_曲线_加噪"]; ax.plot(v["lag"], v["nu"], color=C["violet"], label="fBm H=0.6 + 3 mm 噪声")
    ax.set_xscale("log"); ax.set_yscale("log"); ax.set_xlabel("Δx（m）"); ax.set_ylabel("ν（m）"); ax.legend(fontsize=7); ax.set_title("自检：合成曲面", loc="left")
    for k, v in R["噪声"].items():
        bx.plot(v["lag"], v["nu_噪"], label=f"{k}（点 σ 组 {v['点σ_组']*1000:.1f} mm，模型 {v['模型σ_中点']*1000:.1f}）", lw=1.5)
    bx.set_xscale("log"); bx.set_yscale("log"); bx.set_xlabel("Δx（m）"); bx.set_ylabel("ν_噪 = ν(奇−偶)/2（m）"); bx.legend(fontsize=6.5); bx.set_title("实测立体噪声（奇/偶 sol 差场）", loc="left")
    fig.tight_layout(); figs.append(("图0_自检与噪声.png", fig))
    from matplotlib.ticker import FuncFormatter, NullFormatter
    fmt = FuncFormatter(lambda v, _: f"{v:g}")                             # 对数轴用普通小数（中文字体没有数学减号）
    for name, f in figs:
        for a_ in f.axes:
            if getattr(a_, "name", "") == "polar": continue
            if a_.get_xscale() == "log": a_.xaxis.set_major_formatter(fmt); a_.xaxis.set_minor_formatter(NullFormatter())
            if a_.get_yscale() == "log": a_.yaxis.set_major_formatter(fmt); a_.yaxis.set_minor_formatter(NullFormatter())
        f.savefig(OUT/name); plt.close(f); log(f"  图 {name}")


if __name__ == "__main__":
    step = sys.argv[1] if len(sys.argv) > 1 else "全部"
    OUT.mkdir(parents=True, exist_ok=True)
    if step == "自检":
        S = 自检(); (OUT/"自检.json").write_text(json.dumps(_json(S), ensure_ascii=False, indent=1))
        for k, v in S.items():
            if not k.startswith("_"): log(k, json.dumps(_json(v), ensure_ascii=False))
    elif step == "噪声":
        噪声栅格()
    elif step == "全部":
        S = 自检(); (OUT/"自检.json").write_text(json.dumps(_json(S), ensure_ascii=False, indent=1))
        R, lay = 全部(); R["_HiRISE裁"] = R["反照率"].pop("_HiRISE裁")
        R_out = {k: v for k, v in R.items() if not k.startswith("_")}; R_out["各向异性"] = {k: ({kk: vv for kk, vv in v.items() if kk not in ("g2",)} if isinstance(v, dict) and "g2" in v else v if k == "诊断" else
                                               {"峰": v.get("峰"), "谱": None if not v.get("谱") else {kk: v["谱"][kk] for kk in ("k", "P", "块", "n块", "拟合")}} if isinstance(v, dict) and "峰" in v else v)
                                           for k, v in R["各向异性"].items()}
        for nm_, v in R_out["地类"].items():
            if isinstance(v, dict) and "各向异性" in v: v["各向异性"] = [{kk: vv for kk, vv in a.items()} for a in v["各向异性"]]
        (OUT/"指纹.json").write_text(json.dumps(_json(R_out), ensure_ascii=False, indent=1))
        画图(R, lay, S)
        log(f"全部 ✓（{R['耗时_s']:.0f} s）→ {OUT}")
