"""
火星地表 Blender 渲染（2100 年）—— 仿 SpaceEngine：真实地形 + 程序细节 + 物理大气。插图，不进系列图。

流程（全在 Blender 自带的 Python 里，先跑 50 准备数据）：
1. 地形：区域按真实曲率做成球面片（场景坐标见 镜头.py），Cycles 自适应细分（屏幕上约 1 像素一格），
   真位移＝50 做的 231 m 高程（HRSC+MOLA 200 m + 推定的冲沟、岩层台阶）+ 着色器里的程序细节：fBM 起伏、坡上小脊、
   两档 Voronoi 撞击坑（数据分辨率以下的部分，推定）。
   着色：TES 反照率决定亮尘 / 暗砂，陡坡露出按高度分层的玄武岩（夹氧化层与浅色层），再乘 CTX 影像的明暗起伏，
   水边一圈湿岸。
2. 水：按 11 的水位做成 4 km 厚的封闭水板，与地形相交处就是岸线；水体吸收按纯水 + 悬浮细尘，
   阴影光线直接穿过水面（不算焦散），所以浅水能看见湖底。
3. 三遍渲染：A 只有太阳（大气顶的白光，照度 1），B 只有天光（火星大气.py 算的天空图），都开降噪；
   C 是位置图（表面临时换成「发光＝世界坐标」，几何与位移不变）。
4. 后期（numpy）：A 的每个像素乘「该点到太阳的大气透射率」（谷底与高原不一样红），加 B，
   再按视线做大气积分：地表 × 透射率 + 内散射；天空直接积分到大气顶，加太阳盘；
   最后自动曝光（按地面）、35% 灰世界白平衡、泛光、ACES 色调映射，存 PNG。
运行：blender -b -P scripts/Blender/51_地表渲染.py -- [--shot 科普莱特斯峡谷] [--preview] [--post-only] [--ev 0]
产出：产出/Blender/<镜头>.png（--preview 是 <镜头>_预览.png）；中间的 EXR 在 DEM/Blender缓存/<区域>/
"""
import argparse, json, math, pathlib, sys, time
import numpy as np
import bpy
from mathutils import Matrix
HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import 镜头 as K
import 火星大气 as AT

MAP = HERE.parent.parent
CACHE = MAP/"DEM"/"Blender缓存"
OUT = MAP/"产出"/"Blender"
R = K.R
MESH_N = (1280, 896)                    # 地形底网格（经向 × 纬向顶点）；细节靠自适应细分


def log(*a): print("[51]", *a, flush=True)


# ── 节点小工具 ─────────────────────────────────────────────────────
class G:
    def __init__(self, tree):
        self.t = tree; tree.nodes.clear()

    def n(self, kind, **kw):
        node = self.t.nodes.new(kind)
        for k, v in kw.items(): setattr(node, k, v)
        return node

    def link(self, a, b): self.t.links.new(a, b)

    def _in(self, sock, v):
        if isinstance(v, bpy.types.NodeSocket): self.link(v, sock)
        else: sock.default_value = v

    def m(self, op, a, b=None, clamp=False):
        node = self.n("ShaderNodeMath", operation=op, use_clamp=clamp)
        self._in(node.inputs[0], a)
        if b is not None: self._in(node.inputs[1], b)
        return node.outputs[0]

    def v(self, op, a, b=None, scale=None):
        node = self.n("ShaderNodeVectorMath", operation=op)
        self._in(node.inputs[0], a)
        if b is not None: self._in(node.inputs[1], b)
        if scale is not None: self._in(node.inputs["Scale"], scale)
        return node.outputs["Value" if op in ("LENGTH", "DOT_PRODUCT", "DISTANCE") else "Vector"]

    def noise(self, vec, scale, detail=8.0, rough=0.5, lac=2.0, kind="FBM", out="Fac"):
        node = self.n("ShaderNodeTexNoise", noise_dimensions="3D", noise_type=kind, normalize=True)
        self._in(node.inputs["Vector"], vec)
        node.inputs["Scale"].default_value = scale
        node.inputs["Detail"].default_value = detail
        node.inputs["Roughness"].default_value = rough
        node.inputs["Lacunarity"].default_value = lac
        return node.outputs[out]

    def maprange(self, x, a, b, c=0.0, d=1.0, smooth=True):
        node = self.n("ShaderNodeMapRange", interpolation_type="SMOOTHSTEP" if smooth else "LINEAR", clamp=True)
        self._in(node.inputs["Value"], x)
        for k, val in (("From Min", a), ("From Max", b), ("To Min", c), ("To Max", d)): node.inputs[k].default_value = val
        return node.outputs["Result"]

    def mix(self, f, a, b):
        node = self.n("ShaderNodeMix", data_type="RGBA")
        self._in(node.inputs["Factor"], f)
        self._in(node.inputs[6], a); self._in(node.inputs[7], b)
        return node.outputs[2]

    def rgb_mul(self, c, s):
        node = self.n("ShaderNodeMix", data_type="RGBA", blend_type="MULTIPLY")
        node.inputs["Factor"].default_value = 1.0
        self._in(node.inputs[6], c)
        if isinstance(s, bpy.types.NodeSocket):
            comb = self.n("ShaderNodeCombineColor"); [self.link(s, comb.inputs[i]) for i in range(3)]
            self.link(comb.outputs[0], node.inputs[7])
        else: node.inputs[7].default_value = (s, s, s, 1)
        return node.outputs[2]


