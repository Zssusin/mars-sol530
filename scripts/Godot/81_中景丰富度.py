#!/usr/bin/env python3
"""81_中景丰富度.py —— 中景（30–500 m）地面丰富度：量化指标、控制图屏占比、顶视预览。
子命令：
  指标 <渲染目录> [名]   把 斜视*.png 的地面区域算纹理 / 块状 / 色块指标，并按平地投影查控制图算材质屏占比（--控制图 old|2）
  参考                    同样的指标算在 Navcam 彩色中景实拍（资料/地面材质/_api/med/NLF_053x）上
"""
import sys, os, json, pathlib, math
import numpy as np
from PIL import Image
from scipy.ndimage import gaussian_filter, map_coordinates

HERE = pathlib.Path(__file__).resolve().parent
def find_map():
    p = HERE
    while p != p.parent:
        if (p/"godot").is_dir() and (p/"scripts").is_dir(): return p
        p = p.parent
    raise SystemExit("找不到仓库根")
MAP = find_map()
GD = MAP/"godot"/"数据"/"sol0530"
REFDIR = MAP/"资料"/"地面材质"/"_api"/"med"
CAMS = [  # E,N,离地高,朝向,下俯,hfov；地面行范围 (y0,y1)，x 范围 (x0,x1)（占图比）
    dict(n="平视南 2m", c=(0, 0, 2, 180, 2, 60), y=(0.46, 1.0), x=(0, 1)),
    dict(n="平视北 2m", c=(0, 0, 2, 0, 2, 60), y=(0.55, 1.0), x=(0, 1)),
    dict(n="平视西 2m(12,-15)", c=(12, -15, 2, 270, 2, 60), y=(0.46, 1.0), x=(0, 1)),
    dict(n="斜俯 20m (120,-80)", c=(120, -80, 20, 45, 30, 60), y=(0.0, 1.0), x=(0, 1)),
    dict(n="斜俯 20m (-150,60)", c=(-150, 60, 20, 0, 30, 60), y=(0.0, 1.0), x=(0, 1)),
    dict(n="平视东 2m (200,-300)", c=(200, -300, 2, 90, 2, 60), y=(0.37, 1.0), x=(0, 1)),
]
REFS = [("NLF_0535_0714445390", (0.2, 0.95), (0, 1)), ("NLF_0537_0714620432", (0.12, 0.88), (0, 0.55)), ("NLF_0538_0714707681", (0.42, 0.85), (0, 0.9))]
W_CMP = 500   # 比较宽度：Navcam 800 px / 96° ≈ 0.12°/px；60° 视场 500 px 同角分辨率


def lin_log(im):
    a = np.asarray(im.convert("RGB"), np.float32)/255
    L = np.clip(a, 1e-3, 1)**2.2
    return L


def stats(rgb, ym, xm):
    h, w = rgb.shape[:2]
    y0, y1, x0, x1 = int(ym[0]*h), int(ym[1]*h), int(xm[0]*w), int(xm[1]*w)
    lum = rgb @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    ll = np.log(np.maximum(lum, 1e-4))
    c1 = np.log(np.maximum(rgb[..., 0], 1e-4)/np.maximum(rgb[..., 1], 1e-4)); c2 = np.log(np.maximum(rgb[..., 2], 1e-4)/np.maximum(rgb[..., 1], 1e-4))
    g = lambda f, s: gaussian_filter(f, s, mode="nearest")
    sl = lambda f: f[y0 + 8:y1 - 8, x0 + 8:x1 - 8]
    out = {}
    out["细纹理"] = float(sl(ll - g(ll, 1.5)).std())               # 0.18°以内
    out["块状"] = float(sl(g(ll, 2) - g(ll, 16)).std())            # 0.24–1.9°：几米到几十米的明暗块
    out["色块"] = float(np.hypot(sl(g(c1, 2) - g(c1, 16)).std(), sl(g(c2, 2) - g(c2, 16)).std()))
    out["整体对比"] = float(sl(g(ll, 2) - g(ll, 60)).std())
    return out


