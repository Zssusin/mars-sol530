"""
火星车视角近景场景（Blender 里跑：开着的界面用 bl.py 送进去，或 blender -b -P）。
近景＝HiRISE 真高程网格（相机附近原始 2 m，往外 4、8 m）+ 0.5 m 正射影像；远景＝50 的 HRSC/CTX 大地形；石块按 Golombek 分布实例化。
分步：--step terrain（近景地形 + 相机 + 太阳天空）/ far（远景）/ all（＝前两步）/ rocks（撒石，要单独点名）/ save / render。
--engine eevee（默认，游戏式：2 m 真实网格 + 随视距淡出的厘米级凹凸，实时光栅化，显存小，视口「渲染」模式即成片）/ cycles（自适应细分真位移 + 三遍物理大气后期，吃显存）。
运行：python3 scripts/Blender/bl.py scripts/Blender/53_近景场景.py -- --step all       # 在开着的界面里搭
      python3 scripts/Blender/bl.py scripts/Blender/53_近景场景.py -- --step save      # 存 .blend（界面占着显存时）
      blender -b DEM/Blender缓存/梅拉斯层状沉积/梅拉斯层状沉积.blend -P scripts/Blender/53_近景场景.py -- --step render
"""
import argparse, importlib, json, math, pathlib, sys, time
import numpy as np
import bpy
HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import 镜头 as K
import 火星大气 as AT
R51 = importlib.import_module("51_地表渲染")
for _m in (K, AT, R51): importlib.reload(_m)                              # 界面里的 Blender 会缓存模块，改了脚本要重载
G = R51.G
R = K.R
SHOT = "梅拉斯层状沉积"
ENGINE = "eevee"


def log(*a): print("[53]", *a, flush=True)


class NearGeo:
    """near.json 里的 HiRISE 等距圆柱参数。"""
    def __init__(self, m):
        self.m = m; self.R = m["R"]; self.lon0 = m["lon0"]; self.k = math.cos(math.radians(m["lat_ts"]))

    def lonlat(self, row, col, T):
        x = T[0] + (np.asarray(col) + 0.5)*T[1]; y = T[2] + (np.asarray(row) + 0.5)*T[3]
        return self.lon0 + np.degrees(x/(self.R*self.k)), np.degrees(y/self.R)

    def rowcol(self, lon, lat, T):
        x = np.radians(np.asarray(lon) - self.lon0)*self.R*self.k; y = np.radians(lat)*self.R
        return (y - T[2])/T[3] - 0.5, (x - T[0])/T[1] - 0.5


def clear_scene():
    for coll in (bpy.data.objects, bpy.data.meshes, bpy.data.materials, bpy.data.images, bpy.data.lights,
                 bpy.data.cameras, bpy.data.node_groups, bpy.data.collections):
        for x in list(coll):
            if getattr(x, "users", 0) >= 0: coll.remove(x)
    for w in list(bpy.data.worlds): bpy.data.worlds.remove(w)


def setup_viewport(cam):
    """界面里：切到相机视角、材质预览，远裁剪面拉到 2000 km。"""
    for win in bpy.context.window_manager.windows:
        for area in win.screen.areas:
            if area.type != "VIEW_3D": continue
            for sp in area.spaces:
                if sp.type != "VIEW_3D": continue
                sp.clip_start = 0.0005; sp.clip_end = 3000.0
                sp.shading.type = "MATERIAL"
                sp.shading.use_scene_world = True; sp.shading.use_scene_lights = True
                sp.region_3d.view_perspective = "CAMERA"
                sp.overlay.show_floor = False; sp.overlay.show_axis_x = False; sp.overlay.show_axis_y = False
    vs = bpy.context.scene.view_settings
    vs.view_transform = "AgX"; vs.exposure = 2.4                           # 物理亮度（太阳照度 1）→ 视口看得清


def graded(c, n, plans):
    """从 c 往两边取行（列）号，离 c 越远步长越大：plans＝(往小号那边, 往大号那边)，各是 [(距离像元, 步长), …]。
    行号、列号分别取，拼成张量网格：疏密过渡处全是完整四边形，不会有 T 形接缝的裂缝。"""
    idx = {int(round(c))}
    for sign, plan in zip((-1, 1), plans):
        i = int(round(c))
        while True:
            d = abs(i - c)
            i += sign*next((s_ for D, s_ in plan if d < D), plan[-1][1])
            if not 0 <= i < n: idx.add(0 if sign < 0 else n - 1); break
            idx.add(i)
    return np.array(sorted(idx))


def smooth_dtm(z, sigma):
    """HiRISE DTM 平滑。2 px 尺度是立体匹配白噪声；另有约 4 个格点（8 m）一周期的「华夫格」纹（SOCET SET 的规则伪影，
    频谱峰高出背景 12 倍），σ1.2 只压到 17%，掠射光下成满坡条纹。σ2 把它压到 0.5%，冲沟、土丘都还在
    （HiRISE DTM 有效分辨率本就只有 3–5 倍格距）。频谱陷波试过，会在行向拉出新的条纹，不用。可分离卷积，纯 numpy。"""
    r = int(3*sigma + 1); k = np.exp(-0.5*(np.arange(-r, r + 1)/sigma)**2); k /= k.sum()
    zp = np.pad(z, r, mode="edge")
    zp = sum(k[i]*zp[i:i + zp.shape[0] - 2*r, :] for i in range(2*r + 1))
    return sum(k[i]*zp[:, i:i + zp.shape[1] - 2*r] for i in range(2*r + 1)).astype(np.float32)


# ── 近景：HiRISE 网格 + 相机脚下的投影网格 ──────────────────────────────
# 做法照行星仿真器（PANGU、DLR OAISYS、JPL MARTIAN）和游戏地形：轨道 DEM 只管米级以上的形状；
# 米以下用照片扫描的地面（Poly Haven CC0）补，hex-tiling（Mikkelsen 2022）去重复，按高度混合（浮土 / 基岩），
# 扫描图只取亮度和高度，颜色仍由 HiRISE 正射定。相机前 70 m 是按屏幕像素铺的扇形网格，扫描高度做真位移（投得出影子）。
FAN_R = 0.070                               # 投影网格半径（km）
FAN_D = 0.0017                              # 径向、周向间距 ≈ 0.0017 × 距离（1920 宽、70° 视场下约 2.6 像素）
FAN_A = math.radians(52)                    # 前方 ±52° 密，背后稀


class NearCtx:
    """HiRISE 高程（平滑后）、坡度、相机所在行列。"""
    def __init__(self, nd, meta, shot):
        nh = np.load(nd/"near_hgt.npy", mmap_mode="r")                    # (行, 列, 3)：高程 km、裙边、0；第 0 行在北
        z = np.asarray(nh[..., 0])
        self.zs = smooth_dtm(z, 2.0)                                       # σ2 px：滤掉匹配噪声和 4 格点一周期的「华夫格」纹（见 smooth_dtm）
        gy, gx = np.gradient(smooth_dtm(z, 4.0)*1000.0, meta["px"])
        self.slope = np.degrees(np.arctan(np.hypot(gx, gy))).astype(np.float32)   # 8 m 尺度的坡度（度）：分浮土 / 基岩
        self.edge = np.asarray(nh[..., 1])
        self.rows, self.cols = z.shape
        self.meta = meta; self.geo = NearGeo(meta); self.T = meta["T"]; self.r0 = meta["rows"][0]
        self.px = meta["px"]/1000.0                                          # km
        self.kx = math.cos(math.radians(shot["cam"][1]))/math.cos(math.radians(meta["lat_ts"]))   # 列向地面距离 / 投影距离
        cr, cc = self.geo.rowcol(*shot["cam"][:2], self.T)
        self.cr, self.cc = cr - self.r0, cc
        self.heading = math.radians(shot["heading"])

    def uvs(self, rr, cc):
        """浮点行列 → HiRISE 高程图 UV、0.5 m 正射 UV（第 0 行在北的数组顺序）。"""
        lon, lat = self.geo.lonlat(rr + self.r0, cc, self.T)
        uv = np.stack([(cc + 0.5)/self.cols, 1 - (rr + 0.5)/self.rows], -1)
        o = self.meta["ortho"]
        orr, occ = self.geo.rowcol(lon, lat, o["T"])
        uvo = np.stack([(occ - o["c0"] + 0.5)/o["shape"][1], 1 - (orr - o["r0"] + 0.5)/o["shape"][0]], -1)
        return lon, lat, uv, uvo

    def polar(self, rr, cc):
        """行列 → 相对相机的水平距离（km）、方位（相对航向，弧度，−π…π）。"""
        dy = (self.cr - rr)*self.px; dx = (cc - self.cc)*self.px*self.kx
        return np.hypot(dx, dy), (np.arctan2(dx, dy) - self.heading + math.pi) % (2*math.pi) - math.pi


