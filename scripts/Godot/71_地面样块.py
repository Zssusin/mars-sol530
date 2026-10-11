#!/usr/bin/env python3
"""
71 地面样块：真火星地面材质样块，第一批（M1 板间暗沙、M2 浅色裂隙岩板、M3 棱角砾石裙、M12 磨蚀斑/钻孔、M4 撞击沙纹、M8 纹层）。
方案见 docs/地面材质/方案.md，报告见 docs/地面材质/样块_第一批.md。只读 PDS 原始数据、只写 资料/地面材质/样块/，不碰游戏着色器和 godot/数据/。

数据（fedora，资料/地面材质/PDS/，清单.json）：
  批1  Navcam 工作区全分辨率立体：sol 502–516 NCAM00708/9（3840×2880）、sol 520–532 NCAM00712（5120×3840），同一指向，
       XYZ（站点系，x 北 y 东 z 下）、UVW（ROVER_NAV 系法线）、RAS 左右（16 位辐射亮度 × RADIANCE_SCALING_FACTOR）。
  批2  Mastcam-Z 110 mm：ZCAM08544（sol 520/531，撞击沙纹）、ZCAM08547（sol 523，纹层岩阶）、ZCAM08558（sol 538，颗粒面）；
       ZLF XYZ/UVW + ZL0 IOF（未去马赛克 RGGB）。

子命令（.venv/bin/python scripts/Godot/71_地面样块.py <子命令>）：
  （每步约 1–6 分钟；正射 4 进程 ~1 min，分离 ~6 min，切块 ~2 min，对比 ~20 s）
  正射    每帧 XYZ → 公共 2 mm 水平格（ENU，原点 = 毅力号导航点，与游戏同一坐标；第 0 行在南）：
          高度（米，向上）、RAS 左辐射亮度、RAS 右（按右相机 CAHVOR 投影取样，交叉核对）、UVW 法线、点数、有效掩膜，
          标签里的当地真太阳时和站点系太阳方位/高度。最后做多日配准（高度高通后相位相关，分 4 象限），结果写 正射/配准.json。
  分离    反照率/明暗分离（sol 520–532 的 NCAM00712 帧，地面在 516 取芯之后就不再变）：
          基线 = 辐射亮度 ÷（Lunar-Lambert 直射 × 投射阴影掩膜 + 天空项），法线取立体高度平滑到 1 cm，逐帧增益/天空比
          交替最小二乘，再逐像素跨帧取中值；投射阴影由高度图沿太阳方向求地平角。
          进阶 = 逐像素跨帧最小二乘光度立体（b = ρn，带立体法线先验），留一帧交叉验证比较两者。
  切块    按表面类型（亮度分割 + 形态学：岩板 = 大块连通亮区、砾石 = 小块亮碎片密集、暗沙 = 暗且平滑）滑窗选块，
          每型 2–3 个变体；去平面 + 0.5 m 低频（与 57 ⑨ 中观同约定），高度按 Navcam 可信频段（≈1 cm 波长）低通，
          Moisan 周期分解；导出成现有细节图块格式到 样块/godot/（不覆盖 godot/数据/sol0530）。
          M12 磨蚀斑/钻孔：位置由 sol 530 原图点选、经同帧 XYZ 换成 ENU（sol 502→520 差分只作佐证），按真实位置切 16 cm 贴花（2 mm 格）。
          Mastcam-Z：ZCAM08544（sol 520、531）→ M4 撞击沙纹（1 mm 格），ZCAM08547（sol 523）→ M8 纹层（0.5 mm 格），
          去光影 = Lambert 直射 × 投射阴影 + 常数天光 0.5（单一光照，分不开）。
  对比    现有 meso/micro 图块 vs 新样块：反照率细节、高度晕渲、固定太阳下的简单着色，加同一块地的实拍照片裁切；
          每类的数值（反照率对比度、高度 RMS、1 cm 坡度 RMS、主波长、谱指数）。图写到 样块/对比/，小图拷 docs/地面材质/图/。
  全部    依次跑上面四步。

约定（和 scripts/Blender/实景地形系统.md §2–§3、57 ⑨、61 一致）：
  反照率细节均值为 1（逐通道），PNG 里存 0.5×；高度单位米，godot 版是 int32 宽高头 + float32（同 61 的 *_height.bin）。
数据：NASA/JPL-Caltech/ASU/MSSS（PDS Imaging Node，Mars 2020 Navcam / Mastcam-Z）。
"""
import json, math, os, re, sys, time, pathlib
import numpy as np

HERE = pathlib.Path(__file__).resolve().parent


def find_map():
    for p in (HERE, *HERE.parents):
        if (p/"资料"/"地面材质").is_dir() and (p/"godot").is_dir():
            return p
    raise SystemExit("找不到 地图/ 根目录（要有 资料/地面材质 和 godot/）")


MAP = find_map()
sys.path.insert(0, str(MAP/"docs"/"地面材质"))
from 读PDS影像 import read_img, group, rover_pose_in_site, debayer2x2   # noqa: E402

PDS = MAP/"资料"/"地面材质"/"PDS"
OUT = MAP/"资料"/"地面材质"/"样块"
GD = MAP/"godot"/"数据"/"sol0530"
CS = 0.002                                   # 工作区正射格距 2 mm
M_SE = np.array([[0, 1, 0], [1, 0, 0], [0, 0, -1]], float)   # 站点系 (N, E, 下) → ENU
CLASSES = ["沙", "砾石风化层", "基岩", "暗色岩块"]
_t0 = time.time()


def log(*a):
    s = f"[{time.time() - _t0:7.1f} s] " + " ".join(str(x) for x in a)
    print(s, flush=True)
    OUT.mkdir(parents=True, exist_ok=True)
    with open(OUT/"日志.txt", "a", encoding="utf-8") as f:
        f.write(time.strftime("%m-%d %H:%M:%S ") + s + "\n")


# ── 标签与几何 ────────────────────────────────────────────────────────────────────────────
def qrot(q):
    """四元数 (s, x, y, z) → 旋转矩阵（ROVER_NAV → SITE）。"""
    s, x, y, z = np.asarray(q, float)/np.linalg.norm(q)
    return np.array([[1 - 2*(y*y + z*z), 2*(x*y - s*z), 2*(x*z + s*y)],
                     [2*(x*y + s*z), 1 - 2*(x*x + z*z), 2*(y*z - s*x)],
                     [2*(x*z - s*y), 2*(y*z + s*x), 1 - 2*(x*x + y*y)]])


def tup(v):
    return np.array([float(x) for x in (v if isinstance(v, tuple) else (v,))])


def camera_site(lab):
    """GEOMETRIC_CAMERA_MODEL（ROVER_NAV 系的 CAHVOR(E)）→ 站点系。E 项 ~1e-8 m，忽略。"""
    g = group(lab, "GEOMETRIC_CAMERA_MODEL")
    ref = g.get("REFERENCE_COORD_SYSTEM_NAME", "")
    comp = {k: tup(g[f"MODEL_COMPONENT_{i}"]) for i, k in enumerate("CAHVOR", 1) if f"MODEL_COMPONENT_{i}" in g}
    if "ROVER" in ref:
        off, q = rover_pose_in_site(lab); R = qrot(q)
        comp = {k: (R @ v + off if k == "C" else (R @ v if k in "AHVO" else v)) for k, v in comp.items()}
    if "O" not in comp: comp["O"] = comp["A"]
    if "R" not in comp: comp["R"] = np.zeros(3)
    T = int(float(g.get("MODEL_COMPONENT_8", 1))) if g.get("MODEL_TYPE") == "CAHVORE" else 1
    comp["L"] = {1: 1.0, 2: 0.0}.get(T, float(g.get("MODEL_COMPONENT_9", 1.0)))
    return comp


def cahvor(cam, P):
    """站点系的点 (N,3) → (sample, line)、沿光轴距离。
    CAHVORE（Gennery 2006）：ψ = 光线与 O 的夹角；θ 由线性度 L 定（L=1 透视 θ=tanψ，L=0 鱼眼 θ=ψ，其余 tan(Lψ)/L 或 sin(Lψ)/L）；
    χ = θ(1+r0) + r1θ³ + r2θ⁵；再按 CAHV 投影方向 O + χ·λ̂。Navcam 是 T=2（L=0），按 CAHVOR 近似会差 ~100 px。E（入瞳移动 ~1e-8 m）忽略。"""
    p = P - cam["C"]; zeta = p @ cam["O"]
    lam3 = p - zeta[:, None]*cam["O"]; lam = np.linalg.norm(lam3, axis=1)
    L = cam.get("L", 1.0); r = cam["R"]
    psi = np.arctan2(lam, zeta)
    if L > 1e-9: th = np.tan(L*psi)/L
    elif L < -1e-9: th = np.sin(L*psi)/L
    else: th = psi
    chi = th*(1 + r[0]) + r[1]*th**3 + r[2]*th**5
    u = lam3/np.maximum(lam, 1e-12)[:, None]
    pp = cam["O"][None] + chi[:, None]*u
    den = pp @ cam["A"]
    return (pp @ cam["H"])/den, (pp @ cam["V"])/den, zeta


def site_sun(lab):
    g = group(lab, "SITE_DERIVED_GEOMETRY_PARMS")
    return float(g["SOLAR_AZIMUTH"]), float(g["SOLAR_ELEVATION"])


def sun_enu(az, el):
    a, e = math.radians(az), math.radians(el)
    return np.array([math.cos(e)*math.sin(a), math.cos(e)*math.cos(a), math.sin(e)])


def label_meta(lab):
    off, q = rover_pose_in_site(lab)
    az, el = site_sun(lab)
    rmc = lab.get("ROVER_MOTION_COUNTER")
    return dict(ltst=lab.get("LOCAL_TRUE_SOLAR_TIME"), sol=int(lab.get("PLANET_DAY_NUMBER", 0)),
                sun_az=az, sun_el=el, rover_off=off.tolist(), rover_q=q.tolist(),
                rmc=[int(x) for x in rmc] if isinstance(rmc, tuple) else rmc)


def rad_scale(lab):
    """RAS → W/m²/sr/nm。读取器若已按 PDS4 xml 的 scaling_factor 换算过（lab['_scaled']），这里不再乘。"""
    if lab.get("_scaled"): return 1.0, 0.0
    g = group(lab, "DERIVED_IMAGE_PARMS")
    return float(g.get("RADIANCE_SCALING_FACTOR", 1.0)), float(g.get("RADIANCE_OFFSET", 0.0))


# ── 公共工具 ──────────────────────────────────────────────────────────────────────────────
def gauss(a, s):
    from scipy.ndimage import gaussian_filter
    return gaussian_filter(a, s, mode="nearest")


def nan_gauss(a, s, min_w=1e-3):
    """带掩膜的高斯（归一化卷积）：NaN 不参与。"""
    m = np.isfinite(a)
    w = gauss(m.astype(np.float32), s)
    v = gauss(np.where(m, a, 0).astype(np.float32), s)
    with np.errstate(invalid="ignore", divide="ignore"):
        r = v/w
    r[w < min_w] = np.nan
    return r, w


def periodic(u):
    """Moisan 2011 周期＋平滑分解，只留周期分量（同 57 ⑨）。"""
    if u.ndim == 3: return np.stack([periodic(u[..., c]) for c in range(u.shape[-1])], -1)
    u = u.astype(np.float64); M, N = u.shape
    v = np.zeros_like(u)
    v[0] += u[-1] - u[0]; v[-1] += u[0] - u[-1]; v[:, 0] += u[:, -1] - u[:, 0]; v[:, -1] += u[:, 0] - u[:, -1]
    q = np.arange(M)[:, None]; r = np.arange(N)[None, :]
    den = 2*np.cos(2*np.pi*q/M) + 2*np.cos(2*np.pi*r/N) - 4; den[0, 0] = 1
    Sf = np.fft.fft2(v)/den; Sf[0, 0] = 0
    return (u - np.real(np.fft.ifft2(Sf))).astype(np.float32)


