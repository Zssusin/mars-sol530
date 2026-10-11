#!/usr/bin/env python3
"""
73 材质规则：地面材质阶段 1 的离线原型（numpy）。方案见 docs/地面材质/方案.md、设计_技术与架构.md §4.3，报告见 docs/地面材质/阶段1.md。
从游戏用的同一份地形高度（godot/数据/sol0530/heights.bin）算派生场，按 scripts/Godot/地面材质表.json 的规则给每个纹素算材质权重，
烘成控制图（每纹素 32 位：前 3 种材质号 + 权重 + 积尘），再拿真值核对；另把样块导出成纹理数组（DDS：BC7 / BC5 / R16）。

子命令（fedora 上 .venv/bin/python scripts/Godot/73_材质规则.py <子命令>）：
  场      派生场：近（±50 m、4 cm，2500²）、远（±1 km、1 m，2000²，和 geo_class.bin 同网格）。
          坡度、曲率、局部相对高程（TPI，多尺度）、小尺度粗糙度、Winstral Sx 背风遮蔽（盛行风由沙纹走向反推）、汇流累积（D8，只在远图）、
          数据分辨率 r(x)、地类先验 W(x)（可选）。写 资料/地面材质/材质规则/场_近.npz、场_远.npz。约 1–2 分钟（Sx 用显卡）。
  烘焙    按材质表的规则算权重 → 取前 3 → 量化 → godot/数据/sol0530/mat_ctrl_4cm.bin、mat_ctrl_1m.bin（int32 宽高 + RGBA8）。
          --配置=几何+地类+反照率（默认取材质表 规则.默认配置）：开关用 + 连。程序化地形没有 HiRISE 地类时就是 "几何"（或 "几何+反照率"）。
          另烘中观位移门 mat_gate_4cm.bin（int32 宽高 + R8，同近图网格）：片元第 1 步的反照率数据分辨率 r → g = clamp(log2(2r/4 cm)/log2(12.5))，
          GPU 顶点位移和 CPU h_cpu 用同一张（阶段1.md §9.3）。只烘门：--只门。
  验证    真值核对：71 的工作区分类（2 mm，暗沙 / 碎片 / 岩板）、class_mid（4 cm）、HiRISE 地类（1 m）；三种配置各算混淆矩阵、
          总体一致率、κ、每类 IoU；近景反照率按预测分组的均值；叠图写到 资料/地面材质/材质规则/验证/，小图拷 docs/地面材质/图/阶段1_规则_*.jpg。
  导出    纹理数组：样块（地面样块库.json 有就按库，没有就按第一批 样块.json）→ 每层 512²：
          反照率细节 RGB（÷gain）+ A 混合高度 → BC7；高度梯度（导数图，surface gradient 用）→ BC5；中观物理高度 → R16。
          mip 链在这里算好，压缩交给编辑器版 Godot 无头跑（cvtt 出 BC7、etcpak 出 BC5），拼成 DX10 头的 DDS 数组，
          写到 godot/数据/sol0530/材质/（带 .gdignore，免得编辑器把 DDS 当普通贴图导入）；清单 mat.json。
  加载测  Godot 无头测：DDS 数组 load()、自己读 DDS 拼数组、运行时 Image.compress 三种方式的加载时间。
  全部    场 → 烘焙 → 验证 → 导出。

坐标：Godot（x 东、z 南）。图的第 0 行在北（z 最小），纹素 (i, j) 中心 = (−half + (i+½)cs, −half + (j+½)cs)，同 geo_class.bin。
数据：NASA/JPL-Caltech/ASU/MSSS/University of Arizona（PDS：Mars 2020 Navcam、Mastcam-Z；MRO HiRISE）。
"""
import json, math, os, pathlib, subprocess, sys, time
import numpy as np

HERE = pathlib.Path(__file__).resolve().parent


def find_map():
    for p in (HERE, *HERE.parents):
        if (p/"godot").is_dir() and (p/"scripts").is_dir():
            return p
    raise SystemExit("找不到 地图/ 根目录")


MAP = find_map()
GD = MAP/"godot"/"数据"/"sol0530"
WORK = MAP/"资料"/"地面材质"/"材质规则"
TABLE = pathlib.Path(os.environ.get("MAT_TABLE") or HERE/"地面材质表.json")   # MAT_TABLE：换一份材质表（消融用）
LIB = HERE/"地面样块库.json"                                   # 素材库扩充（并行工作）出的目录；没有时退回第一批
BATCH1 = MAP/"资料"/"地面材质"/"样块"
FIG = MAP/"docs"/"地面材质"/"图"
CLASSES = ["沙", "砾石风化层", "基岩", "暗色岩块"]
TAG = os.environ.get("MAT_TAG", "")                           # MAT_TAG=2：控制图 / 材质数组 / 清单都加后缀（mat_ctrl_1m2.bin、材质2/、mat2.json），不碰现行文件（中景丰富度，81 用）
GRIDS = {"近": dict(half=50.0, cs=0.04, file=f"mat_ctrl_4cm{TAG}.bin"), "远": dict(half=1000.0, cs=1.0, file=f"mat_ctrl_1m{TAG}.bin")}
_t0 = time.time()


def log(*a):
    msg = " ".join(str(x) for x in a)
    print(f"[73 {time.time() - _t0:6.1f}s] {msg}", flush=True)
    WORK.mkdir(parents=True, exist_ok=True)
    with open(WORK/"日志.txt", "a") as f: f.write(time.strftime("%m-%d %H:%M:%S ") + msg + "\n")


def table():
    return json.loads(TABLE.read_text())


# ———————————————————— 地形高度（和 Godot 的 hl_height 同一份数据、同一选层）
class Heights:
    def __init__(self):
        b = (GD/"heights.bin").read_bytes()
        self.L, self.N = (int(v) for v in np.frombuffer(b[:8], np.int32))
        self.H = np.frombuffer(b[8:], np.float32).reshape(self.L, self.N, self.N)
        S = json.loads((GD/"scene.json").read_text())["heights"]
        self.c0, self.h0 = S["c0"], S["half0"]

    def sample(self, x, z):
        """Godot (x, z) → 高（米，ENU 的 U）。取包含该点的最细一层（外缘 2% 不用），双线性。"""
        from scipy.ndimage import map_coordinates
        out = np.full(x.shape, np.nan, np.float32); e = np.maximum(np.abs(x), np.abs(z))
        todo = np.ones(x.shape, bool)
        for k in range(self.L):
            c, hf = self.c0*2**k, self.h0*2**k
            m = todo & (e < hf*0.98)
            if not m.any(): continue
            out[m] = map_coordinates(self.H[k], [(z[m] + hf)/c, (x[m] + hf)/c], order=1, mode="nearest")
            todo &= ~m
        return out

    def cell(self, e):
        """这里用的那一层的格距（米）。"""
        k = np.maximum(0, np.ceil(np.log2(np.maximum(e, 1e-6)/(self.h0*0.98))))
        return self.c0*2**k


def grid_xz(g):
    n = int(round(2*g["half"]/g["cs"]))
    c = -g["half"] + (np.arange(n) + 0.5)*g["cs"]
    return np.meshgrid(c, c)                                    # x[j, i]、z[j, i]：第 0 行 z 最小 = 北


def data_res(e, hts):
    """高程数据的有效分辨率 r(x)（米）：立体噪声主导的尺度不算分辨得出（地形生成器设计.md §2.8：近层 6 m 外的 2 cm、
    中层 15 m 外 0.3 m 以下是噪声）→ Navcam 近层 2 cm（≤ 6 m）、4 cm（6–10 m）、中层 0.3 m（10–50 m）；HiRISE DTM 只可信到约 3 m 波长
    → 1.5 m（§2.1）。再和该处所用高度层的格距取大。程序化地形没有这一项，r = 网格格距。"""
    r = np.where(e < 6, 0.02, np.where(e < 10, 0.04, np.where(e < 50, 0.3, 1.5)))
    return np.maximum(r, hts.cell(e)).astype(np.float32)


# ———————————————————— 派生场
def gauss(a, s_cells):
    from scipy.ndimage import gaussian_filter
    return gaussian_filter(a, s_cells, mode="nearest") if s_cells > 0.3 else a


def f_slope(h, cs, s):
    """坡度（度），先平滑到尺度 s（米）。"""
    hs = gauss(h, s/cs)
    gz, gx = np.gradient(hs, cs)
    return np.degrees(np.arctan(np.hypot(gx, gz))).astype(np.float32)


