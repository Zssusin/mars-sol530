"""
实景 → Godot 数据（venv 里跑）：把 57 导出的引擎无关资产（默认取 封存_v5/导出）转成 Godot 直接读的格式，放到 godot/数据/sol0530/。
  坐标：ENU（x 东、y 北、z 上）→ Godot（x 东、y 上、z 南）：(E, N, U) → (E, U, −N)，行列式 +1，不改手性。
        三角形绕序反过来（Blender 逆时针为正面，Godot 顺时针为正面）。
  地面：15 环 → ring_KK.bin（顶点 float32×3 | 法线 float32×3 | 索引 int32，前面 3 个 int32 头：顶点数、索引数、0）。
        同一份高度另存成 15 层嵌套高度图 heights.bin（给 Godot 的 CDLOD 地面：顶点着色器取高）：头 int32 层数 L、边长 N，
        再 float32 L×N×N。第 k 层格距 c0·2^k、半宽 half0·2^k，纹素 (i, j) ↔ Godot (x, z) = (−half + i·c, −half + j·c)；
        内圈（被细一层覆盖处）用细一层隔点取，和环网格的顶点逐点相同。
  贴图：反照率 / 地类 PNG 原样（reflink）换成 ASCII 名，写好 .import（无损、带 mipmap，回归要和 Cycles 逐像素比）。
        细节高度是 16 位 PNG，Godot 读 PNG 会降成 8 位 → 换成米为单位的 float32 .bin（Image FORMAT_RF）。
  细节：微观取 57 导出；中观按 地面样块表.json 取 71_地面样块.py 切出的真火星样块（浮点反照率细节 A、高度 H）。
        反照率细节（均值 1）存 8 位时除以每块自己的 gain（scene.json detail.*.gain，着色器 meso_gain / micro_gain 乘回去）：
        gain 取全图最大值（向上取到 0.01），一个像素都不截。57 导出的老图块是固定 0.5×（gain 2），原样拷，记 gain 2。
  石块：实测石块（三角化、平直着色用的面法线展开）+ 统计撒石表 → rocks.bin + scene.json 里的索引。
  天空：火星大气.py 今天() 的等距圆柱图（ENU，58 同一约定），每个时刻一张 sky_HHMM.bin（float32 RGB，第 0 行在上）
        + 太阳方向、直射透过率；太阳照度 W/m² 原样给，Godot 那边自己换算。
  相机：对照（与 NASA 照片同位姿同内参）、人眼、高处（同 58 的定义），给 Godot 坐标的位置、前、上和水平视场角。
运行：.venv/bin/python scripts/Godot/61_Godot数据.py [--源 重建|封存_v5] [--中观=样块|旧] [--只天空] [--时刻 13:07 09:00 …（放最后）]
     --只细节 [--中观=旧]：只重写细节图块（meso_* / micro_*）和 scene.json 的 detail 段，其余不动；--中观=旧 = 中观回到 57 导出的老图块
     --只天空：只补算天空（地面、贴图不重写，正在跑的 Godot 不受影响）
     --天气天空 --τ 0.3 1.5 3 5 [--进程 8] [--时刻 …]：天气模块用的几套尘埃光学厚度的天空（sky_t{τ}_HHMM.bin，scene.json 的 sky_tau / beta_ap_tau）
数据：NASA/JPL-Caltech/ASU/MSSS/University of Arizona/USGS。
"""
import json, math, pathlib, shutil, subprocess, sys, time
import numpy as np
from PIL import Image

HERE = pathlib.Path(__file__).resolve().parent
MAP = HERE.parent.parent
sys.path.insert(0, str(HERE.parent/"Blender"))
import 火星大气 as AT

SITE = MAP/"DEM"/"Blender缓存"/"_素材"/"PDS"/"站26_1222"
OUT = MAP/"godot"/"数据"/"sol0530"
LAT = 18.45864728
DECL = math.asin(math.sin(math.radians(25.19))*math.sin(math.radians(286.9)))   # 同 58
E_TOP = 1361/1.40**2
ROVER_YPR = (-107.7939695, -1.871436595, -14.23768937)
M_SB = np.array([[0, 1, 0], [1, 0, 0], [0, 0, -1]], float)
BETA_AP = 0.67/10.8e3
MAST_PARTS = ("head", "bottom", "bottom.001", "bottom.002", "bottom.003", "top", "probe.001",
              "arm", "arm.001", "arm.002", "arm.003", "arm.004", "arm_cable_etc")
