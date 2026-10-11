# 地平线 GI（资料/实时引擎/地形GI设计.md §3 G1 + G3 简化版）：地形对天光的遮蔽按高度场严格算，替代 SDFGI。
#   加载时：C++（扩展/仿真核心 core/horizon.cpp）对 15 层高度（数据 + 地貌印章）算 16 个方位的地平线仰角 → 4 张 RGBA8 Texture2DArray，缓存到盘。
#   换天空时：天空图按 16 扇区 × 64 档仰角积分成向量辐照度表（每通道一个向量 + 一行几何立体角）。
#   着色（着色器/地平线GI.gdshaderinc）：E = Σ n·V_k(θ_k) + L_g·(π − Σ n·U_k(θ_k))，写 IRRADIANCE = E/π。
#   L_g = 平均地面辐亮度（实景.gd set_sun 里同下半球那个）。
#   G2 远处地影：同一套高度网格沿太阳方位步进，得每纹素在太阳方向上的地平线仰角（float 数组），着色器里和太阳仰角比。
extends RefCounted

const DIRS := 16
const NB := 64
const VERSION := "hz1"

var stride := 2
var growth := 0.1
var t_max := 40000.0
var n_tex := 0; var n_lv := 0
var maps: Array = []                                            # 地平线图（C++ horizon_maps 格式），换天空时要用
var sky_key := ""
var wtex: Array[Texture2DArray] = []
var mats: Array[ShaderMaterial] = []
var core: RefCounted
var on_rover := true                                             # --车遮挡=0 关 G5
var on_sun := true                                               # --远影=0 关 G2（远处地影）
var sun_tex: Texture2DArray = null
var sun_az := INF
var sun_dbg := false                                             # --远影=诊断：地形只显示太阳可见度
var sun_stat := false                                            # --远影统计：打印每层在影里的纹素比例（诊断）
# G4 石块遮地面：rock_bucket 的结果 → C++ 把每块石头当等体积球，解析算它挡掉的天光，写两级跟着相机走的可见度图
var on_rk := true                                                # --石遮=0 关
var rk_types := PackedFloat32Array()                             # 每种单位石块网格的包围盒：中心 xyz、半尺寸 xyz
const RK_CASC := [[20.48, 2048, 1.0], [81.92, 2048, 4.0]]        # 每级边长（m）、纹素数、相机挪多远才重算（m）：1 cm 管 ±10 m，4 cm 管 ±41 m
var rk_tex: Array = [null, null]
var rk_ctr: Array = [Vector2(INF, INF), Vector2(INF, INF)]          # 每级上次算的相机位置（主线程写，后台读：差一帧无妨）
var gmat: ShaderMaterial
# 异步（实时档）：换天空、太阳方位重算放后台线程，贴图分几帧传。离线渲染 / 视频同步算，保证每帧都对。--异步=0 关
var async := false
const UP_PER_FRAME := 9                                          # 每帧最多传几层（RGBAH 301² 一层 0.7 MB，RF 0.36 MB）
var uploads: Array = []                                          # 排队的 [Texture2DArray, Image, 层]
var sky_busy := false                                            # 实景.gd 的换天空任务在跑（地影让路）
var sun_task := -1; var sun_job := {}; var sun_want := INF; var sun_req := INF; var sun_el := 0.0
const SUN_AZ_STEP := 0.25*PI/180.0                               # 太阳方位变了这么多才重算（仰角在着色器里比，不用重算）


