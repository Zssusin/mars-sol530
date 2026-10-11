#!/usr/bin/env python3
"""
74 多站样块：把 71 的地面样块管线推广到任意站点（毅力号 Navcam / Mastcam-Z，好奇号 Navcam），由站点配置驱动：
下载 → 正射 + 多帧配准 → 反照率/明暗分离 → 切块 → 导出（按块 gain 的现有图块格式）→ 样块库目录 scripts/Godot/地面样块库.json。
报告：docs/地面材质/样块库.md。只读 PDS、只写 资料/地面材质/样块库/ 和 地面样块库.json，不碰着色器、godot/数据/、61、地面样块表.json。

站点配置：scripts/Godot/样块站点.json（每站一项，键见文件里的 说明）。s0530 = 第一批（71）的同一套设置，用来核对复现。

子命令（.venv/bin/python scripts/Godot/74_多站样块.py <子命令> <站|全部> [选项]）：
  下载   按配置里的产品地址下到 资料/地面材质/PDS/站/<站>/sol####/（断点续传；有 PDS4 xml 的按 md5 校验，没有的按大小）
  正射   每帧 XYZ → 公共水平格（ENU，原点 = 参考帧的车导航点；第 0 行在南）+ 多帧配准（同 71）    [--进程=N]
  分离   反照率/明暗分离（同 71 的基线：Lunar-Lambert 直射 × 投射阴影 + 天光，逐帧增益交替最小二乘，跨帧中值）
  切块   按规则（亮格占比分类 + 滑窗打分）或手选窗口切块，空洞「平滑底 + 平移细节」补，去 0.5 m 低频，Moisan 周期分解；
         Mastcam-Z 块（亚毫米）、贴花；每块导出 godot 格式（PNG 存 A/gain，gain = 全图最大值向上取 0.01；高度 int32 宽高 + float32 米）
  图     本站的正射总览（反照率 + 选块框）
  库     汇总所有站的样块 → scripts/Godot/地面样块库.json，并画每类的对照图 docs/地面材质/图/样块库_<类>.jpg
  核对   s0530 的新输出与 71 第一批输出（资料/地面材质/样块/切块/*.npz）逐块比较
  全部   下载、正射、分离、切块、图

约定同 71：反照率细节均值 1（逐通道）；高度米、零均值；ENU 第 0 行在南。
数据：NASA/JPL-Caltech/ASU/MSSS（PDS Imaging Node）。
"""
import json, math, os, re, sys, time, pathlib, subprocess, hashlib, importlib.util
import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("m71", HERE/"71_地面样块.py")
L = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(L)      # 71 当库用：纯数值函数原样复用（第一批可复现）
from 读PDS影像 import read_img, group, rover_pose_in_site                    # noqa: E402（71 已把 docs/地面材质 放进 sys.path）

MAP = L.MAP
PDS = MAP/"资料"/"地面材质"/"PDS"
LIB = MAP/"资料"/"地面材质"/"样块库"
CFG = HERE/"样块站点.json"
CATALOG = HERE/"地面样块库.json"
DOCFIG = MAP/"docs"/"地面材质"/"图"
B1 = MAP/"资料"/"地面材质"/"样块"                                          # 71 第一批输出（核对用）
M_SE = L.M_SE
_t0 = time.time()
ST = None                                                                   # 当前站的配置（dict）


def out_dir():
    return LIB/ST["id"]


def log(*a):
    s = f"[{time.time() - _t0:7.1f} s] " + " ".join(str(x) for x in a)
    print(s, flush=True)
    d = out_dir() if ST else LIB
    d.mkdir(parents=True, exist_ok=True)
    with open(d/"日志.txt", "a", encoding="utf-8") as f:
        f.write(time.strftime("%m-%d %H:%M:%S ") + s + "\n")


def load_cfg():
    return json.loads(CFG.read_text())


def cs_():
    return float(ST.get("cs", 0.002))


def kcs():
    """按 2 mm 格定的 σ（格）换到本站格距的系数；2 mm 时正好 1.0（第一批逐位复现）。"""
    return 0.002/cs_()


# ── 下载 ─────────────────────────────────────────────────────────────────────────────────
def local_path(url, sol):
    return PDS/"站"/ST["id"]/f"sol{sol:04d}"/os.path.basename(url)


def product_urls():
    """配置里所有要下的产品（IMG + 同名标签）。"""
    out = []
    for fr in ST.get("frames", []):
        for k in ("xyz", "ras", "rasR", "uvw"):
            if fr.get(k): out.append((fr["sol"], fr[k]))
    for z in ST.get("mastcam", {}).get("frames", []):
        for k in ("xyz", "iof"):
            if z.get(k): out.append((z["sol"], z[k]))
    lab = []
    for sol, u in out:
        if u.upper().endswith(".IMG"):
            lab.append((sol, u[:-4] + (".xml" if "/m20/" in u or "mars2020" in u else ".LBL")))
    seen, res = set(), []
    for sol, u in lab + out:
        if u not in seen: seen.add(u); res.append((sol, u))
    return res


def _md5(p):
    h = hashlib.md5()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 22), b""): h.update(b)
    return h.hexdigest()


def _remote_size(url):
    r = subprocess.run(["curl", "-sSIL", url], capture_output=True, text=True)
    m = re.findall(r"(?im)^content-length:\s*(\d+)", r.stdout)
    return int(m[-1]) if m else None


def cmd_download(args):
    items = product_urls()
    tot = 0; bad = 0
    for k, (sol, u) in enumerate(items):
        dst = local_path(u, sol); dst.parent.mkdir(parents=True, exist_ok=True)
        if pathlib.Path(str(dst) + ".ok").exists():
            tot += dst.stat().st_size; continue
        ok = False
        for attempt in range(2):
            r = subprocess.run(["curl", "-sS", "-f", "-L", "--retry", "5", "--retry-delay", "10", "-C", "-", "-o", str(dst), u])
            if r.returncode != 0 and not dst.exists():
                if u.endswith((".xml", ".LBL")): ok = True; break            # 标签不一定有（好奇号多为附加标签）
                continue
            if u.upper().endswith(".IMG"):
                xml = dst.with_suffix(".xml")
                want = None
                if xml.exists():
                    t = xml.read_text(errors="replace")
                    m = re.search(r"<file_name>\s*" + re.escape(dst.name) + r"\s*</file_name>.*?<md5_checksum>\s*([0-9a-f]{32})", t, re.S)
                    want = m.group(1) if m else None
                if want and _md5(dst) != want:
                    log(f"md5 不符，重下 {dst.name}"); dst.unlink(); continue
                if not want:
                    rs = _remote_size(u)
                    if rs and rs != dst.stat().st_size:
                        log(f"大小不符 {dst.stat().st_size} ≠ {rs}，重下 {dst.name}"); dst.unlink(); continue
            ok = True; break
        if ok and dst.exists():
            pathlib.Path(str(dst) + ".ok").touch(); tot += dst.stat().st_size
            if u.upper().endswith(".IMG"): log(f"[{k + 1}/{len(items)}] sol {sol} {dst.name}（{dst.stat().st_size/2**20:.0f} MB）")
        elif not ok:
            bad += 1; log(f"失败 {u}")
    log(f"下载：{len(items)} 个文件，本站共 {tot/2**30:.2f} GB，失败 {bad}")


# ── 帧 ──────────────────────────────────────────────────────────────────────────────────
def navcam_frames():
    """本站各帧：左 XYZ、UVW、RAS 左、RAS 右（同名取最新版本）。
    s0530：沿用 71 的 glob（批1 全部）；其他站：配置里的 frames（已下载到 PDS/站/<站>/）。"""
    out = []
    if ST.get("local_glob"):
        xyzs = sorted(MAP.glob(ST["local_glob"]))
    else:
        xyzs = sorted({local_path(f["xyz"], f["sol"]) for f in ST.get("frames", []) if f.get("xyz")})
    if ST.get("dedupe", True):                                              # 同一帧多个产品版本（如 NCAM02539 / NCAM03539）：只留文件名排最后的
        last = {}
        for x in xyzs: last[x.name[:23]] = x
        xyzs = [x for x in xyzs if last[x.name[:23]] == x]
    for xyz in xyzs:
        if not xyz.exists(): continue
        key = xyz.name[:23]; d = xyz.parent
        pick = lambda pat: (sorted(d.glob(pat)) or [None])[-1]
        if ST.get("rover", "M2020") == "MSL":
            fr = msl_frame_files(xyz)
        else:
            fr = dict(xyz=xyz, uvw=pick(f"{key}UVW_*.IMG"), rasL=pick(f"{key}RAS_*.IMG"), rasR=pick(f"NRF{key[3:]}RAS_*.IMG"),
                      seq=re.search(r"NCAM\d{5}", xyz.name).group(), sol=int(key[4:8]))
        if fr is not None: out.append(fr)
    return out


def msl_frame_files(xyz):
    """好奇号 Navcam：XYZ 与配套的辐射产品（配置 frames 里给的 ras），单色。"""
    for f in ST["frames"]:
        if f.get("xyz") and local_path(f["xyz"], f["sol"]) == xyz:
            ras = local_path(f["ras"], f["sol"]) if f.get("ras") else None
            return dict(xyz=xyz, uvw=None, rasL=ras, rasR=None, seq=f.get("seq", ""), sol=f["sol"])
    return None


def frames_index():
    p = out_dir()/"正射"/"帧.json"
    return json.loads(p.read_text()) if p.exists() else {}


def tag_for(fr, meta, used):
    t = L.frame_tag(meta["sol"], meta["ltst"] or "0000")
    if t in used and used[t] != fr["xyz"].name:
        k = 1
        while f"{t}_{k}" in used and used[f"{t}_{k}"] != fr["xyz"].name: k += 1
        t = f"{t}_{k}"
    return t


# ── 几何（好奇号标签的差异在这里收口）────────────────────────────────────────────────────
def to_enu(P, lab, origin):
    """XYZ 产品 → ENU（米，原点 = 本站原点 = 参考帧车导航点在站点系的位置）。
    毅力号 Navcam / Mastcam-Z：XYZ 在 SITE_FRAME（x 北 y 东 z 下）。好奇号：按标签的参考系，ROVER 系先用车姿转到站点系。"""
    di = group(lab, "DERIVED_IMAGE_PARMS")
    ref = (di.get("REFERENCE_COORD_SYSTEM_NAME") or "").upper()
    if "ROVER" in ref:
        off, q = rover_pose_in_site(lab)
        X = (L.qrot(q) @ P.reshape(3, -1).astype(np.float64) + off[:, None]).reshape(P.shape)
        X[:, ~np.any(P != 0, 0)] = 0
        P = X
    # 与 71 完全相同的算式（float32 数组减 float64 标量，类型提升规则也一样），保证第一批逐位复现
    E = P[1] - origin[1]; N = P[0] - origin[0]; U = -(P[2] - origin[2])
    return E, N, U


def station_origin():
    p = out_dir()/"正射"/"格.json"
    if p.exists(): return np.array(json.loads(p.read_text())["origin_site"])
    return None


def ras_rgb(path):
    """辐射亮度（3 通道；好奇号单色复制成 3 通道），NaN = 无效。"""
    ras, lab = read_img(str(path)); s, o = L.rad_scale(lab)
    if ras.shape[0] == 1: ras = np.repeat(ras, 3, 0)
    rgb = ras*s + o; rgb[:, ~(np.nan_to_num(ras).min(0) > 0)] = np.nan
    return rgb, lab