def hillshade(h, cs, az=225.0, el=30.0, exag=1.0):
    """高度（米，第 0 行在南）→ 朗伯晕渲 0–1（太阳方位从北顺时针）。"""
    gy, gx = np.gradient(np.nan_to_num(h)*exag, cs)
    n = np.stack([-gx, -gy, np.ones_like(gx)]); n /= np.linalg.norm(n, axis=0)
    s = sun_enu(az, el)
    return np.clip(np.tensordot(s, n, 1), 0, 1)


def to_u8(img):
    return (np.clip(img, 0, 1)*255 + 0.5).astype(np.uint8)


def stretch(img, lo=1, hi=99, mask=None):
    v = img[mask] if mask is not None else img[np.isfinite(img)]
    a, b = np.nanpercentile(v, [lo, hi])
    return np.clip((img - a)/max(b - a, 1e-9), 0, 1)


def save_img(path, arr, south_up=False):
    """arr：H×W 或 H×W×3，0–1；第 0 行在南的地图默认翻转成北朝上。"""
    from PIL import Image
    a = arr if south_up else arr[::-1]
    a = to_u8(np.nan_to_num(a))
    Image.fromarray(a).save(path, quality=90)


# ── ① 正射 ─────────────────────────────────────────────────────────────────────────────
def navcam_frames():
    """批1 每帧：左 XYZ、UVW、RAS 左、RAS 右（同名取最新版本）。"""
    out = []
    for xyz in sorted(PDS.glob("批1/sol*/NLF_*XYZ_*.IMG")):
        key = xyz.name[:23]; d = xyz.parent
        pick = lambda pat: (sorted(d.glob(pat)) or [None])[-1]
        fr = dict(xyz=xyz, uvw=pick(f"{key}UVW_*.IMG"), rasL=pick(f"{key}RAS_*.IMG"), rasR=pick(f"NRF{key[3:]}RAS_*.IMG"),
                  seq=re.search(r"NCAM\d{5}", xyz.name).group(), sol=int(key[4:8]))
        out.append(fr)
    return out


def frame_tag(sol, ltst):
    return f"{sol:04d}_{ltst.replace(':', '')[:4]}"


def grid_def():
    p = OUT/"正射"/"格.json"
    return json.loads(p.read_text()) if p.exists() else None


def splat(ii, jj, ny, nx, vals):
    """最近格平均：vals 是 (k, N) 数组，返回 (k, ny, nx) 和点数。"""
    idx = ii*nx + jj
    cnt = np.bincount(idx, minlength=ny*nx).astype(np.float32)
    out = np.stack([np.bincount(idx, weights=v, minlength=ny*nx) for v in vals]).astype(np.float32)
    with np.errstate(invalid="ignore", divide="ignore"):
        out = out/cnt
    return out.reshape(len(vals), ny, nx), cnt.reshape(ny, nx)


def fill_small(arrs, cnt, s=1.0, max_gap_w=0.12):
    """小空洞（点距 > 格距处的缝，≲ 3 格）用归一化高斯卷积补；被石块挡住的大空洞不补。"""
    m = cnt > 0
    w = gauss(m.astype(np.float32), s)
    ok = m | (w >= max_gap_w)
    out = []
    for a in arrs:
        v = gauss(np.where(m, a, 0).astype(np.float32), s)
        with np.errstate(invalid="ignore", divide="ignore"):
            f = np.where(m, a, v/w)
        f[~ok] = np.nan
        out.append(f.astype(np.float32))
    return out, ok


def ortho_frame(fr, grid=None):
    t0 = time.time()
    P, lab = read_img(str(fr["xyz"]))
    meta = label_meta(lab)
    meta.update(xyz=fr["xyz"].name, seq=fr["seq"], shape=list(P.shape[1:]))
    di = group(lab, "DERIVED_IMAGE_PARMS")
    meta["coord"] = f'{di.get("REFERENCE_COORD_SYSTEM_NAME")} {di.get("REFERENCE_COORD_SYSTEM_INDEX")}'
    off = np.array(meta["rover_off"]); R = qrot(meta["rover_q"])
    valid = np.any(P != 0, axis=0)
    # 站点系 → ENU（原点 = 毅力号导航点）
    E = P[1] - off[1]; N = P[0] - off[0]; U = -(P[2] - off[2])
    r = np.hypot(E, N)
    sel = valid & (r > 1.0) & (r < 6.0)
    if grid is None:                                                       # 第一帧（sol 530）定公共格：1–5.5 m 内点的外包
        s2 = sel & (r < 5.5)
        x0, x1 = np.percentile(E[s2], [0.2, 99.8]); y0, y1 = np.percentile(N[s2], [0.2, 99.8])
        x0, y0 = math.floor(x0*50)/50, math.floor(y0*50)/50
        grid = dict(x0=x0, y0=y0, nx=int(math.ceil((x1 - x0)/CS)), ny=int(math.ceil((y1 - y0)/CS)), cs=CS,
                    说明="ENU 米，原点 = 毅力号导航点（sol 502–532 同一 site 26 / drive 1222）；格 (i, j) 中心 = (x0 + (j+.5)cs, y0 + (i+.5)cs)；第 0 行在南")
        (OUT/"正射").mkdir(parents=True, exist_ok=True)
        (OUT/"正射"/"格.json").write_text(json.dumps(grid, ensure_ascii=False, indent=1))
        log(f"公共格：x {x0:.2f}…{x0 + grid['nx']*CS:.2f}，y {y0:.2f}…{y0 + grid['ny']*CS:.2f} m，{grid['nx']}×{grid['ny']}")
    nx, ny, x0, y0 = grid["nx"], grid["ny"], grid["x0"], grid["y0"]
    jj = np.floor((E - x0)/CS).astype(np.int64); ii = np.floor((N - y0)/CS).astype(np.int64)
    sel &= (jj >= 0) & (jj < nx) & (ii >= 0) & (ii < ny)
    # 相机投影自检：左 XYZ 投回左相机应落在自己的像素上
    camL = camera_site(lab)
    meta["cam_C_enu"] = (M_SE @ (camL["C"] - off)).tolist()
    rr_, cc_ = np.nonzero(sel); k = np.random.default_rng(0).choice(len(rr_), min(20000, len(rr_)), replace=False)
    xs, ys, _ = cahvor(camL, P[:, rr_[k], cc_[k]].T.astype(np.float64))
    meta["proj_err_px"] = float(np.median(np.hypot(xs - cc_[k], ys - rr_[k])))
    rasL, labL = read_img(str(fr["rasL"])); sL, oL = rad_scale(labL)
    rgbL = rasL*sL + oL; rgbL[:, ~(np.nan_to_num(rasL).min(0) > 0)] = np.nan
    nrm = None
    if fr["uvw"] is not None:
        W, labW = read_img(str(fr["uvw"]))
        ref = group(labW, "DERIVED_IMAGE_PARMS").get("REFERENCE_COORD_SYSTEM_NAME", "")
        Wv = W[:, sel].astype(np.float64)
        if "ROVER" in ref: Wv = R @ Wv
        nrm = M_SE @ Wv                                                    # ENU
        del W
    vals = [U[sel], *[rgbL[c][sel] for c in range(3)]]
    if nrm is not None: vals += list(nrm)
    G, cnt = splat(ii[sel], jj[sel], ny, nx, vals)
    del rasL, rgbL
    (h, *rest), ok = fill_small(list(G), cnt)
    rgb = np.stack(rest[:3]); n = np.stack(rest[3:6]) if nrm is not None else None
    if n is not None: n /= np.maximum(np.linalg.norm(np.nan_to_num(n), axis=0), 1e-6)
    # RAS 右：格中心 + 高度 → 站点系 → 右相机 CAHVOR → 双线性取样
    rgbR = None
    if fr["rasR"] is not None:
        rasR, labR = read_img(str(fr["rasR"])); sR, oR = rad_scale(labR)
        camR = camera_site(labR)
        iv, jv = np.nonzero(ok)
        Ee = x0 + (jv + 0.5)*CS; Nn = y0 + (iv + 0.5)*CS; Uu = h[iv, jv]
        Ps = np.stack([Nn + off[0], Ee + off[1], -Uu + off[2]], 1)
        xs, ys, den = cahvor(camR, Ps)
        H_, W_ = rasR.shape[1:]
        g = (xs >= 0) & (ys >= 0) & (xs < W_ - 1) & (ys < H_ - 1) & (den > 0)
        x0i = np.floor(xs[g]).astype(int); y0i = np.floor(ys[g]).astype(int); fx = xs[g] - x0i; fy = ys[g] - y0i
        rgbR = np.full((3, ny, nx), np.nan, np.float32)
        for c in range(3):
            b = rasR[c].astype(np.float32)*sR + oR; b[~(np.nan_to_num(rasR[c]) > 0)] = np.nan
            v = (b[y0i, x0i]*(1 - fx)*(1 - fy) + b[y0i, x0i + 1]*fx*(1 - fy) + b[y0i + 1, x0i]*(1 - fx)*fy + b[y0i + 1, x0i + 1]*fx*fy)
            rgbR[c, iv[g], jv[g]] = v
        del rasR
    tag = frame_tag(meta["sol"], meta["ltst"])
    meta.update(tag=tag, valid_frac=float(ok.mean()), pts_per_cell=float(np.median(cnt[cnt > 0])),
                fill_frac=float((ok & (cnt == 0)).sum()/max(ok.sum(), 1)))
    if rgbR is not None:                                                   # 左右交叉核对：亮度比、1 cm 以下细节相关
        m = ok & np.all(np.isfinite(rgbR), 0) & np.all(np.isfinite(rgb), 0)
        lL = rgb.mean(0); lR = rgbR.mean(0)
        ratio = lR[m]/np.maximum(lL[m], 1e-9)
        hpL = lL - gauss(np.nan_to_num(lL), 3); hpR = lR - gauss(np.nan_to_num(lR), 3)
        meta["LR"] = dict(ratio_med=float(np.median(ratio)), ratio_mad=float(np.median(np.abs(ratio - np.median(ratio)))),
                          ratio_rgb=[float(np.median(rgbR[c][m]/np.maximum(rgb[c][m], 1e-9))) for c in range(3)],
                          hp_corr=float(np.corrcoef(hpL[m][::7], hpR[m][::7])[0, 1]), frac=float(m.mean()))
    if n is not None:                                                      # UVW 与高度图法线的夹角
        gy, gx = np.gradient(gauss(np.nan_to_num(h), 2), CS)
        nh = np.stack([-gx, -gy, np.ones_like(gx)]); nh /= np.linalg.norm(nh, axis=0)
        m = ok & np.all(np.isfinite(n), 0)
        meta["uvw_vs_h_deg"] = float(np.degrees(np.median(np.arccos(np.clip((n[:, m]*nh[:, m]).sum(0), -1, 1)))))
    np.savez(OUT/"正射"/f"{tag}.npz", h=np.where(ok, h, np.nan).astype(np.float32), rgb=rgb.astype(np.float32),
             rgbR=(rgbR if rgbR is not None else np.zeros((3, 1, 1))).astype(np.float32),
             n=(n if n is not None else np.zeros((3, 1, 1))).astype(np.float16), cnt=np.minimum(cnt, 255).astype(np.uint8), ok=ok,
             meta=json.dumps(meta, ensure_ascii=False))
    # 预览（缩 4 倍）
    sm = slice(None, None, 4)
    L_ = rgb.mean(0)[sm, sm]
    pv = np.concatenate([np.repeat(stretch(L_)[..., None], 3, -1),
                         np.repeat(hillshade(h[sm, sm], CS*4, meta["sun_az"], meta["sun_el"], 3)[..., None], 3, -1)], 1)
    save_img(OUT/"正射"/f"预览_{tag}.jpg", pv)
    log(f"正射 {tag}（{fr['seq']}，LTST {meta['ltst']}，太阳 {meta['sun_az']:.1f}°/{meta['sun_el']:.1f}°）：有效 {meta['valid_frac']*100:.0f}%，"
        f"每格 {meta['pts_per_cell']:.1f} 点，补 {meta['fill_frac']*100:.1f}%，投影自检 {meta['proj_err_px']:.2f} px，"
        f"UVW–高度法线 {meta.get('uvw_vs_h_deg', float('nan')):.1f}°，左右比 {meta.get('LR', {}).get('ratio_med', float('nan')):.3f}"
        f"（细节相关 {meta.get('LR', {}).get('hp_corr', float('nan')):.2f}），{time.time() - t0:.0f} s")
    return meta


