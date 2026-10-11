"""
火星实拍素材：NASA PDS 里毅力号 Navcam 立体重建的地面网格（mars2020_navcam_ops_mesh，OBJ + 原始照片贴图，单位 m，
站点坐标 X 北、Y 东、Z 朝下）→ 近场正交烘焙 → ① 可平铺的地面贴图（亮度 + 高度，换掉地球上的 Poly Haven 扫描）
② 石块库（凸出地面的连通块，2.5D 高度场石块，53 里实例化）。
取三角洲前缘（sol 420–600）：层状沉积坡脚 + 碎石，和梅拉斯的镜头最像。数据：NASA/JPL-Caltech，PDS Imaging Node。

  python3 scripts/Blender/54_火星素材.py 下载                                  # 系统 Python
  blender -b --factory-startup -P scripts/Blender/54_火星素材.py -- 烘焙       # 后台 Blender（Cycles CPU，不占界面的显存）
  .venv/bin/python scripts/Blender/54_火星素材.py 素材                         # 切地面贴图、分割石块（scipy）
"""
import json, math, pathlib, re, sys, urllib.request
import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
MAP = HERE.parent.parent
DIR = MAP/"DEM"/"Blender缓存"/"_素材"/"PDS"
URL = "https://planetarydata.jpl.nasa.gov/img/data/mars2020/mars2020_navcam_ops_mesh/data/sol/{:05d}/ids/rdr/mesh/"
SOLS = (420, 436, 449, 461, 490, 502, 521, 530, 541, 553, 566, 593)   # 三角洲前缘（Hawksbill Gap 一带）
PER_SOL = 2                                  # 每个 sol 取最大的两个楔块（顶点多＝近场地面多）
WIN = 4.0                                    # 烘焙窗口边长（m），取顶点最密处
PX = 2048                                    # → 约 2 mm 一像素


def log(*a): print("[54]", *a, flush=True)


# ── 下载 ───────────────────────────────────────────────────────────
def download():
    DIR.mkdir(parents=True, exist_ok=True)
    got = []
    for sol in SOLS:
        html = urllib.request.urlopen(URL.format(sol), timeout=60).read().decode()
        rows = re.findall(r'href="(N[A-Z0-9_]+)\.obj".*?>\s*([\d.]+)([KM])\s*<', html)
        size = {b: float(n)*(1024 if u == "M" else 1) for b, n, u in rows}
        for base in sorted(size, key=size.get, reverse=True)[:PER_SOL]:
            for ext in ("obj", "mtl", "png"):
                p = DIR/f"{base}.{ext}"
                if not p.exists():
                    urllib.request.urlretrieve(URL.format(sol) + f"{base}.{ext}", p)
            got.append(base); log(f"sol {sol}: {base}（{size[base]/1024:.0f} MB）")
    (DIR/"清单.json").write_text(json.dumps(got, indent=1))


