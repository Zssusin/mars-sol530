# CDLOD 地面（Strugar 2009，"Continuous Distance-Dependent Level of Detail for Rendering Heightmaps"）。
#   四叉树按到相机的距离选块：第 l 级的块边长 m·c0·2^l、格距 c0·2^l，只在 R_l = R_0·2^l 以内用。
#   所有块共用一张 m×m 格网；顶点着色器（地形.gdshader 的 clip 分支）从 15 层嵌套高度图取高，
#   并在每级可见半径的最后 30% 里把奇数格点并到偶数格点上（几何渐变），与外面粗一级的块无缝相接。
#   每块是一个 RenderingServer 实例（单独的包围盒）→ Godot 对主相机和每层阴影级联分别剔除。
#   疏密：R_0 = c0 /（目标三角形像素 × 每像素角）—— 相机越近越密，按屏幕像素而不是按离车距离。
extends Node3D

var m := 64                                   # 每块格数（偶数）
var c0 := 0.01                                # 第 0 级格距（m）：比近层数据（2 cm）细，给中观位移用；按像素定疏密，所以不更贵
var tri_px := 8.0                             # 每级可见半径外缘处一格约多少像素
var L := 18                                   # 级数：第 17 级块边长 1.28·2^17 ≈ 168 km
var R: Array[float] = []
var range0 := 6.0
var W := 98304.0                              # 数据范围半宽（最外一环）
var shadows := true

var hl: Array[PackedFloat32Array] = []        # CPU 一份高度层（算包围盒）
var hN := 601; var hc0 := 0.02; var hh0 := 6.0; var hL := 15
var mesh: ArrayMesh                           # m×m：整块
var mesh_q: ArrayMesh                         # (m/2)×(m/2)：父块落在近区外的那 1/4，按父级格距画、随父级渐变
var mat: ShaderMaterial
var mats: Array[ShaderMaterial] = []           # 另外也要每帧更新 lod_cam / lod_range0 的材质（石块：中观位移）
var scenario: RID
var live := {}                                # 键 → 实例 RID
var box := {}                                 # 键 → [hmin, hmax]（缓存）
var n_sel := 0
var n_new := 0; var n_del := 0                 # 测帧诊断：上次 update 新建 / 删掉的块
var geo: RefCounted = null                     # 地貌印章 CPU 版（地貌.gd）：h_cpu 加上它，车轮、撒石和画出来的地面一致


func setup(J: Dictionary, D: String, material: ShaderMaterial, args: Dictionary) -> void:
	mat = material
	m = int(args.get("块格", "64")); c0 = float(args.get("地面格", "0.01")); tri_px = float(args.get("地面像素", "8"))
	shadows = args.get("地影", "1") == "1"
	var H: Dictionary = J["heights"]
	hN = int(H["N"]); hc0 = float(H["c0"]); hh0 = float(H["half0"]); hL = int(H["L"])
	W = hh0*pow(2.0, hL - 1)
	var b := FileAccess.get_file_as_bytes(D + H["file"])
	var imgs: Array[Image] = []
	for k in hL:
		var o := 8 + k*hN*hN*4
		var raw := b.slice(o, o + hN*hN*4)
		hl.append(raw.to_float32_array())
		imgs.append(Image.create_from_data(hN, hN, false, Image.FORMAT_RF, raw))
	var tex := Texture2DArray.new(); tex.create_from_images(imgs)
	mat.set_shader_parameter("hlv", tex)
	mat.set_shader_parameter("hlv_info", Vector4(hc0, hh0, hN, hL))
	mat.set_shader_parameter("lod_c0", c0)
	mat.set_shader_parameter("clip", true)
	mesh = grid(m); mesh_q = grid(m/2)
	scenario = get_world_3d().scenario
	print("[实景] CDLOD 地面：每块 %d×%d，c0 %.3f m，%d 级，目标 %.0f 像素/格" % [m, m, c0, L, tri_px])


func grid(n: int) -> ArrayMesh:
	"""n×n 格网，顶点就是整数格坐标 (i, 0, j)；块的变换 = 缩放格距再平移到块角。"""
	var V := PackedVector3Array(); var I := PackedInt32Array()
	for j in n + 1:
		for i in n + 1: V.append(Vector3(i, 0, j))
	for j in n:
		for i in n:
			var a := j*(n + 1) + i
			I.append_array([a, a + 1, a + n + 2, a, a + n + 2, a + n + 1])   # 从上往下看顺时针 = Godot 正面
	var arr := []; arr.resize(Mesh.ARRAY_MAX); arr[Mesh.ARRAY_VERTEX] = V; arr[Mesh.ARRAY_INDEX] = I
	var N := PackedVector3Array(); N.resize(V.size()); N.fill(Vector3.UP); arr[Mesh.ARRAY_NORMAL] = N
	var am := ArrayMesh.new(); am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return am


func _exit_tree() -> void:
	for k in live: RenderingServer.free_rid(live[k])
	live.clear()


# ———— CPU 取高：数据层（和着色器同样选层、同样混合）+ 地貌印章。包围盒只用数据层 + 印章余量（快）
func h_cpu(x: float, z: float, kmin: int) -> float:
	return h_data(x, z, kmin) + (geo.h(x, z) if geo else 0.0)