def xcorr_shift(a, b, rmax=8):
    """b 相对 a 的平移（格）：普通互相关（不白化：白化后 2–4 mm 的立体噪声占了大半频点，峰会锁到 ±1 格），峰值二次曲面亚像素。"""
    F = np.fft.fft2(a)*np.conj(np.fft.fft2(b))
    c = np.fft.fftshift(np.real(np.fft.ifft2(F)))
    cy, cx = c.shape[0]//2, c.shape[1]//2
    w = c[cy - rmax:cy + rmax + 1, cx - rmax:cx + rmax + 1]
    i, j = np.unravel_index(np.argmax(w), w.shape)
    i = min(max(i, 1), w.shape[0] - 2); j = min(max(j, 1), w.shape[1] - 2)
    def sub(m1, m0, p1):
        d = m1 - 2*m0 + p1
        return 0.0 if d == 0 else 0.5*(m1 - p1)/d
    di = sub(w[i - 1, j], w[i, j], w[i + 1, j]); dj = sub(w[i, j - 1], w[i, j], w[i, j + 1])
    pk = float(w[i, j]/max(np.sqrt((a*a).sum()*(b*b).sum()), 1e-30))
    return (i + di - rmax), (j + dj - rmax), pk


def _bp(x, s0=1.5, s1=10):
    x = np.where(np.isfinite(x), x - np.nanmean(x), 0)
    return gauss(x, s0) - gauss(x, s1)


def tile_shifts(hR, h, m, T=400, step=300, band=(1.5, 10)):
    """分块互相关：返回 [(格中心 i, j, s_i, s_j, 峰)]，s = b 相对 a 的内容位移（格）。"""
    out = []
    ny, nx = h.shape
    win = np.outer(np.hanning(T), np.hanning(T))
    for a0 in range(0, ny - T + 1, step):
        for b0 in range(0, nx - T + 1, step):
            sl = (slice(a0, a0 + T), slice(b0, b0 + T)); mm = m[sl]
            if mm.mean() < 0.5: continue
            w = win*mm
            di, dj, pk = xcorr_shift(_bp(hR[sl], *band)*w, _bp(h[sl], *band)*w)
            if not pk >= 0.3: continue
            out.append((a0 + T/2, b0 + T/2, -di, -dj, pk))
    return np.array(out)


def fit_affine(S):
    """s_i、s_j 各拟合成 c0 + c1·i + c2·j（格），两轮 3×MAD 剔除。"""
    A = np.c_[np.ones(len(S)), S[:, 0], S[:, 1]]; keep = np.ones(len(S), bool)
    for _ in range(3):
        ci = np.linalg.lstsq(A[keep], S[keep, 2], rcond=None)[0]; cj = np.linalg.lstsq(A[keep], S[keep, 3], rcond=None)[0]
        r = np.hypot(S[:, 2] - A @ ci, S[:, 3] - A @ cj)
        keep = r <= max(3*np.median(r[keep]), 0.15)
    return ci, cj, float(np.sqrt(np.mean(r[keep]**2))), int(keep.sum())


def warp(arr, corr):
    """按配准改正把一帧的图对齐到参考帧：在 (i + s_i, j + s_j) 处取样（双线性），高度再减平面。"""
    from scipy.ndimage import map_coordinates
    ny, nx = arr.shape[-2:]
    ci, cj = np.array(corr["ci"]), np.array(corr["cj"])
    I, J = np.mgrid[0:ny, 0:nx].astype(np.float32)
    si = ci[0] + ci[1]*I + ci[2]*J; sj = cj[0] + cj[1]*I + cj[2]*J
    co = np.stack([I + si, J + sj])
    if arr.ndim == 3:
        return np.stack([map_coordinates(a, co, order=1, mode="constant", cval=np.nan) for a in arr])
    return map_coordinates(arr, co, order=1, mode="constant", cval=np.nan)


def load_frame(tag, aligned=True):
    D = np.load(OUT/"正射"/f"{tag}.npz"); meta = json.loads(str(D["meta"]))
    h, rgb, n, ok = D["h"], D["rgb"], D["n"].astype(np.float32), D["ok"]
    if aligned and (OUT/"正射"/"配准.json").exists():
        c = json.loads((OUT/"正射"/"配准.json").read_text())[tag]["改正"]
        h = warp(h, c); rgb = warp(rgb, c); n = warp(n, c) if n.shape[1] > 1 else n
        ny, nx = h.shape; I, J = np.mgrid[0:ny, 0:nx]
        h = h - (c["dz"][0] + c["dz"][1]*J*CS + c["dz"][2]*I*CS)
        ok = np.isfinite(h) & np.all(np.isfinite(rgb), 0)
    return dict(h=h, rgb=rgb, n=n, ok=ok, meta=meta)


REF = "0531_1201"                            # 配准参考帧：正午（太阳 180.6°/47.4°），与正午一簇光照最接近


def _loglum(D):
    L = np.log(np.maximum(D["rgb"].mean(0), 1e-12)); L[~D["ok"]] = np.nan
    return L


def register():
    """各帧配准到参考帧 REF（sol 531 正午）：
    水平：0.8 m 分块互相关 → 仿射位移场。光照与参考相近（方位差 ≤ 13°、高度差 ≤ 3°）的帧用 log 亮度（1.4–12 mm 带通，峰尖、
          准到 0.3 mm）；光照不同的帧用高度（3 mm–2 cm 带通）—— 亮度的明暗随太阳方向移动，会把石子「拉」向太阳几毫米。
    竖直：对齐后的高度差拟合平面（偏移 + 倾斜），残差 MAD 即单帧立体高度噪声。
    改正写进 配准.json（load_frame() 读时套用）；改正后用同一方法再量一次。"""
    files = sorted((OUT/"正射").glob("0*.npz"))
    R = np.load(OUT/"正射"/f"{REF}.npz"); hR = R["h"]; LR = _loglum(R); mR = json.loads(str(R["meta"]))
    ny, nx = hR.shape; I, J = np.mgrid[0:ny, 0:nx]
    res = {}
    for f in files:
        D = np.load(f); h = D["h"]; meta = json.loads(str(D["meta"])); tag = meta["tag"]
        daz = abs((meta["sun_az"] - mR["sun_az"] + 180) % 360 - 180); delv = abs(meta["sun_el"] - mR["sun_el"])
        by_lum = daz <= 13 and delv <= 3
        a_, b_, band = (LR, _loglum(D), (0.7, 6)) if by_lum else (hR, h, (1.5, 10))
        m = np.isfinite(a_) & np.isfinite(b_)
        S = tile_shifts(a_, b_, m, band=band)
        ci, cj, rms, nk = fit_affine(S) if len(S) >= 4 else (np.zeros(3), np.zeros(3), float("nan"), 0)
        if tag == REF: ci, cj, rms = np.zeros(3), np.zeros(3), 0.0
        corr = dict(ci=ci.tolist(), cj=cj.tolist(), dz=[0.0, 0.0, 0.0])
        h2 = warp(h, corr); b2 = warp(b_, corr) if by_lum else h2
        m2 = np.isfinite(h2) & np.isfinite(hR)
        dz = (h2 - hR)[m2]; iv, jv = I[m2], J[m2]
        A = np.c_[np.ones(len(iv)), jv*CS, iv*CS]
        c = np.linalg.lstsq(A[::13], dz[::13], rcond=None)[0]; corr["dz"] = c.tolist()
        resid = dz - A @ c
        mad = float(np.median(np.abs(resid - np.median(resid))))
        S2 = tile_shifts(a_, b2, np.isfinite(a_) & np.isfinite(b2), band=band)
        mag = lambda X: float(np.median(np.hypot(X[:, 2], X[:, 3]))*CS*1e3) if len(X) else float("nan")
        corners = np.array([[0, 0], [0, nx], [ny, 0], [ny, nx]], float)
        smax = float(max(np.hypot(ci[0] + ci[1]*a + ci[2]*b, cj[0] + cj[1]*a + cj[2]*b) for a, b in corners)*CS*1e3)
        res[tag] = dict(sol=meta["sol"], ltst=meta["ltst"], seq=meta["seq"], rmc=meta["rmc"], sun=[meta["sun_az"], meta["sun_el"]],
                        method="亮度" if by_lum else "高度", 改正=corr,
                        dz_med_mm=float(np.median(dz)*1e3), tilt_mm_per_m=[float(c[1]*1e3), float(c[2]*1e3)], resid_mad_mm=mad*1e3,
                        frac_changed_2cm=float((np.abs(resid) > 0.02).mean()), overlap=float(m.mean()),
                        shift_before_mm=mag(S), shift_after_mm=mag(S2), shift_max_mm=smax, affine_rms_mm=rms*CS*1e3, n_tiles=nk,
                        peak_med=float(np.median(S[:, 4])) if len(S) else None)
        log(f"配准 {tag}（按{'亮度' if by_lum else '高度'}）：水平位移 中值 {mag(S):.2f} mm（格内最大 {smax:.1f} mm；{nk} 块，仿射残差 {rms*CS*1e3:.2f} mm，"
            f"峰 {res[tag]['peak_med'] or 0:.2f}）→ 改正后 {mag(S2):.2f} mm；高度 偏移 {np.median(dz)*1e3:+.1f} mm、倾斜 ({c[1]*1e3:+.2f}, {c[2]*1e3:+.2f}) mm/m，"
            f"残差 MAD {mad*1e3:.2f} mm，>2 cm 变化 {res[tag]['frac_changed_2cm']*100:.2f}%")
    (OUT/"正射"/"配准.json").write_text(json.dumps(res, ensure_ascii=False, indent=1))


# ── ② 反照率 / 明暗分离 ─────────────────────────────────────────────────────────────────────
SEP = ["0520_1246", "0520_1549", "0526_1229", "0527_1237", "0528_1236", "0529_1203", "0530_1433", "0531_1201", "0532_1143"]
# sol 521 06:41（太阳高 1.2°，几乎全是天光）不进求解；sol 502–516 的地面被磨蚀/取芯改过，只给 M12 用。


def horizon_tan(Hf, az, dmax, device=None):
    """沿方位 az（从北顺时针）看，每格到 dmax 米内的最大仰角正切（地平角）。Hf 不能有 NaN。torch，显卡上跑。"""
    import torch
    dev = device or ("cuda" if torch.cuda.is_available() else "cpu")
    H = torch.from_numpy(np.ascontiguousarray(Hf, np.float32)).to(dev)
    ny, nx = H.shape
    de, dn = math.sin(math.radians(az)), math.cos(math.radians(az))
    best = torch.full_like(H, -10.0)
    seen = set()
    for k in range(1, int(dmax/CS) + 1):
        di, dj = int(round(k*dn)), int(round(k*de))                        # 行向北、列向东
        if (di, dj) in seen: continue
        seen.add((di, dj))
        src = H[max(di, 0):ny + min(di, 0), max(dj, 0):nx + min(dj, 0)]
        ds = (slice(max(-di, 0), ny + min(-di, 0)), slice(max(-dj, 0), nx + min(-dj, 0)))
        t = (src - H[ds])/(math.hypot(di, dj)*CS)
        best[ds] = torch.maximum(best[ds], t)
    return best.cpu().numpy()


def normals_from(H, s):
    gy, gx = np.gradient(gauss(H, s) if s > 0 else H, CS)
    n = np.stack([-gx, -gy, np.ones_like(gx)]); n /= np.linalg.norm(n, axis=0)
    return n.astype(np.float32)


def lunar_lambert(mu0, mu, L):
    return (1 - L)*mu0 + L*2*mu0/np.maximum(mu0 + mu, 1e-3)


def robust_lstsq(X, y, it=3):
    keep = np.isfinite(y)
    for _ in range(it):
        c = np.linalg.lstsq(X[keep], y[keep], rcond=None)[0]
        r = y - X @ c; mad = np.median(np.abs(r[keep])) + 1e-12
        keep = np.isfinite(r) & (np.abs(r) < 3*1.4826*mad)
    return c