# ── 烘焙（Blender）────────────────────────────────────────────────
def bake(*objs):
    """objs：指定的 .obj 路径（测试用）；不给就按 清单.json。"""
    import bpy
    out_dir = DIR/"烘焙"; out_dir.mkdir(exist_ok=True)
    paths = [pathlib.Path(o) for o in objs] or [DIR/f"{b}.obj" for b in json.loads((DIR/"清单.json").read_text())]
    for path in paths:
        base = path.stem
        dst = out_dir/f"{base}.npz"
        if dst.exists(): continue
        bpy.ops.wm.read_factory_settings(use_empty=True)
        bpy.ops.wm.obj_import(filepath=str(path), forward_axis="Y", up_axis="Z")   # 不转轴：保持 X 北 Y 东 Z 下
        ob = bpy.context.selected_objects[0]; me = ob.data
        V = np.empty(len(me.vertices)*3); me.vertices.foreach_get("co", V); V = V.reshape(-1, 3)
        # 顶点最密的 WIN×WIN 窗口（0.5 m 格子计数，滑窗求和）
        c = 0.5; k = int(WIN/c)
        xe = np.arange(V[:, 0].min(), V[:, 0].max() + c, c); ye = np.arange(V[:, 1].min(), V[:, 1].max() + c, c)
        H, _, _ = np.histogram2d(V[:, 0], V[:, 1], bins=[xe, ye])
        if H.shape[0] < k or H.shape[1] < k: log(base, "太小，跳过"); continue
        S = np.lib.stride_tricks.sliding_window_view(H, (k, k)).sum((2, 3))
        i, j = np.unravel_index(S.argmax(), S.shape)
        x0, y0 = xe[i], ye[j]; cx, cy = x0 + WIN/2, y0 + WIN/2
        sel = (abs(V[:, 0] - cx) < WIN/2) & (abs(V[:, 1] - cy) < WIN/2)
        log(base, f"窗口中心 ({cx:.1f}, {cy:.1f})，{int(sel.sum()):,} 顶点（间距约 {WIN/math.sqrt(max(sel.sum(), 1))*100:.1f} cm）")
        zc = float(np.median(V[sel, 2]))
        sc = bpy.context.scene; sc.render.engine = "CYCLES"; sc.cycles.device = "CPU"
        sc.render.resolution_x = sc.render.resolution_y = PX; sc.render.film_transparent = True
        sc.cycles.filter_width = 0.01; sc.view_settings.view_transform = "Standard"
        cam = bpy.data.objects.new("俯视", bpy.data.cameras.new("俯视")); sc.collection.objects.link(cam); sc.camera = cam
        cam.data.type = "ORTHO"; cam.data.ortho_scale = WIN; cam.data.clip_end = 500
        cam.location = (cx, cy, zc - 100); cam.rotation_euler = (math.pi, 0, math.pi/2)   # 从上（−Z）往下看；图像上＝北、右＝东
        img = next(n.image for m in me.materials for n in m.node_tree.nodes if n.bl_idname == "ShaderNodeTexImage")
        def emit(build):
            mat = bpy.data.materials.new("烘"); nt = mat.node_tree; nt.nodes.clear()
            o = nt.nodes.new("ShaderNodeOutputMaterial"); e = nt.nodes.new("ShaderNodeEmission")
            nt.links.new(build(nt), e.inputs["Color"]); nt.links.new(e.outputs[0], o.inputs["Surface"])
            me.materials.clear(); me.materials.append(mat)
        def col(nt):
            t = nt.nodes.new("ShaderNodeTexImage"); t.image = img; t.interpolation = "Cubic"; return t.outputs["Color"]
        def hgt(nt):                                                         # 发光＝200 − z（m，朝上为正，保证正值）
            g = nt.nodes.new("ShaderNodeNewGeometry"); s = nt.nodes.new("ShaderNodeSeparateXYZ")
            m = nt.nodes.new("ShaderNodeMath"); m.operation = "SUBTRACT"; m.inputs[0].default_value = 200.0
            nt.links.new(g.outputs["Position"], s.inputs[0]); nt.links.new(s.outputs[2], m.inputs[1])
            cc = nt.nodes.new("ShaderNodeCombineColor"); [nt.links.new(m.outputs[0], cc.inputs[q]) for q in range(3)]
            return cc.outputs[0]
        res = {}
        for name, build, spp in (("色", col, 4), ("高", hgt, 1)):
            emit(build); sc.cycles.samples = spp
            s_ = sc.render.image_settings; s_.file_format = "OPEN_EXR"; s_.color_depth = "32"; s_.color_mode = "RGBA"
            tmp = out_dir/f"_{name}.exr"; sc.render.filepath = str(tmp)
            bpy.ops.render.render(write_still=True)
            im = bpy.data.images.load(str(tmp)); a = np.empty(PX*PX*4, np.float32); im.pixels.foreach_get(a)
            res[name] = a.reshape(PX, PX, 4)[::-1]; bpy.data.images.remove(im); tmp.unlink()
        alpha = res["高"][..., 3] > 0.99
        h = np.where(alpha, 200.0 - res["高"][..., 0], np.nan).astype(np.float32)
        np.savez_compressed(dst, color=res["色"][..., :3].astype(np.float16), height=h, alpha=alpha,
                            px=WIN/PX, center=(cx, cy), sol=int(base[4:8]))
        log(f"  → {dst.name}：覆盖 {alpha.mean()*100:.0f}%")


# ── 出素材（venv，scipy）─────────────────────────────────────────────
TILE = 1.6                                   # 地面贴图边长（m）