TABLE = HERE/"地面样块表.json"                                            # 中观细节取哪个真火星样块（71 的输出）
TEX = {"近": "albedo_near", "中": "albedo_mid", "HiRISE": "albedo_hirise", "CTX": "albedo_ctx",
       "地类_中": "class_mid", "地类_HiRISE": "class_hirise"}


def log(*a): print("[61]", *a, flush=True)


def g3(v):
    """ENU → Godot（可以是 (…, 3) 数组）。"""
    v = np.asarray(v, np.float64)
    return np.stack([v[..., 0], v[..., 2], -v[..., 1]], -1)


def sun_dir(ltst):
    hh, mm = (int(x) for x in ltst.split(":")[:2]); H = math.radians((hh + mm/60 - 12)*15)
    p, d = math.radians(LAT), DECL
    return np.array([-math.cos(d)*math.sin(H), math.cos(p)*math.sin(d) - math.sin(p)*math.cos(d)*math.cos(H),
                     math.sin(p)*math.sin(d) + math.cos(p)*math.cos(d)*math.cos(H)])


def fullday_times():
    """全日天空要补的时刻（本地真太阳时 HH:MM）。按太阳高度取，不按钟点：
    日出侧 / 日落侧各：太阳 10°–17.7° 之间 10 分钟一档，10° 以下每 1° 一档（2° 以下每 0.5°），暮光到 −16°（−3° 以下每 1°–1.5°，再往下 2°）；
    再补 08:00–10:00、16:00–17:00 之间缺的 10 分钟档。老的 40 张不动。"""
    el = lambda m: math.degrees(math.asin(sun_dir(f"{m//60}:{m%60}")[2]))
    fmt = lambda m: f"{m//60:02d}:{m%60:02d}"
    out = set()
    for m in range(480, 600, 10): out.add(m)                                     # 08:00–10:00 的 10 分钟档
    for m in range(960, 1020, 10): out.add(m)                                    # 16:00–17:00
    targets = [9, 8, 7, 6, 5, 4, 3, 2, 1.5, 1, 0.5, 0, -0.5, -1, -1.5, -2, -2.5, -3, -4, -5, -6, -7, -8, -9, -10, -11.5, -13, -14.5, -16]
    mins = list(range(180, 1260))
    es = np.array([el(m) for m in mins])
    for m in range(390, 480, 10): out.add(m)                                     # 日出侧，太阳 17.7° 之前 10 分钟一档（到 10° 为止见下）
    up = [m for m, e in zip(mins, es) if m < 720 and e >= 10.0 and m < 480]; dn = [m for m, e in zip(mins, es) if m > 720 and e >= 10.0 and m > 960]
    out = {m for m in out if not (m < 480 and el(m) < 9.5)}
    for tg in targets:                                                           # 日出侧：m < 720 上升过 tg；日落侧：m > 720 下降过 tg
        for side in (0, 1):
            cand = [(abs(e - tg), m) for m, e in zip(mins, es) if (m < 720) == (side == 0)]
            out.add(min(cand)[1])
    out -= {int(t[:2])*60 + int(t[3:]) for t in OLD_TIMES}
    out = {m for m in out if m % 10 == 0 or m < 480 or m > 1020 or True}
    return [fmt(m) for m in sorted(out)]


def vertex_normals(V, Q):
    """四边形网格的面积加权顶点法线（ENU）。"""
    a, b, c, d = (V[Q[:, i]] for i in range(4))
    fn = np.cross(c - a, d - b)                                          # 四边形对角线叉积 = 2×面积×法线
    N = np.zeros_like(V)
    for i in range(4): np.add.at(N, Q[:, i], fn)
    N /= np.maximum(np.linalg.norm(N, axis=1, keepdims=True), 1e-12)
    return N


def ground(EX):
    z = np.load(EX/"地面网格.npz"); n = int(z["nring"]); info = []
    for k in range(n):
        V = z[f"V{k}"].astype(np.float64); Q = z[f"F{k}"]
        N = vertex_normals(V, Q)
        T = np.concatenate([Q[:, [0, 2, 1]], Q[:, [0, 3, 2]]]).astype(np.int32)   # 反绕序
        with open(OUT/f"ring_{k:02d}.bin", "wb") as f:
            np.array([len(V), T.size, 0], np.int32).tofile(f)
            g3(V).astype(np.float32).tofile(f); g3(N).astype(np.float32).tofile(f); T.tofile(f)
        info.append(dict(file=f"ring_{k:02d}.bin", half=float(np.abs(V[:, :2]).max()), nv=len(V), ni=int(T.size)))
    log(f"地面 {n} 环，共 {sum(i['nv'] for i in info):,} 顶点")
    return info