def add_layers(ob, shape, keep, uvo, attrs):
    """grid_mesh 压缩过顶点：按同样规则重建用到的顶点，写第二套 UV（正射）和逐顶点属性。"""
    me = ob.data
    ny_, nx_ = shape
    i, j = np.meshgrid(np.arange(ny_ - 1), np.arange(nx_ - 1), indexing="ij")
    q = np.stack([i*nx_ + j, i*nx_ + j + 1, (i + 1)*nx_ + j + 1, (i + 1)*nx_ + j], -1).reshape(-1, 4)
    if keep is not None: q = q[keep.ravel()]
    used = np.unique(q)
    vidx = np.empty(len(me.loops), np.int32); me.loops.foreach_get("vertex_index", vidx)
    lay = me.uv_layers.new(name="正射")
    lay.data.foreach_set("uv", uvo.reshape(-1, 2)[used][vidx].astype(np.float32).ravel())
    for name, arr in attrs.items():
        at = me.attributes.new(name, "FLOAT", "POINT"); at.data.foreach_set("value", arr.reshape(-1)[used].astype(np.float32))


def bspline_sample(a, fi, fj):
    """三次 B 样条取值（C² 连续）：投影网格比 DTM 密得多，双线性在 2 m 格子边上法线会折，前景看得到一块块的面。"""
    i0 = np.floor(fi).astype(int); j0 = np.floor(fj).astype(int)
    u = fi - i0; v = fj - j0
    def w(t): return ((1 - t)**3/6, (3*t**3 - 6*t**2 + 4)/6, (-3*t**3 + 3*t**2 + 3*t + 1)/6, t**3/6)
    wu, wv = w(u), w(v)
    out = np.zeros(fi.shape, np.float64)
    for a_ in range(4):
        ii = np.clip(i0 + a_ - 1, 0, a.shape[0] - 1)
        for b_ in range(4):
            out += wu[a_]*wv[b_]*a[ii, np.clip(j0 + b_ - 1, 0, a.shape[1] - 1)]
    return out


def near_terrain(F, C):
    """HiRISE 真高程网格：相机前方 1.6 km × 左右 1 km 用原始 2 m，往外 4 m、8 m。
    投影网格底下不挖洞：两张网格材质按世界坐标算，颜色一样，投影网格抬 1 cm 盖在上面（挖洞的锯齿边对不齐，会漏黑缝）。"""
    ri = graded(C.cr, C.rows, ([(800, 1), (2000, 2), (1e9, 4)], [(60, 1), (300, 2), (1e9, 4)]))   # 往北（小行号）是前方
    ci = graded(C.cc, C.cols, ([(500, 1), (1200, 2), (1e9, 4)],) * 2)
    RR, CC = np.meshgrid(ri, ci, indexing="ij")
    lon, lat, uv, uvo = C.uvs(RR, CC)
    edge = C.edge[RR, CC]
    Z = C.zs[RR, CC] - 0.08*edge                                           # 裙边：面片边缘往下钻 80 m
    P = F.pos(lon, lat, R + Z)[::-1]                                       # grid_mesh 要第 0 行在南
    e = edge[::-1]
    keep = (e[:-1, :-1] < 0.98) & (e[1:, :-1] < 0.98) & (e[:-1, 1:] < 0.98) & (e[1:, 1:] < 0.98)
    ob = R51.grid_mesh("近景地形_HiRISE", P, uv[::-1], keep=keep)
    add_layers(ob, P.shape[:2], keep, uvo[::-1], {"坡度": C.slope[RR, CC][::-1]})
    log(f"近景网格 {len(ci)}×{len(ri)}（2/4/8 m 渐变），{len(ob.data.polygons):,} 面")
    return ob


def fan_patch(F, C):
    """相机脚下的投影网格（projected grid）：极坐标，间距与距离成正比 ⇒ 屏幕上大致均匀，近处 1 cm、70 m 处 12 cm。
    高度取同一张平滑 DTM 的双线性（与 HiRISE 网格吻合），外圈 15 m 内位移淡出，贴回 HiRISE 表面。"""
    rings = [0.00002]
    while rings[-1] < FAN_R:
        r = rings[-1]; rings.append(r + (0.00002 if r < 0.005 else FAN_D*r))   # 5 m 以内在画面外，2 cm 一圈就够
    r = np.array(rings)
    t = np.concatenate([np.linspace(-math.pi, -FAN_A, 113)[:-1], np.arange(-FAN_A, FAN_A, FAN_D), np.linspace(FAN_A, math.pi, 113)])
    Rr, Tt = np.meshgrid(r, t, indexing="ij")                              # 行＝由里往外（≈ 由南往北），列＝顺时针：法线朝上
    th = Tt + C.heading
    dx, dy = Rr*np.sin(th), Rr*np.cos(th)
    rr = C.cr - dy/C.px; cc = C.cc + dx/(C.px*C.kx)
    Z = bspline_sample(C.zs, rr, cc)
    d = FAN_R - Rr                                                          # 到外圈的距离（km）
    det = np.clip((d - 0.005)/0.015, 0, 1)
    lon, lat, uv, uvo = C.uvs(rr, cc)
    P = F.pos(lon, lat, R + Z)
    ob = R51.grid_mesh("近景贴地", P, uv)
    add_layers(ob, P.shape[:2], None, uvo, {"坡度": R51.bilinear(C.slope, rr, cc), "细节": det})
    log(f"投影网格 {len(t)}×{len(r)}，{len(ob.data.polygons):,} 面")
    return ob


SCANS = {                                   # 键：(Poly Haven 名, 实际边长 m)。都是 CC0 照片扫描
    "浮土": ("rocky_trail_02", 2.0),        # 混粒碎石土（主）
    "细砂": ("gravelly_sand", 2.48),        # 细砂夹砾（斑块）；dry_ground_rocks 的碎石是地球上的白色石英，火星上不对
    "基岩": ("rock_face", 2.38),            # 粗糙基岩面（陡处露头）
    "中景": ("gravelly_sand", 11.3),        # 放大到 11 m 当中尺度明暗（填 0.5 m 正射和 2 m 扫描之间）
}


AMP = {"基岩": 0.08, "中景": 0.05}         # 各层高度 0–1 对应的实际起伏（m）；火星实拍贴图按实测填


def _pack_exr(path, lum, hgt, s_b, s_a):
    """R＝亮度（均值 0.5）、G＝高度 0–1、B、A＝σ s_b、s_a 像素的低通高度。"""
    import OpenImageIO as oiio
    hb = R51.gauss_blur(np.repeat(hgt[..., None], 3, -1), s_b)[..., 0]
    ha = R51.gauss_blur(np.repeat(hgt[..., None], 3, -1), s_a)[..., 0]
    spec = oiio.ImageSpec(lum.shape[1], lum.shape[0], 4, oiio.HALF); spec.attribute("compression", "zip")
    o = oiio.ImageOutput.create(str(path)); o.open(str(path), spec)
    o.write_image(np.stack([lum, hgt, hb, ha], -1).astype(np.float32)); o.close()


