"""
实景场景（Blender，Cycles）：57_实景重建.py 导出的真三维地形 + 去光影反照率，今天的火星大气，NASA 毅力号模型。
  地面：15 个嵌套方环（2 cm → 160 m 格距，±98 km），高度＝立体 2 cm/10 cm + HiRISE 1 m + CTX 20 m + MOLA 融合，含曲率下沉。
  材质：反照率（近 1 cm、中 4 cm、HiRISE 25 cm、CTX 20 m，按范围与覆盖渐变）× Oren–Nayar 漫反射（火星表土粗糙、偏后向）。
  光照：太阳＝sol 530 指定当地真太阳时的方位/高度（默认 13:07，与 NASA 照片同刻），视直径 0.38°（1.40 AU）；
        天空＝火星大气.py 物理散射（今天()：τ 0.67 实测、7.6 hPa）；绝对单位 W/m²，曝光按照片对齐。
  毅力号：25042_Perseverance.glb，按 NASA 到站定位的航向/俯仰/横滚（−107.8°/−1.9°/−14.2°）摆，Navcam 对到桅杆头。
  相机：对照_*（与真照片同位姿同内参，验证用）、人眼（车后 6 m、1.7 m 高）、高处（30 m 高俯瞰三角洲）。
运行：blender -b -P scripts/Blender/58_实景场景.py -- [时刻 13:07] [渲染] [采样 64]
     blender --online-mode DEM/Blender缓存/_素材/PDS/站26_1222/重建/实景_sol0530.blend   # 打开看
数据：NASA/JPL-Caltech/ASU/MSSS/University of Arizona/USGS。
"""
import json, math, pathlib, sys
import numpy as np
import bpy
from mathutils import Matrix, Vector

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import 火星大气 as AT

MAP = HERE.parent.parent
SITE = MAP/"DEM"/"Blender缓存"/"_素材"/"PDS"/"站26_1222"
EX = SITE/"重建"/"导出"
M_SB = np.array([[0, 1, 0], [1, 0, 0], [0, 0, -1]], float)
LAT = 18.45864728
DECL = math.asin(math.sin(math.radians(25.19))*math.sin(math.radians(286.9)))   # sol 530：Ls 286.9 → 赤纬 −24.0°
E_TOP = 1361/1.40**2                                                     # 大气顶太阳照度（W/m²），sol 530 日距 1.40 AU
ROVER_YPR = (-107.7939695, -1.871436595, -14.23768937)                   # 航向、俯仰、横滚（°，LOCAL_LEVEL 北东下）
BETA_AP = 0.67/10.8e3                                                    # 近地尘埃消光（/m）：τ/H
PIXEL_ANGLE = math.radians(60)/1920                                      # 像素角（rad）默认值：渲染时按每台相机的视野/宽度改
SKY_IMG = None                                                           # sky() 建好的天空图，空气透视要用
MAST_PARTS = ("head", "bottom", "bottom.001", "bottom.002", "bottom.003", "top", "probe.001",   # 桅杆：相机就在桅杆头里
              "arm", "arm.001", "arm.002", "arm.003", "arm.004", "arm_cable_etc")                  # 机械臂：模型是默认姿态，和当天不符
# 对照机位里把上面这些从相机视线里藏掉（影子照留）


def log(*a): print("[58]", *a, flush=True)


def sun_dir(ltst):
    """当地真太阳时 → ENU 太阳方向。"""
    hh, mm = (int(x) for x in ltst.split(":")[:2]); H = math.radians((hh + mm/60 - 12)*15)
    p, d = math.radians(LAT), DECL
    return np.array([-math.cos(d)*math.sin(H), math.cos(p)*math.sin(d) - math.sin(p)*math.cos(d)*math.cos(H),
                     math.sin(p)*math.sin(d) + math.cos(p)*math.cos(d)*math.cos(H)])