func setup(P: Node, args: Dictionary) -> bool:
	core = P.lod.core
	if core == null or not core.has_method("horizon_maps"):
		push_warning("地平线 GI 要 C++ 扩展（MarsTerrainCore.horizon_maps）"); return false
	stride = int(args.get("地平线步", "2")); t_max = float(args.get("地平线距", "40000"))
	on_rover = args.get("车遮挡", "1") == "1"
	on_sun = args.get("远影", "1") != "0"
	sun_dbg = args.get("远影", "1") == "诊断"
	sun_stat = args.has("远影统计")
	on_rk = args.get("石遮", "1") == "1"
	async = P.bg
	rk_types = P.rk_aabb; gmat = P.ground_mat
	if gmat: gmat.set_shader_parameter("hz_rk_L", float(args.get("石遮亮", "0.6")))
	var H: Dictionary = P.J["heights"]
	var hfile: String = P.D + H["file"]
	var pfile: String = 环境.地貌参数()
	var key := "%s|%d|%d|%.3f|%.0f|%d|%d|%d" % [VERSION, stride, DIRS, growth, t_max, FileAccess.get_file_as_bytes(hfile).size(),
		FileAccess.get_modified_time(hfile), FileAccess.get_modified_time(pfile) if FileAccess.file_exists(pfile) else 0]
	if P.geo == null or float(args.get("地貌", "1")) <= 0.0: key += "|无印章"
	var cache: String = P.D + "地平线缓存_s%d.bin" % stride
	var L: int = int(H["L"]); var n: int = (int(H["N"]) - 1)/stride + 1
	var t0 := Time.get_ticks_msec()
	var q_arrays := []
	if FileAccess.file_exists(cache):
		var f := FileAccess.open(cache, FileAccess.READ)
		if f.get_line() == key:
			for q in DIRS/4:
				var arr := []
				for k in L: arr.append(f.get_buffer(n*n*4))
				q_arrays.append(arr)
		f.close()
	var from_cache := not q_arrays.is_empty()
	if not from_cache:
		q_arrays = core.horizon_maps(stride, DIRS, growth, t_max)
		var f := FileAccess.open(cache, FileAccess.WRITE)
		if f:
			f.store_line(key)
			for q in DIRS/4:
				for k in L: f.store_buffer(q_arrays[q][k])
			f.close()
	maps = q_arrays; n_tex = n; n_lv = L
	print("[地平线GI] %d 层 %d² × %d 方位，%s %.1f s" % [L, n, DIRS, "读缓存" if from_cache else "生成", (Time.get_ticks_msec() - t0)/1000.0])
	for m in [P.ground_mat, P.rock_mat]:
		if m == null: continue
		mats.append(m)
		m.set_shader_parameter("hz_info", Vector4(float(H["c0"]), float(H["half0"]), n, L))
		m.set_shader_parameter("hz_stride", float(stride))
		m.set_shader_parameter("hz_on", 1)
	return true


# 换天空（实景.gd use_sky 调）：天空表（16 扇区 × 64 档）→ 每个地平线纹素的 W（C++，约 0.1 s）→ 3 张 RGBAH 数组，着色器里 E = n·W。
# sky_prepare 不碰渲染服务器，可在后台线程跑；sky_apply 在主线程：第一次建贴图，之后 sync = false 时排进上传队列分几帧传。
func sky_prepare(img: Image, E_TOP: float) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var T: PackedFloat32Array = core.horizon_sky_table(img.get_data().to_float32_array(), img.get_width(), img.get_height(), E_TOP, DIRS, NB)
	var W: Array = core.horizon_irradiance(maps, T, DIRS, NB, true)
	# 开阔平地（各方位都在第 64 档 = 0°）朝上的天光和几何项：石块的遮天比例、实景.gd 的水平天光照度都用它
	var bf := 64.0/255.0*(NB - 1); var b0 := int(bf); var f := bf - b0
	var oE := Vector3.ZERO; var oU := 0.0
	for k in DIRS:
		var yv := []
		for c in 4:
			var i0 := ((k*4 + c)*NB + b0)*4 + 1
			yv.append(lerpf(T[i0], T[i0 + 4], f))
		oE += Vector3(yv[0], yv[1], yv[2]); oU += yv[3]
	var imgs := []
	for c in 3:
		var a: Array[Image] = []
		for k in n_lv: a.append(Image.create_from_data(n_tex, n_tex, false, Image.FORMAT_RGBAH, W[c][k]))
		imgs.append(a)
	return {"imgs": imgs, "oE": oE, "oU": oU, "ms": Time.get_ticks_msec() - t0}


func sky_apply(job: Dictionary, key: String, sync: bool) -> void:
	if job.is_empty(): return
	sky_key = key
	var first := wtex.is_empty()
	for c in 3:
		var imgs: Array[Image] = job["imgs"][c]
		if first:
			var t := Texture2DArray.new(); t.create_from_images(imgs); wtex.append(t)
		else:
			queue_layers(wtex[c], imgs, sync)
	for m in mats:
		for c in 3: m.set_shader_parameter("hz_w%d" % c, wtex[c])
		m.set_shader_parameter("hz_open_E", job["oE"]); m.set_shader_parameter("hz_open_U", job["oU"])
	if sync: print("[地平线GI] 天空 %s：表 + 辐照图 %d ms" % [key, job["ms"]])