# ── ① 正射 ─────────────────────────────────────────────────────────────────────────────
def ortho_frame(fr, grid=None):
    """同 71.ortho_frame，站点参数化：格距 cs、选点半径、原点（参考帧车位），帧号避免同分钟重名。"""
    t0 = time.time(); CS = cs_(); OUT = out_dir()
    P, lab = read_img(str(fr["xyz"]))
    meta = L.label_meta(lab)
    meta.update(xyz=fr["xyz"].name, seq=fr["seq"], shape=list(P.shape[1:]))
    di = group(lab, "DERIVED_IMAGE_PARMS")
    meta["coord"] = f'{di.get("REFERENCE_COORD_SYSTEM_NAME")} {di.get("REFERENCE_COORD_SYSTEM_INDEX")}'
    off = np.array(meta["rover_off"]); R = L.qrot(meta["rover_q"])
    r_sel = ST.get("r_sel", [1.0, 6.0])
    if grid is None:
        origin = off.copy()
    else:
        origin = np.array(grid["origin_site"])
    valid = np.any(P != 0, axis=0)
    E, N, U = to_enu(P, lab, origin)
    dE, dN = off[1] - origin[1], off[0] - origin[0]                       # 本帧车位相对站点原点
    r = np.hypot(E - dE, N - dN)
    sel = valid & (r > r_sel[0]) & (r < r_sel[1])
    if grid is None:                                                       # 参考帧定公共格：r_sel[0]–r_grid 内点的外包（或配置的 bbox）
        if ST.get("bbox"):
            x0, x1, y0, y1 = ST["bbox"]
        else:
            s2 = sel & (r < ST.get("r_grid", 5.5))
            x0, x1 = np.percentile(E[s2], [0.2, 99.8]); y0, y1 = np.percentile(N[s2], [0.2, 99.8])
        x0, y0 = math.floor(x0*50)/50, math.floor(y0*50)/50
        grid = dict(x0=x0, y0=y0, nx=int(math.ceil((x1 - x0)/CS)), ny=int(math.ceil((y1 - y0)/CS)), cs=CS, origin_site=origin.tolist(),
                    说明=f"ENU 米，原点 = {ST['id']} 参考帧的车导航点（站点系坐标 origin_site）；格 (i, j) 中心 = (x0 + (j+.5)cs, y0 + (i+.5)cs)；第 0 行在南")
        (OUT/"正射").mkdir(parents=True, exist_ok=True)
        (OUT/"正射"/"格.json").write_text(json.dumps(grid, ensure_ascii=False, indent=1))
        log(f"公共格：x {x0:.2f}…{x0 + grid['nx']*CS:.2f}，y {y0:.2f}…{y0 + grid['ny']*CS:.2f} m，{grid['nx']}×{grid['ny']}")
    nx, ny, x0, y0 = grid["nx"], grid["ny"], grid["x0"], grid["y0"]
    jj = np.floor((E - x0)/CS).astype(np.int64); ii = np.floor((N - y0)/CS).astype(np.int64)
    sel &= (jj >= 0) & (jj < nx) & (ii >= 0) & (ii < ny)
    meta["n_in_grid"] = int(sel.sum())
    if sel.sum() < 1000:
        log(f"  {fr['xyz'].name}：格内只有 {sel.sum()} 点，跳过"); return None
    camL = L.camera_site(lab)
    meta["cam_C_enu"] = (M_SE @ (camL["C"] - origin)).tolist()
    rr_, cc_ = np.nonzero(sel); k = np.random.default_rng(0).choice(len(rr_), min(20000, len(rr_)), replace=False)
    try:
        xs, ys, _ = L.cahvor(camL, P[:, rr_[k], cc_[k]].T.astype(np.float64) if "ROVER" not in meta["coord"].upper() else
                             np.stack([N[rr_[k], cc_[k]] + origin[0], E[rr_[k], cc_[k]] + origin[1], -U[rr_[k], cc_[k]] + origin[2]], 1).astype(np.float64))
        meta["proj_err_px"] = float(np.median(np.hypot(xs - cc_[k], ys - rr_[k])))
    except Exception as e:                                                  # noqa: BLE001
        meta["proj_err_px"] = float("nan"); log(f"  投影自检失败 {e!r}")
    rgbL, labL = ras_rgb(fr["rasL"])
    nrm = None
    if fr.get("uvw") is not None:
        W, labW = read_img(str(fr["uvw"]))
        ref = group(labW, "DERIVED_IMAGE_PARMS").get("REFERENCE_COORD_SYSTEM_NAME", "")
        Wv = W[:, sel].astype(np.float64)
        if "ROVER" in ref: Wv = R @ Wv
        nrm = M_SE @ Wv
        del W
    vals = [U[sel], *[rgbL[c][sel] for c in range(3)]]
    if nrm is not None: vals += list(nrm)
    G, cnt = L.splat(ii[sel], jj[sel], ny, nx, vals)
    del rgbL
    (h, *rest), ok = L.fill_small(list(G), cnt)
    rgb = np.stack(rest[:3]); n = np.stack(rest[3:6]) if nrm is not None else None
    if n is not None: n /= np.maximum(np.linalg.norm(np.nan_to_num(n), axis=0), 1e-6)
    rgbR = None
    if fr.get("rasR") is not None:
        rasR, labR = read_img(str(fr["rasR"])); sR, oR = L.rad_scale(labR)
        camR = L.camera_site(labR)
        iv, jv = np.nonzero(ok)
        Ee = x0 + (jv + 0.5)*CS; Nn = y0 + (iv + 0.5)*CS; Uu = h[iv, jv]
        Ps = np.stack([Nn + origin[0], Ee + origin[1], -Uu + origin[2]], 1)
        xs, ys, den = L.cahvor(camR, Ps)
        H_, W_ = rasR.shape[1:]
        g = (xs >= 0) & (ys >= 0) & (xs < W_ - 1) & (ys < H_ - 1) & (den > 0)
        x0i = np.floor(xs[g]).astype(int); y0i = np.floor(ys[g]).astype(int); fx = xs[g] - x0i; fy = ys[g] - y0i
        rgbR = np.full((3, ny, nx), np.nan, np.float32)
        for c in range(3):
            b = rasR[min(c, rasR.shape[0] - 1)].astype(np.float32)*sR + oR; b[~(np.nan_to_num(rasR[min(c, rasR.shape[0] - 1)]) > 0)] = np.nan
            v = (b[y0i, x0i]*(1 - fx)*(1 - fy) + b[y0i, x0i + 1]*fx*(1 - fy) + b[y0i + 1, x0i]*(1 - fx)*fy + b[y0i + 1, x0i + 1]*fx*fy)
            rgbR[c, iv[g], jv[g]] = v
        del rasR
    used = {}
    tag = fr.get("tag") or L.frame_tag(meta["sol"], meta["ltst"] or "0000")
    meta.update(tag=tag, valid_frac=float(ok.mean()), pts_per_cell=float(np.median(cnt[cnt > 0])),
                fill_frac=float((ok & (cnt == 0)).sum()/max(ok.sum(), 1)))
    if rgbR is not None:
        m = ok & np.all(np.isfinite(rgbR), 0) & np.all(np.isfinite(rgb), 0)
        lL = rgb.mean(0); lR = rgbR.mean(0)
        ratio = lR[m]/np.maximum(lL[m], 1e-9)
        hpL = lL - L.gauss(np.nan_to_num(lL), 3); hpR = lR - L.gauss(np.nan_to_num(lR), 3)
        meta["LR"] = dict(ratio_med=float(np.median(ratio)), ratio_mad=float(np.median(np.abs(ratio - np.median(ratio)))),
                          ratio_rgb=[float(np.median(rgbR[c][m]/np.maximum(rgb[c][m], 1e-9))) for c in range(3)],
                          hp_corr=float(np.corrcoef(hpL[m][::7], hpR[m][::7])[0, 1]), frac=float(m.mean()))
    if n is not None:
        gy, gx = np.gradient(L.gauss(np.nan_to_num(h), 2), CS)
        nh = np.stack([-gx, -gy, np.ones_like(gx)]); nh /= np.linalg.norm(nh, axis=0)
        m = ok & np.all(np.isfinite(n), 0)
        meta["uvw_vs_h_deg"] = float(np.degrees(np.median(np.arccos(np.clip((n[:, m]*nh[:, m]).sum(0), -1, 1)))))
    np.savez(OUT/"正射"/f"{tag}.npz", h=np.where(ok, h, np.nan).astype(np.float32), rgb=rgb.astype(np.float32),
             rgbR=(rgbR if rgbR is not None else np.zeros((3, 1, 1))).astype(np.float32),
             n=(n if n is not None else np.zeros((3, 1, 1))).astype(np.float16), cnt=np.minimum(cnt, 255).astype(np.uint8), ok=ok,
             meta=json.dumps(meta, ensure_ascii=False))
    sm = slice(None, None, 4)
    L_ = rgb.mean(0)[sm, sm]
    if np.isfinite(L_).sum() > 100:
        pv = np.concatenate([np.repeat(L.stretch(L_)[..., None], 3, -1),
                             np.repeat(L.hillshade(h[sm, sm], CS*4, meta["sun_az"], meta["sun_el"], 3)[..., None], 3, -1)], 1)
        L.save_img(OUT/"正射"/f"预览_{tag}.jpg", pv)
    log(f"正射 {tag}（{fr['seq']}，{meta['shape'][1]}×{meta['shape'][0]}，LTST {meta['ltst']}，太阳 {meta['sun_az']:.1f}°/{meta['sun_el']:.1f}°）："
        f"有效 {meta['valid_frac']*100:.0f}%，每格 {meta['pts_per_cell']:.1f} 点，补 {meta['fill_frac']*100:.1f}%，投影自检 {meta['proj_err_px']:.2f} px，"
        f"UVW–高度法线 {meta.get('uvw_vs_h_deg', float('nan')):.1f}°，左右比 {meta.get('LR', {}).get('ratio_med', float('nan')):.3f}"
        f"（细节相关 {meta.get('LR', {}).get('hp_corr', float('nan')):.2f}），{time.time() - t0:.0f} s")
    return meta


def assign_tags(frs):
    """帧号 sol_HHMM（同 71）；同一分钟的多帧加 _1、_2。需要先读标签里的 LTST（读标签头，很快）。"""
    used = {}
    for fr in frs:
        head = open(fr["xyz"], "rb").read(1 << 18).decode("latin1")
        m = re.search(r"LOCAL_TRUE_SOLAR_TIME\s*=\s*['\"]?([0-9:]+)", head)
        sol = int(re.search(r"PLANET_DAY_NUMBER\s*=\s*(\d+)", head).group(1)) if re.search(r"PLANET_DAY_NUMBER\s*=\s*(\d+)", head) else fr["sol"]
        t = L.frame_tag(sol, m.group(1) if m else "0000"); t0 = t; k = 1
        while t in used: t = f"{t0}_{k}"; k += 1
        used[t] = fr["xyz"].name; fr["tag"] = t
    return frs