def ground(sc, J):
    z = np.load(EX/"地面网格.npz"); coll = bpy.data.collections.new("地面"); sc.collection.children.link(coll)
    mat = ground_material(J)
    for k in range(int(z["nring"])):
        V, F = z[f"V{k}"], z[f"F{k}"]
        me = bpy.data.meshes.new(f"地面_{k:02d}")
        me.vertices.add(len(V)); me.vertices.foreach_set("co", V.ravel())
        me.loops.add(F.size); me.loops.foreach_set("vertex_index", F.ravel())
        me.polygons.add(len(F)); me.polygons.foreach_set("loop_start", (np.arange(len(F))*4).astype(np.int32))
        me.update(calc_edges=True); me.validate()
        me.polygons.foreach_set("use_smooth", np.ones(len(F), bool))
        me.materials.append(mat)
        coll.objects.link(bpy.data.objects.new(f"地面_{k:02d}", me))
    log(f"地面 {int(z['nring'])} 环")


class NB:
    """节点小工具：少写样板。"""
    def __init__(self, nt): self.nt = nt; self.N = nt.nodes.new; self.L = nt.links.new

    def math(self, op, a, b=None, c=None, clamp=False):
        n = self.N("ShaderNodeMath"); n.operation = op; n.use_clamp = clamp
        for i, x in enumerate((a, b, c)):
            if x is None: continue
            if isinstance(x, (int, float)): n.inputs[i].default_value = x
            else: self.L(x, n.inputs[i])
        return n.outputs[0]

    def vmath(self, op, a, b=None, c=None):
        n = self.N("ShaderNodeVectorMath"); n.operation = op
        for i, x in enumerate((a, b, c)):
            if x is None: continue
            if isinstance(x, (tuple, list)): n.inputs[i].default_value = x
            elif isinstance(x, (int, float)): n.inputs["Scale"].default_value = x
            else: self.L(x, n.inputs[i])
        return n.outputs[1] if op in ("DOT_PRODUCT", "LENGTH", "DISTANCE") else n.outputs[0]

    def mix(self, fac, a, b, kind="RGBA", blend="MIX"):
        n = self.N("ShaderNodeMix"); n.data_type = kind; n.blend_type = blend
        if isinstance(fac, (int, float)): n.inputs[0].default_value = fac
        else: self.L(fac, n.inputs[0])
        ia, ib, out = {"RGBA": (6, 7, 2), "FLOAT": (2, 3, 0), "VECTOR": (4, 5, 1)}[kind]
        for i, x in ((ia, a), (ib, b)):
            if isinstance(x, (int, float)): n.inputs[i].default_value = x if kind == "FLOAT" else (x, x, x, 1)
            elif isinstance(x, tuple): n.inputs[i].default_value = x
            else: self.L(x, n.inputs[i])
        return n.outputs[out]

    def tex(self, path, vec, colorspace="sRGB", interp="Linear", ext="REPEAT"):
        t = self.N("ShaderNodeTexImage"); t.image = bpy.data.images.load(str(path), check_existing=True)
        t.image.colorspace_settings.name = colorspace; t.interpolation = interp; t.extension = ext
        self.L(vec, t.inputs["Vector"]); return t

    def rgb(self, c):
        n = self.N("ShaderNodeRGB"); n.outputs[0].default_value = (*c[:3], 1); return n.outputs[0]

    def val(self, v):
        n = self.N("ShaderNodeValue"); n.outputs[0].default_value = v; return n.outputs[0]