func h_data(x: float, z: float, kmin: int) -> float:
	"""同 地形.gdshader hl_level + hl_height：包含该点的最细层，外缘 10% 里线性混到粗一层（不细于 kmin）。"""
	var e := maxf(absf(x), absf(z))
	var k0 := maxf(0.0, ceilf(log(maxf(e, 1e-6)/(hh0*0.98))/log(2.0)))
	var hk := hh0*pow(2.0, k0)
	var kf := minf(maxf(k0 + clampf((e - 0.9*hk)/(0.08*hk), 0.0, 1.0), kmin), hL - 1.0)
	var k := int(kf); var t := kf - k
	var a := h_level(x, z, k)
	if t > 0.0: a = lerpf(a, h_level(x, z, k + 1), t)
	return a


func h_level(x: float, z: float, k: int) -> float:
	var c := hc0*pow(2.0, k); var h := hh0*pow(2.0, k)
	var fx := clampf((x + h)/c, 0.0, hN - 1.001); var fz := clampf((z + h)/c, 0.0, hN - 1.001)
	var i := int(fx); var j := int(fz); var tx := fx - i; var tz := fz - j
	var a := hl[k]; var o := j*hN + i
	return lerpf(lerpf(a[o], a[o + 1], tx), lerpf(a[o + hN], a[o + hN + 1], tx), tz)


func node_box(l: int, x0: float, z0: float, s: float) -> Array:
	var key := Vector3i(l, roundi(x0/s), roundi(z0/s))
	if box.has(key): return box[key]
	var kmin := clampi(l + roundi(log(c0/hc0)/log(2.0)), 0, hL - 1)
	var lo := INF; var hi := -INF
	for j in 9:
		for i in 9:
			var h := h_data(x0 + s*i/8.0, z0 + s*j/8.0, kmin)
			lo = minf(lo, h); hi = maxf(hi, h)
	var mg := 0.05*s + 0.3                                          # 9×9 采样之间可能漏掉的起伏
	if geo: mg += geo.margin(maxf(maxf(absf(x0), absf(x0 + s)), maxf(absf(z0), absf(z0 + s))))
	var r := [lo - mg, hi + mg]; box[key] = r
	return r


func hits(cam: Vector3, x0: float, z0: float, s: float, b: Array, r: float) -> bool:
	var q := Vector3(clampf(cam.x, x0, x0 + s), clampf(cam.y, b[0], b[1]), clampf(cam.z, z0, z0 + s))
	return q.distance_squared_to(cam) <= r*r


func sel(cam: Vector3, l: int, x0: float, z0: float, out: Array) -> bool:
	var s := m*c0*pow(2.0, l)
	if x0 >= W or z0 >= W or x0 + s <= -W or z0 + s <= -W: return true    # 数据外：不画，也不让父级补
	var b := node_box(l, x0, z0, s)
	if not hits(cam, x0, z0, s, b, R[l]): return false
	if l == 0 or not hits(cam, x0, z0, s, b, R[l - 1]):
		out.append([l, x0, z0, b, 0]); return true
	var hs := s*0.5
	for c in [Vector2(0, 0), Vector2(hs, 0), Vector2(0, hs), Vector2(hs, hs)]:
		if not sel(cam, l - 1, x0 + c.x, z0 + c.y, out):
			# 子块整个在 R_{l−1} 外：按本级（父级）格距画这 1/4，和旁边整块的同级邻居按同一规则渐变（Strugar 的做法）
			out.append([l, x0 + c.x, z0 + c.y, node_box(l - 1, x0 + c.x, z0 + c.y, hs), 1])
	return true


func update(cam: Vector3, pixel_angle: float) -> void:
	range0 = maxf(c0/(tri_px*pixel_angle), 3.0*m*c0)                 # 相邻块最多差一级：R_0 ≥ 2√2·块边长
	R.clear()
	for l in L: R.append(range0*pow(2.0, l))
	for mt in [mat] + mats:
		mt.set_shader_parameter("lod_cam", cam); mt.set_shader_parameter("lod_range0", range0)
	var out := []
	var s := m*c0*pow(2.0, L - 1); var nr := ceili(W/s)
	for j in range(-nr, nr):
		for i in range(-nr, nr): sel(cam, L - 1, i*s, j*s, out)
	var want := {}; n_new = 0; n_del = 0
	for nd in out:
		var l: int = nd[0]; var q: int = nd[4]; var n := m >> q; var c := c0*pow(2.0, l)
		var key := Vector4i(l, roundi(nd[1]/(n*c)), roundi(nd[2]/(n*c)), q)
		want[key] = true
		if live.has(key): continue
		var b: Array = nd[3]
		var rid := RenderingServer.instance_create2((mesh_q if q else mesh).get_rid(), scenario)
		RenderingServer.instance_set_transform(rid, Transform3D(Basis.from_scale(Vector3(c, 1.0, c)), Vector3(nd[1], 0.0, nd[2])))
		RenderingServer.instance_set_custom_aabb(rid, AABB(Vector3(0, b[0], 0), Vector3(n, b[1] - b[0], n)))
		RenderingServer.instance_geometry_set_material_override(rid, mat.get_rid())
		RenderingServer.instance_geometry_set_cast_shadows_setting(rid,
			RenderingServer.SHADOW_CASTING_SETTING_ON if shadows and c*n < 200.0 else RenderingServer.SHADOW_CASTING_SETTING_OFF)
		RenderingServer.instance_geometry_set_flag(rid, RenderingServer.INSTANCE_FLAG_USE_BAKED_LIGHT, true)   # 进 SDFGI
		live[key] = rid; n_new += 1
	for key in live.keys():
		if not want.has(key):
			RenderingServer.free_rid(live[key]); live.erase(key); n_del += 1
	n_sel = out.size()
