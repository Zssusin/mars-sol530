#!/usr/bin/env python3
"""
79 多视角一致性：近处地面「只在拍摄方向好看」的诊断与修复（报告 docs/地面材质/多视角一致性.md）。

近 / 中 / 细层反照率都是 Navcam 从桅杆头一个点拍的照片投到地上，原拍摄方向看不出毛病，换个方向（尤其从远处回望车）
就露出摄影测量的破绽。这个脚本在停车点周围布一圈新机位出图，再把每个像素追到地面（ENU），对上数据空间里的各类破绽图。

子命令（.venv/bin/python scripts/Godot/79_多视角.py <子命令> [选项]）：
  机位    写 产出/多视角/机位.json（实景.gd --视频 格式）和 机位表.json（每帧的半径、高度、方位、类别）。
          环：半径 3/6/10/20/40 m × 离地 0.5/1.5/3/10 m × 12 个方位，都看车（回望车和桅杆）；
          掠射：离地 0.3 m、半径 3/6/10/20 m，沿圆周切向看、下俯 10°；
          桅杆：桅杆头往外看（Navcam 自己的方向，对照组），地面距离 3/6/10 m。
          每个时刻一个镜头（环_1307、环_1600 …），按 --时刻。
  渲染    --标签 <名> [--时刻 13:07,16:00] [--只 环,掠射,桅杆] [其余参数原样给 实景.gd]：分批调 godot/渲染.sh --视频，
          输出 产出/多视角/<标签>/<镜头>/%05d.png。每批不超过 渲染.sh 的 10 分钟看门狗。
  追踪    （未实现）每台相机每个像素（降到 480×270）沿视线打到 CDLOD 地面（heights.bin，同着色器取层），存 ENU 和距离：
          产出/多视角/追踪.npz。
  数据    数据空间的破绽图和指标（层边界、源边界、拉伸、补洞、烘焙明暗、石块）：产出/多视角/数据/。
  视图    （未实现）把破绽图投到每台相机，逐类统计屏幕占比；按类拼示例图：产出/多视角/<标签>/图/。
数据：NASA/JPL-Caltech（PDS Imaging Node）、University of Arizona（HiRISE）。
"""
import importlib.util, json, math, os, subprocess, sys, time, pathlib
import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
MAP = HERE.parent.parent
GD = MAP/"godot"/"数据"/"sol0530"
OUT = MAP/"产出"/"多视角"
SITE = MAP/"DEM"/"Blender缓存"/"_素材"/"PDS"/"站26_1222"
REB = SITE/"重建"
MAST_ENU = np.array([-0.875698, -0.255576, 2.03704])                      # 57 MAST（LOCAL_LEVEL）→ ENU
W, H = 960, 540                                                          # 出图尺寸（渲染再 2× 超采样）
WT, HT = 480, 270                                                        # 追踪分辨率
HFOV = 60.0
RADII = (3, 6, 10, 20, 40)
HEIGHTS = (0.5, 1.5, 3, 10)
NAZ = 12
_t0 = time.time()


def log(*a):
    print(f"[79 {time.time() - _t0:6.1f}s]", *a, flush=True)


def load_mod(name, fn, d=HERE):
    spec = importlib.util.spec_from_file_location(name, d/fn)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m


_M72 = None


def m72():
    global _M72
    if _M72 is None: _M72 = load_mod("m72", "72_近景细化.py")
    return _M72


def heights():
    M = m72(); return M.BaseHeights(M.read_heights())


def ground_z(B, E, N):
    E = np.atleast_1d(np.asarray(E, float)); N = np.atleast_1d(np.asarray(N, float))
    return B.height(E, -N, B.level(E, -N))


def g3(v):
    v = np.asarray(v, float); return np.array([v[0], v[2], -v[1]])


def frame(pos_enu, fwd_enu, t):
    f = np.asarray(fwd_enu, float); f /= np.linalg.norm(f)
    r = np.cross(f, [0, 0, 1.0]); r /= np.linalg.norm(r); up = np.cross(r, f)
    p, f_, u = g3(pos_enu), g3(f), g3(up)
    return dict(pos=[round(float(v), 4) for v in p], fwd=[round(float(v), 6) for v in f_], up=[round(float(v), 6) for v in u], hfov=HFOV, t=t)