def ground_material(J):
    """自动地形着色器：数据（宏观反照率、地类）＋ 按数据分辨率门控的细节（中观/微观，随机平铺，按高度混合）＋ 凹凸 ＋ 空气透视。
    Godot 版照同一逻辑写（见 实景地形系统.md）。"""
    m = bpy.data.materials.new("火星表土"); m.use_nodes = True; nt = m.node_tree; nt.nodes.clear(); B = NB(nt)
    out = B.N("ShaderNodeOutputMaterial"); bs = B.N("ShaderNodeBsdfDiffuse"); bs.inputs["Roughness"].default_value = 0.8
    geo = B.N("ShaderNodeNewGeometry"); P = geo.outputs["Position"]
    sp = B.N("ShaderNodeSeparateXYZ"); B.L(P, sp.inputs[0])
    e = B.math("MAXIMUM", B.math("ABSOLUTE", sp.outputs[0]), B.math("ABSOLUTE", sp.outputs[1]))   # 方距离
    def region(half, feather=0.08):
        return B.math("MINIMUM", B.math("MAXIMUM", B.math("MULTIPLY", B.math("SUBTRACT", half*0.97, e), 1/(half*feather)), 0.0), 1.0)
    def uv(half):
        return B.vmath("MULTIPLY_ADD", P, (0.5/half, 0.5/half, 0), (0.5, 0.5, 0))
    # 1 宏观反照率 + 数据分辨率
    cur = B.rgb(J["tex"]["底色"]); res = B.val(J["data_res"]["CTX"]*4)
    for lv in ("CTX", "HiRISE", "中", "近"):
        t = J["tex"][lv]; tx = B.tex(EX/t["file"], uv(t["half"]), interp="Cubic" if lv == "CTX" else "Linear", ext="EXTEND")
        w = region(t["half"])
        if lv in ("中", "近"): w = B.math("MULTIPLY", w, tx.outputs["Alpha"])
        cur = B.mix(w, cur, tx.outputs["Color"]); res = B.mix(w, res, J["data_res"][lv], "FLOAT")
    # 2 地类权重（RGBA＝沙、砾石、基岩、暗色岩块）
    th = J["tex"]["地类_HiRISE"]; tm = J["tex"]["地类_中"]
    kh = B.tex(EX/th["file"], uv(th["half"]), "Non-Color", ext="EXTEND"); km = B.tex(EX/tm["file"], uv(tm["half"]), "Non-Color", ext="EXTEND")
    ksep = B.N("ShaderNodeSeparateColor"); B.L(km.outputs["Color"], ksep.inputs[0])
    ksum = B.math("ADD", B.math("ADD", ksep.outputs[0], ksep.outputs[1]), B.math("ADD", ksep.outputs[2], km.outputs["Alpha"]))
    wm = B.math("MULTIPLY", region(tm["half"], 0.15), B.math("MULTIPLY", ksum, 2.0, clamp=True))   # 中景地类没数据（四类全 0）→ 用 HiRISE 的
    cls_rgb = B.mix(wm, B.mix(region(th["half"]), (0.35, 0.35, 0.2, 1), kh.outputs["Color"]), km.outputs["Color"])
    cls_a = B.mix(wm, B.mix(region(th["half"]), 0.1, kh.outputs["Alpha"], "FLOAT"), km.outputs["Alpha"], "FLOAT")
    cs_ = B.N("ShaderNodeSeparateColor"); B.L(cls_rgb, cs_.inputs[0]); W = [cs_.outputs[0], cs_.outputs[1], cs_.outputs[2], cls_a]
    # 3 门控：中观只在数据比 4 cm 粗处；微观按像素足迹淡出（足迹 ≈ 距离 × 像素角）
    pa = B.N("ShaderNodeValue"); pa.name = pa.label = "像素角"; pa.outputs[0].default_value = PIXEL_ANGLE   # 渲染时按相机改
    cd = B.N("ShaderNodeCameraData"); fp = B.math("MULTIPLY", cd.outputs["View Distance"], pa.outputs[0])
    g_meso = B.math("DIVIDE", B.math("LOGARITHM", B.math("DIVIDE", res, 0.04), 2.0), math.log2(0.5/0.04), clamp=True)
    # 微观颗粒 1–5 mm：像素足迹 1 mm 起淡、8 mm 全无（再大就只剩重复图案和混叠）
    g_micro = B.math("SUBTRACT", 1.0, B.math("DIVIDE", B.math("LOGARITHM", B.math("MAXIMUM", B.math("DIVIDE", fp, 0.001), 1.0), 2.0), 3.0), clamp=True)
    # 随机平铺：两次采样（旋转 + 平移不同）用低频噪声混合
    noi = B.N("ShaderNodeTexNoise"); noi.inputs["Scale"].default_value = 1.3; noi.inputs["Detail"].default_value = 1.0
    B.L(P, noi.inputs["Vector"]); nmask = B.math("MULTIPLY", B.math("SUBTRACT", noi.outputs["Fac"], 0.5), 6.0)
    nmask = B.math("ADD", nmask, 0.5, clamp=True)
    def stoch(file, size, colorspace):
        a = B.tex(EX/file, B.vmath("SCALE", P, 1/size), colorspace)
        rot = B.N("ShaderNodeVectorRotate"); rot.rotation_type = "Z_AXIS"; rot.inputs["Angle"].default_value = 2.1
        B.L(B.vmath("ADD", B.vmath("SCALE", P, 1/size), (0.37, 0.71, 0)), rot.inputs["Vector"])
        b = B.tex(EX/file, rot.outputs[0], colorspace)
        return B.mix(nmask, a.outputs["Color"], b.outputs["Color"])
    hts, albs = [], []
    for k in range(4):
        dm, ds = J["detail"].get(f"微观_{k}"), J["detail"].get(f"中观_{k}")
        a_k = B.rgb((1, 1, 1)); h_k = B.val(0.0)
        if ds:
            Ad = B.vmath("SCALE", stoch(ds["albedo"], ds["size"], "Non-Color"), 2.0)
            a_k = B.mix(g_meso, a_k, Ad)
            Hd = B.math("MULTIPLY", B.math("SUBTRACT", stoch(ds["height"], ds["size"], "Non-Color"), 0.5), 2*ds["height_range"])
            h_k = B.math("MULTIPLY_ADD", Hd, g_meso, h_k)
        if dm:
            Ad = B.vmath("SCALE", stoch(dm["albedo"], dm["size"], "Non-Color"), 2.0)
            a_k = B.mix(g_micro, a_k, B.mix(1.0, a_k, Ad, blend="MULTIPLY"))
            Hd = B.math("MULTIPLY", B.math("SUBTRACT", stoch(dm["height"], dm["size"], "Non-Color"), 0.5), 2*dm["height_range"])
            h_k = B.math("MULTIPLY_ADD", Hd, g_micro, h_k)
        albs.append(a_k); hts.append(h_k)
    # 4 按高度混合（height blend）：w_k' ∝ W_k · exp((h_k − max h)/0.004)
    sc = [B.math("ADD", B.math("MULTIPLY", W[k], 1.0), 1e-4) for k in range(4)]
    hb = [B.math("MULTIPLY", sc[k], B.math("EXPONENT", B.math("DIVIDE", hts[k], 0.004))) for k in range(4)]
    tot = B.math("ADD", B.math("ADD", hb[0], hb[1]), B.math("ADD", hb[2], hb[3]))
    det = B.rgb((0, 0, 0)); hsum = B.val(0.0)
    for k in range(4):
        wk = B.math("DIVIDE", hb[k], tot)
        det = B.mix(1.0, det, B.mix(wk, (0, 0, 0, 1), albs[k]), blend="ADD")
        hsum = B.math("MULTIPLY_ADD", hts[k], wk, hsum)
    alb = B.mix(1.0, cur, det, blend="MULTIPLY")
    B.L(alb, bs.inputs["Color"])
    bump = B.N("ShaderNodeBump"); bump.inputs["Strength"].default_value = 1.0; bump.inputs["Distance"].default_value = 1.0
    B.L(hsum, bump.inputs["Height"]); B.L(bump.outputs[0], bs.inputs["Normal"])
    surf = bs.outputs[0]
    # 5 空气透视
    if SKY_IMG:
        T = B.math("EXPONENT", B.math("MULTIPLY", cd.outputs["View Distance"], -BETA_AP))
        inc = B.vmath("SCALE", geo.outputs["Incoming"], -1.0)
        s2 = B.N("ShaderNodeSeparateXYZ"); B.L(inc, s2.inputs[0])
        cb = B.N("ShaderNodeCombineXYZ"); B.L(s2.outputs[0], cb.inputs[0]); B.L(s2.outputs[1], cb.inputs[1])
        B.L(B.math("ADD", B.math("MAXIMUM", s2.outputs[2], 0.0), 0.02), cb.inputs[2])
        te = B.N("ShaderNodeTexEnvironment"); te.image = SKY_IMG; B.L(cb.outputs[0], te.inputs["Vector"])
        em = B.N("ShaderNodeEmission"); em.inputs["Strength"].default_value = E_TOP; B.L(te.outputs[0], em.inputs["Color"])
        mx = B.N("ShaderNodeMixShader"); B.L(B.math("SUBTRACT", 1.0, T), mx.inputs[0])
        B.L(surf, mx.inputs[1]); B.L(em.outputs[0], mx.inputs[2]); surf = mx.outputs[0]
    B.L(surf, out.inputs["Surface"])
    return m