# ── 场景 ───────────────────────────────────────────────────────────
def setup_render(res, samples, dicing):
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "OPTIX"; prefs.get_devices()
    for d in prefs.devices: d.use = d.type == "OPTIX"
    cy = sc.cycles
    cy.device = "GPU"
    cy.samples = samples
    cy.use_adaptive_sampling = True; cy.adaptive_threshold = 0.01
    cy.use_denoising = True; cy.denoiser = "OPENIMAGEDENOISE"; cy.denoising_use_gpu = True
    cy.max_bounces = 8; cy.diffuse_bounces = 3; cy.glossy_bounces = 3
    cy.transmission_bounces = 6; cy.volume_bounces = 1; cy.transparent_max_bounces = 8
    cy.caustics_reflective = False; cy.caustics_refractive = False
    cy.blur_glossy = 1.0
    cy.dicing_rate = dicing; cy.max_subdivisions = 9; cy.offscreen_dicing_scale = 16.0   # 9 级：近景 8 m 网格最细 1.6 cm；再细是白占显存
    sc.render.resolution_x, sc.render.resolution_y = res
    sc.render.resolution_percentage = 100
    sc.render.film_transparent = True
    s = sc.render.image_settings
    s.media_type = "MULTI_LAYER_IMAGE"; s.file_format = "OPEN_EXR_MULTILAYER"; s.color_depth = "32"; s.exr_codec = "ZIP"
    return sc


POS_OFF = 4000.0                         # 位置图偏移（km）：发光颜色不能为负


def position_mode():
    """C 遍：所有表面换成「发光＝世界坐标 + POS_OFF」，去掉体积，关降噪（5.2 的多层 EXR 写不出位置通道，只好这样拿）。"""
    for mat in bpy.data.materials:
        nt = mat.node_tree
        out = next(n for n in nt.nodes if n.bl_idname == "ShaderNodeOutputMaterial")
        for k in ("Surface", "Volume"):
            for l in list(out.inputs[k].links): nt.links.remove(l)
        geo = nt.nodes.new("ShaderNodeNewGeometry")
        add = nt.nodes.new("ShaderNodeVectorMath"); add.operation = "ADD"; add.inputs[1].default_value = (POS_OFF,)*3
        em = nt.nodes.new("ShaderNodeEmission"); em.inputs["Strength"].default_value = 1.0
        nt.links.new(geo.outputs["Position"], add.inputs[0]); nt.links.new(add.outputs[0], em.inputs["Color"])
        nt.links.new(em.outputs[0], out.inputs["Surface"])
    sc = bpy.context.scene
    sc.cycles.use_denoising = False; sc.cycles.samples = 16; sc.cycles.use_adaptive_sampling = False
    sc.cycles.max_bounces = 0


def float_image(name, arr):
    """(ny, nx[, 3])，第 0 行在北 → Blender 浮点图（第 0 行在下），数据色彩空间。"""
    if arr.ndim == 2: arr = arr[..., None]
    ny, nx, nc = arr.shape
    img = bpy.data.images.new(name, nx, ny, alpha=False, float_buffer=True, is_data=True)
    rgba = np.ones((ny, nx, 4), np.float32); rgba[..., :3] = arr[::-1] if nc == 3 else arr[::-1, :, :1]
    img.pixels.foreach_set(rgba.ravel())                                  # 别再改色彩空间：生成图一改就清空
    return img


TEXDIR = CACHE/"_贴图"


def file_image(name, arr, kind):
    """(ny, nx[, c])，第 0 行在北 → 写成文件再载入，Cycles 按文件的通道数与精度存（生成图一律 4 通道 32 位，白占显存）。
    kind：f32 单通道 32 位 EXR（高程，半精度在 2 km 处只有 2 m 精度，不够）、half 半精度 EXR、u8 8 位 PNG。"""
    import OpenImageIO as oiio
    TEXDIR.mkdir(parents=True, exist_ok=True)
    a = np.ascontiguousarray(arr if arr.ndim == 3 else arr[..., None])
    h, w, c = a.shape
    path = TEXDIR/f"{name}{'.png' if kind == 'u8' else '.exr'}"
    spec = oiio.ImageSpec(w, h, c, {"f32": oiio.FLOAT, "half": oiio.HALF, "u8": oiio.UINT8}[kind])
    if kind != "u8": spec.attribute("compression", "zip")
    o = oiio.ImageOutput.create(str(path)); o.open(str(path), spec)
    o.write_image(a.astype(np.uint8) if kind == "u8" else a.astype(np.float32)); o.close()
    old = bpy.data.images.get(name)
    if old: bpy.data.images.remove(old)
    img = bpy.data.images.load(str(path)); img.name = name
    img.colorspace_settings.name = "Non-Color"
    return img