def register():
    """同 71.register：各帧配准到参考帧（水平仿射场 + 高度平面）；与参考帧几乎不重叠的帧不改正（记 overlap）。"""
    OUT = out_dir(); CS = cs_(); REF = ST["ref"]
    idx = frames_index()
    files = [OUT/"正射"/f"{t}.npz" for t in sorted(idx)] if idx else sorted((OUT/"正射").glob("0*.npz"))
    R = np.load(OUT/"正射"/f"{REF}.npz"); hR = R["h"]; LR = L._loglum(R); mR = json.loads(str(R["meta"]))
    ny, nx = hR.shape; I, J = np.mgrid[0:ny, 0:nx]
    res = {}
    for f in files:
        D = np.load(f); h = D["h"]; meta = json.loads(str(D["meta"])); tag = meta["tag"]
        daz = abs((meta["sun_az"] - mR["sun_az"] + 180) % 360 - 180); delv = abs(meta["sun_el"] - mR["sun_el"])
        by_lum = daz <= 13 and delv <= 3
        a_, b_, band = (LR, L._loglum(D), (0.7, 6)) if by_lum else (hR, h, (1.5, 10))
        m = np.isfinite(a_) & np.isfinite(b_)
        S = tile_shifts_cs(a_, b_, m, band=band)
        ci, cj, rms, nk = L.fit_affine(S) if len(S) >= 4 else (np.zeros(3), np.zeros(3), float("nan"), 0)
        if tag == REF: ci, cj, rms = np.zeros(3), np.zeros(3), 0.0
        if m.mean() < ST.get("reg_min_overlap", 0.3) and tag != REF:      # 同车位环拍：帧间只在边上重叠，仿射外推不可信 → 不改水平，只量高度偏移
            ci, cj, rms, nk = np.zeros(3), np.zeros(3), float("nan"), 0
        corr = dict(ci=list(map(float, ci)), cj=list(map(float, cj)), dz=[0.0, 0.0, 0.0])
        h2 = L.warp(h, corr); b2 = L.warp(b_, corr) if by_lum else h2
        m2 = np.isfinite(h2) & np.isfinite(hR)
        if m2.sum() > 1000:
            dz = (h2 - hR)[m2]; iv, jv = I[m2], J[m2]
            A = np.c_[np.ones(len(iv)), jv*CS, iv*CS]
            c = np.linalg.lstsq(A[::13], dz[::13], rcond=None)[0]
            if nk < 4 and tag != REF: c = np.array([np.median(dz), 0.0, 0.0])   # 重叠太少：只改高度偏移
            corr["dz"] = c.tolist()
            resid = dz - A @ c
            mad = float(np.median(np.abs(resid - np.median(resid))))
        else:
            dz = np.array([0.0]); c = np.zeros(3); resid = dz; mad = float("nan")
        S2 = tile_shifts_cs(a_, b2, np.isfinite(a_) & np.isfinite(b2), band=band)
        mag = lambda X: float(np.median(np.hypot(X[:, 2], X[:, 3]))*CS*1e3) if len(X) else float("nan")
        corners = np.array([[0, 0], [0, nx], [ny, 0], [ny, nx]], float)
        smax = float(max(np.hypot(ci[0] + ci[1]*a + ci[2]*b, cj[0] + cj[1]*a + cj[2]*b) for a, b in corners)*CS*1e3)
        res[tag] = dict(sol=meta["sol"], ltst=meta["ltst"], seq=meta["seq"], rmc=meta["rmc"], sun=[meta["sun_az"], meta["sun_el"]],
                        method="亮度" if by_lum else "高度", 改正=corr,
                        dz_med_mm=float(np.median(dz)*1e3), tilt_mm_per_m=[float(c[1]*1e3), float(c[2]*1e3)], resid_mad_mm=mad*1e3,
                        frac_changed_2cm=float((np.abs(resid) > 0.02).mean()), overlap=float(m.mean()),
                        shift_before_mm=mag(S), shift_after_mm=mag(S2), shift_max_mm=smax, affine_rms_mm=rms*CS*1e3, n_tiles=nk,
                        peak_med=float(np.median(S[:, 4])) if len(S) else None)
        log(f"配准 {tag}（按{'亮度' if by_lum else '高度'}，重叠 {m.mean()*100:.0f}%）：水平位移 中值 {mag(S):.2f} mm（格内最大 {smax:.1f} mm；{nk} 块，"
            f"仿射残差 {rms*CS*1e3:.2f} mm，峰 {res[tag]['peak_med'] or 0:.2f}）→ 改正后 {mag(S2):.2f} mm；高度 偏移 {np.median(dz)*1e3:+.1f} mm、"
            f"倾斜 ({c[1]*1e3:+.2f}, {c[2]*1e3:+.2f}) mm/m，残差 MAD {mad*1e3:.2f} mm，>2 cm 变化 {res[tag]['frac_changed_2cm']*100:.2f}%")
    (OUT/"正射"/"配准.json").write_text(json.dumps(res, ensure_ascii=False, indent=1))