def rock_material(J, base):
    """石块：底色（实测石块用对象色，统计石块用全局石色）× 每块随机明暗 × 基岩微观细节（三平面投影）＋ 凹凸。"""
    m = bpy.data.materials.new("火星石块"); m.use_nodes = True; nt = m.node_tree; nt.nodes.clear(); B = NB(nt)
    out = B.N("ShaderNodeOutputMaterial"); bs = B.N("ShaderNodeBsdfDiffuse"); bs.inputs["Roughness"].default_value = 0.6
    oi = B.N("ShaderNodeObjectInfo"); tc = B.N("ShaderNodeTexCoord")
    use_obj = B.math("GREATER_THAN", B.vmath("LENGTH", oi.outputs["Color"]), 0.01)
    col = B.mix(use_obj, B.rgb(base), oi.outputs["Color"])
    col = B.mix(1.0, col, B.mix(oi.outputs["Random"], (0.75, 0.75, 0.75, 1), (1.2, 1.15, 1.1, 1)), blend="MULTIPLY")
    d = J["detail"].get("微观_2") or J["detail"].get("微观_3")
    if d:
        vec = B.vmath("SCALE", tc.outputs["Object"], 1/d["size"])
        ta = B.tex(EX/d["albedo"], vec, "Non-Color"); ta.projection = "BOX"; ta.projection_blend = 0.3
        th = B.tex(EX/d["height"], vec, "Non-Color"); th.projection = "BOX"; th.projection_blend = 0.3
        col = B.mix(1.0, col, B.vmath("SCALE", ta.outputs["Color"], 2.0), blend="MULTIPLY")
        bump = B.N("ShaderNodeBump"); bump.inputs["Distance"].default_value = 1.0
        B.L(B.math("MULTIPLY", B.math("SUBTRACT", th.outputs["Color"], 0.5), 2*d["height_range"]), bump.inputs["Height"])
        B.L(bump.outputs[0], bs.inputs["Normal"])
    B.L(col, bs.inputs["Color"]); B.L(bs.outputs[0], out.inputs["Surface"])
    return m


