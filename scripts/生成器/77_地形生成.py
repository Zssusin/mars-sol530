"""
77 地形生成（地形生成器 v0 · S2 合成器 + S3 留出验证）。设计见 docs/地形生成调研/地形生成器设计.md，结果见 v0_结果.md。
  只读 76 的参数图（只用轨道数据）+ 57 缓存里的轨道层（HiRISE/CTX/MOLA 高程、HiRISE 反照率），生成 2 cm – 3 m 的地形，
  写成和 57「导出/」同一种格式，放到 站26_1222/生成/（不碰 重建/、封存_*/、godot/数据/sol0530/）。
  方法：
    · 分频带补缺：≥ 3 m 用 HiRISE（三次插值）；3 m 以下 8 个倍频程的带通噪声（格点高斯白噪声 → 格点上 DoG(1, 2 格) → 三次 B 样条），
      格点间距 λ/6.5，每个倍频程转一个黄金角、平移一个哈希偏移（避免轴向伪影）。格点值 = 哈希(种子, 倍频程, 整数格点坐标)，
      所以结果确定，任意分块无缝。各倍频程振幅 a_b(x) 由目标结构函数定：
        ν_目标(L; x) = A3(x)·g(L)·m(x, L)，g = 指纹 H(尺度) 曲线（3 m → 0.3 m 0.85、→ 0.1 m 0.79、→ 2 cm 0.70），m = 地类倍率（≤ 10 cm 处）
        ν_合成² = ν_目标² − ν_HiRISE²（HiRISE 自身在 L 上的增量）− ν_石块²（石块层的贡献，按 k 查标定表），下限 (0.25 ν_目标)²
        a_b = e(H_b)·ν_合成(λ_b)，e(H) 由标定（非负最小二乘）给出。
    · 显式对象：卵石/石块（Golombek k(x) 的泊松撒点，每个尺寸档按 (种子, 档, 格号) 播种；< 10 cm 的 Matérn II 硬核；≥ 15 cm 的 35% 带 1–3 块碎块）；
      坑（76 坑表，Watters 2015 幂律剖面 + 扩散老化）；厘米级沙纹（λ 8 cm、高 3 mm，脊垂直于输沙 276°）和米级沙波（76 沙波指数处），
      都是相位噪声，只在沙上；休止角 33°（只对松散层，石块之前做）。
    · 反照率：HiRISE 颜色 × 对比度增益 1.45（8 m 以下）× exp(高程带通分量 + 纹理噪声 + 每块石头的明暗)。
  子命令（fedora：.venv/bin/python scripts/生成器/77_地形生成.py <子命令>）：
    标定   带通噪声的归一化与自相关、e(H) 表、石块层 ν 表、闭合检验（只用合成数据）→ 生成/标定.npz
    生成   近 2 cm ±10 m、中 10 cm ±50 m、远 25 cm ±320 m 三层 + 反照率 + 石块表 → 生成/地形.npz 等；打印每层耗时
    导出   57「导出/」同格式 → 生成/导出/
    游戏   61 原样转 Godot 数据 → 生成/godot_生成/sol0530（机位、天空、车用真实版的）；真实版 reflink 一份到 生成/godot_真/sol0530
    统计   S3 统计关：64 的 指纹/比较 对照 Navcam 真值（同格距同掩膜），容差照设计稿 §4 → 生成/验证/统计.json、统计.md
    材质   加分项：73「只用几何」在生成地形上分配材质，和真实版对比
数据：NASA/JPL-Caltech/University of Arizona/USGS（HiRISE、CTX、MOLA；验证用 Mars 2020 Navcam）。
"""
import hashlib, importlib.util, json, math, os, pathlib, shutil, subprocess, sys, time
os.environ.setdefault("OMP_NUM_THREADS", "8"); os.environ.setdefault("OPENBLAS_NUM_THREADS", "8")
import numpy as np
import warnings; warnings.filterwarnings("ignore", category=RuntimeWarning)

HERE = pathlib.Path(__file__).resolve().parent
MAP = HERE.parent.parent
SITE = MAP/"DEM"/"Blender缓存"/"_素材"/"PDS"/"站26_1222"
REC = SITE/"重建"
GEN = SITE/"生成"
VAL = GEN/"验证"
CLASSES = ("沙", "砾石风化层", "基岩", "暗色岩块")
SEED = 530
LAYERS = {"近": (0.02, 1000), "中": (0.10, 1000), "远": (0.25, 2560)}       # 格距 m、边长格数：±10 m、±50 m、±320 m
倍频程下限 = {"近": 1.1, "中": 1.8, "远": 1.8}                              # 用到 λ ≥ 系数·格距（近层要含 2 cm 格内的起伏，同真值）
OCT = [6.0*2.0**-b for b in range(9)]                                     # 合成带：6 m … 2.3 cm（6 m 倍频程 HiRISE 只分辨一半，补一半功率）
LAT = 6.5                                                                  # 格点间距 = λ/6.5（格点上 DoG σ 1、2 格的峰在 6.5 格）
GA = 2.399963229728653                                                     # 黄金角
H_曲线 = [(0.02, 0.10, 0.70), (0.10, 0.30, 0.79), (0.30, 3.0, 0.85)]
地类ν10 = np.array([7.1, 10.0, 9.5, 7.6])                                  # 指纹 §3.2：各地类 ν(10 cm)，mm → 地类倍率
石块 = dict(D0=0.03, 档=6, 格倍=16.0, 硬核D=0.10, 碎块概率=0.35, 网格D=0.15, 中层D=0.20, hD中位=0.30, hD散=0.25, 明暗均=0.0, 明暗散=0.12)
沙纹 = dict(λ=0.08, 高=0.003, 相位λ=0.6, 斑块λ=1.5)
休止角 = 33.0
反照率 = dict(增益=1.45, 低通m=8.0, 纹理std=0.06, 高程std=0.02, 细σ=0.5, 细权=1.2)
素材 = {"沙": ["p8_0_M1_1", "p8_0_M1_2", "p9_2818_M18_1", "p9_2818_M18_2"],             # 多站样块库（docs/地面材质/样块库.md），不用本站 s0530 的块
      "砾石风化层": ["p22_788_M16_1", "p22_788_M17_1", "p56_1010_M22_1", "p56_1010_M22_2"],
      "基岩": ["p7_2050_M14_1", "p7_2050_M14_2", "p7_2050_M14_3"],
      "暗色岩块": ["p61_376_M11_1", "p61_376_M11_2", "p61_376_M11_3"]}
素材格 = 0.6                                                                # 随机铺贴的格边（m），格之间按帐篷权保方差混合
素材增益 = 2.2                                                              # 样块 ln 对比度 × 2.2：多站样块 ν[lnA] ≈ 0.12，指纹定的地面目标 0.25–0.30（§2.6）
间歇 = dict(s=0.5, λ下限=0.375)                                             # 振幅的对数正态间歇性（≥ 0.375 m 的倍频程）


def log(*a): print("[77]", *a, flush=True)


def _mod(name, path):
    spec = importlib.util.spec_from_file_location(name, path); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m


_F = _M57 = None
def F64():
    global _F
    if _F is None: _F = _mod("m64", HERE/"64_地形指纹.py")
    return _F


def M57():
    global _M57
    if _M57 is None: _M57 = _mod("m57", MAP/"scripts"/"Blender"/"57_实景重建.py")
    return _M57


def 网格(cs, n): return (np.arange(n) + 0.5 - n/2)*cs


# ── ① 哈希 ───────────────────────────────────────────────────────────
def _sm(x):
    """splitmix64（uint64 数组，溢出即取模）。"""
    with np.errstate(over="ignore"):
        x = x + np.uint64(0x9E3779B97F4A7C15)
        x = (x ^ (x >> np.uint64(30)))*np.uint64(0xBF58476D1CE4E5B9)
        x = (x ^ (x >> np.uint64(27)))*np.uint64(0x94D049BB133111EB)
        return x ^ (x >> np.uint64(31))


def 哈希(*k):
    return int.from_bytes(hashlib.blake2b(repr(k).encode(), digest_size=8).digest(), "little")


def 格点高斯(tag, I, J):
    """(种子, tag, 整数格点 I, J) → 标准正态（Box–Muller）。"""
    h0 = _sm(np.uint64(哈希(SEED, tag) & 0xFFFFFFFFFFFFFFFF))
    with np.errstate(over="ignore"):
        h1 = _sm(h0 ^ _sm(I.astype(np.int64).view(np.uint64) ^ _sm(J.astype(np.int64).view(np.uint64) + np.uint64(0x632BE59BD9B4E019))))
        h2 = _sm(h1 ^ np.uint64(0xD1B54A32D192ED03))
    u1 = ((h1 >> np.uint64(11)).astype(np.float64) + 0.5)/2.0**53; u2 = (h2 >> np.uint64(11)).astype(np.float64)/2.0**53
    return (np.sqrt(-2*np.log(u1))*np.cos(2*np.pi*u2)).astype(np.float32)


# ── ② 带通噪声（逐点只依赖世界坐标）────────────────────────────────────
_NORM = None


def 带噪(tag, b, λ, xs, ys, norm=True):
    """倍频程 b（波长 λ）的带通噪声在网格 (ys 行 × xs 列) 上的值。格点在旋转 b·黄金角、平移哈希偏移的坐标系里，间距 λ/6.5；
    格点白噪声先在格点上做 DoG(σ 1 格 − σ 2 格)，再按三次 B 样条（不预滤波，即局部卷积）求值 → 和取哪块、多大无关。"""
    from scipy.ndimage import gaussian_filter, map_coordinates
    s = λ/LAT; th = (b*GA) % (2*math.pi); c, sn = math.cos(th), math.sin(th)
    h = 哈希(SEED, tag, b, "偏移"); ou, ov = (h & 0xFFFF)/65536.0, ((h >> 16) & 0xFFFF)/65536.0
    xs = np.asarray(xs, np.float64); ys = np.asarray(ys, np.float64); out = np.empty((len(ys), len(xs)), np.float32); M = 12
    dpx = abs(xs[1] - xs[0]) if len(xs) > 1 else λ
    blk = int(np.clip(2400/(math.sqrt(2)*dpx/s), 64, 1024))                  # 每块（转过之后）的格点 ≲ 2400²
    for r0 in range(0, len(ys), blk):
        for c0 in range(0, len(xs), blk):
            x_, y_ = xs[c0:c0 + blk], ys[r0:r0 + blk]
            xx = np.array([x_[0], x_[-1], x_[0], x_[-1]]); yy = np.array([y_[0], y_[0], y_[-1], y_[-1]])
            U = (c*xx + sn*yy)/s + ou; V = (-sn*xx + c*yy)/s + ov
            j0, j1 = int(math.floor(U.min())) - M, int(math.ceil(U.max())) + M; i0, i1 = int(math.floor(V.min())) - M, int(math.ceil(V.max())) + M
            I, J = np.meshgrid(np.arange(i0, i1 + 1), np.arange(j0, j1 + 1), indexing="ij")
            G = 格点高斯((tag, b), I, J); del I, J
            g = gaussian_filter(G, 1.0, truncate=4.0) - gaussian_filter(G, 2.0, truncate=4.0); del G
            u = (c*x_[None, :] + sn*y_[:, None])/s + ou - j0; v = (-sn*x_[None, :] + c*y_[:, None])/s + ov - i0
            out[r0:r0 + blk, c0:c0 + blk] = map_coordinates(g, [v, u], order=3, prefilter=False, mode="nearest")
    if norm: out /= 标定()["噪声std"]
    return out


_CAL = None
def 标定():
    global _CAL
    if _CAL is None:
        z = np.load(GEN/"标定.npz"); _CAL = {k: z[k] for k in z.files}; _CAL["噪声std"] = float(_CAL["噪声std"])
    return _CAL


def ρ_表(u):
    C = 标定(); uu, rr = C["ρ_u"], C["ρ"]
    u = np.asarray(u, float); one = np.interp(np.log(np.clip(u, uu[0], uu[-1])), np.log(uu), 1 - rr)
    small = u < uu[0]; one = np.where(small, (1 - rr[0])*(u/uu[0])**2, one)
    return 1 - one


