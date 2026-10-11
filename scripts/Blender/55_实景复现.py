"""
实景复现：NASA PDS 毅力号一站（默认 sol 530，耶泽罗三角洲前缘，站点 26 / 行驶 1222）→ Blender 三维场景，相机放回桅杆。
做法＝投影贴图（ground-projected environment / OnSight 式）：
  世界＝NASA 自己拼的 360° Navcam 彩色镶嵌（mars2020_navcam_ops_mosaic，XRZS 柱面）；
  几何＝XYZ 镶嵌做的近景深度网格（1–9 m，一圈）＋ 当天的 Navcam 网格（ops_mesh，臂前方向到 110 m）＋ 地面代理高度场；
  上色＝从镶嵌投影中心把同一张全景投到所有几何上 → 从桅杆看与 NASA 原图逐像素一致，挪开相机有真实视差。
  局限：NASA 的 XYZ 把车体、机械臂遮掉了，它们没有深度，挪开相机时会印在地上；镶嵌 0.0775°/像素，比原照片糊 4 倍。
  ① 标定（venv，仅「照片」旧做法与相机朝向要）：网格顶点 ↔ 照片像素 → Kannala–Brandt 鱼眼相机 → 相机.json、全景.npy
  ①′ 镶嵌（venv）：镶嵌/ 下的 XRZS、XXYZ → 全景_镶嵌.npy、地面.npz、近景.npz、镶嵌.json
  ② 搭建（Blender）：.venv/bin/python scripts/Blender/55_实景复现.py 镶嵌
                     blender --online-mode -P scripts/Blender/55_实景复现.py -- 搭建        # 开界面看（或 -b … 搭建 渲染）
数据：NASA/JPL-Caltech，PDS Imaging Node（mars2020_navcam_ops_mesh、mars2020_navcam_ops_mosaic）。
"""
import json, math, pathlib, sys
import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
MAP = HERE.parent.parent
SOL = 530
DIR = MAP/"DEM"/"Blender缓存"/"_素材"/"PDS"/f"sol{SOL:04d}"
PANO = (8192, 4096)                           # 全景：0.044°/像素（Navcam 约 0.019°）
GROUND = -2.55                                # 桅杆头下方地面（Blender z，米；网格量出）
M_SB = np.array([[0, 1, 0], [1, 0, 0], [0, 0, -1]], float)   # 站点（北、东、下）→ Blender（东、北、上），行列式 +1


def log(*a): print("[55]", *a, flush=True)


def read_obj(path):
    """→ 顶点 (n,3)、每个「顶点/纹理」对的 (vi, ti)、纹理坐标 (m,2)、面 (k,3,2)。"""
    v, vt, f = [], [], []
    with open(path) as fh:
        for l in fh:
            if l.startswith("v "): v.append(l.split()[1:4])
            elif l.startswith("vt "): vt.append(l.split()[1:3])
            elif l.startswith("f "): f.append([t.split("/")[:2] for t in l.split()[1:4]])
    return np.array(v, float), np.array(vt, float), np.array(f, int) - 1


# ── ① 标定 ─────────────────────────────────────────────────────────
def rq3(A):
    """3×3 RQ 分解（K 上三角、对角为正）。"""
    P_ = np.flipud(np.eye(3))
    Q, Rm = np.linalg.qr((P_ @ A).T)
    K = P_ @ Rm.T @ P_; R = P_ @ Q.T
    S = np.diag(np.sign(np.diag(K))); return K @ S, S @ R


def kb_project(Xc, f, cx, cy, k):
    """Kannala–Brandt 鱼眼投影（广角相机的标准模型；Navcam 视场约 96°×73°，针孔 + 径向多项式到边上差几百像素）：
    θ＝光线与光轴夹角，r＝f(θ + k1θ³ + k2θ⁵ + k3θ⁷)。Xc：相机坐标（z 朝前）。"""
    rho = np.hypot(Xc[:, 0], Xc[:, 1]); th = np.arctan2(rho, Xc[:, 2])
    r = f*(th + k[0]*th**3 + k[1]*th**5 + k[2]*th**7)
    s_ = np.where(rho > 1e-12, r/np.maximum(rho, 1e-12), f/np.maximum(Xc[:, 2], 1e-12))
    return cx + Xc[:, 0]*s_, cy + Xc[:, 1]*s_, th