def rocks_build(sc, J):
    z = np.load(EX/"石块.npz"); inst = json.loads(str(z["inst"])); cols = z["colors"]; S = z["scatter"]
    base = tuple(np.median(cols, 0).tolist()) if len(cols) else (0.25, 0.17, 0.12)
    mat = rock_material(J, base)
    real = bpy.data.collections.new("石块_实测"); sc.collection.children.link(real)
    lib = bpy.data.collections.new("石块库"); sc.collection.children.link(lib)
    for i, r in enumerate(inst):
        V, Ff = z[f"V{i}"], z[f"F{i}"]
        F, j = [], 0
        while j < len(Ff): F.append(Ff[j + 1:j + 1 + Ff[j]].tolist()); j += Ff[j] + 1   # 「顶点数, 索引…」平铺
        if not F: continue
        def mesh(name, V_):
            me = bpy.data.meshes.new(name); me.from_pydata(V_.tolist(), [], F); me.validate(); me.update()
            me.polygons.foreach_set("use_smooth", np.zeros(len(me.polygons), bool)); me.materials.append(mat); return me   # 平直着色：碎石的棱面
        ob = bpy.data.objects.new(f"石块_{i:03d}", mesh(f"石块_{i:03d}", V)); ob.location = r["pos"]
        ob.color = (*cols[i], 1); real.objects.link(ob)
        Vn = V.copy(); Vn[:, :2] /= r["D"]; Vn[:, 2] /= max(r["H"], 0.02)       # 归一成单位石块（直径 1、高 1）
        lo = bpy.data.objects.new(f"库_{i:03d}", mesh(f"库_{i:03d}", Vn)); lo.color = (0, 0, 0, 1)   # 对象色 0 → 材质用全局石色
        lib.objects.link(lo)
    lib.hide_render = True; bpy.context.view_layer.layer_collection.children["石块库"].exclude = True
    # 统计石块：点云 + 几何节点实例化
    if len(S):
        me = bpy.data.meshes.new("统计石块点"); me.vertices.add(len(S))
        P = S[:, :3].copy(); P[:, 2] -= 0.25*S[:, 3]*S[:, 6]                  # 埋入四分之一
        me.vertices.foreach_set("co", P.ravel())
        for name, col_ in (("D", 3), ("yaw", 4), ("seed", 5), ("aspect", 6)):
            at = me.attributes.new(name, "FLOAT", "POINT"); at.data.foreach_set("value", S[:, col_].astype(np.float32))
        ob = bpy.data.objects.new("统计石块", me); sc.collection.objects.link(ob)
        ob.color = (0, 0, 0, 1)                                            # 几何节点实例的「对象色」取自这个撒石对象，不是库里的石块
        ng = bpy.data.node_groups.new("撒石", "GeometryNodeTree")
        ng.interface.new_socket("Geometry", in_out="INPUT", socket_type="NodeSocketGeometry")
        ng.interface.new_socket("Geometry", in_out="OUTPUT", socket_type="NodeSocketGeometry")
        N, L = ng.nodes.new, ng.links.new
        gi, go = N("NodeGroupInput"), N("NodeGroupOutput")
        ci = N("GeometryNodeCollectionInfo"); ci.inputs["Collection"].default_value = lib
        ci.inputs["Separate Children"].default_value = True; ci.inputs["Reset Children"].default_value = True
        iop = N("GeometryNodeInstanceOnPoints"); iop.inputs["Pick Instance"].default_value = True
        def attr(name):
            a = N("GeometryNodeInputNamedAttribute"); a.data_type = "FLOAT"; a.inputs["Name"].default_value = name; return a.outputs["Attribute"]
        def m_(op, a, b):
            n = N("ShaderNodeMath"); n.operation = op
            for i, x in enumerate((a, b)):
                if isinstance(x, (int, float)): n.inputs[i].default_value = x
                else: L(x, n.inputs[i])
            return n.outputs[0]
        L(m_("FLOORED_MODULO", attr("seed"), float(len(inst))), iop.inputs["Instance Index"])
        rv = N("FunctionNodeRandomValue"); rv.data_type = "FLOAT_VECTOR"
        rv.inputs["Min"].default_value = (-0.35, -0.35, 0); rv.inputs["Max"].default_value = (0.35, 0.35, 0)
        L(attr("seed"), rv.inputs["Seed"]) if "Seed" in rv.inputs else None
        cr = N("ShaderNodeCombineXYZ"); sr = N("ShaderNodeSeparateXYZ"); L(rv.outputs["Value"], sr.inputs[0])
        L(sr.outputs[0], cr.inputs[0]); L(sr.outputs[1], cr.inputs[1]); L(attr("yaw"), cr.inputs[2])
        L(cr.outputs[0], iop.inputs["Rotation"])
        cs_ = N("ShaderNodeCombineXYZ"); L(attr("D"), cs_.inputs[0]); L(attr("D"), cs_.inputs[1]); L(m_("MULTIPLY", attr("D"), attr("aspect")), cs_.inputs[2])
        L(cs_.outputs[0], iop.inputs["Scale"])
        L(gi.outputs[0], iop.inputs["Points"]); L(ci.outputs[0], iop.inputs["Instance"]); L(iop.outputs[0], go.inputs[0])
        md = ob.modifiers.new("撒石", "NODES"); md.node_group = ng
    log(f"石块：实测 {len(inst)} 块（含补背面）+ 统计 {len(S):,} 块（几何节点实例）")