def import_file(png, srgb):
    """Godot 的 .import：无损、mipmap、不缩小。"""
    return f"""[remap]

importer="texture"
type="CompressedTexture2D"

[deps]

source_file="res://数据/sol0530/{png}"

[params]

compress/mode=0
compress/high_quality=false
compress/lossy_quality=0.7
compress/hdr_compression=1
compress/normal_map=2
compress/channel_pack=0
mipmaps/generate=true
mipmaps/limit=-1
roughness/mode=0
process/fix_alpha_border=false
process/premult_alpha=false
process/normal_map_invert_y=false
process/hdr_as_srgb=false
process/hdr_clamp_exposure=false
process/size_limit=0
detect_3d/compress_to=0
"""


def textures(EX, J):
    out = {}
    for key, name in TEX.items():
        src = EX/J["tex"][key]["file"]; dst = OUT/f"{name}.png"
        dst.unlink(missing_ok=True)
        subprocess.run(["cp", "--reflink=auto", str(src), str(dst)], check=True); dst.chmod(0o644)
        (OUT/f"{name}.png.import").write_text(import_file(dst.name, not key.startswith("地类")))
        out[name] = dict(file=dst.name, half=J["tex"][key]["half"])
    log(f"贴图 {len(out)} 张")
    return out


def albedo_gain(A):
    """反照率细节（均值 1，浮点）存 8 位用的倍率：PNG 存 A/gain，着色器乘 gain。取全图最大值、向上取到 0.01 → 一个像素都不截。
    57 ⑨ 和 71 的细节都夹在 0.3–2.5，所以 gain ≤ 2.5，8 位量化步长最多 0.0098（反照率的 1%）。"""
    return max(math.ceil(float(A.max())*100 - 1e-9)/100, 0.5)


def details(EX, J, meso="样块"):
    """细节图块：微观取 57 导出（8 位 PNG 原样拷，gain 2）；中观 meso="样块" 时按 地面样块表.json 取 71 的样块，"旧" 时同微观取 57 导出。"""
    T = json.loads(TABLE.read_text()) if meso != "旧" else None
    if T:
        PD = MAP/T["样块目录"]; meta = json.loads((PD/"godot"/"样块.json").read_text())
    det = {}
    for key, d in J["detail"].items():
        lv, k = key.split("_"); nm = f"{'micro' if lv == '微观' else 'meso'}_{k}"
        a = OUT/f"{nm}_albedo.png"; a.unlink(missing_ok=True)
        if lv == "中观" and T:
            pid = T["中观"][nm]["样块"]; pid = pid[0] if isinstance(pid, list) else pid   # 以后一类多变体：现在只用第一个
            z = np.load(PD/"切块"/f"{pid}.npz"); A = z["A"].astype(np.float32); h = z["H"].astype(np.float32)
            gain = albedo_gain(A)
            q = (np.clip(A/gain, 0, 1)*255 + 0.5).astype(np.uint8)                # 同 71 export_godot 的取整，gain 2 时逐字节相同
            Image.fromarray(q, "RGB").save(a)
            dec = q.reshape(-1, 3).astype(np.float64).mean(0)/255*gain
            log(f"细节 {nm} ← {pid}：{A.shape[0]}²，gain {gain:.2f}（最大 {A.max():.3f}、99.99% {np.percentile(A, 99.99):.3f}），"
                f"截断像素 {(A > 2.0).any(-1).mean()*100:.3f}% → {(A > gain).any(-1).mean()*100:.3f}%，解码均值 {np.round(dec, 4).tolist()}")
            ent = dict(size=meta[pid]["size"], height_range=meta[pid]["height_range"], gain=gain, 来自=pid)
        else:
            subprocess.run(["cp", "--reflink=auto", str(EX/d["albedo"]), str(a)], check=True)
            h = np.asarray(Image.open(EX/d["height"])).astype(np.float64)/65535.0      # Blender 读 16 位 Non-Color：0–1
            h = ((h - 0.5)*2*d["height_range"]).astype(np.float32)                   # → 米
            ent = dict(size=d["size"], height_range=d["height_range"], gain=2.0)
        a.chmod(0o644)
        (OUT/f"{nm}_albedo.png.import").write_text(import_file(a.name, False))
        with open(OUT/f"{nm}_height.bin", "wb") as f:
            np.array(h.shape[::-1], np.int32).tofile(f); h.tofile(f)
        det[nm] = dict(albedo=a.name, height=f"{nm}_height.bin") | ent
    log(f"细节 {len(det)} 组（中观：{'57 导出（旧）' if not T else '地面样块表.json'}）")
    return det