def f_tpi(h, cs, r):
    """局部相对高程（米）：减去半径约 r 的高斯均值。正 = 比周围高。"""
    return (h - gauss(h, r/cs)).astype(np.float32)


def f_curv(h, cs, s):
    """曲率（1/m）：−∇²(G_s * h)。正 = 凸。"""
    from scipy.ndimage import gaussian_laplace
    return (-gaussian_laplace(h.astype(np.float64), s/cs, mode="nearest")/cs**2).astype(np.float32)


def f_rough(h, cs, s, w):
    """小尺度粗糙度（米）：高通（去掉 s 以上）后在 w 窗里的 RMS。碎片 / 砾石面粗、沙面平。"""
    from scipy.ndimage import uniform_filter
    hp = h - gauss(h, s/cs)
    return np.sqrt(uniform_filter(hp.astype(np.float64)**2, max(int(round(w/cs)), 1), mode="nearest")).astype(np.float32)


def f_sx(h, cs, dmax, az_from, sector=30.0, nray=5, nstep=24, dmin=None):
    """Winstral 等 2002 的 Sx（度）：沿上风方向 dmax 内地形的最大仰角，±sector/2 内 nray 条射线取平均。
    正 = 背风遮蔽（上风有更高的地形挡着）、负 = 迎风暴露。az_from：风的来向（自北顺时针，度）。用显卡（torch grid_sample）。"""
    import torch
    dev = "cuda" if torch.cuda.is_available() else "cpu"
    H = torch.from_numpy(np.ascontiguousarray(h, np.float32)).to(dev)[None, None]
    ny, nx = h.shape
    jj, ii = torch.meshgrid(torch.arange(ny, device=dev, dtype=torch.float32), torch.arange(nx, device=dev, dtype=torch.float32), indexing="ij")
    dmin = dmin or cs
    ds = np.geomspace(dmin, dmax, nstep)
    acc = torch.zeros((ny, nx), device=dev)
    for a in np.linspace(az_from - sector/2, az_from + sector/2, nray):
        ux, uz = math.sin(math.radians(a)), -math.cos(math.radians(a))    # 指向来风方向；Godot z 朝南 = −北
        best = torch.full((ny, nx), -1e9, device=dev)
        for d in ds:
            gi = (ii + ux*d/cs)/(nx - 1)*2 - 1; gj = (jj + uz*d/cs)/(ny - 1)*2 - 1
            hs = torch.nn.functional.grid_sample(H, torch.stack([gi, gj], -1)[None], mode="bilinear", padding_mode="border", align_corners=True)[0, 0]
            best = torch.maximum(best, torch.atan((hs - H[0, 0])/d))
        acc += best
    return (torch.rad2deg(acc/nray)).cpu().numpy().astype(np.float32)


def f_flow(h, cs):
    """D8 汇流累积（m²，含自身），不填洼：洼地就是汇点（火星今天没有径流，这一项只当"低洼 / 古河道底"指示，权重小）。"""
    ny, nx = h.shape; n = ny*nx
    hp = np.pad(h.astype(np.float64), 1, mode="edge")
    best = np.zeros((ny, nx)); tgt = np.arange(n).reshape(ny, nx)
    J, I = np.mgrid[0:ny, 0:nx]
    for dj, di in ((-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)):
        nb = hp[1 + dj:1 + dj + ny, 1 + di:1 + di + nx]
        s = (h - nb)/(cs*math.hypot(dj, di))
        m = s > best
        best[m] = s[m]; tgt[m] = (np.clip(J + dj, 0, ny - 1)*nx + np.clip(I + di, 0, nx - 1))[m]
    order = np.argsort(-h.ravel(), kind="stable")
    acc = np.full(n, cs*cs); t = tgt.ravel()
    for k in order:                                             # 从高到低把面积推给下游（下游一定更低，所以顺序正确）
        d = t[k]
        if d != k: acc[d] += acc[k]
    return acc.reshape(ny, nx).astype(np.float32)


def class_prior(name, x, z):
    """地类先验 W（RGBA = 沙、砾石风化层、基岩、暗色岩块，0..1）和可信度：同 地形.gdshader 第 2 步。近：class_mid（4 cm）往外渐变到 HiRISE；远：geo_class（1 m）。"""
    from PIL import Image
    from scipy.ndimage import map_coordinates
    Image.MAX_IMAGE_PIXELS = None

    def samp(img, half):
        n = img.shape[0]; cs = 2*half/n
        u = (x + half)/cs - 0.5; v = (z + half)/cs - 0.5           # 第 0 行在北（z 最小）
        return np.stack([map_coordinates(img[..., c].astype(np.float32)/255, [v, u], order=1, mode="nearest") for c in range(4)], -1)

    e = np.maximum(np.abs(x), np.abs(z))
    reg = lambda h, f: np.clip((h*0.97 - e)/(h*f), 0, 1)
    geo = np.fromfile(GD/"geo_class.bin", np.uint8).reshape(2000, 2000, 4)
    kh = samp(geo, 1000.0)
    W = kh*reg(1000.0, 0.08)[..., None] + np.array([0.35, 0.35, 0.2, 0.1])*(1 - reg(1000.0, 0.08))[..., None]
    wm = np.zeros(x.shape, np.float32)
    if name == "近":
        km = samp(np.asarray(Image.open(GD/"class_mid.png").convert("RGBA")), 50.0)
        wm = reg(50.0, 0.15)*np.clip(km.sum(-1)*2, 0, 1)
        W = W*(1 - wm[..., None]) + km*wm[..., None]
    return W.astype(np.float32), wm.astype(np.float32)


def lum_residual(img_rgba, half, x, z, trend, gamma=2.2):
    """贴图（第 0 行在北）在 (x, z) 处的 log 亮度减 trend（米）尺度的趋势；alpha < 0.5 或出界 = NaN。"""
    from scipy.ndimage import map_coordinates
    a = img_rgba.astype(np.float32)/255; n = a.shape[0]; cs = 2*half/n
    uv = [(z + half)/cs - 0.5, (x + half)/cs - 0.5]
    lum = sum(map_coordinates(a[..., c]**gamma, uv, order=1, mode="nearest")*w for c, w in enumerate((0.2126, 0.7152, 0.0722)))
    al = map_coordinates(a[..., 3], uv, order=1, mode="nearest") if a.shape[-1] == 4 else np.ones_like(lum)
    ok = (np.abs(x) < half*0.97) & (np.abs(z) < half*0.97) & (al > 0.5) & (lum > 1e-4)
    ly = np.where(ok, np.log(np.maximum(lum, 1e-4)), 0)
    gcs = abs(x[0, 1] - x[0, 0])
    wt = gauss(ok.astype(np.float32), trend/gcs); tr = gauss(ly, trend/gcs)/np.maximum(wt, 1e-3)
    return np.where(ok, ly - tr, np.nan).astype(np.float32)


def albedo_field(name, x, z):
    """反照率先验用的量：log 亮度减趋势（近图减 1.5 m、远图减 30 m）。近图用 Navcam 近 / 中（±10 / ±50 m），没有的地方用 HiRISE
    （对比度乘 1.4：同一块地 Navcam 的反照率对比是 HiRISE 的 1.3–1.6 倍，地形生成器设计.md §2.6）；远图用 HiRISE（25 cm）。"""
    from PIL import Image
    Image.MAX_IMAGE_PIXELS = None
    rgba = lambda nm: np.asarray(Image.open(GD/f"{nm}.png").convert("RGBA"))
    hi = rgba("albedo_hirise")
    if name == "远":
        return lum_residual(hi, 1000.0, x, z, 30.0)
    out = 1.4*lum_residual(hi, 1000.0, x, z, 1.5)
    for nm, half in (("albedo_mid", 50.0), ("albedo_near", 10.0)):
        v = lum_residual(rgba(nm), half, x, z, 1.5); ok = np.isfinite(v); out[ok] = v[ok]
    return out