def sky(sc, s):
    """今天的火星天空（W/m²/sr）+ 太阳灯（W/m²）。"""
    AT.今天()
    atm = AT.Atmosphere()
    o = np.array([0, 0, AT.R - 2.52])
    L, E_sun_h, E_sky = AT.env_map(atm, o, s, w=1024, h=512, ground_albedo=0.22)
    T = atm.transmittance(np.array([-2.52]), np.array([s[2]]))[0]
    img = bpy.data.images.new("火星天空_今天", L.shape[1], L.shape[0], alpha=False, float_buffer=True)
    img.colorspace_settings.name = "Linear Rec.709"
    rgba = np.ones((L.shape[0], L.shape[1], 4), np.float32); rgba[..., :3] = L
    img.pixels.foreach_set(rgba.ravel()); img.pack()
    global SKY_IMG; SKY_IMG = img
    w = bpy.data.worlds.new("火星天空"); sc.world = w; nt = w.node_tree; nt.nodes.clear()
    te = nt.nodes.new("ShaderNodeTexEnvironment"); te.image = img
    bg = nt.nodes.new("ShaderNodeBackground"); bg.inputs["Strength"].default_value = E_TOP
    out = nt.nodes.new("ShaderNodeOutputWorld")
    nt.links.new(te.outputs[0], bg.inputs[0]); nt.links.new(bg.outputs[0], out.inputs[0])
    sun = bpy.data.lights.new("太阳", "SUN"); sun.angle = math.radians(0.38)
    Tm = float(np.mean(T)); sun.energy = E_TOP*Tm; sun.color = tuple((T/Tm).tolist())
    ob = bpy.data.objects.new("太阳", sun); sc.collection.objects.link(ob)
    ob.rotation_euler = Vector((-s).tolist()).to_track_quat("-Z", "Y").to_euler()
    log(f"太阳 高 {math.degrees(math.asin(s[2])):.1f}° 方位 {math.degrees(math.atan2(s[0], s[1])) % 360:.1f}°，"
        f"直射透过率 {np.round(T, 3)}，地面照度 直射 {E_TOP*float(np.mean(E_sun_h)):.0f} + 天光 {E_TOP*float(np.mean(E_sky)):.0f} W/m²")