# ── 机位 ─────────────────────────────────────────────────────────────────────────────────
def cameras(B):
    """返回 [(类别, 参数 dict, 位置 ENU, 前 ENU)]。方位 az：相机在车的哪一侧（0 = 北，顺时针）。"""
    cams = []
    for r in RADII:
        for h in HEIGHTS:
            for i in range(NAZ):
                az = math.radians(i*360/NAZ)
                E, N = r*math.sin(az), r*math.cos(az)
                C = np.array([E, N, float(ground_z(B, E, N)[0]) + h])
                T = np.array([0.0, 0.0, float(ground_z(B, 0.0, 0.0)[0]) + 0.3])
                cams.append(("环", dict(r=r, h=h, az=i*360/NAZ), C, T - C))
    for r in RADII[:4]:
        for i in range(NAZ):
            az = math.radians(i*360/NAZ)
            E, N = r*math.sin(az), r*math.cos(az)
            C = np.array([E, N, float(ground_z(B, E, N)[0]) + 0.3])
            tang = np.array([math.cos(az), -math.sin(az), 0.0])           # 顺时针切向
            pt = math.radians(-10.0)
            cams.append(("掠射", dict(r=r, h=0.3, az=i*360/NAZ), C, np.array([tang[0]*math.cos(pt), tang[1]*math.cos(pt), math.sin(pt)])))
    for dg in (3, 6, 10):
        for i in range(NAZ):
            az = math.radians(i*360/NAZ)
            C = MAST_ENU.copy()
            E, N = C[0] + dg*math.sin(az), C[1] + dg*math.cos(az)
            T = np.array([E, N, float(ground_z(B, E, N)[0])])
            cams.append(("桅杆", dict(r=dg, h=round(float(C[2] - ground_z(B, *C[:2])[0]), 2), az=i*360/NAZ), C, T - C))
    return cams


def cmd_cams(a):
    times = a.get("时刻", "13:07,16:00,09:00").split(",")
    B = heights(); cams = cameras(B)
    shots = []
    kinds = sorted({k for k, *_ in cams}, key=["环", "掠射", "桅杆"].index)
    for t in times:
        for kd in kinds:
            fr = [frame(C, F, t) for k, _, C, F in cams if k == kd]
            shots.append(dict(name=f"{kd}_{t.replace(':', '')}", frames=fr))
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT/"机位.json").write_text(json.dumps(dict(fps=1, W=W, H=H, shots=shots), ensure_ascii=False))
    tab = {kd: [dict(p, pos=[round(float(v), 4) for v in C], fwd=[round(float(v), 6) for v in F/np.linalg.norm(F)])
                for k, p, C, F in cams if k == kd] for kd in kinds}
    (OUT/"机位表.json").write_text(json.dumps(dict(W=W, H=H, hfov=HFOV, mast=MAST_ENU.tolist(), 机位=tab), ensure_ascii=False, indent=0))
    log(f"机位 {len(cams)} 台 × {len(times)} 个时刻 → {OUT/'机位.json'}")


# ── 渲染 ─────────────────────────────────────────────────────────────────────────────────
def cmd_render(a, extra):
    tag = a["标签"]; J = json.loads((OUT/"机位.json").read_text())
    times = a.get("时刻", "13:07").split(","); kinds = a.get("只", "环,掠射,桅杆").split(",")
    godot = os.environ.get("GODOT", "/home/user/引擎/godot/bin/godot.linuxbsd.editor.x86_64.mars")
    for t in times:
        for kd in kinds:
            name = f"{kd}_{t.replace(':', '')}"
            sh = next((s for s in J["shots"] if s["name"] == name), None)
            if sh is None: log(f"没有镜头 {name}，先跑 机位 --时刻 …"); continue
            od = OUT/tag; od.mkdir(parents=True, exist_ok=True)
            n = len(sh["frames"]); step = 150                              # 每批 ≤ 150 帧（约 3 分钟，渲染.sh 看门狗 10 分钟）
            for b0 in range(0, n, step):
                part = dict(J, shots=[dict(name=name, frames=sh["frames"][b0:b0 + step])])
                pf = od/f"_路径_{name}_{b0}.json"; pf.write_text(json.dumps(part, ensure_ascii=False))
                tmp = od/f"_批_{name}_{b0}"
                cmd = [str(MAP/"godot"/"渲染.sh"), str(tmp), t, "2", f"--视频={pf}", f"--出={tmp}", "--每帧=3", *extra]
                t1 = time.time()
                r = subprocess.run(cmd, env=dict(os.environ, GODOT=godot), capture_output=True, text=True)
                dst = od/name; dst.mkdir(exist_ok=True)
                got = sorted((tmp/name).glob("*.png")) if (tmp/name).exists() else []
                for i, p in enumerate(got): p.rename(dst/f"{b0 + i:05d}.png")
                log(f"渲染 {tag}/{name} 帧 {b0}–{b0 + len(got) - 1}（{len(got)} 张，{time.time() - t1:.0f} s）" + ("" if len(got) else f"\n{r.stdout[-800:]}\n{r.stderr[-800:]}"))