def cmd_ref():
    res = {}
    for pre, ym, xm in REFS:
        f = next(REFDIR.glob(pre + "*"))
        im = Image.open(f).convert("RGB"); im = im.resize((W_CMP, W_CMP*im.height//im.width), Image.LANCZOS)
        res[pre] = stats(lin_log(im), ym, xm)
    return res


def load_ctrl(tag):
    n = "mat_ctrl_1m%s.bin" % tag
    w = np.fromfile(GD/n, np.uint8)[8:].view("<u4"); N = int(round(math.sqrt(w.size)))
    return w.reshape(N, N)


def ground_xy(c, W, H, ys, xs):
    E, N, h, az, pt, hf = c
    f = (W/2)/math.tan(math.radians(hf)/2)
    azr, ptr = math.radians(az), math.radians(-pt)
    fw = np.array([math.sin(azr)*math.cos(ptr), math.sin(ptr), -math.cos(azr)*math.cos(ptr)])   # x 东、y 上、z 南
    rt = np.array([math.cos(azr), 0, math.sin(azr)]); up = np.cross(rt, fw)
    u = (xs - W/2 + 0.5)/f; v = -(ys - H/2 + 0.5)/f
    d = fw[None, None, :] + u[..., None]*rt + v[..., None]*up
    ok = d[..., 1] < -1e-4
    t = np.where(ok, -h/np.minimum(d[..., 1], -1e-4), np.nan)
    gx = E + t*d[..., 0]; gz = -N + t*d[..., 2]
    return gx, -gz, t*np.hypot(d[..., 0], d[..., 2])


def share(c, ym, xm, word, nm=32, mask=31):
    """平地投影：地面像素 → 控制图 → 首位材质 / 距离段占比。"""
    W, H = 1920, 1080
    ys, xs = np.mgrid[int(ym[0]*H):int(ym[1]*H):4, int(xm[0]*W):int(xm[1]*W):4]
    gx, gn, dist = ground_xy(c, W, H, ys.astype(np.float32), xs.astype(np.float32))
    N = word.shape[0]; cs = 2000.0/N
    ui = np.clip(np.nan_to_num((gx + 1000)/cs).astype(np.float64), 0, N - 1.001); vi = np.clip(np.nan_to_num((-gn + 1000)/cs), 0, N - 1.001)
    ids = (word[vi.astype(int), ui.astype(int)] & mask).astype(int)
    ok = np.isfinite(dist) & (dist < 700)
    return ids, dist, ok


def cmd_metrics(d, tag=""):
    d = pathlib.Path(d); word = load_ctrl(tag)
    out = {}
    bands = [(0, 30), (30, 60), (60, 120), (120, 250), (250, 500)]
    for i, cam in enumerate(CAMS):
        f = next(d.glob("斜视%d_*.png" % i))
        im = Image.open(f).convert("RGB"); im = im.resize((W_CMP, W_CMP*im.height//im.width), Image.LANCZOS)
        s = stats(lin_log(im), cam["y"], cam["x"])
        ids, dist, ok = share(cam["c"], cam["y"], cam["x"], word, mask=15 if tag.endswith("f") else 31)
        sh = {}
        for lo, hi in bands:
            m = ok & (dist >= lo) & (dist < hi)
            if m.sum() < 50: continue
            cnt = np.bincount(ids[m], minlength=32)/m.sum()
            ent = float(-(cnt[cnt > 0]*np.log2(cnt[cnt > 0])).sum())
            sh[f"{lo}-{hi}"] = dict(像素占比=float(m.mean()), 熵=ent, 材质数_5pct=int((cnt > 0.05).sum()), 首位=int(cnt.argmax()), 首位占比=float(cnt.max()))
        s["屏占比"] = sh; out[cam["n"]] = s
    return out


if __name__ == "__main__":
    a = sys.argv[1:]
    if not a: print(__doc__); sys.exit()
    if a[0] == "参考": print(json.dumps(cmd_ref(), ensure_ascii=False, indent=1))
    elif a[0] == "指标":
        tag = a[3] if len(a) > 3 else ""
        r = cmd_metrics(a[1], tag)
        if len(a) > 2 and a[2] != "-": pathlib.Path(a[2]).write_text(json.dumps(r, ensure_ascii=False, indent=1))
        for k, v in r.items():
            print(k, {x: round(y, 4) for x, y in v.items() if x != "屏占比"})
            for b, s in v["屏占比"].items(): print("   ", b, {x: (round(y, 3) if isinstance(y, float) else y) for x, y in s.items()})


# ---------------------------------------------------------------- 地球 PBR → 样块
EARTH = pathlib.Path(os.environ.get("EARTH_DIR", MAP/"资料"/"素材库"/"地球"/"材质"))
# 名、边长 m（Poly Haven / ambientCG 没给物理尺寸，按纹理里石子大小对照火星样块估的）、高度 RMS mm（位移图只有相对值，按同类火星样块的 h_rms 取）、类
EARTH_SEL = {
    "dry_riverbed_rock": (1.5, 12.0), "rocks_ground_06": (1.5, 14.0), "ambientCG_Ground031": (1.0, 5.0), "dry_ground_01": (1.0, 5.0),
    "mud_cracked_dry_riverbed_002": (1.5, 6.0), "gravelly_sand": (1.0, 5.0), "sandy_gravel_02": (1.0, 6.0), "rock_ground": (1.2, 9.0),
    "dark_rock_02": (1.5, 10.0), "ambientCG_Rocks006": (0.6, 6.0),
}
CHROMA_KEEP = 0.3     # 地球色杂（锈、青）压到 30%：火星样块的 R/B 对比只有 0.04 左右
LOWCUT_M = 0.6        # 去掉 0.6 m 以上的低频（同火星样块：0.5 m 低频已去）


def srgb2lin(a): return np.where(a <= 0.04045, a/12.92, ((a + 0.055)/1.055)**2.4)


def cmd_earth():
    out = MAP/"资料"/"地面材质"/"中景"/"地球"; out.mkdir(parents=True, exist_ok=True)
    info = {}
    for name, (size, hrms) in EARTH_SEL.items():
        d = EARTH/name
        fd = next(iter(list(d.glob("*diff_2k.jpg")) + list(d.glob("*_Color.jpg"))))
        fh = next(iter(list(d.glob("*disp_2k.png")) + list(d.glob("*_Displacement.jpg"))))
        A = srgb2lin(np.asarray(Image.open(fd).convert("RGB"), np.float64)/255)
        H = np.asarray(Image.open(fh)).astype(np.float64)
        if H.ndim == 3: H = H[..., 0]
        H = H/(65535 if H.max() > 255 else 255)
        n = 1024
        rs = lambda a: np.asarray(Image.fromarray(a.astype(np.float32)).resize((n, n), Image.LANCZOS), np.float64)   # 先平铺感无关的下采样（无缝源图，边缘小误差可忽略）
        A = np.stack([rs(A[..., c]) for c in range(3)], -1); H = rs(H)
        px = size/n; sg = LOWCUT_M/px
        lg = np.log(np.maximum(A, 1e-3)); lum = lg.mean(-1, keepdims=True); chroma = lg - lum
        lum = lum - gaussian_filter(lum, sg, mode="wrap")
        chroma = (chroma - chroma.reshape(-1, 3).mean(0))*CHROMA_KEEP
        Ar = np.exp(lum + chroma); Ar /= Ar.reshape(-1, 3).mean(0)
        H = H - gaussian_filter(H, sg, mode="wrap"); H = H/H.std()*hrms*1e-3
        np.savez_compressed(out/(name + ".npz"), A=Ar.astype(np.float32), H=H.astype(np.float32), size=size)
        info[name] = dict(size=size, 对比=float(np.log(Ar).mean(-1).std()), 高度RMS_mm=hrms)
        print(name, info[name])
    (out/"清单.json").write_text(json.dumps(info, ensure_ascii=False, indent=1))

if __name__ == "__main__" and sys.argv[1:2] == ["地球"]: cmd_earth()


# ---------------------------------------------------------------- 更细的地表分类：新增远图场
WORK2 = MAP/"资料"/"地面材质"/"材质规则2"


def _m73():
    import importlib.util
    os.environ["MAT_TAG"] = "2"
    sp = importlib.util.spec_from_file_location("m73", HERE/"73_材质规则.py"); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
    return m


def cmd_fields2():
    """HiRISE 反照率（25 cm）→ 1 m 远图上的新场：alb1:S（log 亮度减 S 米趋势）、red:S（log R/B 减趋势：尘红 / 暗岩偏蓝）、atex:3（1 m 块内 25 cm 亮度起伏，破碎度 / 石多少的代理，3 米平滑）。
    存成 资料/地面材质/材质规则2/场_远.npz（= 原场 + 新场），场_近.npz 链到原来的。"""
    WORK2.mkdir(parents=True, exist_ok=True)
    Image.MAX_IMAGE_PIXELS = None
    m = _m73()
    Fr = dict(np.load(m.WORK/"场_远.npz"))
    a = np.asarray(Image.open(GD/"albedo_hirise.png").convert("RGB"), np.float32)/255
    lin = a**2.2; del a
    lum = lin @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    rb = np.log(np.maximum(lin[..., 0], 1e-4)/np.maximum(lin[..., 2], 1e-4)); del lin
    n = lum.shape[0]; k = n//2000
    blk = lambda x: x.reshape(2000, k, 2000, k).mean((1, 3))
    lum1 = blk(lum); ll = np.log(np.maximum(lum1, 1e-4)); rb1 = blk(rb)
    tex = np.sqrt(np.maximum(blk(lum**2) - lum1**2, 0))/np.maximum(lum1, 1e-4)
    g = lambda x, s: gaussian_filter(x, s, mode="nearest")
    for s in (8, 40): Fr[f"alb1:{s}"] = (ll - g(ll, s)).astype(np.float32)
    Fr["red:30"] = (rb1 - g(rb1, 30)).astype(np.float32)
    Fr["atex:3"] = g(tex, 3).astype(np.float32)
    # 数据里行 0 在北：和 grid_xz 一致（z 最小 = 北）
    np.savez(WORK2/"场_远.npz", **Fr)
    nr = WORK2/"场_近.npz"
    if not nr.exists(): os.symlink(m.WORK/"场_近.npz", nr)
    for kx in ("alb1:8", "alb1:40", "red:30", "atex:3"):
        v = Fr[kx]; print(kx, "5/25/50/75/95%", np.round(np.percentile(v, [5, 25, 50, 75, 95]), 4))
    # 与 HiRISE 地类（geo_class 1 m）交叉：每类的均值，供设阈值
    geo = np.fromfile(GD/"geo_class.bin", np.uint8).reshape(2000, 2000, 4)
    for ci, cn in enumerate(["沙", "砾石风化层", "基岩", "暗色岩块"]):
        mk = geo.argmax(-1) == ci
        print(f"  地类 {cn} {mk.mean()*100:.0f}%：", {kx: round(float(Fr[kx][mk].mean()), 4) for kx in ("alb1:8", "red:30", "atex:3")})

if __name__ == "__main__" and sys.argv[1:2] == ["场2"]: cmd_fields2()


# ---------------------------------------------------------------- 中景材质表（现表 + 6 个新类 + 补变体）
TABLE2 = HERE/"地面材质表_中景.json"
GAIN_NOTE = "反照率增益：线性光 RGB，相对 M1 暗沙 = 1。M1 / M2 / M3 来自 sol 530 Navcam 反照率（albedo_near ±10 m）按 71 工作区分类（暗沙 / 碎片 / 岩板）取均值再除以暗沙；其余是推定（理由见各材质注），待 Mastcam-Z 多光谱校。"
GAINS = {"M1": [1, 1, 1], "M2": [1.43, 1.36, 1.29], "M3": [1.25, 1.17, 1.12], "M4": [1, 1, 1], "M8": [1.43, 1.36, 1.29], "M5": [1.02, 1.0, 0.99],
         "M17": [1.25, 1.17, 1.12], "M11": [1.25, 1.17, 1.12],
         "M16": [1.30, 1.18, 1.02], "M14": [0.87, 0.86, 0.84], "M15": [1.20, 1.12, 1.04], "M18": [0.90, 0.90, 0.93], "M19": [1.12, 1.08, 1.04], "M20": [1.35, 1.28, 1.20]}
GAIN_SRC = {"M1": "实测", "M2": "实测", "M3": "实测"}
MICRO = {"M1": ("57:micro_0", 0.1103), "M2": ("57:micro_2", 0.2304), "M3": ("57:micro_1", 0.2304), "M4": ("p8_0/p8_0_M1_2", 0.256), "M8": ("s0530/s0530_M8_1", 0.32),
         "M5": ("57:micro_3", 0.1103), "M17": ("p61_376/p61_376_M11_5", 0.512), "M11": ("p61_376/p61_376_M11_5", 0.512), "M16": ("p82_2866/p82_2866_M19_4", 0.512),
         "M14": ("p7_2050/p7_2050_M14_5", 0.512), "M15": ("57:micro_3", 0.1103), "M18": ("p8_0/p8_0_M1_2", 0.256), "M19": ("p82_2866/p82_2866_M19_4", 0.512), "M20": ("57:micro_2", 0.2304)}
LIBV = lambda st, t, ks: [f"{st}/{st}_{t}_{k}" for k in ks]
EXTRA_MESO = {   # 现有材质补的变体
    "M1": LIBV("p8_0", "M1", [1]), "M3": LIBV("p56_1010", "M22", [1, 2, 3]) + ["地球:ambientCG_Rocks006"],
    "M17": ["地球:sandy_gravel_02", "地球:gravelly_sand"], "M11": LIBV("m105_106", "M21", [1, 2, 3]),
}
NEW_MATS = [
    dict(id="M16", 名="亮色积尘平原", T型="T16", 地类=["沙", "砾石风化层"], 中观=dict(变体=LIBV("p22_788", "M16", [1, 2, 3]), 尺寸=1.0), 粗糙度=0.80, 混合=dict(对比=0.4, 偏置=-0.05),
         注="库 p22_788（坑底积尘平原，彩色）3 块全用。放在平坦、偏红偏亮（HiRISE R/B 残差高）、1 m 块内起伏小的地方。"),
    dict(id="M14", 名="暗色岩面 / 铺路石", T型="T14", 地类=["暗色岩块", "基岩"], 中观=dict(变体=LIBV("p7_2050", "M14", [1, 2, 3, 4]) + ["地球:rock_ground"], 尺寸=1.0), 粗糙度=0.65, 混合=dict(对比=1.0, 偏置=0.05),
         注="库 p7_2050（Máaz 玄武质铺路石）4 块 + 地球 rock_ground（补库里没有的暗粗糙岩面，已压对比 / 色杂；dark_rock_02 看着像砌砖，删了）。放在 HiRISE 偏暗偏蓝、1 m 块内起伏大的地方。"),
    dict(id="M15", 名="干裂地", T型="T15", 地类=["沙", "砾石风化层"], 中观=dict(变体=LIBV("m89_724", "M15", [1, 2, 3]) + ["地球:dry_ground_01", "地球:mud_cracked_dry_riverbed_002", "地球:ambientCG_Ground031"], 尺寸=1.0), 粗糙度=0.80, 混合=dict(对比=0.6, 偏置=0.0),
         注="库 m89_724（Curiosity Pontours 多边形裂纹，单色）3 块 + 地球三种干裂面。放在平坦、低洼、汇流多的干涸浅盆。"),
    dict(id="M18", 名="暗色沙纹沙", T型="T18", 地类=["沙", "暗色岩块"], 中观=dict(变体=LIBV("p52_0", "M18", [1, 2, 3]) + LIBV("p9_2818", "M18", [1, 2, 3, 4]) + LIBV("m52_1162", "M18", [1, 2]), 尺寸=1.0), 粗糙度=0.80, 混合=dict(对比=0.6, 偏置=-0.05), hex旋转=False,
         注="库 p52_0（3）、p9_2818（4）毅力号暗沙沙纹 + m52_1162（Bagnold 沙丘，单色）。沙纹走向随样块固定。放在背风低处、暗的沙地。"),
    dict(id="M19", 名="颗粒沙席", T型="T19", 地类=["沙"], 中观=dict(变体=LIBV("p82_2866", "M19", [1, 2, 3]) + LIBV("m5_104", "M19", [1, 2]), 尺寸=1.0), 粗糙度=0.85, 混合=dict(对比=0.4, 偏置=-0.05),
         注="库 p82_2866（坑缘外沙席）3 块 + m5_104（Rocknest 沙影，单色）。放在迎风平坦、略亮的沙地。"),
    dict(id="M20", 名="层状基岩", T型="T20", 地类=["基岩"], 中观=dict(变体=LIBV("m105_418", "M20", [1, 2]) + LIBV("m106_660", "M20", [1, 2, 3]) + LIBV("m87_2578", "M20", [1, 2]) + LIBV("m95_3152", "M20", [1, 2]) + ["地球:rocks_ground_06"], 尺寸=1.0), 粗糙度=0.65, 混合=dict(对比=1.0, 偏置=0.05),
         注="库 Curiosity 4 站 9 块层状硫酸盐基岩（单色，借 M2 的色）+ 地球 rocks_ground_06（dry_riverbed_rock 像砌石墙，删了）。放在中等坡、台地边缘、1 m 块内起伏大的基岩上。"),
]
NEW_RULES = {   # 材质: (基, [(量, 型, 阈, 宽, 强)])
    "M16": (-1.0, [("slope:8", "低", 3.0, 1.5, 2.0), ("red:30", "高", 0.012, 0.01, 2.5), ("alb1:8", "高", 0.01, 0.01, 1.5), ("atex:3", "低", 0.0065, 0.002, 1.5)]),
    "M14": (-1.2, [("alb1:8", "低", -0.01, 0.01, 2.5), ("red:30", "低", -0.01, 0.01, 2.0), ("atex:3", "高", 0.011, 0.002, 2.0), ("tpi:10", "高", 0.0, 0.3, 1.0)]),
    "M15": (-1.3, [("slope:8", "低", 4.0, 2.0, 2.0), ("flow:8", "高", 1.8, 0.4, 1.5), ("tpi:30", "低", -0.2, 0.4, 1.5), ("atex:3", "低", 0.0075, 0.002, 1.0)]),
    "M18": (-0.8, [("slope:8", "低", 6.0, 2.0, 1.5), ("tpi:10", "低", -0.15, 0.2, 1.5), ("alb1:8", "低", -0.005, 0.01, 1.5), ("sx:100", "高", 4.0, 3.0, 1.0)]),
    "M19": (-1.0, [("slope:8", "低", 3.0, 1.5, 1.5), ("sx:100", "低", 1.0, 3.0, 1.5), ("alb1:8", "高", 0.0, 0.01, 1.0), ("atex:3", "低", 0.0075, 0.002, 1.5)]),
    "M20": (-1.5, [("slope:8", "带", [8.0, 28.0], 2.5, 2.0), ("tpi:30", "高", 0.4, 0.5, 1.5), ("atex:3", "高", 0.010, 0.002, 2.0)]),
}
PRIOR2 = {"沙": {"M1": .35, "M4": .2, "M5": .12, "M3": .03, "M16": .1, "M18": .1, "M19": .06, "M15": .04},
          "砾石风化层": {"M3": .4, "M17": .15, "M1": .08, "M2": .07, "M11": .04, "M15": .08, "M19": .06, "M16": .06, "M14": .06},
          "基岩": {"M2": .35, "M8": .1, "M3": .1, "M11": .05, "M20": .3, "M14": .1},
          "暗色岩块": {"M1": .4, "M3": .15, "M17": .08, "M2": .02, "M14": .25, "M18": .1}}


def cmd_table():
    T = json.loads((HERE/"地面材质表.json").read_text())
    T["说明"] += "【中景版：81_中景丰富度.py 表 生成，勿手改；在原表上加 6 个新类、补变体、给每个材质加 反照率增益 和独立的微观块。】"
    T["反照率增益说明"] = GAIN_NOTE
    for m in T["材质"]:
        if m["id"] in EXTRA_MESO: m["中观"]["变体"] = m["中观"]["变体"] + EXTRA_MESO[m["id"]]
        if m["id"] in ("M3", "M11", "M17"): m["去残余明暗"] = m.get("去残余明暗", False)
    for nm in NEW_MATS:
        nm["去残余明暗"] = True; T["材质"].append(nm)
    for m in T["材质"]:
        mp, sz = MICRO[m["id"]]; m["微观"] = dict(变体=[mp], 尺寸=sz)
        m["反照率增益"] = GAINS[m["id"]]; m["增益来源"] = GAIN_SRC.get(m["id"], "推定")
    R = T["规则"]
    for mid, (base, terms) in NEW_RULES.items():
        R["基"][mid] = base
        for q, ty, th, w, s in terms: R["项"].append(dict(材质=mid, 量=q, 型=ty, 阈=th, 宽=w, 强=s))
    T["地类先验"]["P"] = PRIOR2
    R["噪声"]["波长"]["远"] = 40.0
    TABLE2.write_text(json.dumps(T, ensure_ascii=False, indent=1))
    n = sum(len(m["中观"]["变体"]) for m in T["材质"])
    print(f"{TABLE2.name}：{len(T['材质'])} 种材质、中观 {n} 层、微观 {len(T['材质'])} 层")


def _wrap_near(m):
    """近图（±50 m）里 Navcam 站点自己的实拍岩板（M2 / M3）更可信：新类按 规则.近图偏移 压低，免得 M20 / M14 把 M2 的位置抢走。"""
    orig = m.mat_logits
    def f(F, T, cfg, name, x, z):
        L, c = orig(F, T, cfg, name, x, z)
        if name == "近":
            for k, v in T["规则"].get("近图偏移", {}).items(): L[k] = L[k] + v
        return L, c
    m.mat_logits = f


def cmd_bake2():
    m = _m73(); m.WORK = WORK2; _wrap_near(m)
    T = json.loads(TABLE2.read_text()); m.TABLE = TABLE2
    for name in ("远", "近"):
        m.bake(name, T["规则"]["默认配置"], T=T, write=True)

if __name__ == "__main__" and sys.argv[1:2] == ["表"]: cmd_table()
if __name__ == "__main__" and sys.argv[1:2] == ["烘焙2"]: cmd_bake2()


TARGET = {"M16": .04, "M14": .05, "M15": .03, "M18": .06, "M19": .05, "M20": .04}


def cmd_tune():
    m = _m73(); m.WORK = WORK2
    T = json.loads(TABLE2.read_text()); m.TABLE = TABLE2
    mats = [x["id"] for x in T["材质"]]
    for it in range(8):
        w, _, _, _ = m.bake("远", T["规则"]["默认配置"], T=T, write=False)
        mean = {k: float(w[..., mats.index(k)].mean()) for k in TARGET}
        print(it, {k: round(v, 3) for k, v in mean.items()})
        for k, t in TARGET.items():
            T["规则"]["基"][k] += 0.9*math.log(t/max(mean[k], 1e-3))
        if all(abs(mean[k]/TARGET[k] - 1) < 0.15 for k in TARGET): break
    print("基", {k: round(T["规则"]["基"][k], 2) for k in TARGET})
    _wrap_near(m); off = T["规则"].setdefault("近图偏移", {}); NT = {"M20": .05, "M14": .06}
    for it in range(8):
        w, _, _, _ = m.bake("近", T["规则"]["默认配置"], T=T, write=False)
        mean = {k: float(w[..., mats.index(k)].mean()) for k in NT}; print("近", it, {k: round(v, 3) for k, v in mean.items()})
        for k, t in NT.items(): off[k] = off.get(k, 0.0) + 0.9*math.log(t/max(mean[k], 1e-3))
        if all(abs(mean[k]/NT[k] - 1) < 0.15 for k in NT): break
    print("近图偏移", {k: round(v, 2) for k, v in off.items()})
    TABLE2.write_text(json.dumps(T, ensure_ascii=False, indent=1))

if __name__ == "__main__" and sys.argv[1:2] == ["调"]: cmd_tune()


def cmd_export2():
    m = _m73(); m.WORK = WORK2; m.TABLE = TABLE2
    m.cmd_export([])

if __name__ == "__main__" and sys.argv[1:2] == ["导出2"]: cmd_export2()


def cmd_sheet():
    """新变体对照卡：每种材质一行，每个变体两格（反照率 × 增益，晕渲高度）。写 docs/地面材质/图/中景_变体_*.jpg"""
    from PIL import ImageDraw
    m = _m73(); m.WORK = WORK2; m.TABLE = TABLE2
    T = json.loads(TABLE2.read_text()); fig = MAP/"docs"/"地面材质"/"图"; S = 144
    rows = []
    for mt in T["材质"]:
        vs = m.expand_variants(mt["中观"]["变体"]); cells = []
        for pid in vs:
            A, H, size, src = m.load_patch(pid)
            if mt.get("去残余明暗"): A = m.deshade(A, H, size, pid)[0]
            n = A.shape[0]; c = n//2; w = min(n, int(round(0.8/(size/n))))        # 都裁成约 0.8 m 见方，同比例看
            sl = slice(c - w//2, c - w//2 + w)
            a = np.clip(A[sl, sl]*np.array(mt["反照率增益"])*0.42, 0, 1)**(1/2.2)
            h = H[sl, sl]; gy, gx = np.gradient(gaussian_filter(h, 1.0), size/n)
            sh = np.clip(0.5 + 0.5*(-gx*0.6 + gy*0.6)/max(np.abs(gx).std()*3, 1e-6), 0, 1)
            ia = Image.fromarray((a*255).astype(np.uint8)).resize((S, S), Image.LANCZOS)
            ih = Image.fromarray((sh*255).astype(np.uint8)).resize((S, S), Image.LANCZOS).convert("RGB")
            cells.append((pid, ia, ih))
        rows.append((mt, cells))
    for part, sel in (("A", rows[:7]), ("B", rows[7:])):
        mx = max(len(c) for _, c in sel); LW = 150
        im = Image.new("RGB", (LW + mx*S, len(sel)*(2*S + 2)), (24, 24, 24)); d = ImageDraw.Draw(im)
        for r, (mt, cells) in enumerate(sel):
            y = r*(2*S + 2); d.text((4, y + 4), f"{mt['id']} {mt['名']}", fill=(255, 255, 0)); d.text((4, y + 20), f"{len(cells)} 变体", fill=(200, 200, 200))
            d.text((4, y + 36), "增益 " + ",".join(f"{g:.2f}" for g in mt["反照率增益"]), fill=(180, 220, 255)); d.text((4, y + 52), mt["增益来源"], fill=(180, 220, 255))
            for k, (pid, ia, ih) in enumerate(cells):
                im.paste(ia, (LW + k*S, y)); im.paste(ih, (LW + k*S, y + S))
                d.text((LW + k*S + 2, y + 2), pid.split("/")[-1][-14:] if not pid.startswith("地球") else pid[3:17], fill=(255, 255, 255))
        im.save(fig/f"中景_变体_{part}.jpg", quality=85); print(part, im.size, os.path.getsize(fig/f"中景_变体_{part}.jpg")//1024, "KB")

if __name__ == "__main__" and sys.argv[1:2] == ["卡"]: cmd_sheet()


# ---------------------------------------------------------------- 顶视预览（离线合成，按现有混合规则：控制图权重 × 样块细节 × HiRISE 宏观反照率；新版再乘材质增益）
PREV = [("A", 120, -80, 150.0), ("B", -150, 60, 150.0), ("C", 200, -300, 150.0)]


def _unpack_far(m, tag, nm):
    w = np.fromfile(GD/f"mat_ctrl_1m{tag}.bin", np.uint8)[8:].view("<u4").reshape(2000, 2000)
    W, dust = m.unpack(w, nm)
    return W


def _tiles(m, T, T_px, px):
    """每种材质：变体细节块 (nv, T_px, T_px, 3)，样块按 px（米 / 像素）面积平均到预览分辨率再取 T_px 见方。"""
    out = {}
    for mt in T["材质"]:
        vs = m.expand_variants(mt["中观"]["变体"]); arr = []
        for pid in vs:
            A, H, size, src = m.load_patch(pid)
            if mt.get("去残余明暗"): A = m.deshade(A, H, size, pid)[0]
            n = A.shape[0]; k = max(1, int(round(px/(size/n))))
            n2 = n//k*k; B = A[:n2, :n2].reshape(n2//k, k, n2//k, k, 3).mean((1, 3))
            tp = np.asarray(Image.fromarray(B.astype(np.float32)).resize((T_px, T_px), Image.BOX) if False else Image.fromarray(np.ascontiguousarray(B[..., 0]).astype(np.float32)))
            Bs = np.stack([np.asarray(Image.fromarray(B[..., c].astype(np.float32)).resize((T_px, T_px), Image.BILINEAR)) for c in range(3)], -1)
            arr.append(Bs)
        out[mt["id"]] = np.stack(arr)
    return out


def _synth(m, T, tag, win, apply_gain, kappa=0.7):
    nm = len(T["材质"]); name, cx, cn, half = win
    n = 1200; px = 2*half/n
    xs = cx - half + (np.arange(n) + 0.5)*px; zs = -cn - half + (np.arange(n) + 0.5)*px          # 行 0 = 北（z 最小）
    X, Z = np.meshgrid(xs, zs)
    W = _unpack_far(m, tag, nm)
    u = (X + 1000)/1.0 - 0.5; v = (Z + 1000)/1.0 - 0.5
    Wi = np.stack([map_coordinates(W[..., k], [v, u], order=1, mode="nearest") for k in range(nm)], -1)
    Image.MAX_IMAGE_PIXELS = None
    hi = np.asarray(Image.open(GD/"albedo_hirise.png").convert("RGB"), np.float32)/255
    j0 = int((cn_row := (-cn - half + 1000))/0.25); i0 = int((cx - half + 1000)/0.25)
    mac = hi[j0:j0 + int(2*half/0.25), i0:i0 + int(2*half/0.25)]**2.2
    mac = np.stack([np.asarray(Image.fromarray(mac[..., c]).resize((n, n), Image.BOX)) for c in range(3)], -1)
    Tp = 10; tl = _tiles(m, T, Tp, px)
    # 每格（0.9 m）每材质一个哈希：变体号 + 平移
    cell = 0.9; ci = np.floor(X/cell).astype(np.int64); cj = np.floor(Z/cell).astype(np.int64)
    det = np.ones((n, n, 3), np.float32); G = np.zeros((n, n, 3), np.float32)
    for k, mt in enumerate(T["材质"]):
        wk = Wi[..., k]
        h = m.u32_hash(((ci*73856093) ^ (cj*19349663) ^ (k*83492791)).astype(np.int64) & 0xffffffff)
        nv = tl[mt["id"]].shape[0]; var = (h % nv).astype(int); ox = ((h >> 8) % Tp).astype(int); oy = ((h >> 16) % Tp).astype(int)
        ux = (np.floor((X - ci*cell)/px).astype(int) + ox) % Tp; uy = (np.floor((Z - cj*cell)/px).astype(int) + oy) % Tp
        tex = tl[mt["id"]][var, uy, ux]
        det = det*(1 + wk[..., None]*(tex - 1))
        G += wk[..., None]*np.array(mt.get("反照率增益", [1, 1, 1]), np.float32)
    if apply_gain:
        G = G/np.maximum(Wi.sum(-1, keepdims=True), 1e-3)
        Gl = np.stack([gaussian_filter(G[..., c], 4.0/px) for c in range(3)], -1)
        det = det*(G/Gl)**kappa
    return mac*det, Wi


def cmd_preview():
    m = _m73(); m.WORK = WORK2
    Told = json.loads((HERE/"地面材质表.json").read_text()); Tnew = json.loads(TABLE2.read_text())
    fig = MAP/"docs"/"地面材质"/"图"; res = {}
    from PIL import ImageDraw
    for win in PREV:
        m.TABLE = HERE/"地面材质表.json"; o, Wo = _synth(m, Told, "", win, False)
        m.TABLE = TABLE2; nw, Wn = _synth(m, Tnew, "2", win, True)
        s = 0.2/o.mean()   # 同一曝光：旧版的几何均值定到 0.6^(1/2.2)... 两张用同一系数
        enc = lambda a: (np.clip(a*s*1.0, 0, 1)**(1/2.2)*255).astype(np.uint8)
        im = Image.new("RGB", (2400 + 6, 1200 + 28), (20, 20, 20))
        im.paste(Image.fromarray(enc(o)), (0, 28)); im.paste(Image.fromarray(enc(nw)), (1206, 28))
        d = ImageDraw.Draw(im); d.text((6, 6), f"OLD 8 materials  win {win[0]} ({win[1]},{win[2]}) 300 m, 0.25 m/px", fill=(255, 255, 0)); d.text((1212, 6), "NEW 14 classes + gains + 71 variants", fill=(255, 255, 0))
        im.save(fig/f"中景_顶视_{win[0]}.jpg", quality=84)
        st = {}
        for tag, a in (("旧", o), ("新", nw)):
            lum = np.log(np.maximum(a @ np.array([0.2126, 0.7152, 0.0722]), 1e-4)); c1 = np.log(a[..., 0]/np.maximum(a[..., 1], 1e-4)); c2 = np.log(a[..., 2]/np.maximum(a[..., 1], 1e-4))
            g = lambda f, s_: gaussian_filter(f, s_)
            st[tag] = dict(块状=float((g(lum, 2) - g(lum, 16)).std()), 色块=float(np.hypot((g(c1, 2) - g(c1, 16)).std(), (g(c2, 2) - g(c2, 16)).std())), 细纹理=float((lum - g(lum, 1.5)).std()),
                           整体=float((g(lum, 2) - g(lum, 60)).std()))
        def ent(Wm): 
            top = Wm.argmax(-1); c = np.bincount(top.ravel(), minlength=Wm.shape[-1])/top.size
            return dict(首位材质数_ge2pct=int((c > 0.02).sum()), 熵=float(-(c[c > 0]*np.log2(c[c > 0])).sum()), 占比={k: round(float(v), 3) for k, v in zip([x["id"] for x in (Told if Wm.shape[-1] == 8 else Tnew)["材质"]], c)})
        st["旧"]["材质"] = ent(Wo); st["新"]["材质"] = ent(Wn); res[win[0]] = st
        print(win[0], json.dumps(st, ensure_ascii=False)[:900])
    (fig/"中景_顶视指标.json").write_text(json.dumps(res, ensure_ascii=False, indent=1))

if __name__ == "__main__" and sys.argv[1:2] == ["预览"]: cmd_preview()


# ================================================================ B 段：4 槽控制图、增益低通图
MICRO_FADE = [1.0, 2.0]       # 试过 [0.006, 0.02]：帧时间没变，却让 C 点俯 30 m / 俯 8 m 的一致性从 0.98 掉到 0.89（新微观块里有 cm 级内容），已撤回
F4_FILES = {"近": "mat_ctrl_4cm2f.bin", "远": "mat_ctrl_1m2f.bin"}
GAINLP_FILE = "mat_gain_lp2.bin"


def pack4(w, dust, k=4):
    """4 槽控制图字：位 0–15 = 4 个材质号（各 4 位，≤ 16 种），16–27 = 前 3 个权重（各 4 位，总和 15，第 4 个 = 15 − 前 3 个），28–31 = 积尘。
    4 槽时 14 类材质少丢权重（3 槽丢 26%）；权重 1/15 量化，双线性混合后连续。"""
    order = np.argsort(-w, axis=-1, kind="stable")[..., :4]
    wk = np.take_along_axis(w, order, -1); wk = wk/np.maximum(wk.sum(-1, keepdims=True), 1e-9)
    q = np.floor(wk*15).astype(np.int32); rem = wk*15 - q
    short = 15 - q.sum(-1); rk = np.argsort(-rem, axis=-1, kind="stable")
    for t in range(4):
        add = (short > t).astype(np.int32)
        np.put_along_axis(q, rk[..., t:t + 1], np.take_along_axis(q, rk[..., t:t + 1], -1) + add[..., None], -1)
    o = order.astype(np.uint32); q = q.astype(np.uint32)
    dq = np.clip(np.round(dust*15), 0, 15).astype(np.uint32)
    return (o[..., 0] | (o[..., 1] << 4) | (o[..., 2] << 8) | (o[..., 3] << 12) | (q[..., 0] << 16) | (q[..., 1] << 20) | (q[..., 2] << 24) | (dq << 28)).astype(np.uint32)


def unpack4(word, nm):
    word = word.astype(np.uint32)
    ids = [(word >> np.uint32(4*i)) & np.uint32(15) for i in range(4)]
    q = [((word >> np.uint32(16 + 4*i)) & np.uint32(15)).astype(np.float32) for i in range(3)]
    ws = q + [15 - q[0] - q[1] - q[2]]
    W = np.zeros(word.shape + (nm,), np.float32)
    for i, wv in zip(ids, ws):
        ix = np.minimum(i.astype(np.int64), nm - 1)[..., None]
        np.put_along_axis(W, ix, np.take_along_axis(W, ix, -1) + wv[..., None]/15, -1)
    return W, ((word >> np.uint32(28)) & np.uint32(15)).astype(np.float32)/15


def cmd_bake4():
    """用 4 槽格式重烘 14 类控制图（mat_ctrl_*2f.bin），并把 mat2.json 的控制图文件、格式、图外配比、每材质增益写进去。"""
    m = _m73(); m.WORK = WORK2; _wrap_near(m)
    T = json.loads(TABLE2.read_text()); m.TABLE = TABLE2
    m.pack = pack4; m.unpack = unpack4
    T["规则"]["锐化"] = float(os.environ.get("SHARP4", "2.0"))        # 4 槽下锐化 2.0：丢权重 10.8%（1.5 时 17.6%）
    for name in ("远", "近"):
        m.GRIDS[name]["file"] = F4_FILES[name]
        m.bake(name, T["规则"]["默认配置"], T=T, write=True)
    mats = [x["id"] for x in T["材质"]]
    J = GD/"mat2.json"; man = json.loads(J.read_text())
    C = man["运行时"]["控制图"]
    C["近"]["file"] = F4_FILES["近"]; C["远"]["file"] = F4_FILES["远"]; C["格式"] = 4
    man["运行时"]["分级"]["微观淡出足迹"] = MICRO_FADE                      
    for e, t in zip(man["材质"], T["材质"]): e["反照率增益"] = t["反照率增益"]; e["增益来源"] = t.get("增益来源", "推定")
    Wf = unpack4(np.fromfile(GD/F4_FILES["远"], np.uint8)[8:].view("<u4").reshape(2000, 2000), len(mats))[0]
    mean = Wf.reshape(-1, len(mats)).mean(0); top = np.argsort(-mean)[:4]
    s = mean[top].sum(); C["图外"] = {mats[i]: round(float(mean[i]/s), 3) for i in top}
    print("图外", C["图外"])
    J.write_text(json.dumps(man, ensure_ascii=False, indent=1))

if __name__ == "__main__" and sys.argv[1:2] == ["烘焙4"]: cmd_bake4()


def cmd_gainmap():
    """增益低通图：G = Σ 权重·增益（线性光 RGB），σ = 4 m 高斯，存 4 m 格（500²，±1 km）的半精度 RGBA（A = 1）。
    ±50 m 内用近图（4 cm）的权重（先 25×25 平均到 1 m），其余用远图。图外 = 1。着色器：det ×= (G_局部 / G_低通)^κ（κ = --中景增益）。"""
    T = json.loads(TABLE2.read_text()); nm = len(T["材质"])
    gain = np.array([x["反照率增益"] for x in T["材质"]], np.float32)         # (nm, 3)
    def G_of(path, n):
        w = np.fromfile(GD/path, np.uint8)[8:].view("<u4").reshape(n, n)
        out = np.zeros((n, n, 3), np.float32)
        for r in range(0, n, 250):
            W, _ = unpack4(w[r:r + 250], nm); out[r:r + 250] = W @ gain
        return out
    Gf = G_of(F4_FILES["远"], 2000)
    Gn = G_of(F4_FILES["近"], 2500)                                          # 4 cm × 2500 = ±50 m
    Gn1 = Gn.reshape(100, 25, 100, 25, 3).mean((1, 3))                       # 1 m
    Gf[950:1050, 950:1050] = Gn1
    Gl = np.stack([gaussian_filter(Gf[..., c], 4.0, mode="nearest") for c in range(3)], -1)
    G4 = Gl.reshape(500, 4, 500, 4, 3).mean((1, 3))
    out = np.concatenate([G4, np.ones((500, 500, 1), np.float32)], -1).astype("<f2")
    with open(GD/GAINLP_FILE, "wb") as f:
        np.array([500, 500], np.int32).tofile(f); out.tofile(f)
    print("增益低通图 →", GAINLP_FILE, "%.2f MB" % (os.path.getsize(GD/GAINLP_FILE)/1e6), "G 均值", Gl.reshape(-1, 3).mean(0), "std", Gf.reshape(-1, 3).std(0), "低通 std", Gl.reshape(-1, 3).std(0))
    J = GD/"mat2.json"; man = json.loads(J.read_text())
    man["运行时"]["增益低通"] = {"file": GAINLP_FILE, "half": 1000.0, "cs": 4.0, "说明": "G 的 σ=4 m 低通，RGBA16F（500²，4 m 格）；81 增益图 生成"}
    J.write_text(json.dumps(man, ensure_ascii=False, indent=1))

if __name__ == "__main__" and sys.argv[1:2] == ["增益图"]: cmd_gainmap()


def cmd_h16slim(drop=2):
    """h16 瘦身：位移（顶点、CPU）只用 mip ≥ 2（最细顶点格距 1 cm、样块边长 ≥ 1 m → 采样密度 ≤ 5 texel/cm... 即 round(log2(格距·n/边长)) ≥ 2），
    把 DDS 的前 drop 级 mip 丢掉（512² → 128² 起），着色器和 CPU 都用 textureSize / 文件宽算 mip，所以同一批 texel。49.6 MB → ~4 MB，顶点取样的缓存压力大减。"""
    import struct
    src = GD/"材质2"/"mat_meso_h16_full.dds"; dst = GD/"材质2"/"mat_meso_h16.dds"
    if not src.exists(): src.write_bytes(dst.read_bytes())
    b = src.read_bytes()
    assert b[:4] == b"DDS " and b[84:88] == b"DX10"
    hh, ww, nm = struct.unpack_from("<III", b, 12)[0], struct.unpack_from("<I", b, 16)[0], max(struct.unpack_from("<I", b, 28)[0], 1)
    na = struct.unpack_from("<I", b, 128 + 12)[0]
    sizes = [max(ww >> m, 1)**2*2 for m in range(nm)]; per = sum(sizes); skip = sum(sizes[:drop])
    out = bytearray(b[:148])
    struct.pack_into("<I", out, 12, max(hh >> drop, 1)); struct.pack_into("<I", out, 16, max(ww >> drop, 1)); struct.pack_into("<I", out, 28, nm - drop)
    struct.pack_into("<I", out, 20, max(ww >> drop, 1)*2)                      # pitchOrLinearSize（R16）
    for L in range(na):
        o = 148 + L*per; out += b[o + skip:o + per]
    dst.write_bytes(bytes(out)); print("h16 瘦身", len(b)/1e6, "→", len(out)/1e6, "MB;", ww, "→", ww >> drop, "层", na)

if __name__ == "__main__" and sys.argv[1:2] == ["h16瘦身"]: cmd_h16slim()