def mars_tiles():
    """54 从 NASA PDS 毅力号 Navcam 实拍网格切出的地面贴图（1.6 m，2 mm/px）→ 浮土（石块多的那块）、细砂（石块少的）。
    高度＝网格 2.5 cm 以上 + 照片亮度高频（2 mm–2.5 cm，亮＝凸，±几毫米），按实测米数存幅度。没跑过 54 就返回空。"""
    src = R51.CACHE/"_素材"/"PDS"/"素材"/"地面贴图.npz"
    if not src.exists(): return {}
    z = np.load(src); n = int(z["n"]); px = float(z["px"])
    ids = sorted(range(n), key=lambda i: float(z[f"t{i}_art"]))[:max(2, n//2)]   # 伪影最少的一半里挑
    ids.sort(key=lambda i: float(z[f"t{i}_rock"]))
    out = {}
    for key, i in (("细砂", ids[0]), ("浮土", ids[-1])):
        path = R51.TEXDIR/"扫描"/f"火星_{key}_t{i}.exr"
        h = z[f"t{i}_hl"].astype(np.float64) + 0.02*z[f"t{i}_hd"]
        lo, hi = np.percentile(h, [1, 99]); AMP[key] = float(hi - lo)
        if not path.exists():
            lum = np.clip(0.5*z[f"t{i}_lum"], 0, 1)
            _pack_exr(path, lum, np.clip((h - lo)/(hi - lo), 0, 1), 3.0, 10.0)   # 2 mm/px：σ 6、20 mm
        out[key] = (path, px*z[f"t{i}_lum"].shape[0])
        log(f"火星贴图 {key}：t{i}，{out[key][1]:.2f} m，起伏 {AMP[key]*100:.1f} cm，石块占 {float(z[f't{i}_rock'])*100:.1f}%")
    return out


def scan_images():
    """扫描贴图 → 一张半精度 EXR：R＝亮度（线性，去掉 σ64 px 的低频，均值 0.5），G＝高度（去掉低频，p1–p99 → 0–1），
    B、A＝低通高度（σ 6 px、20 px ≈ 6、20 mm）：投影网格的顶点 1–2.5 cm 一个，位移用全分辨率会走样成「竖起来的刺」；
    位移按视距在 B、A 间换（相当于位移的 mip），残差走凹凸。浮土、细砂优先用火星实拍（mars_tiles），没有才用 Poly Haven。"""
    import OpenImageIO as oiio
    sd = R51.TEXDIR/"扫描"; out = {}
    mars = mars_tiles()
    for key, (base, size) in SCANS.items():
        if key in mars:
            path, size = mars[key]
        else:
            path = sd/f"扫描_{key}_v3.exr"
            AMP.setdefault(key, 0.05)
            if not path.exists():
                dif = oiio.ImageBuf(str(sd/f"{base}_diff_2k.jpg")).get_pixels(oiio.FLOAT)[..., :3]
                lin = np.where(dif <= 0.04045, dif/12.92, ((dif + 0.055)/1.055)**2.4)
                lum = lin @ np.array([0.2126, 0.7152, 0.0722])
                low = R51.gauss_blur(np.repeat(lum[..., None], 3, -1), 64.0)[..., 0]
                lum = np.clip(0.5*lum/np.maximum(low, 1e-4), 0, 1)
                hgt = oiio.ImageBuf(str(sd/f"{base}_disp_2k.exr")).get_pixels(oiio.FLOAT)[..., 0]
                hgt = hgt - R51.gauss_blur(np.repeat(hgt[..., None], 3, -1), 96.0)[..., 0]
                lo, hi = np.percentile(hgt, [1, 99]); hgt = np.clip((hgt - lo)/(hi - lo), 0, 1)
                R51.TEXDIR.mkdir(parents=True, exist_ok=True)
                _pack_exr(path, lum, hgt, 6.0, 20.0)
        old = bpy.data.images.get(f"扫描_{key}")
        if old: bpy.data.images.remove(old)
        img = bpy.data.images.load(str(path)); img.name = f"扫描_{key}"
        img.colorspace_settings.name = "Non-Color"; img.alpha_mode = "CHANNEL_PACKED"   # A 是数据，不是透明度
        out[key] = (img, size)
    return out


def hex_sample(g, P2, img, size, seed, D=None, rate=2.0):
    """Mikkelsen 2022 hex-tiling：三角网格三个顶点各给随机偏移 + 旋转采一次，按重心权重³ 混合，再按 1/√Σw² 拉回方差
    （不然交界处发灰）。返回 (亮度, 高度, 低通高度)。P2：当地水平坐标（m）；D：视距（km），给了就按它在两级低通间换。"""
    uv = g.v("SCALE", P2, scale=1.0/size)
    st = sep(g, g.v("SCALE", uv, scale=rate))
    kx = st[0]; ky = g.m("SUBTRACT", g.m("MULTIPLY", st[1], 1.15470054), g.m("MULTIPLY", st[0], 0.57735027))
    bx, by = g.m("FLOOR", kx), g.m("FLOOR", ky)
    fx, fy = g.m("SUBTRACT", kx, bx), g.m("SUBTRACT", ky, by)
    tz = g.m("SUBTRACT", g.m("SUBTRACT", 1.0, fx), fy)
    s_ = g.m("LESS_THAN", tz, 0.0); s2 = g.m("SUBTRACT", g.m("MULTIPLY", s_, 2.0), 1.0); ns = g.m("SUBTRACT", 1.0, s_)
    W = [g.m("MULTIPLY", g.m("MULTIPLY", tz, -1.0), s2), g.m("SUBTRACT", s_, g.m("MULTIPLY", fy, s2)), g.m("SUBTRACT", s_, g.m("MULTIPLY", fx, s2))]
    V = [(g.m("ADD", bx, s_), g.m("ADD", by, s_)), (g.m("ADD", bx, s_), g.m("ADD", by, ns)), (g.m("ADD", bx, ns), g.m("ADD", by, s_))]
    W = [g.m("POWER", g.m("MAXIMUM", w, 0.0), 3.0) for w in W]
    ws = g.m("ADD", g.m("ADD", W[0], W[1]), W[2])
    W = [g.m("DIVIDE", w, ws) for w in W]
    norm = g.m("INVERSE_SQRT", g.m("ADD", g.m("ADD", g.m("MULTIPLY", W[0], W[0]), g.m("MULTIPLY", W[1], W[1])), g.m("MULTIPLY", W[2], W[2])))
    lum = hgt = hgb = None
    for (vx, vy), w in zip(V, W):
        wn = g.n("ShaderNodeTexWhiteNoise", noise_dimensions="3D"); g.link(comb(g, vx, vy, float(seed)), wn.inputs["Vector"])
        rnd = sep(g, wn.outputs["Color"])
        rot = g.n("ShaderNodeVectorRotate", rotation_type="Z_AXIS"); g.link(uv, rot.inputs["Vector"])
        g.link(g.m("MULTIPLY", rnd[2], 2*math.pi), rot.inputs["Angle"])
        uvi = g.v("ADD", rot.outputs[0], comb(g, g.m("MULTIPLY", rnd[0], 97.0), g.m("MULTIPLY", rnd[1], 97.0), 0.0))
        t = g.n("ShaderNodeTexImage", image=img, interpolation="Linear", extension="REPEAT"); g.link(uvi, t.inputs["Vector"])
        sc = g.n("ShaderNodeSeparateColor"); g.link(t.outputs["Color"], sc.inputs[0])
        dl = g.m("MULTIPLY", g.m("SUBTRACT", sc.outputs[0], 0.5), w); dh = g.m("MULTIPLY", g.m("SUBTRACT", sc.outputs[1], 0.5), w)
        hb = sc.outputs[2] if D is None else lerp(g, sc.outputs[2], t.outputs["Alpha"], g.maprange(D, 0.008, 0.015))
        db = g.m("MULTIPLY", g.m("SUBTRACT", hb, 0.5), w)
        lum = dl if lum is None else g.m("ADD", lum, dl); hgt = dh if hgt is None else g.m("ADD", hgt, dh)
        hgb = db if hgb is None else g.m("ADD", hgb, db)
    return tuple(g.m("ADD", 0.5, g.m("MULTIPLY", x, norm)) for x in (lum, hgt, hgb))


def sep(g, v):
    n = g.n("ShaderNodeSeparateXYZ"); g.link(v, n.inputs[0]); return n.outputs


def comb(g, x, y, z):
    n = g.n("ShaderNodeCombineXYZ")
    for i, val in enumerate((x, y, z)): g._in(n.inputs[i], val)
    return n.outputs[0]


def lerp(g, a, b, t): return g.m("ADD", a, g.m("MULTIPLY", g.m("SUBTRACT", b, a), t))


def height_blend(g, ha, hb, a, depth):
    """高度混合（游戏地形的标准做法）：掩膜 a 不是线性混，而是谁「高」谁露出来 ⇒ 碎石从沙里冒头、岩面边缘是碎的。返回 b 那层的权重。"""
    A = g.m("ADD", ha, g.m("SUBTRACT", 1.0, a)); B = g.m("ADD", hb, a)
    top = g.m("SUBTRACT", g.m("MAXIMUM", A, B), depth)
    wa = g.m("MAXIMUM", g.m("SUBTRACT", A, top), 0.0); wb = g.m("MAXIMUM", g.m("SUBTRACT", B, top), 0.0)
    return g.m("DIVIDE", wb, g.m("ADD", g.m("ADD", wa, wb), 1e-6))


def ortho_products(nd):
    """0.5 m 正射 → R＝低通明暗（σ 4 px ≈ 2 m，按有效区归一）、G＝石块度（σ 2 m 以下高频起伏的局部均方根，σ 8 px，
    中位数归到 0.5）。HiRISE 0.5 m 上的亮暗斑点基本是 0.5–2 m 的石块和影子（Golombek 等就是数影子定石块丰度），
    不该当颜色，只当丰度用。结果缓存成 near_ortho_lp.npy。"""
    path = nd/"near_ortho_lp.npy"
    if path.exists(): return np.load(path)
    o = np.load(nd/"near_ortho.npy").astype(np.float32)/255.0
    v = (o > 0.004).astype(np.float32)
    nv = np.maximum(smooth_dtm(v, 4.0), 1e-3)
    lp = smooth_dtm(o*v, 4.0)/nv
    hp2 = ((o - lp)**2)*v
    rough = np.sqrt(smooth_dtm(hp2, 8.0)/np.maximum(smooth_dtm(v, 8.0), 1e-3))
    med = np.median(rough[v > 0])
    out = np.zeros(o.shape + (3,), np.uint8)
    out[..., 0] = np.where(v > 0, np.clip(lp*255, 2, 255), 0)
    out[..., 1] = np.clip(0.5*rough/med*255, 0, 255)
    np.save(path, out); log(f"正射低通 + 石块度 → {path.name}")
    return out


def ground_material(name, patch, scans, img_o, img_m):
    """浮土 / 基岩两层，按 8 m 坡度 + 正射亮度 + 噪声定掩膜，按扫描高度做高度混合。
    patch：投影网格，扫描高度当真位移（EEVEE 也是逐顶点位移）；否则只当凹凸，并在 30–90 m 视距淡出（亚像素凹凸只会成噪点）。"""
    mat = bpy.data.materials.new(name)
    mat.displacement_method = "DISPLACEMENT" if patch else "BUMP"
    g = G(mat.node_tree)
    out = g.n("ShaderNodeOutputMaterial")
    geo = g.n("ShaderNodeNewGeometry"); camd = g.n("ShaderNodeCameraData")
    uvm = g.n("ShaderNodeUVMap", uv_map="UVMap"); uvo = g.n("ShaderNodeUVMap", uv_map="正射")
    at_s = g.n("ShaderNodeAttribute", attribute_name="坡度")
    P_ = geo.outputs["Position"]; D = camd.outputs["View Distance"]
    pxyz = sep(g, P_)
    P2 = comb(g, g.m("MULTIPLY", pxyz[0], 1000.0), g.m("MULTIPLY", pxyz[1], 1000.0), 0.0)   # 当地水平坐标（m）

    def otex(img, uvsock, ext):
        t = g.n("ShaderNodeTexImage", image=img, interpolation="Cubic", extension=ext); g.link(uvsock, t.inputs["Vector"])
        bw = g.n("ShaderNodeRGBToBW"); g.link(t.outputs["Color"], bw.inputs[0]); return bw.outputs[0]
    t5 = g.n("ShaderNodeTexImage", image=img_o, interpolation="Cubic", extension="CLIP"); g.link(uvo.outputs["UV"], t5.inputs["Vector"])
    s5 = g.n("ShaderNodeSeparateColor"); g.link(t5.outputs["Color"], s5.inputs[0])
    o5, rough5 = s5.outputs[0], s5.outputs[1]                              # 正射低通明暗、石块度（见 ortho_products）
    o2 = otex(img_m, uvm.outputs["UV"], "EXTEND")
    has5 = g.m("GREATER_THAN", o5, 0.004)
    ortho = lerp(g, o2, o5, has5)                                          # 中位约 0.57
    stony = lerp(g, 0.5, rough5, has5)                                     # 0.5＝一般，1＝石块很多

    l_tr, h_tr, b_tr = hex_sample(g, P2, *scans["浮土"], 1, D)
    l_dr, h_dr, b_dr = hex_sample(g, P2, *scans["细砂"], 2, D)
    l_rk, h_rk, b_rk = hex_sample(g, P2, *scans["基岩"], 3, D)
    l_md, _, _ = hex_sample(g, P2, *scans["中景"], 4)
    l_cb, h_cb, _ = hex_sample(g, P2, scans["浮土"][0], 9.0, 5)            # 浮土放大 4.5 倍＝10–20 cm 的卵石：20–500 m 的中景尺度
    w_cb = g.m("MULTIPLY", g.maprange(D, 0.015, 0.05), g.m("SUBTRACT", 1.0, g.maprange(D, 0.3, 0.6)))
    w_cb = g.m("MULTIPLY", w_cb, g.m("ADD", 0.3, g.m("MULTIPLY", stony, 1.4)))   # 石块多的地方卵石层强
    # 掩膜：坡陡（8 m 尺度）、正射亮 ⇒ 基岩；25 m、4 m 噪声打碎边界
    rk = g.m("ADD", g.maprange(at_s.outputs["Fac"], 18.0, 34.0, 0.0, 0.7), g.maprange(ortho, 0.62, 0.85, 0.0, 0.45))
    rk = g.m("ADD", rk, g.m("ADD", g.m("MULTIPLY", g.m("SUBTRACT", g.noise(P2, 1/25.0, 3), 0.5), 0.7),
                            g.m("MULTIPLY", g.m("SUBTRACT", g.noise(P2, 1/4.0, 3), 0.5), 0.3)))
    rmask = g.m("MAXIMUM", g.m("MINIMUM", rk, 1.0), 0.0)
    dmask = g.maprange(g.noise(P2, 1/9.0, 3), 0.45, 0.62)
    w_dr = height_blend(g, h_tr, h_dr, dmask, 0.2)
    l_rg, h_rg = lerp(g, l_tr, l_dr, w_dr), lerp(g, h_tr, h_dr, w_dr)
    w_rk = height_blend(g, h_rg, h_rk, rmask, 0.15)
    lum = lerp(g, l_rg, l_rk, w_rk)
    a_rg = lerp(g, AMP["浮土"], AMP["细砂"], w_dr)                         # 实测起伏（m）
    amp = lambda hr, hk_: lerp(g, g.m("MULTIPLY", g.m("SUBTRACT", hr, 0.5), a_rg), g.m("MULTIPLY", g.m("SUBTRACT", hk_, 0.5), AMP["基岩"]), w_rk)
    hm = amp(h_rg, h_rk)                                                   # m
    if patch:                                                              # 位移只要低通的那部分，细的走凹凸（叠在位移后的法线上）
        dw = g.n("ShaderNodeAttribute", attribute_name="细节").outputs["Fac"]
        hb_ = amp(lerp(g, b_tr, b_dr, w_dr), b_rk)
        disp, bump_h = g.m("ADD", hb_, 0.01), g.m("SUBTRACT", hm, hb_)   # 抬 1 cm：大半在 HiRISE 网格上面
    else:
        dw = g.m("SUBTRACT", 1.0, g.maprange(D, 0.03, 0.09))
        cob = g.m("MULTIPLY", g.m("MULTIPLY", g.m("SUBTRACT", h_cb, 0.5), 0.22), g.m("SUBTRACT", 1.0, w_rk))   # 卵石起伏 22 cm（基岩上不要）
        disp, bump_h = g.m("ADD", hm, g.m("DIVIDE", g.m("MULTIPLY", cob, w_cb), g.m("MAXIMUM", dw, 0.001))), None   # 下面会乘 dw，先除掉
    dn = g.n("ShaderNodeDisplacement", space="OBJECT")
    g.link(g.m("MULTIPLY", g.m("MULTIPLY", disp, 0.001), dw), dn.inputs["Height"])
    dn.inputs["Midlevel"].default_value = 0; dn.inputs["Scale"].default_value = 1
    g.link(dn.outputs[0], out.inputs["Displacement"])

    # 颜色：岩性底色 × HiRISE 明暗 × 扫描亮度（只取亮度：颜色不会带上地球的土色）
    pc = g.v("ADD", P_, (0.0, 0.0, R)); hk = g.m("SUBTRACT", g.v("LENGTH", pc), R)
    ILD = (0.215, 0.152, 0.110, 1); ILD2 = (0.190, 0.136, 0.100, 1); REG = (0.20, 0.118, 0.075, 1); DUSTY = (0.235, 0.135, 0.085, 1)
    lay = g.m("FRACT", g.m("DIVIDE", g.m("ADD", hk, g.m("MULTIPLY", g.m("SUBTRACT", g.noise(P2, 1/50.0, 3), 0.5), 0.0015)), 0.0023))
    bedc = g.mix(g.maprange(lay, 0.45, 0.6), ILD, ILD2)                    # 层状沉积：2.3 m 一层的色带，顺真实等高线走
    regc = g.mix(g.noise(P2, 1/30.0, 4), REG, DUSTY)
    c = g.mix(w_rk, regc, bedc)
    # HiRISE 明暗（低通到 2 m）：一半直接乘；另一半当掩膜，经扫描高度做高度混合，切成「亮浮尘 / 暗碎石」两态
    # （0.5 m 的原始斑点多是石块和它的影子，直接当颜色会在掠射下拉成横条；它只用来定「这里石头多不多」）
    c = g.rgb_mul(c, g.m("POWER", g.m("MAXIMUM", g.m("DIVIDE", ortho, 0.57), 0.2), 0.6))
    h_mx = lerp(g, lerp(g, h_rg, h_rk, w_rk), h_cb, w_cb)
    m_o = g.m("ADD", 0.5, g.m("MULTIPLY", g.m("SUBTRACT", ortho, 0.57), 2.5))
    m_o = g.m("MAXIMUM", g.m("MINIMUM", g.m("SUBTRACT", m_o, g.m("MULTIPLY", g.m("SUBTRACT", stony, 0.5), 0.8)), 1.0), 0.0)   # 石块多 ⇒ 暗碎石多
    w_br = height_blend(g, g.m("SUBTRACT", 1.0, h_mx), h_mx, m_o, 0.08)   # 亮的（浮尘）落在低处、暗的（碎石）在高处
    c = g.rgb_mul(c, lerp(g, 0.78, 1.22, w_br))
    c = g.rgb_mul(c, g.m("DIVIDE", lum, 0.5))
    c = g.rgb_mul(c, g.m("ADD", 0.5, l_md))                              # 11 m 尺度的明暗起伏（均值 1）
    c = g.rgb_mul(c, g.m("ADD", 1.0, g.m("MULTIPLY", g.m("SUBTRACT", l_cb, 0.5), g.m("MULTIPLY", w_cb, 1.4))))   # 中景卵石的明暗
    bsdf = g.n("ShaderNodeBsdfDiffuse"); bsdf.inputs["Roughness"].default_value = 1.0
    g.link(c, bsdf.inputs["Color"]); g.link(bsdf.outputs[0], out.inputs["Surface"])
    if bump_h is not None:
        bp = g.n("ShaderNodeBump"); bp.inputs["Strength"].default_value = 1.0; bp.inputs["Distance"].default_value = 1.0
        g.link(g.m("MULTIPLY", g.m("MULTIPLY", bump_h, 0.001), dw), bp.inputs["Height"]); g.link(bp.outputs[0], bsdf.inputs["Normal"])
    return mat


def _cam_state(shot, F, nd, meta):
    nh = np.load(nd/"near_hgt.npy", mmap_mode="r")
    geo = NearGeo(meta); lon, lat = shot["cam"][:2]
    r, c = geo.rowcol(lon, lat, meta["T"])
    gnd = float(R51.bilinear(np.asarray(nh[..., 0]), np.array([r - meta["rows"][0]]), np.array([c]))[0])
    shot2 = dict(shot, cam=(lon, lat, gnd + shot["agl"]))
    return shot2, K.camera(shot2, F), K.sun_dir(shot2, F)


def camera_and_light(shot, F, nd, meta):
    nh = np.load(nd/"near_hgt.npy", mmap_mode="r")
    geo = NearGeo(meta)
    lon, lat = shot["cam"][:2]
    r, c = geo.rowcol(lon, lat, meta["T"])
    gnd = float(R51.bilinear(np.asarray(nh[..., 0]), np.array([r - meta["rows"][0]]), np.array([c]))[0])
    shot = dict(shot, cam=(lon, lat, gnd + shot["agl"]))
    log(f"相机：地面 {gnd*1000:.1f} m，离地 {shot['agl']*1000:.1f} m")
    cam = R51.place_camera(shot, F, None)
    bpy.context.scene.camera.data.clip_start = 0.0002
    sun = K.sun_dir(shot, F)
    atm = AT.Atmosphere()
    origin = F.pos(lon, lat, R + gnd) - F.C
    env, E_sun, E_sky = AT.env_map(atm, origin, sun)
    bg = R51.world_env(env)
    sun_ob = R51.place_sun(sun)
    Ts = atm.transmittance(np.array([gnd]), np.array([float(origin @ sun/np.linalg.norm(origin))]))[0]
    sun_ob.data.color = tuple(float(v) for v in Ts/Ts.max()); sun_ob.data.energy = float(Ts.max())   # 界面预览用：地面的太阳色
    return shot, cam, sun, sun_ob, bg, atm


# ── 石块（NASA PDS 毅力号实拍）─────────────────────────────────────────
ROCK_BANDS = ((0.04, 0.15, 0.025), (0.15, 0.40, 0.070), (0.40, 1.50, 0.180))   # 直径段（m）、撒到多远（km）：小石头只撒近处
ROCK_K = 0.12                               # Golombek 石块总覆盖率上限；再按正射「石块度」抽稀（平均约 0.06，火星着陆区常见 0.05–0.1）


def rock_material():
    """实拍颜色（顶点色）+ 朝上的面落一层浮尘 + 细凹凸。"""
    mat = bpy.data.materials.new("石块")
    g = G(mat.node_tree)
    out = g.n("ShaderNodeOutputMaterial")
    at = g.n("ShaderNodeAttribute", attribute_name="色", attribute_type="GEOMETRY")
    geo = g.n("ShaderNodeNewGeometry"); tc = g.n("ShaderNodeTexCoord")
    up = sep(g, geo.outputs["Normal"])[2]
    dust = g.m("MULTIPLY", g.maprange(up, 0.55, 0.95), g.m("ADD", 0.15, g.m("MULTIPLY", g.noise(tc.outputs["Object"], 6.0, 4), 0.35)))
    c = g.mix(dust, at.outputs["Color"], (0.235, 0.135, 0.085, 1))
    bump = g.n("ShaderNodeBump"); bump.inputs["Strength"].default_value = 0.35; bump.inputs["Distance"].default_value = 0.02
    g.link(g.noise(tc.outputs["Object"], 25.0, 8, 0.6), bump.inputs["Height"])
    bs = g.n("ShaderNodeBsdfDiffuse"); bs.inputs["Roughness"].default_value = 0.9
    g.link(c, bs.inputs["Color"]); g.link(bump.outputs[0], bs.inputs["Normal"]); g.link(bs.outputs[0], out.inputs["Surface"])
    return mat


def rock_library(nmax=40):
    """54 的石块库 → 2.5D 高度场网格原型（归一到直径 1，约 1500 顶点），底边往下补一圈裙边埋进地里。
    颜色是 Navcam 照片，自带当时的太阳明暗：围绕均值压一半反差，免得和场景光照打架。"""
    src = R51.CACHE/"_素材"/"PDS"/"素材"/"石块库.npz"
    z = np.load(src); n = min(int(z["n"]), nmax); px = float(z["px"])
    coll = bpy.data.collections.new("石块原型")                             # 不挂进场景：只给实例用
    mat = rock_material()
    for i in range(n):
        h = z[f"r{i}_h"].astype(np.float64); m = z[f"r{i}_mask"]; col = z[f"r{i}_col"].astype(np.float32); d = float(z["d"][i])
        st = max(1, int(math.sqrt(m.sum()/1500)))
        h, m, col = h[::st, ::st], m[::st, ::st], col[::st, ::st]
        ring = np.zeros_like(m)
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1), (1, -1), (-1, 1)):
            ring |= np.roll(np.roll(m, dy, 0), dx, 1)
        ring &= ~m
        kv = m | ring
        zz = np.where(m, h, -0.15*h.max())                                 # 裙边埋下去
        ny, nx = h.shape; iy, ix = np.mgrid[0:ny, 0:nx]
        cy, cx = np.argwhere(m).mean(0)
        P = np.stack([(ix - cx)*px*st/d, -(iy - cy)*px*st/d, zz/d], -1)[::-1]   # 第 0 行在北 → grid_mesh 要南
        k = kv[::-1]; keep = k[:-1, :-1] & k[1:, :-1] & k[:-1, 1:] & k[1:, 1:]
        ob = R51.grid_mesh(f"石块_{i:02d}", P, keep=keep)
        bpy.context.scene.collection.objects.unlink(ob); coll.objects.link(ob)
        me = ob.data
        ny_, nx_ = P.shape[:2]
        ii, jj = np.meshgrid(np.arange(ny_ - 1), np.arange(nx_ - 1), indexing="ij")
        q = np.stack([ii*nx_ + jj, ii*nx_ + jj + 1, (ii + 1)*nx_ + jj + 1, (ii + 1)*nx_ + jj], -1).reshape(-1, 4)[keep.ravel()]
        used = np.unique(q)
        cm = col[m].mean(0); c2 = np.clip(cm + 0.5*(col - cm), 0, 1)[::-1].reshape(-1, 3)[used]
        ca = me.color_attributes.new("色", "FLOAT_COLOR", "POINT")
        ca.data.foreach_set("color", np.concatenate([c2, np.ones((len(used), 1))], 1).astype(np.float32).ravel())
        me.materials.append(mat)
    log(f"石块原型 {n} 块（NASA PDS Navcam 实拍）")
    return coll, n