def calibrate_one(path, W, H, init=None):
    """DLT（画面中心的点，针孔）给初值 → 全幅非线性最小二乘（位置 3、朝向 3、焦距、主点 2、畸变 3），soft-L1 抗离群。"""
    from scipy.optimize import least_squares
    from scipy.spatial.transform import Rotation as Rot
    V, T, F = read_obj(path)
    pairs = np.unique(F.reshape(-1, 2), axis=0)                           # (vi, ti)
    X = V[pairs[:, 0]]; uv = T[pairs[:, 1]]
    u = uv[:, 0]*W; v = (1 - uv[:, 1])*H                                  # OBJ 的 v 从下往上
    f0 = W/2; xo = (u - W/2)/f0; yo = (v - H/2)/f0
    rng = np.random.default_rng(0)
    for rc in (0.35, 0.5, 0.7):                                            # 中心点太少就放宽
        idx = np.flatnonzero(np.hypot(xo, yo) < rc)
        if len(idx) > 2000: break
    if len(idx) < 200: return None
    idx = rng.choice(idx, min(20000, len(idx)), replace=False)
    m = X[idx].mean(0); s = np.abs(X[idx] - m).mean()
    Xh = np.c_[(X[idx] - m)/s, np.ones(len(idx))]; z = np.zeros((len(idx), 4))
    A = np.vstack([np.c_[Xh, z, -xo[idx, None]*Xh], np.c_[z, Xh, -yo[idx, None]*Xh]])
    Pn = np.linalg.svd(A, full_matrices=False)[2][-1].reshape(3, 4)        # full_matrices=False：别生成 4 万×4 万的 U
    Tn = np.diag([1/s, 1/s, 1/s, 1.0]); Tn[:3, 3] = -m/s
    Ti = np.array([[f0, 0, W/2], [0, f0, H/2], [0, 0, 1]])
    P = Ti @ Pn @ Tn
    K, R = rq3(P[:, :3]); K /= K[2, 2]
    if np.linalg.det(R) < 0: R = -R
    C = -np.linalg.solve(P[:, :3], P[:, 3])
    fit = rng.choice(len(X), min(30000, len(X)), replace=False)
    Xf, uf, vf = X[fit], u[fit], v[fit]
    def resid(q):
        Rm = Rot.from_rotvec(q[:3]).as_matrix()
        pu, pv, _ = kb_project((Xf - q[3:6]) @ Rm.T, q[6], q[7], q[8], q[9:12])
        return np.r_[pu - uf, pv - vf]
    q0 = np.r_[Rot.from_matrix(R).as_rotvec(), C, 0.5*(K[0, 0] + K[1, 1]), W/2, H/2, 0, 0, 0]
    if init is not None:                                                   # 同一只眼已标好的相机：内参、位置当初值（朝向仍用 DLT）
        q0[3:6] = init["C"]; q0[6:9] = (init["f"], init["cx"], init["cy"]); q0[9:12] = init["k"]
    sol = least_squares(resid, q0, loss="soft_l1", f_scale=3.0, x_scale="jac", max_nfev=200)
    q = sol.x; Rm = Rot.from_rotvec(q[:3]).as_matrix()
    pu, pv, th = kb_project((X - q[3:6]) @ Rm.T, q[6], q[7], q[8], q[9:12])
    err = np.hypot(pu - u, pv - v)
    return dict(file=path.name, W=W, H=H, R=Rm.tolist(), C=q[3:6].tolist(), f=float(q[6]), cx=float(q[7]), cy=float(q[8]),
                k=q[9:12].tolist(), thmax=float(np.percentile(th, 99.5)),
                err_med=float(np.median(err)), err_90=float(np.percentile(err, 90)))


def project(cam, d_site):
    """站点坐标里的方向（远处）→ 照片像素 (u, v)、离光轴的相对角（羽化用）、是否有效。"""
    R = np.array(cam["R"])
    xc = d_site @ R.T
    pu, pv, th = kb_project(xc, cam["f"], cam["cx"], cam["cy"], cam["k"])
    return pu, pv, th/cam["thmax"], (xc[:, 2] > -0.2) & (th < cam["thmax"])


def srgb_to_lin(c): return np.where(c <= 0.04045, c/12.92, ((c + 0.055)/1.055)**2.4)