def cmd_fields(args):
    T = table(); R = T["规则"]; wind = R["风"]
    hts = Heights()
    for name in ("远", "近"):                                    # 先远后近：近图要用远图的大尺度 Sx、汇流
        g = GRIDS[name]; t0 = time.time()
        x, z = grid_xz(g); cs = g["cs"]; e = np.maximum(np.abs(x), np.abs(z))
        h = hts.sample(x, z)
        F = dict(h=h, r=data_res(e, hts))
        for spec in R["场"][name]:                               # 例：["tpi", 0.3]、["sx", 3.0]
            kind, s = spec[0], float(spec[1]); key = f"{kind}:{s:g}"
            if kind == "slope": F[key] = f_slope(h, cs, s)
            elif kind == "tpi": F[key] = f_tpi(h, cs, s)
            elif kind == "curv": F[key] = f_curv(h, cs, s)
            elif kind == "rough": F[key] = f_rough(h, cs, s, 3*s)
            elif kind == "sx":                                   # 小尺度 Sx 先平滑到 s/20、最近从 s/8 起算：不让立体噪声和高度层分界当成遮蔽
                F[key] = f_sx(gauss(h, s/20/cs), cs, s, wind["来向"], wind["扇区"], dmin=max(cs, s/8))
            elif kind == "flow": F[key] = np.log10(f_flow(gauss(h, s/cs), cs))
            else: raise SystemExit(f"不认识的场：{spec}")
            log(f"  场 {name} {key}：中位 {np.nanmedian(F[key]):+.4g}，5–95% {np.nanpercentile(F[key], 5):+.4g} … {np.nanpercentile(F[key], 95):+.4g}")
        F["W"], F["Wm"] = class_prior(name, x, z)
        F["alb"] = albedo_field(name, x, z)
        if name == "近":                                        # 远图的 Sx / 汇流 采样到近图（规则里写 "远:sx:100"）
            Fr = np.load(WORK/"场_远.npz") if (WORK/"场_远.npz").exists() else None
            if Fr is not None:
                from scipy.ndimage import map_coordinates
                gr = GRIDS["远"]
                u = (x + gr["half"])/gr["cs"] - 0.5; v = (z + gr["half"])/gr["cs"] - 0.5
                for k in Fr.files:
                    if k in ("h", "r", "W", "Wm", "alb"): continue
                    F["远:" + k] = map_coordinates(Fr[k], [v, u], order=1, mode="nearest").astype(np.float32)
        np.savez(WORK/f"场_{name}.npz", **F)
        log(f"场 {name}：{x.shape[0]}² @ {cs*100:g} cm，{len(F)} 项，{time.time() - t0:.0f} s")


# ———————————————————— 规则 → 权重 → 控制图
def u32_hash(x):
    """同 地貌.gdshaderinc 的 geo_hash（uint32 回绕）。"""
    x = x.astype(np.uint32)
    x ^= x >> np.uint32(16); x *= np.uint32(0x7feb352d); x ^= x >> np.uint32(15); x *= np.uint32(0x5bd1e995); x ^= x >> np.uint32(16)
    return x


def value_noise(x, z, lam, seed):
    """整数格点哈希值噪声，0..1，格距 lam（米），smoothstep 插值。确定性：同一世界坐标在近图、远图、C++、着色器里都一样。"""
    fx, fz = x/lam, z/lam
    ix, iz = np.floor(fx).astype(np.int64), np.floor(fz).astype(np.int64)
    tx, tz = fx - ix, fz - iz
    tx, tz = tx*tx*(3 - 2*tx), tz*tz*(3 - 2*tz)

    def h(a, b):
        hb = u32_hash((b.astype(np.int64) & 0xffffffff).astype(np.uint32) + np.uint32(seed*0x165667b1 & 0xffffffff))
        v = u32_hash(((a.astype(np.int64) & 0xffffffff).astype(np.uint32)*np.uint32(0x27d4eb2d)) ^ hb)
        return (v >> np.uint32(8)).astype(np.float32)/16777216.0
    return ((h(ix, iz)*(1 - tx) + h(ix + 1, iz)*tx)*(1 - tz) + (h(ix, iz + 1)*(1 - tx) + h(ix + 1, iz + 1)*tx)*tz).astype(np.float32)


def value_noise_w(x, z, lam, seed, k):
    """中景版（MAT_TAG 非空）：格距 lam 的值噪声在远图上能看出 40 m 的格子（M4 方块斑的根因：远图只有这一个八度、规则项又少，
    锐化把噪声放大成方块）。改法：每种材质一个旋转角、域扭曲（用 1.9·lam 的另一份噪声把坐标挪 ±0.45·lam）、再叠 0.41·lam 的第二个八度（权 0.45），
    归一回同一量级。"""
    ang = math.radians((37.0*k + 11.0) % 90.0); c, s_ = math.cos(ang), math.sin(ang)
    xr, zr = c*x - s_*z, s_*x + c*z
    wx = (value_noise(xr + 7.3, zr, 1.9*lam, seed + 101) - 0.5)*0.9*lam
    wz = (value_noise(xr, zr - 5.1, 1.9*lam, seed + 211) - 0.5)*0.9*lam
    n1 = value_noise(xr + wx, zr + wz, lam, seed)
    n2 = value_noise(xr + 0.7*wz, zr - 0.7*wx, 0.41*lam, seed + 307)
    return (0.5 + ((n1 - 0.5) + 0.45*(n2 - 0.5))/math.sqrt(1 + 0.45**2)).astype(np.float32)


def sigm(x):
    return 1/(1 + np.exp(-np.clip(x, -40, 40)))


def field_of(F, key):
    """规则里的量名：先找本图自己的场，没有就找从远图采样来的（"远:" 前缀）。都没有 = 这一图上不可用（等于门 = 0）。"""
    if key in F: return F[key], False
    if "远:" + key in F: return F["远:" + key], True
    return None, False


def mat_logits(F, T, cfg, name, x, z):
    """各材质的总分（含 M10 积尘）。cfg 是 "+" 连起来的开关：几何（派生场规则）、地类（HiRISE / class_mid 先验）、反照率（近景反照率先验）。"""
    R = T["规则"]; mats = [m["id"] for m in T["材质"]]; g = GRIDS[name]
    shape = F["h"].shape
    L = {m: np.full(shape, float(R["基"].get(m, 0.0)), np.float32) for m in mats + ["M10"]}
    contrib = {}
    if "几何" in cfg:
        r_here = np.maximum(F["r"], g["cs"])
        for t in R["项"]:
            v, from_far = field_of(F, t["量"])
            if v is None: continue
            scale = float(t["量"].split(":")[1])
            r = np.maximum(F["远r"], GRIDS["远"]["cs"]) if from_far and "远r" in F else r_here
            gate = np.clip(scale/r - 0.5, 0, 1)
            if t["型"] == "高": s = sigm((v - t["阈"])/t["宽"])
            elif t["型"] == "低": s = sigm((t["阈"] - v)/t["宽"])
            elif t["型"] == "带": s = sigm((v - t["阈"][0])/t["宽"])*sigm((t["阈"][1] - v)/t["宽"])
            else: raise SystemExit(f"不认识的型：{t}")
            full = gate >= 0.99
            sbar = float(s[full].mean()) if full.any() else 0.5     # 分辨不出的地方给这一项在分辨得出处的平均贡献（边缘化），
            c = (t["强"]*((s - 0.5)*gate + (sbar - 0.5)*(1 - gate))).astype(np.float32)   # 门开关处材质比例不跳
            L[t["材质"]] += c
            contrib[f"{t['材质']} {t['型']} {t['量']}"] = c
    if "反照率" in cfg and "alb" in F:                         # 可选：近景反照率（数据或生成器给的）亮 → 岩板 / 碎片、暗 → 沙
        A = F["alb"]; ok = np.isfinite(A); A0 = np.where(ok, A, 0)
        for t in R["反照率项"]:
            if t["型"] == "高": s_ = sigm((A0 - t["阈"])/t["宽"])
            else: s_ = sigm((t["阈"] - A0)/t["宽"])
            L[t["材质"]] += (R["反照率强度"]*t["强"]*(s_ - 0.5)*ok).astype(np.float32)
    if "地类" in cfg:
        P = T["地类先验"]; lam = float(P["强度"])
        if "Wm" in F: lam = lam*(1 - F["Wm"]) + float(P.get("强度_class_mid", P["强度"]))*F["Wm"]   # class_mid（4 cm k-means）和 HiRISE 地类分开给强度
        W = F["W"]; ok = np.clip(W.sum(-1)*2, 0, 1)
        for m in mats:
            pm = np.array([P["P"][c].get(m, 0.0) for c in CLASSES], np.float32)
            L[m] += lam*ok*np.log(W @ pm + 0.05)
    N = R["噪声"]
    for k, m in enumerate(mats + ["M10"]):
        acc = np.zeros(shape, np.float32)
        for lam, amp in ((N["波长"]["远"], 1.0), (N["波长"]["近"], 0.6)):
            gate = np.clip((lam/g["cs"] - 2)/2, 0, 1)
            if gate > 0: acc += amp*gate*((value_noise_w(x, z, lam, N["种子"] + 31*k, k) if TAG else value_noise(x, z, lam, N["种子"] + 31*k)) - 0.5)*2
        L[m] += N["强"]*acc
    return L, contrib


