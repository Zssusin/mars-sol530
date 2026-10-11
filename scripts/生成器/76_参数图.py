"""
76 参数图（地形生成器 v0 · S1）：只用轨道数据，算 77 合成器要的参数图。设计见 docs/地形生成调研/地形生成器设计.md §3 ①，结果见 v0_结果.md。
  输入（只读，都是 57 缓存里的轨道部分；Navcam 近/中层、Navcam/Mastcam 反照率、实测石块一律不读）：
    重建/地形.npz：hirise（HiRISE DTM 1 m，±1.8 km，外缘 200 m 渐变到 CTX）、ctx、mola、align、mast（桅杆 = 车的定位）
    重建/地类.npz：hirise（25 cm，57 ⑦ 用 HiRISE 查找表外推的四类权重）
    重建/反照率_HiRISE.npz（25 cm，57 ④ HiRISE 正射去光影 + 颜色查找表）
  v0 允许的「同站信息」（S4 跨站关要去掉，文档里列为局限）：
    · HiRISE 的水平/竖直对齐 (−0.5, +0.5, +0.11) m 是对着立体做的，相当于把车定位到 HiRISE 上；
    · 地类查找表、HiRISE 颜色查找表是在本站 Navcam 上学的；
    · H(尺度) 曲线、各地类石块密度、反照率增益来自本站指纹（指纹_sol0530/报告.md §4）。
  输出：站26_1222/生成/参数图.npz、参数图.json、参数图.png（小图）
    1 m 格、±1 km（2000²，第 0 行在南，格心 (i + ½ − n/2)·cs，同 57）：
      B6、B12：HiRISE 6 m、12 m 倍频程的带通 rms（8 m 窗），77 的合成带振幅接在 B6 上
      A3、H3_12：HiRISE 3–12 m 局部结构函数（高斯窗 σ 8 m，增量先减去局部坡面）拟合 ν(L) = A3·(L/3)^H
      W：四类地类权重（沙、砾石风化层、基岩、暗色岩块）；k：Golombek k(x) = Σ W_c k_c
      lnA：HiRISE 反照率 ln（1 m 均值）；反照率增益 g（Navcam/HiRISE 米级对比度比）
      沙波：输沙方向 276°（Newman 2022）；HiRISE 正射 1–6 m 方向谱的峰突出度（64 m 块）→ 米级沙波指数、波长、脊走向
    坑表（±400 m）：D 1–5 m 的合成小坑（HiRISE 分辨不出的）：x y D d/D h/D σ_扩散 年龄 等级；剖面表（Watters 2015 幂律 + 扩散）
运行：.venv/bin/python scripts/生成器/76_参数图.py   （约 1 分钟，内存 < 6 GB）
数据：NASA/JPL-Caltech/University of Arizona/USGS（HiRISE DTM 与正射、CTX DTM、MOLA）。
"""
import hashlib, json, math, os, pathlib, sys, time
os.environ.setdefault("OMP_NUM_THREADS", "8")
import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
MAP = HERE.parent.parent
SITE = MAP/"DEM"/"Blender缓存"/"_素材"/"PDS"/"站26_1222"
REC = SITE/"重建"
GEN = SITE/"生成"
CLASSES = ("沙", "砾石风化层", "基岩", "暗色岩块")
CS, N = 1.0, 2000                                                          # 参数图：1 m、±1 km