def byte_image(name, a8):
    """(ny, nx) uint8，第 0 行在北 → 8 位灰度图（省显存：CTX 细节 7 千万像素）。"""
    ny, nx = a8.shape
    img = bpy.data.images.new(name, nx, ny, alpha=False, float_buffer=False, is_data=True)
    px = np.empty((ny, nx, 4), np.float32)
    px[..., :3] = (a8[::-1]/255.0)[..., None]; px[..., 3] = 1
    img.pixels.foreach_set(px.ravel()); del px
    return img


def grid_mesh(name, P, uv=None, keep=None):
    """P：(ny, nx, 3) 顶点（第 0 行在南）；四边形按「东 → 北」逆时针，法线朝上。keep：(ny−1, nx−1) 要哪些面。"""
    ny, nx, _ = P.shape
    i, j = np.meshgrid(np.arange(ny - 1), np.arange(nx - 1), indexing="ij")
    q = np.stack([i*nx + j, i*nx + j + 1, (i + 1)*nx + j + 1, (i + 1)*nx + j], -1).reshape(-1, 4)
    if keep is not None: q = q[keep.ravel()]
    used, inv = np.unique(q, return_inverse=True)
    q = inv.reshape(-1, 4)
    V = P.reshape(-1, 3)[used]
    me = bpy.data.meshes.new(name)
    me.vertices.add(len(V)); me.vertices.foreach_set("co", V.astype(np.float32).ravel())
    me.loops.add(q.size); me.loops.foreach_set("vertex_index", q.ravel().astype(np.int32))
    me.polygons.add(len(q)); me.polygons.foreach_set("loop_start", (np.arange(len(q))*4).astype(np.int32))
    me.update(calc_edges=True)
    if uv is not None:
        lay = me.uv_layers.new(name="UVMap")
        lay.data.foreach_set("uv", uv.reshape(-1, 2)[used][q.ravel()].astype(np.float32).ravel())
    me.shade_smooth()
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def bilinear(a, fi, fj):
    """a[第 0 行在北]，按浮点行列双线性取值（Blender 里没有 scipy）。"""
    i0 = np.clip(np.floor(fi).astype(int), 0, a.shape[0] - 2); j0 = np.clip(np.floor(fj).astype(int), 0, a.shape[1] - 2)
    u = np.clip(fi - i0, 0, 1); v = np.clip(fj - j0, 0, 1)
    return (a[i0, j0]*(1 - u)*(1 - v) + a[i0 + 1, j0]*u*(1 - v) + a[i0, j0 + 1]*(1 - u)*v + a[i0 + 1, j0 + 1]*u*v)


def coarse_lookup(g, uv_socket, img, n, sub=((0.0, 1.0), (0.0, 1.0))):
    """顶点对齐的粗高程图：顶点 i 在 u = ua + (ub−ua)·i/(n−1)，纹素中心在 (i+0.5)/n → 映射后线性采样＝网格本身的双线性。
    sub：网格只铺在 UV 的 [ua, ub]×[va, vb] 里时给出。"""
    mp = g.n("ShaderNodeMapping", vector_type="POINT")
    g.link(uv_socket, mp.inputs["Vector"])
    (ua, ub), (va, vb) = sub
    su = (n[0] - 1)/n[0]/(ub - ua); sv = (n[1] - 1)/n[1]/(vb - va)
    mp.inputs["Scale"].default_value = (su, sv, 1)
    mp.inputs["Location"].default_value = (-ua*su + 0.5/n[0], -va*sv + 0.5/n[1], 0)
    t = g.n("ShaderNodeTexImage", image=img, interpolation="Linear", extension="EXTEND")
    g.link(mp.outputs[0], t.inputs["Vector"])
    sc = g.n("ShaderNodeSeparateColor"); g.link(t.outputs["Color"], sc.inputs[0])
    return sc.outputs[0]