def weights(L, T):
    mats = [m["id"] for m in T["材质"]]
    A = np.stack([L[m] for m in mats], -1)*float(T["规则"].get("锐化", 1.0))   # 锐化：只留前 3 种时少丢权重（材质表 规则.锐化说明）
    A = A - A.max(-1, keepdims=True); E = np.exp(A)
    return (E/E.sum(-1, keepdims=True)).astype(np.float32), sigm(L["M10"]).astype(np.float32)


WB = 6                                                        # 权重位数（每纹素 3 个权重，第 3 个 = 63 − w0 − w1）
DB = 5                                                        # 积尘位数


def pack(w, dust, k=3):
    """前 k=3 种：位 0–4 号0、5–9 号1、10–14 号2、15–20 权0、21–26 权1、27–31 积尘（第 3 个权 = 63 − 权0 − 权1）。
    存成 RGBA8（R = 位 0–7 …），着色器 texelFetch 后拼回 uint。"""
    order = np.argsort(-w, axis=-1, kind="stable")[..., :k]
    wk = np.take_along_axis(w, order, -1); wk = wk/np.maximum(wk.sum(-1, keepdims=True), 1e-9)
    M = (1 << WB) - 1
    q = np.floor(wk*M).astype(np.int32); rem = wk*M - q
    short = M - q.sum(-1)                                     # 最大余数法补齐到 63
    rk = np.argsort(-rem, axis=-1, kind="stable")
    for t in range(k):
        add = (short > t).astype(np.int32)
        np.put_along_axis(q, rk[..., t:t + 1], np.take_along_axis(q, rk[..., t:t + 1], -1) + add[..., None], -1)
    dq = np.clip(np.round(dust*((1 << DB) - 1)), 0, (1 << DB) - 1).astype(np.uint32)
    o = order.astype(np.uint32); q = q.astype(np.uint32)
    word = o[..., 0] | (o[..., 1] << 5) | (o[..., 2] << 10) | (q[..., 0] << 15) | (q[..., 1] << 21) | (dq << 27)
    return word.astype(np.uint32)


def unpack(word, nm):
    """控制图 → (每纹素各材质权重 (…, nm)、积尘)。和着色器解码一致。"""
    word = word.astype(np.uint32)
    ids = [(word >> np.uint32(s)) & np.uint32(31) for s in (0, 5, 10)]
    w0 = ((word >> np.uint32(15)) & np.uint32(63)).astype(np.float32); w1 = ((word >> np.uint32(21)) & np.uint32(63)).astype(np.float32)
    ws = [w0, w1, 63 - w0 - w1]
    W = np.zeros(word.shape + (nm,), np.float32)
    for i, wv in zip(ids, ws):
        np.put_along_axis(W, i.astype(np.int64)[..., None], np.take_along_axis(W, i.astype(np.int64)[..., None], -1) + wv[..., None]/63, -1)
    return W, ((word >> np.uint32(27)) & np.uint32(31)).astype(np.float32)/31


def load_fields(name):
    z = np.load(WORK/f"场_{name}.npz"); F = {k: z[k] for k in z.files}
    if name == "近" and (WORK/"场_远.npz").exists():           # 远图采样来的项要用远图的分辨率门
        from scipy.ndimage import map_coordinates
        Fr = np.load(WORK/"场_远.npz"); g = GRIDS[name]; gr = GRIDS["远"]
        x, zz = grid_xz(g)
        F["远r"] = map_coordinates(Fr["r"], [(zz + gr["half"])/gr["cs"] - 0.5, (x + gr["half"])/gr["cs"] - 0.5], order=1, mode="nearest")
    return F


def bake(name, cfg, T=None, write=False):
    T = T or table(); g = GRIDS[name]
    F = load_fields(name); x, z = grid_xz(g)
    L, contrib = mat_logits(F, T, cfg, name, x, z)
    w, dust = weights(L, T)
    word = pack(w, dust)
    if write:
        n = word.shape[0]
        with open(GD/g["file"], "wb") as f:
            np.array([n, n], np.int32).tofile(f); word.astype("<u4").tofile(f)
        nm = w.shape[-1]; srt = -np.sort(-w, -1)
        lost = {k: float((1 - srt[..., :k].sum(-1)).mean()) for k in (1, 2, 3, 4)}
        Wq, dq = unpack(word, nm)
        log(f"烘焙 {name}（{cfg}）→ {g['file']}：{n}²，{os.path.getsize(GD/g['file'])/1e6:.1f} MB；各材质平均权重 "
            + "、".join(f"{m['id']} {w[..., i].mean():.2f}" for i, m in enumerate(T["材质"]))
            + f"；积尘均值 {dust.mean():.2f}；每纹素只留前 k 种丢掉的权重 k=1 {lost[1]:.3f}、2 {lost[2]:.3f}、3 {lost[3]:.4f}、4 {lost[4]:.5f}；"
            f"量化误差 |Δw| 平均 {np.abs(Wq - w).mean():.4f}、最大 {np.abs(Wq - w).max():.3f}")
    return w, dust, word, contrib


def cmd_bake(args):
    cfg = next((a.split("=", 1)[1] for a in args if a.startswith("--配置=")), table()["规则"]["默认配置"])
    if "--只门" not in args:
        for name in ("远", "近"):
            bake(name, cfg, write=True)
    bake_gate()


GATE_FILE = "mat_gate_4cm.bin"


def bake_gate():
    """中观位移门：和 地形.gdshader 片元第 1、1b、3 步同一条链（CTX → HiRISE → 中 → 近 → 细 → 贴片）算反照率数据分辨率 r，
    g = clamp(log2(2r/0.04)/log2(0.5/0.04), 0, 1)，烘在近图网格（4 cm、±50 m）上。图外 g = 1（HiRISE / CTX 区 r ≥ 0.25 m）。
    GPU 顶点（中观位移.gdshaderinc）和 CPU（材质.gd、terrain_core MatDisp）都双线性读这一张，所以碰撞和画出来的位移逐点一致；
    片元仍按逐像素的 r 算自己的 g_meso（细节反照率和法线用）。72 / 61 重导出反照率后要重跑 `73 烘焙 --只门`。"""
    from PIL import Image
    from scipy.ndimage import map_coordinates
    Image.MAX_IMAGE_PIXELS = None
    S = json.loads((GD/"scene.json").read_text()); T = S["tex"]; R = S["data_res"]
    g = GRIDS["近"]; x, z = grid_xz(g); e = np.maximum(np.abs(x), np.abs(z))

    def region(h, f): return np.clip((h*0.97 - e)/(h*f), 0, 1)

    def samp(img, u, v):                                      # 双线性，像素中心 (i + ½)，同 GPU texture()
        H_, W_ = img.shape[:2]
        return map_coordinates(img, [v*H_ - 0.5, u*W_ - 0.5], order=1, mode="nearest")

    def alpha(name):
        return np.asarray(Image.open(GD/T[name]["file"]))[..., 3].astype(np.float32)/255

    def map_uv(h): return x/(2*h) + 0.5, z/(2*h) + 0.5          # Godot xz：u = E/(2h) + ½、v = z/(2h) + ½（第 0 行在北）
    res = np.full(x.shape, R["albedo_ctx"]*4.0, np.float64)
    w = region(T["albedo_ctx"]["half"], 0.08); res += (R["albedo_ctx"] - res)*w
    w = region(T["albedo_hirise"]["half"], 0.08); res += (R["albedo_hirise"] - res)*w
    for k in ("albedo_mid", "albedo_near"):
        h = T[k]["half"]; w = region(h, 0.08)*samp(alpha(k), *map_uv(h)); res += (R[k] - res)*w
    NF = S.get("near_fine")
    if NF:
        hf = float(NF["albedo"]["half"]); inside = e < hf
        u, v = map_uv(max(hf, 1.0))
        wf = samp(alpha_img := np.asarray(Image.open(GD/NF["albedo"]["file"]))[..., 3].astype(np.float32)/255, u, v)*inside
        del alpha_img
        rv = samp(np.asarray(Image.open(GD/NF["res"]["file"])).astype(np.float32)/255, u, v)
        res += (0.001*np.exp2(rv*(255.0/32.0)) - res)*wf
        pr = NF["patch"]["rect"]; E, N = x, -z
        m = inside & (E > pr[0]) & (E < pr[2]) & (N > pr[1]) & (N < pr[3])
        pa = np.asarray(Image.open(GD/NF["patch"]["file"]))[..., 3].astype(np.float32)/255
        ta = samp(pa, (E - pr[0])/(pr[2] - pr[0]), (pr[3] - N)/(pr[3] - pr[1]))*m
        res += (float(NF["patch"]["res"]) - res)*ta
    gate = np.clip(np.log2(2*res/0.04)/np.log2(0.5/0.04), 0, 1)
    q = (gate*255 + 0.5).astype(np.uint8); n = q.shape[0]
    with open(GD/GATE_FILE, "wb") as f:
        np.array([n, n], np.int32).tofile(f); q.tofile(f)
    log(f"位移门 → {GATE_FILE}：{n}²，{os.path.getsize(GD/GATE_FILE)/1e6:.1f} MB；g = 0 占 {(q == 0).mean()*100:.1f}%、= 1 占 {(q == 255).mean()*100:.1f}%，"
        f"±10 m 内均值 {gate[e < 10].mean():.3f}、10–45 m {gate[(e >= 10) & (e < 45)].mean():.3f}")