# ── 学到的规律（本站指纹，报告 §0、§3、§4；设计稿 §2）──────────────────────────
H_曲线 = [(0.02, 0.10, 0.70), (0.10, 0.30, 0.79), (0.30, 3.0, 0.85)]          # (尺度下限, 上限, H)：3 m 以下往下外推用
石块密度_8cm = {"沙": 0.33, "砾石风化层": 1.31, "基岩": 0.08, "暗色岩块": 0.70}   # 每 m²，D ≥ 8 cm（报告 §3.6，r < 6 m）
反照率增益 = 1.45                                                           # Navcam/HiRISE 对比度 1.3–1.6（报告 §3.7）取中
输沙方向 = 276.0                                                            # 度，朝向（Newman 2022）；脊垂直于它
坑 = dict(f_eq=0.3, D_min=1.0, D_max=5.0, 半宽=400.0, 格=50.0,                # Hartmann 1984 平衡线 × f_eq（统计 §2.1、§6 默认 0.3）
         新鲜dD=0.20, 新鲜hD=0.036, 指数=1.75, 坑外指数=-3.0, κ=1e-6,       # Daubar 2014 / Pike；Watters 2015 幂律 1.75；Golombek 2014 κ
         等级dD={"2": 0.081, "3": 0.078, "4": 0.063, "5": 0.046}, 等级比={"2": 1, "3": 2, "4": 4, "5": 4})   # Sweeney 2018
SEED = 530


def log(*a): print("[76]", *a, flush=True)


def 哈希(*k):
    """(种子, 整数世界坐标, …) → 64 位整数（确定性，和顺序、分块无关）。"""
    return int.from_bytes(hashlib.blake2b(repr(k).encode(), digest_size=8).digest(), "little")


def 网格(cs, n):
    return (np.arange(n) + 0.5 - n/2)*cs


def 裁中(a, n_src, n_dst):
    o = (n_src - n_dst)//2; return a[o:o + n_dst, o:o + n_dst]


# ── ① HiRISE 局部振幅 ────────────────────────────────────────────────
def 局部振幅(z, cs, σw=8.0, σ坡=20.0, 轴向=(1, 2, 3, 4, 6, 8, 12), 对角=(1, 2, 3, 4, 6, 8)):
    """局部结构函数：每个滞后的平方增量（减去 σ坡 尺度的局部坡面 L·∇z，相当于指纹按区域去平面）放到增量中点，高斯窗 σw 平均；
    只用 3–12 m 的滞后（HiRISE 可信段）对 log ν – log L 逐格最小二乘 → A3 = ν(3 m)、H。
    另返回 1、2 m 滞后的 ν（HiRISE 自身在 3 m 以下的增量，几乎全是大尺度坡度的贡献，合成带要和它按平方和接上）。"""
    from scipy.ndimage import gaussian_filter
    zs = gaussian_filter(z, σ坡/cs); gy, gx = np.gradient(zs, cs)
    pts = [(l, 0, l*cs) for l in 轴向] + [(k, k, k*cs*math.sqrt(2)) for k in 对角]
    out = []
    for a, b, L in pts:
        acc = np.zeros_like(z); cnt = np.zeros_like(z)
        for dy, dx in ((0, a), (a, 0)) if b == 0 else ((a, a), (a, -a)):
            H_, W_ = z.shape
            ys = slice(max(0, -dy), H_ - max(0, dy)); xs = slice(max(0, -dx), W_ - max(0, dx))
            ye = slice(max(0, dy), H_ - max(0, -dy)); xe = slice(max(0, dx), W_ - max(0, -dx))
            d = z[ye, xe] - z[ys, xs] - (dx*cs*0.5*(gx[ye, xe] + gx[ys, xs]) + dy*cs*0.5*(gy[ye, xe] + gy[ys, xs]))
            oy, ox = (abs(dy) + 1)//2, (abs(dx) + 1)//2                     # 放到中点（向下取整的偏移，σw ≫ 1 格，影响可忽略）
            acc[oy:oy + d.shape[0], ox:ox + d.shape[1]] += d*d; cnt[oy:oy + d.shape[0], ox:ox + d.shape[1]] += 1
        g = gaussian_filter(acc, σw/cs); w = gaussian_filter(cnt, σw/cs)
        out.append((L, np.sqrt(g/np.maximum(w, 1e-9)).astype(np.float32)))
    fit = [p for p in out if 2.5 <= p[0] <= 12.5]
    Ls = np.log(np.array([p[0] for p in fit]))[:, None, None]; Y = np.log(np.maximum(np.stack([p[1] for p in fit]), 1e-6))
    xm = Ls.mean(0); ym = Y.mean(0)
    H = ((Ls - xm)*(Y - ym)).sum(0)/((Ls - xm)**2).sum(0)
    A3 = np.exp(ym + H*(math.log(3.0) - xm))
    return A3.astype(np.float32), H.astype(np.float32), out


