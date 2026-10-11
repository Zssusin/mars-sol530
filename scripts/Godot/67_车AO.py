"""给毅力号烘自遮挡 AO（地形GI设计.md §9「车被照」）：Godot 里车用天空环境光，没有自遮挡，车头下方凹处发白。
做法：每个网格加第二套 UV「AO_UV」（Godot 的 UV2；材质只用第一套，多余的 UV 层删掉），全车 smart project + 一起打包进一张图集，
Cycles 只烘车自己（不放地面：地面在 Godot 里是下半球的光源，不是遮挡物），导出带 UV2 的 glb + 灰度 AO 图。
Godot（实景.gd build_rover）读到 rover_ao.glb / rover_ao.png 就给车的材质开 AO（ao_on_uv2，只压环境光）。
运行（fedora，用 GPU）：
  ~/.local/bin/blender -b --python scripts/Godot/67_车AO.py -- godot/数据/sol0530/rover.glb godot/数据/sol0530/rover_ao.glb godot/数据/sol0530/rover_ao.png [尺寸 4096] [采样 128] [AO 距离 m 1.0]
"""
import bpy, sys, math, time

a = sys.argv[sys.argv.index("--") + 1:]
SRC, OUT_GLB, OUT_PNG = a[0], a[1], a[2]
SIZE = int(a[3]) if len(a) > 3 else 4096
SAMPLES = int(a[4]) if len(a) > 4 else 128
DIST = float(a[5]) if len(a) > 5 else 1.0
t0 = time.time()
def log(*x): print("[67]", *x, flush=True)

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=SRC)
meshes = [o for o in bpy.data.objects if o.type == "MESH"]
log(f"导入 {len(meshes)} 个网格，{sum(len(o.data.polygons) for o in meshes)} 面")

# 1 UV：第 0 层留给材质（检查过：所有材质都用默认 UV），其余删掉，第 1 层 = AO_UV
for o in meshes:
    uvs = o.data.uv_layers
    if len(uvs) == 0:
        uvs.new(name="UVMap")
    while len(uvs) > 1:
        uvs.remove(uvs[1])
    ao = uvs.new(name="AO_UV")
    uvs[0].active_render = True
    uvs.active = ao
    if not o.data.materials:
        o.data.materials.append(bpy.data.materials.new("无材质"))

# 2 每个物体单独展开、打包进自己的 [0,1]，再按 √面积（有下限）分图块、货架法排进一张图集。
#   全车一起按面积打包时，NavCams、转轴这类小件只分到不到一个像素，烘不上（第一版 15 个物体全黑）。
import bmesh
def area(o):
    bm = bmesh.new(); bm.from_mesh(o.data); bm.transform(o.matrix_world)
    a = sum(f.calc_area() for f in bm.faces); bm.free(); return a
for o in meshes:
    bpy.ops.object.select_all(action="DESELECT"); o.select_set(True); bpy.context.view_layer.objects.active = o
    bpy.ops.object.mode_set(mode="EDIT"); bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=math.radians(66), island_margin=0.01, scale_to_bounds=True)
    bpy.ops.uv.pack_islands(rotate=True, margin=0.01)
    bpy.ops.object.mode_set(mode="OBJECT")
A = {o.name: max(area(o), 1e-6) for o in meshes}
S_MIN = 48.0/SIZE; PAD = 4.0/SIZE
def shelf(k):
    tiles = sorted(((max(k*math.sqrt(A[o.name]), S_MIN), o) for o in meshes), key=lambda t: -t[0])
    x = y = 0.0; row = 0.0; pos = {}
    for s_, o in tiles:
        if x + s_ > 1.0 + 1e-9: x = 0.0; y += row + PAD; row = 0.0
        pos[o.name] = (x, y, s_); x += s_ + PAD; row = max(row, s_)
    return pos, y + row
k = 1.0/math.sqrt(sum(A.values()))                               # Σ s² ≈ 1 的初值，往下缩到装得下
while True:
    pos, h = shelf(k)
    if h <= 1.0: break
    k *= 0.97
for o in meshes:
    x0, y0, s_ = pos[o.name]
    d = o.data.uv_layers["AO_UV"].data
    for l in d: l.uv = (x0 + l.uv[0]*s_, y0 + l.uv[1]*s_)
sz = sorted(p_[2]*SIZE for p_ in pos.values())
log(f"UV：{len(meshes)} 块，图块边长 {sz[0]:.0f}–{sz[-1]:.0f} px（中位 {sz[len(sz)//2]:.0f}），占高 {h:.2f}，{time.time() - t0:.1f} s")

# 3 烘焙：每个材质放一个选中的图像节点（不连线，导出时不带出去）
img = bpy.data.images.new("rover_ao", SIZE, SIZE, alpha=False, float_buffer=False, is_data=True)
img.colorspace_settings.name = "Non-Color"
nodes_added = []
for m in {m for o in meshes for m in o.data.materials if m}:
    m.use_nodes = True
    nt = m.node_tree
    n = nt.nodes.new("ShaderNodeTexImage"); n.image = img
    uvn = nt.nodes.new("ShaderNodeUVMap"); uvn.uv_map = "AO_UV"
    nt.links.new(uvn.outputs["UV"], n.inputs["Vector"])
    for x in nt.nodes: x.select = False
    n.select = True; nt.nodes.active = n
    nodes_added.append((m, n, uvn))

sc = bpy.context.scene
sc.render.engine = "CYCLES"
pr = bpy.context.preferences.addons["cycles"].preferences
for dev in ("OPTIX", "CUDA"):
    try:
        pr.compute_device_type = dev; pr.get_devices()
        if any(d.type == dev for d in pr.devices): break
    except TypeError:
        continue
for d in pr.devices: d.use = d.type != "CPU"
sc.cycles.device = "GPU"
sc.cycles.samples = SAMPLES
sc.world = sc.world or bpy.data.worlds.new("w")
sc.world.light_settings.distance = DIST
sc.render.bake.margin = 6
log(f"烘焙 {SIZE}² × {SAMPLES} 采样，AO 距离 {DIST} m，设备 {pr.compute_device_type}")
t1 = time.time()
bpy.ops.object.select_all(action="DESELECT")
for o in meshes: o.select_set(True)
bpy.context.view_layer.objects.active = meshes[0]
bpy.ops.object.bake(type="AO", margin=6, use_clear=True, target="IMAGE_TEXTURES")
log(f"烘焙 {time.time() - t1:.1f} s")
img.filepath_raw = OUT_PNG; img.file_format = "PNG"
img.save()
px = img.pixels[:]  # RGBA float
import statistics
r = px[0::4]
log(f"AO 图存 {OUT_PNG}，均值 {sum(r)/len(r):.3f}（含空白处）")

# 4 去掉烘焙节点，导出带 UV2 的 glb
for m, n, uvn in nodes_added:
    m.node_tree.nodes.remove(n); m.node_tree.nodes.remove(uvn)
for o in meshes:
    o.data.uv_layers.active = o.data.uv_layers[0]
bpy.ops.object.select_all(action="DESELECT")
bpy.ops.export_scene.gltf(filepath=OUT_GLB, export_format="GLB", export_texcoords=True, export_normals=True,
                          export_materials="EXPORT", export_image_format="AUTO", export_yup=True)
log(f"导出 {OUT_GLB}，共 {time.time() - t0:.1f} s")