def calibrate():
    from PIL import Image
    Image.MAX_IMAGE_PIXELS = None
    cams = []
    for p in sorted(DIR.glob("N*.obj")):
        W, H = Image.open(p.with_suffix(".png")).size
        c = calibrate_one(p, W, H)
        if c is None: log(f"{p.name[:30]}… 画面里几乎没有网格点，跳过"); continue
        cams.append(c)
        log(f"{p.name[:30]}… 相机 {np.round(c['C'], 2)}，重投影误差 中位 {c['err_med']:.1f} px、90% {c['err_90']:.1f} px")
    for i, c in enumerate(cams):                                           # 掉进局部最优的：拿同一只眼误差最小的那台当初值重来
        if c["err_90"] <= 8: continue
        good = [g for g in cams if g["file"][:2] == c["file"][:2] and g["err_90"] <= 8]
        if not good: continue
        ref = min(good, key=lambda g: g["err_med"])
        p = DIR/c["file"]; c2 = calibrate_one(p, c["W"], c["H"], init=ref)
        if c2 and c2["err_med"] < c["err_med"]:
            cams[i] = c2; log(f"{p.name[:30]}… 重标：误差 中位 {c2['err_med']:.1f} px、90% {c2['err_90']:.1f} px")
    O = np.median([c["C"] for c in cams if c["err_90"] <= 8], 0)           # 桅杆头（各次指向的相机中心中位）
    (DIR/"相机.json").write_text(json.dumps(dict(origin=O.tolist(), cams=cams), indent=1))
    log(f"桅杆头（站点坐标）{np.round(O, 2)}")
    # 全景：Blender 的等距柱面约定 u = −atan2(y, x)/2π + 0.5，v = atan2(z, √(x²+y²))/π + 0.5；第 0 行＝天顶
    Wp, Hp = PANO
    acc = np.zeros((Hp, Wp, 3), np.float32); wsum = np.zeros((Hp, Wp), np.float32)
    for cam in cams:
        if cam["err_90"] > 8: log(f"  {cam['file'][:30]} 误差大，不进全景"); continue
        img = np.asarray(Image.open(DIR/cam["file"].replace(".obj", ".png")).convert("RGB"))
        Hh, Ww = img.shape[:2]
        for r0 in range(0, Hp, 256):                                      # 分条算，省内存
            rows = np.arange(r0, min(r0 + 256, Hp))
            el = (0.5 - (rows + 0.5)/Hp)*math.pi
            az = (0.5 - (np.arange(Wp) + 0.5)/Wp)*2*math.pi                 # = atan2(y, x)
            EL, AZ = np.meshgrid(el, az, indexing="ij")
            db = np.stack([np.cos(EL)*np.cos(AZ), np.cos(EL)*np.sin(AZ), np.sin(EL)], -1).reshape(-1, 3)
            u, v, rn, ok = project(cam, db @ M_SB)                           # Blender 方向 → 站点方向（M 是正交阵，转置即逆；这里行向量右乘 M）
            ok &= (u >= 0) & (u < Ww - 1) & (v >= 0) & (v < Hh - 1)
            if not ok.any(): continue
            i0 = np.floor(v[ok]).astype(int); j0 = np.floor(u[ok]).astype(int); fy = v[ok] - i0; fx = u[ok] - j0
            c = (img[i0, j0]*((1 - fy)*(1 - fx))[:, None] + img[i0 + 1, j0]*(fy*(1 - fx))[:, None]
                 + img[i0, j0 + 1]*((1 - fy)*fx)[:, None] + img[i0 + 1, j0 + 1]*(fy*fx)[:, None])/255.0
            w = np.clip(1 - rn[ok], 0, 1) + 1e-3                             # 离光轴越近越好
            fl = np.flatnonzero(ok)
            a_ = acc[r0:r0 + len(rows)].reshape(-1, 3); w_ = wsum[r0:r0 + len(rows)].reshape(-1)
            win = w > w_[fl]                                                 # 只取最靠近画面中心的那张：机械臂各张位置不同，平均会叠出重影
            a_[fl[win]] = srgb_to_lin(c[win]); w_[fl[win]] = w[win]
        log(f"  全景 ← {cam['file'][:30]}")
    pano = acc
    pano[wsum < 1e-6] = srgb_to_lin(np.array([0.80, 0.70, 0.60]))           # 没拍到的方向：火星天色
    np.save(DIR/"全景.npy", pano.astype(np.float16))
    log(f"全景 {Wp}×{Hp}，覆盖 {(wsum > 0).mean()*100:.0f}% → 全景.npy")