def rover(sc, J):
    """导入 NASA 模型，按到站姿态摆好，Navcam 对到桅杆头。"""
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(SITE/"毅力号.glb"))
    new = [o for o in bpy.data.objects if o not in before]
    coll = bpy.data.collections.new("毅力号"); sc.collection.children.link(coll)
    for o in new:
        for c in list(o.users_collection): c.objects.unlink(o)
        coll.objects.link(o)
    nav = bpy.data.objects.get("NavCams")
    bpy.context.view_layer.update()
    pc = sum((nav.matrix_world @ Vector(c) for c in nav.bound_box), Vector())/8 if nav else Vector((-0.56, -0.77, 1.97))
    A = np.array([[0, -1, 0], [-1, 0, 0], [0, 0, -1]], float)              # 模型（车头 −Y、Z 上）→ 车体（X 前、Y 右、Z 下）
    y, p, r = (math.radians(v) for v in ROVER_YPR)
    Rz = np.array([[math.cos(y), -math.sin(y), 0], [math.sin(y), math.cos(y), 0], [0, 0, 1]])
    Ry = np.array([[math.cos(p), 0, math.sin(p)], [0, 1, 0], [-math.sin(p), 0, math.cos(p)]])
    Rx = np.array([[1, 0, 0], [0, math.cos(r), -math.sin(r)], [0, math.sin(r), math.cos(r)]])
    Rm = M_SB @ Rz @ Ry @ Rx @ A                                           # 模型 → ENU
    t = np.array(J["mast"]) - Rm @ np.array(pc)
    M4 = Matrix.Identity(4)
    for i in range(3):
        for j in range(3): M4[i][j] = Rm[i, j]
        M4[i][3] = t[i]
    root = bpy.data.objects.new("毅力号_位姿", None); coll.objects.link(root); root.matrix_world = M4
    for o in new:
        if o.parent is None: o.parent = root
    log(f"毅力号 {len(new)} 件，模型 Navcam {np.round(np.array(pc), 2)} → 桅杆头 {np.round(J['mast'], 2)}")


def camera(sc, name, loc, fwd, up=(0, 0, 1), lens=None, fov=None, W=1920, H=1080):
    cam = bpy.data.cameras.new(name); ob = bpy.data.objects.new(name, cam); sc.collection.objects.link(ob)
    f = Vector(fwd).normalized(); r = f.cross(Vector(up)).normalized(); u = r.cross(f)
    M = Matrix((r, u, -f)).transposed().to_4x4(); M.translation = Vector(loc); ob.matrix_world = M
    cam.sensor_fit = "HORIZONTAL"; cam.sensor_width = 36
    if lens: cam.lens = lens
    if fov: cam.angle = math.radians(fov)
    cam.clip_start = 0.02; cam.clip_end = 200000
    ob["res"] = (W, H)
    return ob