def solve_albedo(I, D, SV, valid, L_iter=4, sub=None, min_s=0.25):
    """I：[帧][通道] 辐射亮度；D：[帧] 直射明暗（Lunar-Lambert × 受光）；SV：天空可见度。
    交替：逐帧逐通道 I/A ≈ g·D + g·a·SV（稳健最小二乘）→ A = 跨帧中值 I/(g·D + g·a·SV)（分母太小的帧不参与）。"""
    nf = len(I); ny, nx = SV.shape
    sub = sub if sub is not None else (slice(None, None, 3), slice(None, None, 3))
    A = np.stack([np.nanmedian(np.stack([np.where(valid[f], I[f][c], np.nan) for f in range(nf)]), 0) for c in range(3)])
    G = np.zeros((nf, 3)); Ga = np.zeros((nf, 3))
    for _ in range(L_iter):
        for f in range(nf):
            m = valid[f][sub] & np.isfinite(A[0][sub])
            X = np.c_[D[f][sub][m], SV[sub][m]]
            for c in range(3):
                cf = robust_lstsq(X, I[f][c][sub][m]/A[c][sub][m])
                G[f, c], Ga[f, c] = cf[0], max(cf[1], 0.0)
        A = np.empty((3, ny, nx), np.float32); Af = []
        for c in range(3):
            st = []
            for f in range(nf):
                den = G[f, c]*D[f] + Ga[f, c]*SV
                ok = valid[f] & (den > min_s*G[f, c]*np.median(D[f][valid[f]]))
                st.append(np.where(ok, I[f][c]/np.maximum(den, 1e-12), np.nan))
            st = np.stack(st); A[c] = np.nanmedian(st, 0); Af.append(st)
    return A, G, Ga, Af


def cmd_separate(args):
    from scipy.ndimage import binary_erosion
    t0 = time.time()
    (OUT/"分离").mkdir(parents=True, exist_ok=True)
    Fs = [load_frame(t) for t in SEP]
    metas = [F["meta"] for F in Fs]
    ny, nx = Fs[0]["h"].shape
    # 公共高度：对齐后跨帧中值（单帧立体噪声 MAD 0.5–1.8 mm → 中值约降 √9）
    Hs = np.stack([F["h"] for F in Fs]); H = np.nanmedian(Hs, 0); nH = np.isfinite(Hs).sum(0)
    h_noise = float(np.nanmedian(np.abs(Hs - H[None]))*1e3)
    del Hs
    Hf, _ = nan_gauss(H, 6.0); Hf = np.where(np.isfinite(H), H, Hf); Hf = np.where(np.isfinite(Hf), Hf, np.nanmedian(H))
    n_s = normals_from(Hf, 2.5)                                             # 立体法线：σ 5 mm（1 cm 波长以上）
    C = np.mean([m_["cam_C_enu"] for m_ in metas], 0)
    gx0 = json.loads((OUT/"正射"/"格.json").read_text())
    X_ = gx0["x0"] + (np.arange(nx) + 0.5)*CS; Y_ = gx0["y0"] + (np.arange(ny) + 0.5)*CS
    V = np.stack(np.broadcast_arrays(C[0] - X_[None, :], C[1] - Y_[:, None], C[2] - Hf)).astype(np.float32)
    V /= np.linalg.norm(V, axis=0)
    mu = np.clip((n_s*V).sum(0), 0.05, 1)
    phase = [float(np.degrees(np.arccos(np.clip(np.median((sun_enu(m_["sun_az"], m_["sun_el"])[:, None]*V[:, ::50, ::50].reshape(3, -1)).sum(0)), -1, 1)))) for m_ in metas]
    # 天空可见度：8 个方位 0.3 m 内的地平角 → 1 − mean sin²θ，乘 (1+n_z)/2
    sh = np.zeros((ny, nx), np.float32)
    for az in range(0, 360, 45):
        t = horizon_tan(Hf, az, 0.3); th = np.arctan(np.maximum(t, 0)); sh += np.sin(th)**2/8
    SV = ((1 - sh)*(1 + n_s[2])/2).astype(np.float32)
    # 每帧投射阴影（地平角 vs 太阳高度；约 1° 的过渡）与直射项
    lit, mu0s = [], []
    for m_ in metas:
        s = sun_enu(m_["sun_az"], m_["sun_el"])
        t = horizon_tan(Hf, m_["sun_az"], 1.0)
        lit.append(np.clip((math.tan(math.radians(m_["sun_el"])) - t)/0.035 + 0.5, 0, 1).astype(np.float32))
        mu0s.append(np.clip(np.tensordot(s, n_s, 1), 0, 1).astype(np.float32))
    I = [F["rgb"] for F in Fs]
    valid = [F["ok"] & np.isfinite(H) for F in Fs]
    log(f"分离：{len(Fs)} 帧，公共高度 跨帧 MAD {h_noise:.2f} mm；相位角 {', '.join(f'{p:.0f}°' for p in phase)}；"
        f"投射阴影占比 {', '.join(f'{(1 - l[valid[i]]).mean()*100:.1f}%' for i, l in enumerate(lit))}（{time.time() - t0:.0f} s）")
    # 光照一致性：用 sol 530 14:33、sol 520 15:49 两帧（与正午一簇光照不同）对照正午中值
    noon = [i for i, m_ in enumerate(metas) if abs(m_["sun_el"] - 46) < 2.5]
    off = [i for i in range(len(metas)) if i not in noon]
    def consistency(Af):
        lum = [np.nanmean(np.stack([Af[c][f] for c in range(3)]), 0) for f in range(len(metas))]
        ref = np.nanmedian(np.stack([lum[i] for i in noon]), 0)
        out = {}
        for i in off:
            d = np.log(lum[i]/ref); d = d[np.isfinite(d)]; d -= np.median(d)
            out[SEP[i]] = float(np.median(np.abs(d)))
        return out
    # 不做明暗改正（只除逐帧增益）作为对照
    D0 = [np.ones_like(SV) for _ in metas]
    _, _, _, Af0 = solve_albedo(I, D0, np.zeros_like(SV), valid, L_iter=1)
    cons = {"不改正": consistency(Af0)}
    best = None
    for L in (0.0, 0.25, 0.5, 0.75, 1.0):
        D = [lunar_lambert(mu0s[f], mu, L)*lit[f] for f in range(len(metas))]
        A, G, Ga, Af = solve_albedo(I, D, SV, valid)
        cons[f"L={L}"] = consistency(Af)
        sc = float(np.mean(list(cons[f"L={L}"].values())))
        log(f"  Lunar-Lambert L={L}：正午外两帧 与正午中值的反照率差（中位 |Δlog|）{', '.join(f'{k} {v:.3f}' for k, v in cons[f'L={L}'].items())}；天空/直射 {Ga.mean(1)/G.mean(1)}")
        if best is None or sc < best[0]: best = (sc, L, A, G, Ga, Af, D)
    sc, L, A, G, Ga, Af, D = best
    log(f"  取 L={L}（不改正时 {', '.join(f'{v:.3f}' for v in cons['不改正'].values())}）")
    # 残余阴影泄漏：(a) 反照率与各帧直射明暗的高通相关；(b) 只在某些帧受光的格：阴影帧（天光模型）与受光帧给出的反照率之比
    lumA = A.mean(0)
    def hp(x): x = np.where(np.isfinite(x), x, np.nanmedian(x)); return x - gauss(x, 8)
    corr = {}
    for i in off + noon[:1]:
        mm = valid[i] & np.isfinite(lumA)
        raw = np.log(np.maximum(I[i].mean(0), 1e-9)); sh_ = np.log(np.maximum(D[i] + Ga[i].mean()/G[i].mean()*SV, 1e-3))
        corr[SEP[i]] = dict(raw=float(np.corrcoef(hp(raw)[mm][::11], hp(sh_)[mm][::11])[0, 1]),
                            albedo=float(np.corrcoef(hp(np.log(np.maximum(lumA, 1e-9)))[mm][::11], hp(sh_)[mm][::11])[0, 1]))
    nlit = np.sum([(l > 0.99) & v for l, v in zip(lit, valid)], 0); nshd = np.sum([(l < 0.01) & v for l, v in zip(lit, valid)], 0)
    mix = (nlit >= 2) & (nshd >= 2)
    rat = []
    for f in range(len(metas)):
        sh_ = (lit[f] < 0.01) & valid[f] & mix
        lum_f = np.nanmean(np.stack([Af[c][f] for c in range(3)]), 0)
        r = lum_f[sh_]/lumA[sh_]; r = r[np.isfinite(r)]
        if len(r) > 1000: rat.append(float(np.median(r)))
    sky_only = np.isfinite(H) & (nlit == 0) & (nshd > 0)
    leak = dict(corr=corr, shadow_vs_lit=rat, sky_only_frac=float(sky_only.sum()/np.isfinite(H).sum()))
    log(f"  阴影泄漏：高通相关（原始辐亮 → 反照率）{', '.join(f'{k} {v[chr(114)+chr(97)+chr(119)]:.2f}→{v[chr(97)+chr(108)+chr(98)+chr(101)+chr(100)+chr(111)]:.2f}' for k, v in corr.items())}；"
        f"阴影帧（天光模型）/受光帧 反照率比 中值 {np.median(rat) if rat else float('nan'):.2f}（{len(rat)} 帧）；只有天光样本的格 {leak['sky_only_frac']*100:.1f}%")
    np.savez(OUT/"分离"/"基线.npz", A=A.astype(np.float32), H=H.astype(np.float32), Hf=Hf.astype(np.float32), n_s=n_s.astype(np.float16),
             SV=SV.astype(np.float16), nlit=nlit.astype(np.uint8), nH=nH.astype(np.uint8), G=G, Ga=Ga, L=L)
    # ── 进阶：逐像素光度立体（b = ρn，Lambert + 天光；先验 b0 = A·n_s，λ 控制） + 留一帧交叉验证 ──
    ps = photometric_stereo(I, lit, valid, metas, G, Ga, SV, A, n_s, mu, L)
    metrics = dict(frames=SEP, sun=[[m_["sun_az"], m_["sun_el"]] for m_ in metas], phase_deg=phase, h_cross_frame_mad_mm=h_noise,
                   L=L, consistency=cons, gain=G.tolist(), sky=Ga.tolist(), leak=leak, ps=ps, seconds=time.time() - t0)
    (OUT/"分离"/"指标.json").write_text(json.dumps(metrics, ensure_ascii=False, indent=1))
    # 预览
    sm = (slice(None, None, 4), slice(None, None, 4))
    lo = lambda x: stretch(np.log(np.maximum(x, 1e-9)))
    i530 = SEP.index("0530_1433")
    pv = np.concatenate([np.repeat(lo(I[i530].mean(0)[sm])[..., None], 3, -1),
                         np.moveaxis(np.stack([stretch(A[c][sm]) for c in range(3)]), 0, -1)], 1)
    save_img(OUT/"分离"/"预览_辐亮0530_反照率.jpg", pv)
    log(f"分离完成（{time.time() - t0:.0f} s）")