# ———————————————————— 验证
GROUPS = ["沙", "碎片砾石", "岩"]                               # 真值能分的三组：M1/M4 → 沙、M3 → 碎片、M2/M8 → 岩
GROUP_OF = {"M1": 0, "M4": 0, "M5": 0, "M3": 1, "M17": 1, "M11": 1, "M2": 2, "M8": 2}
CLS2GROUP = [0, 1, 2, 0]                                       # 地类 → 组：沙、砾石风化层、基岩、暗色岩块（调研 §0.1：暗块多半是暗沙 + 浮石 + 阴影）
PAL_MAT = {"M1": (0.36, 0.22, 0.15), "M2": (0.95, 0.92, 0.82), "M3": (0.95, 0.72, 0.20), "M4": (0.85, 0.45, 0.30), "M8": (0.45, 0.55, 0.75),
           "M5": (0.40, 0.75, 0.40), "M17": (0.75, 0.35, 0.75), "M11": (0.30, 0.70, 0.75)}   # 和 材质.gdshaderinc MAT_PAL 同序（材质号 0–7）
PAL_GRP = np.array([(0.36, 0.22, 0.15), (0.95, 0.72, 0.20), (0.95, 0.92, 0.82)])


def group_w(w, T):
    G = np.zeros(w.shape[:-1] + (3,), np.float32)
    for i, m in enumerate(T["材质"]): G[..., GROUP_OF[m["id"]]] += w[..., i]
    return G


def metrics(truth, pred, n=3):
    """truth、pred：0..n−1，其余忽略。返回混淆矩阵（行 = 真值、列 = 预测）、总体一致率、κ、每类 IoU。"""
    m = (truth < n) & (pred < n)
    C = np.bincount(truth[m].astype(int)*n + pred[m].astype(int), minlength=n*n).reshape(n, n).astype(np.int64)
    N = C.sum(); oa = np.trace(C)/N
    pe = (C.sum(0)*C.sum(1)).sum()/N**2; kappa = (oa - pe)/(1 - pe)
    iou = [C[i, i]/max(C[i].sum() + C[:, i].sum() - C[i, i], 1) for i in range(n)]
    return dict(C=C.tolist(), N=int(N), OA=float(oa), kappa=float(kappa), IoU=[float(v) for v in iou], 真值占比=(C.sum(1)/N).tolist(), 预测占比=(C.sum(0)/N).tolist())


def truth_workspace():
    """71 的工作区分类（2 mm：0 暗沙、1 碎片、2 岩板、255 无数据）→ 近图 4 cm 纹素的多数票（有效 ≥ 80%）+ 每类占比。"""
    gx = json.loads((BATCH1/"正射"/"格.json").read_text())
    cls = np.load(BATCH1/"切块"/"分类.npz")["cls"]
    g = GRIDS["近"]; n = int(round(2*g["half"]/g["cs"]))
    I, J = np.mgrid[0:cls.shape[0], 0:cls.shape[1]]
    E = gx["x0"] + (J + 0.5)*gx["cs"]; Nn = gx["y0"] + (I + 0.5)*gx["cs"]
    ci = np.floor((E + g["half"])/g["cs"]).astype(np.int64); cj = np.floor((-Nn + g["half"])/g["cs"]).astype(np.int64)
    cnt = np.zeros((n*n, 4), np.int64)
    c = np.where(cls == 255, 3, cls).astype(np.int64)
    for k in range(4):
        m = (c == k).ravel(); cnt[:, k] = np.bincount((cj*n + ci).ravel()[m], minlength=n*n)
    cnt = cnt.reshape(n, n, 4); tot = cnt.sum(-1)
    lab = np.full((n, n), 255, np.uint8)
    ok = (tot > 0) & (cnt[..., 3] < 0.2*np.maximum(tot, 1))
    lab[ok] = cnt[..., :3][ok].argmax(-1)
    frac = cnt[..., :3]/np.maximum(cnt[..., :3].sum(-1, keepdims=True), 1)
    js, is_ = np.nonzero(tot > 0)
    return lab, frac, (js.min(), js.max() + 1, is_.min(), is_.max() + 1)


def raw_class_mid():
    from PIL import Image
    from scipy.ndimage import map_coordinates
    km = np.asarray(Image.open(GD/"class_mid.png").convert("RGBA")).astype(np.float32)/255
    x, z = grid_xz(GRIDS["近"]); half = 50.0; cs = 2*half/km.shape[0]
    K = np.stack([map_coordinates(km[..., c], [(z + half)/cs - 0.5, (x + half)/cs - 0.5], order=0, mode="nearest") for c in range(4)], -1)
    lab = np.where((K.sum(-1) > 0.5) & (K.max(-1) > 0.5), K.argmax(-1), 255).astype(np.uint8)
    return lab


def albedo_residual():
    """近景反照率（albedo_near 1 cm ±10 m、albedo_mid 2 cm ±50 m）→ 近图上 log 亮度减 1.5 m 趋势。"""
    from PIL import Image
    from scipy.ndimage import map_coordinates
    Image.MAX_IMAGE_PIXELS = None
    x, z = grid_xz(GRIDS["近"]); out = np.full(x.shape, np.nan, np.float32); Y = np.full(x.shape, np.nan, np.float32)
    for nm, half in (("albedo_mid", 50.0), ("albedo_near", 10.0)):
        a = np.asarray(Image.open(GD/f"{nm}.png").convert("RGBA")).astype(np.float32)/255
        cs = 2*half/a.shape[0]; uv = [(z + half)/cs - 0.5, (x + half)/cs - 0.5]
        lum = sum(map_coordinates((a[..., c])**2.2, uv, order=1, mode="nearest")*wt for c, wt in enumerate((0.2126, 0.7152, 0.0722)))
        al = map_coordinates(a[..., 3], uv, order=1, mode="nearest")
        inside = (np.abs(x) < half*0.97) & (np.abs(z) < half*0.97) & (al > 0.5)
        Y[inside] = lum[inside]
    ly = np.log(np.maximum(Y, 1e-4)); ok = np.isfinite(ly)
    from scipy.ndimage import gaussian_filter
    lf = np.where(ok, ly, 0); wt = gaussian_filter(ok.astype(np.float32), 1.5/0.04); tr = gaussian_filter(lf, 1.5/0.04)/np.maximum(wt, 1e-3)
    out[ok] = (ly - tr)[ok]
    return out, Y


def colorize(w, T, base=None, alpha=0.65):
    pal = np.array([PAL_MAT[m["id"]] for m in T["材质"]])
    col = np.einsum("...k,kc->...c", w, pal)
    if base is not None: col = col*alpha + base[..., None]*(1 - alpha)
    return np.clip(col, 0, 1)


def save_jpg(path, rgb, q=88, maxw=None):
    from PIL import Image
    im = Image.fromarray((np.clip(rgb, 0, 1)*255 + 0.5).astype(np.uint8))
    if maxw and im.width > maxw: im = im.resize((maxw, round(im.height*maxw/im.width)), Image.LANCZOS)
    path.parent.mkdir(parents=True, exist_ok=True); im.save(path, quality=q)


