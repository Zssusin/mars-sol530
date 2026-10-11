# 近景砾石（颗粒感 §3）：相机周围撒 D = 3 mm – 5 cm 的小石子（MultiMesh，20 面）。
# 补 撒石.gd 管不到的那一段：撒石最小一档是 5–10 cm，再小的靠材质的 2–3 mm 样块（只有法线和反照率，没有轮廓、视差、阴影）。
# 定律同 撒石.gd：Golombek & Rapp 1997，累计面积分数 F(D) = k·exp(−q·D)，q = 1.79 + 0.152/k；k 取 scene.json geo.k_cls（57 的近景定标），
#   这里按 材质.gd 控制图每点的材质权重混合：材质 → 它在 地面材质表.json 里 地类 的第一项（沙 0、砾石风化层 1、基岩 2、暗色岩块 3）。
#   所以沙上少、砾石风化层（M3、M11、M17）上多，和控制图一致。--砾石密度=s 整体乘 s（物理值 s = 1）。
# 只补数据分辨不出的：D < 2.5 × 该处高程分辨率（同撒石.gd），所以 Navcam 近区（±8 m，2 mm 实测高度里已有石子）基本不撒。
# 档：b = −1…−4，D ∈ [0.05·2^b, 0.1·2^b)，区块边长 = 128·D_下界（按 (档, 格号) 播种，同一处每次一样）；可见半径 = D/(像素角·--砾石像素)。
# 生成和装配在后台线程（WorkerThreadPool），相机挪过 0.5 m 才重装配；应用在主线程。
extends RefCounted

const G := preload("res://撒石.gd")
const NB := 4
const TILE_K := 128.0
const MAXN := 80000

var host: Node3D; var lod: Node3D; var geo: RefCounted; var mats: RefCounted
var dens := 1.0; var px := 1.5
var k_mat := PackedFloat32Array()
var N := []; var Dt := []; var Ct := []; var Nmax := []        # [档][材质]
var cache := {}                                                 # Vector3i(档 0..NB−1, i, j) → PackedFloat32Array（每块 16 个数 + 之后另存 D）
var mm: MultiMesh; var mmi: MultiMeshInstance3D
var task := -1; var result := PackedFloat32Array(); var rcam := Vector3(INF, INF, INF)
var base := Color(0.24, 0.17, 0.13)
var n_inst := 0; var n_tiles := 0


func setup(host_: Node3D, lod_: Node3D, geo_: RefCounted, mats_: RefCounted, J: Dictionary, rock_mat: ShaderMaterial, base_: Color, args: Dictionary) -> bool:
	host = host_; lod = lod_; geo = geo_; mats = mats_; base = base_
	dens = float(args.get("砾石密度", "1")); px = float(args.get("砾石像素", "4"))
	if dens <= 0.0 or mats == null or geo == null or lod == null: return false
	var kc: Array = J["geo"]["k_cls"]
	var first := {"M1": 0, "M2": 2, "M3": 1, "M4": 0, "M5": 0, "M8": 2, "M11": 1, "M17": 1, "M16": 0, "M14": 2, "M15": 0, "M18": 0, "M19": 0, "M20": 2}   # 地面材质表.json 的 地类 第一项（沙 0、砾石风化层 1、基岩 2）
	var nm: int = mats.nmat
	k_mat.resize(nm)
	for m in nm: k_mat[m] = float(kc[int(first.get(String(mats.M["材质"][m]["id"]), 0))])
	for bi in NB:
		var b := -(bi + 1); var d1 := 0.05*pow(2.0, b); var d2 := 2.0*d1
		var nb := []; var db := []; var cb := []; var mx := 0.0
		for m in nm:
			var t := G.golombek_n(k_mat[m], d1, d2)
			nb.append(t[0]*dens); db.append(t[1]); cb.append(t[2]); mx = maxf(mx, t[0]*dens)
		N.append(nb); Dt.append(db); Ct.append(cb); Nmax.append(mx)
	mm = MultiMesh.new(); mm.transform_format = MultiMesh.TRANSFORM_3D; mm.use_colors = true; mm.mesh = _ico()
	mmi = MultiMeshInstance3D.new(); mmi.multimesh = mm; mmi.material_override = rock_mat; mmi.name = "砾石"
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if args.get("砾石影", "0") == "1" else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	host.add_child(mmi)
	print("[砾石] %d 档 D %.1f–%.0f mm，密度 ×%.1f，每 m² 最多 %s 块；k_材质 %s" % [NB, 0.05*pow(2.0, -NB)*1000.0, 0.1*pow(2.0, -1)*1000.0, dens,
		str(Nmax.map(func(x): return snappedf(x, 0.01))), str(Array(k_mat).map(func(x): return snappedf(x, 0.0001)))])
	return true