# ── 数据空间：各层、各源、补洞、拉伸、烘焙明暗、石块 ─────────────────────────────────────────────
_M57 = None


def m57():
    global _M57
    if _M57 is None: _M57 = load_mod("m57", "57_实景重建.py", HERE.parent/"Blender")
    return _M57


def region(e, h, fe):
    return np.clip((h*0.97 - e)/(h*fe), 0, 1)


def tex(name):
    """游戏贴图（godot/数据/sol0530，scene.json tex / near_fine）→ 线性 RGB、alpha（第 0 行在北）、half。"""
    S = json.loads((GD/"scene.json").read_text())
    if name == "fine": f, half = S["near_fine"]["albedo"]["file"], S["near_fine"]["albedo"]["half"]
    else: f, half = S["tex"][name]["file"], S["tex"][name]["half"]
    rgb, a = m72().read_rgba_lin(GD/f)
    return rgb, a, half


def grid(cs, half):
    c = -half + (np.arange(int(round(2*half/cs))) + 0.5)*cs
    return np.meshgrid(c, c)                                             # 第 0 行在南（同 57）


def nlp(x, m, s):
    """归一化高斯低通（只用 m 内的格），s 以格计。"""
    from scipy.ndimage import gaussian_filter
    mf = m.astype(np.float32); w = gaussian_filter(mf, s)
    return gaussian_filter(np.where(m, x, 0).astype(np.float32), s)/np.maximum(w, 1e-6), w


def lum(rgb): return rgb @ np.array([0.2126, 0.7152, 0.0722], np.float32)


def composite(cs, half):
    """按 地形.gdshader 第 1、1b 步把 HiRISE → mid → near → fine（→ 贴片）混成屏幕上的宏观反照率，同时给出各层最终权重。
    返回 dict：A（线性 RGB，第 0 行在南）、w_hi / w_mid / w_near / w_fine、各层自己的颜色（同格取样）。"""
    M = m72(); X, Y = grid(cs, half); e = np.maximum(np.abs(X), np.abs(Y))
    out = {}
    hi, _, hh = tex("albedo_hirise"); Ahi = M.sample_tex(hi, hh, X, Y); del hi
    mid, am, hm = tex("albedo_mid"); Am = M.sample_tex(mid, hm, X, Y); am_ = M.sample_tex(am, hm, X, Y); del mid, am
    near, an, hn = tex("albedo_near"); An = M.sample_tex(near, hn, X, Y); an_ = M.sample_tex(an, hn, X, Y); del near, an
    fine, af, hf = tex("fine"); Af = M.sample_tex(fine, hf, X, Y); af_ = M.sample_tex(af, hf, X, Y)*(e < hf); del fine, af
    wm = region(e, hm, 0.08)*am_; wn = region(e, hn, 0.08)*an_; wf = af_
    A = Ahi.copy()
    A = A*(1 - wm[..., None]) + Am*wm[..., None]
    A = A*(1 - wn[..., None]) + An*wn[..., None]
    A = A*(1 - wf[..., None]) + Af*wf[..., None]
    out.update(A=A, Ahi=Ahi, Am=Am, An=An, Af=Af, w_fine=wf, w_near=wn*(1 - wf), w_mid=wm*(1 - wn)*(1 - wf),
               w_hi=(1 - wm)*(1 - wn)*(1 - wf), X=X, Y=Y, cs=cs, half=half)
    return out


def ok57(lv):
    """57 导出时反照率「有数据」的格（同 export()：Mastcam + Navcam、去掉虚构区、零星孤点），和 Mastcam 覆盖。第 0 行在南。"""
    from scipy.ndimage import uniform_filter
    M = m57(); A, has_, cs, n = M.best_albedo(lv)
    c = M.grid_xy(cs, n); X, Y = np.meshgrid(c, c)
    has_ &= (A.max(-1) > 1e-4) & ~M.fabricate_zone(X, Y)
    dens = uniform_filter(has_.astype(np.float32), max(3, int(0.07/cs)) | 1)
    has_ &= dens >= 0.6
    zp = M.OUT/f"反照率Z_{lv}.npz"
    hz = (np.load(zp)["cov"] > 0) if zp.exists() else np.zeros_like(has_)
    return has_, hz, cs, n, M.fabricate_zone(X, Y)