def scatter_rocks(F, C, nd):
    """Golombek 模型（F(D)＝k·e^(−qD)，q＝1.79＋0.152/k）按直径段撒在相机前方 ±55° 扇形里，按 0.5 m 正射的石块度抽稀。"""
    coll, nproto = rock_library()
    rng = np.random.default_rng(11)
    lp = ortho_products(nd); oh, ow = lp.shape[:2]
    q = 1.79 + 0.152/ROCK_K
    Fk = lambda D: ROCK_K*np.exp(-q*D)
    A = math.radians(55)
    xs = []
    for d0, d1, rmax in ROCK_BANDS:
        edges = np.geomspace(d0, d1, 12)
        for a_, b_ in zip(edges[:-1], edges[1:]):
            dm = math.sqrt(a_*b_); area = A*(rmax*1000)**2                  # 扇形面积（m²）
            nrock = rng.poisson((Fk(a_) - Fk(b_))*area/(math.pi*dm*dm/4))
            D = rng.uniform(a_, b_, nrock)
            r = rmax*np.sqrt(rng.uniform(0.0004, 1, nrock)); t = rng.uniform(-A, A, nrock) + C.heading
            xs.append((D, r*np.sin(t), r*np.cos(t)))
    D = np.concatenate([x[0] for x in xs]); dx = np.concatenate([x[1] for x in xs]); dy = np.concatenate([x[2] for x in xs])
    rr = C.cr - dy/C.px; cc = C.cc + dx/(C.px*C.kx)
    ok = (rr > 2) & (rr < C.rows - 3) & (cc > 2) & (cc < C.cols - 3)
    D, rr, cc = D[ok], rr[ok], cc[ok]
    lon, lat, _, uvo = C.uvs(rr, cc)
    oi = np.clip(((1 - uvo[:, 1])*oh - 0.5).astype(int), 0, oh - 1); oj = np.clip((uvo[:, 0]*ow - 0.5).astype(int), 0, ow - 1)
    stony = lp[oi, oj, 1]/255.0
    keep = rng.uniform(0, 1, len(D)) < np.clip(stony, 0.05, 1)            # 石块度 0.5 ⇒ 留一半
    D, rr, cc, lon, lat = D[keep], rr[keep], cc[keep], lon[keep], lat[keep]
    Z = bspline_sample(C.zs, rr, cc) - 0.15*D/1000                          # 埋进去 15%
    P = F.pos(lon, lat, R + Z)
    me = bpy.data.meshes.new("石块点")
    me.vertices.add(len(P)); me.vertices.foreach_set("co", P.astype(np.float32).ravel())
    rot = np.zeros((len(P), 3), np.float32); rot[:, 2] = rng.uniform(0, 2*math.pi, len(P))
    for name, typ, dom, val, arr in (("rot", "FLOAT_VECTOR", "POINT", "vector", rot.ravel()),
                                     ("scl", "FLOAT", "POINT", "value", (D/1000).astype(np.float32)),
                                     ("kind", "INT", "POINT", "value", rng.integers(0, nproto, len(P)).astype(np.int32))):
        at = me.attributes.new(name, typ, dom); at.data.foreach_set(val, arr)
    ob = bpy.data.objects.new("石块", me); bpy.context.scene.collection.objects.link(ob)
    ng = bpy.data.node_groups.new("撒石", "GeometryNodeTree")
    ng.interface.new_socket("Geometry", in_out="INPUT", socket_type="NodeSocketGeometry")
    ng.interface.new_socket("Geometry", in_out="OUTPUT", socket_type="NodeSocketGeometry")
    N = ng.nodes; L = ng.links
    gi = N.new("NodeGroupInput"); go = N.new("NodeGroupOutput")
    ci = N.new("GeometryNodeCollectionInfo"); ci.inputs["Collection"].default_value = coll
    ci.inputs["Separate Children"].default_value = True; ci.inputs["Reset Children"].default_value = True
    io = N.new("GeometryNodeInstanceOnPoints"); io.inputs["Pick Instance"].default_value = True
    na = {}
    for nm, dt in (("kind", "INT"), ("rot", "FLOAT_VECTOR"), ("scl", "FLOAT")):
        na[nm] = N.new("GeometryNodeInputNamedAttribute"); na[nm].data_type = dt; na[nm].inputs["Name"].default_value = nm
    er = N.new("FunctionNodeEulerToRotation")
    L.new(gi.outputs[0], io.inputs["Points"]); L.new(ci.outputs[0], io.inputs["Instance"])
    L.new(na["kind"].outputs["Attribute"], io.inputs["Instance Index"])
    L.new(na["rot"].outputs["Attribute"], er.inputs[0]); L.new(er.outputs[0], io.inputs["Rotation"])
    L.new(na["scl"].outputs["Attribute"], io.inputs["Scale"])
    L.new(io.outputs[0], go.inputs[0])
    ob.modifiers.new("撒石", "NODES").node_group = ng
    log(f"撒石 {len(P):,} 块（Golombek k≤{ROCK_K}，按石块度抽稀），{nproto} 种原型")
    return ob