# ── ①′ NASA 镶嵌（推荐）─────────────────────────────────────────────────
MOS = DIR/"镶嵌"
MOS_RGB = "N_LRGB_0533XRZS_0261222_CYL_L_AUTOGENJ01"                     # 辐射校正彩色，柱面，左眼
MOS_XYZ = "N_LRGB_0532XXYZ_0261222_CYL_L_AUTOGENJ01"                     # 同一投影下逐像素的站点坐标
GRID = (0.25, 1024)                                                      # 地面代理：0.25 m 格、±128 m


def read_mosaic(name, dtype):
    """PDS4 标签 → (波段, 行, 列) 数组 + 柱面投影参数（像素/度、零仰角行、投影原点：LOCAL_LEVEL → 站点）。"""
    import re
    x = (MOS/f"{name}.xml").read_text()
    arr = x[x.index("<Array_3D_Image>"):]
    off = int(re.search(r'<offset unit="byte">(\d+)', arr).group(1))
    n = [int(v) for v in re.findall(r"<elements>(\d+)</elements>", arr)[:3]]
    sc = float(re.search(r"<scaling_factor>([-\d.eE+]+)", arr).group(1)) if "<scaling_factor>" in arr else 1.0
    a = np.fromfile(MOS/f"{name}.IMG", dtype, offset=off, count=n[0]*n[1]*n[2]).reshape(n).astype(np.float32)*sc
    cyl = x[x.index("<cart:Cylindrical>"):x.index("</cart:Cylindrical>")]
    g = lambda k, s=cyl: float(re.search(rf"<cart:{k}[^>]*>([-\d.eE+]+)<", s).group(1))
    ll = x[x.index("<local_identifier>LOCAL_LEVEL_FRAME"):]
    ll = ll[ll.index("<geom:Vector_Origin_Offset>"):ll.index("</geom:Vector_Origin_Offset>")]
    G = lambda k: float(re.search(rf"<geom:{k}[^>]*>([-\d.eE+]+)<", ll).group(1))
    O = np.array([G("x_position"), G("y_position"), G("z_position")]) + \
        np.array([g("x_position"), g("y_position"), g("z_position")])     # 投影原点（站点坐标）
    return a, dict(scale=g("pixel_scale_x"), z0=g("zero_elevation_line"), origin=O.tolist())