def _mgauss(ndi, v, m, s):
    """带掩膜的高斯平均（洞不参与）。"""
    return ndi.gaussian_filter(np.where(m, v, 0.0), s)/np.maximum(ndi.gaussian_filter(m.astype(np.float64), s), 1e-6)


def materials():
    """烘焙图 → ① 地面贴图：亮度（线性）+ 高度（m）。网格高度只取 σ1.5 cm 以上（ops 网格是多分辨率拼的，
    粗块是阶梯、细处有匹配皱纹），更细的起伏由照片亮度的高频推（照片里有真太阳照出来的明暗，Substance /
    Materialize 的「由亮度生成高度」同理）。挑覆盖完整、伪影能量低的方块，羽化成可平铺。
    ② 石块库：高出地面趋势（σ30 cm，剔除石块后重算）2 cm 以上的连通块，直径 6–80 cm、不贴边、背面缺口少。"""
    import scipy.ndimage as ndi
    out = DIR/"素材"; out.mkdir(exist_ok=True)
    tiles, rocks = [], []
    for f in sorted((DIR/"烘焙").glob("*.npz")):
        z = np.load(f); a = z["alpha"].copy(); px = float(z["px"])
        h = -np.nan_to_num(z["height"].astype(np.float64))                 # 烘焙存的是 Z（朝下）→ 高度朝上
        # 离群：多分辨率拼块间的竖直「帘子」和远处碎片会投进窗口（±100 m）；和 6 cm 尺度的中值差 25 cm 以上的当洞
        q = 4; hf = h[tuple(ndi.distance_transform_edt(~a, return_distances=False, return_indices=True))]   # 中值滤波不认 NaN：先最近邻填洞
        med = ndi.median_filter(hf[::q, ::q], size=15, mode="nearest")
        a &= np.abs(h - np.kron(med, np.ones((q, q)))[:h.shape[0], :h.shape[1]]) < 0.25
        a = ndi.binary_opening(a, iterations=2)
        if a.mean() < 0.2: continue
        col = z["color"].astype(np.float32)
        lum = col @ np.array([0.2126, 0.7152, 0.0722], np.float32)
        idx = ndi.distance_transform_edt(~a, return_distances=False, return_indices=True)   # 洞先用最近邻填上
        h = h[tuple(idx)]; lum = lum[tuple(idx)]; col = col[tuple(idx)]
        s_g = 0.30/px
        g = _mgauss(ndi, h, a, s_g); r = h - g
        g = _mgauss(ndi, h, a & (r < 0.02), s_g); r = h - g              # 剔除石块再算地面
        h_lo = ndi.gaussian_filter(r, 0.025/px)                          # 网格只信到 2.5 cm（边长中位 2.4 cm，1/4 的三角形是歪的）
        art = np.sqrt(ndi.gaussian_filter((r - h_lo)**2, 0.05/px))       # 伪影能量（网格高频）
        l_lp = ndi.gaussian_filter(lum, 0.05/px)
        l_hp = lum/np.maximum(l_lp, 1e-4) - 1.0                          # 亮度高频（相对）
        h_det = ndi.gaussian_filter(l_hp, 1.0) - ndi.gaussian_filter(l_hp, 0.025/px)   # 2 mm–2.5 cm：亮＝凸
        # ── 地面贴图 ──
        T = int(TILE/px); cov = ndi.uniform_filter(a.astype(np.float64), T); bad = ndi.uniform_filter(art, T)
        score = np.where(cov > 0.97, -bad, -np.inf)                          # 3% 以内的小洞（石块背后）已最近邻填
        for _ in range(2):                                               # 每个烘焙图最多两块，互不重叠
            i, j = np.unravel_index(np.argmax(score), score.shape)
            if not np.isfinite(score[i, j]): break
            sl = (slice(i - T//2, i - T//2 + T), slice(j - T//2, j - T//2 + T))
            if sl[0].start < 0 or sl[1].start < 0 or sl[0].stop > a.shape[0] or sl[1].stop > a.shape[1]:
                score[max(i - T//2, 0):i + T//2, max(j - T//2, 0):j + T//2] = -np.inf; continue
            tiles.append(dict(src=f.stem, lum=lum[sl], lp=l_lp[sl], hl=h_lo[sl], hd=h_det[sl], col=col[sl],
                              art=float(art[sl].mean()), rock=float((r[sl] > 0.02).mean())))
            score[max(i - T, 0):i + T, max(j - T, 0):j + T] = -np.inf
        # ── 石块 ──
        lab, n = ndi.label((h_lo > 0.03) & a)                             # 平滑后高出地面 3 cm
        for k, sl in enumerate(ndi.find_objects(lab), 1):
            m = lab[sl] == k
            d = 2*math.sqrt(m.sum()/math.pi)*px
            if not 0.06 <= d <= 0.8: continue
            if sl[0].start < 4 or sl[1].start < 4 or sl[0].stop > a.shape[0] - 4 or sl[1].stop > a.shape[1] - 4: continue
            pad = max(4, int(0.15*d/px))
            big = (slice(max(sl[0].start - pad, 0), sl[0].stop + pad), slice(max(sl[1].start - pad, 0), sl[1].stop + pad))
            mk = ndi.binary_dilation(lab[big] == k, iterations=3)          # 带一圈石脚
            hole = (~a[big]) & ndi.binary_dilation(mk, iterations=6)
            if hole.sum() > 0.25*mk.sum(): continue                       # 背后看不见的部分太多
            if m.sum() > 30:                                               # 凸度：伪影块方方正正、带枝杈，真石块接近凸
                from scipy.spatial import ConvexHull
                yx = np.argwhere(m)
                if m.sum()/max(ConvexHull(yx).volume, 1) < 0.75: continue
            if art[sl][m].mean() > 0.006: continue                          # 块里网格高频太大＝匹配噪声
            rr = np.where(mk, np.maximum(h_lo[big], 0.0), 0.0)
            if rr.max() < 0.03: continue
            rocks.append(dict(src=f.stem, h=rr.astype(np.float32), mask=mk, col=col[big].astype(np.float16), d=d))
        log(f"{f.stem}：贴图候选 {len(tiles)}，石块累计 {len(rocks)}")
    # 平铺：每块和自己错开半幅的副本按窗口羽化（边上全是副本、中间全是原图 ⇒ 四边能接上）
    def tileable(x):
        n = x.shape[0]; w1 = np.sin(np.linspace(0, math.pi, n))**2; W = np.outer(w1, w1)
        return W*x + (1 - W)*np.roll(x, (n//2, n//2), (0, 1))
    pack = {}
    for t_i, t in enumerate(sorted(tiles, key=lambda t: t["art"])[:8]):
        lum_n = t["lum"]/np.maximum(t["lp"], 1e-4)                         # 去掉 5 cm 以上的明暗（照明 + 大斑）
        pack[f"t{t_i}_lum"] = tileable(lum_n).astype(np.float32)
        pack[f"t{t_i}_hl"] = tileable(t["hl"]).astype(np.float32)
        pack[f"t{t_i}_hd"] = tileable(t["hd"]).astype(np.float32)
        pack[f"t{t_i}_col"] = np.stack([tileable(t["col"][..., c]) for c in range(3)], -1).astype(np.float16)
        pack[f"t{t_i}_rock"] = np.float32(t["rock"]); pack[f"t{t_i}_art"] = np.float32(t["art"])
        log(f"贴图 t{t_i}：{t['src'][:8]} 伪影 {t['art']*1000:.1f} mm，石块占 {t['rock']*100:.1f}%")
    np.savez_compressed(out/"地面贴图.npz", px=px, n=len([k for k in pack if k.endswith("_lum")]), **pack)
    rocks.sort(key=lambda q: -q["d"])
    np.savez_compressed(out/"石块库.npz", n=len(rocks), px=px,
                        **{f"r{i}_{k}": q[k] for i, q in enumerate(rocks) for k in ("h", "mask", "col")},
                        d=np.array([q["d"] for q in rocks]))
    log(f"→ 地面贴图 {len(pack)//4} 块，石块 {len(rocks)} 块（直径 {rocks[-1]['d']*100:.0f}–{rocks[0]['d']*100:.0f} cm）" if rocks else "没有石块")


if __name__ == "__main__":
    try:
        import bpy  # noqa
        argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    except ImportError:
        argv = sys.argv[1:]
    step = argv[0] if argv else "下载"
    {"下载": download, "烘焙": bake, "素材": materials}[step](*argv[1:])