# ── ② 地类（纯轨道：查找表处处套用，不叠 Navcam 实测）────────────────────────
def 地类_轨道():
    """57 ⑦ 的 地类.npz['hirise'] 在 ±50 m 重叠区直接用了 Navcam 实测分类（Ph[sl] = Pk），不能用于留出。
    这里照 57 ⑦ 原样复原「HiRISE 25 cm 亮度 × 1 m 纹理 → 四类比例」的 24×24 查找表（训练样本仍是本站 Navcam，记为同站信息），
    然后处处只用查表结果。返回 25 cm、±1 km 的 (8000, 8000, 4) 以及与 57 版在重叠区外的最大差（应 ≈ float16 舍入）。"""
    from scipy.ndimage import uniform_filter
    K = np.load(REC/"地类.npz"); P = K["mid"].astype(np.float32); P[P < 0] = np.nan; cs, n = float(K["cs_mid"]), int(K["n_mid"])
    hz = np.load(REC/"反照率_HiRISE.npz"); Ah = hz["A"].astype(np.float32).mean(-1); hcs, hn = float(hz["cs"]), int(hz["n"]); del hz
    tex = np.sqrt(np.maximum(uniform_filter(Ah**2, 4) - uniform_filter(Ah, 4)**2, 0))
    k = int(round(hcs/cs)); Pk = np.nanmean(P[:n//k*k, :n//k*k].reshape(n//k, k, n//k, k, 4), (1, 3)); del P
    off = (hn - n//k)//2; sl = (slice(off, off + n//k), slice(off, off + n//k))
    a_ov, t_ov = Ah[sl].ravel(), tex[sl].ravel(); p_ov = Pk.reshape(-1, 4); ok = np.isfinite(p_ov).all(1)
    qa = np.quantile(a_ov[ok], np.linspace(0, 1, 25)); qt = np.quantile(t_ov[ok], np.linspace(0, 1, 25))
    fb = lambda a, t: (np.clip(np.digitize(a, qa) - 1, 0, 23), np.clip(np.digitize(t, qt) - 1, 0, 23))
    ia, it = fb(a_ov[ok], t_ov[ok]); lut = np.zeros((24, 24, 4)); cnt = np.zeros((24, 24))
    np.add.at(lut, (ia, it), p_ov[ok]); np.add.at(cnt, (ia, it), 1)
    lut = (lut + 5*p_ov[ok].mean(0))/(cnt[..., None] + 5)
    ia, it = fb(Ah, tex); Ph = lut[ia, it].astype(np.float32)
    H57 = K["hirise"]; m = np.ones(Ph.shape[:2], bool); m[sl] = False
    diff = float(np.abs(Ph[::7, ::7][m[::7, ::7]] - H57[::7, ::7][m[::7, ::7]].astype(np.float32)).max())
    return Ph, hcs, diff


# ── ③ 石块 k ─────────────────────────────────────────────────────────
def golombek_N(k, D1, D2=3.0, n=400):
    """Golombek & Rapp 1997：F(D) = k·e^(−qD)，q = 1.79 + 0.152/k → 每 m² [D1, D2) 的块数。"""
    q = 1.79 + 0.152/k; D = np.geomspace(D1, D2, n); nd = k*q*np.exp(-q*D)/(math.pi*D*D/4)
    return float(np.trapezoid(nd, D))


def k_由密度(N8):
    lo, hi = 1e-4, 0.5
    for _ in range(60):
        m = math.sqrt(lo*hi)
        if golombek_N(m, 0.08) < N8: lo = m
        else: hi = m
    return math.sqrt(lo*hi)


# ── ④ 沙波（HiRISE 正射方向谱）────────────────────────────────────────
def 沙波谱(L, cs=0.25, 块=256, λ=(1.0, 6.0)):
    """每 64 m 块：ln 亮度去均值 + Hann 窗 → 二维功率谱；在 λ 1–6 m 的环带里按 5° 方位分箱，
    突出度 = 最强方位 / 各方位中位；记峰的波长与脊走向（波矢方向 + 90°）。"""
    nb = L.shape[0]//块; win = np.outer(np.hanning(块), np.hanning(块))
    f = np.fft.fftfreq(块, cs); FX, FY = np.meshgrid(f, f); FR = np.hypot(FX, FY)
    ang = (np.degrees(np.arctan2(FX, FY)) % 180.0)                           # 波矢方位（自北顺时针，0–180）
    band = (FR >= 1/λ[1]) & (FR <= 1/λ[0]); ab = (ang[band]//5).astype(int); fr = FR[band]
    prom = np.zeros((nb, nb), np.float32); wl = np.zeros_like(prom); crest = np.zeros_like(prom)
    for i in range(nb):
        for j in range(nb):
            t = L[i*块:(i + 1)*块, j*块:(j + 1)*块]; t = (t - t.mean())*win
            P = np.abs(np.fft.fft2(t))**2; p = P[band]
            s = np.bincount(ab, p, 36); c = np.bincount(ab, minlength=36); s = s/np.maximum(c, 1)
            k = int(np.argmax(s)); prom[i, j] = s[k]/max(np.median(s), 1e-12)
            m = ab == k; wl[i, j] = 1/np.average(fr[m], weights=p[m]); crest[i, j] = (k*5 + 2.5 + 90) % 180
    return prom, wl, crest


# ── ⑤ 坑：剖面表 + 坑表 ───────────────────────────────────────────────
def 坑剖面表(ns=48, smax=1.6, res=0.02, rmax=5.0):
    """归一化剖面（R = 1，D = 2）：坑内 z = −d₀ + (d₀ + h₀)·r^1.75（Watters 2015 平均剖面幂律），坑外 h₀·r^−3；
    新鲜坑缘到底 (d₀ + h₀)/D = 0.20、坑缘 h₀/D = 0.036。退化 = 二维扩散 = 高斯卷积 σ = s·R（σ² = 2κt）。
    返回 s 表、r 表、剖面/D（ns × nr）、坑缘到底 d/D(s)、坑缘高 h/D(s)。"""
    from scipy.ndimage import gaussian_filter
    D = 2.0; h0 = 坑["新鲜hD"]*D; d0 = 坑["新鲜dD"]*D - h0
    n = int(2*(rmax + 2*smax + 1)/res) | 1; c = (np.arange(n) - n//2)*res; X, Y = np.meshgrid(c, c); r = np.hypot(X, Y)
    z = np.where(r < 1, -d0 + (d0 + h0)*r**坑["指数"], h0*np.maximum(r, 1)**坑["坑外指数"])
    s_tab = np.linspace(0, smax, ns); r_tab = np.arange(0, rmax + 1e-9, res); prof = []; dD = []; hD = []
    for s in s_tab:
        zz = gaussian_filter(z, s/res, mode="nearest") if s > 0 else z
        p = zz[n//2, n//2:n//2 + len(r_tab)]
        prof.append(p/D); dD.append((p.max() - p.min())/D); hD.append((p.max() - p[-1])/D)
    return s_tab.astype(np.float32), r_tab.astype(np.float32), np.array(prof, np.float32), np.array(dD), np.array(hD)


def 坑表(s_tab, dD_tab):
    """每 50 m 格按 (种子, 格号) 播种：数目 Poisson(面积·f_eq·N_eq(≥D_min))，D 按 N(≥D) ∝ D^−1.83 截断抽样，
    退化等级按 Sweeney 2018 的样本比 2:3:4:5 = 1:2:4:4，d/D 加 ±10% 抖动 → 由剖面表反查扩散 σ → 年龄 σ²/(2κ)。"""
    a = 1.83; Nm2 = 坑["f_eq"]*10**-1.14*(坑["D_min"]/1000)**-a/1e6            # 每 m² ≥ D_min
    g = 坑["格"]; m = int(坑["半宽"]/g); rows = []
    lv = list(坑["等级dD"]); p = np.array([坑["等级比"][k] for k in lv], float); p /= p.sum()
    for i in range(-m, m):
        for j in range(-m, m):
            rng = np.random.default_rng(哈希(SEED, "坑", i, j))
            for _ in range(rng.poisson(Nm2*g*g)):
                u = rng.random(); D = (坑["D_min"]**-a - u*(坑["D_min"]**-a - 坑["D_max"]**-a))**(-1/a)
                x = (j + rng.random())*g; y = (i + rng.random())*g
                k = lv[rng.choice(len(lv), p=p)]; dd = 坑["等级dD"][k]*math.exp(rng.normal(0, 0.1))
                s = float(np.interp(-dd, -dD_tab, s_tab))                    # dD 随 s 单调减
                σ = s*D/2; rows.append((x, y, D, dd, s, σ, σ*σ/(2*坑["κ"]), int(k)))
    return np.array(rows, np.float64).reshape(-1, 8)


def main():
    from scipy.ndimage import zoom
    t0 = time.time(); GEN.mkdir(parents=True, exist_ok=True)
    T = np.load(REC/"地形.npz"); Lv = json.loads(str(T["levels"])); cs_h, n_h = Lv["HiRISE"]
    hi = T["hirise"].astype(np.float64)
    # ① 振幅：先在 ±1.2 km 上算（窗口边缘），再裁到 ±1 km
    sub = 裁中(hi, n_h, 2400)
    A3, H3, nus = 局部振幅(sub, cs_h)
    A3 = 裁中(A3, 2400, N); H3 = np.clip(裁中(H3, 2400, N), 0.4, 1.2)
    nuH = {f"{L:.2f}": 裁中(v, 2400, N) for L, v in nus if L < 2.5}               # HiRISE 自身 1–2.8 m 的增量 ν
    # 频带振幅：HiRISE 在 λ = 6、12 m 倍频程上的带通 rms（DoG σ = λ/6.5、2λ/6.5，和 77 的合成噪声同一个带形），高斯窗 σ 8 m
    from scipy.ndimage import gaussian_filter
    Bλ = {}
    for λ in (6.0, 12.0):
        d = gaussian_filter(sub, λ/6.5/cs_h) - gaussian_filter(sub, 2*λ/6.5/cs_h)
        Bλ[λ] = 裁中(np.sqrt(gaussian_filter(d*d, 8.0/cs_h)), 2400, N).astype(np.float32)
    log(f"HiRISE 6 m 带 rms：车旁 r<15 m {np.median(Bλ[6.0][np.hypot(*np.meshgrid(网格(CS, N), 网格(CS, N))) < 15])*1000:.0f} mm，"
        f"±1 km 中位 {np.median(Bλ[6.0])*1000:.0f} mm；12/6 m 比中位 {np.median(Bλ[12.0]/np.maximum(Bλ[6.0], 1e-6)):.2f}")
    c = 网格(CS, N); X, Y = np.meshgrid(c, c); mast = T["mast"][:2]; r = np.hypot(X - mast[0], Y - mast[1])
    ring = lambda a, b: float(np.median(A3[(r >= a) & (r < b)]))
    log(f"A3 = ν_HiRISE(3 m)：车旁 r<15 m {ring(0, 15)*1000:.0f} mm，15–25 m {ring(15, 25)*1000:.0f}，25–45 m {ring(25, 45)*1000:.0f}，"
        f"±1 km 中位 {np.median(A3)*1000:.0f} mm；H 中位 {np.median(H3):.2f}（{time.time() - t0:.0f} s）")
    # ② 地类、k
    P, cs_k, dk = 地类_轨道(); f = int(round(CS/cs_k))
    log(f"地类（纯查表）：与 57 版在 ±50 m 外最大差 {dk:.4f}")
    np.save(GEN/"地类_轨道_25cm.npy", P.astype(np.float16))                    # 77 用（地类_中/地类_HiRISE 导出）
    W = P.reshape(N, f, N, f, 4).mean((1, 3)); del P; W = np.clip(W, 0, None); W /= np.maximum(W.sum(-1, keepdims=True), 1e-6)
    k_c = {c_: k_由密度(石块密度_8cm[c_]) for c_ in CLASSES}
    kmap = (W*np.array([k_c[c_] for c_ in CLASSES])).sum(-1).astype(np.float32)
    log("各地类 k（按指纹 D ≥ 8 cm 密度反解 Golombek）：" + "，".join(f"{c_} {v:.4f}" for c_, v in k_c.items()) +
        f"；地类比例 ±1 km {np.round(W.reshape(-1, 4).mean(0), 2).tolist()}，r<15 m {np.round(W[r < 15].mean(0), 2).tolist()}")
    # ③ 反照率、沙波
    AH = np.load(REC/"反照率_HiRISE.npz"); A = AH["A"]; fa = int(round(CS/float(AH["cs"])))
    lum = np.log(np.maximum(A.astype(np.float32).mean(-1), 1e-4))
    lnA = lum.reshape(N, fa, N, fa).mean((1, 3)).astype(np.float32)
    prom, wl, crest = 沙波谱(lum, float(AH["cs"]))
    thr = max(3.0, 3*float(np.median(prom)))                                  # 处处都有的峰（推扫条纹）不算
    idx = np.clip((prom - thr)/thr, 0, 1).astype(np.float32)
    log(f"沙波谱：突出度中位 {np.median(prom):.1f}（全区普遍，视为推扫伪影），超过 {thr:.1f} 的块 {np.mean(prom > thr)*100:.1f}%；"
        f"峰波长中位 {np.median(wl):.2f} m，脊走向中位 {np.median(crest):.0f}°")
    # ④ 坑
    s_tab, r_tab, prof, dD_tab, hD_tab = 坑剖面表()
    CT = 坑表(s_tab, dD_tab)
    log(f"坑表：±{坑['半宽']:.0f} m 内 D {坑['D_min']}–{坑['D_max']} m 共 {len(CT)} 个（f_eq {坑['f_eq']}），"
        f"d/D 中位 {np.median(CT[:, 3]):.3f}，扩散 σ 中位 {np.median(CT[:, 5]):.2f} m，等效年龄中位 {np.median(CT[:, 6])/1e3:.0f} ka")
    np.savez_compressed(GEN/"参数图.npz", A3=A3, H3_12=H3.astype(np.float32), W=W.astype(np.float16), k=kmap, lnA=lnA,
                        B6=Bλ[6.0], B12=Bλ[12.0], nuH_L=np.array([float(k) for k in nuH]), nuH=np.stack(list(nuH.values())).astype(np.float32), 沙波指数=idx, 沙波波长=wl, 沙波脊=crest, 沙波突出=prom, 坑表=CT, 坑_s=s_tab, 坑_r=r_tab, 坑_剖面=prof,
                        坑_dD=dD_tab.astype(np.float32), 坑_hD=hD_tab.astype(np.float32), cs=CS, n=N, mast=T["mast"], align=T["align"])
    J = dict(说明=__doc__.strip().split("\n")[0], 时间=time.strftime("%F %T"), 格=dict(cs=CS, n=N, half=CS*N/2),
             H曲线=H_曲线, 石块密度_8cm=石块密度_8cm, k_地类=k_c, 反照率增益=反照率增益, 输沙方向=输沙方向, 坑=坑, 种子=SEED,
             振幅=dict(窗σ_m=8.0, 去坡σ_m=20.0, nuH_车旁r15={k: float(np.median(v[r < 15])) for k, v in nuH.items()}, 车旁r15=ring(0, 15), 环15_25=ring(15, 25), 环25_45=ring(25, 45), 全区中位=float(np.median(A3)),
                     全区均方根=float(np.sqrt(np.mean(A3**2))), H中位=float(np.median(H3))),
             沙波=dict(突出度中位=float(np.median(prom)), 门槛=thr, 有沙波块比例=float(np.mean(prom > thr))),
             坑统计=dict(个数=len(CT), dD中位=float(np.median(CT[:, 3])), σ中位_m=float(np.median(CT[:, 5]))),
             同站信息=["HiRISE 对齐（立体）", "地类查找表（Navcam）", "HiRISE 颜色查找表（Navcam/Mastcam）", "H 曲线、石块密度、反照率增益（本站指纹）"])
    (GEN/"参数图.json").write_text(json.dumps(J, ensure_ascii=False, indent=1, default=float))
    图(A3, H3, W, kmap, idx, prom, lnA, CT, mast)
    log(f"→ {GEN/'参数图.npz'}（{time.time() - t0:.0f} s）")


def 图(A3, H3, W, kmap, idx, prom, lnA, CT, mast):
    import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
    plt.rcParams["font.sans-serif"] = ["Noto Sans CJK SC", "Noto Sans CJK JP", "DejaVu Sans"]; plt.rcParams["axes.unicode_minus"] = False
    fig, ax = plt.subplots(2, 4, figsize=(16, 8.2), dpi=90); e = [-1000, 1000, -1000, 1000]
    def show(a, k, t, **kw):
        im = a_.imshow(k, origin="lower", extent=e, **kw); a_.set_title(t, fontsize=10); fig.colorbar(im, ax=a_, fraction=0.046)
    a_ = ax[0, 0]; show(a_, A3*1000, "A3 = ν_HiRISE(3 m)，mm", cmap="magma", vmin=0, vmax=np.percentile(A3, 99)*1000)
    a_ = ax[0, 1]; show(a_, H3, "H（3–12 m 局部拟合）", cmap="viridis", vmin=0.5, vmax=1.2)
    a_ = ax[0, 2]; a_.imshow(W[..., :3], origin="lower", extent=e); a_.set_title("地类 RGB = 沙 / 砾石 / 基岩", fontsize=10)
    a_ = ax[0, 3]; show(a_, kmap, "石块 k(x)", cmap="cividis")
    a_ = ax[1, 0]; show(a_, lnA, "HiRISE ln 反照率", cmap="gray")
    a_ = ax[1, 1]; im = a_.imshow(prom, origin="lower", extent=e, cmap="plasma"); a_.set_title("正射 1–6 m 方向谱突出度", fontsize=10); fig.colorbar(im, ax=a_, fraction=0.046)
    a_ = ax[1, 2]; show(a_, idx, "米级沙波指数", cmap="Blues", vmin=0, vmax=1)
    a_ = ax[1, 3]; a_.scatter(CT[:, 0], CT[:, 1], s=CT[:, 2]**2*0.4, c=CT[:, 3], cmap="viridis", lw=0); a_.set_xlim(-400, 400); a_.set_ylim(-400, 400)
    a_.set_aspect("equal"); a_.set_title(f"合成小坑 {len(CT)} 个（色 = d/D）", fontsize=10)
    for a_ in ax.flat: a_.plot(mast[0], mast[1], "c+", ms=8); a_.tick_params(labelsize=7)
    for a_ in ax.flat[:7]:
        a_.set_xlim(-300, 300); a_.set_ylim(-300, 300)
    fig.suptitle("76 参数图（只用轨道数据，±300 m 局部，+ = 车）", fontsize=12); fig.tight_layout()
    fig.savefig(GEN/"参数图.png"); plt.close(fig)


if __name__ == "__main__":
    main()