def rocks(EX):
    z = np.load(EX/"石块.npz"); inst = json.loads(str(z["inst"])); cols = z["colors"]; S = z["scatter"]
    pos, nrm, meshes = [], [], []
    off = 0
    for i, r in enumerate(inst):
        V, Ff = z[f"V{i}"], z[f"F{i}"]
        tris, j = [], 0
        while j < len(Ff):
            poly = Ff[j + 1:j + 1 + Ff[j]]; j += Ff[j] + 1
            tris += [(poly[0], poly[t], poly[t + 1]) for t in range(1, len(poly) - 1)]   # 扇形三角化
        if not tris: continue
        T = np.array(tris)
        Vn = V.copy(); Vn[:, :2] /= r["D"]; Vn[:, 2] /= max(r["H"], 0.02)              # 单位石块（同 58 的库）
        P = Vn[T]                                                                      # (nt, 3, 3) 展开：平直着色
        fn = np.cross(P[:, 1] - P[:, 0], P[:, 2] - P[:, 0])                            # 单位石块的面法线（缩放后在着色器里重算）
        fn /= np.maximum(np.linalg.norm(fn, axis=1, keepdims=True), 1e-12)
        P = P[:, [0, 2, 1]]                                                            # 反绕序
        pos.append(g3(P.reshape(-1, 3))); nrm.append(g3(np.repeat(fn, 3, 0)))
        meshes.append(dict(i=i, off=off, n=len(T)*3, pos=g3(r["pos"]).tolist(), D=r["D"], H=max(r["H"], 0.02),
                           color=cols[i].tolist()))
        off += len(T)*3
    pos = np.concatenate(pos).astype(np.float32); nrm = np.concatenate(nrm).astype(np.float32)
    # 统计石块：x y z D yaw seed aspect；埋入四分之一（同 58）
    P = S[:, :3].astype(np.float64).copy(); P[:, 2] -= 0.25*S[:, 3]*S[:, 6]
    sc = np.concatenate([g3(P), S[:, 3:7].astype(np.float64)], 1).astype(np.float32)
    with open(OUT/"rocks.bin", "wb") as f:
        np.array([len(pos), len(sc), 0], np.int32).tofile(f); pos.tofile(f); nrm.tofile(f); sc.tofile(f)
    base = np.median(cols, 0).tolist() if len(cols) else [0.25, 0.17, 0.12]
    log(f"石块：实测 {len(meshes)} 块、统计 {len(sc):,} 块")
    return dict(file="rocks.bin", meshes=meshes, n_scatter=len(sc), base=base)


OLD_TIMES = ("08:00 09:00 10:00 10:10 10:20 10:30 10:40 10:50 11:00 11:10 11:20 11:30 11:40 11:50 12:00 12:10 12:20 12:30 12:40 12:50 "
             "13:07 13:10 13:20 13:30 13:40 13:50 14:00 14:10 14:20 14:30 14:40 14:50 15:00 15:10 15:20 15:30 15:40 15:50 16:00 17:00").split()
# 老的 40 张（08:00–17:00）按老模型算、文件不动（照片回归的基线）。其余时刻（低太阳、暮光、补的 10 分钟档）用新模型：
# 日落后星球阴影按站点高度的地面球算、Ψ 表 128 档、尘埃相函数逐通道（数字与来源见 docs/全日天空.md §3）。
NEW_PHYS = dict(shadow_h=-2.52, **json.loads((HERE/"尘埃相函数.json").read_text())["今天参数"])
PHASE_BLEND_EL = None                                                    # --相函数过渡=a,b（太阳高度°）
FORCE_NEW = False                                                        # --新物理：OLD_TIMES 里的时刻也用新模型（全日天空 2：比较 13:07 在新相函数下的样子）
K_FLOOR_EL = 5.5                                                         # 天气变体的多次散射定标用平面平行蒙特卡洛，太阳低于这个高度就不可靠 → 沿用 17:00（5.5°）的 k
K_REF = {}                                                               # τ → 17:00 的 k_ms（main 从 scene.json 读）