def ok72():
    """72 细层：实测（cover > 0.05）、补缝 / 合成（alpha > 0 但没实测）。第 0 行在南，4 mm。"""
    Z = np.load(MAP/"资料"/"地面材质"/"近景细化"/"融合"/"融合.npz")
    return Z["cover"] > 0.05, Z


def resample(a, cs_a, half_a, X, Y, order=0):
    """第 0 行在南的格网 a 在 (X, Y) 处取样（最近 / 双线性）。"""
    from scipy.ndimage import map_coordinates
    n = a.shape[0]
    r = (Y + half_a)/cs_a - 0.5; c = (X + half_a)/cs_a - 0.5
    return map_coordinates(a.astype(np.float32), [r, c], order=order, mode="nearest")


def struct_ratio(L, ok, cs, s1, s2, bins):
    """径向 / 切向梯度能量比（以桅杆为中心）：数据从桅杆一个点拍，像素足迹沿径向拉长 → 径向被抹平，比值 < 1。
    L：对数亮度；带通 σ s1–s2（米）；只统计 ok 格。返回每个距离段 (比值, 格数)。"""
    from scipy.ndimage import gaussian_filter
    n = L.shape[0]; half = n*cs/2; X, Y = grid(cs, half)
    Lf = np.where(ok, L, nlp(L, ok, s2/cs)[0])
    b = gaussian_filter(Lf, s1/cs) - gaussian_filter(Lf, s2/cs)
    gy, gx = np.gradient(b, cs)
    dx, dy = X - MAST_ENU[0], Y - MAST_ENU[1]; d = np.hypot(dx, dy); ux, uy = dx/np.maximum(d, 1e-6), dy/np.maximum(d, 1e-6)
    gr = gx*ux + gy*uy; gt = -gx*uy + gy*ux
    from scipy.ndimage import binary_erosion
    okk = binary_erosion(ok, iterations=max(1, int(2*s2/cs)))
    res = []
    for a, b_ in zip(bins[:-1], bins[1:]):
        m = okk & (d >= a) & (d < b_)
        res.append((float((gr[m]**2).sum()/max((gt[m]**2).sum(), 1e-12)) if m.sum() > 500 else float("nan"), int(m.sum())))
    return res


def shading_corr(L, ok, Hgt, cs, sun_az, sun_el, bands):
    """烘焙明暗：对数亮度带通 和 μ0 = n·s 带通 的相关（照片的太阳 / 转 90° / 转 180° 三个太阳，后两个是对照）。"""
    from scipy.ndimage import gaussian_filter, binary_erosion
    M = m57(); res = {}
    for s1, s2 in bands:
        Hs = gaussian_filter(Hgt, s1/cs); gy, gx = np.gradient(Hs, cs)
        nrm = np.stack([-gx, -gy, np.ones_like(gx)], -1); nrm /= np.linalg.norm(nrm, axis=-1, keepdims=True)
        Lf = np.where(ok, L, nlp(L, ok, s2/cs)[0])
        y = gaussian_filter(Lf, s1/cs) - gaussian_filter(Lf, s2/cs)
        okk = binary_erosion(ok, iterations=max(1, int(2*s2/cs)))
        row = {}
        for tag, da in (("照片太阳", 0), ("转90°", 90), ("转180°", 180)):
            s = M.sun_enu(sun_az + da, sun_el); mu = np.clip(nrm @ s, 0, None)
            x = mu - gaussian_filter(mu, s2/cs)
            xv, yv = x[okk], y[okk]
            r = float(np.corrcoef(xv, yv)[0, 1]) if okk.sum() > 1000 else float("nan")
            k = float((xv*yv).sum()/max((xv*xv).sum(), 1e-12))
            row[tag] = dict(r=round(r, 3), 斜率=round(k, 3))
        res[f"{s1*100:.0f}–{s2*100:.0f} cm"] = row
    return res


def edge_jump(La, Lb, wa, cs, s, lo=0.2, hi=0.8):
    """两层在过渡带（a 的权重 lo–hi）上的低频差 |LP_s(a) − LP_s(b)|（对数，×100 ≈ %）。"""
    from scipy.ndimage import gaussian_filter
    band = (wa > lo) & (wa < hi)
    if band.sum() < 50: return dict(格数=int(band.sum()))
    d = gaussian_filter(La, s/cs) - gaussian_filter(Lb, s/cs)
    v = np.abs(d[band])
    return dict(格数=int(band.sum()), 中位=round(float(np.median(v))*100, 1), p90=round(float(np.percentile(v, 90))*100, 1))