def terrain(F, region, hgt_img, aux_img, col_img, ctx_img, dicing, hgt=None, sink=None, hole=None, extent=None):
    """hgt：高程数组（km，第 0 行在北）。给了就把底网格顶点放在真实高度上（视口里看得到地形），
    位移只补「纹理 − 网格双线性」的差和细节；sink：(ny, nx) 顶点处下沉量（km，近景范围里压低）。"""
    lon0, lon1, lat0, lat1 = region
    nx, ny = MESH_N
    ea, eb, ec, ed = extent or region                                      # extent：网格只铺这一块（近景镜头用，格子更细）
    lon = np.linspace(ea, eb, nx); lat = np.linspace(ed, ec, ny)
    LO, LA = np.meshgrid(lon, lat)
    Hv = np.zeros(LO.shape, np.float32)
    if hgt is not None:
        Hv = bilinear(hgt, (lat0 - LA)*hgt.shape[0]/(lat0 - lat1) - 0.5, (LO - lon0)*hgt.shape[1]/(lon1 - lon0) - 0.5).astype(np.float32)
    if sink is not None: Hv = Hv - sink
    P = F.pos(LO, LA, R + Hv)
    uv = np.stack([(LO - lon0)/(lon1 - lon0), (LA - lat1)/(lat0 - lat1)], -1)
    keep = None
    if hole is not None:                                                   # hole：顶点在近景范围里；四角都在里面的面挖掉
        keep = ~(hole[:-1, :-1] & hole[1:, :-1] & hole[:-1, 1:] & hole[1:, 1:])
    ob = grid_mesh("地形", P, uv, keep=keep)
    mod = ob.modifiers.new("自适应细分", "SUBSURF")
    mod.subdivision_type = "SIMPLE"; mod.levels = 0; mod.render_levels = 0
    mod.use_adaptive_subdivision = True; mod.adaptive_space = "PIXEL"; mod.adaptive_pixel_size = dicing
    mat = bpy.data.materials.new("火星地表"); mat.use_nodes = True
    mat.displacement_method = "DISPLACEMENT"
    g = G(mat.node_tree)
    out = g.n("ShaderNodeOutputMaterial")
    tc = g.n("ShaderNodeTexCoord")
    geo = g.n("ShaderNodeNewGeometry")
    th = g.n("ShaderNodeTexImage", image=hgt_img, interpolation="Cubic", extension="EXTEND")
    g.link(tc.outputs["UV"], th.inputs["Vector"])
    sh = g.n("ShaderNodeSeparateColor"); g.link(th.outputs["Color"], sh.inputs[0])
    ta = g.n("ShaderNodeTexImage", image=aux_img, interpolation="Linear", extension="EXTEND")
    g.link(tc.outputs["UV"], ta.inputs["Vector"])
    sa = g.n("ShaderNodeSeparateColor"); g.link(ta.outputs["Color"], sa.inputs[0])
    H, S, WL = sh.outputs[0], sa.outputs[0], sa.outputs[1]
    tcol = g.n("ShaderNodeTexImage", image=col_img, interpolation="Cubic", extension="EXTEND")
    g.link(tc.outputs["UV"], tcol.inputs["Vector"])
    tx = g.n("ShaderNodeTexImage", image=ctx_img, interpolation="Linear", extension="EXTEND")
    g.link(tc.outputs["UV"], tx.inputs["Vector"])
    P_ = geo.outputs["Position"]

    # 位移：MOLA + 程序细节（km）
    fb = g.m("SUBTRACT", g.noise(P_, 0.6, 12, 0.52), 0.5)                  # 2 km 起、一直到米级的 fBM
    rough = g.m("MULTIPLY", fb, g.m("ADD", 0.05, g.m("MULTIPLY", 0.25, g.maprange(S, 0.05, 0.6, smooth=False))))
    rd = g.noise(P_, 1.2, 8, 0.55)                                         # 坡上的小脊：1 − |2n − 1|
    ridge = g.m("SUBTRACT", 1.0, g.m("ABSOLUTE", g.m("SUBTRACT", g.m("MULTIPLY", rd, 2.0), 1.0)))
    wall = g.m("MULTIPLY", g.m("SUBTRACT", ridge, 0.6), g.m("MULTIPLY", 0.12, g.maprange(S, 0.15, 0.7)))   # 大的沟脊已在 50 里
    dry = g.maprange(g.m("SUBTRACT", H, WL), 0.02, 0.15)                   # 水下不画坑
    flat = g.m("SUBTRACT", 1.0, g.maprange(S, 0.04, 0.2))

    def craters(scale, r0, r1, frac):
        vo = g.n("ShaderNodeTexVoronoi", voronoi_dimensions="3D", feature="F1", distance="EUCLIDEAN")
        g.link(P_, vo.inputs["Vector"]); vo.inputs["Scale"].default_value = scale
        rc = g.n("ShaderNodeSeparateColor"); g.link(vo.outputs["Color"], rc.inputs[0])
        rad = g.m("ADD", r0, g.m("MULTIPLY", r1, g.m("POWER", rc.outputs[0], 3.0)))
        x = g.m("DIVIDE", g.m("DIVIDE", vo.outputs["Distance"], scale), rad)
        xm = g.m("MINIMUM", x, 1.0)
        bowl = g.m("MULTIPLY", g.m("SUBTRACT", g.m("MULTIPLY", xm, xm), 1.0), g.m("MULTIPLY", rad, 0.40))
        t = g.m("MULTIPLY", g.m("SUBTRACT", x, 1.0), 3.5)
        rim = g.m("MULTIPLY", g.m("EXPONENT", g.m("MULTIPLY", g.m("MULTIPLY", t, t), -1.0)), g.m("MULTIPLY", rad, 0.09))
        have = g.m("GREATER_THAN", rc.outputs[1], 1 - frac)
        return g.m("MULTIPLY", g.m("ADD", bowl, rim), have)

    cr = g.m("ADD", craters(0.30, 0.10, 1.10, 0.55), craters(1.4, 0.025, 0.24, 0.6))
    cr = g.m("MULTIPLY", cr, g.m("MULTIPLY", dry, flat))
    sk = sa.outputs[2]                                                     # aux 第三通道：近景范围的下沉（km，463 m 一格）
    if sink is not None:                                                   # 给了顶点下沉就用它（与网格同分辨率，接缝更细）
        sk_img = file_image("下沉_顶点", sink[::-1].astype(np.float32), "f32")
        sk = coarse_lookup(g, tc.outputs["UV"], sk_img, (nx, ny),
                           (((ea - lon0)/(lon1 - lon0), (eb - lon0)/(lon1 - lon0)), ((ed - lat1)/(lat0 - lat1), (ec - lat1)/(lat0 - lat1))))
    keep = g.m("SUBTRACT", 1.0, g.m("MINIMUM", g.m("MULTIPLY", sk, 50.0), 1.0))
    detail = g.m("MULTIPLY", g.m("ADD", g.m("ADD", rough, wall), cr), keep)
    base_h = g.m("SUBTRACT", H, sk)
    if hgt is not None:                                                    # 网格已在 R + Hv：位移只补 (H − 下沉) − 网格双线性
        hv_img = file_image("高程_顶点", Hv[::-1], "f32")                   # 第 0 行在北
        subuv = (((ea - lon0)/(lon1 - lon0), (eb - lon0)/(lon1 - lon0)), ((ed - lat1)/(lat0 - lat1), (ec - lat1)/(lat0 - lat1)))
        base_h = g.m("SUBTRACT", base_h, coarse_lookup(g, tc.outputs["UV"], hv_img, (nx, ny), subuv))
    disp_h = g.m("ADD", base_h, detail)
    dn = g.n("ShaderNodeDisplacement", space="OBJECT")
    g.link(disp_h, dn.inputs["Height"]); dn.inputs["Midlevel"].default_value = 0.0; dn.inputs["Scale"].default_value = 1.0
    g.link(dn.outputs[0], out.inputs["Displacement"])

    # 着色
    pc = g.v("ADD", P_, (0.0, 0.0, R))
    up = g.v("NORMALIZE", pc)
    hk = g.m("SUBTRACT", g.v("LENGTH", pc), R)
    steep = g.m("SUBTRACT", 1.0, g.v("DOT_PRODUCT", geo.outputs["Normal"], up))
    rockf = g.m("MULTIPLY", g.maprange(steep, 0.10, 0.30), g.maprange(S, 0.12, 0.45))   # 大坡上的陡处才露岩
    warp = g.m("ADD", g.m("MULTIPLY", g.m("SUBTRACT", g.noise(P_, 0.12, 5), 0.5), 0.9), g.m("MULTIPLY", g.m("SUBTRACT", g.noise(P_, 1.1, 4), 0.5), 0.15))
    band = g.m("FRACT", g.m("MULTIPLY", g.m("ADD", hk, warp), 1.1))
    ramp = g.n("ShaderNodeValToRGB"); g.link(band, ramp.inputs[0])
    cr_ = ramp.color_ramp; cr_.interpolation = "EASE"
    strata = [(0.0, (0.120, 0.076, 0.058)), (0.25, (0.150, 0.082, 0.058)), (0.45, (0.110, 0.072, 0.057)),
              (0.62, (0.165, 0.105, 0.078)), (0.80, (0.100, 0.068, 0.054))]
    while len(cr_.elements) < len(strata): cr_.elements.new(0.5)
    for el, (pos, c) in zip(cr_.elements, strata): el.position = pos; el.color = (*c, 1)
    var = g.m("ADD", 0.78, g.m("MULTIPLY", g.noise(P_, 1.3, 6, 0.6), 0.44))
    rock = g.rgb_mul(ramp.outputs["Color"], var)
    vb = g.m("ADD", g.m("MULTIPLY", g.noise(P_, 0.25, 6, 0.55), 0.4),                      # 4 km
               g.m("ADD", g.m("MULTIPLY", g.noise(P_, 20.0, 5, 0.6), 0.3),                  # 50 m
                   g.m("MULTIPLY", g.noise(P_, 85.0, 4, 0.6), 0.2)))                        # 12 m
    base = g.rgb_mul(tcol.outputs["Color"], g.m("ADD", 0.35, vb))
    c1 = g.mix(rockf, base, rock)
    ctxk = g.m("ADD", 0.6, g.m("MULTIPLY", tx.outputs["Color"], 0.8))     # CTX 明暗：0.6–1.4 倍
    c1 = g.rgb_mul(c1, ctxk)
    dw = g.m("SUBTRACT", hk, WL)
    wet = g.m("SUBTRACT", 1.0, g.maprange(dw, 0.0, 0.035))
    c2 = g.rgb_mul(c1, g.m("SUBTRACT", 1.0, g.m("MULTIPLY", wet, 0.45)))
    bsdf = g.n("ShaderNodeBsdfDiffuse"); bsdf.inputs["Roughness"].default_value = 0.7
    g.link(c2, bsdf.inputs["Color"])
    g.link(bsdf.outputs[0], out.inputs["Surface"])
    ob.data.materials.append(mat)
    return ob