def photometric_stereo(I, lit, valid, metas, G, Ga, SV, A0, n_s, mu, L, lam=0.3):
    """b = ρ n 的逐像素正则最小二乘：Σ_f w_f (I_f/g_f − ρ0·a_f·SV − b·s_f)² + λ·|b − ρ0·n_s|²（亮度通道，w_f = 受光）。
    留一帧（0530_1433、0520_1549）验证：用其余帧解出的 (ρ, n) 预测该帧辐亮度，与基线（立体法线 + 中值反照率）比 log 残差。"""
    nf = len(metas)
    S = np.stack([sun_enu(m_["sun_az"], m_["sun_el"]) for m_ in metas])
    sv = np.linalg.svd(S, compute_uv=False)
    lumI = [I[f].mean(0) for f in range(nf)]; g = G.mean(1); ga = Ga.mean(1); rho0 = A0.mean(0)
    def solve(fr):
        ny, nx = SV.shape
        M = np.zeros((ny, nx, 3, 3), np.float32); r = np.zeros((ny, nx, 3), np.float32)
        for f in fr:
            w = (valid[f] & (lit[f] > 0.99)).astype(np.float32)
            y = np.where(w > 0, lumI[f]/g[f] - np.nan_to_num(rho0)*ga[f]/g[f]*SV, 0)
            s = S[f].astype(np.float32)
            M += w[..., None, None]*np.outer(s, s)[None, None]; r += (w*y)[..., None]*s[None, None]
        M += lam*np.eye(3, dtype=np.float32)[None, None]                    # 先验：λ|b − ρ0·n_s|²
        r += lam*(np.nan_to_num(rho0)[..., None]*np.moveaxis(n_s, 0, -1)).astype(np.float32)
        b = np.linalg.solve(M.reshape(-1, 3, 3), r.reshape(-1, 3, 1))[..., 0].reshape(ny, nx, 3)
        rho = np.linalg.norm(b, axis=-1); n = np.moveaxis(b/np.maximum(rho, 1e-9)[..., None], -1, 0)
        return rho, n
    out = dict(sun_matrix_singular=sv.tolist(), cond=float(sv[0]/sv[-1]))
    for k in ("0530_1433", "0520_1549"):
        if k not in SEP: continue
        fo = SEP.index(k); fr = [f for f in range(nf) if f != fo]
        rho, n = solve(fr)
        mu0 = np.clip(np.tensordot(S[fo], n, 1), 0, 1)
        pred_ps = g[fo]*(rho*mu0*lit[fo] + rho*ga[fo]/g[fo]*SV)
        mu0s = np.clip(np.tensordot(S[fo], n_s, 1), 0, 1)
        Ab = np.nanmedian(np.stack([lumI[f]/np.maximum(g[f]*(lunar_lambert(np.clip(np.tensordot(S[f], n_s, 1), 0, 1), mu, L)*lit[f]) + ga[f]*SV, 1e-9)
                                    for f in fr]), 0)
        pred_b = g[fo]*Ab*(lunar_lambert(mu0s, mu, L)*lit[fo]) + ga[fo]*Ab*SV
        m = valid[fo] & (lit[fo] > 0.99) & np.isfinite(pred_ps) & np.isfinite(pred_b) & (pred_ps > 0) & (pred_b > 0)
        def err(p):
            d = np.log(lumI[fo][m]/p[m]); d -= np.median(d)
            return float(np.median(np.abs(d)))
        def err_hp(p):
            d = np.log(np.maximum(lumI[fo], 1e-12)/np.maximum(p, 1e-12)); d[~m] = 0
            d = d - gauss(d, 4); return float(np.median(np.abs(d[m])))
        out[k] = dict(baseline_med_abs_dlog=err(pred_b), ps_med_abs_dlog=err(pred_ps), baseline_hp=err_hp(pred_b), ps_hp=err_hp(pred_ps))
        log(f"  光度立体 留一 {k}：预测该帧辐亮度 中位 |Δlog| 基线 {out[k]['baseline_med_abs_dlog']:.3f} / 光度立体 {out[k]['ps_med_abs_dlog']:.3f}；"
            f"8 mm 以下 基线 {out[k]['baseline_hp']:.3f} / 光度立体 {out[k]['ps_hp']:.3f}")
    rho, n = solve(range(nf))
    ang = np.degrees(np.arccos(np.clip((n*n_s).sum(0), -1, 1)))
    out["ps_vs_stereo_normal_deg_median"] = float(np.nanmedian(ang[np.isfinite(rho0)]))
    np.savez(OUT/"分离"/"光度立体.npz", rho=rho.astype(np.float32), n=n.astype(np.float16))
    log(f"  光度立体：太阳方向矩阵奇异值 {', '.join(f'{x:.2f}' for x in sv)}（条件数 {out['cond']:.1f}）；与立体法线夹角中值 {out['ps_vs_stereo_normal_deg_median']:.1f}°")
    return out


# ── ③ 切块 ──────────────────────────────────────────────────────────────────────────────
M12_POS = {"钻孔A": (-2.162, -0.519), "钻孔B": (-2.054, -0.611), "磨蚀斑": (-2.217, -0.490)}   # ENU 米，见 cmd_cut 的注释
TREND_SIGMA = 0.5                             # 去低频：0.5 m（同 57 ⑨ 中观），先去平面
NAV_H_LP = 0.94                               # Navcam 高度低通 σ（格）：1 cm 波长处响应 0.5（立体高度只可信到 ~1 cm）


def shift_fill(arrs, ok, seed=0, rmin=20, rmax=150, it=60):
    """空洞纹理补：整块随机平移（循环），用平移后有值的格补当前空洞（arrs 同步），同 57 的 shift_fill 思路。"""
    rng = np.random.default_rng(seed); ok = ok.copy(); arrs = [a.copy() for a in arrs]
    for _ in range(it):
        if ok.all(): break
        dy, dx = rng.integers(rmin, rmax, 2)*rng.choice([-1, 1], 2)
        src_ok = np.roll(ok, (dy, dx), (0, 1)); take = ~ok & src_ok
        for a in arrs:
            sh = np.roll(a, (dy, dx), (-2, -1)); a[..., take] = sh[..., take]
        ok |= take
    return arrs, ok


def smooth_fill(x, ok):
    """空洞用逐级放大的归一化高斯补平滑值（4 → 16 → 64 → 256 格）。"""
    y = np.where(ok, x, np.nan); out = np.where(ok, x, np.nan)
    for sg in (4, 16, 64, 256):
        v, _ = nan_gauss(y, sg); hole = ~np.isfinite(out); out[hole] = v[hole]
        if np.isfinite(out).all(): break
    return np.where(np.isfinite(out), out, np.nanmedian(x[ok]))


def fill_patch(a3, hh, ok, seed=0, rmin=20, rmax=150):
    """样块空洞：低频（平滑插值）+ 高频细节（σ 8 格以下，整块随机平移搬来）。反照率在 log 里做。
    直接平移原值会在空洞边留下台阶（高度差几厘米），所以只搬细节。"""
    la = np.log(np.maximum(np.where(ok[None], a3, np.nan), 1e-9))
    lowa = np.stack([smooth_fill(la[c], ok) for c in range(3)]); lowh = smooth_fill(hh, ok)
    da = np.where(ok[None], la - np.stack([gauss(lowa[c], 8) for c in range(3)]), 0)
    dh = np.where(ok, hh - gauss(lowh, 8), 0)
    (da, dh), _ = shift_fill([da, dh], ok, seed=seed, rmin=rmin, rmax=rmax)
    A_ = np.exp(np.where(ok[None], la, np.stack([gauss(lowa[c], 8) for c in range(3)]) + da))
    H_ = np.where(ok, hh, gauss(lowh, 8) + dh)
    return A_.astype(np.float32), H_.astype(np.float32)


def plane_remove(z):
    ny, nx = z.shape; I, J = np.mgrid[0:ny, 0:nx]
    A = np.c_[np.ones(z.size), I.ravel(), J.ravel()]
    c = np.linalg.lstsq(A, z.ravel(), rcond=None)[0]
    return z - (A @ c).reshape(z.shape)


def make_detail(A3, H, px, h_lp=0.0):
    """A3 (3,N,N) 反照率、H (N,N) 高度（米，可 None）→ 反照率细节（均值 1，逐通道）、高度细节（米，零均值）；都做 Moisan 周期分解。"""
    sig = TREND_SIGMA/px
    la = np.log(np.maximum(A3, 1e-9))
    det = []
    for c in range(3):
        x = plane_remove(la[c]); x = x - gauss(x, sig); det.append(np.exp(x))
    Ad = np.stack(det, -1); Ad /= Ad.reshape(-1, 3).mean(0)
    Ad = periodic(np.clip(Ad, 0.3, 2.5)); Ad = np.clip(Ad/Ad.reshape(-1, 3).mean(0), 0.3, 2.5)
    Hd = None
    if H is not None:
        z = plane_remove(H); z = z - gauss(z, sig)
        if h_lp > 0: z = gauss(z, h_lp)
        Hd = periodic(z); Hd -= Hd.mean()
    return Ad.astype(np.float32), (Hd.astype(np.float32) if Hd is not None else None)


def classify(A, H, ok):
    """亮度分割 + 形态学：岩板 = 大块连通亮区（含裂缝）、碎片 = 小块亮区、暗沙 = 其余。返回 (类图 0 沙/1 碎片/2 岩板, 亮度对数残差)。"""
    from scipy.ndimage import binary_opening, binary_closing, binary_dilation, label
    Y = A.mean(0)
    ly = np.log(np.maximum(Y, 1e-9)); ly[~ok] = np.nan
    lb, _ = nan_gauss(ly, 1.5/CS)                                         # 只去 1.5 m 以上的趋势（工作区边缘光照/帧数不均），岩板内部仍算亮
    lr = ly - lb
    hist, edges = np.histogram(lr[ok & np.isfinite(lr)], 200, (-1, 1)); mode = edges[np.argmax(hist)] + 0.005
    bright = np.nan_to_num(lr, nan=-9) > mode + 0.22                       # 亮于暗沙众数 ×1.25
    # 岩板在这里碎成几厘米的块、缝 1–5 mm，按连通块分不出来；改按 2.5 cm 邻域里亮格的占比：
    # > 0.6 = 岩板铺面（板 + 缝），0.15–0.6 = 碎片砾石，< 0.15 = 暗沙
    bd = gauss(bright.astype(np.float32), 0.025/CS)
    slab = binary_closing(bd > 0.6, np.ones((5, 5)))
    cls = np.zeros(Y.shape, np.uint8); cls[(bd > 0.15) & ~slab] = 1; cls[slab] = 2
    cls[~ok] = 255
    return cls, lr, float(mode)


def pick_windows(score, N, k=3, border_pen=None):
    from scipy.ndimage import uniform_filter
    sc = uniform_filter(score, N)
    if border_pen is not None: sc = sc - border_pen
    h = N//2; sc[:h] = sc[-h:] = sc[:, :h] = sc[:, -h:] = -9
    out = []
    for _ in range(k):
        i, j = np.unravel_index(np.argmax(sc), sc.shape)
        if sc[i, j] < 0.3: break
        out.append((i - h, j - h, float(sc[i, j])))
        sc[max(i - N, 0):i + N, max(j - N, 0):j + N] = -9
    return out


def export_godot(name, Ad, Hd, px, extra):
    """现有细节图块格式：<名>_albedo.png（RGB，反照率细节 ×0.5）、<名>_height.bin（int32 宽高 + float32 米）。"""
    from PIL import Image
    d = OUT/"godot"; d.mkdir(parents=True, exist_ok=True)
    Image.fromarray((np.clip(Ad*0.5, 0, 1)*255 + 0.5).astype(np.uint8), "RGB").save(d/f"{name}_albedo.png")   # 同 57：第 0 行在南
    rng_ = float(np.percentile(np.abs(Hd), 99.5))*1.2 + 1e-6
    with open(d/f"{name}_height.bin", "wb") as f:
        np.array(Hd.shape[::-1], np.int32).tofile(f); Hd.astype(np.float32).tofile(f)
    return dict(albedo=f"{name}_albedo.png", height=f"{name}_height.bin", size=px*Ad.shape[0], height_range=rng_, px=px, **extra)


def ortho_points(E, N, U, vals, x0, y0, n, cs):
    jj = np.floor((E - x0)/cs).astype(np.int64); ii = np.floor((N - y0)/cs).astype(np.int64)
    m = (jj >= 0) & (jj < n) & (ii >= 0) & (ii < n) & np.isfinite(U)
    G, cnt = splat(ii[m], jj[m], n, n, [U[m]] + [v[m] for v in vals])
    (h, *rest), ok = fill_small(list(G), cnt, s=1.0)
    return h, np.stack(rest) if rest else None, ok, cnt