def push_pull(z, w, levels=10):
    """带权补洞（Gortler 1996 Lumigraph 的 push-pull）：逐级 2×2 加权下采样，再逐级上采样只填空洞。"""
    from scipy.ndimage import zoom
    if levels == 0 or min(z.shape) < 4: return np.where(w > 0, z, (z*w).sum()/max(w.sum(), 1e-9))
    zw = (z*w).reshape(z.shape[0]//2, 2, z.shape[1]//2, 2).sum((1, 3)); w2 = w.reshape(zw.shape[0], 2, zw.shape[1], 2).sum((1, 3))
    zc = push_pull(np.where(w2 > 0, zw/np.maximum(w2, 1e-9), 0), np.minimum(w2, 1), levels - 1)
    up = zoom(zc, 2, order=1, mode="nearest")
    a = np.clip(w, 0, 1); return a*z + (1 - a)*up


def mosaic():
    """NASA 镶嵌 → ① 等距柱面世界全景（Blender 约定，线性）② 地面代理高度场。原点＝镶嵌的投影中心（≈桅杆头）。"""
    from scipy.ndimage import map_coordinates, gaussian_filter1d, gaussian_filter
    rgb, P = read_mosaic(MOS_RGB, ">i2"); O = np.array(P["origin"])
    sc, z0 = P["scale"], P["z0"]; _, Lm, Sm = rgb.shape
    ok = (rgb > 0).all(0)
    rgb /= np.percentile(rgb[:, ok], 99.5)                                 # 辐射亮度 → 线性显示值（太阳附近的天空≈1）
    # 补空：每列往下用最后一行有效值（−78° 以下、车身挡住的黑洞）
    for c in range(3):
        b = np.where(ok, rgb[c], np.nan)
        for i in range(1, Lm):
            m = np.isnan(b[i]); b[i, m] = b[i - 1, m]
        for i in range(Lm - 2, -1, -1):
            m = np.isnan(b[i]); b[i, m] = b[i + 1, m]
        rgb[c] = np.nan_to_num(b, nan=np.nanmean(b))
    # 等距柱面：每像素与镶嵌同密度
    W = int(round(360*sc)); H = W//2
    el = 90 - (np.arange(H) + 0.5)*180/H
    phi = 180 - (np.arange(W) + 0.5)*360/W                                   # Blender：atan2(y北, x东)
    az = (90 - phi) % 360                                                  # 从北顺时针
    jj = az*sc - 0.5
    pano = np.empty((H, W, 3), np.float32)
    top = gaussian_filter1d(rgb[:, :12].mean(1), 5*sc, axis=1, mode="wrap")  # 镶嵌顶边（+30°）每个方位的颜色，方位上糊 5°
    zen = rgb[:, :12].mean((1, 2))
    for c in range(3):
        ii = np.clip(z0 - np.minimum(el, 30)[:, None]*sc - 0.5, 0, Lm - 1)*np.ones((1, W))
        pano[..., c] = map_coordinates(rgb[c], [ii, np.broadcast_to(jj, (H, W))], order=1, mode="grid-wrap")
        t = np.clip((el - 30)/60, 0, 1)[:, None]; t = t*t*(3 - 2*t)        # +30° 以上：顶边颜色 → 天顶均色
        sky = (1 - t)*np.interp(jj, np.arange(Sm), top[c], period=Sm)[None] + t*zen[c]
        pano[..., c] = np.where(el[:, None] > 30, sky, pano[..., c])
    np.save(DIR/"全景_镶嵌.npy", pano.astype(np.float16))
    log(f"世界全景 {W}×{H}（{1/sc:.4f}°/像素）← {MOS_RGB}")
    # 地面代理：XYZ 镶嵌 + 全部网格顶点 → 0.25 m 格网均值 → push-pull 补洞
    xyz, _ = read_mosaic(MOS_XYZ, ">f4")
    pts = [xyz[:, (xyz != 0).all(0)].T]
    for p in sorted(DIR.glob("N*.obj")):
        v = []
        with open(p) as fh:
            for l in fh:
                if l.startswith("v "): v.append(l.split()[1:4])
        pts.append(np.array(v, np.float32))
    b = (np.concatenate(pts) - O) @ M_SB.T                                  # Blender：东、北、上，原点＝投影中心
    dh = np.hypot(b[:, 0], b[:, 1])
    g0 = np.median(b[(dh > 4) & (dh < 8), 2])
    b = b[~((dh < 4) & (b[:, 2] > g0 + 0.3))]                                # 车体、机械臂
    cs, n = GRID
    ij = np.floor(b[:, :2]/cs + n/2).astype(int); m = ((ij >= 0) & (ij < n)).all(1); ij, zb = ij[m], b[m, 2]
    k = ij[:, 1]*n + ij[:, 0]                                              # 行＝北、列＝东
    cnt = np.bincount(k, minlength=n*n); s1 = np.bincount(k, zb, minlength=n*n)
    mu = s1/np.maximum(cnt, 1)
    keep = np.abs(zb - mu[k]) < 0.3                                        # 一格里离均值 >30 cm 的当离群
    cnt = np.bincount(k[keep], minlength=n*n); s1 = np.bincount(k[keep], zb[keep], minlength=n*n)
    w = (cnt > 0).astype(np.float32).reshape(n, n); z = (s1/np.maximum(cnt, 1)).reshape(n, n).astype(np.float32)
    z = push_pull(z, w)
    z = np.where(w > 0, z, gaussian_filter(z, 2))                           # 补出来的地方再顺一下
    np.savez_compressed(DIR/"地面.npz", z=z.astype(np.float32), w=w, cell=cs, n=n)
    # 近景深度网格：XYZ 镶嵌当深度图，隔 1 像素取点，相邻 2×2 都有效且距离比 <1.06（不跨遮挡边）就连两个三角形。
    # 车体、机械臂在这里有了自己的形状，挪开相机时不再是印在地上的贴花。
    st = 2
    X = xyz[:, ::st, ::st].transpose(1, 2, 0); okx = (X != 0).all(-1)
    B = (X - O) @ M_SB.T; Rr = np.linalg.norm(B, axis=-1)
    idx = -np.ones(okx.shape, np.int64); idx[okx] = np.arange(okx.sum())
    a_, b_, c_, d_ = idx[:-1, :-1], idx[:-1, 1:], idx[1:, :-1], idx[1:, 1:]
    q = (a_ >= 0) & (b_ >= 0) & (c_ >= 0) & (d_ >= 0)
    r4 = np.stack([Rr[:-1, :-1], Rr[:-1, 1:], Rr[1:, :-1], Rr[1:, 1:]])
    q &= r4.max(0)/np.maximum(r4.min(0), 1e-6) < 1.06
    tri = np.concatenate([np.stack([a_[q], c_[q], b_[q]], -1), np.stack([b_[q], c_[q], d_[q]], -1)])
    np.savez_compressed(DIR/"近景.npz", v=B[okx].astype(np.float32), f=tri.astype(np.int32))
    log(f"近景深度网格 {okx.sum():,} 点、{len(tri):,} 三角（距离 {np.percentile(Rr[okx], 1):.1f}–{np.percentile(Rr[okx], 99):.1f} m）")
    (DIR/"镶嵌.json").write_text(json.dumps(dict(origin=O.tolist(), ground=float(g0), rgb=MOS_RGB, xyz=MOS_XYZ), indent=1))
    log(f"投影中心（站点）{np.round(O, 3)}；地面代理 {n}×{n}×{cs} m，实测格 {w.mean()*100:.1f}%，桅杆下地面 z={g0:.2f} m")


# ── ② 搭建（Blender）──────────────────────────────────────────────────
def fan_ground(z, cs, n, drop=0.02, R=120.0, r0=0.4, r1=3000.0, na=720, q=1.0087):
    """地面代理：极坐标扇形网格（环距 ∝ 半径，跟透视走），高度从 0.25 m 格网双线性取；120 m 外沿用 120 m 处的高度。"""
    r = r0*q**np.arange(int(math.log(r1/r0)/math.log(q)) + 1)
    th = np.arange(na)*2*math.pi/na
    X = r[:, None]*np.cos(th); Y = r[:, None]*np.sin(th)
    rs = np.minimum(r, R)[:, None]
    cx = rs*np.cos(th)/cs + n/2 - 0.5; cy = rs*np.sin(th)/cs + n/2 - 0.5
    c0 = np.clip(np.floor(cx).astype(int), 0, n - 2); r0_ = np.clip(np.floor(cy).astype(int), 0, n - 2)
    fx = np.clip(cx - c0, 0, 1); fy = np.clip(cy - r0_, 0, 1)
    Z = (z[r0_, c0]*(1 - fx)*(1 - fy) + z[r0_, c0 + 1]*fx*(1 - fy) + z[r0_ + 1, c0]*(1 - fx)*fy + z[r0_ + 1, c0 + 1]*fx*fy) - drop
    V = np.stack([X, Y, Z], -1).reshape(-1, 3)
    k = np.arange(len(r) - 1)[:, None]*na; j = np.arange(na)[None]; j1 = (j + 1) % na
    F = np.stack([k + j, k + j1, k + na + j1, k + na + j], -1).reshape(-1, 4)
    return V, F


def build(*opts):
    """世界＝NASA 镶嵌全景；几何＝Navcam 网格（去车体、机械臂、碎片，右眼优先）＋地面代理；
    上色＝从投影中心把同一张全景投到几何上（从桅杆看与 NASA 原图一致，挪开相机才有视差）。
    opts：「渲染」出图（桅杆视角＋偏 1.5 m 的视角）；「照片」改用旧做法（网格贴原照片、照片拼的全景）。"""
    import bpy, bmesh
    from mathutils import Matrix
    meta = json.loads((DIR/"相机.json").read_text()); good = {c["file"] for c in meta["cams"] if c["err_90"] <= 8}
    use_mos = (DIR/"镶嵌.json").exists() and "照片" not in opts
    if use_mos:
        mj = json.loads((DIR/"镶嵌.json").read_text()); O = np.array(mj["origin"]); ground = mj["ground"]
        pano = np.load(DIR/"全景_镶嵌.npy").astype(np.float32)
    else:
        O = np.array(meta["origin"]); ground = GROUND; pano = np.load(DIR/"全景.npy").astype(np.float32)
    bpy.ops.wm.read_homefile(use_empty=True)
    sc = bpy.context.scene
    # 全景图 → 世界 ＋ 投影材质
    Hp, Wp = pano.shape[:2]
    img = bpy.data.images.new("全景", Wp, Hp, alpha=False, float_buffer=True)
    img.colorspace_settings.name = "Linear Rec.709"
    rgba = np.ones((Hp, Wp, 4), np.float32); rgba[..., :3] = pano[::-1]   # Blender 像素第 0 行在底
    img.pixels.foreach_set(rgba.ravel()); img.pack(); del rgba, pano
    w = bpy.data.worlds.new("实景天空"); sc.world = w
    nt = w.node_tree; nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputWorld"); bg = nt.nodes.new("ShaderNodeBackground"); te = nt.nodes.new("ShaderNodeTexEnvironment")
    te.image = img; nt.links.new(te.outputs["Color"], bg.inputs["Color"]); nt.links.new(bg.outputs[0], out.inputs["Surface"])
    proj = bpy.data.materials.new("全景投影"); proj.use_nodes = True; nt = proj.node_tree; nt.nodes.clear()
    geo = nt.nodes.new("ShaderNodeNewGeometry"); te = nt.nodes.new("ShaderNodeTexEnvironment"); te.image = img
    em = nt.nodes.new("ShaderNodeEmission"); out = nt.nodes.new("ShaderNodeOutputMaterial")
    nt.links.new(geo.outputs["Position"], te.inputs["Vector"])             # 原点＝投影中心，位置即方向
    nt.links.new(te.outputs["Color"], em.inputs["Color"]); nt.links.new(em.outputs[0], out.inputs["Surface"])
    # Navcam 网格
    T = np.eye(4); T[:3, :3] = M_SB; T[:3, 3] = -M_SB @ O                     # b = M (s − O)
    order = sorted(DIR.glob("N*.obj"), key=lambda p: (p.name[:2] != "NR", p.name))   # 右眼先
    occ = np.zeros((720, 1440), bool)                                      # 从桅杆看的方向占用（0.25°）
    coll = bpy.data.collections.new(f"sol{SOL}_实景"); sc.collection.children.link(coll)
    nf = 0
    for p in order:
        if p.name not in good: continue
        bpy.ops.wm.obj_import(filepath=str(p), forward_axis="Y", up_axis="Z")
        ob = bpy.context.selected_objects[0]; ob.name = p.stem[:8] + p.stem[18:27]
        for c_ in list(ob.users_collection): c_.objects.unlink(ob)
        coll.objects.link(ob)
        me = ob.data
        me.transform(Matrix(T.tolist())); me.update()
        cen = np.empty(len(me.polygons)*3); me.polygons.foreach_get("center", cen); cen = cen.reshape(-1, 3)
        rng_ = np.linalg.norm(cen, axis=1)
        az = ((np.degrees(np.arctan2(cen[:, 1], cen[:, 0])) + 180)*4).astype(int) % 1440
        el = np.clip(((np.degrees(np.arcsin(cen[:, 2]/np.maximum(rng_, 1e-6))) + 90)*4).astype(int), 0, 719)
        # 车体和机械臂（桅杆 4 m 内、离地 0.3 m 以上）、天上的立体匹配碎片（照片黑角；仰角 >2°、30 m 外）都删掉
        bad = ((np.hypot(cen[:, 0], cen[:, 1]) < 4) & (cen[:, 2] > ground + 0.3)) | ((el >= 92*4) & (rng_ > 30))
        if p.name[:2] != "NR": bad |= occ[el, az]                         # 左眼：右眼已看到的方向删掉
        if bad.any():
            bm = bmesh.new(); bm.from_mesh(me); bm.faces.ensure_lookup_table()
            bmesh.ops.delete(bm, geom=[bm.faces[i] for i in np.flatnonzero(bad)], context="FACES")
            bm.to_mesh(me); bm.free()
            az, el = az[~bad], el[~bad]
        o2 = np.zeros_like(occ); o2[el, az] = True
        occ |= np.roll(o2, 1, 1) | np.roll(o2, -1, 1) | np.roll(o2, 1, 0) | np.roll(o2, -1, 0) | o2
        if use_mos:
            me.materials.clear(); me.materials.append(proj)
        else:                                                              # 原照片直接发光（照片里已经是当时的阳光）
            for mat in me.materials:
                nt = mat.node_tree
                im = next(n.image for n in nt.nodes if n.bl_idname == "ShaderNodeTexImage")
                nt.nodes.clear()
                out = nt.nodes.new("ShaderNodeOutputMaterial"); em = nt.nodes.new("ShaderNodeEmission")
                tx = nt.nodes.new("ShaderNodeTexImage"); tx.image = im; tx.interpolation = "Linear"
                nt.links.new(tx.outputs["Color"], em.inputs["Color"]); nt.links.new(em.outputs[0], out.inputs["Surface"])
        nf += len(me.polygons)
    for im in list(bpy.data.images):                                       # 用不上的照片别打进 .blend
        if im.users == 0: bpy.data.images.remove(im)
    for m in list(bpy.data.materials):
        if m.users == 0: bpy.data.materials.remove(m)
    # 地面代理：网格没覆盖的方向（360° 里的大半）靠它接住投影
    if use_mos:
        g = np.load(DIR/"地面.npz")
        V, F = fan_ground(g["z"], float(g["cell"]), int(g["n"]))
        me = bpy.data.meshes.new("地面代理")
        me.vertices.add(len(V)); me.vertices.foreach_set("co", V.astype(np.float32).ravel())
        me.loops.add(F.size); me.loops.foreach_set("vertex_index", F.astype(np.int32).ravel())
        me.polygons.add(len(F)); me.polygons.foreach_set("loop_start", (np.arange(len(F))*4).astype(np.int32))
        me.update(calc_edges=True); me.validate()
        me.materials.append(proj)
        gob = bpy.data.objects.new("地面代理", me); coll.objects.link(gob)
        nf += len(F)
        if (DIR/"近景.npz").exists():                                      # XYZ 镶嵌的深度网格：车体、机械臂、近处地面
            g = np.load(DIR/"近景.npz"); V, F = g["v"], g["f"]
            me = bpy.data.meshes.new("近景深度")
            me.vertices.add(len(V)); me.vertices.foreach_set("co", V.ravel())
            me.loops.add(F.size); me.loops.foreach_set("vertex_index", F.ravel())
            me.polygons.add(len(F)); me.polygons.foreach_set("loop_start", (np.arange(len(F))*3).astype(np.int32))
            me.update(calc_edges=True); me.validate()
            me.materials.append(proj)
            coll.objects.link(bpy.data.objects.new("近景深度", me)); nf += len(F)
    # 相机：桅杆头（投影中心），朝照片最多的方向
    dirs = [np.array(c["R"])[2] @ M_SB.T for c in meta["cams"] if c["file"] in good]
    fwd = np.mean(dirs, 0); fwd[2] = 0; fwd /= np.linalg.norm(fwd)
    cam = bpy.data.objects.new("桅杆相机", bpy.data.cameras.new("桅杆相机")); sc.collection.objects.link(cam); sc.camera = cam
    yaw = math.atan2(fwd[1], fwd[0]) - math.pi/2
    cam.location = (0, 0, 0); cam.rotation_euler = (math.radians(80), 0, yaw)   # 往下 10°
    cam.data.sensor_fit = "HORIZONTAL"; cam.data.angle = math.radians(70); cam.data.clip_start = 0.05; cam.data.clip_end = 5000
    sc.render.engine = "BLENDER_EEVEE"; sc.view_settings.view_transform = "Standard"; sc.view_settings.look = "None"
    sc.render.resolution_x, sc.render.resolution_y = 1920, 1080; sc.eevee.taa_render_samples = 16
    for win in bpy.context.window_manager.windows if bpy.context.window_manager else []:
        for area in win.screen.areas:
            if area.type == "VIEW_3D":
                sp = area.spaces[0]; sp.shading.type = "MATERIAL"; sp.shading.use_scene_world = True
                sp.region_3d.view_perspective = "CAMERA"; sp.clip_start = 0.05; sp.clip_end = 5000
    path = DIR/f"sol{SOL:04d}_实景.blend"
    bpy.ops.wm.save_as_mainfile(filepath=str(path), compress=True)
    log(f"{len(coll.objects)} 块几何、{nf:,} 面（{'NASA 镶嵌投影' if use_mos else '原照片'}）→ {path.name}")
    if "渲染" in opts:
        sc.render.image_settings.file_format = "PNG"
        side = np.array([fwd[1], -fwd[0], 0])                               # 相机右手边
        for tag, loc in (("", (0, 0, 0)), ("_偏移", tuple(1.5*side + np.array([0, 0, -0.6])))):
            cam.location = loc
            outp = MAP/"产出"/"Blender"/f"实景_sol{SOL:04d}{tag}.png"; sc.render.filepath = str(outp)
            bpy.ops.render.render(write_still=True); log(f"→ {outp.name}")


if __name__ == "__main__":
    try:
        import bpy  # noqa
        argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    except ImportError:
        argv = sys.argv[1:]
    step = argv[0] if argv else "标定"
    if step == "标定": calibrate()
    elif step == "镶嵌": mosaic()
    else: build(*argv)