def water(F, region, name):
    wz = np.load(CACHE/name/"water.npz")
    bl, levels = wz["basin"], wz["levels"]
    if not (bl > 0).any(): return None
    lon0, lon1, lat0, lat1 = region
    ny, nx = bl.shape
    b = bl[::-1]                                                          # 第 0 行在南
    lat = lat1 + (np.arange(ny) + 0.5)/K.PPD_WATER
    lon = lon0 + (np.arange(nx) + 0.5)/K.PPD_WATER
    LO, LA = np.meshgrid(lon, lat)
    lv = np.where(b > 0, levels[np.maximum(b, 1) - 1], 0.0)
    P = F.pos(LO, LA, R + lv)
    keep = (b[:-1, :-1] > 0) & (b[:-1, :-1] == b[1:, :-1]) & (b[:-1, :-1] == b[:-1, 1:]) & (b[:-1, :-1] == b[1:, 1:])
    ob = grid_mesh("水", P, keep=keep)
    so = ob.modifiers.new("水深", "SOLIDIFY"); so.thickness = 4.0; so.offset = -1.0; so.use_rim = True
    mat = bpy.data.materials.new("水"); mat.use_nodes = True
    g = G(mat.node_tree)
    out = g.n("ShaderNodeOutputMaterial")
    geo = g.n("ShaderNodeNewGeometry")
    pr = g.n("ShaderNodeBsdfGlass", distribution="GGX")                 # Principled 的闭包太多（超 64）
    pr.inputs["Color"].default_value = (1, 1, 1, 1)
    pr.inputs["Roughness"].default_value = 0.025
    pr.inputs["IOR"].default_value = 1.333
    bump = g.n("ShaderNodeBump"); bump.inputs["Strength"].default_value = 0.25; bump.inputs["Distance"].default_value = 0.0015
    wave = g.noise(geo.outputs["Position"], 45.0, 6, 0.55)
    g.link(wave, bump.inputs["Height"]); g.link(bump.outputs["Normal"], pr.inputs["Normal"])
    tr = g.n("ShaderNodeBsdfTransparent")
    lp = g.n("ShaderNodeLightPath")
    mx = g.n("ShaderNodeMixShader")
    g.link(lp.outputs["Is Shadow Ray"], mx.inputs[0]); g.link(pr.outputs[0], mx.inputs[1]); g.link(tr.outputs[0], mx.inputs[2])
    g.link(mx.outputs[0], out.inputs["Surface"])
    # 体积：纯水吸收（650/550/450 nm：0.34/0.057/0.009 /m）+ 细尘 0.03 /m；km 单位
    sig = np.array([0.34, 0.057, 0.009]) + 0.03
    dens = 400.0
    ab = g.n("ShaderNodeVolumeAbsorption")
    ab.inputs["Color"].default_value = (*(1 - sig*1000/dens), 1); ab.inputs["Density"].default_value = dens
    g.link(ab.outputs[0], out.inputs["Volume"])                           # 再加散射会让闭包超 64（5.2），只留吸收
    ob.data.materials.append(mat)
    return ob