def skies(times, tau=None):
    """tau=None：今天（τ 0.67，sky_HHMM.bin）；给 tau：天气模块的另一套尘埃光学厚度（sky_t{τ}_HHMM.bin），其余参数同今天()。
    OLD_TIMES 里的时刻用老模型，其余用新模型（见上）。"""
    out = {}
    for new in (False, True):
        ts = [t for t in times if ((t not in OLD_TIMES) or FORCE_NEW) == new]
        if ts: out |= _skies(ts, tau, new)
    return dict(sorted(out.items(), key=lambda kv: tuple(int(v) for v in kv[0].split(":"))))


def _skies(times, tau, new):
    o = np.array([0, 0, AT.R - 2.52]); out = {}
    phys_full = NEW_PHYS if new else {}; nmu = 128 if new else 32
    # 相函数过渡（--相函数过渡=a,b）：太阳高度 ≥ b° 用老的双 HG（和之前逐位相同），≤ a° 全用 Mie 全套（相函数 + ω0），之间两套天空图 smoothstep 混合
    blend = bool(new and PHASE_BLEND_EL and "phase_table" in phys_full)
    phys = {k: v for k, v in phys_full.items() if k not in ("phase_table", "ssa")} if blend else phys_full
    def _use(ph): AT.今天(**(ph if tau is None else dict(ph, tau=tau)))
    atmM = None
    if tau is not None:                                                  # 多次散射定标（godot/天气/天空定标.py）：先算 τ 0.67 各时刻的漫射照度作锚
        sys.path.insert(0, str(MAP/"godot"/"天气")); import 天空定标 as DB
        AT.今天(tau=DB.TAU0, **phys); a0 = AT.Atmosphere(psi_nmu=nmu); E0 = {t: DB.e_sky(a0, o, sun_dir(t)) for t in times}; del a0
    if tau is None: AT.今天(**phys)
    else: AT.今天(tau=tau, **phys)
    atm = AT.Atmosphere(psi_nmu=nmu)
    psi0 = atm.psi.copy()
    for t in times:
        t0 = time.time(); s = sun_dir(t); k = np.ones(3)
        if tau is not None:
            if math.degrees(math.asin(s[2])) < K_FLOOR_EL: k = np.array(K_REF[tau_key(tau)])
            else: k, _ = DB.calibrate(atm, E0[t], o, s, tau)
            atm.psi = (psi0*k).astype(np.float32)
        L, E_sun_h, E_sky = AT.env_map(atm, o, s, w=1024, h=512, ground_albedo=0.22)
        atm.psi = psi0
        if blend:
            x = min(max((PHASE_BLEND_EL[1] - math.degrees(math.asin(s[2])))/(PHASE_BLEND_EL[1] - PHASE_BLEND_EL[0]), 0), 1); b = x*x*(3 - 2*x)
            if b > 0:
                _use(phys_full)
                if atmM is None: atmM = AT.Atmosphere(psi_nmu=nmu); psiM0 = atmM.psi.copy()
                atmM.psi = (psiM0*k).astype(np.float32); LM, _, EskyM = AT.env_map(atmM, o, s, w=1024, h=512, ground_albedo=0.22); atmM.psi = psiM0
                L = (1 - b)*L + b*LM; E_sky = (1 - b)*E_sky + b*EskyM; _use(phys)
        T = atm.transmittance(np.array([-2.52]), np.array([s[2]]))[0]
        nm = f"sky_{t.replace(':', '')}.bin" if tau is None else f"sky_t{tau_key(tau)}_{t.replace(':', '')}.bin"
        with open(OUT/nm, "wb") as f:
            np.array([L.shape[1], L.shape[0]], np.int32).tofile(f)
            np.ascontiguousarray(L[::-1]).astype(np.float32).tofile(f)      # env_map 第 0 行在下 → 翻成第 0 行在上
        out[t] = dict(file=nm, sun_enu=s.tolist(), sun=g3(s).tolist(), T=np.asarray(T).tolist(),
                      elev=math.degrees(math.asin(s[2])), E_sun_h=float(np.mean(E_sun_h))*E_TOP, E_sky=float(np.mean(E_sky))*E_TOP)
        if tau is not None: out[t] |= dict(k_ms=np.round(k, 4).tolist(), E_sky_rgb=(np.asarray(E_sky)*E_TOP).tolist())
        log(f"天空 {'' if tau is None else 'τ ' + tau_key(tau) + ' '}{t}：太阳高 {out[t]['elev']:.1f}°，{time.time() - t0:.0f} s")
    return out


def tau_key(tau):
    """0.3 → "0.3"，3.0 → "3"：文件名和 scene.json 的键。"""
    return f"{float(tau):g}"