def demosaic_rggb(a):
    """(1,H,W) RGGB → (3,H,W)，双线性（归一化卷积）。"""
    from scipy.ndimage import convolve
    b = np.nan_to_num(a[0]); ny, nx = b.shape
    I, J = np.mgrid[0:ny, 0:nx]
    masks = [(I % 2 == 0) & (J % 2 == 0), (I % 2) != (J % 2), (I % 2 == 1) & (J % 2 == 1)]
    k = np.array([[1, 2, 1], [2, 4, 2], [1, 2, 1]], float)
    out = []
    for m in masks:
        m = m & np.isfinite(a[0])
        out.append(convolve(np.where(m, b, 0), k, mode="nearest")/np.maximum(convolve(m.astype(float), k, mode="nearest"), 1e-9))
    o = np.stack(out).astype(np.float32); o[:, ~np.isfinite(a[0])] = np.nan
    return o


def mastcam_patch(xyz_files, cs, N, tag, sky=0.5, center=None, search=1.6):
    """Mastcam-Z 110 mm 若干帧 → cs 格正射（多帧平均）→ 简单去光影（Lambert 直射 × 投射阴影 + 常数天光）→ N×N 样块。"""
    Es, Ns, Us, cols = [], [], [], []
    sun = None; crops = []
    for xf in xyz_files:
        P, lab = read_img(str(xf))
        iof = sorted(xf.parent.glob(xf.name[:23].replace("ZLF", "ZL0") + "IOF_*.IMG"))
        if not iof: continue
        I, _ = read_img(str(iof[-1])); rgb = demosaic_rggb(I)
        if rgb.shape[1:] != P.shape[1:]: log(f"  {xf.name}: IOF {rgb.shape} 与 XYZ {P.shape} 不同尺寸，跳过"); continue
        off, q = rover_pose_in_site(lab); az, el = site_sun(lab); sun = (az, el)
        v = np.any(P != 0, 0) & np.all(np.isfinite(rgb), 0)
        Es.append(P[1][v] - off[1]); Ns.append(P[0][v] - off[0]); Us.append(-(P[2][v] - off[2])); cols.append(rgb[:, v])
        crops.append((P, off, rgb))
    E = np.concatenate(Es); Nn = np.concatenate(Ns); U = np.concatenate(Us); col = np.concatenate(cols, 1)
    cx, cy = (np.median(E), np.median(Nn)) if center is None else center
    if center is None:                                                     # 先在大范围上落格，挑有效率最高的 N×N 窗
        M_ = int(search/cs); hb = M_*cs/2
        _, _, okb, _ = ortho_points(E, Nn, U, [], cx - hb, cy - hb, M_, cs)
        from scipy.ndimage import uniform_filter
        f = uniform_filter(okb.astype(np.float32), N); f[:N//2] = f[-N//2:] = f[:, :N//2] = f[:, -N//2:] = 0
        i, j = np.unravel_index(np.argmax(f), f.shape)
        cx, cy = cx - hb + (j + .5)*cs, cy - hb + (i + .5)*cs
    half = N*cs/2
    h, rgb, ok, cnt = ortho_points(E, Nn, U, list(col), cx - half, cy - half, N, cs)
    Hf, _ = nan_gauss(h, 4.0); Hf = np.where(np.isfinite(h), h, Hf); Hf = np.where(np.isfinite(Hf), Hf, np.nanmedian(h))
    s = sun_enu(*sun)
    gy, gx = np.gradient(gauss(Hf, 3.0), cs)
    n = np.stack([-gx, -gy, np.ones_like(gx)]); n /= np.linalg.norm(n, axis=0)
    mu0 = np.clip(np.tensordot(s, n, 1), 0, 1)
    # 投射阴影（地平角，CPU 简版：这里的块小）
    sh = np.zeros_like(Hf); de, dn = math.sin(math.radians(sun[0])), math.cos(math.radians(sun[0]))
    tmax = np.full_like(Hf, -10)
    for k in range(1, int(0.15/cs)):
        di, dj = int(round(k*dn)), int(round(k*de))
        src = np.roll(Hf, (-di, -dj), (0, 1)); tmax = np.maximum(tmax, (src - Hf)/(math.hypot(di, dj)*cs))
    lit = (tmax < math.tan(math.radians(sun[1]))).astype(np.float32)
    shade = mu0*lit + sky
    A = rgb/np.maximum(shade, 1e-3)[None]
    good = ok & np.all(np.isfinite(A), 0) & (lit > 0)
    return dict(h=h, A=A, rgb=rgb, ok=good, cnt=cnt, sun=sun, center=(float(cx), float(cy)), crops=crops, bounds=(cx - half, cy - half, cs, N))


_PHOTO = {}


def photo_crop_navcam(x0, y0, size, sol=530):
    """同一块地在 Navcam 原图（sol 530 14:33 RAS 左）上的透视裁切：取 ENU 落在块内的像素的外包框。"""
    if sol not in _PHOTO:
        fr = [f for f in navcam_frames() if f["sol"] == sol][0]
        P, lab = read_img(str(fr["xyz"])); off, _ = rover_pose_in_site(lab)
        ras, _ = read_img(str(fr["rasL"]))
        _PHOTO[sol] = (P[1] - off[1], P[0] - off[0], np.any(P != 0, 0), ras)
    E, N, v, ras = _PHOTO[sol]
    m = v & (E >= x0) & (E < x0 + size) & (N >= y0) & (N < y0 + size)
    r, c = np.nonzero(m)
    if len(r) < 100: return None
    r0, r1 = np.percentile(r, [0.5, 99.5]).astype(int); c0, c1 = np.percentile(c, [0.5, 99.5]).astype(int)
    im = np.moveaxis(ras[:, r0:r1, c0:c1], 0, -1)
    return im/np.nanpercentile(im, 99.5)


def cmd_cut(args):
    from scipy.ndimage import zoom
    t0 = time.time()
    B = np.load(OUT/"分离"/"基线.npz"); A, H = B["A"], B["H"]; nH = B["nH"]
    ok = np.all(np.isfinite(A), 0) & np.isfinite(H) & (nH >= 4)
    gx0 = json.loads((OUT/"正射"/"格.json").read_text())
    cls, lr, mode = classify(A, H, ok)
    (OUT/"切块").mkdir(parents=True, exist_ok=True)
    np.savez_compressed(OUT/"切块"/"分类.npz", cls=cls, lr=lr.astype(np.float16))
    frac = {k: float((cls == i).sum()/ok.sum()) for i, k in enumerate(["暗沙", "碎片", "岩板"])}
    log(f"切块：分类 {', '.join(f'{k} {v*100:.0f}%' for k, v in frac.items())}（暗沙众数 log {mode:+.2f}，亮阈 +0.22）")
    sm = (slice(None, None, 4), slice(None, None, 4))
    pal = np.array([[0.35, 0.22, 0.15], [0.95, 0.75, 0.2], [0.95, 0.9, 0.8]])
    cv = np.zeros(cls[sm].shape + (3,)); c_ = cls[sm]
    for i in range(3): cv[c_ == i] = pal[i]
    sand = (cls == 0).astype(np.float32); frag = (cls == 1).astype(np.float32); slab = (cls == 2).astype(np.float32); okf = ok.astype(np.float32)
    fragd = gauss(frag, 0.03/CS)
    patches = []
    def add(typ, i0, j0, N, sc, note):
        sl = (slice(i0, i0 + N), slice(j0, j0 + N))
        a = A[:, sl[0], sl[1]].copy(); hh = H[sl].copy(); m = ok[sl].copy()
        hole = float(1 - m.mean())
        if hole > 0.08 or sum(1 for p in patches if p["type"] == typ) >= 3:
            log(f"  跳过 {typ} 候选 ({i0}, {j0})：空洞 {hole*100:.0f}%"); return
        a, hh = fill_patch(a, hh, m, seed=len(patches))
        Ad, Hd = make_detail(a, hh, CS, NAV_H_LP)
        x0 = gx0["x0"] + j0*CS; y0 = gx0["y0"] + i0*CS
        name = f"{typ}_{sum(1 for p in patches if p['type'] == typ) + 1}"
        np.savez_compressed(OUT/"切块"/f"{name}.npz", A=Ad, H=Hd, A_raw=a.astype(np.float32), H_raw=hh.astype(np.float32), mask=m)
        meta = dict(type=typ, name=name, x0=x0, y0=y0, size=N*CS, px=CS, score=sc, hole_frac=hole, note=note,
                    src="Navcam NCAM00712 sol 520–532 9 帧，基线去光影")
        meta["godot"] = export_godot(name, Ad, Hd, CS, dict(来源=meta["src"], ENU=[x0, y0]))
        patches.append(meta)
        log(f"  {name}：ENU ({x0:+.2f}, {y0:+.2f}) m，{N*CS:.2f} m / {CS*1e3:.0f} mm，得分 {sc:.2f}，空洞补 {hole*100:.1f}%，"
            f"反照率细节 σ(log) {np.log(Ad.mean(-1)).std():.3f}，高度 RMS {Hd.std()*1e3:.2f} mm")
        cv[i0//4:(i0 + N)//4, j0//4] = cv[i0//4:(i0 + N)//4, (j0 + N)//4 - 1] = [0, 1, 1]
        cv[i0//4, j0//4:(j0 + N)//4] = cv[(i0 + N)//4 - 1, j0//4:(j0 + N)//4] = [0, 1, 1]
    # M1 暗沙：暗沙占比高、碎片少、全是实测
    for i0, j0, sc in pick_windows(sand*okf - 0.5*fragd - 0.6*slab, 768, 5):
        if sc >= 0.88: add("M1", i0, j0, 768, sc, "暗沙（含风成小波纹与零星小砾）")
    # M2 岩板：板占比高，边框上的板少（整岛不被切断）
    edge = slab.copy()
    for i0, j0, sc in pick_windows(slab*okf + 0.3*frag, 512, 5):
        N = 512; e = np.r_[slab[i0, j0:j0 + N], slab[i0 + N - 1, j0:j0 + N], slab[i0:i0 + N, j0], slab[i0:i0 + N, j0 + N - 1]].mean()
        add("M2", i0, j0, N, sc, f"浅色裂隙岩板岛 + 板间沙；边框过板比例 {e*100:.0f}%")
    # M3 砾石裙：碎片密度高、板少
    taken = np.zeros_like(okf)
    for p in patches:
        if p["type"] == "M2":
            j0_ = int(round((p["x0"] - gx0["x0"])/CS)); i0_ = int(round((p["y0"] - gx0["y0"])/CS)); taken[i0_:i0_ + 512, j0_:j0_ + 512] = 1
    for i0, j0, sc in pick_windows(okf*frag - 0.5*slab - 2*taken, 512, 5):
        add("M3", i0, j0, 512, sc, "棱角碎片砾石铺面")
    save_img(OUT/"切块"/"分类与选块.jpg", cv)
    # M12：sol 502（磨蚀/取芯之前）与正午 sol 520 12:46（同样光照）的差分定位，在基线反照率上切 20 cm 贴花
    try:
        F0 = load_frame("0502_1246"); F1 = load_frame("0520_1246")
        d = np.log(np.maximum(F1["rgb"].mean(0), 1e-9)) - np.log(np.maximum(F0["rgb"].mean(0), 1e-9))
        dh = F1["h"] - F0["h"]
        m = np.isfinite(d) & np.isfinite(dh)
        d = np.where(m, d - np.nanmedian(d[m]), 0); dh = np.where(m, dh, 0)
        from scipy.ndimage import binary_erosion
        Xc = gx0["x0"] + (np.arange(d.shape[1]) + .5)*CS; Yc = gx0["y0"] + (np.arange(d.shape[0]) + .5)*CS
        near = np.hypot(Xc[None, :], Yc[:, None]) < 3.8                        # 机械臂工作区在 ~2–3 m
        inner = binary_erosion(m, np.ones((41, 41)))                             # 离两帧有效区边缘 4 cm 以上
        sc = (gauss(np.abs(d), 4) + gauss(np.abs(dh), 4)/0.004*0.1)*near*inner
        np.savez_compressed(OUT/"切块"/"M12_差分.npz", d=d.astype(np.float16), dh=dh.astype(np.float16))
        # 差分最大处落在被扰动的岩板面（岩屑、粉尘），不正好在孔上；孔和磨蚀斑的位置改由 sol 530 原图（NLF RAS 左）上人工点选的像素
        # 经同帧 XYZ 换成 ENU（行, 列）：钻孔 A (2327, 3155)、钻孔 B (2361, 2965)、磨蚀斑 (2314, 3220)，见 样块对比_M12位置.jpg
        found = []
        for nm, (ex, ny_) in M12_POS.items():
            i = int((ny_ - gx0["y0"])/CS); j = int((ex - gx0["x0"])/CS)
            found.append((i, j, nm, float(d[i - 5:i + 6, j - 5:j + 6].mean()), float(dh[i - 5:i + 6, j - 5:j + 6].mean())))
        cands = []
        for _ in range(4):
            i, j = np.unravel_index(np.argmax(sc), sc.shape)
            cands.append([float(gx0["x0"] + (j + .5)*CS), float(gx0["y0"] + (i + .5)*CS), float(d[i - 5:i + 6, j - 5:j + 6].mean()), float(dh[i - 5:i + 6, j - 5:j + 6].mean()*1e3)])
            sc[max(i - 60, 0):i + 60, max(j - 60, 0):j + 60] = 0
        log(f"  M12 差分候选（ENU x, y, Δlog, Δh mm）：{cands}")
        for k, (i, j, label_, dd, ddh) in enumerate(found):
            N = 80; i0, j0 = max(i - N//2, 0), max(j - N//2, 0)
            sl = (slice(i0, i0 + N), slice(j0, j0 + N))
            a = A[:, sl[0], sl[1]]; hh = H[sl]; mm = ok[sl]
            a, hh = fill_patch(a, hh, mm, seed=99 + k, rmin=5, rmax=30)
            la = np.log(np.maximum(a, 1e-9)); Ad = np.exp(la - la.reshape(3, -1).mean(1)[:, None, None]).transpose(1, 2, 0)
            Hd = gauss(plane_remove(hh), NAV_H_LP)
            x0 = gx0["x0"] + j0*CS; y0 = gx0["y0"] + i0*CS
            name = f"M12_{k + 1}"
            np.savez_compressed(OUT/"切块"/f"{name}.npz", A=Ad.astype(np.float32), H=Hd.astype(np.float32), A_raw=a, H_raw=hh, mask=mm)
            meta = dict(type="M12", name=name, x0=x0, y0=y0, size=N*CS, px=CS, center_enu=[gx0["x0"] + (j + .5)*CS, gx0["y0"] + (i + .5)*CS],
                        dlog=dd, dh_mm=ddh*1e3, label=label_, note=f"{label_}贴花（不平铺、不做周期分解）；位置由 sol 530 原图点选", src="Navcam 基线反照率")
            meta["godot"] = export_godot(name, Ad, Hd, CS, dict(来源=meta["src"], ENU=[x0, y0], 贴花=True))
            patches.append(meta)
            log(f"  {name}（{label_}）：中心 ENU ({meta['center_enu'][0]:+.3f}, {meta['center_enu'][1]:+.3f}) m，Δlog 亮度 {dd:+.2f}，Δ高度 {ddh*1e3:+.1f} mm")
    except Exception as e:
        log(f"  M12 失败：{e!r}")
    # Mastcam-Z：M4 撞击沙纹（ZCAM08544 sol 520 / 531），M8 纹层（ZCAM08547 sol 523）
    Z = PDS/"批2"
    for typ, sol, cs, N in (("M4", 520, 0.001, 768), ("M4", 531, 0.001, 768), ("M8", 523, 0.0005, 768)):
        try:
            xs = [f for f in sorted((Z/f"sol{sol:04d}").glob("ZLF_*XYZ_*.IMG"))]
            xs = [f for f in xs if read_img(str(f))[0].shape[1] > 500]
            while True:                                                        # 有效率 < 75% 就缩小窗口（不小于 512 格）
                r = mastcam_patch(xs, cs, N, f"{typ}_{sol}"); m = r["ok"]
                if m.mean() >= 0.75 or N <= 512: break
                N = int(N*0.85)//16*16
            a = np.where(m[None], r["A"], np.nan); hh = r["h"]
            fill = float(1 - m.mean())
            a, hh = fill_patch(a, hh, m, seed=sol, rmin=10, rmax=N//3)
            Ad, Hd = make_detail(a, hh, cs, 1.5)                               # Mastcam 高度可信到 ~3–5 mm：σ 1.5 格
            name = f"{typ}_{sum(1 for p in patches if p['type'] == typ) + 1}"
            x0, y0 = r["bounds"][0], r["bounds"][1]
            np.savez_compressed(OUT/"切块"/f"{name}.npz", A=Ad, H=Hd, A_raw=a.astype(np.float32), H_raw=hh.astype(np.float32), mask=m, rgb=r["rgb"].astype(np.float32))
            meta = dict(type=typ, name=name, x0=float(x0), y0=float(y0), size=N*cs, px=cs, hole_frac=fill, sun=r["sun"],
                        src=f"Mastcam-Z 110 mm sol {sol} {', '.join(f.name[4:23] for f in xs)}，Lambert + 常数天光 0.5 去光影")
            meta["godot"] = export_godot(name, Ad, Hd, cs, dict(来源=meta["src"], ENU=[float(x0), float(y0)]))
            patches.append(meta)
            # 实拍裁切：IOF 原图上落在块内的像素外包框
            best_ = None
            for P, off, rgb in r["crops"]:                                    # 取块内像素最多的那一帧
                E = P[1] - off[1]; Nn = P[0] - off[0]
                mm = np.any(P != 0, 0) & (E >= x0) & (E < x0 + N*cs) & (Nn >= y0) & (Nn < y0 + N*cs)
                if best_ is None or mm.sum() > best_[0].sum(): best_ = (mm, rgb)
            mm, rgb = best_; rr, cc = np.nonzero(mm)
            if len(rr):
                im = np.moveaxis(rgb[:, rr.min():rr.max(), cc.min():cc.max()], 0, -1); np.save(OUT/"切块"/f"{name}_照片.npy", (im/np.nanpercentile(im, 99.5)).astype(np.float16))
            log(f"  {name}：{N*cs:.2f} m / {cs*1e3:.1f} mm，ENU ({x0:+.2f}, {y0:+.2f})，有效 {m.mean()*100:.0f}%，"
                f"反照率细节 σ(log) {np.log(Ad.mean(-1)).std():.3f}，高度 RMS {Hd.std()*1e3:.2f} mm")
        except Exception as e:
            import traceback; traceback.print_exc(); log(f"  {typ} sol {sol} 失败：{e!r}")
    # Navcam 块的实拍裁切（sol 530 14:33 原图）
    for p in patches:
        if p["type"] in ("M1", "M2", "M3", "M12"):
            im = photo_crop_navcam(p["x0"], p["y0"], p["size"])
            if im is not None: np.save(OUT/"切块"/f"{p['name']}_照片.npy", im.astype(np.float16))
    # 中观替换包：把每类第一块按现有 meso_k 命名，供以后 A/B（不覆盖 godot/数据/sol0530）
    rep = OUT/"godot"/"中观替换"; rep.mkdir(parents=True, exist_ok=True)
    det = {}
    for k, typ in ((0, "M1"), (1, "M3"), (2, "M2"), (3, "M1")):
        p = next((q for q in patches if q["type"] == typ), None)
        if p is None: continue
        g = p["godot"]
        for ext in ("albedo", "height"):
            src = OUT/"godot"/g[ext]; dst = rep/f"meso_{k}_{ext}{'.png' if ext == 'albedo' else '.bin'}"
            dst.write_bytes(src.read_bytes())
        det[f"meso_{k}"] = dict(albedo=f"meso_{k}_albedo.png", height=f"meso_{k}_height.bin", size=g["size"], height_range=g["height_range"], 来自=p["name"])
    (rep/"detail.json").write_text(json.dumps(det, ensure_ascii=False, indent=1))
    (OUT/"切块"/"样块.json").write_text(json.dumps(patches, ensure_ascii=False, indent=1, default=float))
    (OUT/"godot"/"样块.json").write_text(json.dumps({p["name"]: p["godot"] for p in patches}, ensure_ascii=False, indent=1, default=float))
    log(f"切块完成：{len(patches)} 块（{time.time() - t0:.0f} s）")


# ── ④ 对比 ──────────────────────────────────────────────────────────────────────────────
CUR = {"M1": 0, "M4": 0, "M2": 2, "M8": 2, "M3": 1, "M12": 2}    # 新样块 ↔ 现有地类（0 沙、1 砾石风化层、2 基岩、3 暗色岩块）
SUN_R = (225.0, 30.0)                                             # 对比着色的固定太阳（方位、高度）
BASE = np.array([0.62, 0.42, 0.30])                               # 对比着色的底色（火星土壤，显示用）


def load_current(kind, k):
    from PIL import Image
    J = json.loads((GD/"scene.json").read_text())["detail"][f"{kind}_{k}"]
    A_ = np.asarray(Image.open(GD/J["albedo"]).convert("RGB")).astype(np.float32)/255*J.get("gain", 2.0)   # 61 按块存 1/gain×（老图块 2）
    raw = np.fromfile(GD/J["height"], np.float32); w, h = raw[:2].view(np.int32)
    H_ = raw[2:].reshape(h, w)
    return A_, H_, J["size"]/A_.shape[0]


def tile_metrics(Ad, Hd, px):
    lum = np.log(np.maximum(Ad.mean(-1), 1e-6))
    rb = np.log(np.maximum(Ad[..., 0], 1e-6)/np.maximum(Ad[..., 2], 1e-6))
    hs = gauss(Hd, max(0.005/px, 0.5)); gy, gx = np.gradient(hs, px)
    F = np.abs(np.fft.fft2((Hd - Hd.mean())*np.outer(np.hanning(Hd.shape[0]), np.hanning(Hd.shape[1]))))**2
    ky = np.fft.fftfreq(Hd.shape[0], px); kx = np.fft.fftfreq(Hd.shape[1], px)
    k = np.hypot(*np.meshgrid(ky, kx, indexing="ij"))
    lam_edges = np.geomspace(0.5, 0.02, 15); res = []
    for l0, l1 in zip(lam_edges[:-1], lam_edges[1:]):
        m = (k >= 1/l0) & (k < 1/l1); res.append((np.sqrt(l0*l1), F[m].sum()))
    lam_dom = max(res, key=lambda t: t[1])[0] if res else float("nan")
    m = (k > 1/0.2) & (k < 1/max(0.02, 4*px))
    beta = float(-np.polyfit(np.log(k[m]), np.log(F[m] + 1e-30), 1)[0]) if m.sum() > 10 else float("nan")
    return dict(albedo_contrast=float(lum.std()), rb_contrast=float(rb.std()), h_rms_mm=float(Hd.std()*1e3),
                slope_rms_1cm_deg=float(np.degrees(np.arctan(np.sqrt(np.mean(gx**2 + gy**2))))), lam_dom_m=float(lam_dom), psd_beta=beta,
                px_mm=px*1e3, size_m=px*Hd.shape[0])


def render(Ad, Hd, px):
    gy, gx = np.gradient(Hd, px)
    n = np.stack([-gx, -gy, np.ones_like(gx)]); n /= np.linalg.norm(n, axis=0)
    sh = np.clip(np.tensordot(sun_enu(*SUN_R), n, 1), 0, 1)
    return np.clip(BASE*Ad*(0.85*sh[..., None]/math.sin(math.radians(SUN_R[1]))*0.6 + 0.25), 0, 1)


def crop_m(arr, px, W):
    n = min(arr.shape[0], int(round(W/px))); i0 = (arr.shape[0] - n)//2
    return arr[i0:i0 + n, i0:i0 + n]


def panel(img, S):
    from PIL import Image
    a = to_u8(np.nan_to_num(img))
    if a.ndim == 2: a = np.repeat(a[..., None], 3, -1)
    im = Image.fromarray(a[::-1].copy() if a.shape[0] == a.shape[1] else a)   # 地图类北朝上；照片原样
    im.thumbnail((S, S), Image.LANCZOS) if max(im.size) > S else None
    if max(im.size) < S: im = im.resize((S, int(S*im.size[1]/im.size[0])) if im.size[0] >= im.size[1] else (int(S*im.size[0]/im.size[1]), S), Image.LANCZOS)
    c = Image.new("RGB", (S, S), (20, 20, 20)); c.paste(im, ((S - im.size[0])//2, (S - im.size[1])//2))
    return c


def sheet(rows, cols, S, path, title, row_labels):
    from PIL import Image, ImageDraw, ImageFont
    fp = next((f for f in ["/usr/share/fonts/google-noto-sans-mono-cjk-vf-fonts/NotoSansMonoCJK-VF.ttc", "/usr/share/fonts/fandol/FandolHei-Regular.otf"] if os.path.exists(f)), None)
    font = ImageFont.truetype(fp, 15) if fp else ImageFont.load_default(); fb = ImageFont.truetype(fp, 19) if fp else font
    L = 64; T = 58
    W = L + S*len(cols); Hh = T + S*len(rows)
    im = Image.new("RGB", (W, Hh), (12, 12, 12)); dr = ImageDraw.Draw(im)
    dr.text((8, 6), title, fill=(240, 240, 240), font=fb)
    for c, t in enumerate(cols): dr.text((L + c*S + 6, 34), t, fill=(220, 200, 160), font=font)
    for r, (cells, lab) in enumerate(zip(rows, row_labels)):
        for ln, t in enumerate(lab.split("\n")): dr.text((6, T + r*S + 8 + ln*20), t, fill=(220, 220, 220), font=font)
        for c, cell in enumerate(cells):
            if cell is not None: im.paste(cell, (L + c*S, T + r*S))
    im.save(path, quality=86)


def cmd_compare(args):
    from PIL import Image
    t0 = time.time()
    D = OUT/"对比"; D.mkdir(parents=True, exist_ok=True)
    P = json.loads((OUT/"切块"/"样块.json").read_text())
    first = {}
    for p in P: first.setdefault(p["type"], p)
    nums = {}
    # 现有图块
    cur = {}
    for k in range(4):
        cur[("meso", k)] = load_current("meso", k); cur[("micro", k)] = load_current("micro", k)
        A_, H_, px = cur[("meso", k)]; nums[f"现有 中观 {CLASSES[k]}"] = tile_metrics(A_, H_, px)
        A_, H_, px = cur[("micro", k)]; nums[f"现有 微观 {CLASSES[k]}"] = tile_metrics(A_, H_, px)
    for p in P:
        Z = np.load(OUT/"切块"/f"{p['name']}.npz")
        if p["type"] != "M12": nums[f"新 {p['name']}"] = tile_metrics(Z["A"], Z["H"], p["px"])
    # 表 1：1 m 视野（中观尺度）
    S = 218; rows, labs = [], []
    for typ, lab in (("M1", "M1\n暗沙"), ("M2", "M2\n岩板"), ("M3", "M3\n砾石"), ("M4", "M4\n沙纹"), ("M8", "M8\n纹层")):
        if typ not in first: continue
        p = first[typ]; Z = np.load(OUT/"切块"/f"{p['name']}.npz"); k = CUR[typ]
        A_, H_, px = cur[("meso", k)]; W = min(1.0, p["size"])
        cA, cH = crop_m(A_, px, W), crop_m(H_, px, W); nA, nH = crop_m(Z["A"], p["px"], W), crop_m(Z["H"], p["px"], W)
        ph = OUT/"切块"/f"{p['name']}_照片.npy"
        rows.append([panel(cA*0.5, S), panel(hillshade(cH, px, *SUN_R), S), panel(render(cA, cH, px), S),
                     panel(nA*0.5, S), panel(hillshade(nH, p["px"], *SUN_R), S), panel(render(nA, nH, p["px"]), S),
                     panel(np.load(ph).astype(np.float32), S) if ph.exists() else None])
        labs.append(lab + f"\n{W:.2f} m")
    cols = [f"现有中观·{''}反照率", "现有·高度晕渲", "现有·着色", "新·反照率细节", "新·高度晕渲", "新·着色", "实拍（同一块地）"]
    sheet(rows, cols, S, D/"样块对比_1m视野.jpg", f"现有中观图块（类 {'/'.join(CLASSES)}，1 cm）vs 新真火星样块：同 1 m 视野，太阳 {SUN_R[0]:.0f}°/{SUN_R[1]:.0f}°", labs)
    # 表 2：25 cm 视野（微观尺度：现有微观图块 vs 新样块，新样块 2 mm/1 mm 格放大）
    S2 = 300; rows, labs = [], []
    for typ, lab in (("M1", "M1\n暗沙"), ("M2", "M2\n岩板"), ("M3", "M3\n砾石"), ("M4", "M4\n沙纹")):
        if typ not in first: continue
        p = first[typ]; Z = np.load(OUT/"切块"/f"{p['name']}.npz"); k = CUR[typ]
        A_, H_, px = cur[("micro", k)]; W = 0.25
        cA, cH = crop_m(A_, px, W), crop_m(H_, px, W); nA, nH = crop_m(Z["A"], p["px"], W), crop_m(Z["H"], p["px"], W)
        rows.append([panel(render(cA, cH, px), S2), panel(render(nA, nH, p["px"]), S2), panel(nA*0.5, S2)])
        labs.append(lab + f"\n{W:.2f} m")
    sheet(rows, ["现有微观·着色（WATSON/MAHLI 等）", f"新·着色（{''}格距见表）", "新·反照率细节"], S2, D/"样块对比_25cm视野.jpg",
          "近看 25 cm：现有微观图块 vs 新样块（Navcam 2 mm / Mastcam-Z 1 mm 格，放大显示）", labs)
    # 表 3：全部变体 + M12 贴花（着色 | 实拍）
    S3 = 200; rows, labs = [], []
    for typ in ("M1", "M2", "M3", "M4", "M8", "M12"):
        ps = [p for p in P if p["type"] == typ]
        if not ps: continue
        cells = []
        for p in ps[:3]:
            Z = np.load(OUT/"切块"/f"{p['name']}.npz"); cells.append(panel(render(Z["A"], Z["H"], p["px"]), S3))
            ph = OUT/"切块"/f"{p['name']}_照片.npy"; cells.append(panel(np.load(ph).astype(np.float32), S3) if ph.exists() else None)
        rows.append(cells); labs.append(f"{typ}\n{ps[0]['size']:.2f} m\n{ps[0]['px']*1e3:.1f} mm")
    sheet(rows, ["变体1 着色", "变体1 实拍", "变体2 着色", "变体2 实拍", "变体3 着色", "变体3 实拍"], S3, D/"样块对比_全部变体.jpg",
          "全部样块变体（整块，着色）与同一块地的原始照片", labs)
    # 表 4：去光影效果（同一块 1 m：sol 530 14:33 辐亮 | sol 520 15:49 辐亮 | 基线反照率）
    B = np.load(OUT/"分离"/"基线.npz"); gx0 = json.loads((OUT/"正射"/"格.json").read_text())
    rows, labs = [], []
    for typ in ("M2", "M3", "M1"):
        if typ not in first: continue
        p = first[typ]; j0 = int(round((p["x0"] - gx0["x0"])/CS)); i0 = int(round((p["y0"] - gx0["y0"])/CS)); N = int(round(p["size"]/CS))
        sl = (slice(i0, i0 + N), slice(j0, j0 + N))
        cells = []
        for t in ("0530_1433", "0520_1549", "0531_1201"):
            F = load_frame(t); x = F["rgb"][:, sl[0], sl[1]]; x = np.moveaxis(x, 0, -1); cells.append(panel(x/np.nanpercentile(x, 99.5), 300))
        a = np.moveaxis(B["A"][:, sl[0], sl[1]], 0, -1); cells.append(panel(a/np.nanpercentile(a, 99.5), 300))
        rows.append(cells); labs.append(f"{typ}\n{N*CS:.2f} m")
    sheet(rows, ["sol 530 14:33 辐亮（太阳 223°/33°）", "sol 520 15:49（234°/19°）", "sol 531 12:01（181°/47°）", "基线反照率（9 帧）"], 300,
          D/"样块对比_去光影.jpg", "反照率/明暗分离：同一块地三种光照的正射辐亮 vs 分离后的反照率", labs)
    # M12 位置：sol 530 原图上标出差分找到的中心
    try:
        from PIL import ImageDraw, ImageFont
        m12 = [p for p in P if p["type"] == "M12"]
        photo_crop_navcam(-2.0, -0.8, 0.1)                                      # 填缓存
        E, Nn, v, ras = _PHOTO[530]
        pts = []
        for p in m12:
            cx, cy = p["center_enu"]; d = np.where(v, (E - cx)**2 + (Nn - cy)**2, 9)
            r, c = np.unravel_index(np.argmin(d), d.shape); pts.append((r, c, p["name"]))
        rs = [q[0] for q in pts]; cs_ = [q[1] for q in pts]
        r0, r1 = max(min(rs) - 500, 0), min(max(rs) + 500, ras.shape[1]); c0, c1 = max(min(cs_) - 700, 0), min(max(cs_) + 700, ras.shape[2])
        im = np.moveaxis(ras[:, r0:r1, c0:c1], 0, -1); im = to_u8(im/np.nanpercentile(im, 99.5))
        I_ = Image.fromarray(im); dr = ImageDraw.Draw(I_)
        fp = "/usr/share/fonts/google-noto-sans-mono-cjk-vf-fonts/NotoSansMonoCJK-VF.ttc"
        font = ImageFont.truetype(fp, 40) if os.path.exists(fp) else None
        for r, c, nm in pts:
            dr.ellipse((c - c0 - 60, r - r0 - 60, c - c0 + 60, r - r0 + 60), outline=(0, 255, 255), width=5)
            dr.text((c - c0 + 65, r - r0 - 60), nm, fill=(0, 255, 255), font=font)
        I_.thumbnail((1400, 1400)); I_.save(D/"样块对比_M12位置.jpg", quality=86)
    except Exception as e:
        log(f"  M12 位置图失败：{e!r}")
    # 工作区总览：分类与选块
    im = Image.open(OUT/"切块"/"分类与选块.jpg"); im.thumbnail((800, 800)); im.save(D/"样块对比_工作区分类.jpg", quality=86)
    (D/"数值.json").write_text(json.dumps(nums, ensure_ascii=False, indent=1))
    for k, v in nums.items():
        log(f"  {k:<16} 反照率对比 {v['albedo_contrast']:.3f}  R/B 对比 {v['rb_contrast']:.3f}  高度 RMS {v['h_rms_mm']:6.2f} mm  "
            f"1 cm 坡度 RMS {v['slope_rms_1cm_deg']:5.1f}°  主波长 {v['lam_dom_m']*100:5.1f} cm  谱指数 {v['psd_beta']:.2f}  （{v['size_m']:.2f} m / {v['px_mm']:.1f} mm）")
    log(f"对比完成（{time.time() - t0:.0f} s）")


def cmd_ortho(args):
    frs = navcam_frames()
    only = [a for a in args if a.isdigit()]
    ref = [f for f in frs if f["sol"] == 530][0]
    grid = grid_def()
    if grid is None or "--重定格" in args:
        ortho_frame(ref, None); grid = grid_def(); only = [x for x in only if x != "530"]
        if not only and [a for a in args if a.isdigit()]: register(); return
    todo = [f for f in frs if str(f["sol"]) in only] if only else frs
    nproc = int(next((a.split("=")[1] for a in args if a.startswith("--进程=")), "3"))
    if nproc > 1 and len(todo) > 1:
        from concurrent.futures import ProcessPoolExecutor
        with ProcessPoolExecutor(nproc) as ex:
            list(ex.map(ortho_frame, todo, [grid]*len(todo)))
    else:
        for f in todo: ortho_frame(f, grid)
    register()


if __name__ == "__main__":
    if len(sys.argv) < 2: print(__doc__); sys.exit(0)
    cmd, args = sys.argv[1], sys.argv[2:]
    {"正射": cmd_ortho, "配准": lambda a: register(), "分离": cmd_separate, "切块": cmd_cut, "对比": cmd_compare,
     "全部": lambda a: (cmd_ortho(a), cmd_separate(a), cmd_cut(a), cmd_compare(a))}[cmd](args)