def place_camera(shot, F, res):
    p, f, right, up = K.camera(shot, F)
    cd = bpy.data.cameras.new("相机")
    cd.sensor_fit = "HORIZONTAL"; cd.angle = math.radians(shot["fov"])
    cd.clip_start = 0.002; cd.clip_end = 5000.0
    ob = bpy.data.objects.new("相机", cd)
    ob.matrix_world = Matrix(((right[0], up[0], -f[0], p[0]), (right[1], up[1], -f[1], p[1]),
                              (right[2], up[2], -f[2], p[2]), (0, 0, 0, 1)))
    bpy.context.scene.collection.objects.link(ob)
    bpy.context.scene.camera = ob
    bpy.context.scene.cycles.dicing_camera = ob
    return p, f, right, up


def place_sun(s):
    ld = bpy.data.lights.new("太阳", "SUN")
    ld.energy = 1.0; ld.angle = math.radians(0.35); ld.color = (1, 1, 1)
    ob = bpy.data.objects.new("太阳", ld)
    z = s/np.linalg.norm(s)
    x = np.cross([0, 0, 1], z); x = x/np.linalg.norm(x) if np.linalg.norm(x) > 1e-6 else np.array([1.0, 0, 0])
    y = np.cross(z, x)
    ob.matrix_world = Matrix(((x[0], y[0], z[0], 0), (x[1], y[1], z[1], 0), (x[2], y[2], z[2], 0), (0, 0, 0, 1)))
    bpy.context.scene.collection.objects.link(ob)
    return ob


def world_env(env):
    w = bpy.data.worlds.new("火星天空"); w.use_nodes = True
    bpy.context.scene.world = w
    h, wd, _ = env.shape
    img = bpy.data.images.new("天空图", wd, h, alpha=False, float_buffer=True)
    img.colorspace_settings.name = "Linear Rec.709"                       # 先设色彩空间再写像素
    rgba = np.ones((h, wd, 4), np.float32); rgba[..., :3] = env
    img.pixels.foreach_set(rgba.ravel())
    g = G(w.node_tree)
    out = g.n("ShaderNodeOutputWorld")
    te = g.n("ShaderNodeTexEnvironment", image=img, interpolation="Linear")
    bg = g.n("ShaderNodeBackground")
    g.link(te.outputs["Color"], bg.inputs["Color"])
    g.link(bg.outputs[0], out.inputs["Surface"])
    return bg