def tile_shifts_cs(a, b, m, band):
    """71.tile_shifts 的块大小按 2 mm 格定（0.8 m 块、0.6 m 步）；格距不同时按米换算。"""
    k = kcs()
    T = int(round(400*k)); step = int(round(300*k))
    T = max(T//2*2, 64)
    return L.tile_shifts(a, b, m, T=T, step=step, band=band)


def load_frame(tag, aligned=True):
    """同 71.load_frame，目录换成本站。"""
    OUT = out_dir(); CS = cs_()
    D = np.load(OUT/"正射"/f"{tag}.npz"); meta = json.loads(str(D["meta"]))
    h, rgb, n, ok = D["h"], D["rgb"], D["n"].astype(np.float32), D["ok"]
    if aligned and (OUT/"正射"/"配准.json").exists():
        c = json.loads((OUT/"正射"/"配准.json").read_text())[tag]["改正"]
        h = L.warp(h, c); rgb = L.warp(rgb, c); n = L.warp(n, c) if n.shape[1] > 1 else n
        ny, nx = h.shape; I, J = np.mgrid[0:ny, 0:nx]
        h = h - (c["dz"][0] + c["dz"][1]*J*CS + c["dz"][2]*I*CS)
        ok = np.isfinite(h) & np.all(np.isfinite(rgb), 0)
    return dict(h=h, rgb=rgb, n=n, ok=ok, meta=meta, cnt=D["cnt"])


def cmd_ortho(args):
    frs = assign_tags(navcam_frames())
    if not frs: raise SystemExit(f"{ST['id']}：没有帧（先 下载）")
    (out_dir()/"正射").mkdir(parents=True, exist_ok=True)
    ref_xyz = ST.get("ref_xyz")
    ref = next((f for f in frs if f["tag"] == ST["ref"]), None) if not ref_xyz else next(f for f in frs if f["xyz"].name.startswith(ref_xyz))
    if ST.get("grid_from_sol"):                                             # s0530：同 71，用 sol 530 那帧定格
        ref = [f for f in frs if f["sol"] == ST["grid_from_sol"]][0]
    grid = json.loads((out_dir()/"正射"/"格.json").read_text()) if (out_dir()/"正射"/"格.json").exists() else None
    if (grid is None or "--重定格" in args) and ST.get("grid_union") and not ST.get("bbox"):
        ST["bbox"] = union_bbox(frs)                                        # 环拍拼图：所有帧的外包
    if grid is None or "--重定格" in args:
        ortho_frame(ref, None); grid = json.loads((out_dir()/"正射"/"格.json").read_text())
    nproc = int(next((a.split("=")[1] for a in args if a.startswith("--进程=")), "3"))
    if nproc > 1 and len(frs) > 1:
        from concurrent.futures import ProcessPoolExecutor
        with ProcessPoolExecutor(nproc, initializer=_init_worker, initargs=(ST,)) as ex:
            metas = list(ex.map(ortho_frame, frs, [grid]*len(frs)))
    else:
        metas = [ortho_frame(f, grid) for f in frs]
    idx = {m["tag"]: dict(xyz=m["xyz"], sol=m["sol"], ltst=m["ltst"], sun=[m["sun_az"], m["sun_el"]], seq=m["seq"], shape=m["shape"],
                          valid_frac=m["valid_frac"], rmc=m["rmc"]) for m in metas if m}
    (out_dir()/"正射"/"帧.json").write_text(json.dumps(idx, ensure_ascii=False, indent=1))
    register()


def union_bbox(frs):
    """各帧 r_sel 内地面点的外包并集（ENU，原点 = 参考帧车位）。"""
    ref = next(f for f in frs if f["tag"] == ST["ref"])
    _, lab0 = read_img(str(ref["xyz"])); origin, _ = rover_pose_in_site(lab0)
    r_sel = ST.get("r_sel", [1.0, 6.0]); bb = [9e9, -9e9, 9e9, -9e9]
    for fr in frs:
        P, lab = read_img(str(fr["xyz"])); E, N, U = to_enu(P, lab, origin)
        off, _ = rover_pose_in_site(lab); r = np.hypot(E - (off[1] - origin[1]), N - (off[0] - origin[0]))
        s = np.any(P != 0, 0) & (r > r_sel[0]) & (r < ST.get("r_grid", r_sel[1]))
        if s.sum() < 1000: continue
        x0, x1 = np.percentile(E[s], [0.2, 99.8]); y0, y1 = np.percentile(N[s], [0.2, 99.8])
        bb = [min(bb[0], x0), max(bb[1], x1), min(bb[2], y0), max(bb[3], y1)]
    log(f"拼图外包：x {bb[0]:.2f}…{bb[1]:.2f}，y {bb[2]:.2f}…{bb[3]:.2f} m")
    return [float(v) for v in bb]


def _init_worker(st):
    global ST
    ST = st


# ── ② 反照率 / 明暗分离（同 71.cmd_separate，帧表与「正午簇」参数化；光度立体不做）───────────────────────────
def horizon_tan(Hf, az, dmax):
    import torch
    CS = cs_()
    dev = "cuda" if torch.cuda.is_available() else "cpu"
    H = torch.from_numpy(np.ascontiguousarray(Hf, np.float32)).to(dev)
    ny, nx = H.shape
    de, dn = math.sin(math.radians(az)), math.cos(math.radians(az))
    best = torch.full_like(H, -10.0)
    seen = set()
    for k in range(1, int(dmax/CS) + 1):
        di, dj = int(round(k*dn)), int(round(k*de))
        if (di, dj) in seen: continue
        seen.add((di, dj))
        src = H[max(di, 0):ny + min(di, 0), max(dj, 0):nx + min(dj, 0)]
        ds = (slice(max(-di, 0), ny + min(-di, 0)), slice(max(-dj, 0), nx + min(-dj, 0)))
        t = (src - H[ds])/(math.hypot(di, dj)*CS)
        best[ds] = torch.maximum(best[ds], t)
    return best.cpu().numpy()


def normals_from(H, s):
    gy, gx = np.gradient(L.gauss(H, s) if s > 0 else H, cs_())
    n = np.stack([-gx, -gy, np.ones_like(gx)]); n /= np.linalg.norm(n, axis=0)
    return n.astype(np.float32)


def sep_frames():
    idx = frames_index()
    if ST.get("sep"): return [t for t in ST["sep"] if t in idx]
    ex = set(ST.get("sep_exclude", []))
    return [t for t in sorted(idx) if t not in ex and idx[t]["sun"][1] >= ST.get("sep_min_el", 8.0)]


def noon_cluster(metas):
    """「主光照簇」：s0530 沿用 71（太阳高度 46° ± 2.5°）；其他站取太阳方向离中心帧 ≤ 12° 的帧。其余帧用来量光照一致性。"""
    rule = ST.get("sep_ref_rule")
    if rule:
        return [i for i, m in enumerate(metas) if abs(m["sun_el"] - rule["el"]) < rule["tol"]]
    S = np.stack([L.sun_enu(m["sun_az"], m["sun_el"]) for m in metas])
    ang = np.degrees(np.arccos(np.clip(S @ S.T, -1, 1)))
    med = int(np.argmin(np.median(ang, 1)))
    return [i for i in range(len(metas)) if ang[med, i] <= 12]


def cmd_separate(args):
    t0 = time.time(); OUT = out_dir(); CS = cs_()
    (OUT/"分离").mkdir(parents=True, exist_ok=True)
    SEP = sep_frames()
    Fs = [load_frame(t) for t in SEP]
    metas = [F["meta"] for F in Fs]
    ny, nx = Fs[0]["h"].shape
    Hs = np.stack([F["h"] for F in Fs]); H = np.nanmedian(Hs, 0); nH = np.isfinite(Hs).sum(0)
    h_noise = float(np.nanmedian(np.abs(Hs - H[None]))*1e3) if len(Fs) > 1 else float("nan")
    best = None
    if ST.get("mosaic"):                                                    # 环拍拼图：每格只取点最密的那一帧（帧边缘互相差 8–10 mm，取中值会糊）
        # 点密度平滑到 5 cm 再比（每格常只有 1 个点，逐格比会来回跳，接缝遍地）；没数据的帧记 −1
        Cn = np.stack([np.where(F["ok"], L.gauss(np.where(F["ok"], F["cnt"].astype(np.float32), 0), 0.05/cs_()) + 1e-3*F["cnt"], -1) for F in Fs])
        best = np.argmax(Cn, 0); H = np.take_along_axis(Hs, best[None], 0)[0]
    del Hs
    k_ = kcs()
    sig_fill = 6.0*k_
    Hf, _ = L.nan_gauss(H, sig_fill); Hf = np.where(np.isfinite(H), H, Hf); Hf = np.where(np.isfinite(Hf), Hf, np.nanmedian(H))
    n_s = normals_from(Hf, ST["shade_sigma_m"]/cs_() if ST.get("shade_sigma_m") else 2.5*k_)   # 明暗用的法线：缺省 σ 5 mm（同 71）；半分辨率站放宽
    Hsh = L.gauss(Hf, ST["shade_sigma_m"]/cs_()) if ST.get("shade_sigma_m") else Hf                # 地平角（天空可见度、投射阴影）也用同一平滑的高度
    C = np.mean([m_["cam_C_enu"] for m_ in metas], 0)
    gx0 = json.loads((OUT/"正射"/"格.json").read_text())
    X_ = gx0["x0"] + (np.arange(nx) + 0.5)*CS; Y_ = gx0["y0"] + (np.arange(ny) + 0.5)*CS
    V = np.stack(np.broadcast_arrays(C[0] - X_[None, :], C[1] - Y_[:, None], C[2] - Hf)).astype(np.float32)
    V /= np.linalg.norm(V, axis=0)
    mu = np.clip((n_s*V).sum(0), 0.05, 1)
    phase = [float(np.degrees(np.arccos(np.clip(np.median((L.sun_enu(m_["sun_az"], m_["sun_el"])[:, None]*V[:, ::50, ::50].reshape(3, -1)).sum(0)), -1, 1)))) for m_ in metas]
    sh = np.zeros((ny, nx), np.float32)
    for az in range(0, 360, 45):
        t = horizon_tan(Hsh, az, 0.3); th = np.arctan(np.maximum(t, 0)); sh += np.sin(th)**2/8
    SV = ((1 - sh)*(1 + n_s[2])/2).astype(np.float32)
    lit, mu0s = [], []
    for m_ in metas:
        s = L.sun_enu(m_["sun_az"], m_["sun_el"])
        t = horizon_tan(Hsh, m_["sun_az"], 1.0)
        lit.append(np.clip((math.tan(math.radians(m_["sun_el"])) - t)/0.035 + 0.5, 0, 1).astype(np.float32))
        mu0s.append(np.clip(np.tensordot(s, n_s, 1), 0, 1).astype(np.float32))
    I = [F["rgb"] for F in Fs]
    valid = [F["ok"] & np.isfinite(H) for F in Fs]
    log(f"分离：{len(Fs)} 帧 {SEP}，公共高度 跨帧 MAD {h_noise:.2f} mm；相位角 {', '.join(f'{p:.0f}°' for p in phase)}；"
        f"投射阴影占比 {', '.join(f'{(1 - l[valid[i]]).mean()*100:.1f}%' for i, l in enumerate(lit))}（{time.time() - t0:.0f} s）")
    noon = noon_cluster(metas)
    off = [i for i in range(len(metas)) if i not in noon]
    def consistency(Af):
        lum = [np.nanmean(np.stack([Af[c][f] for c in range(3)]), 0) for f in range(len(metas))]
        ref = np.nanmedian(np.stack([lum[i] for i in noon]), 0)
        out = {}
        for i in off:
            d = np.log(lum[i]/ref); d = d[np.isfinite(d)]; d -= np.median(d)
            out[SEP[i]] = float(np.median(np.abs(d)))
        return out
    if not off and ST.get("single_illum_sky", True):                     # 单一光照：逐帧增益/天光比的回归是退化的 → 天光比由投射阴影定
        return separate_single(I, lit, mu0s, mu, SV, valid, metas, SEP, H, Hf, n_s, nH, phase, h_noise, t0, best)
    D0 = [np.ones_like(SV) for _ in metas]
    _, _, _, Af0 = L.solve_albedo(I, D0, np.zeros_like(SV), valid, L_iter=1)
    cons = {"不改正": consistency(Af0)}
    best = None
    Ls = (0.0, 0.25, 0.5, 0.75, 1.0) if off else (ST.get("L_default", 0.0),)
    for Lc in Ls:
        D = [L.lunar_lambert(mu0s[f], mu, Lc)*lit[f] for f in range(len(metas))]
        A, G, Ga, Af = L.solve_albedo(I, D, SV, valid)
        cons[f"L={Lc}"] = consistency(Af)
        sc = float(np.mean(list(cons[f"L={Lc}"].values()))) if off else 0.0
        log(f"  Lunar-Lambert L={Lc}：主光照簇外 {len(off)} 帧 与簇中值的反照率差（中位 |Δlog|）{', '.join(f'{k} {v:.3f}' for k, v in cons[f'L={Lc}'].items())}；"
            f"天空/直射 {np.round(Ga.mean(1)/np.maximum(G.mean(1), 1e-9), 3)}")
        if best is None or sc < best[0]: best = (sc, Lc, A, G, Ga, Af, D)
    sc, Lc, A, G, Ga, Af, D = best
    log(f"  取 L={Lc}" + (f"（不改正时 {', '.join(f'{v:.3f}' for v in cons['不改正'].values())}）" if off else "（单一光照簇，按缺省）"))
    lumA = A.mean(0)
    def hp(x): x = np.where(np.isfinite(x), x, np.nanmedian(x)); return x - L.gauss(x, 8*k_)
    corr = {}
    for i in off + noon[:1]:
        mm = valid[i] & np.isfinite(lumA)
        raw = np.log(np.maximum(I[i].mean(0), 1e-9)); sh_ = np.log(np.maximum(D[i] + Ga[i].mean()/max(G[i].mean(), 1e-9)*SV, 1e-3))
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
    leak = dict(corr=corr, shadow_vs_lit=rat, sky_only_frac=float(sky_only.sum()/max(np.isfinite(H).sum(), 1)))
    log(f"  阴影泄漏：高通相关（原始辐亮 → 反照率）{', '.join(f'{k} {v[chr(114)+chr(97)+chr(119)]:.2f}→{v[chr(97)+chr(108)+chr(98)+chr(101)+chr(100)+chr(111)]:.2f}' for k, v in corr.items())}；"
        f"阴影帧（天光模型）/受光帧 反照率比 中值 {np.median(rat) if rat else float('nan'):.2f}（{len(rat)} 帧）；只有天光样本的格 {leak['sky_only_frac']*100:.1f}%")
    np.savez(OUT/"分离"/"基线.npz", A=A.astype(np.float32), H=H.astype(np.float32), Hf=Hf.astype(np.float32), n_s=n_s.astype(np.float16),
             SV=SV.astype(np.float16), nlit=nlit.astype(np.uint8), nH=nH.astype(np.uint8), G=G, Ga=Ga, L=Lc)
    S = np.stack([L.sun_enu(m_["sun_az"], m_["sun_el"]) for m_ in metas])
    sv = np.linalg.svd(S, compute_uv=False) if len(S) >= 3 else np.array([1.0])
    metrics = dict(frames=SEP, sun=[[m_["sun_az"], m_["sun_el"]] for m_ in metas], ltst=[m_["ltst"] for m_ in metas], phase_deg=phase,
                   h_cross_frame_mad_mm=h_noise, L=Lc, noon=[SEP[i] for i in noon], off=[SEP[i] for i in off], consistency=cons,
                   gain=G.tolist(), sky=Ga.tolist(), leak=leak, sun_cond=float(sv[0]/max(sv[-1], 1e-9)) if len(sv) == 3 else None,
                   n_illum=len(off) + (1 if noon else 0), seconds=time.time() - t0)
    (OUT/"分离"/"指标.json").write_text(json.dumps(metrics, ensure_ascii=False, indent=1))
    sm = (slice(None, None, 4), slice(None, None, 4))
    lo = lambda x: L.stretch(np.log(np.maximum(x, 1e-9)))
    pv = np.concatenate([np.repeat(lo(I[off[0] if off else 0].mean(0)[sm])[..., None], 3, -1),
                         np.moveaxis(np.stack([L.stretch(A[c][sm]) for c in range(3)]), 0, -1)], 1)
    L.save_img(OUT/"分离"/"预览_辐亮_反照率.jpg", pv)
    log(f"分离完成（{time.time() - t0:.0f} s）")


def sky_ratio_from_shadows(I, D, lit, SV, valid, blk=None):
    """同一帧里投射阴影与旁边受光的地面比亮度定天光比 a：I_受光 = ρ(D + a·SV)，I_阴影 = ρ·a·SV，
    r = I_阴影/I_受光 → a = r·D_受光 /(SV_阴影 − r·SV_受光)。按 ~6 cm 小块各算一次（块内反照率近似相同），取中值。逐通道。"""
    blk = blk or max(int(round(0.064/cs_())), 8)
    ny, nx = SV.shape; out = [[], [], []]
    for i0 in range(0, ny - blk + 1, blk):
        for j0 in range(0, nx - blk + 1, blk):
            sl = (slice(i0, i0 + blk), slice(j0, j0 + blk)); v = valid[sl]
            sh = v & (lit[sl] < 0.01); li = v & (lit[sl] > 0.99)
            if sh.sum() < 0.15*blk*blk or li.sum() < 0.15*blk*blk: continue
            Dl = np.median(D[sl][li]); SVs = np.median(SV[sl][sh]); SVl = np.median(SV[sl][li])
            for c in range(3):
                r = np.median(I[c][sl][sh])/max(np.median(I[c][sl][li]), 1e-12)
                den = SVs - r*SVl
                if 0 < r < 0.95 and den > 1e-3: out[c].append(r*Dl/den)
    return [float(np.median(o)) if len(o) >= 5 else float("nan") for o in out], len(out[0])


def separate_single(I, lit, mu0s, mu, SV, valid, metas, SEP, H, Hf, n_s, nH, phase, h_noise, t0, best=None):
    """单一光照站：A_f = I_f /(D_f + a_f·SV)（Lunar-Lambert L 取缺省），a_f 由本帧投射阴影/受光对比定；多帧（拼图）取中值。
    增益 g 不定（反照率只要相对值），各帧按重叠区中值对齐到参考帧。"""
    OUT = out_dir(); Lc = ST.get("L_default", 0.0)
    # 投射阴影：单帧时由立体高度算出的阴影位置不可信（半分辨率站与图像的高通相关 ≈ 0），不拿它去除；
    # 改为「预测阴影（外扩 1 cm）且图像上确实暗（比 5 cm 邻域中值暗 0.15 log 以上）」的格当阴影，切块时作空洞补。
    from scipy.ndimage import binary_dilation, median_filter
    lit_pred = lit; lit = []
    for f in range(len(metas)):
        ll = np.log(np.maximum(np.nan_to_num(I[f].mean(0)), 1e-12))
        loc = L.gauss(np.where(valid[f], ll, np.nanmedian(ll[valid[f]])), 0.025/cs_())
        dark = valid[f] & (ll - loc < -0.15)
        near = binary_dilation(lit_pred[f] < 0.5, iterations=max(int(round(0.01/cs_())), 1))
        lit.append(np.where(dark & near, 0.0, 1.0).astype(np.float32))
    D = [L.lunar_lambert(mu0s[f], mu, Lc) for f in range(len(metas))]
    sky, nb = [], []
    for f in range(len(metas)):
        a, n = sky_ratio_from_shadows(I[f], D[f]*lit_pred[f], lit_pred[f], SV, valid[f]); sky.append(a); nb.append(n)
    # 阴影块 < 100 时阴影法不稳（s0530 正午帧只有 12–27 块，给出 4–12，明显偏大：小石子的阴影格多半标错），改用天光模型：
    # a = 0.7·(exp(τ/sin h) − 1)·sin h —— s0530 长影帧的阴影法实测（14:33 a = 0.80，15:49 a = 1.18）按 τ = 0.6 拟合，c = 0.72 / 0.69
    tau = ST.get("tau", 0.6); src = []
    for f in range(len(metas)):
        sh_ = math.sin(math.radians(max(metas[f]["sun_el"], 3)))
        model = 0.7*(math.exp(tau/sh_) - 1)*sh_
        if nb[f] >= 100 and all(np.isfinite(sky[f])): src.append("阴影法")
        else: sky[f] = [model]*3; src.append(f"模型 τ={tau}")
    Af = []
    for f in range(len(metas)):
        den = np.stack([D[f] + sky[f][c]*SV for c in range(3)])
        a_ = np.where(valid[f][None] & (den > 0.05) & (lit[f] > 0.5)[None], I[f]/np.maximum(den, 1e-9), np.nan); Af.append(a_)
    ri = SEP.index(ST["ref"]) if ST["ref"] in SEP else 0
    G = np.ones((len(metas), 3))
    for f in range(len(metas)):                                             # 帧间增益：与参考帧重叠区的中值比（重叠太少就不改）
        m = np.all(np.isfinite(Af[f]), 0) & np.all(np.isfinite(Af[ri]), 0)
        if f != ri and m.sum() > 2000:
            for c in range(3): G[f, c] = np.median(Af[f][c][m])/np.median(Af[ri][c][m])
        Af[f] = Af[f]/G[f][:, None, None]
    if best is None:
        A = np.nanmedian(np.stack(Af), 0).astype(np.float32); seam = np.zeros(H.shape, bool)
    else:
        A = np.take_along_axis(np.stack(Af), best[None, None], 0)[0].astype(np.float32)
        from scipy.ndimage import binary_dilation
        e = (np.diff(best, axis=0, prepend=best[:1]) != 0) | (np.diff(best, axis=1, prepend=best[:, :1]) != 0)
        seam = binary_dilation(e & np.isfinite(H), iterations=max(int(0.02/cs_()), 1))
    nlit = np.sum([(l > 0.99) & v for l, v in zip(lit, valid)], 0); nshd = np.sum([(l < 0.01) & v for l, v in zip(lit, valid)], 0)
    sky_only = np.isfinite(H) & (nlit == 0) & (nshd > 0)
    lumA = A.mean(0)
    def hp(x): x = np.where(np.isfinite(x), x, np.nanmedian(x)); return x - L.gauss(x, 8*kcs())
    corr = {}
    for i in range(min(len(metas), 3)):
        mm = valid[i] & np.isfinite(lumA) & (lit[i] > 0.5)
        raw = np.log(np.maximum(I[i].mean(0), 1e-9)); sh_ = np.log(np.maximum(D[i] + np.mean(sky[i])*SV, 1e-3))
        corr[SEP[i]] = dict(raw=float(np.corrcoef(hp(raw)[mm][::11], hp(sh_)[mm][::11])[0, 1]),
                            albedo=float(np.corrcoef(hp(np.log(np.maximum(lumA, 1e-9)))[mm][::11], hp(sh_)[mm][::11])[0, 1]))
    log(f"  单一光照：天光比 a（逐帧 RGB）{[np.round(a, 2).tolist() for a in sky]}（来源 {src}，阴影块数 {nb}）；帧间增益 {np.round(G.mean(1), 3).tolist()}；"
        f"明暗高通相关（原始 → 反照率）{', '.join(f'{k} {v[chr(114)+chr(97)+chr(119)]:.2f}→{v[chr(97)+chr(108)+chr(98)+chr(101)+chr(100)+chr(111)]:.2f}' for k, v in corr.items())}；"
        f"只有阴影样本的格 {sky_only.sum()/max(np.isfinite(H).sum(), 1)*100:.1f}%")
    np.savez(OUT/"分离"/"基线.npz", A=A, H=H.astype(np.float32), Hf=Hf.astype(np.float32), n_s=n_s.astype(np.float16),
             SV=SV.astype(np.float16), nlit=nlit.astype(np.uint8), nH=nH.astype(np.uint8), G=G, Ga=np.array(sky), L=Lc, seam=seam,
             best=(best if best is not None else np.zeros(1)).astype(np.uint8))
    metrics = dict(frames=SEP, mode="单一光照", sun=[[m_["sun_az"], m_["sun_el"]] for m_ in metas], ltst=[m_["ltst"] for m_ in metas],
                   phase_deg=phase, h_cross_frame_mad_mm=h_noise, L=Lc, sky_ratio=sky, sky_src=src, sky_blocks=nb, tau=tau, frame_gain=G.tolist(),
                   leak=dict(corr=corr, sky_only_frac=float(sky_only.sum()/max(np.isfinite(H).sum(), 1))), n_illum=1, seconds=time.time() - t0)
    (OUT/"分离"/"指标.json").write_text(json.dumps(metrics, ensure_ascii=False, indent=1))
    log(f"分离完成（单一光照，{time.time() - t0:.0f} s）")


# ── ③ 切块 ──────────────────────────────────────────────────────────────────────────────
def classify(A, H, ok, prm):
    """同 71.classify，阈值参数化：亮格 = 亮度对 trend 米趋势的残差 > 暗众数 + thr；2.5 cm 邻域亮格占比 > slab = 岩板，> frag = 碎片。"""
    from scipy.ndimage import binary_closing
    CS = cs_()
    Y = A.mean(0)
    ly = np.log(np.maximum(Y, 1e-9)); ly[~ok] = np.nan
    lb, _ = L.nan_gauss(ly, prm.get("trend", 1.5)/CS)
    lr = ly - lb
    hist, edges = np.histogram(lr[ok & np.isfinite(lr)], 200, (-1, 1)); mode = edges[np.argmax(hist)] + 0.005
    bright = np.nan_to_num(lr, nan=-9) > mode + prm.get("thr", 0.22)
    bd = L.gauss(bright.astype(np.float32), prm.get("r", 0.025)/CS)
    slab = binary_closing(bd > prm.get("slab", 0.6), np.ones((5, 5)))
    cls = np.zeros(Y.shape, np.uint8); cls[(bd > prm.get("frag", 0.15)) & ~slab] = 1; cls[slab] = 2
    cls[~ok] = 255
    return cls, lr, float(mode), bd


def export_godot(pid, Ad, Hd, px, extra):
    """现有细节图块格式，按块 gain（同 61.albedo_gain）：<id>_albedo.png = round(A/gain·255)，<id>_height.bin = int32 宽高 + float32 米。"""
    from PIL import Image
    d = out_dir()/"godot"; d.mkdir(parents=True, exist_ok=True)
    gain = max(math.ceil(float(Ad.max())*100 - 1e-9)/100, 0.5)
    q = (np.clip(Ad/gain, 0, 1)*255 + 0.5).astype(np.uint8)
    Image.fromarray(q, "RGB").save(d/f"{pid}_albedo.png")
    rng_ = float(np.percentile(np.abs(Hd), 99.5))*1.2 + 1e-6
    with open(d/f"{pid}_height.bin", "wb") as f:
        np.array(Hd.shape[::-1], np.int32).tofile(f); Hd.astype(np.float32).tofile(f)
    dec = q.reshape(-1, 3).astype(np.float64).mean(0)/255*gain
    return dict(albedo=f"{pid}_albedo.png", height=f"{pid}_height.bin", size=px*Ad.shape[0], height_range=rng_, px=px, gain=gain,
                decoded_mean=[round(float(x), 4) for x in dec], **extra)


def photo_crop(fr, x0, y0, size, origin):
    """同一块地在某帧原图（RAS 左）上的透视裁切：ENU 落在块内的像素外包框。"""
    P, lab = read_img(str(fr["xyz"]))
    E, N, _ = to_enu(P, lab, origin); v = np.any(P != 0, 0)
    rgb, _ = ras_rgb(fr["rasL"])
    m = v & (E >= x0) & (E < x0 + size) & (N >= y0) & (N < y0 + size)
    r, c = np.nonzero(m)
    if len(r) < 100: return None
    r0, r1 = np.percentile(r, [0.5, 99.5]).astype(int); c0, c1 = np.percentile(c, [0.5, 99.5]).astype(int)
    im = np.moveaxis(rgb[:, r0:r1, c0:c1], 0, -1)
    return im/np.nanpercentile(im, 99.5)


def mastcam_patch(xyz_files, cs, N, origin, sky=0.5, center=None, search=1.6):
    """同 71.mastcam_patch（多帧平均正射 → Lambert 直射 × 投射阴影 + 常数天光去光影），原点参数化，IOF 用修正后的读取器（ODL 缩放）。"""
    Es, Ns, Us, cols = [], [], [], []
    sun = None; crops = []
    for xf in xyz_files:
        P, lab = read_img(str(xf))
        iof = sorted(xf.parent.glob(xf.name[:23].replace("ZLF", "ZL0") + "IOF_*.IMG"))
        if not iof: continue
        I, _ = read_img(str(iof[-1])); rgb = L.demosaic_rggb(I)
        if rgb.shape[1:] != P.shape[1:]: log(f"  {xf.name}: IOF {rgb.shape} 与 XYZ {P.shape} 不同尺寸，跳过"); continue
        off, q = rover_pose_in_site(lab); az, el = L.site_sun(lab); sun = (az, el)
        o = origin if origin is not None else off
        v = np.any(P != 0, 0) & np.all(np.isfinite(rgb), 0)
        Es.append(P[1][v] - o[1]); Ns.append(P[0][v] - o[0]); Us.append(-(P[2][v] - o[2])); cols.append(rgb[:, v])
        crops.append((P, o, rgb))
    E = np.concatenate(Es); Nn = np.concatenate(Ns); U = np.concatenate(Us); col = np.concatenate(cols, 1)
    cx, cy = (np.median(E), np.median(Nn)) if center is None else center
    if center is None:
        M_ = int(search/cs); hb = M_*cs/2
        _, _, okb, _ = L.ortho_points(E, Nn, U, [], cx - hb, cy - hb, M_, cs)
        from scipy.ndimage import uniform_filter
        f = uniform_filter(okb.astype(np.float32), N); f[:N//2] = f[-N//2:] = f[:, :N//2] = f[:, -N//2:] = 0
        i, j = np.unravel_index(np.argmax(f), f.shape)
        cx, cy = cx - hb + (j + .5)*cs, cy - hb + (i + .5)*cs
    half = N*cs/2
    h, rgb, ok, cnt = L.ortho_points(E, Nn, U, list(col), cx - half, cy - half, N, cs)
    Hf, _ = L.nan_gauss(h, 4.0); Hf = np.where(np.isfinite(h), h, Hf); Hf = np.where(np.isfinite(Hf), Hf, np.nanmedian(h))
    s = L.sun_enu(*sun)
    gy, gx = np.gradient(L.gauss(Hf, 3.0), cs)
    n = np.stack([-gx, -gy, np.ones_like(gx)]); n /= np.linalg.norm(n, axis=0)
    mu0 = np.clip(np.tensordot(s, n, 1), 0, 1)
    de, dn = math.sin(math.radians(sun[0])), math.cos(math.radians(sun[0]))
    tmax = np.full_like(Hf, -10)
    for k in range(1, int(0.15/cs)):
        di, dj = int(round(k*dn)), int(round(k*de))
        src = np.roll(Hf, (-di, -dj), (0, 1)); tmax = np.maximum(tmax, (src - Hf)/(math.hypot(di, dj)*cs))
    lit = (tmax < math.tan(math.radians(sun[1]))).astype(np.float32)
    shade = mu0*lit + sky
    A = rgb/np.maximum(shade, 1e-3)[None]
    good = ok & np.all(np.isfinite(A), 0) & (lit > 0)
    return dict(h=h, A=A, rgb=rgb, ok=good, cnt=cnt, sun=sun, center=(float(cx), float(cy)), crops=crops, bounds=(cx - half, cy - half, cs, N),
                shadow_frac=float(1 - lit[ok].mean()) if ok.any() else 0.0)


def seam_step(a3, hh, ok, lab, cs, sig_m=0.02):
    """块内帧接缝的台阶：按「每格取哪一帧」（拼图站）或「参与中值的帧数」（中值站）分区，相邻两区各自在本区内做 2 cm 归一化平滑，
    在两区交界处比 log 反照率和高度，取中位差。自然纹理和交界线无关，中位差 ≈ 0；帧间增益/高度偏移会留下一致的台阶。
    返回（最大 |Δlog A|，最大 |ΔH| 毫米，交界格数）。"""
    from scipy.ndimage import gaussian_filter as G
    la = np.log(np.maximum(np.nan_to_num(a3.mean(0)), 1e-9)); h = np.nan_to_num(hh); sig = sig_m/cs
    labs = [v for v in np.unique(lab[ok]) if (lab[ok] == v).mean() > 0.02]
    if len(labs) < 2: return 0.0, 0.0, 0
    sm = {}
    for v in labs:
        m = (ok & (lab == v)).astype(np.float32); gm = G(m, sig)
        sm[v] = (gm, G(la*m, sig)/np.maximum(gm, 1e-6), G(h*m, sig)/np.maximum(gm, 1e-6))
    sA = sH = 0.0; nb = 0
    for i, a in enumerate(labs):
        for b in labs[i + 1:]:
            bd = np.zeros(lab.shape, bool)
            for x, y, s_ in ((lab[:-1], lab[1:], (slice(None, -1),)), (lab[:, :-1], lab[:, 1:], (slice(None), slice(None, -1)))):
                bd[s_] |= ((x == a) & (y == b)) | ((x == b) & (y == a))
            sel = bd & (sm[a][0] > 0.2) & (sm[b][0] > 0.2)
            if sel.sum() < 100: continue
            dA = float(np.median(sm[a][1][sel] - sm[b][1][sel])); dH = float(np.median(sm[a][2][sel] - sm[b][2][sel]))*1e3
            sA = max(sA, abs(dA)); sH = max(sH, abs(dH)); nb += int(sel.sum())
    return sA, sH, nb


def cmd_cut(args):
    t0 = time.time(); OUT = out_dir(); CS = cs_()
    (OUT/"切块").mkdir(parents=True, exist_ok=True)
    for f in list((OUT/"切块").glob(f"{ST['id']}_*")) + list((OUT/"godot").glob(f"{ST['id']}_*")):   # 重切：先清掉本站旧块（规则变了，旧块不能留着混进来）
        f.unlink()
    patches = []
    frs = {f["tag"]: f for f in assign_tags(navcam_frames())} if ST.get("frames") or ST.get("local_glob") else {}
    gx0 = json.loads((OUT/"正射"/"格.json").read_text()) if (OUT/"正射"/"格.json").exists() else None
    origin = np.array(gx0["origin_site"]) if gx0 else None
    cut = ST.get("cut", {})
    if (OUT/"分离"/"基线.npz").exists():
        B = np.load(OUT/"分离"/"基线.npz"); A, H = B["A"], B["H"]; nH = B["nH"]; nlit = B["nlit"]
        ok = np.all(np.isfinite(A), 0) & np.isfinite(H) & (nH >= cut.get("min_frames", 4))
        if cut.get("mask_shadow"):                                         # 第一批的教训：每帧都在投射阴影里的格（只有天光样本）当空洞补
            ok &= nlit > 0
        cls, lr, mode, bd = classify(A, H, ok, cut.get("classify", {}))
        np.savez_compressed(OUT/"切块"/"分类.npz", cls=cls, lr=lr.astype(np.float16))
        frac = {k: float((cls == i).sum()/max(ok.sum(), 1)) for i, k in enumerate(["暗", "碎片", "亮板"])}
        log(f"切块：分类 {', '.join(f'{k} {v*100:.0f}%' for k, v in frac.items())}（暗众数 log {mode:+.2f}）；有效格 {ok.mean()*100:.0f}%")
        sm = (slice(None, None, 4), slice(None, None, 4))
        pal = np.array([[0.35, 0.22, 0.15], [0.95, 0.75, 0.2], [0.95, 0.9, 0.8]])
        cv = np.zeros(cls[sm].shape + (3,)); c_ = cls[sm]
        for i in range(3): cv[c_ == i] = pal[i]
        env = dict(np=np, sand=(cls == 0).astype(np.float32), frag=(cls == 1).astype(np.float32), slab=(cls == 2).astype(np.float32),
                   okf=ok.astype(np.float32), bd=bd, lr=np.nan_to_num(lr),
                   shadow=(np.isfinite(H) & (nlit == 0)).astype(np.float32), gauss=L.gauss, cs=CS)
        env["fragd"] = L.gauss(env["frag"], 0.03/CS)
        hd = np.where(np.isfinite(H), H, np.nanmedian(H)); env["rough"] = np.abs(hd - L.gauss(hd, 0.05/CS))
        env["hrel"] = hd - L.gauss(hd, 0.5/CS)
        env["seam"] = B["seam"].astype(np.float32) if "seam" in B else np.zeros_like(env["okf"])
        from scipy.ndimage import binary_dilation as _bd                    # 帧覆盖边：参与中值的帧数在这里变（跨过去高度/反照率会有台阶）
        e_ = (np.diff(nH.astype(np.int16), axis=0, prepend=nH[:1].astype(np.int16)) != 0) | (np.diff(nH.astype(np.int16), axis=1, prepend=nH[:, :1].astype(np.int16)) != 0)
        env["edge"] = _bd(e_ & np.isfinite(H), iterations=max(int(0.02/CS), 1)).astype(np.float32)
        env["nH"] = nH.astype(np.float32)
        Cx, Cy = np.meshgrid(gx0["x0"] + (np.arange(A.shape[2]) + .5)*CS, gx0["y0"] + (np.arange(A.shape[1]) + .5)*CS)
        env["r"] = np.hypot(Cx, Cy).astype(np.float32)                    # 离车距离（米）
        env["x"], env["y"] = Cx.astype(np.float32), Cy.astype(np.float32)  # ENU（米）
        def add(typ, i0, j0, N, sc, note, kmax, sub=None):
            sl = (slice(i0, i0 + N), slice(j0, j0 + N))
            a = A[:, sl[0], sl[1]].copy(); hh = H[sl].copy(); m = ok[sl].copy()
            hole = float(1 - m.mean())
            if sum(1 for p in patches if p["type"] == typ) >= kmax: return False      # 本类已够数
            if hole > cut.get("max_hole", 0.08):
                log(f"  跳过 {typ} 候选 ({i0}, {j0})：空洞 {hole*100:.0f}%"); return False
            if m.shape != (N, N): return False
            lab = (B["best"] if B["best"].shape == H.shape else nH)[sl] if "best" in B.files else nH[sl]
            sA, sH, nb = seam_step(a, hh, m, lab, CS)
            ms = cut.get("max_seam_step")                                   # [log 反照率, 毫米]：帧接缝台阶超过就换下一个候选
            if ms and (sA > ms[0] or sH > ms[1]):
                log(f"  跳过 {typ} 候选 ({i0}, {j0})：帧接缝台阶 {sA:.3f} log / {sH:.1f} mm"); return False
            a, hh = L.fill_patch(a, hh, m, seed=len(patches))
            Ad, Hd = L.make_detail(a, hh, CS, ST.get("h_lp", L.NAV_H_LP)*kcs())
            x0 = gx0["x0"] + j0*CS; y0 = gx0["y0"] + i0*CS
            k = sum(1 for p in patches if p["type"] == typ) + 1
            pid = f"{ST['id']}_{typ}_{k}"
            np.savez_compressed(OUT/"切块"/f"{pid}.npz", A=Ad, H=Hd, A_raw=a.astype(np.float32), H_raw=hh.astype(np.float32), mask=m)
            rc = float(np.hypot(x0 + N*CS/2, y0 + N*CS/2)); hc = ST.get("cam_h", 1.95)
            fp = [(max(rc - N*CS/2, 0.5)**2 + hc**2)*ST.get("ifov_mrad", 0.33)*1e-3/hc*1e3, (rc**2 + hc**2)*ST.get("ifov_mrad", 0.33)*1e-3/hc*1e3,
                  ((rc + N*CS/2)**2 + hc**2)*ST.get("ifov_mrad", 0.33)*1e-3/hc*1e3]    # 顺距离方向像素足迹（mm）：近边、中心、远边
            meta = dict(id=pid, type=typ, name=f"{typ}_{k}", x0=x0, y0=y0, size=N*CS, px=CS, score=sc, hole_frac=hole, note=note, sub=sub,
                        range_m=round(rc, 2), footprint_mm=[round(v, 1) for v in fp],
                        shadow_frac=float(env["shadow"][sl].mean()), nframes_med=float(np.median(nH[sl])),
                        seam_step_log=round(sA, 4), seam_step_mm=round(sH, 2),
                        src=f"{ST.get('rover', 'M2020')} Navcam {ST['id']}（{len(sep_frames())} 帧基线去光影）")
            meta["godot"] = export_godot(pid, Ad, Hd, CS, dict(来源=meta["src"], ENU=[x0, y0]))
            patches.append(meta)
            log(f"  {pid}：ENU ({x0:+.2f}, {y0:+.2f}) m，{N*CS:.2f} m / {CS*1e3:.0f} mm，得分 {sc:.2f}，空洞补 {hole*100:.1f}%，"
                f"全阴影格 {meta['shadow_frac']*100:.1f}%，反照率细节 σ(log) {np.log(Ad.mean(-1)).std():.3f}，高度 RMS {Hd.std()*1e3:.2f} mm，gain {meta['godot']['gain']}")
            cv[i0//4:(i0 + N)//4, j0//4] = cv[i0//4:(i0 + N)//4, (j0 + N)//4 - 1] = [0, 1, 1]
            cv[i0//4, j0//4:(j0 + N)//4] = cv[(i0 + N)//4 - 1, j0//4:(j0 + N)//4] = [0, 1, 1]
            return True
        for rule in cut.get("rules", []):
            N = int(round(rule["size"]/CS)) if "size" in rule else rule["N"]
            taken = np.zeros_like(env["okf"])
            for p in patches:
                if p["type"] in rule.get("avoid", []) or "*" in rule.get("avoid", []):
                    j0_ = int(round((p["x0"] - gx0["x0"])/CS)); i0_ = int(round((p["y0"] - gx0["y0"])/CS)); n_ = int(round(p["size"]/CS))
                    taken[i0_:i0_ + n_, j0_:j0_ + n_] = 1
            env["taken"] = taken
            score = eval(rule["score"], {"__builtins__": {}}, env)
            for i0, j0, sc in L.pick_windows(score, N, rule.get("k", 5)):
                if sc < rule.get("min_score", -1e9): continue
                note = rule.get("note", "")
                if rule.get("edge_note"):
                    e = np.r_[env["slab"][i0, j0:j0 + N], env["slab"][i0 + N - 1, j0:j0 + N], env["slab"][i0:i0 + N, j0], env["slab"][i0:i0 + N, j0 + N - 1]].mean()
                    note = f"{note}；边框过板比例 {e*100:.0f}%"
                add(rule["type"], i0, j0, N, sc, note, rule.get("max", 3), rule.get("sub"))
        for w in cut.get("windows", []):                                    # 手选窗口（ENU 左下角 + 边长）
            N = int(round(w["size"]/CS)); j0 = int(round((w["x0"] - gx0["x0"])/CS)); i0 = int(round((w["y0"] - gx0["y0"])/CS))
            add(w["type"], i0, j0, N, float(ok[i0:i0 + N, j0:j0 + N].mean()), w.get("note", "手选"), w.get("max", 9), w.get("sub"))
        L.save_img(OUT/"切块"/"分类与选块.jpg", cv)
        # 贴花（s0530 的 M12）：按真实位置切，不做周期分解
        for k, dc in enumerate(cut.get("decals", [])):
            ex, ny_ = dc["center"]; i = int((ny_ - gx0["y0"])/CS); j = int((ex - gx0["x0"])/CS)
            N = dc.get("N", 80); i0, j0 = max(i - N//2, 0), max(j - N//2, 0)
            sl = (slice(i0, i0 + N), slice(j0, j0 + N))
            a = A[:, sl[0], sl[1]]; hh = H[sl]; mm = ok[sl]
            a, hh = L.fill_patch(a, hh, mm, seed=99 + k, rmin=5, rmax=30)
            la = np.log(np.maximum(a, 1e-9)); Ad = np.exp(la - la.reshape(3, -1).mean(1)[:, None, None]).transpose(1, 2, 0)
            Hd = L.gauss(L.plane_remove(hh), L.NAV_H_LP)
            x0 = gx0["x0"] + j0*CS; y0 = gx0["y0"] + i0*CS
            pid = f"{ST['id']}_{dc['type']}_{k + 1}"
            np.savez_compressed(OUT/"切块"/f"{pid}.npz", A=Ad.astype(np.float32), H=Hd.astype(np.float32), A_raw=a, H_raw=hh, mask=mm)
            meta = dict(id=pid, type=dc["type"], name=f"{dc['type']}_{k + 1}", x0=x0, y0=y0, size=N*CS, px=CS,
                        center_enu=[gx0["x0"] + (j + .5)*CS, gx0["y0"] + (i + .5)*CS], label=dc["label"], hole_frac=float(1 - mm.mean()),
                        note=f"{dc['label']}贴花（不平铺、不做周期分解）", src="Navcam 基线反照率", decal=True)
            meta["godot"] = export_godot(pid, Ad, Hd, CS, dict(来源=meta["src"], ENU=[x0, y0], 贴花=True))
            patches.append(meta)
            log(f"  {pid}（{dc['label']}）：中心 ENU ({meta['center_enu'][0]:+.3f}, {meta['center_enu'][1]:+.3f}) m")
    # Mastcam-Z 块
    for z in ST.get("mastcam", {}).get("patches", []):
        try:
            d = (MAP/z["dir"]) if z.get("dir") else (PDS/"站"/ST["id"]/f"sol{z['sol']:04d}")
            xs = sorted(d.glob("ZLF_*XYZ_*.IMG"))
            if z.get("seq"): xs = [f for f in xs if z["seq"] in f.name]
            if z.get("files"): xs = [f for f in xs if any(f.name.startswith(p) for p in z["files"])]
            xs = [f for f in xs if read_img(str(f))[0].shape[1] > 500]
            cs = z["cs"]; N = z["N"]
            while True:
                r = mastcam_patch(xs, cs, N, origin if z.get("station_origin", True) and origin is not None else None,
                                  center=tuple(z["center"]) if z.get("center") else None, search=z.get("search", 1.6))
                m = r["ok"]
                if m.mean() >= z.get("min_valid", 0.75) or N <= z.get("N_min", 512): break
                N = int(N*0.85)//16*16
            a = np.where(m[None], r["A"], np.nan); hh = r["h"]
            fill = float(1 - m.mean())
            a, hh = L.fill_patch(a, hh, m, seed=z.get("seed", z["sol"]), rmin=10, rmax=N//3)
            Ad, Hd = L.make_detail(a, hh, cs, z.get("h_lp", 1.5))
            typ = z["type"]; k = sum(1 for p in patches if p["type"] == typ) + 1
            pid = f"{ST['id']}_{typ}_{k}"
            x0, y0 = r["bounds"][0], r["bounds"][1]
            np.savez_compressed(OUT/"切块"/f"{pid}.npz", A=Ad, H=Hd, A_raw=a.astype(np.float32), H_raw=hh.astype(np.float32), mask=m, rgb=r["rgb"].astype(np.float32))
            meta = dict(id=pid, type=typ, name=f"{typ}_{k}", x0=float(x0), y0=float(y0), size=N*cs, px=cs, hole_frac=fill, sun=r["sun"],
                        shadow_frac=r["shadow_frac"], note=z.get("note", ""), mastcam=True,
                        src=f"Mastcam-Z 110 mm sol {z['sol']} {', '.join(f.name[4:23] for f in xs)}，Lambert + 常数天光 0.5 去光影")
            meta["godot"] = export_godot(pid, Ad, Hd, cs, dict(来源=meta["src"], ENU=[float(x0), float(y0)]))
            patches.append(meta)
            best_ = None
            for P, off, rgb in r["crops"]:
                E = P[1] - off[1]; Nn = P[0] - off[0]
                mm = np.any(P != 0, 0) & (E >= x0) & (E < x0 + N*cs) & (Nn >= y0) & (Nn < y0 + N*cs)
                if best_ is None or mm.sum() > best_[0].sum(): best_ = (mm, rgb)
            mm, rgb = best_; rr, cc = np.nonzero(mm)
            if len(rr):
                im = np.moveaxis(rgb[:, rr.min():rr.max(), cc.min():cc.max()], 0, -1); np.save(OUT/"切块"/f"{pid}_照片.npy", (im/np.nanpercentile(im, 99.5)).astype(np.float16))
            log(f"  {pid}：{N*cs:.2f} m / {cs*1e3:.1f} mm，ENU ({x0:+.2f}, {y0:+.2f})，有效 {m.mean()*100:.0f}%，"
                f"反照率细节 σ(log) {np.log(Ad.mean(-1)).std():.3f}，高度 RMS {Hd.std()*1e3:.2f} mm，gain {meta['godot']['gain']}")
        except Exception as e:                                              # noqa: BLE001
            import traceback; traceback.print_exc(); log(f"  Mastcam {z.get('type')} sol {z.get('sol')} 失败：{e!r}")
    # Navcam 块的实拍裁切
    ph = frs.get(ST.get("photo")) if ST.get("photo") else None
    if ST.get("photo_sol"): ph = next((f for f in navcam_frames() if f["sol"] == ST["photo_sol"]), None)
    cache = {}
    def cover(fr, p):                                                       # 本帧原图里落在块内的像素数
        if fr["tag"] not in cache:
            P, lab = read_img(str(fr["xyz"])); E, N, _ = to_enu(P, lab, origin); cache[fr["tag"]] = (E[::4, ::4], N[::4, ::4], np.any(P != 0, 0)[::4, ::4])
        E, N, v = cache[fr["tag"]]
        return int((v & (E >= p["x0"]) & (E < p["x0"] + p["size"]) & (N >= p["y0"]) & (N < p["y0"] + p["size"])).sum())
    for p in patches:
        if p.get("mastcam"): continue
        fr = ph
        if fr is None and frs:                                              # 拼图站：取块内像素最多的那一帧
            fr = max(frs.values(), key=lambda f: cover(f, p))
        if fr is None: continue
        im = photo_crop(fr, p["x0"], p["y0"], p["size"], origin)
        if im is not None:
            np.save(OUT/"切块"/f"{p['id']}_照片.npy", im.astype(np.float16)); p["photo_frame"] = fr.get("tag")
    (OUT/"切块"/"样块.json").write_text(json.dumps(patches, ensure_ascii=False, indent=1, default=float))
    log(f"切块完成：{len(patches)} 块（{time.time() - t0:.0f} s）")


# ── 总览图 ──────────────────────────────────────────────────────────────────────────────
def cmd_overview(args):
    """本站正射总览：基线反照率（北朝上）+ 选块框 + 每 0.5 m 网格线，给人工选窗用。"""
    from PIL import Image, ImageDraw
    OUT = out_dir(); CS = cs_()
    B = np.load(OUT/"分离"/"基线.npz"); A = B["A"]; gx0 = json.loads((OUT/"正射"/"格.json").read_text())
    f = max(1, int(round(0.008/CS)))
    a = np.moveaxis(A[:, ::f, ::f], 0, -1)
    a = np.nan_to_num(a/np.nanpercentile(a, 99.5)); im = Image.fromarray(L.to_u8(a[::-1]))
    dr = ImageDraw.Draw(im); ny = im.size[1]
    for xm in np.arange(math.ceil(gx0["x0"]*2)/2, gx0["x0"] + gx0["nx"]*CS, 0.5):
        x = (xm - gx0["x0"])/CS/f; dr.line([(x, 0), (x, ny)], fill=(60, 60, 255) if abs(xm % 1) < 1e-6 else (40, 40, 120)); dr.text((x + 2, 2), f"{xm:+.1f}", fill=(120, 120, 255))
    for ym in np.arange(math.ceil(gx0["y0"]*2)/2, gx0["y0"] + gx0["ny"]*CS, 0.5):
        y = ny - (ym - gx0["y0"])/CS/f; dr.line([(0, y), (im.size[0], y)], fill=(60, 60, 255) if abs(ym % 1) < 1e-6 else (40, 40, 120)); dr.text((2, y + 2), f"{ym:+.1f}", fill=(120, 120, 255))
    pj = OUT/"切块"/"样块.json"
    if pj.exists():
        for p in json.loads(pj.read_text()):
            if p.get("mastcam"): continue
            x0 = (p["x0"] - gx0["x0"])/CS/f; y1 = ny - (p["y0"] - gx0["y0"])/CS/f; s = p["size"]/CS/f
            dr.rectangle([x0, y1 - s, x0 + s, y1], outline=(0, 255, 255), width=2); dr.text((x0 + 3, y1 - s + 3), p["name"], fill=(0, 255, 255))
    im.save(OUT/"总览.jpg", quality=88)
    log(f"总览 → {OUT/'总览.jpg'}（{im.size[0]}×{im.size[1]}，{CS*f*1e3:.0f} mm/像素）")


# ── ④ 样块库（目录 + 对照图）────────────────────────────────────────────────────────────
def color_stats(st_id, p):
    """块的平均线性 RGB（基线反照率，补洞后）÷ 本站参考（Navcam：整站有效格中值；Mastcam：本块所在帧的中值）。"""
    d = LIB/st_id
    Z = np.load(d/"切块"/f"{p['id']}.npz")
    a = Z["A_raw"].reshape(3, -1) if Z["A_raw"].shape[0] == 3 else np.moveaxis(Z["A_raw"], -1, 0).reshape(3, -1)
    m = Z["mask"].reshape(-1) if "mask" in Z else np.ones(a.shape[1], bool)
    mean = np.nanmean(a[:, m], 1)
    if p.get("mastcam"):
        ref = np.nanmedian(np.moveaxis(Z["rgb"], 0, 0).reshape(3, -1), 1) if "rgb" in Z else mean
    else:
        B = np.load(d/"分离"/"基线.npz"); A = B["A"]; ok = np.all(np.isfinite(A), 0)
        ref = np.array([np.nanmedian(A[c][ok][::7]) for c in range(3)])
    return (mean/ref).tolist(), mean.tolist()


def waypoint(st):
    """毅力号站点的经纬度、高程（MMGIS waypoints，按 site/drive；好奇号取配置里的 lat/lon）。"""
    if st.get("rover", "M2020") != "M2020": return {k: st.get(k) for k in ("lat", "lon", "elev_m")}
    f = MAP/"资料"/"NASA补充"/"位姿"/"MMGIS"/"M20_waypoints.json"
    if not f.exists(): return {}
    for w in json.loads(f.read_text())["features"]:
        p = w["properties"]
        if p.get("site") == st.get("site") and p.get("drive") == st.get("drive"):
            return dict(lat=round(p["lat"], 6), lon=round(p["lon"], 6), elev_m=round(p["elev_geoid"], 2))
    return {}


def cmd_catalog(args):
    """汇总所有站的 切块/样块.json → scripts/Godot/地面样块库.json；每类对照图 docs/地面材质/图/样块库_<类>.jpg。"""
    cfg = load_cfg(); types = cfg["类型"]
    rows = []
    for sid, st in cfg["站点"].items():
        pj = LIB/sid/"切块"/"样块.json"
        if not pj.exists(): continue
        sepm = json.loads((LIB/sid/"分离"/"指标.json").read_text()) if (LIB/sid/"分离"/"指标.json").exists() else {}
        cr = [v.get("albedo") for v in (sepm.get("leak") or {}).get("corr", {}).values() if isinstance(v, dict)]
        cr = [abs(x) for x in cr if x is not None and np.isfinite(x)]
        leak = round(max(cr), 3) if cr else None                             # 分离后反照率与明暗模型的高通相关（站级，前 3 帧最大值）
        for p in json.loads(pj.read_text()):
            Z = np.load(LIB/sid/"切块"/f"{p['id']}.npz")
            met = L.tile_metrics(Z["A"], Z["H"], p["px"]) if not p.get("decal") else {}
            rel_st, mean_raw = color_stats(sid, p)
            g = p["godot"]
            q = dict(hole_frac=round(p.get("hole_frac", 0), 4), shadow_frac=round(p.get("shadow_frac", 0), 4),
                     frames=(1 if p.get("mastcam") else len(sepm.get("frames", []))), illuminations=(1 if p.get("mastcam") else sepm.get("n_illum")),
                     nframes_med=p.get("nframes_med"), range_m=p.get("range_m"), footprint_mm=p.get("footprint_mm"),
                     seam_step_log=p.get("seam_step_log"), seam_step_mm=p.get("seam_step_mm"),
                     shading_leak_r=(None if p.get("mastcam") else leak))
            flags = []
            if q["hole_frac"] > 0.1: flags.append("空洞多")
            if q["shadow_frac"] > 0.03: flags.append("投射阴影多")
            if (q["seam_step_log"] or 0) > 0.04 or (q["seam_step_mm"] or 0) > 3: flags.append("帧接缝台阶")
            if (q["shading_leak_r"] or 0) > 0.12: flags.append(f"残余明暗（高通相关 {q['shading_leak_r']:.2f}）")
            if (p.get("footprint_mm") or [0, 0])[1] > 2.5*p["px"]*1e3: flags.append("远处像素足迹大于格距（反照率偏糊）")
            if not p.get("mastcam") and (q["frames"] or 0) < 3: flags.append("帧少")
            if not p.get("mastcam") and (q["illuminations"] or 0) < 2: flags.append("单一光照")
            if p.get("mastcam"): flags.append("单光照近似去光影")
            if st.get("rover") == "MSL": flags.append("单色（Navcam 全色）")
            flags += [f for f in p.get("flags", []) + st.get("flags", []) if not (f.startswith("残余明暗（高通相关") and any(g.startswith("残余明暗") for g in flags))]
            flags = list(dict.fromkeys(flags))                                 # 去重（站点配置里手写的和自动的可能重复）
            ent = dict(id=p["id"], type=p["type"], station=sid, rover=st.get("rover", "M2020"), site=st.get("site"), drive=st.get("drive"),
                       sols=st.get("sols") if not p.get("mastcam") else [int(re.search(r"sol (\d+)", p["src"]).group(1))] if re.search(r"sol (\d+)", p["src"]) else st.get("sols"),
                       camera="Mastcam-Z 110 mm" if p.get("mastcam") else f"{st.get('rover', 'M2020')} Navcam",
                       enu_x0y0=[round(p["x0"], 3), round(p["y0"], 3)], size_m=round(p["size"], 4), px_m=p["px"], n_px=int(round(p["size"]/p["px"])),
                       gain=g["gain"], height_range_m=round(g["height_range"], 5),
                       h_rms_mm=round(met.get("h_rms_mm", float(np.std(Z["H"]))*1e3), 3),
                       albedo_contrast=round(met.get("albedo_contrast", float(np.log(Z["A"].mean(-1)).std())), 4),
                       rb_contrast=round(met.get("rb_contrast", 0), 4) if met else None,
                       slope_rms_1cm_deg=round(met["slope_rms_1cm_deg"], 2) if met else None,
                       lam_dom_cm=round(met["lam_dom_m"]*100, 1) if met else None, psd_beta=round(met["psd_beta"], 2) if met else None,
                       rgb_rel_station=[round(x, 4) for x in rel_st], decal=bool(p.get("decal")), sub=p.get("sub"), note=p.get("note", ""),
                       quality=q, flags=flags,
                       files=dict(albedo=str((LIB/sid/"godot"/g["albedo"]).relative_to(MAP)), height=str((LIB/sid/"godot"/g["height"]).relative_to(MAP)),
                                  npz=str((LIB/sid/"切块"/f"{p['id']}.npz").relative_to(MAP)),
                                  photo=str((LIB/sid/"切块"/f"{p['id']}_照片.npy").relative_to(MAP)) if (LIB/sid/"切块"/f"{p['id']}_照片.npy").exists() else None))
            rows.append(ent)
    # 颜色相对类均值（几何平均）
    for t in {r["type"] for r in rows}:
        rs = [r for r in rows if r["type"] == t and not r["decal"]]
        if not rs: continue
        gm = np.exp(np.mean([np.log(np.maximum(r["rgb_rel_station"], 1e-6)) for r in rs], 0))
        for r in rs: r["rgb_rel_type"] = [round(float(x), 4) for x in np.array(r["rgb_rel_station"])/gm]
    cat = dict(说明=cfg["库说明"], 格式=cfg["库格式"], 生成="scripts/Godot/74_多站样块.py 库", 日期=time.strftime("%Y-%m-%d"),
               类型说明=cfg.get("类型说明"), 类型={k: v for k, v in types.items()},
               站点={sid: {k: st.get(k) for k in ("name", "rover", "site", "drive", "sols", "types", "note")} | waypoint(st) for sid, st in cfg["站点"].items()
                     if (LIB/sid/"切块"/"样块.json").exists()},
               样块=sorted(rows, key=lambda r: (int(re.sub(r"\D", "", r["type"]) or 0), r["station"], r["id"])))
    for k, v in cat["类型"].items():
        v["变体数"] = sum(1 for r in rows if r["type"] == k and not r["decal"])
        v["贴花数"] = sum(1 for r in rows if r["type"] == k and r["decal"])
    CATALOG.write_text(json.dumps(cat, ensure_ascii=False, indent=1))
    log(f"样块库：{len(rows)} 块，{len({r['type'] for r in rows})} 类 → {CATALOG}")
    if "--不画" not in args: contact_sheets(rows, types)


def contact_sheets(rows, types):
    """每类一张：一行一个变体（着色 | 反照率细节 | 高度晕渲 | 实拍），整块，≤ 1100 px 宽。"""
    DOCFIG.mkdir(parents=True, exist_ok=True)
    for t in sorted({r["type"] for r in rows}, key=lambda x: int(re.sub(r"\D", "", x) or 0)):
        rs = [r for r in rows if r["type"] == t]
        S = 200 if len(rs) <= 6 else 168; cells, labs = [], []                # 全部变体都画；行多时缩格子，保持图小
        for r in rs:
            Z = np.load(MAP/r["files"]["npz"]); A, H, px = Z["A"], Z["H"], r["px_m"]
            # 显示前降到 ≤ 512 格
            f = max(1, A.shape[0]//512); A = A[::f, ::f]; H = L.gauss(H, f/2)[::f, ::f] if f > 1 else H; pxs = px*f
            row = [L.panel(L.render(A, H, pxs), S), L.panel(A*0.5, S), L.panel(L.hillshade(H, pxs, *L.SUN_R), S)]
            ph = r["files"]["photo"]
            row.append(L.panel(np.load(MAP/ph).astype(np.float32), S) if ph and (MAP/ph).exists() else None)
            cells.append(row)
            labs.append(f"{r['id'].split('_', 1)[0]}\n#{r['id'].rsplit('_', 1)[-1]} {r['size_m']:.2f} m\n{r['px_m']*1e3:.1f} mm\nh {r['h_rms_mm']:.1f} mm")
        nm = types.get(t, {}).get("名称", t)
        L.sheet(cells, ["着色（225°/30° 太阳）", "反照率细节 ×0.5", "高度晕渲", "实拍（同一块地）"], S, DOCFIG/f"样块库_{t}.jpg",
                f"{t} {nm}：{len(rs)} 块", labs)
        f_ = DOCFIG/f"样块库_{t}.jpg"; q_ = 80
        while f_.stat().st_size > 390_000 and q_ >= 60:                       # 文档图 < 400 KB
            from PIL import Image
            Image.open(f_).convert("RGB").save(f_.with_suffix(".tmp.jpg"), quality=q_); f_.with_suffix(".tmp.jpg").replace(f_); q_ -= 6
        log(f"  图 样块库_{t}.jpg（{len(rs)} 行）")


# ── 核对：s0530 与第一批 ─────────────────────────────────────────────────────────────────
def cmd_check(args):
    old = {p["name"]: p for p in json.loads((B1/"切块"/"样块.json").read_text())}
    new = json.loads((LIB/"s0530"/"切块"/"样块.json").read_text())
    res = {}
    for p in new:
        o = old.get(p["name"])
        if o is None: log(f"  {p['id']}：第一批没有 {p['name']}"); continue
        Zo = np.load(B1/"切块"/f"{p['name']}.npz"); Zn = np.load(LIB/"s0530"/"切块"/f"{p['id']}.npz")
        dA = float(np.abs(Zo["A"] - Zn["A"]).max()) if Zo["A"].shape == Zn["A"].shape else float("nan")
        dH = float(np.abs(Zo["H"] - Zn["H"]).max()*1e3) if Zo["H"].shape == Zn["H"].shape else float("nan")
        same_pos = abs(o["x0"] - p["x0"]) < 1e-9 and abs(o["y0"] - p["y0"]) < 1e-9 and abs(o["size"] - p["size"]) < 1e-9
        rA = float(np.corrcoef(np.log(Zo["A"].mean(-1)).ravel(), np.log(Zn["A"].mean(-1)).ravel())[0, 1]) if Zo["A"].shape == Zn["A"].shape else float("nan")
        res[p["name"]] = dict(id=p["id"], same_window=same_pos, max_abs_dA=dA, max_abs_dH_mm=dH, corr_logA=rA,
                              sigma_logA_old=float(np.log(Zo["A"].mean(-1)).std()), sigma_logA_new=float(np.log(Zn["A"].mean(-1)).std()))
        log(f"  {p['name']} ↔ {p['id']}：窗口{'相同' if same_pos else '不同'}，|ΔA| 最大 {dA:.2e}，|ΔH| 最大 {dH:.2e} mm，log A 相关 {rA:.5f}，"
            f"σ(log A) {res[p['name']]['sigma_logA_old']:.4f} → {res[p['name']]['sigma_logA_new']:.4f}")
    (LIB/"s0530"/"核对_第一批.json").write_text(json.dumps(res, ensure_ascii=False, indent=1))


CMDS = {"下载": cmd_download, "正射": cmd_ortho, "配准": lambda a: register(), "分离": cmd_separate, "切块": cmd_cut, "图": cmd_overview}


if __name__ == "__main__":
    if len(sys.argv) < 2: print(__doc__); sys.exit(0)
    cmd, args = sys.argv[1], sys.argv[2:]
    cfg = load_cfg()
    if cmd == "库": cmd_catalog(args); sys.exit(0)
    sids = [a for a in args if not a.startswith("--")]
    if not sids or sids == ["全部"]: sids = list(cfg["站点"])
    for sid in sids:
        ST = dict(cfg["站点"][sid], id=sid)
        if cmd == "核对": cmd_check(args); continue
        if cmd == "全部":
            for c in ("下载", "正射", "分离", "切块", "图"):
                if c == "下载" and ST.get("local_glob"): continue
                CMDS[c](args)
        else:
            CMDS[cmd](args)