def build(opts):
    J = json.loads((EX/"场景.json").read_text())
    ltst = opts[opts.index("时刻") + 1] if "时刻" in opts else "13:07"
    spp = int(opts[opts.index("采样") + 1]) if "采样" in opts else 64
    bpy.ops.wm.read_homefile(use_empty=True)
    sc = bpy.context.scene
    s = sun_dir(ltst)
    sky(sc, s); ground(sc, J); rocks_build(sc, J); rover(sc, J)
    mast = np.array(J["mast"])
    cams = []
    for ref in J["refs"]:                                                  # 与真照片同位姿、同内参
        d = -np.array(ref["down"])
        cams.append(camera(sc, f"对照_{ref['file'][:4]}{ref['file'][18:27]}", ref["C"], ref["fwd"], up=d,
                           lens=ref["f"]/ref["W"]*36, W=ref["W"], H=ref["H"]))
    az = math.radians(ROVER_YPR[0] % 360)
    hd = np.array([math.sin(az), math.cos(az), 0])                          # 车头朝向（方位 252°，ENU）
    bpy.context.view_layer.update(); dg = bpy.context.evaluated_depsgraph_get()
    def ground_z(x, y):
        hit, p, *_ = sc.ray_cast(dg, Vector((x, y, 500)), Vector((0, 0, -1)))
        return p.z if hit else 0.0
    eye = mast - 6*hd; eye[2] = ground_z(*eye[:2]) + 1.7                   # 车后 6 m，人眼 1.7 m
    cams.append(camera(sc, "人眼", eye.tolist(), (hd + np.array([0, 0, -0.10])).tolist(), fov=60))
    hi = mast + np.array([18, 25, 0]); hi[2] = ground_z(*hi[:2]) + 30       # 东北 30 m 外、离地 30 m 往回俯瞰
    cams.append(camera(sc, "高处", hi.tolist(), (mast - hi + np.array([0, 0, -2])).tolist(), fov=65))
    sc.camera = cams[0]
    sc.render.engine = "CYCLES"; sc.cycles.samples = spp; sc.cycles.use_denoising = True
    prefs = bpy.context.preferences.addons["cycles"].preferences          # 测试机：OptiX
    for t in ("OPTIX", "CUDA"):
        try: prefs.compute_device_type = t; prefs.get_devices(); break
        except TypeError: continue
    gpu = [d for d in prefs.devices if d.type != "CPU"]
    for d in prefs.devices: d.use = d.type != "CPU"
    sc.cycles.device = "GPU" if gpu else "CPU"
    log(f"Cycles 设备：{[d.name for d in gpu] or 'CPU'}")
    sc.cycles.max_bounces = 4; sc.cycles.diffuse_bounces = 3
    sc.view_settings.view_transform = "Standard"; sc.view_settings.look = "None"
    sc.view_settings.exposure = -6.0                                        # W/m²/sr → 显示值；对照后再调
    sc.render.resolution_x, sc.render.resolution_y = 1920, 1080
    path = SITE/"重建"/"实景_sol0530.blend"
    bpy.ops.wm.save_as_mainfile(filepath=str(path), compress=True)
    log(f"→ {path}")
    if "渲染" in opts:
        outd = MAP/"产出"/"Blender"/"实景"; outd.mkdir(parents=True, exist_ok=True)
        roots = [o for o in bpy.data.objects if o.name in MAST_PARTS]
        mast_obs = list({x for o in roots for x in (o, *o.children_recursive)})   # 连同所有下级（炮塔、PIXL 挂在 arm.004 下面）
        for ob in cams:
            for o in mast_obs: o.visible_camera = not ob.name.startswith("对照")   # 相机就在桅杆头里
            sc.camera = ob; sc.render.resolution_x, sc.render.resolution_y = ob["res"]
            bpy.data.materials["火星表土"].node_tree.nodes["像素角"].outputs[0].default_value = ob.data.angle_x/ob["res"][0]
            sc.render.filepath = str(outd/f"{ob.name}_{ltst.replace(':', '')}.png")
            bpy.ops.render.render(write_still=True); log(f"  渲染 {ob.name}")


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    build(argv)