# ── EXR 读写 ───────────────────────────────────────────────────────
def read_exr(path):
    import OpenImageIO as oiio
    inp = oiio.ImageInput.open(str(path))
    spec = inp.spec(); names = list(spec.channelnames)
    px = inp.read_image(0, 0, 0, spec.nchannels, oiio.FLOAT); inp.close()
    px = np.asarray(px).reshape(spec.height, spec.width, spec.nchannels)
    def ch(*suffix):
        out = []
        for s in suffix:
            k = [i for i, n in enumerate(names) if n.endswith(s)]
            out.append(px[..., k[0]])
        return np.stack(out, -1)
    return ch


def write_png(path, rgb8):
    import OpenImageIO as oiio
    h, w, _ = rgb8.shape
    o = oiio.ImageOutput.create(str(path))
    o.open(str(path), oiio.ImageSpec(w, h, 3, oiio.UINT8)); o.write_image(np.ascontiguousarray(rgb8)); o.close()


def write_exr(path, rgb):
    import OpenImageIO as oiio
    h, w, _ = rgb.shape
    o = oiio.ImageOutput.create(str(path))
    o.open(str(path), oiio.ImageSpec(w, h, 3, oiio.HALF)); o.write_image(np.ascontiguousarray(rgb.astype(np.float32))); o.close()


# ── 后期：大气 + 色调 ──────────────────────────────────────────────
def gauss_blur(img, sigma):
    h, w, _ = img.shape
    fy = np.fft.fftfreq(h)[:, None]; fx = np.fft.rfftfreq(w)[None, :]
    k = np.exp(-2*(math.pi*sigma)**2*(fx*fx + fy*fy))
    return np.stack([np.fft.irfft2(np.fft.rfft2(img[..., c])*k, s=(h, w)) for c in range(3)], -1)