# ── ③ 目标结构函数 ────────────────────────────────────────────────────
def g_曲线(L):
    """ν(L)/ν(3 m)：指纹 H(尺度) 曲线，从 3 m 往下链式外推。"""
    L = np.asarray(L, float); out = np.ones_like(L); ref = 3.0; f = 1.0
    for lo, hi, H in sorted(H_曲线, key=lambda t: -t[1]):
        seg = (L >= lo) & (L <= hi) if lo > 0.02 else (L <= hi)
        out = np.where(seg, f*(L/hi)**H, out); f *= (lo/hi)**H
    return np.where(L > 3.0, (L/3.0)**0.9, out)


def ν_石块(L, k, 层):
    """石块层自身对 ν(L) 的贡献（标定表，k 之间按 log k 线性插值）。"""
    C = 标定(); kt, Lt, T = C[f"石ν_k_{层}"], C["石ν_L"], C[f"石ν_{层}"]
    lk = np.clip(np.log(np.asarray(k, float)), np.log(kt[0]), np.log(kt[-1])); fk = np.interp(lk, np.log(kt), np.arange(len(kt)))
    i0 = np.clip(np.floor(fk).astype(int), 0, len(kt) - 2); w = fk - i0
    col = np.array([np.interp(math.log(L), np.log(Lt), np.log(np.maximum(T[i], 1e-9))) for i in range(len(kt))])
    return np.exp((1 - w)*col[i0] + w*col[i0 + 1])


def 振幅图(P, 层, half=340.0, 石=True):
    """参数图（1 m）→ 各倍频程振幅 a_b（1 m 网格，±half）。
    a_b = B12/κ · c(λ_b) · m(x, λ_b)，B12 = HiRISE 12 m 倍频程带通 rms（76，HiRISE 完全分辨的最细一档），κ = 同一带通对 H 0.9 幂律噪声的响应（标定），
    c(λ) = (λ/12)^0.9（12 → 3 m）再接指纹 H(尺度) 曲线；m = 地类倍率（≤ 10 cm 全额，1 m 起为 1）。
    减去石块层在同一倍频程的带功率（按 k 查标定表），下限 25%。HiRISE DTM 有效分辨率 3–6 m（Kirk 2021）：6 m 倍频程只补一半功率。"""
    cs, n = float(P["cs"]), int(P["n"]); m = int(half/cs); o = n//2 - m; sl = (slice(o, o + 2*m), slice(o, o + 2*m))
    B6 = P["B12"][sl].astype(np.float64); W = P["W"][sl].astype(np.float64); k = P["k"][sl].astype(np.float64)
    mc = (W*(地类ν10/地类ν10.mean())).sum(-1)/np.maximum(W.sum(-1), 1e-6)
    C = 标定(); a6 = B6/float(C["κ"]); a = np.zeros((len(OCT),) + B6.shape, np.float32)
    for b, λ in enumerate(OCT):
        t = float(np.clip((0.0 - math.log10(λ))/1.0, 0, 1))
        tgt = a6*(0.25**0.9)*float(g_曲线(λ))*(1 + (mc - 1)*t)
        if 石 and f"石带_{层}" in C:
            kt = C[f"石带_k_{层}"]; rb = np.array([np.interp(math.log(λ), np.log(C["石带_λ"]), np.log(np.maximum(C[f"石带_{层}"][i], 1e-9))) for i in range(len(kt))])
            r = np.exp(np.interp(np.log(np.clip(k, kt[0], kt[-1])), np.log(kt), rb))
            tgt = np.sqrt(np.maximum(tgt**2 - r**2, (0.25*tgt)**2))
        a[b] = (tgt*(math.sqrt(0.5) if b == 0 else 1.0)).astype(np.float32)
    振幅图.拟合 = (float(np.median(a[1])), 0.0, 3.0)
    return a, -half + 0.5*cs, cs


def 取图(img, x0, cs_img, xs, ys, order=1):
    """规则网格图（第 0 行在南，格心 x0 + i·cs）在 (ys × xs) 网格上插值。"""
    from scipy.ndimage import map_coordinates
    out = np.empty((len(ys), len(xs)), np.float32); u = (np.asarray(xs) - x0)/cs_img; v_all = (np.asarray(ys) - x0)/cs_img
    j0 = max(int(math.floor(u.min())) - 4, 0); j1 = min(int(math.ceil(u.max())) + 5, img.shape[1])
    i0 = max(int(math.floor(v_all.min())) - 4, 0); i1 = min(int(math.ceil(v_all.max())) + 5, img.shape[0])
    img = np.asarray(img[i0:i1, j0:j1], np.float32); u = u - j0; x0 = x0 + i0*cs_img
    for r0 in range(0, len(ys), 512):
        v = (np.asarray(ys[r0:r0 + 512]) - x0)/cs_img
        V, U = np.meshgrid(v, u, indexing="ij"); out[r0:r0 + 512] = map_coordinates(img, [V, U], order=order, mode="nearest")
    return out


# ── ④ 石块 ───────────────────────────────────────────────────────────
import functools


@functools.lru_cache(maxsize=8192)
def golombek_tab(k, D1, D2, n=48):
    q = 1.79 + 0.152/max(k, 1e-5); D = np.geomspace(D1, D2, n); nd = k*q*np.exp(-q*D)/(math.pi*D*D/4)
    cdf = np.concatenate([[0], np.cumsum(0.5*(nd[1:] + nd[:-1])*np.diff(D))]); return cdf[-1], D, cdf/max(cdf[-1], 1e-12)


def 撒石(kfun, x0, x1, y0, y1, Dmin=None, 边=0.6):
    """区域 [x0, x1) × [y0, y1)（多取 边 m 余量）里的石块表。kfun(x, y) → Golombek k。尺寸档 b：D ∈ [D0·2^b, D0·2^(b+1))，
    格边 = 16·D0·2^b，每格按 (种子, '石', b, i, j) 播种：数目 Poisson(N_b(k)·格²)，D 按档内数目分布逆 CDF。
    返回字段：x y D hD p 椭 向 a2 a3 a4 φ2 φ3 φ4 明暗（每块的形状参数都来自同一个 rng，和分块无关）。"""
    from scipy.spatial import cKDTree
    rows = []
    for b in range(石块["档"]):
        d1 = 石块["D0"]*2**b; d2 = 2*d1; g = 石块["格倍"]*d1
        if Dmin is not None and d2 <= Dmin: continue
        for i in range(int(math.floor((y0 - 边)/g)), int(math.ceil((y1 + 边)/g))):
            for j in range(int(math.floor((x0 - 边)/g)), int(math.ceil((x1 + 边)/g))):
                cx, cy = (j + 0.5)*g, (i + 0.5)*g; k = float(kfun(cx, cy))
                if k <= 0: continue
                Nb, Dt, Ct = golombek_tab(round(k, 4), d1, d2)
                rng = np.random.default_rng(哈希(SEED, "石", b, i, j))
                for _ in range(rng.poisson(Nb*g*g)):
                    D = float(np.interp(rng.random(), Ct, Dt)); x = (j + rng.random())*g; y = (i + rng.random())*g
                    rows.append(_石参(rng, x, y, D))
                    if D >= 石块["网格D"] and rng.random() < 石块["碎块概率"]:               # 碎裂：1–3 块碎块
                        for _ in range(1 + rng.poisson(0.7)):
                            a = rng.random()*2*math.pi; r = D*rng.uniform(0.55, 0.9)
                            rows.append(_石参(rng, x + r*math.cos(a), y + r*math.sin(a), D*rng.uniform(0.25, 0.5)))
    R = np.array(rows, np.float64).reshape(-1, 14)
    if len(R) > 1:                                                         # Matérn II 硬核：< 10 cm 的互不重叠，标记小的让位
        mark = np.array([哈希(SEED, "标", round(x, 5), round(y, 5)) % 1000003 for x, y in R[:, :2]], float)
        T = cKDTree(R[:, :2]); small = R[:, 2] < 石块["硬核D"]; drop = np.zeros(len(R), bool)
        for i, j in T.query_pairs(石块["硬核D"]):
            if small[i] and small[j] and math.hypot(*(R[i, :2] - R[j, :2])) < 0.5*(R[i, 2] + R[j, 2]):
                drop[i if mark[i] < mark[j] else j] = True
        R = R[~drop]
    if Dmin is not None: R = R[R[:, 2] >= Dmin]
    s = (R[:, 0] >= x0 - 边) & (R[:, 0] < x1 + 边) & (R[:, 1] >= y0 - 边) & (R[:, 1] < y1 + 边)
    return R[s]


def _石参(rng, x, y, D):
    hD = float(np.clip(石块["hD中位"]*math.exp(rng.normal(0, 石块["hD散"])), 0.15, 0.8))
    return (x, y, D, hD, rng.uniform(1.3, 2.2), rng.uniform(0.6, 1.0), rng.uniform(0, math.pi),
            rng.normal(0, 0.10), rng.normal(0, 0.06), rng.normal(0, 0.04), rng.uniform(0, 2*math.pi), rng.uniform(0, 2*math.pi),
            rng.uniform(0, 2*math.pi), rng.normal(石块["明暗均"], 石块["明暗散"]))


def 石形(R, du, dv):
    """单块石头在局部偏移 (du, dv)（m，相对石心，ENU）处的露出高度：超椭圆足迹（半轴 D/2、椭·D/2，转 向）、轮廓按 2–4 阶谐波起伏，
    z = h·(1 − ρ^p)^(1/p)。R 是 (n, 14) 或一行；du, dv 可广播。"""
    D, hD, p, e, th = R[..., 2], R[..., 3], R[..., 4], R[..., 5], R[..., 6]
    c, s = np.cos(th), np.sin(th); u = c*du + s*dv; v = -s*du + c*dv
    a = 0.5*D; b_ = a*e; ang = np.arctan2(v/b_, u/a)
    edge = 1 + R[..., 7]*np.cos(2*ang + R[..., 10]) + R[..., 8]*np.cos(3*ang + R[..., 11]) + R[..., 9]*np.cos(4*ang + R[..., 12])
    rho = np.hypot(u/a, v/b_)/np.maximum(edge, 0.5)
    return np.where(rho < 1, hD*D*np.power(np.maximum(1 - rho**p, 0), 1/p), 0.0)


