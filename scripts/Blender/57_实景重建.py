"""
实景重建（真三维，venv 里跑）：毅力号 site 26 / drive 1222 这一站 → 能从任何角度、任何太阳下渲染的地形 + 反照率。
数据由 56_实景数据.py 下好（DEM/Blender缓存/_素材/PDS/站26_1222/ 与 sol0530/）。

坐标：Blender ENU（x 东、y 北、z 上，m），原点＝本站 LOCAL_LEVEL 原点（毅力号导航点，站点坐标 68.4117, −21.7435, −11.5649），
z＝0 对应海拔 E0 = −2523.168 m（NASA 到站定位，DeltaGeoid）。远处按火星曲率下沉 d²/2R（15 km 处 33 m）。

① 相机：每块 Navcam 网格的照片按 55 的方法标定（顶点↔像素 → Kannala–Brandt 鱼眼），得到站点系相机 → 相机.json
② 地形：残差式贝叶斯融合，四层由粗到细，每层以上一层为先验：
     MOLA 400 m（±90 km）→ CTX 20 m（±40 km，空洞用 MOLA）→ HiRISE 1 m（±1.8 km，竖直/水平先对齐到立体数据）→ 立体 10 cm（±50 m）→ 立体 2 cm（±10 m）。
   立体样本＝全部网格顶点 + XYZ 镶嵌，权重 1/σ²，σ = 3 mm + 2.4e-4·r²（Navcam 基线 0.42 m、0.3 px 匹配误差）。
   每格：残差 = 样本 − 先验 → 加权均值（3σ 剔离群）→ push-pull 补洞 → 离数据越远越退回先验（near 2 m、mid 8 m 尺度）。
   → 地形.npz（各层高度网格 + 覆盖权重 + 网格参数）
③ 反照率：每格投到每台相机（z-buffer 判遮挡，相机自己的网格也溅进去，所以机械臂会挡住它后面的地）→ 线性亮度样本；
   模型 L = A·(a_c·S + b_c·K)：S＝阴影×max(n·s, 0)（拍摄时的太阳，标签站点系），K＝天空可见度；
   交替求每格 A 与每台相机的 a_c、b_c（曝光×日光、曝光×天光），Huber 降权；红通道中位定标到 0.24 → 反照率_近/中.npz
运行：.venv/bin/python scripts/Blender/57_实景重建.py 相机|地形|反照率
"""
import importlib.util, json, math, pathlib, re, sys, time
import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
MAP = HERE.parent.parent
PDS = MAP/"DEM"/"Blender缓存"/"_素材"/"PDS"
DIR = PDS/"站26_1222"
DIRS = (DIR, PDS/"sol0530", DIR/"邻站")                                  # 邻站：到站前的 drive 1004（21 m 外）、离站途中
OUT = DIR/"重建"
R_MARS = 3396190.0
LAT, LON, E0 = 18.45864728, 77.40592495, -2523.168
O_LL = np.array([68.4117, -21.7435, -11.5649])                          # LOCAL_LEVEL_26_1222 原点（站点系）
MAST = np.array([-0.255576, -0.875698, -2.03704])                        # 镶嵌投影中心（LOCAL_LEVEL 系，≈桅杆头）
M_SB = np.array([[0, 1, 0], [1, 0, 0], [0, 0, -1]], float)               # 站点（北、东、下）→ ENU（东、北、上）
LEVELS = {"近": (0.02, 1000), "中": (0.10, 1000)}                         # 格距 m、边长格数 → ±10 m、±50 m
HI = (1.0, 3600)                                                         # HiRISE 重采样到 ENU：1 m、±1.8 km
CTX = (20.0, 4000)                                                       # CTX：20 m、±40 km
MOLA = (400.0, 450)                                                      # MOLA：400 m、±90 km（最外圈）


def log(*a): print("[57]", *a, flush=True)


_M55 = None


def m55():
    global _M55
    if _M55 is None:
        spec = importlib.util.spec_from_file_location("m55", HERE/"55_实景复现.py")
        _M55 = importlib.util.module_from_spec(spec); spec.loader.exec_module(_M55)
    return _M55


def objs():
    return sorted({p for d in DIRS for p in d.glob("N[LR][FM]_*.obj")}, key=lambda p: p.name)


def to_enu(s): return (np.asarray(s, np.float64) - O_LL) @ M_SB.T


MAST_ENU = MAST @ M_SB.T                                                  # LOCAL_LEVEL 与站点同轴，只差原点


# ── ① 相机 ─────────────────────────────────────────────────────────
def cameras():
    from PIL import Image
    M = m55(); OUT.mkdir(exist_ok=True)
    path = OUT/"相机.json"
    done = {c["file"]: c for c in json.loads(path.read_text())} if path.exists() else {}
    for p in objs():
        if p.name in done or not p.with_suffix(".png").exists(): continue    # 照片还没下完的下回再标
        W, H = Image.open(p.with_suffix(".png")).size
        c = M.calibrate_one(p, W, H)
        if c is None: log(f"{p.name[:30]} 无可用点，跳过"); continue
        if c["err_90"] > 8:                                                # 局部最优：拿同一只眼最好的当初值重来
            ref = [g for g in done.values() if g["file"][:2] == p.name[:2] and g["err_90"] <= 8]
            if ref:
                c2 = M.calibrate_one(p, W, H, init=min(ref, key=lambda g: g["err_med"]))
                if c2 and c2["err_med"] < c["err_med"]: c = c2
        c["dir"] = str(p.parent.relative_to(PDS)); done[p.name] = c
        lab = p.with_name(p.stem + ".label.xml")                          # 拍摄时的太阳（站点系方位、高度）
        if lab.exists():
            x = lab.read_text()
            az =re.findall(r'<geom:solar_azimuth unit="deg">([-\d.]+)<', x); el = re.findall(r'<geom:solar_elevation unit="deg">([-\d.]+)<', x)
            lt = re.search(r"<local_true_solar_time>([\d:]+)<", x)
            if az: c["sun_all"] = [[float(a), float(e)] for a, e in zip(az, el)]
            if lt: c["ltst"] = lt.group(1)
        log(f"{p.name[:34]} 误差 中位 {c['err_med']:.2f} / 90% {c['err_90']:.2f} px")
        path.write_text(json.dumps(list(done.values()), indent=1))
    log(f"相机 {len(done)} 台 → {path}")


# ── ② 地形 ─────────────────────────────────────────────────────────
def obj_vertices(p):
    data = p.read_bytes()
    return np.array(b" ".join(re.findall(rb"^v ([^\n]+)", data, re.M)).split(), np.float64).reshape(-1, 3)


def stereo_samples():
    """全部网格顶点 + XYZ 镶嵌 → ENU 点 (x, y, z) 与 σ。"""
    pts, fe = [], []
    cams = {c["file"]: c for c in json.loads((OUT/"相机.json").read_text())} if (OUT/"相机.json").exists() else {}
    for p in objs():
        Vs = obj_vertices(p)
        pts.append(to_enu(Vs).astype(np.float32))
        if p.name in cams:                                                 # 羽化：离画面边缘越近权重越低（各张网格间有厘米级系统差）
            _, _, _, rn, _ = project_pts(cams[p.name], Vs)
            fe.append(np.clip((0.95 - rn)/0.35, 0.03, 1).astype(np.float32))
        else:
            fe.append(np.ones(len(Vs), np.float32))
    xyz = PDS/"sol0530"/"镶嵌"/"N_LRGB_0532XXYZ_0261222_CYL_L_AUTOGENJ01.IMG"
    if xyz.exists():
        a = np.fromfile(xyz, ">f4", offset=167256, count=3*1394*4646).reshape(3, -1).T
        pts.append(to_enu(a[(a != 0).all(1)]).astype(np.float32)); fe.append(np.full(len(pts[-1]), 0.5, np.float32))
    P = np.concatenate(pts); F = np.concatenate(fe)
    r = np.linalg.norm(P - MAST_ENU, axis=1)
    keep = (r > 1.0) & (r < 150)
    P, r, F = P[keep], r[keep], F[keep]
    # 车体、机械臂：转到车体系（X 前、Y 右、Z 下，原点≈车底地面；车停在 14° 横坡上，不能按 ENU 高度判）
    Q = (P.astype(np.float64) @ M_SB) @ rover_R()                          # ENU → 北东下 → 车体（行向量右乘 R）
    up = -Q[:, 2]
    body = (Q[:, 0] > -1.8) & (Q[:, 0] < 2.4) & (np.abs(Q[:, 1]) < 1.4) & (up > 0.20)
    arm = (Q[:, 0] >= 2.4) & (Q[:, 0] < 3.4) & (np.abs(Q[:, 1]) < 1.4) & (up > 0.45)
    keep = ~(body | arm)
    log(f"立体样本 {keep.sum():,} 点（剔车体 {body.sum():,}、机械臂 {arm.sum():,}）")
    return P[keep], ((0.003 + 2.4e-4*r[keep]**2)/np.sqrt(F[keep])).astype(np.float32)


ROVER_YPR = (-107.7939695, -1.871436595, -14.23768937)                   # NASA 到站定位：航向、俯仰、横滚（°）


def rover_R():
    """车体系 → LOCAL_LEVEL（北东下）的旋转（航向-俯仰-横滚，ZYX）。"""
    y, p, r = (math.radians(v) for v in ROVER_YPR)
    Rz = np.array([[math.cos(y), -math.sin(y), 0], [math.sin(y), math.cos(y), 0], [0, 0, 1]])
    Ry = np.array([[math.cos(p), 0, math.sin(p)], [0, 1, 0], [-math.sin(p), 0, math.cos(p)]])
    Rx = np.array([[1, 0, 0], [0, math.cos(r), -math.sin(r)], [0, math.sin(r), math.cos(r)]])
    return Rz @ Ry @ Rx


def grid_xy(cs, n):
    c = (np.arange(n) + 0.5 - n/2)*cs
    return c                                                               # 格心坐标（x 与 y 同）


def sample(grid, cs, n, x, y, order=1):
    """规则 ENU 网格（行＝y 自南向北、列＝x）在 (x, y) 处插值。"""
    from scipy.ndimage import map_coordinates
    return map_coordinates(grid, [y/cs + n/2 - 0.5, x/cs + n/2 - 0.5], order=order, mode="nearest")