def _sky_job(job):
    tau, times = job
    return tau, skies(times, tau)


def weather_skies(S, taus, times, procs=8):
    """天气模块（godot/天气/）：几套尘埃光学厚度 τ 的天空，写进 scene.json 的 sky_tau[τ][时刻] 与 beta_ap_tau[τ]（近地消光 τ/H，
    H = 今天() 的尘埃标高 10.8 km，同 BETA_AP）。每个进程一套 τ 的一段时刻（各建一次查找表），numpy 逐元素运算本来就单线程。"""
    import multiprocessing as mp
    per = max(1, -(-len(taus)*len(times)//procs))
    jobs = [(float(tau), times[i:i + per]) for tau in taus for i in range(0, len(times), per)]
    with mp.get_context("fork").Pool(min(procs, len(jobs))) as pool:
        res = pool.map(_sky_job, jobs)
    S.setdefault("sky_tau", {}); S.setdefault("beta_ap_tau", {})
    for tau, d in res:
        k = tau_key(tau)
        S["sky_tau"][k] = dict(sorted((S["sky_tau"].get(k, {}) | d).items()))
        S["beta_ap_tau"][k] = float(tau)/(AT.HM*1e3)
    return S


def geo(EX):
    """地貌印章与实时撒石的 CPU/GPU 共用数据：HiRISE 地类 25 cm → 1 m（4×4 平均，RGBA8 原始字节，Godot 同时当贴图和 CPU 表）+ 各地类 Golombek k。"""
    from PIL import Image
    Image.MAX_IMAGE_PIXELS = None
    A = np.asarray(Image.open(EX/"地类_HiRISE.png").convert("RGBA")).astype(np.float32)
    n = A.shape[0]//4; A = A[:n*4, :n*4].reshape(n, 4, n, 4, 4).mean((1, 3))
    A = np.clip(np.round(A), 0, 255).astype(np.uint8)
    A.tofile(OUT/"geo_class.bin")
    k = np.load(EX/"石块.npz")["k_cls"].astype(float).tolist()
    log(f"地貌：地类 {n}² @ {2000.0/n:.2f} m，k = {np.round(k, 4).tolist()}")
    return dict(file="geo_class.bin", N=n, half=1000.0, k_cls=k)


def heights(EX):
    z = np.load(EX/"地面网格.npz"); n = int(z["nring"]); c0, h0 = 0.02, 6.0
    N = int(round(2*h0/c0)) + 1; H = np.full((n, N, N), np.nan, np.float32)
    for k in range(n):
        c, h = c0*2**k, h0*2**k; V = z[f"V{k}"]
        i = np.round((V[:, 0] + h)/c).astype(int); j = np.round((h - V[:, 1])/c).astype(int)   # j：Godot z = −N
        assert np.abs(V[:, 0] + h - i*c).max() < 1e-3*c and np.abs(h - V[:, 1] - j*c).max() < 1e-3*c, f"第 {k} 环不在格点上"
        H[k, j, i] = V[:, 2]
        if k:                                                              # 内圈：细一层隔点取
            a = (N - 1)//4; H[k, a:a + (N - 1)//2 + 1, a:a + (N - 1)//2 + 1] = H[k - 1, ::2, ::2]
        assert not np.isnan(H[k]).any(), f"第 {k} 层有空"
    with open(OUT/"heights.bin", "wb") as f:
        np.array([n, N], np.int32).tofile(f); H.tofile(f)
    log(f"高度层 {n}×{N}²（{H.nbytes/1e6:.0f} MB）")
    return dict(file="heights.bin", L=n, N=N, c0=c0, half0=h0)


def ground_z(EX, x, y):
    z = np.load(EX/"地面网格.npz")
    for k in range(int(z["nring"])):
        V = z[f"V{k}"]
        if max(abs(x), abs(y)) < 0.95*np.abs(V[:, :2]).max():
            d = np.hypot(V[:, 0] - x, V[:, 1] - y); i = np.argsort(d)[:4]; w = 1/np.maximum(d[i], 1e-6)
            return float((V[i, 2]*w).sum()/w.sum())
    return 0.0


def cameras(EX, J):
    def cam(name, C, fwd, up, hfov, W, H):
        f = np.asarray(fwd, float); f /= np.linalg.norm(f)
        r = np.cross(f, up); r /= np.linalg.norm(r); u = np.cross(r, f)
        return dict(name=name, pos=g3(C).tolist(), fwd=g3(f).tolist(), up=g3(u).tolist(), hfov=hfov, W=W, H=H,
                    pixel_angle=math.radians(hfov)/W)
    out = []
    for ref in J["refs"]:
        out.append(cam(f"对照_{ref['file'][:4]}{ref['file'][18:27]}", ref["C"], ref["fwd"], -np.array(ref["down"]),
                       math.degrees(2*math.atan(ref["W"]/2/ref["f"])), ref["W"], ref["H"]) | dict(ref=ref["png"], ltst=ref["ltst"]))
    mast = np.array(J["mast"]); az = math.radians(ROVER_YPR[0] % 360)
    hd = np.array([math.sin(az), math.cos(az), 0])
    eye = mast - 6*hd; eye[2] = ground_z(EX, *eye[:2]) + 1.7
    out.append(cam("人眼", eye, hd + np.array([0, 0, -0.10]), np.array([0, 0, 1.]), 60, 1920, 1080))
    hi = mast + np.array([18, 25, 0]); hi[2] = ground_z(EX, *hi[:2]) + 30
    out.append(cam("高处", hi, mast - hi + np.array([0, 0, -2]), np.array([0, 0, 1.]), 65, 1920, 1080))
    side = np.array([hd[1], -hd[0], 0])                                    # 车头右手
    gp = mast + 4.0*hd + 2.0*side; gp[2] = ground_z(EX, *gp[:2])           # 车前右 4 m 的空地
    ey = gp - 1.0*hd; ey[2] = gp[2] + 1.2                                  # 离地 1.2 m、往前下看 50°：看毫米级细节
    out.append(cam("近地", ey, gp - ey, np.array([0, 0, 1.]), 60, 1920, 1080))
    return out


def rover(J):
    """模型（glTF：Y 上）→ Godot 的位姿。58 在 Blender 里：Blender 模型坐标 b = (gx, −gz, gy)，ENU = Rm·b + t，
    t 让模型 NavCams 包围盒中心落到桅杆头。这里给 Rm（ENU←Blender 模型）与桅杆头，Godot 端量 NavCams 再求 t。"""
    A = np.array([[0, -1, 0], [-1, 0, 0], [0, 0, -1]], float)
    y, p, r = (math.radians(v) for v in ROVER_YPR)
    Rz = np.array([[math.cos(y), -math.sin(y), 0], [math.sin(y), math.cos(y), 0], [0, 0, 1]])
    Ry = np.array([[math.cos(p), 0, math.sin(p)], [0, 1, 0], [-math.sin(p), 0, math.cos(p)]])
    Rx = np.array([[1, 0, 0], [0, math.cos(r), -math.sin(r)], [0, math.sin(r), math.cos(r)]])
    Rm = M_SB @ Rz @ Ry @ Rx @ A
    G = np.array([[1, 0, 0], [0, 0, 1], [0, -1, 0]], float)                # ENU → Godot
    B = np.array([[1, 0, 0], [0, 0, -1], [0, 1, 0]], float)                # glTF/Godot 模型 → Blender 模型
    R = G @ Rm @ B                                                         # 模型（Godot 坐标）→ 世界（Godot 坐标）
    return dict(file="rover.glb", basis_cols=R.T.tolist(), mast=g3(J["mast"]).tolist(),
                hide_in_ref=[n.replace(".", "_") for n in MAST_PARTS])


def main(a):
    global FORCE_NEW, PHASE_BLEND_EL
    FORCE_NEW = "--新物理" in a
    for x in a:                                                          # --相函数=<键>：尘埃相函数.json 里该键的参数并进新模型（如 Mie：phase_table 指向 .npz，相对 scripts/Godot/）
        if x.startswith("--相函数过渡="): PHASE_BLEND_EL = [float(v) for v in x.split("=", 1)[1].split(",")]
        if x.startswith("--相函数="):
            kw = dict(json.loads((HERE/"尘埃相函数.json").read_text())[x.split("=", 1)[1]]); kw.pop("来源", None); kw.pop("说明", None)
            if "phase_table" in kw: kw["phase_table"] = str(HERE/kw["phase_table"])
            NEW_PHYS.update(kw); log(f"新模型参数：{NEW_PHYS}")
    src = a[a.index("--源") + 1] if "--源" in a else "封存_v5"
    EX = SITE/("重建" if src == "重建" else src)/"导出"
    times = [x for x in a[a.index("--时刻") + 1:] if not x.startswith("--")] if "--时刻" in a else ["13:07"]
    meso = next((x.split("=", 1)[1] for x in a if x.startswith("--中观=")), a[a.index("--中观") + 1] if "--中观" in a else "样块")
    assert meso in ("样块", "旧"), f"--中观 只能是 样块 或 旧：{meso}"
    OUT.mkdir(parents=True, exist_ok=True)
    J = json.loads((EX/"场景.json").read_text())
    if "--列时刻" in a:                                                   # 全日天空要补的时刻（见 fullday_times），一行打印，可直接接在 --时刻 后面
        ts = fullday_times(); print(" ".join(ts)); log(f"{len(ts)} 个时刻"); return
    if "--只细节" in a:                                                   # 只重写细节图块和 scene.json 的 detail 段（键序不变，git diff 最小）
        S = json.loads((OUT/"scene.json").read_text()); EX = MAP/S["source"]
        det = details(EX, json.loads((EX/"场景.json").read_text()), meso)
        S["detail"] = {k: det[k] for k in S.get("detail", {}) if k in det} | det
        (OUT/"scene.json").write_text(json.dumps(S, ensure_ascii=False, indent=1)); return
    if "--只高度" in a:                                                   # 只补高度层（其余不动）
        S = json.loads((OUT/"scene.json").read_text()); EX = MAP/S["source"]
        S["heights"] = heights(EX); (OUT/"scene.json").write_text(json.dumps(S, ensure_ascii=False, indent=1)); return
    if "--只地貌" in a:
        S = json.loads((OUT/"scene.json").read_text()); EX = MAP/S["source"]
        S["geo"] = geo(EX); (OUT/"scene.json").write_text(json.dumps(S, ensure_ascii=False, indent=1)); return
    if "--天气天空" in a:                                                # 天气模块：--天气天空 --τ 0.3 1.5 3 5 [--进程 8] [--时刻 …]（默认＝sky 的全部时刻）
        S = json.loads((OUT/"scene.json").read_text())
        for k, d in S.get("sky_tau", {}).items(): K_REF[k] = d["17:00"]["k_ms"]
        taus = []
        for x in a[a.index("--τ") + 1:]:
            if x.startswith("--"): break
            taus.append(float(x))
        tt = times if "--时刻" in a else sorted(S["sky"], key=lambda t: tuple(int(v) for v in t.split(":")))
        procs = int(a[a.index("--进程") + 1]) if "--进程" in a else 8
        t0 = time.time(); S = weather_skies(S, taus, tt, procs)
        (OUT/"scene.json").write_text(json.dumps(S, ensure_ascii=False, indent=1))
        log(f"天气天空 τ {[tau_key(t) for t in taus]} × {len(tt)} 个时刻，{time.time() - t0:.0f} s"); return
    if "--只天空" in a:
        S = json.loads((OUT/"scene.json").read_text())
        S["sky"] = S["sky"] | skies([t for t in times if t not in S["sky"] or "--重算天空" in a])
        (OUT/"scene.json").write_text(json.dumps(S, ensure_ascii=False, indent=1)); log(f"天空 {sorted(S['sky'])}"); return
    S = dict(source=str(EX.relative_to(MAP)), E_TOP=E_TOP, beta_ap=BETA_AP, base_color=J["tex"]["底色"],
             data_res={TEX.get(k, k): v for k, v in J["data_res"].items()}, classes=J["classes"])
    S["ground"] = ground(EX)
    S["heights"] = heights(EX)
    S["tex"] = textures(EX, J)
    S["detail"] = details(EX, J, meso)
    S["rocks"] = rocks(EX)
    S["geo"] = geo(EX)
    S["cameras"] = cameras(EX, J)
    S["rover"] = rover(J)
    rv = OUT/"rover.glb"
    if not rv.exists(): shutil.copy(SITE/"毅力号.glb", rv)
    for p in EX.glob("对照_*.png"): shutil.copyfile(p, OUT/("ref_" + p.name.split("_", 1)[1]))   # 只拷内容：封存是只读的
    prev = json.loads((OUT/"scene.json").read_text()) if (OUT/"scene.json").exists() else {}
    old = prev.get("sky", {})
    if "near_fine" in prev: S["near_fine"] = prev["near_fine"]                 # 近景细化（72_近景细化.py 安装）：不是从 57 导出来的，原样保留
    S["sky"] = old | skies([t for t in times if t not in old or "--重算天空" in a])
    (OUT/"scene.json").write_text(json.dumps(S, ensure_ascii=False, indent=1))
    log(f"→ {OUT}")


if __name__ == "__main__":
    main(sys.argv[1:])