def label_panel(img, text):
    from PIL import Image, ImageDraw, ImageFont
    im = Image.fromarray((np.clip(img, 0, 1)*255 + 0.5).astype(np.uint8)).convert("RGB")
    d = ImageDraw.Draw(im)
    try: font = ImageFont.truetype("/usr/share/fonts/google-noto-sans-mono-cjk-vf-fonts/NotoSansMonoCJK-VF.ttc", max(14, im.width//22))
    except Exception: font = ImageFont.load_default()
    d.rectangle([0, 0, im.width, font.size + 8], fill=(0, 0, 0)); d.text((4, 2), text, fill=(255, 255, 255), font=font)
    return np.asarray(im).astype(np.float32)/255


def hstack(ps, gap=6):
    h = max(p.shape[0] for p in ps)
    out = [np.pad(p, ((0, h - p.shape[0]), (0, gap), (0, 0)), constant_values=1) for p in ps]
    return np.concatenate(out, 1)


def cmd_validate(args):
    T = table(); res = {}; V = WORK/"验证"; V.mkdir(parents=True, exist_ok=True)
    cfgs = ["几何", "地类", "反照率", "几何+地类", "几何+反照率", "几何+地类+反照率"]
    best = T["规则"]["默认配置"]
    # A 71 工作区
    lab, frac, (j0, j1, i0, i1) = truth_workspace()
    cm = raw_class_mid()
    ar, Y = albedo_residual()
    near = {c: bake("近", c, T) for c in cfgs}
    res["工作区_71"] = {}
    for c in cfgs:
        G = group_w(near[c][0], T); pred = G.argmax(-1).astype(np.uint8)
        sub = (slice(j0, j1), slice(i0, i1))
        M = metrics(lab[sub], pred[sub])
        # 软一致：20 cm 块里真值各类占比 vs 预测组权重
        b = 5; fs = frac[sub]; gs = G[sub]; okb = (lab[sub] < 3)
        nb0, nb1 = fs.shape[0]//b, fs.shape[1]//b
        rs = lambda a: a[:nb0*b, :nb1*b].reshape(nb0, b, nb1, b, -1).mean((1, 3))
        okr = rs(okb[..., None].astype(np.float32))[..., 0] > 0.8
        tf, pf = rs(fs*okb[..., None])[okr], rs(gs*okb[..., None])[okr]
        M["软_20cm"] = dict(相关=[float(np.corrcoef(tf[:, k], pf[:, k])[0, 1]) for k in range(3)], 平均绝对差=float(np.abs(tf - pf).mean()))
        res["工作区_71"][c] = M
        log(f"验证 71 工作区 [{c}]：OA {M['OA']:.3f}、κ {M['kappa']:.3f}、IoU 沙 {M['IoU'][0]:.2f} 碎片 {M['IoU'][1]:.2f} 岩 {M['IoU'][2]:.2f}；"
            f"预测占比 {np.round(M['预测占比'], 2).tolist()}（真值 {np.round(M['真值占比'], 2).tolist()}）；20 cm 软相关 {np.round(M['软_20cm']['相关'], 2).tolist()}")
    # 基线：多数类、class_mid 本身
    sub = (slice(j0, j1), slice(i0, i1))
    res["工作区_71"]["基线_全沙"] = metrics(lab[sub], np.zeros_like(lab[sub]))
    cmg = np.where(cm < 4, np.array(CLS2GROUP + [255]*252, np.uint8)[np.minimum(cm, 255)], 255).astype(np.uint8)
    res["工作区_71"]["基线_class_mid"] = metrics(lab[sub], cmg[sub])
    log(f"验证 71 工作区 基线：全判沙 OA {res['工作区_71']['基线_全沙']['OA']:.3f}；class_mid 直接映射 OA {res['工作区_71']['基线_class_mid']['OA']:.3f}、"
        f"κ {res['工作区_71']['基线_class_mid']['kappa']:.3f}（覆盖 {res['工作区_71']['基线_class_mid']['N']} 纹素）")
    # B ±50 m：class_mid
    res["近_class_mid"] = {}
    e = np.maximum(*[np.abs(a) for a in grid_xz(GRIDS["近"])])
    for c in cfgs:
        pred = group_w(near[c][0], T).argmax(-1).astype(np.uint8)
        M = metrics(cmg, pred); res["近_class_mid"][c] = M
        log(f"验证 ±50 m 对 class_mid [{c}]：OA {M['OA']:.3f}、κ {M['kappa']:.3f}、IoU {np.round(M['IoU'], 2).tolist()}，N {M['N']}")
    # D 反照率：按预测组的 log 亮度残差（岩应最亮、沙最暗）
    res["反照率"] = {}
    for c in cfgs:
        pred = group_w(near[c][0], T).argmax(-1)
        sel = np.isfinite(ar) & (e < 10)
        res["反照率"][c] = [float(np.nanmean(ar[sel & (pred == k)])) if (sel & (pred == k)).any() else None for k in range(3)]
        log(f"验证 反照率残差（±10 m，log）[{c}]：沙 {res['反照率'][c][0]}、碎片 {res['反照率'][c][1]}、岩 {res['反照率'][c][2]}")
    # C ±1 km：HiRISE 地类（geo_class 1 m）
    geo = np.fromfile(GD/"geo_class.bin", np.uint8).reshape(2000, 2000, 4).astype(np.float32)/255
    gl = np.where(geo.max(-1) > 0.5, np.array(CLS2GROUP)[geo.argmax(-1)], 255).astype(np.uint8)
    far = {c: bake("远", c, T) for c in cfgs}
    res["远_HiRISE地类"] = {}
    for c in cfgs:
        pred = group_w(far[c][0], T).argmax(-1).astype(np.uint8)
        M = metrics(gl, pred)
        # 软一致：HiRISE 地类按组的权重（0..1）和预测组权重，10 m 块平均后的相关（地类 argmax 几乎全是"沙"组，硬指标没信息）
        Gp = group_w(far[c][0], T); Gt = np.zeros_like(Gp)
        for k, gi in enumerate(CLS2GROUP): Gt[..., gi] += geo[..., k]
        Gt /= np.maximum(Gt.sum(-1, keepdims=True), 1e-6)
        rs = lambda a: a.reshape(200, 10, 200, 10, 3).mean((1, 3)).reshape(-1, 3)
        tp, pp = rs(Gt), rs(Gp)
        M["软_10m相关"] = [float(np.corrcoef(tp[:, k], pp[:, k])[0, 1]) for k in range(3)]
        res["远_HiRISE地类"][c] = M
        log(f"验证 ±1 km 对 HiRISE 地类 [{c}]：OA {M['OA']:.3f}、κ {M['kappa']:.3f}；10 m 软相关 沙 {M['软_10m相关'][0]:+.2f} 碎片 {M['软_10m相关'][1]:+.2f} 岩 {M['软_10m相关'][2]:+.2f}；"
            f"预测占比 {np.round(M['预测占比'], 2).tolist()}（地类 argmax {np.round(M['真值占比'], 2).tolist()}）")
    (V/"结果.json").write_text(json.dumps(res, ensure_ascii=False, indent=1))
    # —— 叠图
    sub = (slice(j0, j1), slice(i0, i1))
    yb = Y[sub]; yb = np.clip((yb/np.nanpercentile(yb, 99))**(1/2.2), 0, 1); yb = np.nan_to_num(yb)
    tcol = np.where((lab[sub] < 3)[..., None], PAL_GRP[np.minimum(lab[sub], 2)], 0.0)
    pan = [label_panel(np.repeat(yb[..., None], 3, -1), "反照率（Navcam）"), label_panel(tcol, "真值：71 分类"),
           label_panel(colorize(near["几何"][0][sub], T), "只用几何"), label_panel(colorize(near["几何+反照率"][0][sub], T), "几何+反照率"),
           label_panel(colorize(near[best][0][sub], T), best), label_panel(np.repeat(near[best][1][sub][..., None], 3, -1), "积尘 M10")]
    up = lambda a: np.kron(a, np.ones((3, 3, 1)))
    save_jpg(V/"工作区.jpg", hstack([up(p) for p in pan]))
    save_jpg(FIG/"阶段1_规则_工作区.jpg", hstack([up(p) for p in pan]), q=82, maxw=1600)
    # ±50 m 总图（降到 8 cm）
    ys = np.nan_to_num(np.clip((Y/np.nanpercentile(Y, 99))**(1/2.2), 0, 1))[::2, ::2]
    pan = [label_panel(np.repeat(ys[..., None], 3, -1), "反照率 ±50 m"),
           label_panel(colorize(near["几何"][0][::2, ::2], T, ys), "只用几何"), label_panel(colorize(near[best][0][::2, ::2], T, ys), best),
           label_panel(np.repeat(near[best][1][::2, ::2][..., None], 3, -1), "积尘 M10")]
    save_jpg(V/"近_50m.jpg", hstack(pan))
    save_jpg(FIG/"阶段1_规则_50m.jpg", hstack(pan), q=80, maxw=1800)
    from PIL import Image
    Image.MAX_IMAGE_PIXELS = None
    ah = np.asarray(Image.open(GD/"albedo_hirise.png").convert("L").resize((1000, 1000), Image.BILINEAR)).astype(np.float32)/255
    pan = [label_panel(np.repeat(ah[..., None], 3, -1), "HiRISE ±1 km"), label_panel(colorize(far["几何"][0][::2, ::2], T, ah), "只用几何"),
           label_panel(colorize(far[best][0][::2, ::2], T, ah), best),
           label_panel(np.where((gl[::2, ::2] < 3)[..., None], PAL_GRP[np.minimum(gl[::2, ::2], 2)], 0.0)*0.65 + ah[..., None]*0.35, "HiRISE 地类（三组）")]
    save_jpg(V/"远_1km.jpg", hstack(pan))
    save_jpg(FIG/"阶段1_规则_1km.jpg", hstack(pan), q=80, maxw=1800)
    log(f"验证图 → {V}，小图 → {FIG}/阶段1_规则_*.jpg")


# ———————————————————— 导出纹理数组
ENGINE = os.environ.get("GODOT", "/home/user/引擎/godot/bin/godot.linuxbsd.editor.x86_64.mars")
OUTM = GD/("材质" + TAG)                                               # 带 .gdignore：编辑器不导入这里的 DDS，运行时 load() 直接走 DDS 加载器


def fft_resample(a, n):
    """周期图（样块都做过 Moisan 周期分解）按傅里叶截断 / 补零重采样到 n²，保持无缝。a：(N, N) 或 (N, N, C)。"""
    N = a.shape[0]
    if N == n: return a.astype(np.float64)
    F = np.fft.fftshift(np.fft.fft2(a.astype(np.float64), axes=(0, 1)), axes=(0, 1))
    # fftshift 后零频在 N//2，ifftshift 要它在 n//2：按零频对齐裁 / 补（不能用 (N − n)//2——奇数边长（M11 的 333²）会差一格，
    # 等于整幅乘一个 cos 斜坡：第二任时 M11 导出后均值 0.34、5% 截到下限，远处岩坡一片暗，照片回归窄条超线就是它）
    if n < N:
        c = N//2 - n//2; F = F[c:c + n, c:c + n]
    else:
        p = n//2 - N//2; F = np.pad(F, ((p, n - N - p), (p, n - N - p)) + ((0, 0),)*(a.ndim - 2))
    return np.real(np.fft.ifft2(np.fft.ifftshift(F, axes=(0, 1)), axes=(0, 1)))*(n*n)/(N*N)


def _lib_rows():
    """地面样块库.json（74_多站样块.py 库 写的目录）的样块行；没有这个文件 = 空。"""
    if not LIB.exists(): return []
    try: lib = json.loads(LIB.read_text())
    except Exception: return []
    rows = lib.get("样块", []) if isinstance(lib, dict) else lib
    return [r for r in rows if isinstance(r, dict)]


def _lib_entry(pid):
    """目录里找样块：id 或 "站点/id"（不同站的 id 可能重名）。返回 npz 路径、边长、来源；找不到 = None（退回第一批）。"""
    for r in _lib_rows():
        if pid in (r.get("id"), f"{r.get('station')}/{r.get('id')}"):
            f = (r.get("files") or {}).get("npz")
            if f and (MAP/f).exists():
                return dict(npz=MAP/f, size=float(r.get("size_m") or 0) or None, src=f"样块库 {r.get('station')}/{r.get('id')}")
    return None


def expand_variants(vs):
    """变体列表展开："库:M1" = 目录里 M1 的全部非贴花样块（没有目录时这一项为空）；其余原样。"""
    out = []
    for v in vs:
        if v.startswith("库:"):
            t = v.split(":", 1)[1]
            out += [f"{r['station']}/{r['id']}" for r in _lib_rows() if r.get("type") == t and not r.get("decal")]
        else: out.append(v)
    return out


def load_patch(pid):
    """样块 → (反照率细节 A (N,N,3) 均值 1、高度 H (N,N) 米、物理边长 m、来源说明)。第 0 行在南（同 57 / 71）。"""
    if pid.startswith("地球:"):                                # 81 暂存的地球 PBR 样块（A 均值 1、H 米、边长）：资料/地面材质/中景/地球/<名>.npz
        z = np.load(WORK.parent/"中景"/"地球"/(pid.split(":", 1)[1] + ".npz"))
        return z["A"].astype(np.float64), z["H"].astype(np.float64), float(z["size"]), f"地球 PBR {pid[3:]}"
    if pid.startswith("57:"):                                  # 现有 57 导出的微观图块（gain 2 的 8 位 PNG + float 高度）
        from PIL import Image
        k = pid.split(":")[1]; d = json.loads((GD/"scene.json").read_text())["detail"][k]
        A = np.asarray(Image.open(GD/d["albedo"]).convert("RGB")).astype(np.float64)/255*float(d.get("gain", 2.0))
        b = (GD/d["height"]).read_bytes(); w, h = np.frombuffer(b[:8], np.int32)
        H = np.frombuffer(b[8:], np.float32).reshape(h, w).astype(np.float64)
        return A, H, float(d["size"]), f"57 导出 {k}"
    ent = _lib_entry(pid)
    if ent:
        z = np.load(ent["npz"]); A = z["A"].astype(np.float64); H = z["H"].astype(np.float64)
        return A, H, ent["size"], ent["src"]
    meta = {m["name"]: m for m in json.loads((BATCH1/"切块"/"样块.json").read_text())}
    z = np.load(BATCH1/"切块"/f"{pid}.npz")
    return z["A"].astype(np.float64), z["H"].astype(np.float64), float(meta[pid]["size"]), f"第一批 {pid}"


def deshade(A, H, size, pid):
    """样块反照率里残余的明暗（样块库 shading_leak_r：单一光照站去光影不净）：用样块自己的高度和该站太阳方向算朗伯 μ，
    在高通（σ 8 像素）里对 log 反照率做最小二乘，减掉 β·hp(log μ)（只在 β > 0 时；β < 0 是去过头，不动），再归一到均值 1。
    第 0 行在南、列朝东（同 load_patch）。返回 (A, 相关前, 相关后, β)；不是样块库的块（没有站的太阳方向）原样返回、相关为 None。"""
    from scipy.ndimage import gaussian_filter
    st = pid.split("/")[0]; mf = MAP/"资料"/"地面材质"/"样块库"/st/"分离"/"指标.json"
    if "/" not in pid or not mf.exists(): return A, None, None, 0.0
    sun = np.array(json.loads(mf.read_text())["sun"], np.float64)
    az, el = np.radians(np.median(sun[:, 0])), np.radians(np.median(sun[:, 1]))
    s = np.array([math.sin(az)*math.cos(el), math.cos(az)*math.cos(el), math.sin(el)])
    px = size/H.shape[0]; hy, hx = np.gradient(H, px)
    n = np.stack([-hx, -hy, np.ones_like(H)], -1); n /= np.linalg.norm(n, axis=-1, keepdims=True)
    hp = lambda x: x - gaussian_filter(x, 8, mode="wrap")
    lm = hp(np.log(np.clip(n @ s, 0.05, None))); la = np.log(np.clip(A, 1e-3, None))
    ll = hp(la.mean(-1)); c0 = float(np.corrcoef(ll.ravel(), lm.ravel())[0, 1]); beta = float((ll*lm).sum()/max((lm*lm).sum(), 1e-12))
    if beta <= 0: return A, c0, c0, 0.0
    A2 = np.exp(la - beta*lm[..., None]); A2 /= A2.reshape(-1, 3).mean(0)
    c1 = float(np.corrcoef(hp(np.log(A2).mean(-1)).ravel(), lm.ravel())[0, 1])
    return A2, c0, c1, beta


def cmd_export(args):
    """样块 → 每层 512²：ah（RGBA8 → BC7）、d（RG8 导数图 → BC5）、h16（R16，只中观）。Godot 无头压缩并写 DDS 数组。"""
    T = table(); X = T["导出"]; n = int(X["层"]); gmax = float(X["梯度量程"])
    stage = WORK/"导出"; stage.mkdir(parents=True, exist_ok=True)
    OUTM.mkdir(parents=True, exist_ok=True); (OUTM/".gdignore").write_text("")
    man = dict(说明="73 导出的材质纹理数组清单（实景.gd 读）。层号 = 材质的 起始层 + 变体号；ah：RGB 反照率细节 ÷gain、A 混合高度（每层 0..1）；"
               "d：∂h/∂u、∂h/∂v 存 0.5 + g/(2·梯度量程)（u 朝东、v 朝北、第 0 行在南）；h16：中观物理高度 0.5 + h/(2·量程)。",
               层=n, 梯度量程=gmax, 材质=[], 数组={})
    jobs = []
    for lv in ("中观", "微观"):
        gain = float(X["反照率gain"]) if lv == "中观" else 2.0
        files = {"ah": [], "d": [], "h16": []}; layer = 0
        for m in T["材质"]:
            ent = next((e for e in man["材质"] if e["id"] == m["id"]), None)
            if ent is None: ent = dict(id=m["id"]); man["材质"].append(ent)
            vs = expand_variants(m[lv]["变体"]) or m[lv]["变体"]; hr = 0.0; srcs = []; sizes = []
            data = []; lohi = []
            for pid in vs:
                A, H, size, src = load_patch(pid); srcs.append(src); sizes.append(size)
                if lv == "中观" and m.get("去残余明暗"):
                    A, c0, c1, beta = deshade(A, H, size, pid)
                    if c0 is not None: log(f"去残余明暗 {pid}：高通相关 {c0:.2f} → {c1:.2f}（β {beta:.2f}）")
                A = np.clip(fft_resample(A, n), 0.05, gain); H = fft_resample(H - H.mean(), n)
                data.append((A, H, size)); hr = max(hr, float(np.percentile(np.abs(H), 99.9))*1.1)
            for vi, (A, H, size) in enumerate(data):
                px = size/n
                lo, hi = np.percentile(H, [0.5, 99.5]); a = np.clip((H - lo)/max(hi - lo, 1e-9), 0, 1)
                lohi.append([float(lo), float(max(hi, lo + 1e-9))])   # 顶点 / CPU 由 h16 的高度按同样的 lo、hi 算混合高度 a
                gu = (np.roll(H, -1, 1) - np.roll(H, 1, 1))/(2*px); gv = (np.roll(H, -1, 0) - np.roll(H, 1, 0))/(2*px)
                ah = np.concatenate([A/gain, a[..., None]], -1)
                q8 = lambda v: (np.clip(v, 0, 1)*255 + 0.5).astype(np.uint8)
                tag = f"{lv}_{m['id']}_{vi}"
                q8(ah).tofile(stage/f"{tag}_ah.raw"); files["ah"].append(str(stage/f"{tag}_ah.raw"))
                q8(np.stack([0.5 + gu/(2*gmax), 0.5 + gv/(2*gmax)], -1)).tofile(stage/f"{tag}_d.raw"); files["d"].append(str(stage/f"{tag}_d.raw"))
                if lv == "中观":
                    (np.clip(0.5 + H/(2*hr), 0, 1)*65535 + 0.5).astype("<u2").tofile(stage/f"{tag}_h16.raw"); files["h16"].append(str(stage/f"{tag}_h16.raw"))
                sat = float(((A >= gain - 1e-6).any(-1)).mean())
                log(f"导出 {tag} ← {srcs[vi]}：{size:.3f} m → {n}²（{px*1e3:.2f} mm/像素），高度 RMS {H.std()*1e3:.2f} mm，梯度 RMS {np.hypot(gu, gv).std():.3f}、"
                    f"超量程 {(np.hypot(gu, gv) > gmax).mean()*100:.2f}%，反照率截断 {sat*100:.3f}%")
            ent[lv] = dict(起始层=layer, 变体数=len(vs), 尺寸=float(np.mean(sizes))*float(m[lv].get("缩放", 1.0)), 量程=hr, 来源=srcs,
                           混合高度=lohi)
            ent.update(粗糙度=float(m.get("粗糙度", 0.8)), 对比=float(m["混合"]["对比"]), 偏置=float(m["混合"]["偏置"]),
                       旋转=bool(m.get("hex旋转", True)))
            layer += len(vs)
        pre = "mat_meso" if lv == "中观" else "mat_micro"
        for kind, fmt, src_fmt, dxgi in (("ah", "BC7", "RGBA8", 98), ("d", "BC5", "RG8", 83), ("h16", "R16", "R16", 56)):
            if not files[kind]: continue
            out = OUTM/f"{pre}_{kind}.dds"
            jobs.append(dict(out=str(out), layers=files[kind], w=n, h=n, src=src_fmt, 压缩=fmt, dxgi=dxgi))
            man["数组"][f"{pre}_{kind}"] = dict(file=f"{OUTM.name}/{out.name}", 格式=fmt, 层数=len(files[kind]))
        man[f"{lv}_gain"] = gain
    # 运行时参数（导出包读不到 scripts/，着色器要的都抄进清单）
    man["运行时"] = dict(锐度=float(T["混合"]["锐度"]), 边缘起伏=float(T["混合"].get("边缘起伏", 0.0)), 修饰=T["修饰"], 逐像素=T["逐像素"], 档=T["档"],
                       hex=T.get("hex", dict(中观格距=0.45, 微观格距=0.06, 指数=7.0, 高度权=0.6)), 宏观=T.get("宏观", {}), 分级=T.get("分级", {}),
                       风=dict(来向=float(T["规则"]["风"]["来向"])),
                       控制图=dict(近=dict(GRIDS["近"]), 远=dict(GRIDS["远"]), 门=GATE_FILE,
                                 图外=T["规则"].get("图外", {"M1": 0.6, "M3": 0.3, "M4": 0.1})))
    (stage/"任务.json").write_text(json.dumps(dict(arrays=jobs), ensure_ascii=False, indent=1))
    t0 = time.time()
    r = subprocess.run([ENGINE, "--headless", "--path", str(MAP/"godot"), "--script", "res://工具/打包材质.gd", "--", str(stage/"任务.json")],
                       capture_output=True, text=True, timeout=1800)
    for line in (r.stdout + r.stderr).splitlines():
        if "[打包材质]" in line or "ERROR" in line or "error" in line.lower(): log("  " + line.strip())
    if r.returncode != 0: raise SystemExit(f"打包材质.gd 失败（{r.returncode}）")
    for k, v in man["数组"].items(): v["MB"] = round(os.path.getsize(GD/v["file"])/1e6, 2)
    (GD/f"mat{TAG}.json").write_text(json.dumps(man, ensure_ascii=False, indent=1))
    log(f"导出 {len(jobs)} 个数组，压缩 {time.time() - t0:.0f} s，共 {sum(v['MB'] for v in man['数组'].values()):.1f} MB → {OUTM}；清单 mat.json")



def cmd_loadtest(args):
    """在 kwin 虚拟合成器里（真显卡、Vulkan）跑 godot/工具/材质加载测.gd；--无头 = 只量 CPU 一侧。"""
    gargs = ["--path", str(MAP/"godot"), "--script", "res://工具/材质加载测.gd", "--", "res://数据/sol0530/", str(WORK/"导出")]
    if "--无头" in args:
        cmd = [ENGINE, "--headless"] + gargs
    else:
        sh = ('SOCK=mat-$$; kwin_wayland --virtual --socket "$SOCK" --width 1280 --height 720 --no-lockscreen >/dev/null 2>&1 & KP=$!; '
              'trap "kill $KP 2>/dev/null" EXIT; for i in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/$SOCK" ] && break; sleep 0.1; done; '
              'WAYLAND_DISPLAY=$SOCK DISPLAY= timeout 90 "$0" --display-driver wayland --audio-driver Dummy "$@"')
        cmd = ["bash", "-c", sh, ENGINE] + gargs
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=400)
    for line in (r.stdout + r.stderr).splitlines():
        if "[加载测]" in line or "ERROR" in line: log("  " + line.strip())


CMDS = {"场": "cmd_fields", "烘焙": "cmd_bake", "验证": "cmd_validate", "导出": "cmd_export", "加载测": "cmd_loadtest"}


def main(a):
    if not a or a[0] not in CMDS and a[0] != "全部": raise SystemExit(__doc__)
    for c in (["场", "烘焙", "验证", "导出"] if a[0] == "全部" else [a[0]]):
        log(f"== {c} {' '.join(a[1:])}")
        globals()[CMDS[c]](a[1:])


if __name__ == "__main__":
    main(sys.argv[1:])