func _ico() -> ArrayMesh:
	var t := (1.0 + sqrt(5.0))/2.0
	var V := [Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0), Vector3(0, -1, t), Vector3(0, 1, t),
		Vector3(0, -1, -t), Vector3(0, 1, -t), Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1)]
	for i in V.size(): V[i] = V[i].normalized()*0.5
	var F := [[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
		[3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9], [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]]
	var P := PackedVector3Array(); var Nn := PackedVector3Array()
	for f in F:
		var a: Vector3 = V[f[0]]; var b: Vector3 = V[f[1]]; var c: Vector3 = V[f[2]]
		var fn := (c - a).cross(b - a).normalized()                   # 外法线（同 实景.gd unindex 的绕序）
		if fn.dot(a + b + c) < 0.0: fn = -fn; P.append_array([a, c, b])
		else: P.append_array([a, b, c])
		Nn.append_array([fn, fn, fn])
	var arr := []; arr.resize(Mesh.ARRAY_MAX); arr[Mesh.ARRAY_VERTEX] = P; arr[Mesh.ARRAY_NORMAL] = Nn
	var am := ArrayMesh.new(); am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return am


func gen_tile(bi: int, ti: int, tj: int) -> PackedFloat32Array:
	var b := -(bi + 1); var T := TILE_K*0.05*pow(2.0, b)
	var rng := RandomNumberGenerator.new()
	rng.seed = geo.ih(geo.ih(bi*0x3c6ef372 + 11) ^ geo.ih(((ti & geo.M32)*0x27d4eb2d) & geo.M32) ^ ((tj & geo.M32)*0x165667b1 & geo.M32))
	var out := PackedFloat32Array()
	var cnt := G.poisson(rng, Nmax[bi]*T*T)
	var nm: int = mats.nmat
	for _n in cnt:
		var x := (ti + rng.randf())*T; var z := (tj + rng.randf())*T
		var u1 := rng.randf(); var u2 := rng.randf(); var u3 := rng.randf(); var u4 := rng.randf()
		var dl: float = geo.dem_l(x, z)
		if dl <= -4.5: continue                                      # 近区（Navcam 2 mm 实测）：不撒
		var Tb: Array = mats.table(x, z)                               # [id0..3, w0..3]
		var ns := 0.0; var nc := [0.0, 0.0, 0.0, 0.0]
		for q in 4:
			if Tb[q] >= 0 and Tb[q] < nm: nc[q] = Tb[4 + q]*N[bi][Tb[q]]; ns += nc[q]
		if u1*Nmax[bi] >= ns: continue
		var c := 0; var acc: float = nc[0]; var pick := u2*ns
		while c < 3 and pick > acc: c += 1; acc += nc[c]
		var mid: int = Tb[c]
		var D := G.inv_cdf(Dt[bi][mid], Ct[bi][mid], u3)
		if u4 >= clampf(dl + 1.321928 - log(D)/log(2.0), 0.0, 1.0): continue
		var sd := float(rng.randi() & 0x3FFFFFFF)
		var asp := rng.randf_range(0.35, 0.75)
		var H := D*asp
		var y: float = lod.h_cpu(x, z, 0) + 0.25*H                     # 单位网格 y ∈ [−½, ½]，埋入四分之一
		var B: Basis = host.enu_basis((host.hash01(sd, 1.0) - 0.5)*0.7, (host.hash01(sd, 2.0) - 0.5)*0.7, rng.randf()*TAU, D, D*rng.randf_range(0.6, 1.0), H)
		var r: float = host.hash01(sd, 3.1)
		var col := Color(base.r*lerpf(0.75, 1.2, r), base.g*lerpf(0.75, 1.15, r), base.b*lerpf(0.75, 1.1, r), lerpf(0.4, 1.0, host.hash01(sd, 5.3)))
		out.append_array([B.x.x, B.y.x, B.z.x, x, B.x.y, B.y.y, B.z.y, y, B.x.z, B.y.z, B.z.z, z, col.r, col.g, col.b, col.a])
	return out


func _assemble(cam: Vector3, pa: float) -> PackedFloat32Array:
	var buf := PackedFloat32Array(); var nt := 0
	var agl := maxf(cam.y - lod.h_cpu(cam.x, cam.z, 0), 0.0)
	for bi in NB:
		var b := -(bi + 1); var Dh := 0.1*pow(2.0, b); var T := TILE_K*0.05*pow(2.0, b)
		var r := Dh/(px*pa)
		if r <= agl: continue
		var rh := sqrt(r*r - agl*agl)
		for tj in range(floori((cam.z - rh)/T), floori((cam.z + rh)/T) + 1):
			for ti in range(floori((cam.x - rh)/T), floori((cam.x + rh)/T) + 1):
				var dx := maxf(maxf(ti*T - cam.x, cam.x - (ti + 1)*T), 0.0); var dz := maxf(maxf(tj*T - cam.z, cam.z - (tj + 1)*T), 0.0)
				if sqrt(dx*dx + dz*dz + agl*agl) > r: continue
				var key := Vector3i(bi, ti, tj)
				if not cache.has(key): cache[key] = gen_tile(bi, ti, tj)
				var tile: PackedFloat32Array = cache[key]; nt += 1
				for q in range(0, tile.size(), 16):
					var D := Vector3(tile[q], tile[q + 4], tile[q + 8]).length()
					var dist := cam.distance_to(Vector3(tile[q + 3], tile[q + 7], tile[q + 11]))
					if D/(maxf(dist, 0.05)*pa) < px: continue
					buf.append_array(tile.slice(q, q + 16))
					if buf.size() >= MAXN*16: n_tiles = nt; return buf
	n_tiles = nt
	if cache.size() > 3000: cache = {}                                  # 粗暴丢缓存（下次重生成，哈希播种所以一样）
	return buf


func update(cam: Vector3, pa: float) -> void:
	if task >= 0:
		if not WorkerThreadPool.is_task_completed(task): return
		WorkerThreadPool.wait_for_task_completion(task); task = -1
		n_inst = result.size()/16
		mm.instance_count = n_inst
		if n_inst > 0: mm.buffer = result
	if cam.distance_to(rcam) < 0.5: return
	rcam = cam
	task = WorkerThreadPool.add_task(func(): result = _assemble(cam, pa))


func sync(cam: Vector3, pa: float) -> void:
	"""离线渲染：当场装配、当场应用。"""
	rcam = cam
	var b := _assemble(cam, pa)
	n_inst = b.size()/16
	mm.instance_count = n_inst
	if n_inst > 0: mm.buffer = b
	print("[砾石] %d 块，区块 %d" % [n_inst, n_tiles])


func wait_all() -> void:
	if task >= 0: WorkerThreadPool.wait_for_task_completion(task); task = -1