def post(shot, F, atm, sun, cam, exA, exB, exC, ev=0.0):
    p, f, right, up = cam
    A = read_exr(exA); B = read_exr(exB); C = read_exr(exC)
    rgbA = A(".Combined.R", ".Combined.G", ".Combined.B"); alpha = A(".Combined.A")[..., 0]
    pos = C(".Combined.R", ".Combined.G", ".Combined.B") - POS_OFF*C(".Combined.A")
    rgbB = B(".Combined.R", ".Combined.G", ".Combined.B")
    h, w = alpha.shape
    t0 = time.time()
    # 每个像素的视线方向（EXR 第 0 行在上）
    tx = math.tan(math.radians(shot["fov"])/2); ty = tx*h/w
    xs = ((np.arange(w) + 0.5)/w*2 - 1)*tx
    ys = (1 - (np.arange(h) + 0.5)/h*2)*ty
    X, Y = np.meshgrid(xs, ys)
    d = f[None, None] + X[..., None]*right + Y[..., None]*up
    d /= np.linalg.norm(d, axis=-1, keepdims=True)
    o = p - F.C                                                            # 相对火星中心
    hit = alpha > 1e-4
    ppos = np.where(hit[..., None], pos/np.maximum(alpha, 1e-4)[..., None], 0) - F.C
    # 地表：A × 太阳透射率（逐点）+ B
    rp = np.linalg.norm(ppos, axis=-1)
    Ts = np.zeros((h, w, 3), np.float32)
    Ts[hit] = atm.transmittance(rp[hit] - R, (ppos[hit] @ sun)/rp[hit])
    surf = rgbA*Ts + rgbB
    final = np.zeros((h, w, 3), np.float32)
    dist = np.linalg.norm(ppos - o, axis=-1)
    if hit.any():
        Lt, Tt = atm.integrate(o[None], d[hit], dist[hit], sun)
        final[hit] = surf[hit]*Tt + alpha[hit][:, None]*Lt
    sky = alpha < 0.9999
    if sky.any():
        Ls, Tsk = atm.integrate(o[None], d[sky], np.inf, sun)
        Ls = Ls + atm.sun_disc(d[sky], sun)*Tsk
        final[sky] += (1 - alpha[sky])[:, None]*Ls
    log(f"大气积分 {time.time() - t0:.1f} s")
    # 曝光：按地面像素的对数平均亮度 → 0.15（不让亮天空把地面压暗）
    lum = final @ np.array([0.2126, 0.7152, 0.0722])
    sel = alpha > 0.5 if (alpha > 0.5).mean() > 0.05 else np.ones_like(alpha, bool)
    key = math.exp(np.mean(np.log(np.clip(lum[sel], 1e-6, None))))
    x = final*(0.15/key)*2**ev
    # 白平衡：相机式灰世界，只修正 35%（远处的蓝是空气透视，不该全抹掉）
    m = np.mean(final[sel], 0)
    x = x*(m.mean()/m)**0.35
    # 泛光：亮处模糊叠加（太阳、水面反光）
    hi = np.maximum(x - 1.0, 0)
    x = x + 0.08*gauss_blur(hi, w/500) + 0.03*gauss_blur(hi, w/80)
    # ACES（Narkowicz 拟合）→ sRGB
    y = np.clip(x*(2.51*x + 0.03)/(x*(2.43*x + 0.59) + 0.14), 0, 1)
    srgb = np.where(y <= 0.0031308, 12.92*y, 1.055*np.power(y, 1/2.4) - 0.055)
    return final, (np.clip(srgb, 0, 1)*255 + 0.5).astype(np.uint8), key


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--shot", default="科普莱特斯峡谷", choices=list(K.SHOTS))
    ap.add_argument("--preview", action="store_true", help="1920×1080、少采样、粗一点的细分")
    ap.add_argument("--res", default="3840x2160")
    ap.add_argument("--samples", type=int, default=384)
    ap.add_argument("--post-only", action="store_true", help="不重渲，只重做后期")
    ap.add_argument("--ev", type=float, default=0.0)
    arg = ap.parse_args(argv)
    shot = K.SHOTS[arg.shot]
    region = K.REGIONS[shot["data"]]
    F = K.Frame(region)
    cdir = CACHE/shot["data"]
    if shot["cam"][2] is None:                                            # 离地高度 → 绝对高度
        lon0, lon1, lat0, lat1 = region
        hg = np.load(cdir/"hgt.npy", mmap_mode="r")
        ppd = hg.shape[1]/(lon1 - lon0)
        i, j = (lat0 - shot["cam"][1])*ppd - 0.5, (shot["cam"][0] - lon0)*ppd - 0.5
        i0, j0 = int(i), int(j)
        gnd = float(np.max(hg[i0 - 2:i0 + 4, j0 - 2:j0 + 4]))              # 取周围最高，免得钻进小丘
        shot = dict(shot, cam=(shot["cam"][0], shot["cam"][1], gnd + shot["agl"]))
        log(f"地面 {gnd:+.2f} km → 相机 {gnd + shot['agl']:+.2f} km")
    sun = K.sun_dir(shot, F)
    el, az = K.sun_altaz(shot, F)
    log(f"{arg.shot}：太阳高度 {el:.1f}°、方位 {az:.1f}°")
    res = (1920, 1080) if arg.preview else tuple(int(v) for v in arg.res.split("x"))
    samples = 64 if arg.preview else arg.samples
    dicing = 1.5 if arg.preview else 2.0                                 # 4K 时 1 像素一格会超 8 GB 显存
    tag = "_预览" if arg.preview else ""
    pre = f"{arg.shot}_"
    exA, exB, exC = (cdir/f"{pre}{k}{tag}.exr" for k in ("A_太阳", "B_天光", "C_位置"))
    t0 = time.time()
    atm = AT.Atmosphere()
    log(f"大气查找表 {time.time() - t0:.1f} s")

    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = setup_render(res, samples, dicing)
    cam = place_camera(shot, F, res)
    if not arg.post_only:
        hgt_arr = np.load(cdir/"hgt.npy")
        hgt_img = file_image("高程", hgt_arr, "f32")
        aux_img = file_image("坡度水位", np.load(cdir/"aux.npy"), "half")
        col_img = file_image("底色", np.load(cdir/"col.npy"), "half")
        ctx_img = file_image("CTX", np.load(cdir/"ctx.npy"), "u8")
        terrain(F, region, hgt_img, aux_img, col_img, ctx_img, dicing, hgt=hgt_arr)
        water(F, region, shot["data"])
        # 天光图：从相机正下方地面（基准面）看出去
        lon, lat, _ = shot["cam"]
        origin = F.pos(lon, lat, R) - F.C
        env, E_sun, E_sky = AT.env_map(atm, origin, sun)
        log(f"地面照度：直射 {np.round(E_sun, 3)}，天光 {np.round(E_sky, 3)}")
        bg = world_env(env)
        sun_ob = place_sun(sun)
        # A：只有太阳
        bg.inputs["Strength"].default_value = 0.0
        sc.render.filepath = str(exA)
        t1 = time.time(); bpy.ops.render.render(write_still=True); log(f"A 太阳 {time.time() - t1:.0f} s")
        # B：只有天光
        bg.inputs["Strength"].default_value = 1.0
        sun_ob.hide_render = True
        sc.render.filepath = str(exB)
        t1 = time.time(); bpy.ops.render.render(write_still=True); log(f"B 天光 {time.time() - t1:.0f} s")
        # C：位置图
        bg.inputs["Strength"].default_value = 0.0
        position_mode()
        sc.render.filepath = str(exC)
        t1 = time.time(); bpy.ops.render.render(write_still=True); log(f"C 位置 {time.time() - t1:.0f} s")
    lin, png, key = post(shot, F, atm, sun, cam, exA, exB, exC, arg.ev)
    OUT.mkdir(parents=True, exist_ok=True)
    write_exr(cdir/f"{pre}合成{tag}.exr", lin)
    out = OUT/f"{arg.shot}{tag}.png"
    write_png(out, png)
    log(f"→ {out}（曝光基准 {key:.4g}，共 {time.time() - t0:.0f} s）")


if __name__ == "__main__":
    main()