def cmd_data(a):
    from scipy.ndimage import gaussian_filter, label, distance_transform_edt
    from PIL import Image
    od = OUT/a.get("标签", "数据"); od.mkdir(parents=True, exist_ok=True)
    M = m72(); B = heights(); rep = {}
    # ── 合成：±10 m 2 cm、±50 m 4 cm
    for nm, cs, half in (("近", 0.02, 10.0), ("中", 0.04, 50.0)):
        C = composite(cs, half); X, Y = C["X"], C["Y"]
        Hgt = ground_z(B, X.ravel(), Y.ravel()).reshape(X.shape).astype(np.float32)
        C["H"] = Hgt
        np.savez_compressed(od/f"合成_{nm}.npz", **{k: (v.astype(np.float16) if isinstance(v, np.ndarray) and v.dtype == np.float32 and k not in ("X", "Y", "H") else v) for k, v in C.items() if k not in ("X", "Y")})
        rep[f"层权重_{nm}"] = {k: round(float(C[k].mean()), 3) for k in ("w_fine", "w_near", "w_mid", "w_hi")}
        log(f"合成 {nm}：{rep[f'层权重_{nm}']}")
    # ── (c) 补洞：各层自己的「没实测」格，按最终权重算屏幕上（俯视）的合成面积
    hasN, hzN, csN, nN, fabN = ok57("近"); hasM, hzM, csM, nM, fabM = ok57("中")
    has72, Z72 = ok72(); cs72 = 2*8.192/has72.shape[0]
    syn = {}
    for nm, cs, half in (("近", 0.02, 10.0), ("中", 0.04, 50.0)):
        z = np.load(od/f"合成_{nm}.npz"); X, Y = grid(cs, half)
        sN = 1 - resample(hasN, csN, csN*nN/2, X, Y, 1); sM = 1 - resample(hasM, csM, csM*nM/2, X, Y, 1)
        s72 = 1 - resample(has72, cs72, 8.192, X, Y, 1)
        S = z["w_fine"]*s72 + z["w_near"]*sN + z["w_mid"]*sM
        fab = resample(fabN, csN, csN*nN/2, X, Y, 0) > 0.5
        syn[nm] = S.astype(np.float32)
        d = np.hypot(X - MAST_ENU[0], Y - MAST_ENU[1])
        rows = {}
        for r0, r1 in ((0, 3), (3, 6), (6, 10), (10, 20), (20, 50)):
            m = (d >= r0) & (d < r1) & (np.maximum(np.abs(X), np.abs(Y)) < half)
            if m.sum(): rows[f"{r0}–{r1} m"] = dict(合成占比=round(float(S[m].mean()), 3), 其中车底虚构=round(float((S*fab)[m].mean()), 3),
                                                   HiRISE占比=round(float(z["w_hi"][m].mean()), 3))
        lab, nl = label(S > 0.5); sz = np.bincount(lab.ravel())[1:]*cs*cs
        rep[f"补洞_{nm}"] = dict(按距离=rows, 连通块数_大于0_01m2=int((sz > 0.01).sum()), 连通块数_大于1m2=int((sz > 1).sum()),
                                最大块_m2=round(float(sz.max()), 2) if len(sz) else 0, 合成总面积_m2=round(float(S.sum()*cs*cs), 1))
        np.save(od/f"合成掩膜_{nm}.npy", S.astype(np.float16))
        log(f"补洞 {nm}：{rep[f'补洞_{nm}']}")
    # ── (a) 层边界、源边界：过渡带两侧低频差
    z = np.load(od/"合成_近.npz"); L = {k: np.log(np.maximum(lum(z[k].astype(np.float32)), 1e-4)) for k in ("Ahi", "Am", "An", "Af")}
    X, Y = grid(0.02, 10.0); e = np.maximum(np.abs(X), np.abs(Y)); _, an, hn = tex("albedo_near"); an_ = M.sample_tex(an, hn, X, Y)
    _, af, hf = tex("fine"); af_ = M.sample_tex(af, hf, X, Y)*(e < hf)
    _, am, hm = tex("albedo_mid"); am_ = M.sample_tex(am, hm, X, Y)
    jumps = {}
    for s in (0.05, 0.2):
        jumps[f"细↔近 σ{s*100:.0f}cm"] = edge_jump(L["Af"], L["An"], af_, 0.02, s)
        jumps[f"近↔中 σ{s*100:.0f}cm（近层洞边）"] = edge_jump(L["An"], L["Am"], an_*region(e, hn, 0.08), 0.02, s)
    z2 = np.load(od/"合成_中.npz"); X2, Y2 = grid(0.04, 50.0); e2 = np.maximum(np.abs(X2), np.abs(Y2))
    L2 = {k: np.log(np.maximum(lum(z2[k].astype(np.float32)), 1e-4)) for k in ("Ahi", "Am", "An")}
    am2 = M.sample_tex(am, hm, X2, Y2)
    for s in (0.2, 1.0):
        jumps[f"中↔HiRISE σ{s*100:.0f}cm（中层洞边）"] = edge_jump(L2["Am"], L2["Ahi"], am2*region(e2, hm, 0.08), 0.04, s)
        jumps[f"近↔中 σ{s*100:.0f}cm（±10 m 方框边）"] = edge_jump(L2["An"], L2["Am"], region(e2, hn, 0.08)*(am2 > 0.9), 0.04, s, 0.05, 0.95)
    # Mastcam ↔ Navcam（57 近、中层内部）
    for lv, (has_, hz, cs_, n_) in (("近", (hasN, hzN, csN, nN)), ("中", (hasM, hzM, csM, nM))):
        Mm = m57(); nv = np.load(Mm.OUT/f"反照率_{lv}.npz"); zz = np.load(Mm.OUT/f"反照率Z_{lv}.npz")
        Az = zz["A"].astype(np.float32); csz, nz = float(zz["cs"]), int(zz["n"])
        Xz, Yz = grid(csz, csz*nz/2)
        An_ = np.stack([resample(nv["A"][..., ch], float(nv["cs"]), float(nv["cs"])*int(nv["n"])/2, Xz, Yz, 1) for ch in range(3)], -1)
        okn = resample(nv["cov"] > 0, float(nv["cs"]), float(nv["cs"])*int(nv["n"])/2, Xz, Yz, 0) > 0.5
        hzz = zz["cov"] > 0; both = hzz & okn
        if both.sum() > 1000:
            dl = np.log(np.maximum(lum(Az), 1e-4)) - np.log(np.maximum(lum(An_), 1e-4))
            dc = np.log(np.maximum(Az[..., 0]/np.maximum(Az[..., 2], 1e-4), 1e-3)) - np.log(np.maximum(An_[..., 0]/np.maximum(An_[..., 2], 1e-4), 1e-3))
            lp = nlp(dl, both, 0.2/csz)[0]; lc = nlp(dc, both, 0.2/csz)[0]
            jumps[f"Mastcam↔Navcam {lv}层（重叠区）"] = dict(面积_m2=round(float(both.sum()*csz*csz), 1), 亮度差_中位=round(float(np.median(dl[both]))*100, 1),
                                                    亮度差_20cm_p10_p90=[round(float(v)*100, 1) for v in np.percentile(lp[both], [10, 90])],
                                                    红蓝比差_中位=round(float(np.median(dc[both]))*100, 1),
                                                    红蓝比差_20cm_p10_p90=[round(float(v)*100, 1) for v in np.percentile(lc[both], [10, 90])])
    rep["边界跳变_对数x100"] = jumps
    log(f"边界跳变 {jumps}")
    # ── (b) 拉伸：俯视 UV 在陡面上的拉伸 1/n_z；照片足迹的各向异性（径向 / 切向梯度能量比）
    st = {}
    for nm, cs, half in (("近", 0.02, 10.0), ("中", 0.04, 50.0)):
        X, Y = grid(cs, half); Hh = ground_z(B, X.ravel(), Y.ravel()).reshape(X.shape)
        gy, gx = np.gradient(gaussian_filter(Hh, 1.0), cs); s_ = np.sqrt(1 + gx*gx + gy*gy)
        st[f"俯视UV拉伸_{nm}"] = {f">{t}": round(float((s_ > t).mean())*100, 2) for t in (1.15, 1.3, 1.5, 2.0)}
        d = np.hypot(X - MAST_ENU[0], Y - MAST_ENU[1]); h_ = MAST_ENU[2] - Hh
        nrm = np.stack([-gx, -gy, np.ones_like(gx)], -1)/s_[..., None]
        v = np.stack([MAST_ENU[0] - X, MAST_ENU[1] - Y, MAST_ENU[2] - Hh], -1); v /= np.linalg.norm(v, axis=-1, keepdims=True)
        cosv = (nrm*v).sum(-1)
        rows = {}
        for r0, r1 in ((1, 3), (3, 6), (6, 10), (10, 20), (20, 50)):
            m = (d >= r0) & (d < r1)
            if m.sum(): rows[f"{r0}–{r1} m"] = dict(足迹长宽比_中位=round(float(np.median(1/np.maximum(cosv[m], 0.01))), 1),
                                                   掠射_cos小于0_1=round(float((cosv[m] < 0.1).mean())*100, 1), 背向桅杆=round(float((cosv[m] < 0).mean())*100, 1))
        st[f"照片足迹_{nm}"] = rows
        np.save(od/f"足迹cos_{nm}.npy", cosv.astype(np.float16))
    bins = [1, 2, 3, 4, 6, 8, 10, 14, 20, 30, 50]
    nv = np.load(m57().OUT/"反照率_近.npz"); An57 = nv["A"].astype(np.float32); csn = float(nv["cs"])
    st["径向切向能量比_近层57_带1–4cm"] = struct_ratio(np.log(np.maximum(lum(An57), 1e-4)), hasN if hasN.shape == An57.shape[:2] else nv["cov"] > 0, csn, 0.01, 0.04, bins[:7])
    nv = np.load(m57().OUT/"反照率_中.npz"); Am57 = nv["A"].astype(np.float32); csm = float(nv["cs"])
    okm = resample(hasM, csM, csM*nM/2, *grid(csm, csm*Am57.shape[0]/2), 0) > 0.5
    st["径向切向能量比_中层57_带4–16cm"] = struct_ratio(np.log(np.maximum(lum(Am57), 1e-4)), okm, csm, 0.04, 0.16, bins)
    LA = Z72["LA"]; L72 = (0.2126*LA[0] + 0.7152*LA[1] + 0.0722*LA[2]).astype(np.float32)
    k2 = 2; L72c = L72[:L72.shape[0]//k2*k2, :L72.shape[1]//k2*k2].reshape(L72.shape[0]//k2, k2, -1, k2).mean((1, 3))
    ok72c = has72[::k2, ::k2][:L72c.shape[0], :L72c.shape[1]]
    st["径向切向能量比_细层72_带1–4cm"] = struct_ratio(L72c, ok72c, cs72*k2, 0.01, 0.04, bins[:7])
    rep["拉伸"] = st
    log(f"拉伸 {st}")
    # ── (d) 烘焙明暗：对数亮度 vs μ0（照片太阳 方位 201.5°、高 43.5°：sol 502–532 Navcam 中位）
    sh = {}
    zN = np.load(od/"合成_近.npz"); okc = (zN["w_fine"] + zN["w_near"]) > 0.9
    X, Y = grid(0.02, 10.0)
    syn_ = syn["近"] < 0.1
    sh["近处显示（2 cm 格，细+近）"] = shading_corr(np.log(np.maximum(lum(zN["A"].astype(np.float32)), 1e-4)), okc & syn_, zN["H"], 0.02, 201.5, 43.5, ((0.04, 0.16), (0.16, 0.64)))
    Hf = Z72["Hf"].astype(np.float32); okH = np.isfinite(Hf) & has72
    Hff = np.where(okH, Hf, nlp(np.nan_to_num(Hf), okH, 5)[0])
    sub = slice(None, None, 2)
    sh["细层72（8 mm 格）"] = shading_corr(L72[sub, sub], okH[sub, sub], Hff[sub, sub], cs72*2, 201.5, 43.5, ((0.016, 0.064), (0.064, 0.256)))
    zM = np.load(od/"合成_中.npz"); X2, Y2 = grid(0.04, 50.0); d2 = np.hypot(X2 - MAST_ENU[0], Y2 - MAST_ENU[1])
    okm2 = (zM["w_mid"] > 0.9) & (syn["中"] < 0.1) & (d2 > 10)
    sh["中层显示（4 cm 格，10–50 m）"] = shading_corr(np.log(np.maximum(lum(zM["A"].astype(np.float32)), 1e-4)), okm2, zM["H"], 0.04, 201.5, 43.5, ((0.16, 0.64), (0.64, 2.56)))
    rep["烘焙明暗_相关"] = sh
    log(f"烘焙明暗 {sh}")
    # ── (e) 石块
    rep["石块"] = rocks_check(od)
    (od/"指标.json").write_text(json.dumps(rep, ensure_ascii=False, indent=1))
    log(f"→ {od/'指标.json'}")


def poly_tris(P):
    """57 石块的面表 [n, i0, …, i(n−1), n, …] → 三角形（扇形剖分）。"""
    out, i = [], 0
    while i < len(P):
        n = int(P[i]); f = P[i + 1:i + 1 + n]; i += 1 + n
        for j in range(1, n - 1): out.append((f[0], f[j], f[j + 1]))
    return np.array(out, np.int64)


def rocks_check(od):
    """实测石块网格：封闭性、背面（背向桅杆、超椭球补的）面积占比、单色 vs 周围地面、石块照片溢到地上的光晕。"""
    S = json.loads((GD/"scene.json").read_text()); R = np.load(MAP/S["source"]/"石块.npz"); inst = json.loads(str(R["inst"]))
    z = np.load(od/"合成_近.npz"); A = z["A"].astype(np.float32); X, Y = grid(0.02, 10.0)
    rows = []; base = np.array(S["rocks"]["base"])
    for k, r in enumerate(inst):
        V = R[f"V{k}"].astype(np.float64)
        if f"F{k}" not in R: continue
        F = poly_tris(R[f"F{k}"])
        e = np.sort(np.concatenate([F[:, [0, 1]], F[:, [1, 2]], F[:, [2, 0]]]), 1)
        _, cnt = np.unique(e, axis=0, return_counts=True)
        tri = V[F]; nrm = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0]); ar = np.linalg.norm(nrm, axis=1)/2
        nn = nrm/np.maximum(2*ar[:, None], 1e-12); ctr = tri.mean(1)
        v = MAST_ENU - ctr; v /= np.linalg.norm(v, axis=1, keepdims=True)
        up = nn[:, 2] > -0.2
        back = float(ar[up & ((nn*v).sum(1) < 0.05)].sum()/max(ar[up].sum(), 1e-9))
        x, y = r["pos"][0], r["pos"][1]; D = r["D"]; dd = np.hypot(X - x, Y - y)
        ring_in = (dd > D/2) & (dd < D/2 + 0.06); ring_out = (dd > D/2 + 0.12) & (dd < D/2 + 0.35)
        col = np.array(S["rocks"]["meshes"][k]["color"]) if k < len(S["rocks"]["meshes"]) else base
        if col.max() <= 0: col = base
        gi = A[ring_in].mean(0) if ring_in.any() else np.full(3, np.nan); go = A[ring_out].mean(0) if ring_out.any() else np.full(3, np.nan)
        rows.append(dict(i=k, D=round(D, 3), 距桅杆=round(float(math.hypot(x - MAST_ENU[0], y - MAST_ENU[1])), 1), 开边=int((cnt == 1).sum()),
                         背面占比=round(back, 2), 石色对地=round(float(lum(col[None])[0]/max(lum(go[None])[0], 1e-4)), 2),
                         光晕=round(float(lum(gi[None])[0]/max(lum(go[None])[0], 1e-4)), 2), 色为零=bool(max(S["rocks"]["meshes"][k]["color"]) <= 0)))
    import statistics as stt
    summ = dict(块数=len(rows), 有开边=sum(r_["开边"] > 0 for r_ in rows), 背面占比_中位=stt.median(r_["背面占比"] for r_ in rows),
                石色对地_p10_p50_p90=np.percentile([r_["石色对地"] for r_ in rows], [10, 50, 90]).round(2).tolist(),
                光晕_p10_p50_p90=np.nanpercentile([r_["光晕"] for r_ in rows], [10, 50, 90]).round(2).tolist(), 色为零=sum(r_["色为零"] for r_ in rows))
    (od/"石块.json").write_text(json.dumps(rows, ensure_ascii=False, indent=0))
    log(f"石块 {summ}")
    return summ


def parse(argv):
    a, extra = {}, []
    for s in argv:
        if s.startswith("--"):
            k, _, v = s[2:].partition("=")
            if k in ("时刻", "只", "标签", "前", "后", "变体"): a[k] = v
            else: extra.append(s)
    return a, extra


if __name__ == "__main__":
    sub = sys.argv[1] if len(sys.argv) > 1 else "机位"
    a, extra = parse(sys.argv[2:])
    {"机位": lambda: cmd_cams(a), "渲染": lambda: cmd_render(a, extra), "数据": lambda: cmd_data(a)}[sub]()