def push_pull(z, w):
    from scipy.ndimage import zoom
    if min(z.shape) < 4: return np.where(w > 0, z, (z*w).sum()/max(w.sum(), 1e-9))
    h, wd = z.shape[0]//2*2, z.shape[1]//2*2
    zz, ww = z[:h, :wd], w[:h, :wd]
    zw = (zz*ww).reshape(h//2, 2, wd//2, 2).sum((1, 3)); w2 = ww.reshape(h//2, 2, wd//2, 2).sum((1, 3))
    zc = push_pull(np.where(w2 > 0, zw/np.maximum(w2, 1e-9), 0), np.minimum(w2, 1))
    up = zoom(zc, (z.shape[0]/zc.shape[0], z.shape[1]/zc.shape[1]), order=1, mode="nearest")
    a = np.clip(w, 0, 1); return a*z + (1 - a)*up


def fuse(P, sig, prior, cs, n, decay, smooth=False):
    """残差融合：返回 (高度网格, 每格权重和)。prior(x, y) → 先验高度。"""
    from scipy.ndimage import distance_transform_edt
    half = cs*n/2
    m = (np.abs(P[:, 0]) < half) & (np.abs(P[:, 1]) < half)
    x, y, z, s = P[m, 0], P[m, 1], P[m, 2], sig[m]
    res = z - prior(x, y)
    k = (np.floor(y/cs + n/2).astype(np.int64))*n + np.floor(x/cs + n/2).astype(np.int64)
    w = 1/s**2
    for it in range(2):                                                    # 第二遍剔掉离格均值 3σ+2 cm 以外的
        W = np.bincount(k, w, n*n); Rm = np.bincount(k, w*res, n*n)/np.maximum(W, 1e-12)
        if it == 0:
            ok = np.abs(res - Rm[k]) < 3*s + 0.02
            k, w, res, s = k[ok], w[ok], res[ok], s[ok]
    W = W.reshape(n, n).astype(np.float32); Rm = Rm.reshape(n, n).astype(np.float32)
    if smooth:                                                             # 归一化卷积，平滑尺度随距离长（立体误差 ∝ r²）
        from scipy.ndimage import gaussian_filter
        c = grid_xy(cs, n); X, Y = np.meshgrid(c, c)
        sig_m = np.clip(0.004*np.maximum(np.hypot(X - MAST_ENU[0], Y - MAST_ENU[1]) - 8, 0)**1.5, 0, 1.5)   # 8 m 内不平滑，30 m ≈ 0.4 m，50 m ≈ 1.1 m
        WR = W*Rm; out = Rm.copy(); Wo = W.copy(); prev = 0.0
        for sg in (0.15, 0.3, 0.6, 1.0, 1.5):
            m = (sig_m > prev) & (sig_m <= sg + 1e-9)
            if m.any():
                gw = gaussian_filter(W, sg/cs); gr = gaussian_filter(WR, sg/cs)
                out[m] = (gr/np.maximum(gw, 1e-12))[m]; Wo[m] = gw[m]
            prev = sg
        Rm = np.where(Wo > 0, out, 0).astype(np.float32); W = np.where(W > 0, W, np.where(Wo > W.max()*1e-6, Wo, 0)).astype(np.float32)
    has = W > 0
    Rf = push_pull(np.where(has, Rm, 0), has.astype(np.float32))
    d = distance_transform_edt(~has)*cs
    Rf = np.where(has, Rm, Rf*np.exp(-(d/decay)**2))
    c = grid_xy(cs, n); X, Y = np.meshgrid(c, c)
    return (prior(X.ravel(), Y.ravel()).reshape(n, n) + Rf).astype(np.float32), W


def enu_to_lonlat(x, y):
    lat = LAT + np.degrees(y/R_MARS)
    lon = LON + np.degrees(x/(R_MARS*np.cos(np.radians(lat))))
    return lon, lat


def orbital_grid(name, cs, n, shift=(0.0, 0.0), keep_holes=False):
    """把下好的轨道高程窗口重采样到 ENU 网格（含曲率下沉）。shift：ENU 里对轨道数据的平移（对齐用）。
    keep_holes：没数据的地方给 nan（留给下一层补），否则用近邻补。"""
    from scipy.ndimage import map_coordinates, distance_transform_edt
    from rasterio.warp import transform
    a = np.load(DIR/f"{name}.npy").astype(np.float32); m = json.loads((DIR/f"{name}.json").read_text())
    bad = ~np.isfinite(a) | (a < -1e30)
    if m.get("nodata") is not None: bad |= a == np.float32(m["nodata"])
    valid = (~bad).astype(np.float32)
    if bad.any():                                                          # 插值前先用近邻补（三次插值不能碰 nan）
        idx = distance_transform_edt(bad, return_distances=False, return_indices=True); a = a[tuple(idx)]
    c = grid_xy(cs, n); out = np.empty((n, n), np.float32)
    t = m["transform"]
    for r0 in range(0, n, 256):                                            # 分条，省内存
        X, Y = np.meshgrid(c, c[r0:r0 + 256])
        lon, lat = enu_to_lonlat(X.ravel() - shift[0], Y.ravel() - shift[1])
        px, py = transform(f"+proj=longlat +R={R_MARS} +no_defs", m["crs"], lon, lat)
        col = (np.array(px) - t[2])/t[0] - 0.5; row = (np.array(py) - t[5])/t[4] - 0.5
        v = map_coordinates(a, [row, col], order=3, mode="nearest")
        if keep_holes:
            ok = map_coordinates(valid, [row, col], order=1, mode="constant", cval=0) > 0.5
            v = np.where(ok, v, np.nan)
        d2 = X.ravel()**2 + Y.ravel()**2
        out[r0:r0 + 256] = (v - E0 - d2/(2*R_MARS)).reshape(X.shape)       # 曲率下沉
    return out


def align_hirise(P, sig, Hgrid, cs, n):
    """HiRISE 对齐到立体：10–60 m 环带，水平 ±4 m（0.5 m 步）搜去趋势后高度差的方差最小，再取竖直中位差。"""
    r = np.hypot(P[:, 0], P[:, 1]); m = (r > 10) & (r < 60) & (sig < 0.5)
    x, y, z = P[m, 0][::7], P[m, 1][::7], P[m, 2][::7]
    best = None
    for dx in np.arange(-4, 4.01, 0.5):
        for dy in np.arange(-4, 4.01, 0.5):
            d = z - sample(Hgrid, cs, n, x - dx, y - dy)
            v = np.var(d - np.median(d))
            if best is None or v < best[0]: best = (v, dx, dy, np.median(d))
    log(f"HiRISE 对齐：水平 ({best[1]:+.1f}, {best[2]:+.1f}) m，竖直 {best[3]:+.2f} m，残差 σ {math.sqrt(best[0]):.2f} m")
    return best[1], best[2], best[3]


def terrain():
    OUT.mkdir(exist_ok=True); t0 = time.time()
    mo = orbital_grid("mola_463m", *MOLA)
    cx = orbital_grid("ctx_dtm_20m", *CTX, keep_holes=True)
    c = grid_xy(*CTX); X, Y = np.meshgrid(c, c)
    mos = sample(mo, *MOLA, X.ravel(), Y.ravel(), order=3).reshape(X.shape)
    hole = np.isnan(cx); dm = np.nanmedian(cx - mos)
    mo += dm                                                               # MOLA 竖直对齐到 CTX
    cx = np.where(hole, mos + dm, cx)
    if hole.any():                                                         # 接缝 1 km 内两边渐变
        from scipy.ndimage import distance_transform_edt
        a = np.clip(distance_transform_edt(~hole)*CTX[0]/1000, 0, 1)
        cx = a*cx + (1 - a)*(mos + dm)
    log(f"CTX → ENU {CTX[1]}² × {CTX[0]} m，空洞 {hole.mean()*100:.0f}% 用 MOLA 补（改正 {dm:+.1f} m）（{time.time() - t0:.0f} s）")
    P, sig = stereo_samples()
    hi0 = orbital_grid("hirise_dtm_1m", *HI)
    dx, dy, dz = align_hirise(P, sig, hi0, *HI)
    hi = orbital_grid("hirise_dtm_1m", *HI, shift=(dx, dy)) + dz
    # HiRISE 外缘 200 m 渐变到 CTX（CTX 也先竖直对齐到 HiRISE）
    c = grid_xy(*HI); X, Y = np.meshgrid(c, c)
    cxs = sample(cx, *CTX, X.ravel(), Y.ravel(), order=3).reshape(X.shape)
    cx += np.median(hi - cxs)
    edge = np.minimum(HI[0]*HI[1]/2 - np.abs(X), HI[0]*HI[1]/2 - np.abs(Y))
    a = np.clip(edge/200, 0, 1)
    hi = a*hi + (1 - a)*(cxs + np.median(hi - cxs))
    log(f"HiRISE → ENU {HI[1]}² × {HI[0]} m，CTX 竖直改正 {np.median(hi - cxs):+.2f} m")
    cs, n = LEVELS["中"]
    mid, Wm = fuse(P, sig, lambda x, y: sample(hi, *HI, x, y, order=3), cs, n, decay=8.0, smooth=True)
    log(f"中层 {n}² × {cs} m：有数据 {np.mean(Wm > 0)*100:.0f}%")
    cs2, n2 = LEVELS["近"]
    near, Wn = fuse(P, sig, lambda x, y: sample(mid, cs, n, x, y, order=3), cs2, n2, decay=2.0)
    log(f"近层 {n2}² × {cs2} m：有数据 {np.mean(Wn > 0)*100:.0f}%")
    np.savez_compressed(OUT/"地形.npz", near=near, near_w=Wn, mid=mid, mid_w=Wm, hirise=hi.astype(np.float32),
                        ctx=cx.astype(np.float32), mola=mo.astype(np.float32),
                        levels=json.dumps(dict(近=LEVELS["近"], 中=LEVELS["中"], HiRISE=HI, CTX=CTX, MOLA=MOLA)),
                        align=np.array([dx, dy, dz]), mast=MAST_ENU)
    log(f"地形.npz ✓（{time.time() - t0:.0f} s）")


# ── ③ 反照率 ───────────────────────────────────────────────────────
ALB = {"近": (0.01, 2000), "中": (0.04, 2500)}                            # 反照率格：1 cm ±10 m、4 cm ±50 m
ALB_MED_R = 0.24                                                         # 定标：近景红通道反照率中位数（三角洲浅色层 + 尘）


def sun_enu(az, el):
    a, e = math.radians(az), math.radians(el)
    return np.array([math.sin(a)*math.cos(e), math.cos(a)*math.cos(e), math.sin(e)])


def shift2(Z, ox, oy):
    """Z 平移 (ox 列, oy 行)，边缘用最近值。"""
    n0, n1 = Z.shape
    r = np.clip(np.arange(n0) + oy, 0, n0 - 1); c = np.clip(np.arange(n1) + ox, 0, n1 - 1)
    return Z[r][:, c]


def shadow(Z, cs, s, maxd):
    """朝太阳 s 走 maxd 米，被挡就 0（1＝受晒）。"""
    h = math.hypot(s[0], s[1]); dx, dy = s[0]/h, s[1]/h; tn = s[2]/h
    V = np.ones(Z.shape, bool); t = 1
    while t*cs <= maxd:
        V &= shift2(Z, int(round(t*dx)), int(round(t*dy))) <= Z + t*cs*tn
        t += max(1, t//20)
    return V


def sky_view(Z, cs, maxd, ndir=16):
    """天空可见度 ≈ 各方位 cos²(地平高度) 的平均（各向同性天空、水平面）。"""
    acc = np.zeros(Z.shape, np.float32)
    for k in range(ndir):
        a = 2*math.pi*k/ndir; dx, dy = math.cos(a), math.sin(a); hz = np.zeros(Z.shape, np.float32); t = 1
        while t*cs <= maxd:
            hz = np.maximum(hz, (shift2(Z, int(round(t*dx)), int(round(t*dy))) - Z)/(t*cs))
            t += max(1, t//10)
        acc += 1/(1 + hz**2)                                               # cos²(atan(hz))
    return acc/ndir


def normals(Z, cs):
    gy, gx = np.gradient(Z, cs)
    n = np.stack([-gx, -gy, np.ones_like(Z)], -1); return n/np.linalg.norm(n, axis=-1, keepdims=True)


def project_pts(cam, s):
    """站点系的点 → 照片像素 (u, v)（像素中心＝整数）、到相机距离、离光轴相对角、相机系 z。"""
    M = m55()
    R = np.array(cam["R"]); Xc = (s - np.array(cam["C"])) @ R.T
    u, v, th = M.kb_project(Xc, cam["f"], cam["cx"], cam["cy"], cam["k"])
    return u - 0.5, v - 0.5, np.linalg.norm(Xc, axis=1), th/cam["thmax"], Xc[:, 2]


def enu_to_site(b): return b @ M_SB + O_LL                                # M_SB 对称且自逆


def zbuffer(cam, pts_site, W, H, k=4):
    """把点（地形格 + 该相机自己的原始网格顶点，含机械臂）按距离溅到 1/k 分辨率 → 每像素最近距离（3×3 取最小补缝）。"""
    from scipy.ndimage import minimum_filter
    u, v, r, rn, zc = project_pts(cam, pts_site)
    ok = (zc > 0.05) & (rn < 1.0) & (u >= 0) & (v >= 0) & (u < W - 1) & (v < H - 1)
    iu = (u[ok]/k).astype(np.int32); iv = (v[ok]/k).astype(np.int32); r = r[ok]
    Wk, Hk = W//k + 1, H//k + 1
    zb = np.full(Wk*Hk, np.inf, np.float32)
    np.minimum.at(zb, iv*Wk + iu, r.astype(np.float32))
    return minimum_filter(zb.reshape(Hk, Wk), 3), k


def rover_proxy(step=0.02):
    """车体代理（车体系盒子：车身＋甲板、六轮、收起的机械臂、桅杆）表面点 → ENU。尺寸按 NASA 模型包围盒。"""
    boxes = [((-1.75, 1.30), (-1.30, 1.30), (0.55, 1.50)),                   # 车身 + 甲板上的仪器
             ((-1.80, -0.90), (-0.70, 0.70), (0.80, 1.75)),                  # 车尾 RTG
             ((1.30, 2.40), (-0.60, 0.80), (0.60, 1.20)),                    # 收起的机械臂 / 炮塔
             ((0.70, 1.00), (0.35, 0.75), (1.25, 2.25))]                     # 桅杆
    for x0 in (-1.05, 0.0, 1.05):
        for sy in (-1, 1): boxes.append(((x0 - 0.27, x0 + 0.27), tuple(sorted((sy*0.95, sy*1.35))), (0.0, 0.53)))
    pts = []
    for (xa, xb), (ya, yb), (za, zb) in boxes:
        xs, ys, zs = (np.arange(a, b + step/2, step) for a, b in ((xa, xb), (ya, yb), (za, zb)))
        for X, Y, Z in ((*np.meshgrid(xs, ys, [za, zb]),), (*np.meshgrid(xs, [ya, yb], zs),), (*np.meshgrid([xa, xb], ys, zs),)):
            pts.append(np.stack([X.ravel(), Y.ravel(), -Z.ravel()], 1))       # 车体系 Z 朝下
    Q = np.concatenate(pts)
    return (Q @ rover_R().T) @ M_SB                                        # 车体 → 北东下 → ENU


ROVER_BOXES_TIGHT = [((-1.75, 0.40), (-1.30, 1.30), (0.55, 1.50)),       # 车身后半＋甲板仪器（视线判遮挡用，比 rover_proxy 贴身）
                     ((0.40, 1.30), (-1.30, 1.30), (0.55, 1.10)),        # 车头：甲板只到 ~1.1 m
                     ((-1.80, -0.90), (-0.70, 0.70), (0.80, 1.75)),      # RTG
                     ((1.30, 2.40), (-0.60, 0.80), (0.60, 1.20))]        # 收起的机械臂（不含桅杆：相机就在桅杆头里）
_BOXES = DIR/"车体盒.json"                                                   # NASA 模型逐件包围盒（车体系，由 58 场景导出）
if _BOXES.exists():                                                      # 手工盒漏了前甲板仪器（高到 1.54 m）和桅杆底座，校准靶被印到地上
    ROVER_BOXES_TIGHT += [tuple(map(tuple, b)) for b in json.loads(_BOXES.read_text())["boxes"]]


def rays_hit_rover(C_enu, P_enu):
    """线段 C→P（ENU）是否穿过车体盒子（车体系 slab 求交）：返回每条线段的布尔。C 可以是一点或每条一个。
    与分辨率无关——长焦帧里车体代理点溅射到 z-buffer 会漏（2 cm 一点在画面上隔几十像素），甲板和轮子被印到地上。"""
    Rb = rover_R()
    to_b = lambda q: (np.atleast_2d(q) @ M_SB @ Rb)*np.array([1, 1, -1.0])   # ENU → 车体系（z 改成朝上）
    P_enu = np.atleast_2d(P_enu); C_enu = np.broadcast_to(np.atleast_2d(C_enu), P_enu.shape)
    hit = np.zeros(len(P_enu), bool)
    dc = P_enu - C_enu; t = np.clip(((np.array([0.0, 0.0, 0.9]) - C_enu)*dc).sum(1)/np.maximum((dc*dc).sum(1), 1e-12), 0, 1)
    near_ = np.linalg.norm(C_enu + t[:, None]*dc - np.array([0.0, 0.0, 0.9]), axis=1) < 3.2   # 离车远的线段不用算
    if not near_.any(): return hit
    c = to_b(C_enu[near_]); d = to_b(P_enu[near_]) - c
    h_ = np.zeros(len(d), bool)
    for (xa, xb), (ya, yb), (za, zb) in ROVER_BOXES_TIGHT:
        lo = (np.array([xa, ya, za]) - c)/np.where(np.abs(d) < 1e-9, 1e-9, d); hi = (np.array([xb, yb, zb]) - c)/np.where(np.abs(d) < 1e-9, 1e-9, d)
        tmin = np.minimum(lo, hi).max(1); tmax = np.maximum(lo, hi).min(1)
        h_ |= (tmax >= np.maximum(tmin, 0.0)) & (tmin <= 1.0)
    hit[near_] = h_
    return hit


def frame_sees_rover(z, G, gi):
    """这帧里哪些格的视线穿过车体（从相机外 0.35 m 起算，相机在桅杆头里）。"""
    c = grid_xy(G.cs, G.n); P = np.stack([c[gi % G.n], c[gi//G.n], G.Z.ravel()[gi]], 1)
    C = to_enu(z["cam"]["C"][None])[0]; u = P - C; u /= np.linalg.norm(u, axis=1, keepdims=True)
    return rays_hit_rover(C + 0.35*u, P)


def under_rover(x, y, margin=0.0):
    """ENU 平面点是否在车身投影下（车体系 x −1.8…2.45、|y| < 1.4），可再往外扩 margin 米。"""
    q = (np.stack([x, y, np.zeros_like(x)], -1) @ M_SB) @ rover_R()
    return (q[..., 0] > -1.8 - margin) & (q[..., 0] < 2.45 + margin) & (np.abs(q[..., 1]) < 1.4 + margin)


def fabricate_zone(x, y):
    """反照率整块重新合成的格：车身外沿（虚构区.json 车身外沿_m）＋ 手标多边形（机械臂残影等）。没有文件时只有车底。"""
    from matplotlib.path import Path as MPath
    f = DIR/"虚构区.json"
    if not f.exists(): return under_rover(x, y)
    J = json.loads(f.read_text()); m = under_rover(x, y, J.get("车身外沿_m", 0.0))
    P = np.stack([x.ravel(), y.ravel()], 1)
    for z in J["区域"]: m |= MPath(np.asarray(z["多边形"])).contains_points(P).reshape(x.shape)
    return m


def albedo():
    from PIL import Image
    from scipy.ndimage import zoom, gaussian_filter
    Image.MAX_IMAGE_PIXELS = None
    T = np.load(OUT/"地形.npz"); L = json.loads(str(T["levels"]))
    near, mid = T["near"], T["mid"]; (csn, nn), (csm, nm) = L["近"], L["中"]
    cams = [c for c in json.loads((OUT/"相机.json").read_text()) if c["err_90"] <= 8 and "sun_all" in c]
    log(f"相机 {len(cams)} 台")
    # 遮挡用的地形点：近层 + 中层（近层范围外），站点系
    def grid_pts(Z, cs, n, step=1, hole=None):
        c = grid_xy(cs, n)[::step]; X, Y = np.meshgrid(c, c); z = Z[::step, ::step]
        m = np.ones(X.shape, bool) if hole is None else ~((np.abs(X) < hole) & (np.abs(Y) < hole))
        return enu_to_site(np.stack([X[m], Y[m], z[m]], 1))
    occ_pts = np.concatenate([grid_pts(near, csn, nn), grid_pts(mid, csm, nm, hole=csn*nn/2),
                              enu_to_site(rover_proxy())]).astype(np.float64)    # 车体代理也挡视线
    def height(x, y):
        h = sample(mid, csm, nm, x, y, order=3)
        inn = (np.abs(x) < csn*nn/2 - csn) & (np.abs(y) < csn*nn/2 - csn)
        h[inn] = sample(near, csn, nn, x[inn], y[inn], order=3); return h
    for lv, (cs, n) in ALB.items():
        t0 = time.time()
        c = grid_xy(cs, n); X, Y = np.meshgrid(c, c)
        Z = height(X.ravel(), Y.ravel()).reshape(n, n).astype(np.float32); del X, Y
        Nrm = normals(gaussian_filter(Z, 1.0), cs)
        Zs = zoom(Z, 0.25, order=1) if lv == "近" else Z                   # 天空可见度在粗一点的格上算
        K = sky_view(Zs, cs*(4 if lv == "近" else 1), 6.0)
        K = zoom(K, (n/K.shape[0], n/K.shape[1]), order=1) if K.shape != Z.shape else K
        sun_cache = {}
        cells, camid, Ls, Ws, Ss = [], [], [], [], []
        for ci, cam in enumerate(cams):
            img_p = PDS/cam["dir"]/cam["file"].replace(".obj", ".png")
            img = np.asarray(Image.open(img_p).convert("RGB")); Hh, Ww = img.shape[:2]
            own = to_enu(obj_vertices(PDS/cam["dir"]/cam["file"]))      # 该相机自己的网格（含机械臂）
            zb, k = zbuffer(cam, np.concatenate([occ_pts, enu_to_site(own)]), Ww, Hh)
            sa = cam["sun_all"][-1]; key = (round(sa[0]), round(sa[1]))   # 最后一组＝站点系
            if key not in sun_cache:
                s = sun_enu(*sa)
                sun_cache[key] = (np.maximum(Nrm @ s, 0)*shadow(Z, cs, s, 4.0)).astype(np.float32)
            S = sun_cache[key]
            for r0 in range(0, n, 250):                                    # 分条投影
                cc = grid_xy(cs, n); Xr, Yr = np.meshgrid(cc, cc[r0:r0 + 250])
                b = np.stack([Xr.ravel(), Yr.ravel(), Z[r0:r0 + 250].ravel()], 1)
                u, v, rr, rn, zc = project_pts(cam, enu_to_site(b))
                ok = (zc > 0.05) & (rn < 0.97) & (u >= 1) & (v >= 1) & (u < Ww - 2) & (v < Hh - 2) & (rr < (12 if lv == "近" else 60))
                if not ok.any(): continue
                idx = np.flatnonzero(ok)
                # 容差随 r² 长：1/k 分辨率一个像素在掠射的地面上沿视线跨 k·r²/(f·h)（h≈2 m），再乘 3×3 取最小
                tol = 0.03 + 0.01*rr[idx] + 1.5*k*rr[idx]**2/(cam["f"]*2.0)
                ok2 = rr[idx] <= zb[(v[idx]/k).astype(int), (u[idx]/k).astype(int)] + tol
                idx = idx[ok2]
                if not idx.size: continue
                i0 = np.floor(v[idx]).astype(int); j0 = np.floor(u[idx]).astype(int); fy = (v[idx] - i0)[:, None]; fx = (u[idx] - j0)[:, None]
                col = (img[i0, j0]*(1 - fy)*(1 - fx) + img[i0 + 1, j0]*fy*(1 - fx) + img[i0, j0 + 1]*(1 - fy)*fx + img[i0 + 1, j0 + 1]*fy*fx)/255.0
                dark = col.max(1) < 0.02                                   # 照片黑角
                lin = np.where(col <= 0.04045, col/12.92, ((col + 0.055)/1.055)**2.4)
                gidx = r0*n + idx
                vdir = enu_to_site(b[idx]) - np.array(cam["C"]); vdir /= np.linalg.norm(vdir, axis=1, keepdims=True)
                cosv = -np.einsum("ij,ij->i", Nrm.reshape(-1, 3)[gidx], vdir @ M_SB.T)   # 视线与法线夹角
                w = (cam["f"]/rr[idx])**2*np.clip((cosv - 0.02)/0.1, 0, 1)*np.clip((0.97 - rn[idx])/0.1, 0, 1)
                w[dark | under_rover(b[idx, 0], b[idx, 1])] = 0                 # 黑角；车底（照片里是车身）
                keep = w > 0
                cells.append(gidx[keep].astype(np.int32)); camid.append(np.full(keep.sum(), ci, np.int16))
                Ls.append(lin[keep].astype(np.float32)); Ws.append(w[keep].astype(np.float32)); Ss.append(S.ravel()[gidx[keep]])
            log(f"  {lv} ← {cam['file'][:30]}（{sum(map(len, cells)):,} 样本）")
        cell = np.concatenate(cells); cid = np.concatenate(camid); Lm = np.concatenate(Ls); w = np.concatenate(Ws); Sv = np.concatenate(Ss)
        Kv = K.ravel()[cell]; nc = len(cams)
        del cells, camid, Ls, Ws, Ss
        # 交替求解：L = g_c·A·(S + β·K)，每通道；g_c＝每台相机的增益，β＝天光/日光（全局，近层解、中层沿用）；Huber 重加权
        g = np.ones((nc, 3), np.float32); A = np.zeros((n*n, 3), np.float32)
        if lv == "近": beta = np.full(3, 0.5, np.float32)
        wr = w.copy(); cnt = np.bincount(cid, minlength=nc).astype(np.float64)
        for it in range(8):
            for ch in range(3):
                sh = Sv + beta[ch]*Kv; gs = g[cid, ch]*sh
                A[:, ch] = np.bincount(cell, wr*Lm[:, ch]*gs, n*n)/np.maximum(np.bincount(cell, wr*gs*gs, n*n), 1e-12)
                As = A[cell, ch]*sh
                g[:, ch] = np.bincount(cid, wr*Lm[:, ch]*As, nc)/np.maximum(np.bincount(cid, wr*As*As, nc), 1e-12)
                g[cnt > 0, ch] /= np.average(g[cnt > 0, ch], weights=cnt[cnt > 0])   # 规范：相机增益平均为 1（保留照片色平衡）
                if lv == "近":
                    gA = g[cid, ch]*A[cell, ch]; q = gA*Kv
                    beta[ch] = np.clip(np.sum(wr*q*(Lm[:, ch] - gA*Sv))/max(np.sum(wr*q*q), 1e-12), 0.05, 5)
            res = np.abs(Lm - g[cid]*A[cell]*(Sv[:, None] + beta*Kv[:, None])).mean(1)/np.maximum(Lm.mean(1), 1e-3)
            wr = w*np.minimum(1, 0.15/np.maximum(res, 1e-6))                 # 相对误差 > 15% 的降权（影子边、机械臂残留）
        a, bsky = g, g*beta
        cov = np.bincount(cell, w, n*n).reshape(n, n)
        A = A.reshape(n, n, 3)
        if lv == "近":
            scale = ALB_MED_R/np.median(A[cov > 0, 0])
        A *= scale
        np.savez_compressed(OUT/f"反照率_{lv}.npz", A=A.astype(np.float16), cov=cov.astype(np.float32), cs=cs, n=n,
                            a=a/scale, b=bsky/scale, cams=[c["file"] for c in cams])
        log(f"反照率 {lv}：{n}² × {cs} m，有覆盖 {np.mean(cov > 0)*100:.0f}%，中位 RGB {np.round(np.median(A[cov > 0], 0), 3)}，"
            f"日光/天光比 中位 {np.median(a/bsky):.2f}（{time.time() - t0:.0f} s）")


# ── ⑥ Mastcam-Z（科学标定 IOF，CAHVOR）──────────────────────────────────
ZDIR = DIR/"mastcamz"


def quat_R(qc, q1, q2, q3):
    """PDS Quaternion_Plus_Direction（Forward）→ 旋转阵：v_参考 = R v_本系。"""
    w, x, y, z = qc, q1, q2, q3
    return np.array([[1 - 2*(y*y + z*z), 2*(x*y - w*z), 2*(x*z + w*y)],
                     [2*(x*y + w*z), 1 - 2*(x*x + z*z), 2*(y*z - w*x)],
                     [2*(x*z - w*y), 2*(y*z + w*x), 1 - 2*(x*x + y*y)]])


def read_z(xml):
    """Mastcam-Z IOF 标签 + 图 → dict(img=(h, w, 3) IOF（2×2 合并去 Bayer）, cam=CAHVOR（站点系）, sun, ltst, sol, focal)。"""
    x = xml.read_text()
    arr = x[x.index("<Array_2D_Image>"):] if "<Array_2D_Image>" in x else x[x.index("<Array_3D_Image>"):]
    off = int(re.search(r'<offset unit="byte">(\d+)', arr).group(1))
    n = [int(v) for v in re.findall(r"<elements>(\d+)</elements>", arr)]
    if len(n) != 2 or "Bayer" not in x: return None                       # 只要 Bayer 编码的 RGB 全幅
    sc = float(re.search(r"<scaling_factor>([-\d.eE+]+)", arr).group(1))
    vo = float(re.search(r"<value_offset>([-\d.eE+]+)", arr).group(1)) if "<value_offset>" in arr else 0.0
    raw = np.fromfile(xml.with_suffix(".IMG"), ">i2", offset=off, count=n[0]*n[1]).reshape(n).astype(np.float32)
    bad = raw == 0
    raw = raw*sc + vo; raw[bad] = np.nan
    h2, w2 = n[0]//2*2, n[1]//2*2; r = raw[:h2, :w2]
    rgb = np.stack([r[0::2, 0::2], 0.5*(r[0::2, 1::2] + r[1::2, 0::2]), r[1::2, 1::2]], -1)   # RGGB
    fl = int(re.search(r"<img:first_line>(\d+)", x).group(1)); fs = int(re.search(r"<img:first_sample>(\d+)", x).group(1))
    cb = x[x.index("<geom:CAHVOR_Model>"):x.index("</geom:CAHVOR_Model>")]
    vec = lambda tag, k: np.array([float(v) for v in re.findall(rf'<geom:[xyz]_{k}[^>]*>([-\d.eE+]+)<', cb[cb.index(tag):])[:3]])
    C, A, H, V, O = vec("Vector_Center", "position"), vec("Vector_Axis", "unit"), vec("Vector_Horizontal", "pixel"), \
        vec("Vector_Vertical", "pixel"), vec("Vector_Optical", "unit")
    Rr = [float(v) for v in re.findall(r"<geom:c[012]>([-\d.eE+]+)<", cb)]
    # 车体系 → 站点系：标签里 ROVER_NAV_FRAME 的定义（原点在站点系、四元数）
    m = re.search(r"<local_identifier>ROVER_NAV_FRAME[^<]*</local_identifier>(.*?)</geom:Coordinate_Space_Definition>", x, re.S).group(1)
    org = np.array([float(v) for v in re.findall(r'<geom:[xyz]_position unit="m">([-\d.eE+]+)<', m)[:3]])
    q = [float(re.search(rf"<geom:{k}>([-\d.eE+]+)<", m).group(1)) for k in ("qcos", "qsin1", "qsin2", "qsin3")]
    Rq = quat_R(*q)
    cam = dict(C=Rq @ C + org, A=Rq @ A, H=Rq @ H, V=Rq @ V, O=Rq @ O, R=Rr, fl=fl - 1, fs=fs - 1)
    az = float(re.search(r'<geom:solar_azimuth unit="deg">([-\d.]+)', x).group(1))
    el = float(re.search(r'<geom:solar_elevation unit="deg">([-\d.]+)', x).group(1))
    lt = re.search(r"<local_true_solar_time>([\d:]+)", x).group(1)
    sol = int(re.search(r"<msn:start_local_true_solar_time_sol>(\d+)", x).group(1)) if "start_local_true_solar_time_sol" in x else 0
    return dict(img=rgb, cam=cam, sun=(az, el), ltst=lt, sol=sol, focal=float(re.search(r'<img:focal_length unit="mm">([\d.]+)', x).group(1)),
                name=xml.stem)


def cahvor(cam, P):
    """站点系的点 → 全幅像素 (sample, line)（像素中心＝整数）、沿光轴距离。"""
    p = P - cam["C"]; lam = p @ cam["O"]
    rho = p - lam[:, None]*cam["O"]; tau = np.sum(rho*rho, 1)/np.maximum(lam*lam, 1e-12)
    mu = cam["R"][0] + cam["R"][1]*tau + cam["R"][2]*tau*tau
    pp = p + mu[:, None]*rho
    den = pp @ cam["A"]
    return (pp @ cam["H"])/den, (pp @ cam["V"])/den, den


ZALB = {"近": (0.01, 2000), "中": (0.02, 5000)}                           # Mastcam-Z 反照率格：1 cm ±10 m、2 cm ±50 m


class Ground:
    """反照率格的几何：每格高度、法线、天空可见度、站点系坐标；阴影按太阳缓存。"""
    def __init__(self, cs, n):
        from scipy.ndimage import gaussian_filter, zoom
        T = np.load(OUT/"地形.npz"); L = json.loads(str(T["levels"]))
        (csn, nn), (csm, nm) = L["近"], L["中"]; near = near_filled(); mid = T["mid"]
        c = grid_xy(cs, n); X, Y = np.meshgrid(c, c)
        Z = sample(mid, csm, nm, X.ravel(), Y.ravel(), order=3)
        inn = (np.abs(X.ravel()) < csn*nn/2 - csn) & (np.abs(Y.ravel()) < csn*nn/2 - csn)
        Z[inn] = sample(near, csn, nn, X.ravel()[inn], Y.ravel()[inn], order=3)
        self.cs, self.n = cs, n; self.Z = Z.reshape(n, n).astype(np.float32); del X, Y
        self.N = normals(gaussian_filter(self.Z, 1.0), cs).astype(np.float32)
        k = max(1, int(round(0.04/cs)))
        Zs = self.Z[::k, ::k]; K = sky_view(Zs, cs*k, 6.0)
        self.K = zoom(K, (n/K.shape[0], n/K.shape[1]), order=1).astype(np.float32)
        self.sh = {}
        self.under = under_rover(*np.meshgrid(c, c)).ravel()
        B = self.B = max(1, int(round(1.0/cs))); nb = self.nb = n//B           # 1 m 一块，视锥剔除用
        cb = (np.arange(nb)*B + B/2 - n/2)*cs; BX, BY = np.meshgrid(cb, cb)
        BZ = self.Z[:nb*B, :nb*B].reshape(nb, B, nb, B).mean((1, 3))
        self.bc = enu_to_site(np.stack([BX.ravel(), BY.ravel(), BZ.ravel()], 1)); self.br = B*cs*0.75

    def site_idx(self, idx):
        c = grid_xy(self.cs, self.n)
        return enu_to_site(np.stack([c[idx % self.n], c[idx//self.n], self.Z.ravel()[idx]], 1))

    def cells_of_blocks(self, blocks):
        B, nb, n = self.B, self.nb, self.n
        bi, bj = blocks//nb, blocks % nb
        o = np.arange(B)
        rows = (bi[:, None, None]*B + o[None, :, None]); cols = (bj[:, None, None]*B + o[None, None, :])
        return (rows*n + cols).ravel()

    def site(self, rows):
        """第 rows 行的格心 → 站点系 (m, 3)。"""
        c = grid_xy(self.cs, self.n); X, Y = np.meshgrid(c, c[rows])
        return enu_to_site(np.stack([X.ravel(), Y.ravel(), self.Z[rows].ravel()], 1))

    def shade(self, sun):
        key = (round(sun[0]), round(sun[1]))
        if key not in self.sh:
            s = sun_enu(*key)
            self.sh[key] = (np.maximum(self.N @ s, 0)*shadow(self.Z, self.cs, s, 4.0)*255 + 0.5).astype(np.uint8)
        return self.sh[key]


def z_frames():
    """全部 Mastcam-Z 帧：读进来（2×2 合并），去掉非 Bayer 的。"""
    for x in sorted(ZDIR.glob("Z*.xml")):
        try: z = read_z(x)
        except Exception as e: log(f"  {x.name[:30]} 读不了：{e}"); continue
        if z is not None: yield z


def z_project(z, G, shift=(0.0, 0.0)):
    """把格投进这帧（先按 1 m 块剔视锥）：返回 (格索引, 合并后像素 x, y, 距离, 一格的像素足迹)，只含画面内、在前方的。"""
    cam = z["cam"]; h, w = z["img"].shape[:2]
    fpx = np.linalg.norm(cam["H"] - (cam["H"] @ cam["A"])*cam["A"])/2      # 合并后的焦距（像素）
    x, y, d = cahvor(cam, G.bc)
    bx = (x - cam["fs"] - 0.5)/2 + shift[0]; by = (y - cam["fl"] - 0.5)/2 + shift[1]
    rb = np.linalg.norm(G.bc - cam["C"], axis=1); mg = G.br*fpx/np.maximum(rb, 0.3) + 4
    keep = np.flatnonzero((d > 0.3) & (bx > -mg) & (by > -mg) & (bx < w + mg) & (by < h + mg))
    if not keep.size: return (np.zeros(0, np.int64),) + (np.zeros(0),)*4
    idx = G.cells_of_blocks(keep); P = G.site_idx(idx)
    x, y, d = cahvor(cam, P)
    bx = (x - cam["fs"] - 0.5)/2 + shift[0]; by = (y - cam["fl"] - 0.5)/2 + shift[1]
    ok = (d > 0.5) & (bx >= 1) & (by >= 1) & (bx < w - 2) & (by < h - 2)
    idx, P, bx, by = idx[ok], P[ok], bx[ok], by[ok]
    rr = np.linalg.norm(P - cam["C"], axis=1)
    return idx, bx, by, rr, G.cs*fpx/rr


def mastcam_albedo(limit=None):
    """两遍：① 逐帧配准（预测图 vs 实拍，带掩膜 NCC）+ 增益 + 剔车体特写；② 按光照模型把 IOF 累积到反照率格。"""
    from skimage.registration import phase_cross_correlation
    from scipy.ndimage import gaussian_filter
    t0 = time.time()
    nav = {lv: np.load(OUT/f"反照率_{lv}.npz") for lv in ("近", "中")}
    beta = float(np.median((nav["近"]["b"]/np.maximum(nav["近"]["a"], 1e-9))[np.isfinite(nav["近"]["b"]/np.maximum(nav["近"]["a"], 1e-9))]))
    G = Ground(*ZALB["中"]); log(f"中层格 {G.n}²×{G.cs} m 就绪（{time.time() - t0:.0f} s），β = {beta:.2f}")
    # 参考反照率（Navcam）插到中层格上（亮度），覆盖外为 nan
    c = grid_xy(G.cs, G.n); X, Y = np.meshgrid(c, c)
    ref = np.full(G.n*G.n, np.nan, np.float32)
    for lv in ("中", "近"):
        A = nav[lv]["A"].astype(np.float32).mean(-1); cov = nav[lv]["cov"]; cs, n = float(nav[lv]["cs"]), int(nav[lv]["n"])
        m = (np.abs(X.ravel()) < cs*n/2 - cs) & (np.abs(Y.ravel()) < cs*n/2 - cs)
        a = sample(np.where(cov > 0, A, np.nan), cs, n, X.ravel()[m], Y.ravel()[m], order=0)
        ref[m] = np.where(np.isfinite(a), a, ref[m])
    del X, Y
    proxy = enu_to_site(rover_proxy())
    # ── 第一遍：配准 + 增益
    meta = {}
    mp = OUT/"mastcam_配准.json"
    cached = not limit and mp.exists() and json.loads(mp.read_text()).get("_全量")   # 全量第一遍跑过就直接用（重跑删掉这个文件）
    if cached: meta = json.loads(mp.read_text()); del meta["_全量"]; log(f"① 用已有配准 {len(meta)} 帧")
    for fi, z in enumerate(() if cached else z_frames()):
        if limit and fi >= limit: break
        h, w = z["img"].shape[:2]; lum = np.nanmean(z["img"], -1)
        # 遮挡：格 + 车体代理溅到 1/2 分辨率
        k = 2; Wk, Hk = w//k + 1, h//k + 1; zb = np.full(Wk*Hk, np.inf, np.float32)
        hits = []
        gi, bx, by, rr, fp = z_project(z, G)
        if gi.size:
            np.minimum.at(zb, (by/k).astype(np.int32)*Wk + (bx/k).astype(np.int32), rr.astype(np.float32)); hits.append((gi, bx, by, rr, fp))
        px, py, pd = cahvor(z["cam"], proxy); pbx = (px - z["cam"]["fs"] - 0.5)/2; pby = (py - z["cam"]["fl"] - 0.5)/2
        okp = (pd > 0.05) & (pbx >= 0) & (pby >= 0) & (pbx < w - 1) & (pby < h - 1)
        np.minimum.at(zb, (pby[okp]/k).astype(np.int32)*Wk + (pbx[okp]/k).astype(np.int32), np.linalg.norm(proxy[okp] - z["cam"]["C"], axis=1).astype(np.float32))
        from scipy.ndimage import minimum_filter
        zb = minimum_filter(zb.reshape(Hk, Wk), 3)
        if not hits: meta[z["name"]] = dict(ok=False, why="不在格内"); continue
        gi = np.concatenate([a[0] for a in hits]); bx = np.concatenate([a[1] for a in hits]); by = np.concatenate([a[2] for a in hits]); rr = np.concatenate([a[3] for a in hits])
        vis = rr <= zb[(by/k).astype(int), (bx/k).astype(int)] + 0.02 + 0.01*rr
        vis &= ~frame_sees_rover(z, G, gi)
        fpv = np.concatenate([a[4] for a in hits])[vis] if len(hits[0]) > 4 else None
        gi, bx, by, rr = gi[vis], bx[vis], by[vis], rr[vis]
        if gi.size < 60: meta[z["name"]] = dict(ok=False, why="可见地面太少（车体特写/天空）"); continue
        sh = G.shade(z["sun"]).ravel()[gi].astype(np.float32)/255 + beta*G.K.ravel()[gi]
        pred = ref[gi]*sh
        # 预测图与实拍对比 → 平移；配准分辨率按格的像素足迹选（一格≈一像素，近距特写一格跨几十像素）
        k = int(np.clip(round(float(np.median(fpv))), 2, 32)) if fpv is not None else 2
        Wk, Hk = w//k + 1, h//k + 1
        P_img = np.zeros(Hk*Wk, np.float32); P_cnt = np.zeros(Hk*Wk, np.float32)
        okp = np.isfinite(pred); ii = (by[okp]/k).astype(np.int32)*Wk + (bx[okp]/k).astype(np.int32)
        np.add.at(P_img, ii, pred[okp]); np.add.at(P_cnt, ii, 1)
        P_img = (P_img/np.maximum(P_cnt, 1)).reshape(Hk, Wk); Pm = (P_cnt > 0).reshape(Hk, Wk)
        hh, ww = h//k*k, w//k*k
        I_img = np.nan_to_num(lum)[:hh, :ww].reshape(h//k, k, w//k, k).mean((1, 3)); Im = np.isfinite(lum)[:hh, :ww].reshape(h//k, k, w//k, k).all((1, 3))
        I_img = np.pad(I_img, ((0, Hk - I_img.shape[0]), (0, Wk - I_img.shape[1]))); Im = np.pad(Im, ((0, Hk - Im.shape[0]), (0, Wk - Im.shape[1])))
        if Pm.sum() < 60:
            meta[z["name"]] = dict(ok=True, shift=(0.0, 0.0), g=None, ncc=None, sun=z["sun"], seq=z["name"][27:36]); continue
        hp = lambda a, m: np.where(m, a - gaussian_filter(np.where(m, a, a[m].mean()), 4), 0)   # 去低频（照度不均）
        sft = phase_cross_correlation(hp(I_img, Im), hp(P_img, Pm), reference_mask=Im, moving_mask=Pm, overlap_ratio=0.3)
        sft = np.asarray(sft[0] if isinstance(sft, tuple) else sft, float)
        dy, dx = -sft[0]*k, -sft[1]*k                                        # 合并像素
        # 平移后的 NCC 和增益
        sx = np.clip(bx + dx, 0, w - 1.001); sy = np.clip(by + dy, 0, h - 1.001)
        obs = lum[sy.astype(int), sx.astype(int)]
        m = np.isfinite(obs) & np.isfinite(pred) & (pred > 0)
        ncc = float(np.corrcoef(obs[m], pred[m])[0, 1]) if m.sum() > 50 else None
        g = float(np.median(obs[m]/pred[m])) if m.sum() > 50 else None
        meta[z["name"]] = dict(ok=True, shift=(dx, dy), g=g, ncc=ncc, sun=z["sun"], seq=z["name"][27:36], n=int(gi.size))
        if fi % 50 == 0: log(f"  ① {fi}：{z['name'][:30]} 平移 ({dx:+.0f}, {dy:+.0f}) 像素，NCC {ncc if ncc is None else round(ncc, 2)}，增益 {g if g is None else round(g, 3)}（{time.time() - t0:.0f} s）")
    # 增益：NCC 低的不信，按序列中位补
    seqg = {}
    for k_, v in meta.items():
        if v.get("ok") and v.get("g") and (v.get("ncc") or 0) > 0.4: seqg.setdefault(v["seq"], []).append(v["g"])
    allg = float(np.median([g for gs in seqg.values() for g in gs])) if seqg else 1.0
    for v in meta.values():
        if not v.get("ok"): continue
        nc = v.get("ncc"); nc = None if nc is None or not np.isfinite(nc) else nc   # NaN 跟什么比都是 False：原来 NaN 帧带着几百像素的假平移进了累加
        if not (v.get("g") and (nc or 0) > 0.4): v["g"] = float(np.median(seqg.get(v["seq"], [allg])))
        if nc is None or nc < 0.2 or (max(abs(v["shift"][0]), abs(v["shift"][1])) > 40 and nc < 0.5): v["shift"] = (0.0, 0.0)
    if not cached: mp.write_text(json.dumps(dict(meta, _全量=not limit), indent=1, default=float))
    good = sum(1 for v in meta.values() if v.get("ok"))
    log(f"① 配准完：{good}/{len(meta)} 帧可用（{time.time() - t0:.0f} s）")
    # ── 第二遍：累积（中层 2 cm；近层 1 cm 另建格）
    for lv in ("中", "近"):
        if lv == "近": G = Ground(*ZALB["近"])
        S1 = np.zeros((G.n*G.n, 3), np.float32); S0 = np.zeros(G.n*G.n, np.float32)
        # Navcam 反照率（干净、低频可信）重采到本格并模糊 10 cm：拿来检验每帧 Mastcam 的颜色。
        # 有些帧（拍校准靶/甲板的）整张被投到几米外的地面上，NCC 普遍偏低（中位 0.13）筛不掉，颜色一比就露馅
        from scipy.ndimage import gaussian_filter
        nv_ = nav[lv]; An_ = nv_["A"].astype(np.float32); csn_, nn_ = float(nv_["cs"]), int(nv_["n"])
        cg = grid_xy(G.cs, G.n); NREF = np.empty((G.n*G.n, 3), np.float32)
        for ch in range(3):
            g_ = gaussian_filter(np.where(nv_["cov"] > 0, An_[..., ch], 0), 0.1/csn_)/np.maximum(gaussian_filter((nv_["cov"] > 0).astype(np.float32), 0.1/csn_), 1e-3)
            for r0 in range(0, G.n, 500):                                  # 分块，省内存
                Xr, Yr = np.meshgrid(cg, cg[r0:r0 + 500])
                NREF[r0*G.n:(r0 + Xr.shape[0])*G.n, ch] = sample(g_, csn_, nn_, Xr.ravel(), Yr.ravel())
        hasref = sample((gaussian_filter((nv_["cov"] > 0).astype(np.float32), 0.1/csn_) > 0.5).astype(np.float32), csn_, nn_, *[a.ravel() for a in np.meshgrid(cg, cg)]) > 0.5
        nbad = 0
        for fi, z in enumerate(z_frames()):
            if limit and fi >= limit: break
            v = meta.get(z["name"])
            if not v or not v.get("ok"): continue
            h, w = z["img"].shape[:2]
            pyr = [z["img"]]
            for _ in range(3):
                a = pyr[-1]; a = np.nan_to_num(a)[:a.shape[0]//2*2, :a.shape[1]//2*2]
                pyr.append(a.reshape(a.shape[0]//2, 2, a.shape[1]//2, 2, 3).mean((1, 3)))
            k = 2; Wk, Hk = w//k + 1, h//k + 1; zb = np.full(Wk*Hk, np.inf, np.float32); hits = []
            gi, bx, by, rr, fp = z_project(z, G, shift=v["shift"])
            if gi.size:
                np.minimum.at(zb, (by/k).astype(np.int32)*Wk + (bx/k).astype(np.int32), rr.astype(np.float32)); hits.append((gi, bx, by, rr, fp))
            if not hits: continue
            px, py, pd = cahvor(z["cam"], proxy); pbx = (px - z["cam"]["fs"] - 0.5)/2 + v["shift"][0]; pby = (py - z["cam"]["fl"] - 0.5)/2 + v["shift"][1]
            okp = (pd > 0.05) & (pbx >= 0) & (pby >= 0) & (pbx < w - 1) & (pby < h - 1)
            np.minimum.at(zb, (pby[okp]/k).astype(np.int32)*Wk + (pbx[okp]/k).astype(np.int32), np.linalg.norm(proxy[okp] - z["cam"]["C"], axis=1).astype(np.float32))
            from scipy.ndimage import minimum_filter
            zb = minimum_filter(zb.reshape(Hk, Wk), 3)
            gi, bx, by, rr, fp = (np.concatenate([a[j] for a in hits]) for j in range(5))
            vis = (rr <= zb[(by/k).astype(int), (bx/k).astype(int)] + 0.02 + 0.01*rr) & ~G.under[gi]
            vis[vis] &= ~frame_sees_rover(z, G, gi[vis])
            gi, bx, by, rr, fp = gi[vis], bx[vis], by[vis], rr[vis], fp[vis]
            direct = G.shade(z["sun"]).ravel()[gi].astype(np.float32)/255
            sh = direct + beta*G.K.ravel()[gi]
            lvl = np.clip(np.floor(np.log2(np.maximum(fp, 1))), 0, 3).astype(int)   # 一格跨 2^L 个像素 → 取第 L 层（先平均再采，防混叠）
            col = np.zeros((gi.size, 3), np.float32)
            for L in range(4):
                m = lvl == L
                if not m.any(): continue
                a = pyr[L]; xx = np.clip((bx[m] + 0.5)/2**L - 0.5, 0, a.shape[1] - 1.001); yy = np.clip((by[m] + 0.5)/2**L - 0.5, 0, a.shape[0] - 1.001)
                i0 = yy.astype(int); j0 = xx.astype(int); fy = (yy - i0)[:, None]; fx = (xx - j0)[:, None]
                col[m] = a[i0, j0]*(1 - fy)*(1 - fx) + a[i0 + 1, j0]*fy*(1 - fx) + a[i0, j0 + 1]*(1 - fy)*fx + a[i0 + 1, j0 + 1]*fy*fx
            good_ = np.isfinite(col).all(1) & (col.min(1) > 0) & (sh > 0.05)
            alb = col/(v["g"]*sh[:, None])
            wgt = np.minimum(fp, 1.0)**2*(0.03 + 0.97*np.clip(direct/0.3, 0, 1))*(1.0 if (v.get("ncc") or 0) > 0.4 else 0.3)
            # 分辨率够、有直射光、配准可信的权重高；阴影里只有天光（颜色和强度都难算准，会出偏蓝灰的块），几乎不用
            m = good_ & (alb.max(1) < 1.2)
            ref = NREF[gi]; hr = hasref[gi] & (ref.min(1) > 1e-4)
            lr = np.log(np.maximum(alb.mean(1), 1e-4)/np.maximum(ref.mean(1), 1e-4))
            chd = np.abs(alb/np.maximum(alb.sum(1, keepdims=True), 1e-6) - ref/np.maximum(ref.sum(1, keepdims=True), 1e-6)).max(1)
            sel = m & hr
            if sel.sum() > 200 and np.mean((np.abs(lr[sel]) < 0.7) & (chd[sel] < 0.05)) < 0.5:   # 整帧对不上 Navcam：丢
                nbad += 1; continue
            m &= ~hr | ((np.abs(lr) < 1.0) & (chd < 0.08))                 # 单个样本差太远（亮度 ×2.7、色度 0.08）：剔
            np.add.at(S0, gi[m], wgt[m]); np.add.at(S1, gi[m], alb[m]*wgt[m, None])
            if fi % 100 == 0: log(f"  ② {lv} {fi}：{z['name'][:30]}（{time.time() - t0:.0f} s）")
        log(f"  ② {lv}：{nbad} 帧颜色与 Navcam 不符，整帧丢弃")
        A = (S1/np.maximum(S0, 1e-12)[:, None]).reshape(G.n, G.n, 3)
        cov = S0.reshape(G.n, G.n)
        # 定标：与 Navcam 反照率的重叠处对齐（每通道），保持全站一个绝对尺度
        nv = nav[lv]; An = nv["A"].astype(np.float32); csn_, nn_ = float(nv["cs"]), int(nv["n"])
        c = grid_xy(G.cs, G.n); X, Y = np.meshgrid(c, c)
        m = (cov.ravel() > 0) & (np.abs(X.ravel()) < csn_*nn_/2) & (np.abs(Y.ravel()) < csn_*nn_/2)
        a_n = np.stack([sample(An[..., ch], csn_, nn_, X.ravel()[m], Y.ravel()[m], order=1) for ch in range(3)], -1)
        okn = sample(nv["cov"], csn_, nn_, X.ravel()[m], Y.ravel()[m], order=0) > 0
        scale = np.median(a_n[okn]/np.maximum(A.reshape(-1, 3)[m][okn], 1e-6), 0) if okn.sum() > 1000 else np.ones(3)
        if lv == "中": z_scale = scale
        A *= z_scale if lv == "近" else scale
        np.savez_compressed(OUT/f"反照率Z_{lv}.npz", A=A.astype(np.float16), cov=cov.astype(np.float32), cs=G.cs, n=G.n, scale=scale)
        log(f"反照率Z {lv}：{G.n}²×{G.cs} m，有覆盖 {np.mean(cov > 0)*100:.0f}%，对 Navcam 定标 {np.round(scale, 2)}（{time.time() - t0:.0f} s）")


# ── ⑦ 自动地类（数据驱动分类 → 向外推到 HiRISE）─────────────────────────────
CLASSES = ("沙", "砾石风化层", "基岩", "暗色岩块")


def kmeans(X, k, iters=30, seed=0):
    rng = np.random.default_rng(seed); C = X[rng.choice(len(X), k, replace=False)]
    for _ in range(iters):
        d = ((X[:, None, :] - C[None])**2).sum(-1); lab = d.argmin(1)
        C = np.array([X[lab == j].mean(0) if (lab == j).any() else C[j] for j in range(k)])
    return C, lab


def best_albedo(lv):
    """近/中层最终反照率：Mastcam-Z（有就优先，按覆盖羽化）＋ Navcam 打底。返回 (A, 有数据, cs, n)。"""
    from scipy.ndimage import gaussian_filter
    nv = np.load(OUT/f"反照率_{lv}.npz"); cs_n, n_n = float(nv["cs"]), int(nv["n"])
    zp = OUT/f"反照率Z_{lv}.npz"
    if not zp.exists(): return nv["A"].astype(np.float32), nv["cov"] > 0, cs_n, n_n
    z = np.load(zp); A = z["A"].astype(np.float32); cs, n = float(z["cs"]), int(z["n"])
    c = grid_xy(cs, n); X, Y = np.meshgrid(c, c)
    An = np.stack([sample(nv["A"].astype(np.float32)[..., ch], cs_n, n_n, X.ravel(), Y.ravel()) for ch in range(3)], -1).reshape(n, n, 3)
    hn = sample((nv["cov"] > 0).astype(np.float32), cs_n, n_n, X.ravel(), Y.ravel()).reshape(n, n) > 0.5
    hz = z["cov"] > 0
    wz = np.clip(gaussian_filter(hz.astype(np.float32), 0.05/cs)*2 - 0.5, 0, 1)    # Mastcam 覆盖边缘 5 cm 羽化
    A = np.where(hz[..., None], A, An)*wz[..., None] + An*(1 - wz[..., None])
    return A.astype(np.float32), hz | hn, cs, n


def classify():
    """特征：反照率亮度、红/蓝比、反照率纹理（10–40 cm 频段）、坡度、1 m 局部起伏 → k-means（4 类）按亮度/粗糙度命名。
    再用重叠区学「HiRISE 亮度 × 纹理 → 各类比例」的查找表，推到 HiRISE ±1 km；更远按 CTX 亮度查表。"""
    from scipy.ndimage import gaussian_filter, uniform_filter, zoom
    t0 = time.time(); T = np.load(OUT/"地形.npz"); L = json.loads(str(T["levels"]))
    A, has, cs, n = best_albedo("中")
    (csm, nm) = L["中"]; c = grid_xy(cs, n); X, Y = np.meshgrid(c, c)
    Zm = sample(T["mid"], csm, nm, X.ravel(), Y.ravel(), order=3).reshape(n, n); del X, Y
    # 特征都要「与距离无关」：立体高程的分辨率随距离变差（中层 8 m 外按 r^1.5 加平滑），2 cm 粗糙度会把「近＝平、远＝更平」
    # 学成两类（第一版就这样，地类图成了同心环）。所以纹理改用反照率在 10–40 cm 频段的起伏（Navcam 到 50 m 仍有 4 cm 像素），
    # 高程只取 1 m 尺度的起伏和坡度，并且只在 25 m 内可信、往外渐变到中性值。
    from scipy.ndimage import binary_erosion
    c_ = grid_xy(cs, n); rr_ = np.hypot(*np.meshgrid(c_, c_)); conf = np.clip((25.0 - rr_)/10.0, 0, 1)
    has = has & ~under_rover(*np.meshgrid(c_, c_))
    (A,), _ = shift_fill([A], has, seed=3, rmin=0.3/cs, rmax=1.5/cs)       # 空洞先补，免得空洞边（反照率 0）被当成高纹理
    core = binary_erosion(has, iterations=int(0.1/cs))                     # 只用离空洞边 10 cm 以上的格学聚类
    lum = A.mean(-1); rb = A[..., 0]/np.maximum(A[..., 2], 1e-3)
    ll = np.log(np.maximum(lum, 1e-3)); band = gaussian_filter(ll, 0.05/cs) - gaussian_filter(ll, 0.20/cs)
    tex = np.sqrt(uniform_filter(band**2, int(0.4/cs)))                    # 沙匀、砾石花、基岩有层理
    relief = (Zm - gaussian_filter(Zm, 1.0/cs))*conf                       # 1 m 尺度局部凸起（岩块、岩坎）
    gy, gx = np.gradient(gaussian_filter(Zm, 0.25/cs), cs); slope = np.degrees(np.arctan(np.hypot(gx, gy)))*conf
    rough = tex; del rr_, conf, band
    F = np.stack([ll, rb, np.log(rough + 1e-3), relief, slope/30], -1)
    m = has & np.isfinite(F).all(-1); mc = m & core
    mu, sd = F[m].mean(0), F[m].std(0) + 1e-6; Fn = (F - mu)/sd
    rng = np.random.default_rng(0); pick = rng.choice(np.flatnonzero(mc.ravel()), min(200000, mc.sum()), replace=False)
    C, _ = kmeans(Fn.reshape(-1, 5)[pick], 4)
    # 命名：亮度高且粗糙低 → 基岩；粗糙最低 → 沙；起伏/暗 → 暗色岩块；其余砾石
    Cr = C*sd + mu; name = {}
    order = list(range(4))
    j_rock = max(order, key=lambda j: Cr[j, 3] - Cr[j, 0]); order.remove(j_rock)          # 起伏大、偏暗
    j_sand = min(order, key=lambda j: Cr[j, 2]); order.remove(j_sand)                     # 最平滑
    j_bed = max(order, key=lambda j: Cr[j, 0]); order.remove(j_bed)                       # 最亮
    j_grav = order[0]
    remap = np.zeros(4, int); remap[[j_sand, j_grav, j_bed, j_rock]] = [0, 1, 2, 3]
    # 软分类：到各中心距离 → softmax（地类之间自然过渡）
    P = np.empty((n, n, 4), np.float32)
    for r0 in range(0, n, 500):
        d = ((Fn[r0:r0 + 500, :, None, :] - C[None, None])**2).sum(-1)
        e = np.exp(-(d - d.min(-1, keepdims=True))/1.0); e /= e.sum(-1, keepdims=True)
        P[r0:r0 + 500] = e[..., np.argsort(remap)]
    P[~m] = np.nan
    log(f"地类（中层 {n}²×{cs} m）：" + "，".join(f"{CLASSES[i]} {np.nanmean(P[..., i])*100:.0f}%" for i in range(4)) +
        f"（{time.time() - t0:.0f} s）")
    for i in range(4):
        jj = np.argsort(remap)[i]
        log(f"  {CLASSES[i]}：反照率 {np.exp(Cr[jj, 0]):.3f}，红/蓝 {Cr[jj, 1]:.2f}，纹理 {np.exp(Cr[jj, 2]):.3f}，起伏 {Cr[jj, 3]*100:+.1f} cm，坡度 {Cr[jj, 4]*30:.0f}°")
    # 推到 HiRISE：特征＝25 cm 反照率亮度 + 1 m 窗纹理（亮度局部标准差）；二维直方图查表（各类平均比例）
    hz = np.load(OUT/"反照率_HiRISE.npz"); Ah = hz["A"].astype(np.float32).mean(-1); hcs, hn = float(hz["cs"]), int(hz["n"])
    tex = np.sqrt(np.maximum(uniform_filter(Ah**2, 4) - uniform_filter(Ah, 4)**2, 0))
    fb = lambda a, t: (np.clip(np.digitize(a, qa) - 1, 0, 23), np.clip(np.digitize(t, qt) - 1, 0, 23))
    k = int(round(hcs/cs))                                                 # 中层格聚到 HiRISE 像素
    Pk = P[:n//k*k, :n//k*k].reshape(n//k, k, n//k, k, 4); Pk = np.nanmean(Pk, (1, 3))
    off = (hn - n//k)//2; sl = (slice(off, off + n//k), slice(off, off + n//k))
    a_ov, t_ov = Ah[sl].ravel(), tex[sl].ravel(); p_ov = Pk.reshape(-1, 4); ok = np.isfinite(p_ov).all(1)
    qa = np.quantile(a_ov[ok], np.linspace(0, 1, 25)); qt = np.quantile(t_ov[ok], np.linspace(0, 1, 25))
    ia, it = fb(a_ov[ok], t_ov[ok]); lut = np.zeros((24, 24, 4)); cnt = np.zeros((24, 24))
    np.add.at(lut, (ia, it), p_ov[ok]); np.add.at(cnt, (ia, it), 1)
    glob_ = p_ov[ok].mean(0); lut = (lut + 5*glob_)/(cnt[..., None] + 5)                    # 稀的格子往全局均值收
    ia, it = fb(Ah, tex); Ph = lut[ia, it].astype(np.float32)
    Ph[sl] = np.where(np.isfinite(Pk), Pk, Ph[sl])                          # 重叠区用实测
    np.savez_compressed(OUT/"地类.npz", mid=np.nan_to_num(P, nan=-1).astype(np.float16), hirise=Ph.astype(np.float16),
                        cs_mid=cs, n_mid=n, cs_hi=hcs, n_hi=hn, centers=Cr[np.argsort(remap)], classes=json.dumps(CLASSES, ensure_ascii=False))
    log(f"地类推到 HiRISE {hn}²×{hcs} m：" + "，".join(f"{CLASSES[i]} {Ph[..., i].mean()*100:.0f}%" for i in range(4)) + f"（{time.time() - t0:.0f} s）")


# ── ⑧ 石块：分割 → 超椭球补背面 → 大石做封闭网格 → 数据分辨不了的尺寸按 Golombek 统计补 ─────────────
ROCK_MESH_MIN = 0.15                                                     # ≥15 cm 的做独立网格（看得到下沿、能有悬空）


def ground_of(Z, cs, sigma):
    """迭代下包络：反复「平滑 → 与原高度取小」，地面顺着坡走、把凸起的石块压下去（坡上不会整片误判）。"""
    from scipy.ndimage import gaussian_filter
    g = Z.copy()
    for _ in range(8):
        g = np.minimum(g, gaussian_filter(g, sigma/cs))
    return gaussian_filter(g, 0.3*sigma/cs)


def superellipsoid_fit(x, y, z, obs):
    """在一块石头的格上拟合 z = h·(1 − (|u/a|^p + |v/b|^p))^(1/p)₊（u, v 为旋转后的坐标），只用观测到的格。"""
    from scipy.optimize import least_squares
    xo, yo, zo = x[obs], y[obs], z[obs]
    w = np.maximum(zo, 0); cx, cy = (np.sum(xo*w), np.sum(yo*w))/max(w.sum(), 1e-9)
    cov = np.cov(np.stack([xo - cx, yo - cy]), aweights=w + 1e-6) if len(xo) > 3 else np.eye(2)*1e-4
    ev, evec = np.linalg.eigh(cov); th0 = math.atan2(evec[1, 1], evec[0, 1])
    a0, b0 = 2*math.sqrt(max(ev[1], 1e-6)), 2*math.sqrt(max(ev[0], 1e-6))
    def model(p, X, Y):
        cx_, cy_, a, b, th, h, pe = p
        u = (X - cx_)*math.cos(th) + (Y - cy_)*math.sin(th); v = -(X - cx_)*math.sin(th) + (Y - cy_)*math.cos(th)
        s = np.abs(u/a)**pe + np.abs(v/b)**pe
        return h*np.clip(1 - s, 0, None)**(1/pe)
    p0 = [cx, cy, a0, b0, th0, max(zo.max(), 0.01), 2.0]
    lo = [cx - a0, cy - a0, 0.3*a0, 0.3*b0, th0 - math.pi, 0.5*p0[5], 1.2]; hi = [cx + a0, cy + a0, 3*a0, 3*b0, th0 + math.pi, 2.5*p0[5], 6]
    try:
        r = least_squares(lambda p: model(p, xo, yo) - zo, p0, bounds=(lo, hi), loss="soft_l1", f_scale=0.01, max_nfev=200)
        return r.x, model
    except Exception:
        return np.array(p0), model


def rock_mesh(Rc, G, X, Y, m, cs, bury, nth=20):
    """星形网格：外轮廓 r(θ)（从石心沿 20 个方向走到掩膜外，轻度平滑）、5 圈顶面（高度取补全后的凸起）、
    外圈斜插到地下 bury（侧面不是格子台阶），底面封口。返回 (V 相对石心, F, 石心)。"""
    from scipy.ndimage import map_coordinates, gaussian_filter1d
    ys, xs = np.nonzero(m); cy, cx = ys.mean(), xs.mean()                   # 格坐标
    th = np.linspace(0, 2*np.pi, nth, endpoint=False); rr = np.zeros(nth)
    for i, t in enumerate(th):
        r = 0.0
        while True:
            yy, xx = cy + (r + 0.5)*math.sin(t), cx + (r + 0.5)*math.cos(t)
            iy, ix = int(round(yy)), int(round(xx))
            if not (0 <= iy < m.shape[0] and 0 <= ix < m.shape[1]) or not m[iy, ix]: break
            r += 0.5
        rr[i] = r + 0.5
    rr = np.maximum(gaussian_filter1d(rr, 0.7, mode="wrap"), 1.0)           # 少平滑、少分段 → 有棱角的碎块（这里的石头多是层状岩碎片）
    ts = np.array([0.0, 0.45, 0.75, 0.92, 1.0])
    gy = cy + ts[:, None]*rr[None]*np.sin(th)[None]; gx = cx + ts[:, None]*rr[None]*np.cos(th)[None]
    h = np.maximum(map_coordinates(Rc, [gy, gx], order=1, mode="nearest"), 0)
    h *= np.clip((1 - ts)/0.1, 0, 1)[:, None]*0.8 + 0.2                    # 边缘收一下（顶面数据边上是阈值高度的台阶）
    g = map_coordinates(G, [gy, gx], order=1, mode="nearest")
    wx = map_coordinates(X, [gy, gx], order=1, mode="nearest"); wy = map_coordinates(Y, [gy, gx], order=1, mode="nearest")
    top = np.stack([wx, wy, g + h], -1)
    top[0] = top[0, 0]                                                     # 中心一圈退化成一点
    fl = 1.06                                                              # 埋下去的一圈略往外张（石头底部比露出的宽）
    by_, bx_ = cy + fl*rr*np.sin(th), cx + fl*rr*np.cos(th)
    bot = np.stack([map_coordinates(X, [by_, bx_], order=1, mode="nearest"), map_coordinates(Y, [by_, bx_], order=1, mode="nearest"),
                    map_coordinates(G, [by_, bx_], order=1, mode="nearest") - bury], -1)
    V = [top[0, 0]] + [top[k, i] for k in range(1, len(ts)) for i in range(nth)] + [bot[i] for i in range(nth)]
    ctr = np.array([top[0, 0, 0], top[0, 0, 1], float(np.mean(g[-1]))])
    V.append([ctr[0], ctr[1], ctr[2] - bury])
    V = np.array(V, np.float32)
    ring = lambda k: 1 + (k - 1)*nth                                       # 第 k 圈（k ≥ 1）起点
    F = []
    for i in range(nth):
        j = (i + 1) % nth
        F.append((0, ring(1) + i, ring(1) + j))
        for k in range(1, len(ts) - 1):
            F.append((ring(k) + i, ring(k + 1) + i, ring(k + 1) + j, ring(k) + j))
        kb = ring(len(ts)); F.append((ring(len(ts) - 1) + i, kb + i, kb + j, ring(len(ts) - 1) + j))   # 侧面
        F.append((len(V) - 1, kb + j, kb + i))                              # 底面
    return V - ctr, F, ctr


def rocks():
    """近层（2 cm）高程减迭代下包络 → 连通域 → 筛：高宽比 ≥ 0.15（沙波、沙堆是 0.05–0.1）、高度超过该距离的立体噪声 2.5 倍、
    且与周围有反照率反差或者够高（H/D ≥ 0.3）。第一版只看「高出 3 cm」，把带波纹的沙地切成了一片片薄饼。"""
    from scipy.ndimage import label, find_objects, binary_dilation
    t0 = time.time(); T = np.load(OUT/"地形.npz"); L = json.loads(str(T["levels"]))
    cs, n = L["近"]; Z = T["near"].astype(np.float64); W = T["near_w"]
    G = ground_of(Z, cs, 0.25)
    rel = Z - G
    c = grid_xy(cs, n); Xg, Yg = np.meshgrid(c, c); rg = np.hypot(Xg - MAST_ENU[0], Yg - MAST_ENU[1])
    noise = 0.003 + 2.4e-4*rg**2                                           # 立体高程噪声（与融合用的 σ 一致）
    mask = rel > np.maximum(0.03, 2.5*noise)
    nv = np.load(OUT/"反照率_近.npz"); An = nv["A"].astype(np.float32).mean(-1); csa, na = float(nv["cs"]), int(nv["n"])
    alb = sample(np.where(nv["cov"] > 0, An, np.nan), csa, na, Xg.ravel(), Yg.ravel(), order=1).reshape(n, n)
    lab, nl = label(mask)
    objs = find_objects(lab)
    Zc = Z.copy(); big = []; done = 0; filled = 0; why = dict(扁=0, 糊=0, 没反差=0)
    for i, sl in enumerate(objs, 1):
        if sl is None: continue
        sy, sx = sl; pad = 6
        sy = slice(max(sy.start - pad, 0), min(sy.stop + pad, n)); sx = slice(max(sx.start - pad, 0), min(sx.stop + pad, n))
        m = lab[sy, sx] == i
        if m.sum() < 6: continue                                          # < 5 cm 的不管（交给细节材质）
        X, Y = Xg[sy, sx], Yg[sy, sx]; R = rel[sy, sx]; obs = (W[sy, sx] > 0) & m
        D = 2*math.sqrt(m.sum()*cs*cs/math.pi); H = float(R[m].max())
        if D > 1.5: continue                                              # 露头基岩：留在地形里
        if H/D < 0.15: why["扁"] += 1; continue
        if H < 2.5*float(noise[sy, sx][m].mean()): why["糊"] += 1; continue
        ring_ = binary_dilation(m, iterations=4) & ~binary_dilation(m, iterations=1)
        ai, ao = np.nanmedian(alb[sy, sx][m]) if np.isfinite(alb[sy, sx][m]).any() else np.nan, np.nanmedian(alb[sy, sx][ring_]) if np.isfinite(alb[sy, sx][ring_]).any() else np.nan
        contrast = abs(ai/ao - 1) if np.isfinite(ai) and np.isfinite(ao) and ao > 0 else 0.0
        if contrast < 0.04 and H/D < 0.3: why["没反差"] += 1; continue
        reg = binary_dilation(m, iterations=4)                            # 可能被挡住的背面也在石头附近
        hole = reg & (W[sy, sx] == 0)
        if obs.sum() >= 6 and hole.any():
            p, model = superellipsoid_fit(X, Y, R, obs)
            Rm = model(p, X, Y)
            Zc[sy, sx] = np.where(hole, G[sy, sx] + np.maximum(Rm, 0), Zc[sy, sx]); filled += 1
        if D >= ROCK_MESH_MIN and H >= 0.04:
            big.append(dict(sl=(sy.start, sy.stop, sx.start, sx.stop), id=i, D=D, H=H))
        done += 1
    log(f"近层石块 {done} 块（≥5 cm），补背面 {filled} 块，≥{ROCK_MESH_MIN*100:.0f} cm 做网格 {len(big)} 块；"
        f"剔掉：太扁（沙波/沙堆）{why['扁']}、低于噪声 {why['糊']}、无反照率反差 {why['没反差']}（{time.time() - t0:.0f} s）")
    # 大石：从地形里拿出来（地面），网格＝星形穹顶，埋入 20% 高
    meshes, inst = [], []
    Zg = Zc.copy()
    for b in big:
        y0, y1, x0, x1 = b["sl"]; m = lab[y0:y1, x0:x1] == b["id"]
        Zg[y0:y1, x0:x1] = np.where(binary_dilation(m, iterations=1), G[y0:y1, x0:x1], Zg[y0:y1, x0:x1])
        V, F, ctr = rock_mesh(Zc[y0:y1, x0:x1] - G[y0:y1, x0:x1], G[y0:y1, x0:x1], Xg[y0:y1, x0:x1], Yg[y0:y1, x0:x1], m, cs, 0.2*b["H"])
        meshes.append(dict(V=V, F=np.array(F, object))); inst.append(dict(pos=ctr.tolist(), D=b["D"], H=b["H"], src="实测+补全"))
    k_meas = np.sum([math.pi*(b["D"]/2)**2 for b in big])/(cs*n)**2 if big else 0.0
    np.save(OUT/"地形_近石.npy", Zg.astype(np.float32))                      # 地形：小石补背面，大石拿掉留地面
    pack = {}
    for i, m_ in enumerate(meshes):                                        # 面有三角有四边：存成「顶点数, 索引…」平铺
        pack[f"V{i}"] = m_["V"]; pack[f"F{i}"] = np.array([x for f in m_["F"] for x in (len(f), *f)], np.int32)
    np.savez_compressed(OUT/"石块.npz", inst=json.dumps(inst, ensure_ascii=False), nmesh=len(meshes), **pack)
    log(f"石块网格 {len(meshes)} 块 → 石块.npz；近层 ≥15 cm 石块覆盖率 k ≈ {k_meas*100:.2f}%（{time.time() - t0:.0f} s）")


# ── ⑨ 细节材质：微观（Mastcam-Z 近距特写 → 光度测斜）＋ 中观（本站 1 cm 反照率 / 2 cm 高程）─────────────
DETAIL_N, DETAIL_PX = 384, 0.0006                                          # 微观样本：384² × 0.6 mm ≈ 23 cm 见方（一张长焦近距特写在地上只有 ~37×28 cm，46 cm 放不进）


def photoclinometry(I, px, s_t, s_n, eps=0.05):
    """线性光度测斜（Kirk 1987 一类）：I/I₀ − 1 ≈ −(∇z·ŝ_t)·|s_t|/s_n → 沿太阳方位的坡度 → 频域积分成高度（正则化，垂直于太阳的方向靠 ε 稳住）。"""
    from scipy.ndimage import gaussian_filter
    I0 = gaussian_filter(I, 0.02/px)                                       # 2 cm 以上当反照率/大尺度起伏，不算坡度
    g = -(I/np.maximum(I0, 1e-6) - 1)*s_n/max(np.linalg.norm(s_t), 1e-3)    # 沿 t̂ 的坡度
    t = s_t/max(np.linalg.norm(s_t), 1e-9)
    ky = np.fft.fftfreq(I.shape[0], px)*2*np.pi; kx = np.fft.fftfreq(I.shape[1], px)*2*np.pi
    KX, KY = np.meshgrid(kx, ky); kt = KX*t[0] + KY*t[1]; k2 = KX**2 + KY**2
    Gf = np.fft.fft2(g - g.mean())
    Zf = Gf*np.conj(1j*kt)/(kt**2 + eps*k2 + 1e-6)
    Zf[0, 0] = 0
    return np.real(np.fft.ifft2(Zf)).astype(np.float32)


def rectify(z, P0_enu, n0, N, px):
    """把这帧在 P0 处的地面（切平面）重采样成 N×N 的正射小块（px 米/像素）：返回 (RGB IOF, 平面基 e1, e2)。"""
    e1 = np.array([1.0, 0, 0]) - n0*n0[0]; e1 /= np.linalg.norm(e1); e2 = np.cross(n0, e1)
    o = (np.arange(N) - N/2 + 0.5)*px; U, V = np.meshgrid(o, o)
    P = P0_enu + U.ravel()[:, None]*e1 + V.ravel()[:, None]*e2
    x, y, d = cahvor(z["cam"], enu_to_site(P))
    bx = (x - z["cam"]["fs"] - 0.5)/2; by = (y - z["cam"]["fl"] - 0.5)/2
    img = np.nan_to_num(z["img"]); h, w = img.shape[:2]
    ok = (bx >= 0) & (by >= 0) & (bx < w - 1) & (by < h - 1) & (d > 0)
    out = np.full((N*N, 3), np.nan, np.float32)
    i0 = np.floor(by[ok]).astype(int); j0 = np.floor(bx[ok]).astype(int); fy = (by[ok] - i0)[:, None]; fx = (bx[ok] - j0)[:, None]
    out[ok] = img[i0, j0]*(1 - fy)*(1 - fx) + img[i0 + 1, j0]*fy*(1 - fx) + img[i0, j0 + 1]*(1 - fy)*fx + img[i0 + 1, j0 + 1]*fy*fx
    return out.reshape(N, N, 3), e1, e2


def ray_ground(C_enu, d_enu, Hf, tmax=60.0):
    """从 C 沿 d 走到第一次低于地形（Hf(x, y)）的点（粗走 + 二分）。"""
    t = 0.3; prev = 0.3
    while t < tmax:
        p = C_enu + t*d_enu
        if p[2] < Hf(p[0], p[1]):
            lo, hi = prev, t
            for _ in range(20):
                mid = 0.5*(lo + hi); q = C_enu + mid*d_enu
                lo, hi = (mid, hi) if q[2] >= Hf(q[0], q[1]) else (lo, mid)
            return C_enu + hi*d_enu
        prev = t; t += max(0.01, 0.02*t)
    return None


def periodic(u):
    """Moisan 2011「周期＋平滑分解」：去掉边界不连续造成的平滑分量，剩下的周期分量能无缝平铺（逐通道）。"""
    if u.ndim == 3: return np.stack([periodic(u[..., c]) for c in range(u.shape[-1])], -1)
    u = u.astype(np.float64); M, N = u.shape
    v = np.zeros_like(u)
    v[0] += u[-1] - u[0]; v[-1] += u[0] - u[-1]; v[:, 0] += u[:, -1] - u[:, 0]; v[:, -1] += u[:, 0] - u[:, -1]
    q = np.arange(M)[:, None]; r = np.arange(N)[None, :]
    den = 2*np.cos(2*np.pi*q/M) + 2*np.cos(2*np.pi*r/N) - 4; den[0, 0] = 1
    Sf = np.fft.fft2(v)/den; Sf[0, 0] = 0
    return (u - np.real(np.fft.ifft2(Sf))).astype(np.float32)


def details():
    from scipy.ndimage import gaussian_filter
    t0 = time.time(); T = np.load(OUT/"地形.npz"); L = json.loads(str(T["levels"]))
    csm, nm = L["中"]; mid = T["mid"]
    Hf = lambda x, y: float(sample(mid, csm, nm, np.array([x]), np.array([y]))[0])
    K = np.load(OUT/"地类.npz"); Pm = K["mid"].astype(np.float32); cs_k, n_k = float(K["cs_mid"]), int(K["n_mid"])
    meta = json.loads((OUT/"mastcam_配准.json").read_text())
    cand = {i: [] for i in range(4)}
    for z in z_frames():
        v = meta.get(z["name"])
        if not v or not v.get("ok") or z["focal"] < 100 or not (20 <= z["sun"][1] <= 60): continue
        cam = z["cam"]; C = to_enu(cam["C"][None])[0]; d = (cam["A"] @ M_SB); d /= np.linalg.norm(d)
        if d[2] > -0.5: continue                                             # 往下看 ≥30°：太斜的话顺视线方向被压扁，拉出竖条纹
        P0 = ray_ground(C, d, Hf, tmax=8.0)
        if P0 is None or under_rover(np.array([P0[0]]), np.array([P0[1]]))[0]: continue
        o = (np.arange(16) - 7.5)/16*DETAIL_N*DETAIL_PX; U_, V_ = np.meshgrid(o, o)   # 样块里 16×16 个地面点，逐条视线查车体
        Pt = P0 + np.stack([U_.ravel(), V_.ravel(), np.zeros(U_.size)], 1)
        Cs = C + 0.35*(Pt.mean(0) - C)/np.linalg.norm(Pt.mean(0) - C)       # 从相机外 0.35 m 起算（相机就在桅杆头里）
        if rays_hit_rover(Cs, Pt).mean() > 0.01: continue                  # 看的是甲板/校准靶/车轮
        rng_ = float(np.linalg.norm(P0 - C)); pxsz = 2*rng_/np.linalg.norm(cam["H"] - (cam["H"] @ cam["A"])*cam["A"])
        pxsz /= -d[2]                                                        # 顺视线方向的地面足迹（掠射拉长）
        if pxsz > 0.0015: continue                                           # 两个方向都要细于 1.5 mm
        ci = int(round(P0[1]/cs_k + n_k/2 - 0.5)); cj = int(round(P0[0]/cs_k + n_k/2 - 0.5))
        if not (0 <= ci < n_k and 0 <= cj < n_k) or Pm[ci, cj, 0] < 0: continue
        p = Pm[max(ci - 10, 0):ci + 10, max(cj - 10, 0):cj + 10].reshape(-1, 4); p = p[p[:, 0] >= 0].mean(0)
        for k in range(4):
            if p[k] >= 0.3: cand[k].append((float(p[k]), z["name"], P0, pxsz))   # 纯度太低的宁可借别类
    out = {}
    zs = {zz["name"]: zz for zz in z_frames() if any(zz["name"] == c_[1] for k in cand for c_ in sorted(cand[k], key=lambda q: -q[0])[:2])}
    for k in range(4):
        best = sorted(cand[k], key=lambda q: -q[0])[:2]
        tiles = []
        for purity, name, P0, pxsz in best:
            z = zs[name]
            gy, gx = np.gradient(gaussian_filter(mid, 2), csm); i = int(P0[1]/csm + nm/2); j = int(P0[0]/csm + nm/2)
            n0 = np.array([-gx[i, j], -gy[i, j], 1.0]); n0 /= np.linalg.norm(n0)
            rgb, e1, e2 = rectify(z, P0, n0, DETAIL_N, DETAIL_PX)
            bad = ~np.isfinite(rgb).all(-1) | (rgb.min(-1) <= 0)
            if bad.mean() > 0.02: continue
            rgb[bad] = np.median(rgb[~bad], 0)                                # 零星坏像素（饱和/画面边）用中位补，免得 FFT 整块变 nan
            s = sun_enu(*z["sun"]); s_t = np.array([s @ e1, s @ e2]); s_n = float(s @ n0)
            lum = rgb.mean(-1)
            Zd = gaussian_filter(photoclinometry(lum, DETAIL_PX, s_t, s_n, eps=0.5), 1.0)   # ε 大：垂直太阳方向不再拉条纹
            # 单张图分不开反照率和明暗：亮度起伏大半当明暗（已进高度），反照率细节只留 30% 的亮度起伏 + 一半的色差
            low = np.stack([gaussian_filter(rgb[..., c_], 0.04/DETAIL_PX) for c_ in range(3)], -1)
            r_ = rgb/np.maximum(low, 1e-6); l_ = r_.mean(-1, keepdims=True)
            Ad = l_**0.3*(1 + 0.5*(r_/np.maximum(l_, 1e-6) - 1))               # 反照率细节（均值≈1）
            Ad /= np.nanmean(Ad.reshape(-1, 3), 0)
            Ad = periodic(np.clip(Ad, 0.3, 2.5)); Zd = periodic(Zd)
            tiles.append(dict(A=np.clip(Ad, 0.3, 2.5).astype(np.float16), H=(Zd - Zd.mean()).astype(np.float32), src=name, purity=purity, pxsz=pxsz))
            log(f"  微观 {CLASSES[k]} ← {name[:30]}（纯度 {purity:.2f}，原始 {pxsz*1000:.2f} mm/像素，高度 RMS {Zd.std()*1000:.2f} mm）")
        out[k] = tiles
    for k in range(4):                                                     # 没拍到合适特写的类：借反照率最接近的类（标在 info 里）
        if not out[k]:
            got = [j for j in range(4) if out[j] and out[j][0]["src"] and not out[j][0].get("借")]
            if got:
                j = min(got, key=lambda j: abs(K["centers"][j, 0] - K["centers"][k, 0]))
                out[k] = [dict(t, 借=CLASSES[j]) for t in out[j]]; log(f"  微观 {CLASSES[k]}：没有合适特写，借 {CLASSES[j]} 的")
    # 素材库（scripts/素材库/62_近拍素材.py 选用）：本站特写不纯（纯度 < 0.6，多半拍的是混合地面）或没有时，换 WATSON / MAHLI 近拍样块。
    # 有数据用数据：本站纯的特写优先（它就是这片地）；素材库补的是「这一类在这站没拍清楚」。
    LIBD = MAP/"素材库"; sel = LIBD/"选用.json"
    if sel.exists() and "--不用素材库" not in sys.argv:
        from PIL import Image as _I
        S_ = json.loads(sel.read_text()).get("微观", {})
        for k in range(4):
            picks = S_.get(CLASSES[k], [])[:2]
            local = max((t["purity"] for t in out[k] if not t.get("借")), default=0.0)
            if not picks or local >= 0.6: continue
            tl = []
            for x in picks:
                d = LIBD/"细节"/"微观"/CLASSES[k]/x["id"]; m = json.loads((d/"元数据.json").read_text())
                A_ = np.asarray(_I.open(d/"反照率.png")).astype(np.float32)/255*2
                H_ = (np.asarray(_I.open(d/"高度.png")).astype(np.float32)/65535 - 0.5)*2*m["height_range"]
                tl.append(dict(A=A_.astype(np.float16), H=H_ - H_.mean(), src="素材库:" + x["id"], purity=1.0, pxsz=m["像素_m"], px=m["像素_m"]))
            out[k] = tl; log(f"  微观 {CLASSES[k]} ← 素材库 {', '.join(x['id'] for x in picks)}（{tl[0]['px']*1e6:.0f} µm × {tl[0]['A'].shape[0]} px）")
    # 中观：本站 1 cm 反照率 + 2 cm 高程，每类挑纯度最高的 2 m 方块，去掉 0.5 m 以上的低频
    A, has, cs_a, n_a = best_albedo("近"); Zn = near_filled(); csn, nn_ = L["近"]
    c_a = grid_xy(cs_a, n_a); Xa, Ya = np.meshgrid(c_a, c_a)
    Pa = np.stack([sample(np.where(Pm[..., k] >= 0, Pm[..., k], np.nan), cs_k, n_k, Xa.ravel(), Ya.ravel(), order=0) for k in range(4)], -1).reshape(n_a, n_a, 4)
    meso = {}
    S = int(2.0/cs_a)
    from scipy.ndimage import uniform_filter
    hz_ = sample((T["near_w"] > 0).astype(np.float32), csn, nn_, Xa.ravel(), Ya.ravel(), order=0).reshape(n_a, n_a) > 0.5   # 立体真测到的格
    full = uniform_filter((has & hz_).astype(np.float32), S)               # 2 m 方块里反照率和高程都实测的比例
    for k in range(4):
        sc = uniform_filter(np.nan_to_num(Pa[..., k]), S)*(full > 0.97)*(1 + full)
        sc[:S, :] = sc[-S:, :] = sc[:, :S] = sc[:, -S:] = 0
        sc *= ~under_rover(Xa, Ya)
        if sc.max() <= 0:                                                  # 没有完整的方块就放宽
            sc = uniform_filter(np.nan_to_num(Pa[..., k]), S)*full**4; sc[:S, :] = sc[-S:, :] = sc[:, :S] = sc[:, -S:] = 0; sc *= ~under_rover(Xa, Ya)
        i, j = np.unravel_index(np.argmax(sc), sc.shape); sl = (slice(i - S//2, i + S//2), slice(j - S//2, j + S//2))
        a = A[sl].copy(); ok_ = (has & hz_)[sl]
        if not ok_.all(): (a,), _ = shift_fill([a], ok_, seed=k, rmin=5, rmax=40)
        aL = np.stack([gaussian_filter(a[..., c_], 0.5/cs_a) for c_ in range(3)], -1)
        Zs_ = sample(Zn, csn, nn_, Xa[sl].ravel(), Ya[sl].ravel(), order=3).reshape(a.shape[:2])
        Ad = periodic(np.clip(a/np.maximum(aL, 1e-6), 0.3, 2.5)); Hd = periodic(Zs_ - gaussian_filter(Zs_, 0.5/cs_a))
        meso[k] = dict(A=np.clip(Ad, 0.3, 2.5).astype(np.float16), H=(Hd - Hd.mean()).astype(np.float32), full=float(full[i, j]),
                       pxsz=cs_a, at=(float(Xa[i, j]), float(Ya[i, j])), purity=float(np.nanmean(Pa[sl][..., k])))
        log(f"  中观 {CLASSES[k]} ← ({Xa[i, j]:+.1f}, {Ya[i, j]:+.1f}) m，纯度 {meso[k]['purity']:.2f}，实测 {meso[k]['full']*100:.0f}%，高度 RMS {meso[k]['H'].std()*1000:.1f} mm")
    pack = {}
    for k in range(4):
        for t, tl in enumerate(out[k]):
            pack[f"micro{k}_{t}_A"] = tl["A"]; pack[f"micro{k}_{t}_H"] = tl["H"]; pack[f"micro{k}_{t}_px"] = tl.get("px", DETAIL_PX)
        pack[f"meso{k}_A"] = meso[k]["A"]; pack[f"meso{k}_H"] = meso[k]["H"]
    np.savez_compressed(OUT/"细节材质.npz", **pack, micro_px=DETAIL_PX, meso_px=cs_a,
                        info=json.dumps({CLASSES[k]: dict(micro=[dict(src=t["src"], purity=t["purity"], 借=t.get("借")) for t in out[k]], meso=dict(at=meso[k]["at"], purity=meso[k]["purity"])) for k in range(4)}, ensure_ascii=False))
    log(f"细节材质 → 细节材质.npz（{time.time() - t0:.0f} s）")


# ── ④ 远景反照率（HiRISE / CTX 灰度 → 去光影 → 按近景学到的颜色上色）──────────────
FAR = {"HiRISE": ("hirise_ortho_25cm", 0.25, 8000, "hirise", 1.0), "CTX": ("ctx_ortho_10m", 20.0, 4000, "ctx", 20.0)}


def ortho_enu(name, cs, n):
    """正射影像窗口重采样到 ENU 网格（灰度 0–1，没数据 nan）。"""
    from scipy.ndimage import map_coordinates
    from rasterio.warp import transform
    a = np.load(DIR/f"{name}.npy", mmap_mode="r"); m = json.loads((DIR/f"{name}.json").read_text()); t = m["transform"]
    c = grid_xy(cs, n); out = np.empty((n, n), np.float32)
    for r0 in range(0, n, 500):
        X, Y = np.meshgrid(c, c[r0:r0 + 500])
        lon, lat = enu_to_lonlat(X.ravel(), Y.ravel())
        px, py = transform(f"+proj=longlat +R={R_MARS} +no_defs", m["crs"], lon, lat)
        col = (np.array(px) - t[2])/t[0] - 0.5; row = (np.array(py) - t[5])/t[4] - 0.5
        i0, i1 = max(int(row.min()) - 2, 0), min(int(row.max()) + 3, a.shape[0])
        j0, j1 = max(int(col.min()) - 2, 0), min(int(col.max()) + 3, a.shape[1])
        sub = np.asarray(a[i0:i1, j0:j1], np.float32)
        v = map_coordinates(sub, [row - i0, col - j0], order=1, mode="constant", cval=0)
        out[r0:r0 + 500] = np.where(v > 0, v/255.0, np.nan).reshape(X.shape)
    return out


def far_albedo():
    from scipy.ndimage import zoom, gaussian_filter
    T = np.load(OUT/"地形.npz"); L = json.loads(str(T["levels"]))
    mid = np.load(OUT/"反照率_中.npz"); Am = mid["A"].astype(np.float32); cov = mid["cov"]; csm, nm = float(mid["cs"]), int(mid["n"])
    for lv, (name, cs, n, hkey, hcs) in FAR.items():
        t0 = time.time()
        I = ortho_enu(name, cs, n)
        (hc, hn) = L["HiRISE" if hkey == "hirise" else "CTX"]
        Hg = T[hkey]
        # 法线：高程网格（1 m / 20 m）→ 平滑 → 插到影像格
        c = grid_xy(cs, n)
        Nr = normals(gaussian_filter(Hg, 1.0), hc).astype(np.float32)
        def nrm_at(X, Y):
            return np.stack([sample(Nr[..., k], hc, hn, X, Y) for k in range(3)], -1)
        # 太阳方向：抽 20 万点，网格搜 (方位, 高度) 使 I ≈ α + β·max(n·s, 0) 的相关最大
        rng = np.random.default_rng(0); ii = rng.integers(0, n, (200000, 2))
        X, Y = c[ii[:, 1]], c[ii[:, 0]]; Iv = I[ii[:, 0], ii[:, 1]]; ok = np.isfinite(Iv)
        Nv = nrm_at(X[ok], Y[ok]); Iv = Iv[ok]
        best = None
        for az in range(0, 360, 5):
            for el in range(15, 81, 5):
                sh = np.maximum(Nv @ sun_enu(az, el), 0)
                r = np.corrcoef(sh, Iv)[0, 1]
                if best is None or r > best[0]: best = (r, az, el)
        s = sun_enu(best[1], best[2]); sh = np.maximum(Nv @ s, 0)
        beta, alpha = np.polyfit(sh, Iv, 1); k = max(alpha/max(beta, 1e-6), 0.05)
        log(f"{lv} 拍摄时太阳 方位 {best[1]}° 高 {best[2]}°（相关 {best[0]:.2f}），环境/直射 {k:.2f}")
        G = np.empty((n, n), np.float32)
        for r0 in range(0, n, 500):
            Xr, Yr = np.meshgrid(c, c[r0:r0 + 500])
            shr = np.maximum(nrm_at(Xr.ravel(), Yr.ravel()) @ s, 0).reshape(Xr.shape)
            G[r0:r0 + 500] = I[r0:r0 + 500]/(k + shr)                      # 去光影后的相对反照率（灰）
        # 颜色：和中景彩色反照率重叠处学「灰 → RGB」查找表（32 档，按分位数分档）
        half_m = csm*nm/2*0.9
        ov = (np.abs(c) < half_m)
        sel = np.ix_(ov, ov)
        Gm = G[sel]; Xo, Yo = np.meshgrid(c[ov], c[ov])
        Ao = np.stack([sample(gaussian_filter(Am[..., ch], cs/csm/2), csm, nm, Xo.ravel(), Yo.ravel()) for ch in range(3)], -1)
        co = sample(cov, csm, nm, Xo.ravel(), Yo.ravel(), order=0) > 0
        g = Gm.ravel(); m = co & np.isfinite(g)
        if m.sum() < 1000:                                                 # CTX 格太粗：拿上一级（HiRISE 远景）当颜色参考
            ref = np.load(OUT/"反照率_HiRISE.npz"); Ar = ref["A"].astype(np.float32); rcs, rn = float(ref["cs"]), int(ref["n"])
            ov = np.abs(c) < rcs*rn/2*0.9; Xo, Yo = np.meshgrid(c[ov], c[ov]); g = G[np.ix_(ov, ov)].ravel()
            Ao = np.stack([sample(gaussian_filter(Ar[..., ch], cs/rcs/2), rcs, rn, Xo.ravel(), Yo.ravel()) for ch in range(3)], -1)
            m = np.isfinite(g) & np.isfinite(Ao).all(1)
        q = np.quantile(g[m], np.linspace(0, 1, 33)); qc = 0.5*(q[1:] + q[:-1])
        bins = np.clip(np.searchsorted(q, g[m]) - 1, 0, 31)
        lut = np.array([np.median(Ao[m][bins == b], 0) if (bins == b).any() else [np.nan]*3 for b in range(32)])
        for ch in range(3):
            okb = np.isfinite(lut[:, ch]); lut[:, ch] = np.interp(qc, qc[okb], lut[okb, ch])
        A = np.stack([np.interp(G, qc, lut[:, ch], left=lut[0, ch], right=lut[-1, ch]) for ch in range(3)], -1)
        A = np.where(np.isfinite(G)[..., None], A, np.nanmedian(A.reshape(-1, 3), 0))
        np.savez_compressed(OUT/f"反照率_{lv}.npz", A=A.astype(np.float16), cs=cs, n=n, sun=np.array(best[1:]), lut=lut)
        log(f"反照率 {lv}：{n}² × {cs} m，中位 RGB {np.round(np.nanmedian(A.reshape(-1, 3), 0), 3)}（{time.time() - t0:.0f} s）")


# ── ⑤ 导出给 Blender：嵌套方环网格（clipmap）+ 反照率贴图 ───────────────────────
RING0 = (0.02, 6.0)                                                      # 最里一环：2 cm、±6 m；往外每环格距、半宽都翻倍
NRING = 15                                                               # 6·2^14 ≈ 98 km
VALIDATE = ("NRF_0530_0713995035", "NRF_0502_0711508350")                # 对照用的两张：sol 530 臂前方、sol 502 到站环拍


def near_denoised(Z, cs, n):
    """近层 2 cm 高程按距离去噪：立体噪声 σ ≈ 3 mm + 2.4×10⁻⁴·r²，2.5 m 外渐变到 2 cm 平滑、5 m 外 5 cm 平滑。
    不去的话斜看时满地「鳞片」（立体匹配的像素锁定纹）；去掉的那段频率由细节材质（微观）补回。≥15 cm 石块已拿成网格，不受影响。"""
    from scipy.ndimage import gaussian_filter
    c = grid_xy(cs, n); X, Y = np.meshgrid(c, c); r = np.hypot(X - MAST_ENU[0], Y - MAST_ENU[1])
    t = np.clip((r - 2.5)/5.0, 0, 1); Z1 = gaussian_filter(Z, 1.0); Z2 = gaussian_filter(Z, 2.5)
    return np.where(t < 0.5, Z + (Z1 - Z)*2*t, Z1 + (Z2 - Z1)*(2*t - 1)).astype(np.float32)


def height_fn():
    """融合后的高度 H(x, y)：MOLA → CTX → HiRISE → 中 → 近，每层在自己外缘 10% 里渐变到下一层。"""
    from scipy.ndimage import map_coordinates
    T = np.load(OUT/"地形.npz"); L = json.loads(str(T["levels"]))
    lv = [("mola", L["MOLA"]), ("ctx", L["CTX"]), ("hirise", L["HiRISE"]), ("mid", L["中"]), ("near", L["近"])]
    grids = {k: T[k] for k, _ in lv}; grids["near"] = near_denoised(near_filled(), *L["近"])
    def H(x, y):
        h = np.zeros_like(x)
        for k, (cs, n) in lv:
            half = cs*n/2; e = np.maximum(np.abs(x), np.abs(y))
            w = np.clip((half*0.98 - e)/(half*0.1), 0, 1)
            m = w > 0
            if not m.any(): continue
            v = map_coordinates(grids[k], [y[m]/cs + n/2 - 0.5, x[m]/cs + n/2 - 0.5], order=3, mode="nearest")
            h[m] = (1 - w[m])*h[m] + w[m]*v if k != "mola" else v
        return h
    return H


def shift_fill(arrs, valid, seed=0, rmin=30, rmax=150, tries=80, chain=True):
    """空洞纹理合成：反复把整张图随机平移（rmin–rmax 格），用平移后有值的格子补当前空洞；arrs 同步平移（颜色与高度细节一起搬）。
    chain=False：只从原本有值的格搬（补出来的格不再当来源）。链式搬运会把一块脏来源（例如印在地上的车）复制成好几份。"""
    rng = np.random.default_rng(seed); v = valid.copy(); v0 = valid.copy(); out = [a.copy() for a in arrs]
    for _ in range(tries):
        if v.all(): break
        r = rng.uniform(rmin, rmax); t = rng.uniform(0, 2*math.pi); oy, ox = int(r*math.sin(t)), int(r*math.cos(t))
        sv = np.roll(v if chain else v0, (oy, ox), (0, 1)); m = ~v & sv
        for o in out: o[m] = np.roll(o, (oy, ox), (0, 1))[m]
        v |= m
    return out, v


def texture_fill(A, ok, cs, seed=0, cell=0.4, sig_lo=0.3, rmin=0.6, rmax=4.0, tries=48):
    """空洞反照率合成（不再整块平移）：A = 低频色 L × 细节 D。
    L：干净格的归一化卷积，σ 0.3 → 1 → 3 → 10 m 逐级补满，所以空洞里的颜色和四周连续。
    D = ln A − ln L 的高频：空洞按 cell 米的格点铺，每个格点随机取一块离它 rmin–rmax 米、几乎全干净的来源，
    像素在相邻 4 个格点之间用平滑权重混合，按 Σw·D/√Σw² 保方差（Heitz–Neyret 2018），没有直缝也不整块重复。"""
    from scipy.ndimage import gaussian_filter, zoom
    rng = np.random.default_rng(seed); H, W = ok.shape; okf = ok.astype(np.float32)
    lnA = np.log(np.maximum(A, 1e-4))
    k = max(1, int(0.05/cs)); h2, w2 = -(-H//k)*k, -(-W//k)*k             # 低频色在 5 cm 粗格上算（σ ≥ 0.3 m，够细），再放大回来
    def coarse(a): return np.pad(a, ((0, h2 - H), (0, w2 - W))).reshape(h2//k, k, w2//k, k).mean((1, 3))
    okc = coarse(okf); Lc = np.zeros((h2//k, w2//k, A.shape[-1]), np.float32); have = np.zeros_like(okc)
    lnc = [coarse(np.where(ok, lnA[..., c], 0)) for c in range(A.shape[-1])]
    for s in (sig_lo, 1.0, 3.0, 10.0):
        den = gaussian_filter(okc, s/(cs*k))
        w = np.clip(den*4, 0, 1)*(1 - have)                            # 每级只补上一级没覆盖的部分
        for c in range(A.shape[-1]): Lc[..., c] += w*gaussian_filter(lnc[c], s/(cs*k))/np.maximum(den, 1e-6)
        have = have + w
    Lc /= np.maximum(have, 1e-6)[..., None]
    L = np.stack([zoom(Lc[..., c], k, order=1)[:H, :W] for c in range(A.shape[-1])], -1)
    Dt = np.where(ok[..., None], lnA - L, 0)                           # 干净格的细节（≈零均值）
    hole = ~ok
    if not hole.any(): return A
    # 格点与来源偏移
    g = max(4, int(cell/cs)); ny, nx = H//g + 2, W//g + 2
    sat = np.pad(okf.cumsum(0).cumsum(1), ((1, 0), (1, 0)))
    def clean_frac(cy, cx):                                            # 以 (cy, cx) 为中心、边长 2g 的窗里干净格比例
        y0 = np.clip(cy - g, 0, H); y1 = np.clip(cy + g, 0, H); x0 = np.clip(cx - g, 0, W); x1 = np.clip(cx + g, 0, W)
        a = np.maximum((y1 - y0)*(x1 - x0), 1)
        return (sat[y1, x1] - sat[y0, x1] - sat[y1, x0] + sat[y0, x0])/a
    GY, GX = np.meshgrid(np.arange(ny)*g, np.arange(nx)*g, indexing='ij')
    best = np.full(GY.shape, -1.0); oy = np.zeros(GY.shape, np.int64); ox = np.zeros(GY.shape, np.int64)
    for _ in range(tries):
        r = rng.uniform(rmin, rmax, GY.shape)/cs; t = rng.uniform(0, 2*math.pi, GY.shape)
        dy = (r*np.sin(t)).astype(np.int64); dx = (r*np.cos(t)).astype(np.int64)
        f = clean_frac(np.clip(GY + dy, 0, H - 1), np.clip(GX + dx, 0, W - 1))
        f = f + rng.uniform(0, 0.02, f.shape)                          # 同样干净时随机挑，免得相邻格点挑到同一块
        b = f > best; best[b] = f[b]; oy[b] = dy[b]; ox[b] = dx[b]
    I, J = np.nonzero(hole); out = np.zeros((len(I), A.shape[-1]), np.float32); wsum2 = np.zeros(len(I), np.float32)
    fy, fx = I/g, J/g; iy, ix = np.floor(fy).astype(np.int64), np.floor(fx).astype(np.int64); uy, ux = fy - iy, fx - ix
    for ky, wy in ((0, 1 - uy), (1, uy)):
        for kx, wx in ((0, 1 - ux), (1, ux)):
            w = (np.sin(0.5*math.pi*wy)**2*np.sin(0.5*math.pi*wx)**2).astype(np.float32)   # 平滑、四个加起来为 1
            ny_, nx_ = iy + ky, ix + kx
            sy = np.clip(I + oy[ny_, nx_], 0, H - 1); sx = np.clip(J + ox[ny_, nx_], 0, W - 1)
            out += w[:, None]*Dt[sy, sx]; wsum2 += w*w
    D = out/np.sqrt(np.maximum(wsum2, 1e-6))[:, None]
    res = A.copy(); res[I, J] = np.exp(L[I, J] + D)
    return res


def near_filled():
    """近层高程：没测到的格（车底、车尾挡住的地方）用 shift-fill 搬邻近地面的细节（高通，5 cm 以下）叠到平滑补值上。"""
    from scipy.ndimage import gaussian_filter
    path = OUT/"地形_近补.npy"; src = OUT/"地形_近石.npy"                  # 石块步骤的输出（背面已补、大石已移走）优先
    deps = [OUT/"地形.npz"] + ([src] if src.exists() else [])
    if path.exists() and path.stat().st_mtime > max(d.stat().st_mtime for d in deps): return np.load(path)
    T = np.load(OUT/"地形.npz"); W = T["near_w"]
    Z = np.load(src) if src.exists() else T["near"]
    if src.exists(): W = np.where(np.load(src) != T["near"], 1, W)            # 补过背面的格也算有值
    hp = Z - gaussian_filter(Z, 2.5)
    (hpf,), _ = shift_fill([hp], W > 0, seed=1)
    Zf = np.where(W > 0, Z, Z + hpf)
    Zf = wheel_contacts(Zf, W > 0).astype(np.float32); np.save(path, Zf); return Zf


def wheel_contacts(Z, has, sink=0.01, r_disc=0.06):
    """车底没测到的地面要过六个车轮的触地点：车停在六个轮子上。平滑补值不知道这一点，车尾会悬空 15 cm
    （前轮 0、中轮 8、后轮 15 cm）。触地点＝NASA 模型按桅杆位姿摆好后每个轮子的最低点（车轮触地.json），轮子陷 1 cm。
    修正量 δ 只加在没测到的格上：测到的格 δ = 0，触地圆盘（半径 6 cm）δ = 触地高 − 补值，其余格调和插值（拉普拉斯 = 0）。"""
    import scipy.sparse as sp, scipy.sparse.linalg as spl
    from scipy.ndimage import label
    f = DIR/"车轮触地.json"
    if not f.exists(): return Z
    cs, n = LEVELS["近"]; c = grid_xy(cs, n)
    fix = np.zeros_like(has); val = np.zeros(Z.shape)
    for x, y, z in json.loads(f.read_text())["触地点"]:
        i0, j0 = int(round(y/cs + n/2 - 0.5)), int(round(x/cs + n/2 - 0.5)); rr = int(r_disc/cs) + 1
        J, I = np.meshgrid(np.arange(j0 - rr, j0 + rr + 1), np.arange(i0 - rr, i0 + rr + 1))
        m = (np.hypot(c[J] - x, c[I] - y) <= r_disc) & ~has[I, J]
        fix[I[m], J[m]] = True; val[I[m], J[m]] = z + sink - Z[I[m], J[m]]
    lab, _ = label(~has); ids = np.unique(lab[fix]); ids = ids[ids > 0]
    U = np.isin(lab, ids) & ~fix                                            # 未知：含触地点的空洞里、非圆盘的格
    if not U.any(): return Z
    idx = -np.ones(Z.shape, np.int64); idx[U] = np.arange(U.sum())
    I, J = np.nonzero(U); rows, cols, b = [], [], np.zeros(len(I)); dg = np.zeros(len(I))
    for di, dj in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        I2, J2 = np.clip(I + di, 0, n - 1), np.clip(J + dj, 0, n - 1)
        dg += 1; k = idx[I2, J2]; inn = k >= 0
        rows.append(np.arange(len(I))[inn]); cols.append(k[inn])
        b += np.where(inn, 0.0, np.where(fix[I2, J2], val[I2, J2], 0.0))    # 邻居是测到的格 → δ = 0
    A = sp.csr_matrix((np.concatenate([-np.ones(sum(len(r) for r in rows)), dg]),
                       (np.concatenate(rows + [np.arange(len(I))]), np.concatenate(cols + [np.arange(len(I))]))), shape=(len(I),) * 2)
    d = np.where(fix, val, 0.0); d[U] = spl.spsolve(A.tocsc(), b)
    log(f"车轮触地：修正 {U.sum() + fix.sum():,} 格，触地点原来离补值 {np.abs(val[fix]).max()*100:.0f} cm 以内")
    return Z + d


def srgb8(a):
    a = np.clip(a, 0, 1); return (np.where(a <= 0.0031308, a*12.92, 1.055*a**(1/2.4) - 0.055)*255 + 0.5).astype(np.uint8)


import functools


@functools.lru_cache(maxsize=4096)
def golombek_n(k, D1, D2, nD=40):
    """Golombek & Rapp 1997：累计覆盖率 F(D) = k·e^(−qD)，q = 1.79 + 0.152/k → 单位面积 [D1, D2) 内的石块数，以及按数目分布的 D 抽样表。"""
    q = 1.79 + 0.152/max(k, 1e-4)
    D = np.geomspace(D1, D2, nD); nd = k*q*np.exp(-q*D)/(math.pi*D*D/4)    # 每平方米、每米直径
    cdf = np.concatenate([[0], np.cumsum(0.5*(nd[1:] + nd[:-1])*np.diff(D))])
    return cdf[-1], D, cdf/max(cdf[-1], 1e-12)


def scatter_rocks(H, K, k_cls, zones, seed=7):
    """统计撒石（确定性：每格按格号播种，Godot 运行时可同法复现）。zones：[(r0, r1, 格边长 m, D_min(r), D_max)]。"""
    from scipy.ndimage import map_coordinates
    Ph = K["hirise"].astype(np.float32); cs_h, n_h = float(K["cs_hi"]), int(K["n_hi"])
    out = []
    for r0, r1, cell, dmin_f, dmax in zones:
        g = np.arange(-r1, r1, cell) + cell/2; X, Y = np.meshgrid(g, g)
        rr = np.hypot(X, Y); m = (rr >= r0) & (rr < r1); X, Y, rr = X[m], Y[m], rr[m]
        P = np.stack([map_coordinates(Ph[..., c_], [Y/cs_h + n_h/2 - 0.5, X/cs_h + n_h/2 - 0.5], order=1, mode="nearest") for c_ in range(4)], -1)
        for ci in range(len(X)):
            d1 = round(max(dmin_f(rr[ci]), 0.05), 2)
            if d1 >= dmax: continue
            lam = 0.0; tabs = []
            for c_ in range(4):
                if k_cls[c_] <= 0 or P[ci, c_] <= 0.01: continue
                N_, D_, cdf = golombek_n(round(float(k_cls[c_]), 4), d1, float(dmax)); lam += P[ci, c_]*N_*cell*cell; tabs.append((P[ci, c_]*N_, D_, cdf))
            if lam <= 0: continue
            rng = np.random.default_rng(hash((seed, int(round(X[ci]*10)), int(round(Y[ci]*10)))) & 0xFFFFFFFF)
            cnt = rng.poisson(lam)
            if not cnt: continue
            wts = np.array([t[0] for t in tabs]); wts /= wts.sum()
            for _ in range(cnt):
                t = tabs[rng.choice(len(tabs), p=wts)]; D = float(np.interp(rng.random(), t[2], t[1]))
                x = X[ci] + (rng.random() - 0.5)*cell; y = Y[ci] + (rng.random() - 0.5)*cell
                out.append((x, y, D, rng.random()*2*math.pi, int(rng.integers(1 << 30)), rng.uniform(0.35, 0.7)))
    a = np.array(out, np.float32).reshape(-1, 6)
    if len(a): a = np.concatenate([a[:, :2], H(a[:, 0].astype(np.float64), a[:, 1].astype(np.float64))[:, None].astype(np.float32), a[:, 2:]], 1)
    return a                                                               # x, y, z地面, D, 偏航, 种子, 高宽比


def despeckle(A, cs, win_m=0.07, t=0.12, k=0.25):
    """去斑：照片里低于高程分辨率的小卵石，向阳面亮、背阴面暗，去光照时除不掉，会作为"本色"烘进反照率；
    换个太阳方向重打光，就成了不跟光走的亮点、黑点（像撒了碎玻璃）。这里以 win_m 窗口的局部中位亮度为参照，
    把偏离超过 ±t（对数）的部分压到 k 倍。只等比缩放亮度，不动色相；比窗口大的真实颜色变化不受影响。"""
    from scipy.ndimage import median_filter
    L = A.mean(-1); w = max(3, int(round(win_m/cs))) | 1
    lr = np.log(np.maximum(L, 1e-5)/np.maximum(median_filter(L, w), 1e-5))
    T = math.log(1 + t); m = np.abs(lr) > T
    lc = np.where(m, np.sign(lr)*(T + (np.abs(lr) - T)*k), lr)
    log(f"  去斑：窗口 {w} 格，压了 {m.mean()*100:.1f}% 的格（亮 {(lr > T).mean()*100:.1f}%、暗 {(lr < -T).mean()*100:.1f}%）")
    return (A*np.exp(lc - lr)[..., None]).astype(A.dtype)


def export():
    from PIL import Image
    from scipy.ndimage import gaussian_filter, uniform_filter
    Image.MAX_IMAGE_PIXELS = None
    H = height_fn(); EX = OUT/"导出"; EX.mkdir(exist_ok=True)
    h0, e0 = RING0; rings = {}; nq = 0
    for k in range(NRING):
        h, half = h0*2**k, e0*2**k
        c = np.arange(-half, half + h/2, h); n = len(c)
        X, Y = np.meshgrid(c, c)
        Z = H(X.ravel(), Y.ravel()).reshape(n, n)
        if k < NRING - 1:                                                  # 外边与下一环相接：奇数点取两侧平均（下一环没有它们）
            for edge in (Z[0], Z[-1], Z[:, 0], Z[:, -1]):
                edge[1:-1:2] = 0.5*(edge[0:-2:2] + edge[2::2])
        i, j = np.meshgrid(np.arange(n - 1), np.arange(n - 1), indexing="ij")
        cx, cy = (c[:-1] + h/2)[j], (c[:-1] + h/2)[i]
        keep = ~((np.abs(cx) < half/2) & (np.abs(cy) < half/2)) if k else np.ones_like(cx, bool)
        i, j = i[keep], j[keep]
        F = np.stack([i*n + j, i*n + j + 1, (i + 1)*n + j + 1, (i + 1)*n + j], -1).reshape(-1, 4)
        used = np.unique(F); remap = -np.ones(n*n, np.int64); remap[used] = np.arange(used.size)
        V = np.stack([X.ravel()[used], Y.ravel()[used], Z.ravel()[used]], 1).astype(np.float32)
        rings[f"V{k}"] = V; rings[f"F{k}"] = remap[F].astype(np.int32); nq += len(F)
        log(f"  环 {k}：格 {h*100:.0f} cm、±{half:.0f} m，{len(F):,} 面")
    np.savez_compressed(EX/"地面网格.npz", **rings, nring=NRING)
    log(f"地面网格 {nq:,} 面 → 导出/地面网格.npz")
    # 反照率贴图：sRGB 8 位 PNG（Blender 当颜色读进来自动转线性）；近/中带 alpha＝覆盖可信度（羽化）
    tex = {}
    for lv in ("近", "中", "HiRISE", "CTX"):
        z = np.load(OUT/f"反照率_{lv}.npz"); A = z["A"].astype(np.float32); cs, n = float(z["cs"]), int(z["n"])
        if lv in ("近", "中"):                                             # Mastcam-Z（更细、更准的色）＋ Navcam 打底
            A, has_, cs, n = best_albedo(lv)
            c = grid_xy(cs, n); X, Y = np.meshgrid(c, c)
            has_ &= (A.max(-1) > 1e-4) & ~fabricate_zone(X, Y); del X, Y      # 车底＋外沿、机械臂残影：当空洞重新合成（照片里印着车和臂）
            dens = uniform_filter(has_.astype(np.float32), max(3, int(0.07/cs)) | 1)
            has_ &= dens >= 0.6                                            # 零星孤点（远处溅射的散格）也当空洞，否则补完成点阵花纹
            z = dict(cov=has_.astype(np.float32))
        if "cov" in z:
            cov = z["cov"]                                                 # 近/中的 cov 是 0/1 掩膜：第 5 百分位＝1，「> 1」会全判空洞
            ok = cov > (0.5 if lv in ("近", "中") else np.percentile(cov[cov > 0], 5))
            rmax = (4.0 if lv == "近" else 1.5)/cs                          # 车底约 3 m 宽，近层要搬远一点
            if lv in ("近", "中"):                                       # 低频色平滑补 × 小块随机细节保方差混合（不整块平移：会有直缝和成排的复制）
                A = texture_fill(A, ok, cs, seed=2, rmax=rmax*cs)
                if "--不去斑" not in sys.argv: A = despeckle(A, cs)
            else:
                (A,), _ = shift_fill([A], ok, seed=2, rmin=0.3/cs, rmax=rmax, tries=200)
            a = gaussian_filter(ok.astype(np.float32), (0.5 if lv == "近" else 1.5)/cs)
            a = np.clip(a*2 - 0.5, 0, 1)
            if lv == "近":                                                 # 车底：照片里没有，下一层（HiRISE）又太糊 → 用补出来的纹理
                c = grid_xy(cs, n); X, Y = np.meshgrid(c, c)
                a = np.maximum(a, gaussian_filter(fabricate_zone(X, Y).astype(np.float32), 0.3/cs))
            rgba = np.concatenate([srgb8(A), (a*255 + 0.5).astype(np.uint8)[..., None]], -1)
            Image.fromarray(np.flipud(rgba), "RGBA").save(EX/f"反照率_{lv}.png", optimize=False)
        else:
            Image.fromarray(np.flipud(srgb8(A)), "RGB").save(EX/f"反照率_{lv}.png", optimize=False)
        tex[lv] = dict(file=f"反照率_{lv}.png", half=cs*n/2)
        if lv == "CTX": tex["底色"] = np.nanmedian(A.reshape(-1, 3), 0).tolist()
        log(f"  反照率_{lv}.png：{n}²，±{cs*n/2:.0f} m")
    # 地类权重（RGBA＝沙、砾石风化层、基岩、暗色岩块）：中景 4 cm、HiRISE 25 cm
    K = np.load(OUT/"地类.npz")
    Pm = K["mid"].astype(np.float32); csk, nk = float(K["cs_mid"]), int(K["n_mid"])
    Pm2 = Pm[:nk//2*2, :nk//2*2].reshape(nk//2, 2, nk//2, 2, 4).mean((1, 3)); valid = (Pm2 >= 0).all(-1)
    Pm2 = np.where(valid[..., None], Pm2, 0)
    Image.fromarray(np.flipud(np.concatenate([(Pm2*255 + 0.5).astype(np.uint8)[..., :3], ((Pm2[..., 3:]*255 + 0.5).astype(np.uint8))], -1)), "RGBA").save(EX/"地类_中.png")
    Ph = K["hirise"].astype(np.float32)
    Image.fromarray(np.flipud((Ph*255 + 0.5).astype(np.uint8)), "RGBA").save(EX/"地类_HiRISE.png")
    tex["地类_中"] = dict(file="地类_中.png", half=csk*nk/2); tex["地类_HiRISE"] = dict(file="地类_HiRISE.png", half=float(K["cs_hi"])*int(K["n_hi"])/2)
    log(f"  地类权重：中 {nk//2}²、HiRISE {int(K['n_hi'])}²")
    # 细节材质：反照率细节（均值 1，存 0.5×）、高度（16 位，±量程）
    D = np.load(OUT/"细节材质.npz"); det = {}
    for k in range(4):
        for kind, key, px in (("微观", f"micro{k}_0", float(D["micro_px"])), ("中观", f"meso{k}", float(D["meso_px"]))):
            if f"{key}_A" not in D: continue
            if f"{key}_px" in D: px = float(D[f"{key}_px"])                # 素材库样块各有各的像素
            a = D[f"{key}_A"].astype(np.float32); hgt = D[f"{key}_H"].astype(np.float32)
            rng_ = float(np.percentile(np.abs(hgt), 99.5))*1.2 + 1e-6
            Image.fromarray((np.clip(a*0.5, 0, 1)*255 + 0.5).astype(np.uint8), "RGB").save(EX/f"细节_{kind}_{k}_反照率.png")
            Image.fromarray(((np.clip(hgt/rng_, -1, 1)*0.5 + 0.5)*65535 + 0.5).astype(np.uint16)).save(EX/f"细节_{kind}_{k}_高度.png")
            det[f"{kind}_{k}"] = dict(albedo=f"细节_{kind}_{k}_反照率.png", height=f"细节_{kind}_{k}_高度.png",
                                      size=px*a.shape[0], height_range=rng_)
    log(f"  细节材质 {len(det)} 套")
    # 石块：实测（含补背面）网格 + 统计撒石实例
    R = np.load(OUT/"石块.npz"); inst = json.loads(str(R["inst"]))
    A_n, has_n, cs_a, n_a = best_albedo("近")
    rock_cols = []
    for i, r in enumerate(inst):
        x, y = r["pos"][0], r["pos"][1]; rr = max(r["D"]/3, 0.03)
        m = np.ix_(np.abs(grid_xy(cs_a, n_a) - y) < rr, np.abs(grid_xy(cs_a, n_a) - x) < rr)
        rock_cols.append(np.median(A_n[m].reshape(-1, 3), 0).tolist())
    rk = dict(np.load(OUT/"石块.npz"))
    k_cls = np.array([0.01, 0.05, 0.08, 0.15])                              # 各地类 Golombek k（沙少、暗色岩块多），按近景实测总量定标
    k_meas = sum(math.pi*(r["D"]/2)**2 for r in inst)/(LEVELS["近"][0]*LEVELS["近"][1])**2
    Pn = Pm[(nk - int(20/csk))//2:(nk + int(20/csk))//2, (nk - int(20/csk))//2:(nk + int(20/csk))//2]
    w_near = np.nanmean(np.where(Pn >= 0, Pn, np.nan).reshape(-1, 4), 0)
    F15 = lambda k: k*math.exp(-(1.79 + 0.152/k)*0.15)                      # ≥15 cm 的覆盖率
    for _ in range(30):                                                    # 整体缩放 k_cls 使近景 ≥15 cm 覆盖率等于实测
        pred = float(np.sum(w_near*np.array([F15(k) for k in k_cls])))
        k_cls *= (k_meas/max(pred, 1e-6))**0.5
    zones = [(20.0, 50.0, 1.0, lambda r: 0.05, 0.30),                       # 中景：立体 10 cm 看得出 ≥30 cm，补 5–30 cm
             (50.0, 1000.0, 5.0, lambda r: 0.0015*r, 1.5)]                   # HiRISE 区：补到 1.5 m；最小尺寸随距离（≈1.5 像素）
    S = scatter_rocks(height_fn(), K, k_cls, zones)
    np.savez_compressed(EX/"石块.npz", **{k_: v for k_, v in rk.items()}, colors=np.array(rock_cols, np.float32), scatter=S, k_cls=k_cls)
    log(f"  石块：实测网格 {len(inst)} 块；各地类 k = {np.round(k_cls, 3)}；统计撒石 {len(S):,} 块")
    # 对照：真照片去畸变成针孔（1280×960、主点居中），Blender 放同参数的相机渲同一画面
    M = m55(); cams = {c["file"]: c for c in json.loads((OUT/"相机.json").read_text())}
    refs = []
    for pat in VALIDATE:
        f = next((k for k in sorted(cams) if pat in k), None)
        if f is None: continue
        c = cams[f]; img = np.asarray(Image.open(PDS/c["dir"]/f.replace(".obj", ".png")).convert("RGB")).astype(np.float32)
        Wp, Hp, fp = img.shape[1]//4, img.shape[0]//4, c["f"]/4                # 有的照片是子帧
        yy, xx = np.mgrid[0:Hp, 0:Wp]
        d = np.stack([(xx + 0.5 - Wp/2)/fp, (yy + 0.5 - Hp/2)/fp, np.ones_like(xx, float)], -1).reshape(-1, 3)
        u, v, _ = M.kb_project(d, c["f"], c["cx"], c["cy"], c["k"]); u -= 0.5; v -= 0.5
        ok = (u >= 0) & (v >= 0) & (u < img.shape[1] - 1) & (v < img.shape[0] - 1)
        out = np.zeros((Wp*Hp, 3), np.float32)
        i0 = np.floor(v[ok]).astype(int); j0 = np.floor(u[ok]).astype(int); fy = (v[ok] - i0)[:, None]; fx = (u[ok] - j0)[:, None]
        out[ok] = img[i0, j0]*(1 - fy)*(1 - fx) + img[i0 + 1, j0]*fy*(1 - fx) + img[i0, j0 + 1]*(1 - fy)*fx + img[i0 + 1, j0 + 1]*fy*fx
        name = f"对照_{f[:4]}{f[18:27]}.png"
        Image.fromarray(out.reshape(Hp, Wp, 3).clip(0, 255).astype(np.uint8)).save(EX/name)
        R = np.array(c["R"])
        refs.append(dict(file=f, png=name, W=Wp, H=Hp, f=fp, C=to_enu(np.array(c["C"])).tolist(),
                         right=(R[0] @ M_SB).tolist(), down=(R[1] @ M_SB).tolist(), fwd=(R[2] @ M_SB).tolist(),
                         sun=c["sun_all"][-1], ltst=c.get("ltst")))
        log(f"  对照 {name}（LTST {c.get('ltst')}）")
    (EX/"场景.json").write_text(json.dumps(dict(tex=tex, detail=det, classes=CLASSES, mast=MAST_ENU.tolist(), lat=LAT, lon=LON, E0=E0,
                                                rings=NRING, o_ll=O_LL.tolist(), refs=refs,
                                                data_res={"近": 0.01, "中": 0.02, "HiRISE": 0.25, "CTX": 20.0}), indent=1, ensure_ascii=False))
    log("导出 ✓")


if __name__ == "__main__":
    step = sys.argv[1] if len(sys.argv) > 1 else "地形"
    if step == "Mastcam": mastcam_albedo(int(sys.argv[2]) if len(sys.argv) > 2 else None)
    else: {"相机": cameras, "地形": terrain, "反照率": albedo, "远景": far_albedo, "导出": export, "地类": classify, "石块": rocks, "细节": details}[step]()