# 贴图层上传：sync 当场传；否则排队，poll() 每帧最多传 UP_PER_FRAME 层（同一张贴图的旧排队作废）
func queue_layers(t: Texture2DArray, imgs: Array[Image], sync: bool) -> void:
	if sync:
		for k in imgs.size(): t.update_layer(imgs[k], k)
		return
	uploads = uploads.filter(func(u): return u[0] != t)
	for k in imgs.size(): uploads.append([t, imgs[k], k])


# 每帧（实景.gd _process）：收后台结果、传几层贴图
func poll() -> void:
	if sun_task >= 0 and WorkerThreadPool.is_task_completed(sun_task):
		WorkerThreadPool.wait_for_task_completion(sun_task); sun_task = -1
		sun_apply(sun_job, false); sun_job = {}
	kick_sun()
	var n := 0
	while uploads.size() and n < UP_PER_FRAME:
		var u: Array = uploads.pop_front(); (u[0] as Texture2DArray).update_layer(u[1], u[2]); n += 1


func wait_all() -> void:
	if sun_task >= 0: WorkerThreadPool.wait_for_task_completion(sun_task); sun_task = -1


func set_ground(Lg: Vector3) -> void:
	for m in mats:
		m.set_shader_parameter("hz_Lg", Lg)
		m.set_shader_parameter("hz_belly", Lg*BELLY)


# G5：车的遮挡球（车体坐标：x 侧向、y 上、z 前；原点 = 轮底中心）。由 --车部件 打印的包围盒定：
#   车身 Body 中心 (0, 1.09, −0.14)、尺寸 1.55 × 0.83 × 2.08 → 2 × 3 个 r 0.45；RTG (0, 1.16, −1.25) 0.93 高 → r 0.5；
#   桅杆头 head (−0.55, 2.0, 0.70) → r 0.27；臂端 turret (0.28, 1.88, 1.98) → r 0.35；轮子 r 0.26（有绑定就取转轮节点的实时位置）。
const BELLY := 0.5                                               # 车腹辐亮度 ≈ 反照率 0.5 × 地面辐亮度（车腹主要被地面照）
const SPH := [[-0.39, 1.09, -0.83, 0.45], [0.39, 1.09, -0.83, 0.45], [-0.39, 1.09, -0.14, 0.45], [0.39, 1.09, -0.14, 0.45],
	[-0.39, 1.09, 0.55, 0.45], [0.39, 1.09, 0.55, 0.45], [0.0, 1.16, -1.25, 0.5], [-0.55, 2.0, 0.70, 0.27], [0.28, 1.88, 1.98, 0.35]]
const WHEELS := [[-1.22, 0.26, 1.1], [1.22, 0.26, 1.1], [-1.22, 0.26, 0.0], [1.22, 0.26, 0.0], [-1.22, 0.26, -1.1], [1.22, 0.26, -1.1]]

func set_rover(P: Node) -> void:
	if P.rover_root == null or not on_rover: return
	var xf: Transform3D = P.rover_root.global_transform
	var s: Array[Vector4] = []
	for i in SPH.size():
		var e: Array = SPH[i]; var c: Vector3 = xf*Vector3(e[0], e[1], e[2])
		if i == SPH.size() - 1 and P.arm_nodes.size() == 5: c = P.arm_nodes[4].global_transform*P.arm_sph_local   # 臂端跟着机械臂
		s.append(Vector4(c.x, c.y, c.z, e[3]))
	if P.spin_nodes.size() == 6:
		for nd in P.spin_nodes: var c: Vector3 = (nd as Node3D).global_position; s.append(Vector4(c.x, c.y, c.z, 0.26))
	else:
		for e in WHEELS: var c: Vector3 = xf*Vector3(e[0], e[1], e[2]); s.append(Vector4(c.x, c.y, c.z, 0.26))
	var ctr: Vector3 = xf*Vector3(0, 1.0, 0)
	for m in mats:
		m.set_shader_parameter("hz_sph", s); m.set_shader_parameter("hz_nsph", s.size())
		m.set_shader_parameter("hz_sph_bound", Vector4(ctr.x, ctr.y, ctr.z, 8.0))   # 车外 8 m 遮挡 < 0.5%，跳过