def 画石(R, xs, ys, 明暗=False):
    """石块表 → 网格上的露出高度（取最大，不叠加）；明暗=True 时另给每格「最高那块石头」的明暗（ln 反照率偏移），无石处 0。"""
    cs = float(xs[1] - xs[0]); ny, nx = len(ys), len(xs); Z = np.zeros(ny*nx, np.float32); B = np.zeros(ny*nx, np.float32) if 明暗 else None
    if not len(R): return Z.reshape(ny, nx), (B.reshape(ny, nx) if 明暗 else None)
    rp = np.ceil(0.62*R[:, 2]*(1 + np.abs(R[:, 7]) + np.abs(R[:, 8]) + np.abs(R[:, 9]))/cs).astype(int) + 1
    for r in np.unique(rp):
        G = R[rp == r]; off = np.arange(-r, r + 1)
        ci = np.round((G[:, 1] - ys[0])/cs).astype(int); cj = np.round((G[:, 0] - xs[0])/cs).astype(int)
        for c0 in range(0, len(G), max(1, 2_000_000//(2*r + 1)**2)):
            g = G[c0:c0 + max(1, 2_000_000//(2*r + 1)**2)]; ii = ci[c0:c0 + len(g), None, None] + off[None, :, None]; jj = cj[c0:c0 + len(g), None, None] + off[None, None, :]
            du = xs[0] + jj*cs - g[:, 0, None, None]; dv = ys[0] + ii*cs - g[:, 1, None, None]
            z = 石形(g[:, None, None, :], du, dv)
            ok = (ii >= 0) & (ii < ny) & (jj >= 0) & (jj < nx) & (z > 0)
            idx = (ii*nx + jj)[ok]; zz = z[ok].astype(np.float32)
            np.maximum.at(Z, idx, zz)
            if 明暗:
                hb = np.broadcast_to(g[:, 13, None, None], z.shape)[ok].astype(np.float32); top = zz >= Z[idx] - 1e-7
                core = zz > 0.15*np.broadcast_to((g[:, 2]*g[:, 3])[:, None, None], z.shape)[ok]
                B[idx[top & core]] = hb[top & core]
    return Z.reshape(ny, nx), (B.reshape(ny, nx) if 明暗 else None)


# ── ⑤ 坑、沙波、休止角 ────────────────────────────────────────────────
def 画坑(P, xs, ys):
    cs = float(xs[1] - xs[0]); CT = P["坑表"]; s_tab, r_tab, prof = P["坑_s"], P["坑_r"], P["坑_剖面"]
    ny, nx = len(ys), len(xs); Z = np.zeros((ny, nx), np.float32); n = 0
    sel = (CT[:, 2] >= 3*cs) & (CT[:, 0] + 2.5*CT[:, 2] > xs[0]) & (CT[:, 0] - 2.5*CT[:, 2] < xs[-1]) & \
          (CT[:, 1] + 2.5*CT[:, 2] > ys[0]) & (CT[:, 1] - 2.5*CT[:, 2] < ys[-1])
    for x, y, D, dd, s, *_ in CT[sel]:
        R_ = D/2; rr = r_tab[-1]*R_
        j0, j1 = max(0, int((x - rr - xs[0])/cs)), min(nx, int((x + rr - xs[0])/cs) + 2)
        i0, i1 = max(0, int((y - rr - ys[0])/cs)), min(ny, int((y + rr - ys[0])/cs) + 2)
        if j1 <= j0 or i1 <= i0: continue
        X, Y = np.meshgrid(xs[j0:j1], ys[i0:i1]); r = np.hypot(X - x, Y - y)/R_
        k = int(np.argmin(np.abs(s_tab - s))); f = np.interp(r, r_tab, prof[k], right=0.0)
        f -= np.interp(r_tab[-1], r_tab, prof[k])                            # 外缘归零
        Z[i0:i1, j0:j1] += (f*D).astype(np.float32); n += 1
    return Z, n


def 画沙波(P, xs, ys, Wsand, 厘米=True):
    """相位噪声：φ = 2π(k̂·x)/λ + 低频相位扰动；厘米级沙纹（只在格距 ≤ 2 cm 的层）+ 米级沙波（76 沙波指数 > 0 处）。都乘沙的权重。"""
    cs = float(xs[1] - xs[0]); X, Y = np.meshgrid(xs, ys); Z = np.zeros(X.shape, np.float32)
    t = math.radians(276.0); kx, ky = math.sin(t), math.cos(t)                # 输沙方向（自北顺时针）→ 波矢
    if 厘米 and cs <= 0.025:
        ph = 2*math.pi*(kx*X + ky*Y)/沙纹["λ"] + 2.0*带噪("沙纹相位", 0, 沙纹["相位λ"], xs, ys)
        patch = np.clip(0.5 + 0.6*带噪("沙纹斑块", 0, 沙纹["斑块λ"], xs, ys), 0, 1)
        Z += (0.5*沙纹["高"]*(np.sin(ph) + 0.25*np.sin(2*ph + 0.6))/1.03*patch*Wsand).astype(np.float32)
    idx = P["沙波指数"]; nb = idx.shape[0]; tile = 64.0                       # 76：256 px × 25 cm 的块，从 −1000 m 起
    if float(idx.max()) > 0:
        w = idx.astype(np.float64); λ = float((P["沙波波长"]*w).sum()/max(w.sum(), 1e-9)); cr = math.radians(float(np.median(P["沙波脊"][idx > 0])))
        kx2, ky2 = math.sin(cr + math.pi/2), math.cos(cr + math.pi/2)
        I = 取图(np.asarray(idx, np.float32), -1000 + tile/2, tile, xs, ys)
        if float(I.max()) > 0 and λ >= 2.5*cs:
            ph = 2*math.pi*(kx2*X + ky2*Y)/λ + 2.5*带噪("沙波相位", 0, 3*λ, xs, ys)
            h = float(np.clip(0.07*λ, 0.05, 0.3))
            Z += (0.5*h*(np.sin(ph) + 0.3*np.sin(2*ph + 0.6))/1.05*I*Wsand).astype(np.float32)
    return Z


def 休止角(Z, cs, deg=休止角, it=30):
    """松散层坡度上限：相邻格高差 > tan(角)·距离 的部分各让一半（热侵蚀式，30 轮）。"""
    t = math.tan(math.radians(deg))*cs; Z = Z.astype(np.float32).copy(); n0 = 0
    for k in range(it):
        moved = 0
        for ax in (0, 1):
            d = np.diff(Z, axis=ax); ex = np.where(np.abs(d) > t, (np.abs(d) - t)*np.sign(d)*0.25, 0).astype(np.float32)
            moved += int((ex != 0).sum())
            if ax == 0: Z[:-1] += ex; Z[1:] -= ex
            else: Z[:, :-1] += ex; Z[:, 1:] -= ex
        if k == 0: n0 = moved
        if not moved: break
    return Z, n0


# ── ⑥ 一层 ───────────────────────────────────────────────────────────
def 生成层(层, P, T, Wcls, 石=True, 坑=True, 波=True, 限坡=True, 振幅=None):
    """返回 dict：地面（松散层，不含石块）、石（露出高度，全部）、石小（< 网格D，只近层用）、明暗、石表、合成带等。"""
    from scipy.ndimage import map_coordinates
    cs, n = LAYERS[层]; xs = ys = 网格(cs, n); t0 = time.time(); out = {}
    Lh = json.loads(str(T["levels"]))["HiRISE"]; hi = T["hirise"]
    Zh = np.empty((n, n), np.float32)
    for r0 in range(0, n, 512):
        V, U = np.meshgrid(ys[r0:r0 + 512]/Lh[0] + Lh[1]/2 - 0.5, xs/Lh[0] + Lh[1]/2 - 0.5, indexing="ij")
        Zh[r0:r0 + 512] = map_coordinates(hi, [V, U], order=3, mode="nearest")
    a, ax0, acs = 振幅 if 振幅 is not None else 振幅图(P, 层, 石=石 and 层 != "远")
    S = np.zeros((n, n), np.float32); used = []
    for b, λ in enumerate(OCT):
        if λ < 倍频程下限[层]*cs: continue
        f = 取图(a[b], ax0, acs, xs, ys)*带噪("地形", b, λ, xs, ys)
        if λ >= 间歇["λ下限"]: f *= np.exp(间歇["s"]*带噪("间歇", b, 4*λ, xs, ys) - 间歇["s"]**2)
        S += f; used.append(λ)
    out["合成带"] = S; t1 = time.time()
    if 振幅 is None: log(f"  {层}层：3 m 倍频程振幅中位 {振幅图.拟合[0]*1000:.1f} mm（接 HiRISE 12 m 带）")
    Wsand = 取图(Wcls[..., 0], -1000 + 0.125, 0.25, xs, ys)
    Zc, nc = 画坑(P, xs, ys) if 坑 else (np.zeros_like(S), 0)
    Zw = 画沙波(P, xs, ys, Wsand) if 波 else np.zeros_like(S)
    G = Zh + S + Zc + Zw
    if 限坡: G, nrep = 休止角(G, cs)
    else: nrep = 0
    t2 = time.time()
    out.update(地面=G, 坑=Zc, 沙波=Zw)
    Dmin = {"近": 石块["D0"], "中": 石块["中层D"]}.get(层)
    if 石 and Dmin is not None:
        kc = P["k"]; kfun = lambda x, y: float(kc[int(np.clip(y + 1000, 0, 1999)), int(np.clip(x + 1000, 0, 1999))])
        R = 撒石(kfun, xs[0], xs[-1] + cs, ys[0], ys[-1] + cs, Dmin=Dmin)
        Zr, Bm = 画石(R, xs, ys, 明暗=True); out.update(石=Zr, 明暗=Bm, 石表=R)
        if 层 == "近":
            out["石小"], _ = 画石(R[R[:, 2] < 石块["网格D"]], xs, ys)
    else:
        out.update(石=np.zeros_like(S), 石小=np.zeros_like(S), 明暗=np.zeros_like(S), 石表=np.zeros((0, 14)))
    t3 = time.time()
    out["耗时"] = dict(HiRISE加合成带=t1 - t0, 坑波限坡=t2 - t1, 石块=t3 - t2, 合计=t3 - t0)
    log(f"{层}层 {n}²×{cs} m：合成带 {len(used)} 个倍频程（{used[0]:g}–{used[-1]:g} m）std {S.std()*1000:.1f} mm；坑 {nc} 个；"
        f"沙波 std {Zw.std()*1000:.2f} mm；休止角首轮改 {nrep} 处；石块 {len(out['石表'])} 块；耗时 {t3 - t0:.1f} s"
        f"（噪声 {t1 - t0:.1f}，对象 {t3 - t1:.1f}）")
    return out


# ── ⑦ 反照率 ─────────────────────────────────────────────────────────
_TILE = {}
def 素材块(pid, cs):
    """样块库的一块：ln 反照率细节（RGB，均值 1 → ln 后去均值），周期地重采样到格距 cs。"""
    key = (pid, cs)
    if key not in _TILE:
        from scipy.ndimage import zoom, gaussian_filter
        lib = {r["id"]: r for r in json.loads((MAP/"scripts"/"Godot"/"地面样块库.json").read_text())["样块"]}
        r = lib[pid]; z = np.load(MAP/"资料"/"地面材质"/"样块库"/r["station"]/"切块"/f"{pid}.npz")
        L = np.log(np.clip(z["A"].astype(np.float32), 0.05, None)); f = r["px_m"]/cs
        L = np.stack([zoom(gaussian_filter(L[..., c], max(0.5/f - 0.5, 0), mode="wrap"), f, order=1, mode="grid-wrap", grid_mode=True) for c in range(3)], -1)
        _TILE[key] = (L - L.mean((0, 1))).astype(np.float32)
    return _TILE[key]


def 素材纹理(xs, ys, Wc):
    """各地类的样块随机铺贴：格边 0.6 m，每格按 (种子, 地类, 格号) 选块、转 90°×k、平移；相邻 4 格帐篷权混合，按 √Σw² 保方差。
    结果 = Σ_c W_c·T_c（ln 反照率，RGB）。只依赖世界坐标 → 分块无缝。"""
    cs = float(xs[1] - xs[0]); out = np.zeros((len(ys), len(xs), 3), np.float32); g = 素材格
    fx = np.asarray(xs)/g - 0.5; fy = np.asarray(ys)/g - 0.5; ix0 = np.floor(fx).astype(np.int64); iy0 = np.floor(fy).astype(np.int64)
    tx = (fx - ix0).astype(np.float32); ty = (fy - iy0).astype(np.float32)
    px = np.round(np.asarray(xs)/cs - 0.5).astype(np.int64); py = np.round(np.asarray(ys)/cs - 0.5).astype(np.int64)
    for ci, c in enumerate(CLASSES):
        if float(Wc[..., ci].max()) < 0.02: continue
        tiles = [素材块(pid, cs) for pid in 素材[c]]; acc = np.zeros_like(out); w2 = np.zeros(out.shape[:2], np.float32)
        for dy in (0, 1):
            for dx in (0, 1):
                wy = (ty if dy else 1 - ty)[:, None]; wx = (tx if dx else 1 - tx)[None, :]; w = wy*wx
                CY = (iy0 + dy)[:, None]; CX = (ix0 + dx)[None, :]
                with np.errstate(over="ignore"):
                    h = _sm(_sm(np.uint64(哈希(SEED, "素材", c) & 0xFFFFFFFFFFFFFFFF)) ^ _sm(CY.astype(np.uint64)) ^ _sm(_sm(CX.astype(np.uint64)) + np.uint64(7)))
                k = (h % np.uint64(len(tiles))).astype(np.int64); rot = ((h >> np.uint64(8)) % np.uint64(4)).astype(np.int64)
                ox = ((h >> np.uint64(16)) % np.uint64(4096)).astype(np.int64); oy = ((h >> np.uint64(32)) % np.uint64(4096)).astype(np.int64)
                for ti, T in enumerate(tiles):
                    m = np.broadcast_to(k == ti, w.shape)
                    if not m.any(): continue
                    n0, n1 = T.shape[:2]
                    for r_ in range(4):
                        mm = m & np.broadcast_to(rot == r_, w.shape)
                        if not mm.any(): continue
                        PY = np.broadcast_to(py[:, None], w.shape)[mm]; PX = np.broadcast_to(px[None, :], w.shape)[mm]
                        OY = np.broadcast_to(oy, w.shape)[mm]; OX = np.broadcast_to(ox, w.shape)[mm]
                        a, b = (PY + OY, PX + OX) if r_ == 0 else (PX + OX, -PY + OY) if r_ == 1 else (-PY + OY, -PX + OX) if r_ == 2 else (-PX + OX, PY + OY)
                        acc[mm] += w[mm][:, None]*T[a % n0, b % n1]
                w2 += w*w
        out += Wc[..., ci, None]*acc/np.sqrt(w2)[..., None]
    return out


def 反照率层(xs, ys, zbn, Bm, AH, Wc=None):
    """HiRISE 颜色（25 cm，双线性）× exp((增益−1)·(lnL − 8 m 低通)) × exp(高程带通分量 + 纹理 + 石块明暗)。
    zbn：已归一化的高程带通（在高程层原网格上算好再插值过来）。纹理 = 世界格点哈希白噪声（σ 0.8 格平滑，≈ 1–4 cm）
    + 3 个倍频程（0.09–0.375 m），只改亮度不改色相。返回 (ny, nx, 3) float32。"""
    from scipy.ndimage import gaussian_filter
    cs = float(xs[1] - xs[0]); A = AH["A"]; ca, na = float(AH["cs"]), int(AH["n"]); x0 = -ca*na/2 + ca/2
    o = int((xs[0] - 10 - x0)/ca); e = int((xs[-1] + 10 - x0)/ca) + 2; sub = A[o:e, o:e].astype(np.float32); sx0 = x0 + o*ca
    lum = np.log(np.maximum(sub.mean(-1), 1e-4)); lp = gaussian_filter(lum, 反照率["低通m"]/ca)
    out = np.stack([取图(sub[..., c], sx0, ca, xs, ys) for c in range(3)], -1)
    ln = 取图(((反照率["增益"] - 1)*(lum - lp)).astype(np.float32), sx0, ca, xs, ys)
    ln += 反照率["高程std"]*np.clip(zbn, -3, 3)
    I = np.round(np.asarray(ys)/cs - 0.5).astype(np.int64); J = np.round(np.asarray(xs)/cs - 0.5).astype(np.int64)
    fine = np.empty_like(ln)
    for r0 in range(0, len(ys), 1024):
        II, JJ = np.meshgrid(I[r0:r0 + 1024], J, indexing="ij"); fine[r0:r0 + 1024] = 格点高斯(("反照率细", cs), II, JJ)
    fine = gaussian_filter(fine, 反照率["细σ"]); fine /= fine.std()
    oc = np.zeros_like(ln)
    for b, λ in enumerate([0.375, 0.19, 0.094]):
        oc += 带噪("反照率纹理", b, λ, xs, ys)
    oc /= max(oc.std(), 1e-6)
    tex = 反照率["细权"]*fine + 0.6*oc; ln += 反照率["纹理std"]*tex/tex.std()
    if Bm is not None: ln += Bm
    lnc = ln[..., None] + (素材增益*素材纹理(xs, ys, Wc) if Wc is not None else 0.0)
    return np.clip(out*np.exp(lnc), 0, 1).astype(np.float32)


def 高程带通(Z, cs, lo_m, hi_m=1.0):
    """反照率用的高程带通（lo–hi m），按 2 m 窗的局部 rms 归一化。"""
    from scipy.ndimage import gaussian_filter
    zb = gaussian_filter(Z, max(lo_m/cs, 0.5)) - gaussian_filter(Z, hi_m/cs)
    return (zb/(np.sqrt(gaussian_filter(zb**2, 2.0/cs)) + 1e-5)).astype(np.float32)


# ── 子命令：标定 ─────────────────────────────────────────────────────
def cmd_标定():
    F = F64(); t0 = time.time(); GEN.mkdir(parents=True, exist_ok=True)
    λ = 1.0; cs = λ/32; n = 2048; xs = ys = 网格(cs, n)
    f = 带噪("标定", 0, λ, xs, ys, norm=False); sd = float(f.std())
    sf = F.结构函数(f/sd, cs, np.ones_like(f, bool), F.滞后表(400, 12))
    u = sf["lag"]/λ; rho = 1 - sf["nu"]**2/2
    # 各向同性检查：四方向 ν 的最大/最小
    nd = np.stack([sf["nu_dir"][k] for k in sf["nu_dir"] if np.all(np.isfinite(sf["nu_dir"][k]))]); aniso = float(np.nanmax(nd.max(0)/nd.min(0)))
    log(f"带通噪声：std {sd:.4f}（未归一），ρ(0.5λ) {np.interp(0.5, u, rho):+.2f}，ρ(λ) {np.interp(1, u, rho):+.2f}，四方向 ν 最大/最小 {aniso:.3f}")
    np.savez(GEN/"标定.npz", 噪声std=sd, ρ_u=u, ρ=rho); global _CAL; _CAL = None
    # e(H)：纯幂律目标 ν = L^H，倍频程 λ_b = 3·2^−b（b −6…14），NNLS 拟 ν²（相对误差）
    lam = 3.0*2.0**-np.arange(-6, 15); L = np.geomspace(0.01, 6.0, 60)
    Mx = 2*(1 - ρ_表(L[:, None]/lam[None, :])); eH = np.linspace(0.3, 1.2, 19); e = []
    for H in eH:                                                             # a_b = e·λ_b^H：e² = 目标 / 模型（几何平均，L 取中段）
        base = Mx @ lam**(2*H); mid = (L > 0.03) & (L < 1.5)
        e.append(float(np.sqrt(np.exp(np.mean(np.log(L[mid]**(2*H)/base[mid]))))))
        if abs(H - 0.8) < 1e-6:
            rr = np.sqrt(e[-1]**2*base)/L**H
            log(f"  e(0.8) = {e[-1]:.3f}；用 a_b = e·λ_b^H 复原 ν/目标（3 cm–1.5 m）：{rr[mid].min():.3f}–{rr[mid].max():.3f}")
    # 石块层 ν 表（近层 2 cm 全部 ≥ 3 cm、中层 10 cm ≥ 20 cm），地面为 0、k 均匀
    kt = np.array([0.003, 0.006, 0.012, 0.024, 0.048, 0.096]); Lt = np.geomspace(0.02, 3.0, 25); out = {}
    for 层, cs_, n_, Dmin in (("近", 0.02, 600, 石块["D0"]), ("中", 0.10, 400, 石块["中层D"])):
        xs_ = 网格(cs_, n_) + 200.0; rows = []
        for k in kt:
            R = 撒石(lambda x, y: k, xs_[0], xs_[-1] + cs_, xs_[0], xs_[-1] + cs_, Dmin=Dmin)
            Z, _ = 画石(R, xs_, xs_)
            if Z.std() == 0: rows.append(np.full(len(Lt), 1e-9)); continue
            s = F.结构函数(Z.astype(np.float64), cs_, np.ones_like(Z, bool), F.滞后表(int(3.0/cs_), 10))
            rows.append(np.exp(np.interp(np.log(Lt), np.log(s["lag"]), np.log(np.maximum(s["nu"], 1e-9)))))
            if abs(k - 0.024) < 1e-9:
                log(f"  石块层（{层}，k {k}）：{len(R)} 块/{(cs_*n_)**2:.0f} m²，ν(2 cm/10 cm/1 m) = " +
                    "/".join(f"{np.interp(math.log(l), np.log(Lt), np.log(rows[-1])):.4f}" for l in (0.02, 0.1, 1.0)).replace("nan", "-"))
        out[f"石ν_{层}"] = np.array(rows); out[f"石ν_k_{层}"] = kt
    np.savez(GEN/"标定.npz", 噪声std=sd, ρ_u=u, ρ=rho, e_H=eH, e=np.array(e), 石ν_L=Lt, **out); _CAL = None
    # κ：H 0.9 幂律倍频程噪声（λ 3·2^−b，b −4…6，a = λ^0.9）在 λ_ref 倍频程带通（DoG λ/6.5、2λ/6.5）上的 rms / a(λ_ref)
    from scipy.ndimage import gaussian_filter
    lr = 0.75; cs_ = lr/16; n_ = 1536; xs_ = 网格(cs_, n_) + 11.0; S = np.zeros((n_, n_), np.float32)
    for b in range(-4, 7):
        lb = 3.0*2.0**-b; S += float(lb**0.9)*带噪("κ", b, lb, xs_, xs_)
    d = gaussian_filter(S, lr/6.5/cs_) - gaussian_filter(S, 2*lr/6.5/cs_); κ = float(d[64:-64, 64:-64].std()/lr**0.9)
    one = 带噪("κ", 3, lr, xs_, xs_); d1 = gaussian_filter(one, lr/6.5/cs_) - gaussian_filter(one, 2*lr/6.5/cs_); κ1 = float(d1[64:-64, 64:-64].std())
    log(f"κ（H 0.9 全倍频程）= {κ:.3f}；单倍频程 κ1 = {κ1:.3f}")
    # 石块层的倍频程带功率（同一带通 / κ1 → 等效振幅）
    lt = np.array(OCT); band = {}
    for 层, cs_l, n_l, Dmin in (("近", 0.02, 600, 石块["D0"]), ("中", 0.10, 400, 石块["中层D"])):
        xs_ = 网格(cs_l, n_l) + 200.0; rows = []
        for k in kt:
            R = 撒石(lambda x, y: k, xs_[0], xs_[-1] + cs_l, xs_[0], xs_[-1] + cs_l, Dmin=Dmin); Z, _ = 画石(R, xs_, xs_)
            rows.append([float((gaussian_filter(Z, λ/6.5/cs_l) - gaussian_filter(Z, 2*λ/6.5/cs_l))[20:-20, 20:-20].std())/κ1 + 1e-9 for λ in lt])
        band[f"石带_{层}"] = np.array(rows); band[f"石带_k_{层}"] = kt
    np.savez(GEN/"标定.npz", 噪声std=sd, ρ_u=u, ρ=rho, e_H=eH, e=np.array(e), 石ν_L=Lt, κ=κ, κ1=κ1, 石带_λ=lt, **out, **band); _CAL = None
    log("  石块带振幅（近，k 0.024，mm）：" + " ".join(f"{l:g}:{v*1000:.2f}" for l, v in zip(lt, band["石带_近"][3])))
    # 闭合检验    # 闭合检验：A3 = 0.2 m、无 HiRISE、无石块 → 近层 2 cm 合成带的 ν 对目标
    xs_ = 网格(0.02, 800) + 37.0; S = np.zeros((800, 800), np.float32)
    for b, lb in enumerate(OCT):
        if lb < 1.1*0.02: continue
        Hb = 0.85 if lb >= 0.3 else (0.79 if lb >= 0.1 else 0.70)
        S += float(np.interp(Hb, eH, e)*0.2*g_曲线(lb))*带噪("闭合", b, lb, xs_, xs_)
    s = F.结构函数(S.astype(np.float64), 0.02, np.ones_like(S, bool), F.滞后表(150, 10)); rr = s["nu"]/(0.2*g_曲线(s["lag"]))
    log(f"闭合检验（目标 = 0.2·g(L)）：ν/目标 2 cm {rr[0]:.2f}，10 cm {np.interp(0.1, s['lag'], rr):.2f}，0.5 m {np.interp(0.5, s['lag'], rr):.2f}，"
        f"1 m {np.interp(1.0, s['lag'], rr):.2f}（{time.time() - t0:.0f} s）")


# ── 子命令：生成 ─────────────────────────────────────────────────────
def cmd_生成(args=()):
    from scipy.ndimage import gaussian_filter
    t0 = time.time(); P = dict(np.load(GEN/"参数图.npz")); T = np.load(REC/"地形.npz")
    Wcls = np.load(GEN/"地类_轨道_25cm.npy", mmap_mode="r")
    AH = np.load(REC/"反照率_HiRISE.npz")
    pre = "" if not args else args[0]                                       # 变体前缀（消融）：如 "无石_"
    if pre == "只反照率": return 只反照率(P, Wcls, AH)
    kw = dict(石="无石" not in pre, 坑="无坑" not in pre, 波="无波" not in pre)
    if "全局振幅" in pre: P["B12"] = np.full_like(P["B12"], float(np.sqrt(np.mean(P["B12"]**2))))      # 消融：整片 ±1 km 的均方根振幅
    L = {}; 耗时 = {}
    for 层 in ("近", "中", "远"):
        if pre and 层 == "远": continue
        L[层] = 生成层(层, P, T, Wcls, **kw); 耗时[层] = L[层]["耗时"]
    # 车轮触地（车的位姿 → 六个触地点，和 57 一样只改车底一圈）：近层的地面
    M = M57(); cs, n = LAYERS["近"]; X, Y = np.meshgrid(网格(cs, n), 网格(cs, n))
    has = ~M.under_rover(X, Y, margin=0.3)
    g0 = L["近"]["地面"]; L["近"]["地面"] = M.wheel_contacts(g0.astype(np.float64), has).astype(np.float32)
    log(f"车轮触地：车底改正最大 {np.abs(L['近']['地面'] - g0).max()*100:.1f} cm")
    near_all = L["近"]["地面"] + L["近"]["石"]; mid_all = L["中"]["地面"] + L["中"]["石"]
    save = dict(near=near_all, near_w=np.ones_like(near_all), near_export=L["近"]["地面"] + L["近"]["石小"],
                mid=mid_all, mid_w=np.ones_like(mid_all), hirise=T["hirise"], ctx=T["ctx"], mola=T["mola"],
                levels=str(T["levels"]), align=T["align"], mast=T["mast"],
                near_ground=L["近"]["地面"], mid_ground=L["中"]["地面"], near_syn=L["近"]["合成带"], mid_syn=L["中"]["合成带"])
    if "远" in L:
        save.update(far=L["远"]["地面"], far_syn=L["远"]["合成带"], far_level=np.array(LAYERS["远"], float))
    np.savez(GEN/f"{pre}地形.npz", **save)
    np.savez(GEN/f"{pre}石块表.npz", 近=L["近"]["石表"], 中=L["中"]["石表"],
             字段=np.array("x y D hD p 椭 向 a2 a3 a4 φ2 φ3 φ4 明暗".split()))
    t1 = time.time()
    if pre: log(f"变体 {pre} → 生成/{pre}地形.npz（{t1 - t0:.0f} s）"); return
    # 反照率：近 1 cm ±10 m、中 2 cm ±50 m、HiRISE 级 25 cm ±1 km（对比度增益 + 远层高程分量）
    alb = {}
    for 层, (ca, na) in (("近", (0.01, 2000)), ("中", (0.02, 5000))):
        xs = 网格(ca, na); cs_l, n_l = LAYERS[层]
        zbn = 高程带通(near_all if 层 == "近" else mid_all, cs_l, cs_l*0.5 if 层 == "近" else cs_l)
        Zf = 取图(zbn, 网格(cs_l, n_l)[0], cs_l, xs, xs, order=1)
        Bm = 取图(L[层]["明暗"], 网格(cs_l, n_l)[0], cs_l, xs, xs, order=0)
        Wc = np.stack([取图(np.asarray(Wcls[..., c], np.float32), -1000 + 0.125, 0.25, xs, xs) for c in range(4)], -1)
        Wc /= np.maximum(Wc.sum(-1, keepdims=True), 1e-6)
        alb[层] = 反照率层(xs, xs, Zf, Bm, AH, Wc); del Zf, Bm, Wc
        log(f"反照率_{层}：{na}²×{ca} m，ln 亮度 std {np.log(np.maximum(alb[层].mean(-1), 1e-4)).std():.3f}")
        np.savez(GEN/f"反照率_{层}.npz", A=alb[层].astype(np.float16), cs=ca, n=na, cov=np.ones((na, na), np.float32))
    A = AH["A"].astype(np.float32); ca, na = float(AH["cs"]), int(AH["n"])
    lum = np.log(np.maximum(A.mean(-1), 1e-4)); lp = gaussian_filter(lum, 反照率["低通m"]/ca)
    ln = (反照率["增益"] - 1)*(lum - lp); del lum, lp
    cf, nf = LAYERS["远"]; m = int(cf*nf/2/ca); o = na//2 - m
    xs = 网格(ca, 2*m); Zf = 取图(L["远"]["地面"], 网格(cf, nf)[0], cf, xs, xs)
    zb = gaussian_filter(Zf, 0.5/ca) - gaussian_filter(Zf, 4.0/ca); sd = np.sqrt(gaussian_filter(zb**2, 8.0/ca)) + 1e-4
    w = np.clip((cf*nf/2*0.95 - np.maximum(*np.meshgrid(np.abs(xs), np.abs(xs))))/20.0, 0, 1)
    ln[o:o + 2*m, o:o + 2*m] += (0.5*反照率["高程std"]*np.clip(zb/sd, -3, 3)*w).astype(np.float32)
    A *= np.exp(ln)[..., None]; del ln
    np.savez(GEN/"反照率_HiRISE.npz", A=np.clip(A, 0, 1).astype(np.float16), cs=ca, n=na)
    del A
    t2 = time.time()
    耗时["反照率"] = t2 - t1; 耗时["合计"] = t2 - t0
    (GEN/"生成耗时.json").write_text(json.dumps(耗时, ensure_ascii=False, indent=1))
    log(f"→ 生成/地形.npz、石块表.npz、反照率_近/中/HiRISE.npz；高程 {t1 - t0:.0f} s，反照率 {t2 - t1:.0f} s，合计 {t2 - t0:.0f} s")


def 只反照率(P, Wcls, AH):
    """高程不变，只重算近/中反照率（读 生成/地形.npz、石块表.npz）。"""
    t0 = time.time(); G = np.load(GEN/"地形.npz"); RT = np.load(GEN/"石块表.npz")
    for 层, (ca, na) in (("近", (0.01, 2000)), ("中", (0.02, 5000))):
        cs_l, n_l = LAYERS[层]; xl = 网格(cs_l, n_l); Z = G["near" if 层 == "近" else "mid"]
        _, Bm = 画石(RT[层], xl, xl, 明暗=True); xs = 网格(ca, na)
        Zf = 取图(高程带通(Z, cs_l, cs_l*0.5 if 层 == "近" else cs_l), xl[0], cs_l, xs, xs); Bm = 取图(Bm, xl[0], cs_l, xs, xs, order=0)
        Wc = np.stack([取图(np.asarray(Wcls[..., c], np.float32), -1000 + 0.125, 0.25, xs, xs) for c in range(4)], -1)
        Wc /= np.maximum(Wc.sum(-1, keepdims=True), 1e-6)
        A = 反照率层(xs, xs, Zf, Bm, AH, Wc); del Zf, Bm, Wc
        log(f"反照率_{层}：{na}²×{ca} m，ln 亮度 std {np.log(np.maximum(A.mean(-1), 1e-4)).std():.3f}（{time.time() - t0:.0f} s）")
        np.savez(GEN/f"反照率_{层}.npz", A=A.astype(np.float16), cs=ca, n=na, cov=np.ones((na, na), np.float32))


# ── 子命令：导出（57 同格式）────────────────────────────────────────────
def 高度函数(G, 用近导出=True):
    """融合高度 H(x, y)：MOLA → CTX → HiRISE → 远（生成）→ 中（生成）→ 近（生成，大石挖掉），每层外缘 10% 渐变（同 57 height_fn）。"""
    from scipy.ndimage import map_coordinates
    L = json.loads(str(G["levels"]))
    lv = [("mola", L["MOLA"]), ("ctx", L["CTX"]), ("hirise", L["HiRISE"]), ("far", tuple(G["far_level"])), ("mid", L["中"]),
          ("near_export" if 用近导出 else "near", L["近"])]
    grids = {k: G[k] for k, _ in lv}
    def H(x, y):
        h = np.zeros_like(x)
        for k, (cs, n) in lv:
            n = int(n); half = cs*n/2; e = np.maximum(np.abs(x), np.abs(y))
            w = np.clip((half*0.98 - e)/(half*0.1), 0, 1); m = w > 0
            if not m.any(): continue
            v = map_coordinates(grids[k], [y[m]/cs + n/2 - 0.5, x[m]/cs + n/2 - 0.5], order=3, mode="nearest")
            h[m] = (1 - w[m])*h[m] + w[m]*v if k != "mola" else v
        return h
    return H


def 石网格(r, zc):
    """一块石头（石块表的一行）→ 低多边形封闭网格（局部坐标，原点在石心地面）：外轮廓 6–10 个顶点（角度、半径各抖 25%），
    顶面 3 圈、板状剖面 z = h·(1 − ρ^p)^(1/p)（p 2.5–6：顶平、边陡）再加一个随机倾斜，外缘斜插到地下 20% 高、封底。
    游戏里石块是平直着色，少顶点 = 棱角（第一版用了 32 × 8 的圆穹顶，远处一看全是馒头）。面按 57 的格式：[边数, 顶点…]，逆时针为正面。"""
    rng = np.random.default_rng(哈希(SEED, "石网格", round(float(r[0]), 4), round(float(r[1]), 4)))
    D = r[2]; h = D*r[3]; nθ = int(rng.integers(6, 11)); a = 0.5*D; b = a*r[5]; c, s = math.cos(r[6]), math.sin(r[6])
    th = np.linspace(0, 2*np.pi, nθ, endpoint=False) + rng.uniform(-0.25, 0.25, nθ)*2*np.pi/nθ
    rad = rng.uniform(0.75, 1.0, nθ); p = rng.uniform(2.5, 6.0); tx, ty = rng.normal(0, 0.25, 2)
    V = [(0.0, 0.0, h*(1 + 0.0))]; rhos = (0.45, 0.8, 1.0, 1.06)
    for m, rho in enumerate(rhos):
        for k in range(nθ):
            u = rho*rad[k]*a*math.cos(th[k]); v = rho*rad[k]*b*math.sin(th[k])
            z = h*max(1 - min(rho, 1.0)**p, 0)**(1/p)*(1 + tx*u/a + ty*v/max(b, 1e-6)) if rho < 1.0 else (0.0 if rho == 1.0 else -0.2*h)
            V.append((c*u - s*v, s*u + c*v, max(z, 0.0) if rho < 1.0 else z))
    V.append((0.0, 0.0, -0.2*h)); V = np.array(V, np.float32); ring = lambda m, k: 1 + m*nθ + k % nθ
    Fc = []
    for k in range(nθ): Fc += [3, 0, ring(0, k), ring(0, k + 1)]
    for m in range(len(rhos) - 1):
        for k in range(nθ): Fc += [4, ring(m, k), ring(m + 1, k), ring(m + 1, k + 1), ring(m, k + 1)]
    bot = len(V) - 1
    for k in range(nθ): Fc += [3, bot, ring(len(rhos) - 1, k + 1), ring(len(rhos) - 1, k)]
    return V, np.array(Fc, np.int32)


def cmd_导出():
    from PIL import Image
    Image.MAX_IMAGE_PIXELS = None
    M = M57(); t0 = time.time(); G = np.load(GEN/"地形.npz"); EX = GEN/"导出"; EX.mkdir(parents=True, exist_ok=True)
    J0 = json.loads((REC/"导出"/"场景.json").read_text())
    H = 高度函数(G); h0, e0 = M.RING0; rings = {}; nq = 0
    for k in range(M.NRING):                                              # 同 57 export 的环网格
        h, half = h0*2**k, e0*2**k; c = np.arange(-half, half + h/2, h); n = len(c); X, Y = np.meshgrid(c, c)
        Z = H(X.ravel(), Y.ravel()).reshape(n, n)
        if k < M.NRING - 1:
            for edge in (Z[0], Z[-1], Z[:, 0], Z[:, -1]): edge[1:-1:2] = 0.5*(edge[0:-2:2] + edge[2::2])
        i, j = np.meshgrid(np.arange(n - 1), np.arange(n - 1), indexing="ij")
        cx, cy = (c[:-1] + h/2)[j], (c[:-1] + h/2)[i]
        keep = ~((np.abs(cx) < half/2) & (np.abs(cy) < half/2)) if k else np.ones_like(cx, bool)
        i, j = i[keep], j[keep]
        Fq = np.stack([i*n + j, i*n + j + 1, (i + 1)*n + j + 1, (i + 1)*n + j], -1).reshape(-1, 4)
        used = np.unique(Fq); remap = -np.ones(n*n, np.int64); remap[used] = np.arange(used.size)
        rings[f"V{k}"] = np.stack([X.ravel()[used], Y.ravel()[used], Z.ravel()[used]], 1).astype(np.float32)
        rings[f"F{k}"] = remap[Fq].astype(np.int32); nq += len(Fq)
    np.savez_compressed(EX/"地面网格.npz", **rings, nring=M.NRING); log(f"地面网格 {nq:,} 面（{time.time() - t0:.0f} s）")
    tex = dict(J0["tex"])
    for lv in ("近", "中"):
        z = np.load(GEN/f"反照率_{lv}.npz"); A = z["A"].astype(np.float32)
        rgba = np.concatenate([M.srgb8(A), np.full(A.shape[:2] + (1,), 255, np.uint8)], -1)
        Image.fromarray(np.flipud(rgba), "RGBA").save(EX/f"反照率_{lv}.png"); tex[lv] = dict(file=f"反照率_{lv}.png", half=float(z["cs"])*int(z["n"])/2)
    z = np.load(GEN/"反照率_HiRISE.npz"); Image.fromarray(np.flipud(M.srgb8(z["A"].astype(np.float32))), "RGB").save(EX/"反照率_HiRISE.png")
    for f in ("反照率_CTX.png", "细节_*", "对照_*.png"):
        for p in (REC/"导出").glob(f): subprocess.run(["cp", "--reflink=auto", str(p), str(EX/p.name)], check=True)
    # 地类：纯轨道查表（25 cm）→ 地类_HiRISE；地类_中（4 cm ±50 m）= 同一张图插值
    Ph = np.load(GEN/"地类_轨道_25cm.npy").astype(np.float32)
    Image.fromarray(np.flipud((Ph*255 + 0.5).astype(np.uint8)), "RGBA").save(EX/"地类_HiRISE.png")
    xs = 网格(0.04, 2500); Pm = np.stack([取图(Ph[..., c], -1000 + 0.125, 0.25, xs, xs) for c in range(4)], -1)
    Image.fromarray(np.flipud((np.clip(Pm, 0, 1)*255 + 0.5).astype(np.uint8)), "RGBA").save(EX/"地类_中.png"); del Pm
    log(f"贴图（{time.time() - t0:.0f} s）")
    # 石块：近层 ≥ 15 cm → 封闭网格（地面 = 挖掉大石的近层）；统计撒石表（57 scatter_rocks，地类 = 纯轨道，k = 76）
    RT = np.load(GEN/"石块表.npz")["近"]; big = RT[RT[:, 2] >= 石块["网格D"]]
    big = big[(np.abs(big[:, 0]) < 9.5) & (np.abs(big[:, 1]) < 9.5)]
    cs, n = LAYERS["近"]; ge = G["near_export"]; An = np.load(GEN/"反照率_近.npz")["A"].astype(np.float32)
    from scipy.ndimage import map_coordinates
    rk = {}; inst = []; cols = []
    for i, r in enumerate(big):
        zc = float(map_coordinates(ge, [[r[1]/cs + n/2 - 0.5], [r[0]/cs + n/2 - 0.5]], order=1)[0])
        V, Fc = 石网格(r, zc); rk[f"V{i}"] = V; rk[f"F{i}"] = Fc
        inst.append(dict(pos=[float(r[0]), float(r[1]), zc], D=float(r[2]), H=float(r[2]*r[3]), src="生成"))
        ia, ja = int(r[1]/0.01 + 1000), int(r[0]/0.01 + 1000); rr = max(int(r[2]/3/0.01), 2)
        cols.append(np.median(An[ia - rr:ia + rr, ja - rr:ja + rr].reshape(-1, 3), 0).tolist())
    k_c = json.loads((GEN/"参数图.json").read_text())["k_地类"]; k_cls = np.array([k_c[c] for c in CLASSES])
    K = dict(hirise=Ph, cs_hi=0.25, n_hi=8000)
    zones = [(20.0, 50.0, 1.0, lambda r: 0.05, 0.30), (50.0, 1000.0, 5.0, lambda r: 0.0015*r, 1.5)]
    S = M.scatter_rocks(H, K, k_cls, zones)
    np.savez_compressed(EX/"石块.npz", **rk, inst=json.dumps(inst, ensure_ascii=False), colors=np.array(cols, np.float32).reshape(-1, 3),
                        scatter=S, k_cls=k_cls)
    J = dict(J0); J["tex"] = tex; J["生成"] = dict(脚本="scripts/生成器/77_地形生成.py", 种子=SEED, 时间=time.strftime("%F %T"))
    (EX/"场景.json").write_text(json.dumps(J, indent=1, ensure_ascii=False))
    log(f"石块：网格 {len(inst)} 块；k_cls {np.round(k_cls, 4).tolist()}；统计撒石 {len(S):,} 块 → 生成/导出/（{time.time() - t0:.0f} s）")


# ── 子命令：游戏数据 ───────────────────────────────────────────────────
def cmd_游戏():
    """61 原样（只把 OUT 指到 生成/godot_生成/sol0530，--源 生成）；天空、车、机位从真实版拷，保证同机位、同光照。
    真实版另 reflink 一份到 生成/godot_真/sol0530，渲染时由工作树的 godot/数据/sol0530 符号链接选用，主工作树的数据不动。"""
    REAL = MAP.parent/"地图"/"godot"/"数据"/"sol0530"                      # 主工作树的真实版（只读：reflink 拷一份）
    GT = GEN/"godot_真"/"sol0530"; OUTG = GEN/"godot_生成"/"sol0530"
    if not GT.exists():
        GT.parent.mkdir(parents=True, exist_ok=True); subprocess.run(["cp", "-r", "--reflink=auto", str(REAL), str(GT)], check=True)
        log(f"真实版 → {GT}")
    OUTG.mkdir(parents=True, exist_ok=True); SJ = json.loads((GT/"scene.json").read_text())
    for p in GT.iterdir():                                                 # 车、天空：原样（reflink）
        if p.name.startswith(("rover", "sky_")) and not (OUTG/p.name).exists():
            subprocess.run(["cp", "-r", "--reflink=auto", str(p), str(OUTG/p.name)], check=True)
    (OUTG/"scene.json").write_text(json.dumps(dict(sky=SJ["sky"]), ensure_ascii=False))
    m61 = _mod("m61", MAP/"scripts"/"Godot"/"61_Godot数据.py"); m61.OUT = OUTG
    m61.main(["--源", "生成"])
    S = json.loads((OUTG/"scene.json").read_text())
    for k, v in SJ.items():
        if k not in S or k in ("cameras", "rover", "sky", "sky_tau", "beta_ap_tau"): S[k] = v
    S["生成"] = dict(来自="77_地形生成.py", 源=S.get("source"))
    (OUTG/"scene.json").write_text(json.dumps(S, ensure_ascii=False, indent=1))
    log(f"→ {OUTG}（机位、天空、车 = 真实版）")


# ── 子命令：统计关 ─────────────────────────────────────────────────────
def cmd_统计(args=()):
    F = F64(); M = M57(); t0 = time.time(); VAL.mkdir(parents=True, exist_ok=True)
    pre = args[0] if args else ""
    T = np.load(REC/"地形.npz"); G = np.load(GEN/f"{pre}地形.npz"); J = json.loads((MAP/"产出"/"生成器"/"指纹_sol0530"/"指纹.json").read_text())
    Lv = json.loads(str(T["levels"])); (csn, nn), (csm, nm) = Lv["近"], Lv["中"]; mast = T["mast"][:2]
    Xn, Yn, rn = F.网格坐标(csn, nn, mast); Xm, Ym, rm = F.网格坐标(csm, nm, mast)
    rov_n, rov_m = M.under_rover(Xn, Yn), M.under_rover(Xm, Ym)
    real = dict(近=T["near"].astype(np.float64), 中=T["mid"].astype(np.float64)); gen = dict(近=G["near"].astype(np.float64), 中=G["mid"].astype(np.float64))
    W = dict(近=T["near_w"] > 0, 中=T["mid_w"] > 0)
    R = dict(变体=pre or "主", 时间=time.strftime("%F %T")); 判 = []
    def 记(项, 值, 过, 说明=""):
        判.append(dict(项=项, 值=值, 过=bool(过), 说明=说明))
    # 1. ν 各尺度（同环、同去平面、同滞后；只在指纹的「可信段」上比）
    ν = {}
    for key, lv, a, b, mx in (("近_1-3m", "近", 1, 3, 4.0), ("近_3-6m", "近", 3, 6, 4.0), ("近_0-6m", "近", 0, 6, 4.0),
                              ("中_2-8m", "中", 2, 8, 12.0), ("中_8-15m", "中", 8, 15, 14.0), ("中_15-25m", "中", 15, 25, 20.0), ("中_25-45m", "中", 25, 45, 20.0)):
        cs = csn if lv == "近" else csm; r_ = rn if lv == "近" else rm; rov = rov_n if lv == "近" else rov_m
        s = W[lv] & (r_ >= a) & (r_ < b) & ~rov
        mxm = min(2*(b - a), mx)
        fr = F.层_ν(real[lv], cs, s, 最大_m=mxm); fg = F.层_ν(gen[lv], cs, s, 最大_m=mxm)
        ok = np.array(J["粗糙度"][key]["可信"], bool) if len(J["粗糙度"][key]["可信"]) == len(fr["lag"]) else np.ones(len(fr["lag"]), bool)
        d = np.log10(fg["nu"]/fr["nu"])
        ν[key] = dict(lag=fr["lag"], 真=fr["nu"], 生=fg["nu"], 可信=ok, log10比=d)
        if ok.sum():
            mx_ = float(np.max(np.abs(d[ok]))); 记(f"ν {key}（{fr['lag'][ok].min():g}–{fr['lag'][ok].max():g} m）", dict(均log10比=float(np.mean(d[ok])), 最大abs=mx_,
                 比_范围=[float(10**d[ok].min()), float(10**d[ok].max())]), mx_ <= 0.1)
        # 局部 H（同段）
        for lo, hi in ((0.02, 0.1), (0.1, 0.5), (0.5, 1.8)) if lv == "近" and key == "近_0-6m" else ():
            hr = F.拟合H(fr["lag"], fr["nu"], lo, hi); hg = F.拟合H(fg["lag"], fg["nu"], lo, hi)
            if hr and hg: 记(f"H {lo:g}–{hi:g} m（近 r<6）", dict(真=hr["H"], 生=hg["H"]), abs(hr["H"] - hg["H"]) <= 0.05)
        if lv == "中" and ok.sum() >= 4:
            lo, hi = float(fr["lag"][ok].min()), float(fr["lag"][ok].max())
            hr = F.拟合H(fr["lag"], fr["nu"], lo, hi); hg = F.拟合H(fg["lag"], fg["nu"], lo, hi)
            if hr and hg: 记(f"H {lo:.2g}–{hi:.2g} m（{key}）", dict(真=hr["H"], 生=hg["H"]), abs(hr["H"] - hg["H"]) <= 0.05)
    R["ν"] = ν
    # 2. 坡度（RMS ±20%，β ±0.2，峰度数量级）
    sl = []
    for nm_, lv, rmax, B in (("近 r<3", "近", 3, 0.02), ("近 r<6", "近", 6, 0.02), ("近 r<6", "近", 6, 0.1), ("近 r<6", "近", 6, 1.0),
                             ("中 r<15", "中", 15, 1.0), ("中 r<15", "中", 15, 5.0), ("中 r<30", "中", 30, 1.0)):
        cs = csn if lv == "近" else csm; r_ = rn if lv == "近" else rm; rov = rov_n if lv == "近" else rov_m
        s = W[lv] & (r_ < rmax) & ~rov
        zr, _ = F.去平面(real[lv], s); zg, _ = F.去平面(gen[lv], s)
        a_ = F.坡度统计(zr, cs, s, B, 直方=False); b_ = F.坡度统计(zg, cs, s, B, 直方=False)
        if not (a_ and b_): continue
        row = dict(区=nm_, 基线_m=B, 真=dict(rms=a_["rms_deg"], β=a_["广义高斯β"], 峰度=a_["峰度"], p99=a_["角_p99"]),
                   生=dict(rms=b_["rms_deg"], β=b_["广义高斯β"], 峰度=b_["峰度"], p99=b_["角_p99"]))
        sl.append(row)
        记(f"坡度 RMS {nm_} {B:g} m", [a_["rms_deg"], b_["rms_deg"]], abs(b_["rms_deg"]/a_["rms_deg"] - 1) <= 0.2)
        记(f"坡度 β {nm_} {B:g} m", [a_["广义高斯β"], b_["广义高斯β"]], abs(b_["广义高斯β"] - a_["广义高斯β"]) <= 0.2)
        记(f"坡度峰度 {nm_} {B:g} m（数量级）", [a_["峰度"], b_["峰度"]],
           abs(math.log10(max(b_["峰度"], 0.1)/max(a_["峰度"], 0.1))) <= 0.5)
    R["坡度"] = sl
    # 3. 残差偏度（近 r<6：σ 5/10/25/50 cm）
    s = W["近"] & (rn < 6) & ~rov_n
    rr = F.残差统计(F.去平面(real["近"], s)[0], csn, s, (0.05, 0.1, 0.25, 0.5)); rg = F.残差统计(F.去平面(gen["近"], s)[0], csn, s, (0.05, 0.1, 0.25, 0.5))
    R["残差"] = dict(真=rr, 生=rg)
    for a_, b_ in zip(rr, rg):
        记(f"残差偏度 σ {a_['尺度_m']:g} m", [a_["偏度"], b_["偏度"]], (np.sign(a_["偏度"]) == np.sign(b_["偏度"])) and abs(a_["偏度"] - b_["偏度"]) <= 0.5)
    # 4. 地类（中层 10 cm、r 2–15 m；真 = Navcam 地类，生 = 纯轨道地类）：10 cm 增量峰度、10 cm 坡度 RMS
    K = np.load(REC/"地类.npz"); Pm = K["mid"].astype(np.float32); nk = int(K["n_mid"]); f = int(round(csm/float(K["cs_mid"])))
    Pr = Pm.reshape(nk//f, f, nk//f, f, 4).mean((1, 3)); Pr[(Pm.reshape(nk//f, f, nk//f, f, 4) < 0).any((1, 3, 4))] = -1; del Pm
    Ph = np.load(GEN/"地类_轨道_25cm.npy", mmap_mode="r"); xs = 网格(csm, nm)
    Pg = np.stack([取图(np.asarray(Ph[..., c], np.float32), -1000 + 0.125, 0.25, xs, xs) for c in range(4)], -1)
    cls = []
    for name, P_, z in (("真", Pr, real["中"]), ("生", Pg, gen["中"])):
        for ci, c in enumerate(CLASSES):
            for thr in (0.7, 0.5):
                s = W["中"] & (rm >= 2) & (rm < 15) & ~rov_m & (P_[..., ci] > thr)
                if s.sum() >= 2000: break
            if s.sum() < 500: cls.append(dict(源=name, 地类=c, 格=int(s.sum()))); continue
            zz, _ = F.去平面(z, s); sf = F.结构函数(zz, csm, s, [1, 2, 10]); sp = F.坡度统计(zz, csm, s, 0.1, 直方=False)
            cls.append(dict(源=name, 地类=c, 格=int(s.sum()), 阈=thr, 峰度10cm=float(sf["kurt"][0]), 坡度rms10cm=sp["rms_deg"] if sp else None, ν10cm=float(sf["nu"][0])))
    R["地类"] = cls
    def 序(src, key): return [c_ for c_ in sorted([c for c in cls if c["源"] == src and c.get(key) is not None], key=lambda c: c[key])]
    for key in ("峰度10cm", "坡度rms10cm"):
        a_ = [c["地类"] for c in 序("真", key)]; b_ = [c["地类"] for c in 序("生", key)]
        记(f"地类排序 {key}", dict(真=a_, 生=b_), a_ == b_)
        for c in CLASSES:
            x = next((q for q in cls if q["源"] == "真" and q["地类"] == c and q.get(key) is not None), None)
            y = next((q for q in cls if q["源"] == "生" and q["地类"] == c and q.get(key) is not None), None)
            if x and y: 记(f"地类 {c} {key}", [x[key], y[key]], abs(y[key]/x[key] - 1) <= 0.3)
    # 5. 石块：生成表（r < 6 m）的 Golombek k，D 10–25 cm；D ≥ 25 cm（r < 9 m）；格局 R（D ≥ 8 cm，按地类非均匀零假设）
    RT = np.load(GEN/f"{pre}石块表.npz")["近"] if (GEN/f"{pre}石块表.npz").exists() else np.zeros((0, 14))
    rk = {}
    if len(RT):
        r_ = np.hypot(RT[:, 0] - mast[0], RT[:, 1] - mast[1]); win6 = W["近"] & (rn < 6) & ~rov_n
        inw = win6[np.clip((RT[:, 1]/csn + nn/2).astype(int), 0, nn - 1), np.clip((RT[:, 0]/csn + nn/2).astype(int), 0, nn - 1)]
        a6 = win6.sum()*csn*csn; sel = (r_ < 6) & inw
        k1 = F.拟合k(RT[sel, 2], a6, 0.10, 0.25);
        win9 = W["近"] & (rn < 9) & ~rov_n; a9 = win9.sum()*csn*csn
        inw9 = win9[np.clip((RT[:, 1]/csn + nn/2).astype(int), 0, nn - 1), np.clip((RT[:, 0]/csn + nn/2).astype(int), 0, nn - 1)]
        k2 = F.拟合k(RT[(r_ < 9) & inw9, 2], a9, 0.25)
        rk = dict(k_10_25=k1, k_25=k2, 密度8cm=float(((RT[:, 2] >= 0.08) & sel).sum()/a6))
        if k1: 记("石块 k（D 10–25 cm，r<6）", [0.026, k1["k"]], abs(k1["k"]/0.026 - 1) <= 0.3)
        if k2: 记("石块 k（D ≥ 25 cm，r<9）", [0.045, k2["k"]], abs(k2["k"]/0.045 - 1) <= 0.3)
        pts = RT[sel & (RT[:, 2] >= 0.08), :2]
        Pn = np.stack([取图(np.asarray(Ph[..., c], np.float32), -1000 + 0.125, 0.25, 网格(csn, nn), 网格(csn, nn)) for c in range(4)], -1)
        kc = json.loads((GEN/"参数图.json").read_text())["石块密度_8cm"]; lam = (Pn*np.array([kc[c] for c in CLASSES])).sum(-1)
        g = F.点格局(pts, win6, Xn, Yn, csn, nsim=99, 强度=lam)
        if g: rk["格局"] = {k_: g[k_] for k_ in ("n", "密度", "R", "p_聚集")}; 记("石块格局 R（按地类非均匀零假设）", [0.89, g["R"]], 0.85 <= g["R"] <= 1.0 + 0.15)
        记("石块密度 D≥8 cm（r<6）", [0.64, rk["密度8cm"]], abs(rk["密度8cm"]/0.64 - 1) <= 0.3)
    R["石块"] = rk
    # 6. 反照率：ν[lnA]（近 1 cm r<6）、反照率–高程带通相关（近 2 cm r<6）
    if not pre:
        an = np.load(REC/"反照率_近.npz"); Ar = an["A"].astype(np.float32).mean(-1); cov = an["cov"] > 0
        Ag = np.load(GEN/"反照率_近.npz")["A"].astype(np.float32).mean(-1); X1, Y1, r1 = F.网格坐标(0.01, 2000, mast)
        s1 = cov & (r1 < 6) & ~M.under_rover(X1, Y1); lt = F.滞后表(300, 10)
        nr_ = F.结构函数(np.where(s1, np.log(np.maximum(Ar, 1e-4)), 0), 0.01, s1, lt); ng_ = F.结构函数(np.where(s1, np.log(np.maximum(Ag, 1e-4)), 0), 0.01, s1, lt)
        al = dict(lag=nr_["lag"], 真=nr_["nu"], 生=ng_["nu"])
        for l in (0.01, 0.04, 0.25, 1.0):
            a_, b_ = np.interp(l, nr_["lag"], nr_["nu"]), np.interp(l, ng_["lag"], ng_["nu"]); 记(f"反照率 ν[lnA] {l:g} m", [float(a_), float(b_)], abs(b_/a_ - 1) <= 0.3)
        A2r = Ar.reshape(nn, 2, nn, 2).mean((1, 3)); A2g = Ag.reshape(nn, 2, nn, 2).mean((1, 3)); c2 = cov.reshape(nn, 2, nn, 2).all((1, 3))
        cr = F.带通相关(A2r, real["近"], c2 & (rn < 6) & ~rov_n & W["近"], csn, (0.04, 0.08, 0.16, 0.32))
        cg = F.带通相关(A2g, gen["近"], c2 & (rn < 6) & ~rov_n & W["近"], csn, (0.04, 0.08, 0.16, 0.32))
        al["相关"] = dict(真=cr, 生=cg)
        for a_, b_ in zip(cr, cg):
            记(f"反照率–高程相关 {a_['尺度_m']:g} m", [a_["反照率_高程"], b_["反照率_高程"]],
               np.sign(a_["反照率_高程"]) == np.sign(b_["反照率_高程"]) and abs(a_["反照率_高程"] - b_["反照率_高程"]) <= 0.15)
        R["反照率"] = al
    # 7. 各向异性（近 r<6，0.5 m 高通后，滞后 5 / 25 cm）
    s = W["近"] & (rn < 6) & ~rov_n
    for name, z in (("真", real["近"]), ("生", gen["近"])):
        lo, _ = F.归一卷积(z, s, 0.5/csn); zz = np.where(s, z - lo, 0)
        g2, _ = F.变差图2D(zz, s, 20); v = []
        for rp in (3, 12):
            a_, nu_ = F.方向谱(g2, rp); v.append(float(nu_.max()/nu_.min()))
        R.setdefault("各向异性", {})[name] = v
    记("各向异性（0.5 m 高通，5/25 cm）≤ 1.3", R["各向异性"]["生"], max(R["各向异性"]["生"]) <= 1.3)
    R["判定"] = 判; R["通过"] = sum(d["过"] for d in 判); R["总数"] = len(判)
    (VAL/f"{pre}统计.json").write_text(json.dumps(F._json(R), ensure_ascii=False, indent=1))
    md = [f"# 统计关（{pre or '主'}）：{R['通过']}/{R['总数']} 过", "", "| 项 | 真 / 生 | 过 |", "|---|---|---|"]
    for d in 判:
        v = d["值"]; vs = json.dumps(F._json(v), ensure_ascii=False) if not isinstance(v, list) else " / ".join(f"{x:.3g}" for x in v)
        md.append(f"| {d['项']} | {vs} | {'过' if d['过'] else '**不过**'} |")
    (VAL/f"{pre}统计.md").write_text("\n".join(md))
    log(f"统计关 {pre or '主'}：{R['通过']}/{R['总数']} 过（{time.time() - t0:.0f} s）→ {VAL/(pre + '统计.md')}")
    for d in 判:
        if not d["过"]: log("  不过：", d["项"], json.dumps(F._json(d["值"]), ensure_ascii=False)[:160])


# ── 子命令：图（文档用小图）───────────────────────────────────────────
def _晕渲(z, cs, az=315, el=35):
    gy, gx = np.gradient(z, cs); a, e = math.radians(az), math.radians(el)
    n = np.sqrt(1 + gx**2 + gy**2); v = (-gx*math.sin(a)*math.cos(e) - gy*math.cos(a)*math.cos(e) + math.sin(e))/n
    return np.clip(v, 0, 1)


def cmd_图():
    import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
    plt.rcParams["font.sans-serif"] = ["Noto Sans CJK JP", "Noto Sans CJK SC", "DejaVu Sans"]; plt.rcParams["axes.unicode_minus"] = False
    FIG = MAP/"docs"/"地形生成调研"/"图"; FIG.mkdir(parents=True, exist_ok=True)
    T = np.load(REC/"地形.npz"); G = np.load(GEN/"地形.npz"); M = M57()
    fig, ax = plt.subplots(2, 4, figsize=(16, 8.4), dpi=95)
    def sh(a_, z, cs, ext, t, m=None):
        img = _晕渲(z, cs); img = np.where(m, img, np.nan) if m is not None else img
        a_.imshow(img, origin="lower", extent=ext, cmap="gray", vmin=0, vmax=1); a_.set_title(t, fontsize=10); a_.tick_params(labelsize=7)
    sh(ax[0, 0], T["near"], 0.02, [-10, 10, -10, 10], "真：Navcam 近层 2 cm（±10 m）", T["near_w"] > 0)
    sh(ax[0, 1], G["near"], 0.02, [-10, 10, -10, 10], "生：只用轨道数据，近层 2 cm")
    sh(ax[0, 2], T["mid"], 0.1, [-50, 50, -50, 50], "真：Navcam 中层 10 cm（±50 m）", T["mid_w"] > 0)
    sh(ax[0, 3], G["mid"], 0.1, [-50, 50, -50, 50], "生：中层 10 cm")
    an = np.load(REC/"反照率_近.npz"); Ar = an["A"].astype(np.float32); Ag = np.load(GEN/"反照率_近.npz")["A"].astype(np.float32)
    s_ = slice(500, 1500); tone = lambda A: np.clip((A/np.percentile(A[A > 0], 99))**(1/2.2), 0, 1)
    ax[1, 0].imshow(tone(Ar[s_, s_]), origin="lower", extent=[-5, 5, -5, 5]); ax[1, 0].set_title("真：反照率 1 cm（±5 m）", fontsize=10)
    ax[1, 1].imshow(tone(Ag[s_, s_]), origin="lower", extent=[-5, 5, -5, 5]); ax[1, 1].set_title("生：反照率 1 cm（±5 m）", fontsize=10)
    o = 1280 - 600; hs = T["hirise"][1800 - 150:1800 + 150, 1800 - 150:1800 + 150]
    sh(ax[1, 2], hs, 1.0, [-150, 150, -150, 150], "HiRISE DTM 1 m（±150 m，生成器的输入）")
    sh(ax[1, 3], G["far"][o:o + 1200, o:o + 1200], 0.25, [-150, 150, -150, 150], "生：远层 25 cm（±150 m）")
    for a_ in ax.flat: a_.tick_params(labelsize=7)
    fig.suptitle("sol 530 留出：真实重建 vs 只用轨道数据生成（晕渲，北在上）", fontsize=12); fig.tight_layout()
    fig.savefig(FIG/"v0_俯视对照.jpg", pil_kwargs=dict(quality=85)); plt.close(fig)
    # ν 曲线
    R = json.loads((VAL/"统计.json").read_text()); fig, ax = plt.subplots(1, 2, figsize=(13, 5.2), dpi=95)
    cols = plt.cm.viridis(np.linspace(0, 0.9, len(R["ν"])))
    for c, (k, v) in zip(cols, R["ν"].items()):
        a_ = ax[0] if k.startswith("近") else ax[1]; L = np.array(v["lag"]); ok = np.array(v["可信"], bool)
        a_.loglog(L, np.array(v["真"])*1000, "-", color=c, lw=2, label=f"{k} 真"); a_.loglog(L, np.array(v["生"])*1000, "--", color=c, lw=1.5, label=f"{k} 生")
        a_.loglog(L[~ok], np.array(v["真"])[~ok]*1000, "x", color=c, ms=4)
    for a_, t in zip(ax, ("近层 2 cm", "中层 10 cm")):
        a_.set_xlabel("滞后 Δx（m）"); a_.set_ylabel("ν（mm）"); a_.set_title(f"结构函数：{t}（实线 真，虚线 生；× = 指纹的不可信段）", fontsize=10); a_.legend(fontsize=7, ncol=2); a_.grid(alpha=0.3, which="both")
    fig.tight_layout(); fig.savefig(FIG/"v0_结构函数.png"); plt.close(fig)
    log(f"图 → {FIG}")


# ── 子命令：渲染对照图、盲测图（读 生成/渲染/真|生成/{主,远A,远B}）─────────────────
机位 = [("主", "近地", "近地：车前右 4 m 空地，离地 1.2 m 下看"), ("主", "人眼", "人眼：车后 6 m，1.7 m 高"), ("主", "高处", "高处：车东北 30 m 高处回看"),
        ("远A", "远足", "远 A：车南 125 m，1.8 m 高朝车看"), ("远B", "远足", "远 B：车东南 160 m，朝东南沙波区看"),
        ("主", "对照_NRF_5M362RAS_", "对照：sol 502 到站环拍（同 NASA 照片位姿）")]


def cmd_渲染图():
    from PIL import Image, ImageDraw, ImageFont
    REN = GEN/"渲染"; FIG = MAP/"docs"/"地形生成调研"/"图"; FIG.mkdir(parents=True, exist_ok=True)
    try: font = ImageFont.truetype("/usr/share/fonts/google-noto-sans-mono-cjk-vf-fonts/NotoSansMonoCJK-VF.ttc", 22)
    except Exception: font = ImageFont.load_default()
    def ld(v, sub, n, w): im = Image.open(REN/v/sub/f"{n}_1307.png").convert("RGB"); return im.resize((w, round(im.height*w/im.width)), Image.LANCZOS)
    rows = []
    for sub, n, t in 机位:
        a, b = ld("真", sub, n, 790), ld("生成", sub, n, 790)
        row = Image.new("RGB", (1600, a.height + 34), (20, 20, 20)); row.paste(a, (0, 34)); row.paste(b, (810, 34))
        d = ImageDraw.Draw(row); d.text((6, 4), f"{t}　｜左：真实重建　右：只用轨道数据生成", fill=(235, 235, 235), font=font); rows.append(row)
    for k, part in enumerate((rows[:3], rows[3:])):
        H = sum(r.height for r in part); sheet = Image.new("RGB", (1600, H), (20, 20, 20)); y = 0
        for r in part: sheet.paste(r, (0, y)); y += r.height
        sheet.save(FIG/f"v0_渲染对照_{k + 1}.jpg", quality=82)
    # 盲测：5 对，左右顺序按 (种子, 机位) 哈希；答案另存
    BD = FIG/"盲测"; BD.mkdir(exist_ok=True); ans = {}
    for i, (sub, n, t) in enumerate(机位[:5], 1):
        a, b = ld("真", sub, n, 790), ld("生成", sub, n, 790); left_real = 哈希(SEED, "盲测", n, sub) % 2 == 0
        L_, R_ = (a, b) if left_real else (b, a); im = Image.new("RGB", (1600, a.height), (20, 20, 20)); im.paste(L_, (0, 0)); im.paste(R_, (810, 0))
        ImageDraw.Draw(im).text((8, 6), "甲", fill=(255, 255, 255), font=font); ImageDraw.Draw(im).text((818, 6), "乙", fill=(255, 255, 255), font=font)
        im.save(BD/f"盲测_{i}.jpg", quality=85); ans[f"盲测_{i}"] = dict(机位=t, 真实在="甲（左）" if left_real else "乙（右）")
    (GEN/"验证"/"盲测答案.json").write_text(json.dumps(ans, ensure_ascii=False, indent=1))
    (BD/"答案_先别看.json").write_text(json.dumps(ans, ensure_ascii=False, indent=1))
    log(f"对照图、盲测 5 对 → {FIG}")


# ── 子命令：材质（加分项）──────────────────────────────────────────────
def cmd_材质():
    """73「只用几何」规则（docs/地面材质/阶段1.md §2.2）在真实版和生成版的高度上各跑一遍（73 原样导入，只把 GD/WORK 指到 生成/ 下），
    比较各材质的面积比例（±10 m、10–50 m、50 m–1 km）和两版逐纹素的一致率。Sx 强制用 CPU（CUDA_VISIBLE_DEVICES 置空，不占显卡）。"""
    os.environ["CUDA_VISIBLE_DEVICES"] = ""
    from PIL import Image
    m73 = _mod("m73", MAP/"scripts"/"Godot"/"73_材质规则.py"); T = m73.table(); ids = [m["id"] for m in T["材质"]]; out = {}; W = {}
    for v in ("真", "生成"):
        m73.GD = GEN/f"godot_{v}"/"sol0530"; m73.WORK = GEN/"材质规则"/v; m73.WORK.mkdir(parents=True, exist_ok=True)
        m73.cmd_fields([]); W[v] = {}
        for name in ("近", "远"):
            w, dust, _, _ = m73.bake(name, "几何", T); W[v][name] = w
            x, z = m73.grid_xz(m73.GRIDS[name]); e = np.maximum(np.abs(x), np.abs(z))
            rings = ((0, 10), (10, 50)) if name == "近" else ((50, 1000),)
            for a, b in rings:
                m = (e >= a) & (e < b); out.setdefault(v, {})[f"{a}-{b} m"] = {i_: round(float(w[..., k][m].mean()), 3) for k, i_ in enumerate(ids)} | dict(积尘=round(float(dust[m].mean()), 3))
    for name in ("近", "远"):
        a, b = W["真"][name].argmax(-1), W["生成"][name].argmax(-1); out.setdefault("逐纹素一致率", {})[name] = round(float((a == b).mean()), 3)
        g = m73.GRIDS[name]; n = a.shape[0]; c = n//2; h = n//4 if name == "近" else n//20       # 近：±25 m；远：±100 m
        imgs = [(m73.colorize(W[v][name][c - h:c + h, c - h:c + h], T)*255).astype(np.uint8) for v in ("真", "生成")]
        im = Image.fromarray(np.concatenate([imgs[0], np.zeros((2*h, 8, 3), np.uint8), imgs[1]], 1)); im.thumbnail((1400, 700))
        im.save(MAP/"docs"/"地形生成调研"/"图"/f"v0_材质_{name}.jpg", quality=82)
    (VAL/"材质.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
    for v in ("真", "生成"): log(f"{v}：" + "；".join(f"{k} " + " ".join(f"{i_} {x:.2f}" for i_, x in d.items()) for k, d in out[v].items()))
    log(f"逐纹素一致率：{out['逐纹素一致率']}")


if __name__ == "__main__":
    a = sys.argv[1:] or ["生成"]
    {"标定": cmd_标定, "生成": lambda: cmd_生成(a[1:]), "导出": cmd_导出, "游戏": cmd_游戏, "统计": lambda: cmd_统计(a[1:]), "图": cmd_图, "渲染图": cmd_渲染图, "材质": cmd_材质}[a[0]]()