# ── 远景 ───────────────────────────────────────────────────────────
def fuse_dem(hgt, region, nd, meta):
    """DEM 融合（HiRISE 嵌进 HRSC）：HiRISE 范围里远景高度换成 HiRISE 的块平均，范围外把高差（HiRISE − HRSC）
    用归一化高斯卷积往外延、约 2 km 内衰减到零。HRSC 200 m 把坡脚抹高了，这里能差 170 m 以上，只靠下沉压不住。"""
    nh = np.load(nd/"near_hgt.npy", mmap_mode="r")
    b = 8                                                                  # 先 8×8 块平均到 16 m，再按远景格点双线性取
    rows, cols = (nh.shape[0]//b)*b, (nh.shape[1]//b)*b
    zb = np.asarray(nh[:rows, :cols, 0]).reshape(rows//b, b, cols//b, b).mean((1, 3))
    eb = np.asarray(nh[:rows, :cols, 1]).reshape(rows//b, b, cols//b, b).max((1, 3))
    lon0, lon1, lat0, lat1 = region
    ny, nx = hgt.shape
    lat = lat0 - (np.arange(ny) + 0.5)*(lat0 - lat1)/ny; lon = lon0 + (np.arange(nx) + 0.5)*(lon1 - lon0)/nx
    LO, LA = np.meshgrid(lon, lat)
    rr, cc = NearGeo(meta).rowcol(LO, LA, meta["T"])
    fi = (rr - meta["rows"][0] - (b - 1)/2)/b; fj = (cc - (b - 1)/2)/b
    out = (fi < 0) | (fi > zb.shape[0] - 1) | (fj < 0) | (fj > zb.shape[1] - 1)
    zn = R51.bilinear(zb, fi, fj); en = np.where(out, 1.0, R51.bilinear(eb, fi, fj))
    w = np.clip((0.9 - en)/0.9, 0, 1)                                      # 1＝HiRISE 里头，0＝外面
    m = (w > 0.5).astype(np.float64); d = np.where(m > 0, zn - hgt, 0.0)
    s = R51.gauss_blur(np.stack([d*m, m, m], -1), 3.0)                     # 3 格 ≈ 700 m
    ext = s[..., 0]/np.maximum(s[..., 1], 1e-6)
    fall = np.clip(R51.gauss_blur(np.stack([m, m, m], -1), 8.0)[..., 0]*2.5, 0, 1)
    fused = w*zn + (1 - w)*(hgt + ext*fall)
    log(f"DEM 融合：HiRISE − HRSC 高差 均值 {d[m > 0].mean()*1000:.0f} m，最大 {np.abs(d[m > 0]).max()*1000:.0f} m")
    return fused.astype(np.float32)


def far_terrain(F, shot, nd, meta, dicing):
    """50 的 HRSC/CTX 大地形；HiRISE 覆盖到的地方按顶点压低 60 m（边上渐变），让近景网格露出来。
    不挖洞：挖洞会和近景的裙边对不上，漏出天空。"""
    full = K.REGIONS[shot["data"]]
    cdir = R51.CACHE/shot["data"]
    # 只裁相机周围 4.5°×3.5°（贴图与网格都只要这一块；对齐到 128 px/度 的格子，256、512 的也就对齐了）
    L0, _, A0, _ = full; p = K.PPD
    clon, clat = shot["cam"][:2]
    j0, j1 = int(math.floor((clon - 2.25 - L0)*p)), int(math.ceil((clon + 2.25 - L0)*p))
    i0, i1 = int(math.floor((A0 - (clat + 1.75))*p)), int(math.ceil((A0 - (clat - 1.75))*p))
    region = (L0 + j0/p, L0 + j1/p, A0 - i0/p, A0 - i1/p)
    crop = lambda a, k: np.ascontiguousarray(a[i0*k:i1*k, j0*k:j1*k])
    hgt = crop(np.load(cdir/"hgt.npy", mmap_mode="r"), 2); aux = crop(np.load(cdir/"aux.npy", mmap_mode="r"), 1).copy()
    hgt = fuse_dem(hgt, region, nd, meta)
    col = crop(np.load(cdir/"col.npy", mmap_mode="r"), 1); ctx = crop(np.load(cdir/"ctx.npy", mmap_mode="r"), 4)
    nh = np.load(nd/"near_hgt.npy", mmap_mode="r"); edge = np.asarray(nh[..., 1])
    geo = NearGeo(meta); r0 = meta["rows"][0]
    lon0, lon1, lat0, lat1 = region
    ny, nx = aux.shape[:2]
    lat = lat0 - (np.arange(ny) + 0.5)/(ny/(lat0 - lat1)); lon = lon0 + (np.arange(nx) + 0.5)/(nx/(lon1 - lon0))
    # 只算 HiRISE 附近那一小块
    LON, LAT = np.meshgrid(lon, lat)
    rr, cc = geo.rowcol(LON, LAT, meta["T"])
    near = (rr > -500) & (rr < edge.shape[0] + r0 + 500) & (cc > -500) & (cc < edge.shape[1] + 500)
    inside = np.zeros((ny, nx), bool)
    half = 0.5/(nx/(lon1 - lon0))
    for dlon, dlat in ((0, 0), (-half, -half), (half, -half), (-half, half), (half, half)):   # 像元中心 + 四角都在里面才算
        r_, c_ = geo.rowcol(LON + dlon, LAT + dlat, meta["T"])
        ri = np.round(r_ - r0).astype(int); ci = np.round(c_).astype(int)
        ok = near & (ri >= 0) & (ri < edge.shape[0]) & (ci >= 0) & (ci < edge.shape[1])
        e = np.ones((ny, nx)); e[ok] = edge[ri[ok], ci[ok]]
        inside = inside & (e < 0.3) if dlon or dlat else (e < 0.3)
    aux[..., 2] = np.where(inside, 0.06, 0.0)
    log(f"远景：HiRISE 范围内压低 {int(inside.sum())} 个 463 m 像元")
    hgt_img = R51.file_image("高程", hgt, "f32"); aux_img = R51.file_image("坡度水位", aux, "half")
    col_img = R51.file_image("底色", col, "half"); ctx_img = R51.file_image("CTX", ctx, "u8")
    nx_, ny_ = R51.MESH_N                                                  # 1280×896 铺 4.5°×3.5°：约 210 m 一格
    vlon = np.linspace(region[0], region[1], nx_); vlat = np.linspace(region[3], region[2], ny_)
    VLO, VLA = np.meshgrid(vlon, vlat)
    vr, vc = geo.rowcol(VLO, VLA, meta["T"])                              # 顶点处的 HiRISE 裙边值：0＝深入 150 m 以上
    vri = np.round(vr - r0).astype(int); vci = np.round(vc).astype(int)
    okv = (vri >= 0) & (vri < edge.shape[0]) & (vci >= 0) & (vci < edge.shape[1])
    ev = np.ones(VLO.shape); ev[okv] = edge[vri[okv], vci[okv]]
    sink_v = (0.1*np.clip((0.9 - ev)/0.9, 0, 1)).astype(np.float32)        # HiRISE 里压低 100 m（融合后两者同高，再让出 2 m 网格比 200 m 网格多出的起伏），边上渐变
    ob = R51.terrain(F, region, hgt_img, aux_img, col_img, ctx_img, dicing, hgt=hgt, sink=sink_v)
    log(f"远景：{int((sink_v > 0.03).sum())} 个顶点压低（不挖洞）")
    R51.water(F, full, shot["data"])
    return ob


# ── 渲染（Cycles 三遍 + 51 的大气后期）──────────────────────────────
def _restore(saved, n_before):
    """位置遍改过的材质换回来（出错也要换，不然会被存进 .blend）。"""
    for mat, surf, vol in saved:
        nt = mat.node_tree
        for n in [n for n in nt.nodes if n.name not in n_before[mat.name]]: nt.nodes.remove(n)
        out = next(n for n in nt.nodes if n.bl_idname == "ShaderNodeOutputMaterial")
        for sck in surf: nt.links.new(sck, out.inputs["Surface"])
        for sck in vol: nt.links.new(sck, out.inputs["Volume"])


def render(shot2, F, cam, sun, atm, res, samples, tag):
    sc = bpy.context.scene
    sc.render.resolution_x, sc.render.resolution_y = res
    sc.cycles.samples = samples; sc.cycles.use_denoising = True; sc.cycles.use_adaptive_sampling = True
    sc.cycles.max_bounces = 8
    sc.cycles.max_subdivisions = 8                                         # 近景 8 m 网格最细 3 cm；更小的石子是单独的石块模型
    sc.cycles.offscreen_dicing_scale = 32.0                                # 相机背后、画面外的近地网格不必细切
    sc.render.film_transparent = True
    s_ = sc.render.image_settings; s_.media_type = "MULTI_LAYER_IMAGE"; s_.file_format = "OPEN_EXR_MULTILAYER"; s_.color_depth = "32"
    bg = sc.world.node_tree.nodes["Background"] if "Background" in sc.world.node_tree.nodes else \
        next(n for n in sc.world.node_tree.nodes if n.bl_idname == "ShaderNodeBackground")
    sun_ob = bpy.data.objects["太阳"]
    keep_col, keep_e = tuple(sun_ob.data.color), sun_ob.data.energy
    vs = sc.view_settings; keep_vt, keep_ex = vs.view_transform, vs.exposure
    vs.view_transform = "Standard"; vs.exposure = 0.0                      # EXR 存线性，不受影响；这里只是保险
    cdir = R51.CACHE/SHOT
    ex = {k: cdir/f"{SHOT}_{k}{tag}.exr" for k in ("A_太阳", "B_天光", "C_位置")}
    shading = []                                                           # 渲染时视口切实体模式，腾出显存
    for win in bpy.context.window_manager.windows:
        for area in win.screen.areas:
            for sp in area.spaces:
                if sp.type == "VIEW_3D": shading.append((sp, sp.shading.type)); sp.shading.type = "SOLID"
    t0 = time.time()
    sun_ob.data.color = (1, 1, 1); sun_ob.data.energy = 1.0; sun_ob.hide_render = False
    bg.inputs["Strength"].default_value = 0.0
    sc.render.filepath = str(ex["A_太阳"]); bpy.ops.render.render(write_still=True)
    sun_ob.hide_render = True; bg.inputs["Strength"].default_value = 1.0
    sc.render.filepath = str(ex["B_天光"]); bpy.ops.render.render(write_still=True)
    # C：表面临时换成位置发光，渲完换回来
    saved = []
    for mat in bpy.data.materials:
        nt = mat.node_tree
        out = next(n for n in nt.nodes if n.bl_idname == "ShaderNodeOutputMaterial")
        saved.append((mat, [l.from_socket for l in out.inputs["Surface"].links], [l.from_socket for l in out.inputs["Volume"].links]))
    n_before = {m.name: set(n.name for n in m.node_tree.nodes) for m in bpy.data.materials}
    bg.inputs["Strength"].default_value = 0.0
    keep_s = (sc.cycles.samples, sc.cycles.use_denoising, sc.cycles.use_adaptive_sampling)
    R51.position_mode()
    try:
        sc.render.filepath = str(ex["C_位置"]); bpy.ops.render.render(write_still=True)
    finally:
        _restore(saved, n_before)
    sc.cycles.samples, sc.cycles.use_denoising, sc.cycles.use_adaptive_sampling = keep_s
    sc.cycles.max_bounces = 8
    sun_ob.hide_render = False; sun_ob.data.color = keep_col; sun_ob.data.energy = keep_e
    bg.inputs["Strength"].default_value = 1.0
    vs.view_transform, vs.exposure = keep_vt, keep_ex
    for sp, t in shading: sp.shading.type = t
    log(f"三遍渲染 {time.time() - t0:.0f} s")
    lin, png, key = R51.post(shot2, F, atm, sun, cam, ex["A_太阳"], ex["B_天光"], ex["C_位置"])
    R51.OUT.mkdir(parents=True, exist_ok=True)
    out = R51.OUT/f"{SHOT}{tag}.png"
    R51.write_png(out, png)
    # 渲完在界面里打开看
    img = bpy.data.images.get(out.name) or bpy.data.images.load(str(out), check_existing=True)
    img.reload()
    log(f"→ {out}")
    return out


# ── EEVEE（游戏式：米级真实网格 + 厘米级凹凸，实时光栅化）──────────────
def to_eevee():
    """去掉自适应细分，位移全部改成凹凸：几何只到网格分辨率，细节靠法线。显存小一个数量级，视口「渲染」模式就是成片。"""
    for o in bpy.data.objects:
        for m in list(o.modifiers):
            if m.type == "SUBSURF" and m.use_adaptive_subdivision: o.modifiers.remove(m)
    for mat in bpy.data.materials:
        if mat.name != "地面_贴地": mat.displacement_method = "BUMP"      # 投影网格保留真位移（EEVEE 逐顶点）
    far = bpy.data.materials.get("火星地表")                               # 远景的位移是「纹理 − 网格」的残差 + 千米级程序起伏：
    if far:                                                                # 当凹凸用会把法线拧歪（整面发黑），EEVEE 只用网格本身的形状
        for l in list(far.node_tree.links):
            if l.to_node.bl_idname == "ShaderNodeOutputMaterial" and l.to_socket.name == "Displacement": far.node_tree.links.remove(l)
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_EEVEE"
    e = sc.eevee
    e.taa_render_samples = 64; e.taa_samples = 16
    e.use_raytracing = True; e.ray_tracing_method = "SCREEN"
    e.use_fast_gi = True
    e.use_shadows = True; e.shadow_ray_count = 3; e.shadow_step_count = 8; e.shadow_resolution_scale = 1.0
    sun = bpy.data.objects.get("太阳")
    if sun:
        sun.data.angle = math.radians(0.35)
        if hasattr(sun.data, "shadow_maximum_resolution"): sun.data.shadow_maximum_resolution = 0.000002  # 2 mm（场景单位 km）：碎石的影子
        if hasattr(sun.data, "use_shadow_jitter"): sun.data.use_shadow_jitter = True
    vs = sc.view_settings; vs.view_transform = "AgX"; vs.exposure = 2.4
    sc.render.film_transparent = False


def render_eevee(res, tag):
    sc = bpy.context.scene
    sc.render.resolution_x, sc.render.resolution_y = res; sc.render.resolution_percentage = 100
    s_ = sc.render.image_settings; s_.media_type = "IMAGE"; s_.file_format = "PNG"; s_.color_depth = "8"; s_.color_mode = "RGB"
    out = R51.OUT/f"{SHOT}_EEVEE{tag}.png"; R51.OUT.mkdir(parents=True, exist_ok=True)
    sc.render.filepath = str(out)
    t0 = time.time(); bpy.ops.render.render(write_still=True)
    log(f"EEVEE {time.time() - t0:.0f} s → {out}")
    return out


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--step", default="terrain", choices=("terrain", "far", "rocks", "all", "render", "save"))
    ap.add_argument("--device", default="GPU", choices=("GPU", "CPU"))
    ap.add_argument("--engine", default="eevee", choices=("eevee", "cycles"))
    ap.add_argument("--dicing", type=float, default=1.5)
    ap.add_argument("--res", default="1920x1080")
    ap.add_argument("--samples", type=int, default=128)
    arg = ap.parse_args(argv)
    shot = K.SHOTS[SHOT]
    region = K.REGIONS[shot["data"]]
    F = K.Frame(region, center=shot["cam"][:2])
    nd = R51.CACHE/SHOT
    meta = json.loads((nd/"near.json").read_text())
    t0 = time.time()
    global ENGINE
    ENGINE = arg.engine
    if arg.step in ("terrain", "all"):
        clear_scene()
        R51.setup_render((1920, 1080), 64, arg.dicing)
        C = NearCtx(nd, meta, shot)
        ob = near_terrain(F, C); fan = fan_patch(F, C)
        scans = scan_images()
        img_o = R51.file_image("近景正射_低通石块度", ortho_products(nd), "u8")
        img_m = R51.file_image("近景材质_o", np.ascontiguousarray(np.load(nd/"near_mat.npy", mmap_mode="r")[..., 0]), "u8")   # 正射 2 m（0.5 m 没覆盖处）
        ob.data.materials.append(ground_material("地面_HiRISE", False, scans, img_o, img_m))
        fan.data.materials.append(ground_material("地面_贴地", True, scans, img_o, img_m))
        del C
        shot2, cam, sun, sun_ob, bg, atm = camera_and_light(shot, F, nd, meta)
        try: setup_viewport(cam)
        except Exception as ex: log("视口设置跳过：", ex)
    if arg.step in ("far", "all"):
        for o in [o for o in bpy.data.objects if o.name in ("地形", "水")]: bpy.data.objects.remove(o)
        far_terrain(F, shot, nd, meta, arg.dicing)
    if arg.step in ("rocks", "all") and (R51.CACHE/"_素材"/"PDS"/"素材"/"石块库.npz").exists():   # NASA 实拍石块（EEVEE 实例化）
        for o in [o for o in bpy.data.objects if o.name.startswith("石块")]: bpy.data.objects.remove(o)
        for c_ in [c_ for c_ in bpy.data.collections if c_.name.startswith("石块原型")]: bpy.data.collections.remove(c_)
        scatter_rocks(F, NearCtx(nd, meta, shot), nd)
    if ENGINE == "eevee" and arg.step in ("terrain", "far", "rocks", "all"): to_eevee()
    if arg.step == "save":
        for img in bpy.data.images:
            if img.source == "GENERATED" and not img.packed_file: img.pack()
        path = nd/f"{SHOT}.blend"
        bpy.ops.wm.save_as_mainfile(filepath=str(path), copy=True, compress=False)
        log(f"→ {path}")
    if arg.step == "render" and ENGINE == "eevee":
        to_eevee()
        res = tuple(int(v) for v in arg.res.split("x"))
        render_eevee(res, "" if res[0] >= 3000 else "_预览")
    elif arg.step == "render":
        if arg.device == "GPU":
            prefs = bpy.context.preferences.addons["cycles"].preferences
            prefs.compute_device_type = "OPTIX"; prefs.get_devices()
            for d in prefs.devices: d.use = d.type == "OPTIX"
        bpy.context.scene.cycles.device = arg.device
        bpy.context.scene.cycles.dicing_rate = arg.dicing
        for o in bpy.data.objects:
            for m in o.modifiers:
                if m.type == "SUBSURF" and m.use_adaptive_subdivision: m.adaptive_pixel_size = arg.dicing
        shot2, cam, sun = _cam_state(shot, F, nd, meta)
        res = tuple(int(v) for v in arg.res.split("x"))
        render(shot2, F, cam, sun, AT.Atmosphere(), res, arg.samples, "" if res[0] >= 3000 else "_预览")
    log(f"完成 {arg.step}（{time.time() - t0:.1f} s）")
    return dict(step=arg.step, seconds=round(time.time() - t0, 1), objects=[o.name for o in bpy.data.objects])


if __name__ == "__main__":
    result = main()