# G2 远处地影：d = 指向太阳的单位向量（Godot 坐标）。仰角每次都更新；方位变了 > 0.25° 才让 C++ 沿新方位重新步进（15 层，约 0.1–0.2 s）
func set_sun(d: Vector3) -> void:
	if not on_sun: return
	var el := asin(clampf(d.y, -1.0, 1.0))
	var az := atan2(d.x, -d.z)                                   # 自北顺时针，同 core/horizon.cpp 的方位
	sun_el = el
	for m in mats: m.set_shader_parameter("hz_sun_el", el)
	if sun_tex != null and absf(angle_difference(az, sun_req)) < SUN_AZ_STEP: return
	sun_req = az
	if async and sun_tex != null:                                # 实时：后台步进，算完下一帧换上（这期间影按旧方位，差 < 0.25° + 一两帧）
		sun_want = az; kick_sun(); return
	sun_apply(sun_prepare(az), true)


func kick_sun() -> void:
	if sun_task >= 0 or sun_want == INF or sky_busy: return          # 换天空优先：两个都要 C++ 线程池（串行），延时摄影时地影一直在算会把天空拖到 0.6 s
	var a := sun_want; sun_want = INF
	sun_task = WorkerThreadPool.add_task(func(): sun_job = sun_prepare(a))


func sun_prepare(az: float) -> Dictionary:                        # 可在后台线程
	var t0 := Time.get_ticks_msec()
	var A: Array = core.horizon_sun(stride, az, growth, t_max)
	var imgs: Array[Image] = []
	for k in n_lv: imgs.append(Image.create_from_data(n_tex, n_tex, false, Image.FORMAT_RF, (A[k] as PackedFloat32Array).to_byte_array()))
	return {"az": az, "imgs": imgs, "A": A if sun_stat else [], "ms": Time.get_ticks_msec() - t0}


func sun_apply(job: Dictionary, sync: bool) -> void:
	if job.is_empty(): return
	sun_az = job["az"]
	if sun_tex == null:
		sun_tex = Texture2DArray.new(); sun_tex.create_from_images(job["imgs"])
		for m in mats: m.set_shader_parameter("hz_sun", sun_tex); m.set_shader_parameter("hz_sun_on", 2 if sun_dbg else 1)
	else:
		queue_layers(sun_tex, job["imgs"], sync)
	if sun_stat:
		for k in n_lv:
			var a: PackedFloat32Array = job["A"][k]; var c := 0; var mx := -1.0
			for v in a:
				if v > sun_el: c += 1
				mx = maxf(mx, v)
			print("  第 %d 层（纹素 %.2f m）：在影里 %.2f%%，最大地平线 %.2f°" % [k, float(stride)*mats[0].get_shader_parameter("hz_info").x*pow(2.0, k), 100.0*c/a.size(), rad_to_deg(mx)])
	if sync: print("[地平线GI] 远处地影：太阳方位 %.2f°、仰角 %.2f°，%d ms" % [rad_to_deg(sun_az), rad_to_deg(sun_el), job["ms"]])


# G4：可在后台线程调（C++ 只读高度、线程池串行化）。返回每级 [x0, z0, 边长, n, L8 字节]
func rock_occ_compute(res: Array, cam: Vector3, force := false) -> Array:
	if not on_rk or rk_types.is_empty() or gmat == null: return []
	var out := []
	for q in RK_CASC.size():
		var c: Array = RK_CASC[q]
		if Vector2(cam.x, cam.z).distance_to(rk_ctr[q]) < c[2] and not force: out.append([]); continue
		var size: float = c[0]; var n: int = c[1]; var cell := size/n
		var x0 := roundf(cam.x/cell)*cell - size/2.0; var z0 := roundf(cam.z/cell)*cell - size/2.0   # 对齐纹素：相机挪动时图不游
		out.append([x0, z0, size, n, core.rock_occlusion(res, rk_types, x0, z0, cell, n), Vector2(cam.x, cam.z)])
	return out


func rock_occ_apply(occ: Array) -> void:
	if occ.is_empty(): return
	for q in occ.size():
		var o: Array = occ[q]
		if o.is_empty(): continue
		rk_ctr[q] = o[5]
		var img := Image.create_from_data(o[3], o[3], false, Image.FORMAT_L8, o[4])
		if rk_tex[q] == null: rk_tex[q] = ImageTexture.create_from_image(img)
		else: (rk_tex[q] as ImageTexture).update(img)
		gmat.set_shader_parameter("hz_rk%d" % q, rk_tex[q]); gmat.set_shader_parameter("hz_rk_rect%d" % q, Vector3(o[0], o[1], o[2]))
	gmat.set_shader_parameter("hz_rk_on", 1)


func clear_tables() -> void:
	sky_key = ""
