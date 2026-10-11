# 实景 sol 530（Godot 版）：读 scripts/Godot/61_Godot数据.py 转好的 数据/sol0530/，搭出和 58（Blender）同一个场景。
#   地面 15 环 + 自动地形着色器、实测 / 统计石块（MultiMesh）、今天的火星天空与太阳、NASA 毅力号、四台相机。
# 运行：
#   漫游：godot --path godot                          （WASD 走、鼠标看、Shift 快、Q/E 升降、1–4 切机位、T 换时刻、F12 截图、Esc 放开鼠标）
#   渲染：godot --path godot -- --渲染=<目录> [--时刻=13:07] [--超采样=2]   → <目录>/<相机>_1307.png，渲染完退出
#   视频：godot --path godot -- --视频=<路径.json> --出=<目录> [--只=走近,环绕] [--超采样=2] [--每帧=2]   （路径由 scripts/Godot/65_视频路径.py 生成；godot/视频.sh 一步到 mp4）
# 单位：天空与表面辐亮度 W/m²/sr，曝光 2^−6（同 58 的 Standard、exposure −6）。2026-10-06 起曝光乘进 E_TOP（引擎里的数值 = 物理值 × 2^曝光），色调映射曝光为 1，原因见 _ready。
extends Node3D

var D: String = 环境.数据目录()                                     # 编辑器 res://数据/sol0530/；导出包 data/数据/sol0530/（godot/环境.gd）
var J: Dictionary
var ground_mat: ShaderMaterial
var rock_mat: ShaderMaterial
var sky_mat: ShaderMaterial
var sun: DirectionalLight3D
var env: Environment
var cams: Array = []
var hide_parts: Array[GeometryInstance3D] = []
var rover_root: Node3D
var steer_nodes: Array[Node3D] = []                                  # 六个轮子各一个：转向 + 上下补偿（中轮只上下）
var spin_nodes: Array[Node3D] = []                                   # 轮子本身：绕轮轴（模型 +x）转
var steer_base: Array[Transform3D] = []
var fly: Camera3D
var lod: Node3D = null                                                # 默认 CDLOD 地面（地形LOD.gd）；--网格=环：老的 15 环（对照用）
var geo: RefCounted = null                                            # 地貌印章（地貌.gd，只在 CDLOD 下）；--地貌=0 关
var mcache: RefCounted = null                                         # 材质缓存（材质缓存.gd，原型，engine-vt）：--材质缓存=0|1（默认 1）
var mat_sys: RefCounted = null                                        # 地面材质（材质.gd，阶段 1 B 步）；--材质=旧 → null，着色器加 #define MAT_OLD
var rover_dust: ShaderMaterial = null                                 # 车尘叠加层（模块可调 dust）
var post: Node = null                                                  # 屏幕后处理（后处理.gd）：CAS 锐化 + 颗粒，实时画质才建；--后处理=0 关
var pebbles: RefCounted = null                                        # 近景砾石（砾石.gd，颗粒感 §3）：--砾石=1 开，--砾石密度=s
var scat: RefCounted = null                                           # 实时撒石（撒石.gd）；--撒石=表：用 57 导出的固定表
var ltst := "13:07"
var args := {}
var rt := true                                                        # 画质档：实时（漫游 / 测帧，默认）或离线（--渲染 / --视频）；--画质=实时|离线 强制
var bg := false                                                     # 实时（非 --渲染 / --视频）：换天空、远处地影重算放后台线程（--异步=0 关）
var sky_img := {}                                                   # 天空图 Image（磁盘读来的，后台线程也能用；不从 GPU 读回）
var sky_task := -1; var sky_job := {}; var sky_want := ""; var sky_pending := ""
var sun_last := []                                                  # 最近一次 set_sun 的参数：换完天空后重算地面辐亮度
var rk_aabb := PackedFloat32Array()                                # 每种单位石块网格的包围盒（中心、半尺寸），G4 石块遮地面用
var rk_occ: Array = []
var hz: RefCounted = null                                          # 地平线 GI（地平线GI.gd），默认开、同时关 SDFGI；--地平线GI=0 回到 SDFGI
var expo_in_lights := true                                          # 曝光乘进光源（见 _ready），色调映射曝光为 1
# 全日天空（docs/全日天空.md §5）：--曝光=固定（默认，和以前一样不动）| 自动（日落后按水平照度补曝光，像相机的自动曝光，有上限）
var expo_mode := "固定"
var expo_base := 1.0                                                # build_env 之后的 env.tonemap_exposure（含高光肩的 1/H）；自动曝光在它上面乘 expo_mul
var expo_mul := 1.0
const EXPO_REF := 28.67                                             # 参考水平照度 W/m²（= 17:00 的直射 + 天光）：照度高于它不补（08:00–17:00 一档都不动）。游戏设定
const EXPO_MAX_EV := 6.0                                            # 最多补 6 档（64×，手机夜景 / 长曝光的量级）。游戏设定


func _ready() -> void:
	if not 环境.数据问题.is_empty(): set_process(false); set_process_unhandled_input(false); return   # 没有数据：环境.gd 已经在显示提示页
	args = 环境.参数()                                                  # 默认 < 画质预设 < user://settings.cfg < 命令行（godot/环境.gd；设置只在导出版或带 --设置 时生效）
	bg = not (args.has("渲染") or args.has("视频")) and args.get("异步", "1") == "1"
	rt = args.get("画质", "离线" if (args.has("渲染") or args.has("视频")) else "实时") == "实时"
	J = JSON.parse_string(FileAccess.get_file_as_string(D + "scene.json"))
	# 曝光并进光源：所有绝对辐亮度都从 E_TOP 来（太阳、天空、材质的空气透视、天气），乘 2^曝光 后色调映射曝光取 1，画面数学上不变。
	# 原因：SDFGI 探针把光照乘 2^10 存进 16 位整数（sdfgi_integrate.glsl HISTORY_BITS），上限约 32；物理单位的天空约 75–100，
	# 红通道先被截，环境光发灰（地面 R/B 1.51 → 1.41）。--曝光进光源=0 回到旧做法（诊断用）。
	expo_in_lights = args.get("曝光进光源", "1") == "1"
	if args.get("曝光", "") in ["自动", "固定"]: expo_mode = args["曝光"]; args["曝光"] = "-6"   # --曝光=自动|固定 选模式；--曝光=<数字> 仍是旧的曝光档（EV）
	J["E_TOP_phys"] = J["E_TOP"]
	if expo_in_lights: J["E_TOP"] = float(J["E_TOP"])*pow(2.0, float(args.get("曝光", "-6")))
	ltst = args.get("时刻", "13:07")
	var t0 := Time.get_ticks_msec()
	环境.进度("天空", 0.05)
	build_env()
	环境.进度("地面", 0.15)
	build_ground()
	环境.进度("石块与车", 0.55)
	build_rocks()
	环境.进度("地平线光照", 0.75)
	if args.get("地平线GI", "1") == "1":
		hz = load("res://地平线GI.gd").new()
		if not hz.setup(self, args): hz = null
	环境.进度("车", 0.82)
	build_rover()
	if hz: hz.set_rover(self)
	if args.has("车部件"):                                             # 诊断：大件在车体坐标里的包围盒（定 G5 遮挡球）
		var inv := rover_root.global_transform.affine_inverse()
		for g in rover_root.find_children("*", "GeometryInstance3D", true, false):
			var ab: AABB = (g as GeometryInstance3D).get_aabb(); var xf: Transform3D = inv*(g as Node3D).global_transform
			var lo := Vector3(INF, INF, INF); var hi := -lo
			for k in 8: var p := xf*ab.get_endpoint(k); lo = lo.min(p); hi = hi.max(p)
			var sz := hi - lo
			if sz.x*sz.y*sz.z > 0.01: print("[车部件] %-28s 中心 %s 尺寸 %s" % [g.name, (lo + hi)/2.0, sz])
	set_time(ltst)
	for c in J["cameras"]:
		if not args.has("相机") or String(c["name"]).begins_with(args["相机"]): cams.append(c)
	if args.has("校准"):                                               # 诊断：500 m 高空一块朝上的白板（反照率 1），俯拍量照度
		var pl := MeshInstance3D.new(); var pm := PlaneMesh.new(); pm.size = Vector2(40, 40); pl.mesh = pm
		var sm := StandardMaterial3D.new(); sm.albedo_color = Color(1, 1, 1); sm.roughness = 1.0; sm.metallic_specular = 0.0
		sm.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT; sm.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		pl.material_override = sm; pl.position = Vector3(0, 500, 0); add_child(pl)
		cams = [{"name": "校准", "pos": [0, 505, 0], "fwd": [0, -1, 0], "up": [0, 0, -1], "hfov": 30.0, "W": 64, "H": 64, "pixel_angle": 0.008}]
	if args.has("斜机位"):                                           # 诊断：--斜机位=E,N,离地高,朝向°,下俯°[,水平视场°,宽,高][;下一台…]（沙纹对照，docs/地面材质/沙纹.md）
		cams = []
		for cq in String(args["斜机位"]).split(";"):
			var q: PackedStringArray = cq.split(",")
			var E := float(q[0]); var Nn := float(q[1]); var az := deg_to_rad(float(q[3])); var pt := deg_to_rad(-float(q[4]))
			var hf := float(q[5]) if q.size() > 5 else 60.0; var wpx := int(q[6]) if q.size() > 6 else 2560; var hpx := int(q[7]) if q.size() > 7 else 1440
			var gy: float = lod.h_cpu(E, -Nn, 0) if lod else 0.0
			var fw := [sin(az)*cos(pt), sin(pt), -cos(az)*cos(pt)]
			cams.append({"name": "斜视%d" % cams.size(), "pos": [E, gy + float(q[2]), -Nn], "fwd": fw, "up": [0, 1, 0], "hfov": hf, "W": wpx, "H": hpx, "pixel_angle": deg_to_rad(hf)/wpx})
	if args.has("远机位"):                                           # 诊断：--远机位=E,N,朝向°（0 = 北，顺时针），人眼高 1.6 m、下俯 12°
		var q: PackedStringArray = String(args["远机位"]).split(",")
		var E := float(q[0]); var Nn := float(q[1]); var az := deg_to_rad(float(q[2])); var pt := deg_to_rad(-float(args.get("远机位俯", "12")))
		var eh := float(args.get("远机位高", "1.6"))                     # engine-vt：--远机位高=离地高（m）、--远机位俯=下俯角（°），看近地 / 接触阴影用
		var gy: float = float(q[3]) - eh if q.size() > 3 else (lod.h_cpu(E, -Nn, 0) if lod else 0.0)   # 第 4 个数：相机绝对高度（m）
		var fw := [sin(az)*cos(pt), sin(pt), -cos(az)*cos(pt)]
		cams = [{"name": "远足", "pos": [E, gy + eh, -Nn], "fwd": fw, "up": [0, 1, 0], "hfov": 60.0, "W": 1600, "H": 900, "pixel_angle": deg_to_rad(60.0)/1600.0}]
	if args.has("俯机位"):                                           # 诊断：--俯机位=E,N,离地高,水平视场°[,边长像素]：正下方俯拍（北在上），量平铺重复度用（阶段1.md §9.6）
		var q: PackedStringArray = String(args["俯机位"]).split(",")
		var E := float(q[0]); var Nn := float(q[1]); var fov := float(q[3]); var wpx := int(q[4]) if q.size() > 4 else 1024
		var gy: float = lod.h_cpu(E, -Nn, 0) if lod else 0.0
		cams = [{"name": "俯视", "pos": [E, gy + float(q[2]), -Nn], "fwd": [0, -1, 0], "up": [0, 0, -1], "hfov": fov, "W": wpx, "H": wpx, "pixel_angle": deg_to_rad(fov)/wpx}]
	if args.has("转向诊断") and steer_nodes.size() == 6:              # 诊断：--转向诊断=度数，四个角轮打这么多，两台相机对着左前轮（看转向叉和上面的轴承接没接上）
		var RR: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(D + "rover_rig.json"))
		var a := deg_to_rad(float(args["转向诊断"])); var kf := 0; var zf := -INF
		for k in 6:
			var wh: Dictionary = RR["wheels"][k]
			if wh["corner"]: steer_nodes[k].transform = steer_base[k]*Transform3D(Basis(Vector3.UP, a))
			var zz: float = float(wh["c"][2])*(-1.0 if args.get("转向诊断轮", "前") == "后" else 1.0)   # --转向诊断轮=后：看左后轮
			if wh["corner"] and float(wh["c"][0]) > 0.0 and zz > zf: zf = zz; kf = k
		var B: Basis = rover_root.global_transform.basis
		var wp: Vector3 = steer_nodes[kf].global_position + B*Vector3(0, 0.35, 0)
		cams = []
		for v in [["外前", Vector3(1.3, 0.25, 1.0)], ["外后上", Vector3(1.1, 0.9, -0.6)]]:
			var cp: Vector3 = wp + B*v[1]; var fw := (wp - cp).normalized()
			cams.append({"name": "转向_" + v[0], "pos": [cp.x, cp.y, cp.z], "fwd": [fw.x, fw.y, fw.z], "up": [0, 1, 0], "hfov": 45.0, "W": 1200, "H": 900, "pixel_angle": deg_to_rad(45.0)/1200.0})
	if args.has("摇臂诊断") and not rb.is_empty():                  # 诊断：--摇臂诊断=摇臂°,左转向架°,右转向架°（夸张摆关节，看各件接没接上）
		var q := String(args["摇臂诊断"]).split(",")
		var z6 := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
		var xf := rover_root.global_transform
		pose_rover({"b": [[xf.basis.x.x, xf.basis.x.y, xf.basis.x.z], [xf.basis.y.x, xf.basis.y.y, xf.basis.y.z], [xf.basis.z.x, xf.basis.z.y, xf.basis.z.z]],
			"o": [xf.origin.x, xf.origin.y + 0.3, xf.origin.z], "steer": z6, "dy": z6, "spin": z6,
			"rk": deg_to_rad(float(q[0])), "bg": [deg_to_rad(float(q[1])), deg_to_rad(float(q[2]))]})
		var B: Basis = xf.basis; var ctr: Vector3 = xf*Vector3(0, 0.8, 0)
		cams = []
		for v in [["左侧", Vector3(5.5, 0.1, 0.0)], ["斜前", Vector3(3.5, 1.6, 3.0)], ["斜后右", Vector3(-3.5, 1.8, -3.0)]]:
			var cp: Vector3 = ctr + B*v[1]; var fw := (ctr - cp).normalized()
			cams.append({"name": "摇臂_" + v[0], "pos": [cp.x, cp.y, cp.z], "fwd": [fw.x, fw.y, fw.z], "up": [0, 1, 0], "hfov": 42.0, "W": 1600, "H": 900, "pixel_angle": deg_to_rad(42.0)/1600.0})
		var top: Vector3 = xf*Vector3(0.0, 3.2, -0.05); var dn: Vector3 = (xf*Vector3(0.0, 1.17, -0.05) - top).normalized()   # 正上方看差速杆和连杆
		cams.append({"name": "摇臂_顶", "pos": [top.x, top.y, top.z], "fwd": [dn.x, dn.y, dn.z], "up": [B.z.x, B.z.y, B.z.z], "hfov": 40.0, "W": 1600, "H": 900, "pixel_angle": deg_to_rad(40.0)/1600.0})
	if args.has("臂诊断"):                                             # 诊断：--臂诊断=偏航,肩,肘,腕,转塔（°）摆机械臂，两台相机看臂
		var q := Array(String(args["臂诊断"]).split(",")).map(func(x): return float(x))
		set_arm(rover_root.get_child(0), q)
		var B: Basis = rover_root.global_transform.basis; var ctr: Vector3 = rover_root.global_transform*Vector3(0.3, 1.2, 1.6)
		cams = []
		for v in [["左前", Vector3(3.2, 1.0, 3.0)], ["右前上", Vector3(-3.0, 2.2, 2.8)]]:
			var cp: Vector3 = ctr + B*v[1]; var fw := (ctr - cp).normalized()
			cams.append({"name": "臂_" + v[0], "pos": [cp.x, cp.y, cp.z], "fwd": [fw.x, fw.y, fw.z], "up": [0, 1, 0], "hfov": 45.0, "W": 1200, "H": 900, "pixel_angle": deg_to_rad(45.0)/1200.0})
	if args.has("材质诊断"):                                         # 诊断：--材质诊断[=甲板,轮,…] 车材质特写（§17）：模型坐标 +y 上、+z 前、+x 左；「跟车」= 控制模块默认机位（车后 9 m、仰 18°）
		var xf := rover_root.global_transform; var B: Basis = xf.basis
		var V := [["甲板", Vector3(0.0, 1.3, -0.3), Vector3(1.7, 3.3, 1.0), 42.0], ["轮", Vector3(1.06, 0.32, 1.09), Vector3(2.5, 0.75, 2.3), 34.0],
			["桅杆头", Vector3(-0.55, 2.0, 0.72), Vector3(-0.15, 2.3, 2.1), 34.0], ["转塔", Vector3(0.3, 1.85, 1.98), Vector3(1.5, 2.3, 3.0), 36.0],
			["RTG", Vector3(0.0, 1.15, -1.3), Vector3(-1.5, 1.9, -3.1), 40.0], ["侧面", Vector3(0.45, 1.0, -0.1), Vector3(3.2, 1.35, 0.5), 42.0], ["臂", Vector3(0.0, 1.4, 1.9), Vector3(1.6, 1.9, 4.9), 44.0]]
		var want: String = args["材质诊断"]
		cams = []
		for v in V:
			if want != "" and want != "1" and not want.split(",").has(v[0]): continue
			var tp: Vector3 = xf*v[1]; var cp: Vector3 = xf*v[2]; var fw := (tp - cp).normalized()
			cams.append({"name": "材质_" + v[0], "pos": [cp.x, cp.y, cp.z], "fwd": [fw.x, fw.y, fw.z], "up": [0, 1, 0], "hfov": v[3], "W": 1600, "H": 1000, "pixel_angle": deg_to_rad(v[3])/1600.0})
		for yo in [["跟车", 0.0], ["跟车侧", 2.2]]:                    # 控制.gd update_cam：c_dist 9、c_pitch 0.32、目标 = 车原点 + 1 m，fov 60（竖直）
			if want != "" and want != "1" and not want.split(",").has(yo[0]): continue
			var F: Vector3 = B.z; var yaw: float = atan2(-F.x, -F.z) + yo[1]; var tgt: Vector3 = xf.origin + Vector3.UP
			var cp: Vector3 = tgt + Vector3(sin(yaw)*cos(0.32), sin(0.32), cos(yaw)*cos(0.32))*9.0; var fw := (tgt - cp).normalized()
			var hf := rad_to_deg(2.0*atan(tan(deg_to_rad(30.0))*1.6))
			cams.append({"name": "材质_" + yo[0], "pos": [cp.x, cp.y, cp.z], "fwd": [fw.x, fw.y, fw.z], "up": [0, 1, 0], "hfov": hf, "W": 1600, "H": 1000, "pixel_angle": deg_to_rad(hf)/1600.0})
		if args.get("车", "1") == "0": rover_root.visible = false      # 无车底图：和有车的图相减得车的掩膜（量车上像素的统计）
	if args.has("地面特写"):                                         # 诊断：--地面特写[=工作区,磨蚀,钻孔,前方,车旁] 贴地看近景细化（72）；目标点 ENU，相机离地高度、水平距离、方位
		var want: String = args["地面特写"]
		var V := [["工作区", Vector2(-3.0, -1.3), 1.2, 1.8, 230.0, 50.0], ["磨蚀", Vector2(-2.217, -0.490), 0.45, 0.45, 240.0, 30.0],
			["钻孔", Vector2(-2.108, -0.565), 0.30, 0.30, 240.0, 24.0], ["前方", Vector2(-4.6, -3.4), 1.2, 2.0, 40.0, 55.0],
			["车旁", Vector2(1.6, 2.6), 1.2, 1.8, 200.0, 55.0]]
		cams = []
		for v in V:
			if want != "" and want != "1" and not want.split(",").has(v[0]): continue
			var tg: Vector2 = v[1]; var az := deg_to_rad(float(v[4]))     # 方位：相机在目标的哪一侧（0 = 北，顺时针）
			var ce: float = tg.x + sin(az)*float(v[3]); var cn: float = tg.y + cos(az)*float(v[3])
			var ty: float = lod.h_cpu(tg.x, -tg.y, 0) if lod else 0.0; var cy: float = (lod.h_cpu(ce, -cn, 0) if lod else 0.0) + float(v[2])
			var fw := (Vector3(tg.x, ty, -tg.y) - Vector3(ce, cy, -cn)).normalized()
			cams.append({"name": "地面_" + v[0], "pos": [ce, cy, -cn], "fwd": [fw.x, fw.y, fw.z], "up": [0, 1, 0], "hfov": v[5], "W": 1600, "H": 1000, "pixel_angle": deg_to_rad(v[5])/1600.0})
	if args.has("俯视"):                                             # 诊断：车正上方 --俯视=高度（m）往下看
		var hgt := float(args["俯视"])
		cams = [{"name": "俯视", "pos": [0, hgt, 0], "fwd": [0, -1, 0], "up": [0, 0, -1], "hfov": 60.0, "W": 1600, "H": 1600, "pixel_angle": deg_to_rad(60.0)/1600.0}]
	if args.get("天光", "1") == "0":                                  # 诊断：拆开直射与天光（天空做环境光时 energy 不起作用，只能关光源）
		env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED; env.ambient_light_energy = 0.0
		env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	if args.has("阳光"): sun.light_energy *= float(args["阳光"])
	print("[实景] 场景搭好 %.1f s" % ((Time.get_ticks_msec() - t0)/1000.0))
	if args.has("视频"):
		get_viewport().disable_3d = true
		await render_video(args["视频"], args.get("出", "user://视频"), int(args.get("超采样", "2")))
		print("[实景] 全部渲染完")
		await quit_clean()
	elif args.has("渲染"):
		get_viewport().disable_3d = true
		await render_all(args["渲染"], int(args.get("超采样", "2")))
		print("[实景] 全部渲染完")                                     # 渲染.sh 看到这一行就收尾（Godot 偶尔退出时卡住）
		await quit_clean()
	else:
		fly = Camera3D.new(); fly.near = 0.02; fly.far = 200000.0; add_child(fly)
		use_cam(cams[2] if cams.size() > 2 else cams[0], fly)
		fly.current = true
		var vp := get_viewport()
		if args.has("MSAA"): vp.msaa_3d = {"0": Viewport.MSAA_DISABLED, "2": Viewport.MSAA_2X, "4": Viewport.MSAA_4X}[args["MSAA"]]
		match args.get("AA", "TAA"):                                   # 实时抗锯齿：TAA（默认，比 MSAA2 省 ~3.5 ms）/ MSAA2 / FSR2（原生分辨率）/ 无
			"MSAA2": pass
			"TAA": vp.msaa_3d = Viewport.MSAA_DISABLED; vp.use_taa = true
			"FSR2": vp.msaa_3d = Viewport.MSAA_DISABLED; vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2; vp.scaling_3d_scale = 1.0
			"无": vp.msaa_3d = Viewport.MSAA_DISABLED
		if args.get("SSAO半", "0") == "1":
			RenderingServer.environment_set_ssao_quality(RenderingServer.ENV_SSAO_QUALITY_MEDIUM, true, 0.5, 2, 50, 300)
		if args.get("SDFGI慢", "0") == "1":                            # SDFGI 每帧少更新些（收敛慢、尖峰低）
			RenderingServer.environment_set_sdfgi_frames_to_converge(RenderingServer.ENV_SDFGI_CONVERGE_IN_30_FRAMES)
			RenderingServer.environment_set_sdfgi_frames_to_update_light(RenderingServer.ENV_SDFGI_UPDATE_LIGHT_IN_16_FRAMES)
			RenderingServer.environment_set_sdfgi_ray_count(RenderingServer.ENV_SDFGI_RAY_COUNT_32)
		if args.has("缩放"):                                          # 3D 分辨率缩放：AA=FSR2 用 FSR2 放大；TAA / 无（设置页手改）用双线性放大，抗锯齿照旧
			vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2 if args.get("AA", "TAA") == "FSR2" else Viewport.SCALING_3D_MODE_BILINEAR
			vp.scaling_3d_scale = float(args["缩放"])
		if args.get("车", "1") == "0" and rover_root: rover_root.visible = false
		if args.get("石块", "1") == "0":
			for c in get_children(): if c is MultiMeshInstance3D: c.visible = false
		if args.get("地面", "1") == "简":                                 # 诊断：地面换成最简材质，分开几何与着色的开销
			var sm := StandardMaterial3D.new(); sm.albedo_color = Color(0.3, 0.2, 0.15)
			for c in get_children(): if c is MeshInstance3D and String(c.name).begins_with("ring_"): c.material_override = sm
		if args.get("地面", "1") == "0":
			for c in get_children(): if c is MeshInstance3D and String(c.name).begins_with("ring_"): c.visible = false
		# 可插拔模块（各自一个脚本，有就加载）：控制/控制.gd（驾驶、相机模式；有它时下面的自由飞行让出输入）、界面/界面.gd（HUD v3 丙；--界面=旧 换 v2）。
		# 模块通过父节点（本脚本）拿场景：J、args、lod（lod.h_cpu 取高）、rover_root、pose_rover()、set_time_f()、minutes()、ltst、sun、ground_mat。
		# 测帧默认不带模块（和以前的数可比）；--测帧模块=1 带上（控制模块要配 --相机模式=自由，测帧移动的是 fly）。
		if rt and args.get("后处理", "1") == "1":                         # 颗粒感 §1：CAS 锐化 + 颗粒（屏幕后处理，在色调映射和 TAA / FSR2 之后）
			post = load("res://后处理.gd").new(); post.name = "后处理"; add_child(post)
			if not post.setup(args): post.queue_free(); post = null
		var 诊断运行 := args.has("测帧") or args.has("实时截图") or args.has("实时录")
		if not 诊断运行 or args.get("测帧模块", "0") == "1":
			for mod in ["res://控制/控制.gd", "res://界面/界面.gd", "res://天气/天气.gd", "res://声音/声音.gd", "res://玩法/玩法.gd", "res://界面/主菜单.gd", "res://界面/地图台/地图台.gd"]:   # 玩法：docs/玩法A.md，--玩法=0 不加载；主菜单：令.要菜单() 为假时自己退出（界面 2）
				if args.get("模块", "1") == "1" and ResourceLoader.exists(mod) and not (mod.contains("玩法") and args.get("玩法", "1") == "0"):
					var src: String = "res://界面/界面_v2.gd" if mod.ends_with("/界面.gd") and args.get("界面", "") == "旧" else mod   # --界面=旧：v2 仪表式（A/B 对比）
					var node: Node = load(src).new(self) if mod.ends_with("/主菜单.gd") else load(src).new(); node.name = mod.get_file().get_basename(); add_child(node)
		if args.has("测帧"): bench(); return
		if args.has("实时截图"): rt_shots(); return
		if args.has("实时录"): rt_record(); return
		if not has_meta("menu_mouse"): Input.mouse_mode = Input.MOUSE_MODE_CAPTURED   # 主菜单开着时鼠标要能动（它在自己的 _ready 里放开了鼠标，这里不能再抓回去）


func quit_clean() -> void:
	"""退出前先停声音模块的播放器并等两帧，否则 Godot 退出时报 resources still in use。"""
	if has_node("声音") and get_node("声音").has_method("stop_all"):
		get_node("声音").stop_all(); await get_tree().process_frame; await get_tree().process_frame
	get_tree().quit()


func bench() -> void:
	"""测帧率：每个场景 2 秒预热 + 8 秒计时，打印每帧总时间 / GPU 时间（平均、95%、最差）和三角形、绘制调用数。
	地面：人眼机位沿车头方向走；绕车：离车 6 m、1.7 m 高绕圈；高空：车上方 60 m，下俯 20° 转圈看远处；
	远足：离车 ~140 m 贴地朝车走（Navcam 数据外，中观位移在这里才起作用）。
	延时（要 --场景=延时 点名，不在默认里）：人眼机位不动，10 s 里时刻从 10:00 走到 16:00（换天空 36 次、太阳方位一直变），看换天空 / 远处地影重算卡不卡。"""
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var vp := get_viewport(); var rid := vp.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	var c0 := fly.global_transform
	var fwd := -c0.basis.z; fwd.y = 0; fwd = fwd.normalized()
	var R := rover_root.global_position if rover_root else Vector3.ZERO
	var only: Array = String(args.get("场景", "地面,绕车,高空,远足")).split(",")
	print("[实景] 测帧 %dx%d（3D 缩放 %.2f）" % [vp.size.x, vp.size.y, vp.scaling_3d_scale])
	for sc in ["地面", "绕车", "高空", "远足", "延时", "快绕", "飞行"]:
		if not only.has(sc): continue
		var ts: Array[float] = []; var gs: Array[float] = []; var tri := 0; var dc := 0
		var spikes := []                                              # 慢帧：[帧 ms, GPU ms, 换石块, 地面新建块, 地面删块]
		var t0 := Time.get_ticks_usec(); var last := t0
		while true:
			await get_tree().process_frame
			var now := Time.get_ticks_usec(); var t := (now - t0)/1e6
			if t > 10.0: break
			match sc:
				"地面": fly.global_transform = Transform3D(c0.basis, c0.origin + fwd*1.5*t)
				"绕车":
					var a := t*deg_to_rad(30.0); var p := R + Vector3(6.0*sin(a), 1.7, 6.0*cos(a))
					fly.global_transform = Transform3D.IDENTITY.translated(p).looking_at(R + Vector3(0, 0.6, 0), Vector3.UP)
				"快绕":                                                # 材质缓存压测（点名才跑）：离车 9 m、180°/s（线速度 28 m/s）绕圈
					var a := t*deg_to_rad(180.0); var p := R + Vector3(9.0*sin(a), 1.7, 9.0*cos(a))
					fly.global_transform = Transform3D.IDENTITY.translated(p).looking_at(R + Vector3(0, 0.6, 0), Vector3.UP)
				"飞行":                                                # 材质缓存压测（点名才跑）：自由相机 Shift 15 m/s 贴地飞，眼高 1.6 m
					var p := Vector3(100, 0, 100) + Vector3(-0.7071, 0, -0.7071)*15.0*t
					p.y = (lod.h_cpu(p.x, p.z, 0) if lod else 0.0) + 1.6
					fly.global_transform = Transform3D.IDENTITY.translated(p).looking_at(Vector3(p.x - 10.0, p.y - 0.5, p.z - 10.0), Vector3.UP)
				"高空":
					var a := t*deg_to_rad(20.0); var d := Vector3(sin(a), -tan(deg_to_rad(20.0)), cos(a))
					fly.global_transform = Transform3D.IDENTITY.translated(R + Vector3(0, 60, 0)).looking_at(R + Vector3(0, 60, 0) + d, Vector3.UP)
				"远足":                                                # 离车 ~140 m（Navcam 范围外，中观位移生效）贴地朝车走，眼高 1.6 m
					var p := Vector3(100, 0, 100).lerp(Vector3(60, 0, 60), t/10.0)
					p.y = (lod.h_cpu(p.x, p.z, 0) if lod else 0.0) + 1.6
					fly.global_transform = Transform3D.IDENTITY.translated(p).looking_at(Vector3(0, p.y - 4.0, 0), Vector3.UP)
				"延时":
					fly.global_transform = c0; set_time_f(600.0 + 36.0*t)
			ground_mat.set_shader_parameter("pixel_angle", deg_to_rad(fly.fov)/vp.size.x)
			if mcache and t > 2.0 and ts.is_empty(): mcache.report()                # 预热段的烘焙不计
			if t > 2.0:
				ts.append((now - last)/1000.0); gs.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
				if ts[-1] > 14.0: spikes.append([snappedf(ts[-1], 0.1), snappedf(gs[-1], 0.1), rk_applied, lod.n_new if lod else 0, lod.n_del if lod else 0])
				tri = maxi(tri, RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME))
				dc = maxi(dc, RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
			rk_applied = 0
			last = now
		var n := ts.size(); var avg: float = ts.reduce(func(a, b): return a + b)/n; var gavg: float = gs.reduce(func(a, b): return a + b)/n
		ts.sort(); gs.sort()
		if sc == "延时":                                                # 核对后台结果跟得上：天空、地影方位是不是最新的
			for k in 30: await get_tree().process_frame
			print("[实景]   延时结束：时刻 %.1f min，天空 %s（待算 %s），地影方位 %.2f°（要 %.2f°），排队 %d 层" % [time_m, sky_now, sky_pending,
				rad_to_deg(hz.sun_az) if hz else 0.0, rad_to_deg(hz.sun_req) if hz else 0.0, hz.uploads.size() if hz else 0])
		if spikes.size(): print("[实景]   慢帧 %d 个（>14 ms）：%s" % [spikes.size(), str(spikes.slice(0, 12))])
		if lod: print("[实景]   CDLOD 块 %d，R0 %.1f m" % [lod.n_sel, lod.range0])
		if scat: print("[实景]   撒石 区块 %d、石块 %d（累计生成 %d 区块）" % [scat.n_tiles, scat.n_rocks, scat.n_gen])
		print("[实景]   显存 %.0f MB（其中贴图 %.0f MB）" % [RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED)/1048576.0,
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED)/1048576.0])
		print("[实景] 测帧 %s：帧 平均 %.2f ms（%.0f fps）95%% %.2f 最差 %.2f ｜ GPU 平均 %.2f 95%% %.2f ｜ 三角形 %.1f M，绘制 %d，%d 帧" % [
			sc, avg, 1000.0/avg, ts[int(n*0.95)], ts[-1], gavg, gs[int(n*0.95)], tri/1e6, dc, n])
		if mcache: print("[实景] 测帧 %s 材质缓存：%s" % [sc, mcache.report()])
	await quit_clean()


# ———————————————————— 天空、太阳、曝光
func sky_image(file: String) -> Image:                               # 可在后台线程
	var b := FileAccess.get_file_as_bytes(D + file)
	var hd := b.slice(0, 8).to_int32_array()
	return Image.create_from_data(hd[0], hd[1], false, Image.FORMAT_RGBF, b.slice(8))


func build_env() -> void:
	sky_mat = ShaderMaterial.new(); sky_mat.shader = load("res://着色器/天空.gdshader")
	var sky := Sky.new(); sky.sky_material = sky_mat
	sky.process_mode = Sky.PROCESS_MODE_QUALITY; sky.radiance_size = Sky.RADIANCE_SIZE_256
	env = Environment.new()
	env.background_mode = Environment.BG_SKY; env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY; env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR; env.tonemap_exposure = 1.0 if expo_in_lights else pow(2.0, float(args.get("曝光", "-6")))
	env.ssao_enabled = args.get("SSAO", "1") == "1"; env.ssao_radius = 0.6; env.ssao_intensity = 1.5
	env.glow_enabled = false; env.fog_enabled = false
	# 屏幕空间反射（§17.1）：--车反射=ssr 或 探针+ssr 时开。地形自己关了高光、粗糙度 ≥ 0.7 的像素 Godot 直接跳过，实际只作用在车上
	env.ssr_enabled = String(args.get("车反射", "0")).contains("ssr")
	env.ssr_max_steps = int(args.get("SSR步", "32")); env.ssr_fade_in = 0.15; env.ssr_fade_out = 2.0; env.ssr_depth_tolerance = float(args.get("SSR厚", "0.2"))
	if args.get("SDFGI", "0" if args.get("地平线GI", "1") == "1" else "1") == "1":                                 # 有向距离场全局光照：挡天光、算一次反弹
		# 实时档：4 级联、10 cm 格、GI 半分辨率 —— SDFGI 级联更新的尖峰从 ~16 ms 压到 ≤ 14.5 ms（2K、测试机，见 实景地形系统.md §12）
		env.sdfgi_enabled = true; env.sdfgi_use_occlusion = args.get("SDFGI遮蔽", "1") == "1"; env.sdfgi_min_cell_size = float(args.get("格", "0.1" if rt else "0.05"))
		env.sdfgi_cascades = int(args.get("级联", "4" if rt else "6")); env.sdfgi_bounce_feedback = float(args.get("反弹", "0.5"))
		# SDFGI 的天光比 Godot 天空环境光亮 1.50 倍（只开天光、近地 / 高处两机位线性比 1.48–1.52，三通道一致；源码常数推出 4/π，
		# 余下的差没追）。不开 SDFGI 时天空环境光与 Cycles 在开阔地面吻合，所以按它定标。旧做法（截断）下这个偏亮被截断盖住了。
		env.sdfgi_energy = float(args.get("SDFGI能量", "0.667" if expo_in_lights else "1"))
		RenderingServer.gi_set_use_half_resolution(args.get("GI半", "1" if rt else "0") == "1")
	var knee := float(args.get("高光肩", "0"))                         # §17：高光肩（> 0 时 = 拐点，线性值）。线性色调映射在 1.0 硬截，正午白漆整片 255
	if knee > 0.0: highlight_shoulder(knee)
	expo_base = env.tonemap_exposure
	var we := WorldEnvironment.new(); we.environment = env; add_child(we)
	if args.has("补光"):                                              # 补丁 0001 测试：太阳前面先放一盏不开阴影的方向光（接触阴影层号不能错位）
		var fill := DirectionalLight3D.new(); fill.name = "补光"; fill.shadow_enabled = false
		fill.light_energy = float(args["补光"]) if args["补光"] != "" else 0.05
		if expo_in_lights: fill.light_energy *= pow(2.0, float(args.get("曝光", "-6")))   # 0.05 是按旧曝光定的
		fill.rotation_degrees = Vector3(-60.0, 30.0, 0.0); add_child(fill)
	sun = DirectionalLight3D.new(); add_child(sun)
	sun.light_angular_distance = 0.38
	sun.shadow_enabled = true; sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.shadow_enabled = args.get("阴影", "1") == "1"
	sun.directional_shadow_max_distance = float(args.get("阴影距", "150")); sun.shadow_bias = 0.02; sun.shadow_normal_bias = 1.0
	sun.light_specular = 1.0                                          # 物理值（地形着色器自己关了高光，只影响毅力号）


func highlight_shoulder(K: float) -> void:
	"""拐点 K 以下原样（线性），以上按 Reinhard 式尾巴 f = K + (1−K)·t/(1+t)，t = (L−K)/(1−K)（拐点处斜率 1、连续），渐近到 1。
	做法：色调映射曝光乘 1/H（线性，H = 4，色调映射后不截断的余量），Environment 调整打开、亮度 1，再用 1D 色彩校正表
	（4096 宽，输入 sRGB(L/H)，输出 sRGB(f(L))）还原并压肩。每通道各自压（亮的橙色会略往黄白偏，同胶片）。不改中间调。
	天气模块的自动曝光按开场的 tonemap_exposure 做基准再乘比例，所以照样对。"""
	const H := 4.0; const W := 4096
	var img := Image.create(W, 1, false, Image.FORMAT_RGB8)
	for i in W:
		var u := (i + 0.5)/W
		var L := (u/12.92 if u <= 0.04045 else pow((u + 0.055)/1.055, 2.4))*H
		var f := L if L <= K else K + (1.0 - K)*((L - K)/(1.0 - K))/(1.0 + (L - K)/(1.0 - K))
		var o := 12.92*f if f <= 0.0031308 else 1.055*pow(f, 1.0/2.4) - 0.055
		if args.has("肩阶"):                                           # 诊断：三个通道各一个阈值的阶跃表，量色彩校正的输入
			var th: PackedStringArray = String(args["肩阶"]).split(",")
			img.set_pixel(i, 0, Color(float(u > float(th[0])), float(u > float(th[1])), float(u > float(th[2])))); continue
		img.set_pixel(i, 0, Color(o, o, o))
	env.tonemap_exposure *= 1.0/H
	env.adjustment_enabled = true; env.adjustment_brightness = 1.0
	env.adjustment_contrast = float(args.get("肩对比", "1.0")); env.adjustment_saturation = 1.0
	env.adjustment_color_correction = ImageTexture.create_from_image(img)


var time_m := -1.0                                                    # 当前时刻（分钟）：换天空组时按它重设

func set_time(t: String) -> void:
	if not J["sky"].has(t): t = J["sky"].keys()[0]
	ltst = t; time_m = minutes(t)
	var s: Dictionary = J["sky"][t]
	use_sky(t)
	set_sun(Vector3(s["sun"][0], s["sun"][1], s["sun"][2]), s["T"])
	print("[实景] %s 太阳高 %.1f°" % [t, s["elev"]])


var sky_cache := {}
var sky_now := ""
var sky_E := {}                                                   # 天空图 → 水平面天光照度（逐通道，W/m²）


func sky_irradiance(img: Image) -> Vector3:
	"""上半球 ∫L·sinh·dΩ（等距圆柱，第 0 行＝天顶），每 4 列取一列：天空沿方位很平滑，误差 < 1%。可在后台线程调。"""
	var w := img.get_width(); var h := img.get_height()
	var acc := Vector3.ZERO
	for j in h/2:
		var el := (0.5 - (j + 0.5)/h)*PI
		var row := Vector3.ZERO
		for i in range(0, w, 4):
			var c := img.get_pixel(i, j); row += Vector3(c.r, c.g, c.b)
		acc += row*4.0/w*sin(el)*cos(el)
	return acc*(2.0*PI)*(PI/h)*float(J["E_TOP"])

func use_sky(key: String) -> void:
	"""换天空。实时档（bg）且已有天空时：后台读图、算水平天光和地平线 GI 表，算完下一帧换上（期间照旧用上一张，10 分钟一张看不出）。"""
	if key == sky_now or key == sky_pending: return
	if bg and sky_now != "":
		sky_want = key; kick_sky(); return
	sky_apply(sky_prepare(key, sky_img.get(key), sky_E.get(key)), true)


func kick_sky() -> void:
	if sky_task >= 0 or sky_want == "": return
	var key := sky_want; sky_want = ""
	if key == sky_now: return
	sky_pending = key
	var img: Image = sky_img.get(key); var E = sky_E.get(key)          # 在主线程取，后台只读不写这两个表
	sky_task = WorkerThreadPool.add_task(func(): sky_job = sky_prepare(key, img, E))
	if hz: hz.sky_busy = true


func sky_prepare(key: String, img: Image, E) -> Dictionary:           # 可在后台线程：不碰渲染服务器
	var t0 := Time.get_ticks_usec()
	if img == null: img = sky_image(J["sky"][key]["file"])
	var t1 := Time.get_ticks_usec()
	if E == null: E = sky_irradiance(img)
	var t2 := Time.get_ticks_usec()
	var hj: Dictionary = hz.sky_prepare(img, float(J["E_TOP"])) if hz else {}
	var t3 := Time.get_ticks_usec()
	if args.has("异步统计"): print("[实景] 换天空 %s 准备：读图 %.0f ms、水平天光 %.0f ms、地平线 GI %.0f ms；表的开阔平地天光 %s vs 逐像素 %s" % [key,
		(t1 - t0)/1000.0, (t2 - t1)/1000.0, (t3 - t2)/1000.0, str(hj.get("oE", Vector3.ZERO)), str(E)])
	return {"key": key, "img": img, "E": E, "hz": hj}


func sky_apply(job: Dictionary, sync: bool) -> void:
	var key: String = job["key"]
	sky_img[key] = job["img"]
	if not sky_cache.has(key): sky_cache[key] = ImageTexture.create_from_image(job["img"])
	var tex: ImageTexture = sky_cache[key]
	if not sky_E.has(key):
		sky_E[key] = job["E"]
		var Ej = J["sky"][key].get("E_sky", -1.0)
		var ph: Vector3 = sky_E[key]*float(J["E_TOP_phys"])/float(J["E_TOP"])
		if sync: print("[实景] 天光 %s：水平照度 %.1f / %.1f / %.1f W/m²（数据表 %.1f）" % [key, ph.x, ph.y, ph.z, Ej])
	if hz: hz.sky_apply(job["hz"], key, sync)
	sky_now = key; sky_pending = ""
	var E_TOP: float = J["E_TOP"]
	sky_mat.set_shader_parameter("sky_tex", tex); sky_mat.set_shader_parameter("E_TOP", E_TOP)
	for m in [ground_mat, rock_mat]:
		if m: m.set_shader_parameter("sky_tex", tex); m.set_shader_parameter("E_TOP", E_TOP); m.set_shader_parameter("beta_ap", J["beta_ap"]*float(args.get("空气透视", "1")))
	if not sync and sun_last.size(): set_sun(sun_last[0], sun_last[1])   # 地面辐亮度（下半球、L_g）跟着新天空


func poll_sky() -> void:
	if sky_task >= 0 and WorkerThreadPool.is_task_completed(sky_task):
		WorkerThreadPool.wait_for_task_completion(sky_task); sky_task = -1
		sky_apply(sky_job, false); sky_job = {}
		if hz: hz.sky_busy = false
		kick_sky()


func set_sky_set(sky: Dictionary, beta: float) -> void:
	"""天气模块用：整套换天空（各时刻的天空图、太阳方向、透过率，格式同 scene.json 的 sky）和近地消光 beta_ap（/m），按当前时刻重设。"""
	if sky_task >= 0: WorkerThreadPool.wait_for_task_completion(sky_task); sky_task = -1   # 旧天空的后台结果作废
	sky_job = {}; sky_want = ""; sky_pending = ""
	J["sky"] = sky; J["beta_ap"] = beta
	sky_cache.clear(); sky_E.clear(); sky_img.clear(); sky_now = ""
	if hz: hz.clear_tables()
	set_time_f(time_m if time_m >= 0.0 else minutes(ltst))


func minutes(t: String) -> float:
	var p := t.split(":")
	return float(p[0])*60.0 + float(p[1])


func set_time_f(m: float) -> void:
	"""任意时刻（分钟）：太阳方向与透过率在相邻两张天空之间插值，天空图取最近的一张（10 分钟一张时看不出跳变）。"""
	var ks: Array = J["sky"].keys()
	ks.sort_custom(func(a, b): return minutes(a) < minutes(b))
	var i := 0
	while i < ks.size() - 2 and minutes(ks[i + 1]) <= m: i += 1
	var a: Dictionary = J["sky"][ks[i]]; var b: Dictionary = J["sky"][ks[i + 1]]
	var u := clampf((m - minutes(ks[i]))/(minutes(ks[i + 1]) - minutes(ks[i])), 0.0, 1.0)
	time_m = m
	use_sky(ks[i] if u < 0.5 else ks[i + 1])
	var da := Vector3(a["sun"][0], a["sun"][1], a["sun"][2]).normalized()
	var db := Vector3(b["sun"][0], b["sun"][1], b["sun"][2]).normalized()
	var T := []
	for c in 3: T.append(lerp_log(a["T"][c], b["T"][c], u))
	set_sun(da.slerp(db, u), T)
	var kn: Dictionary = a if u < 0.5 else b                           # 显示的那张天空（最近的）
	set_exposure(lerp_log(float(a["E_sun_h"]) + float(a["E_sky"]), float(b["E_sun_h"]) + float(b["E_sky"]), u), float(kn["E_sun_h"]) + float(kn["E_sky"]), float(kn["E_sun_h"]))


func lerp_log(x: float, y: float, u: float) -> float:
	"""相邻两张天空之间插值：太阳低时直射透过率每度差好几倍，线性插值会在两张的中点偏亮很多，所以两端都 > 0 且差超过 25% 时按几何插值
	（差在 25% 以内——08:00–16:00 的 10 分钟档——仍是线性，和以前逐位相同）。"""
	if x > 1e-12 and y > 1e-12 and (maxf(x, y)/minf(x, y) > 1.25): return exp(lerpf(log(x), log(y), u))
	return lerpf(x, y, u)


func set_exposure(E_h: float, E_near: float, E_dir: float) -> void:
	"""曝光倍数 expo_mul = 亮度连续化 × 自动曝光，乘在 expo_base 上（env.tonemap_exposure）。
	亮度连续化：天空图只取最近的一张，太阳低时相邻两张亮度差 20–50%（暮光里每度差 1.5 倍），换图会闪。直射光占水平照度 < 2% 时
	（太阳 < ~6°，整个暮光）场景几乎只被天光照亮，亮度 ∝ 水平照度，所以乘 E_h(插值) / E_h(显示的那张)，换图处亮度连续；直射占 > 6% 时不乘（平滑过渡）。
	自动曝光（--曝光=自动）：EV = clamp(log2(EXPO_REF / E_h), 0, EXPO_MAX_EV)，E_h 是当前时刻水平照度（W/m²）。固定模式只有连续化。"""
	var w := 1.0 - smoothstep(0.02, 0.06, E_dir/maxf(E_near, 1e-9))
	if args.get("亮度连续化", "1") == "0" or time_m < 1020.0: w = 0.0   # 17:00（最后一张老天空）之前不用：08:00–17:00 的曝光和全日天空之前逐位相同；--亮度连续化=0 全关（诊断）
	var m := lerpf(1.0, E_h/maxf(E_near, 1e-9), w)
	if expo_mode == "自动": m *= pow(2.0, clampf(log(EXPO_REF/maxf(E_h, 1e-9))/log(2.0), 0.0, EXPO_MAX_EV))
	if absf(m - expo_mul) < 1e-6: return
	expo_mul = m
	env.tonemap_exposure = expo_base*expo_mul


func set_sun(dir: Vector3, T: Array) -> void:
	sun_last = [dir, T]
	var E_TOP: float = J["E_TOP"]
	var d := dir.normalized()
	var Tm: float = (T[0] + T[1] + T[2])/3.0
	sun.light_energy = E_TOP*Tm/PI*float(args.get("太阳", "1"))      # Godot 的 LIGHT_COLOR 含 π（物理 BRDF 的 1/π 抵掉）；--太阳=0 诊断：只看天光
	sun.light_color = Color(T[0]/Tm, T[1]/Tm, T[2]/Tm).linear_to_srgb() if Tm > 1e-12 else Color.WHITE   # 灯色按 sRGB 填（Tm = 0＝太阳在地平线下，灯关）
	sun.visible = sun.light_energy > 1e-6                          # 太阳落下去：能量早已连续降到 0，这里只是不再算阴影（日落后每帧省一次级联）
	var up := Vector3.UP if abs(d.y) < 0.99 else Vector3.FORWARD
	sun.look_at_from_position(Vector3.ZERO, -d, up)
	if hz: hz.set_sun(d)                                          # G2 远处地影
	var phi := atan2(d.z, d.x)                                    # 材质缓存的微观自阴影（地平线图）要太阳水平方位的 cos / sin 1–3 阶（φ 从 +x 朝 +z，同烘焙）
	if ground_mat:
		ground_mat.set_shader_parameter("mc_sun", d)
		ground_mat.set_shader_parameter("mc_sunt", Vector4(cos(phi), sin(phi), cos(2.0*phi), sin(2.0*phi)))
		ground_mat.set_shader_parameter("mc_sunt3", Vector2(cos(3.0*phi), sin(3.0*phi)))
	var r: float = deg_to_rad(0.19)
	var Ls := Vector3(T[0], T[1], T[2])*E_TOP/(PI*r*r)/0.8
	sky_mat.set_shader_parameter("sun_radiance", Ls); sky_mat.set_shader_parameter("sun_radius", r)
	sky_mat.set_shader_parameter("sun_disc", not args.has("渲染"))
	# 环境图的下半球 = 地面辐亮度 ρ_g·(E_直射 + E_天光)/π（按全局平均反照率、朗伯近似）；--下半球=0 关（旧做法：地平线以下照样是天空）
	var Lg := Vector3(-1, -1, -1)
	if sky_E.has(sky_now):
		var bc: Array = J["base_color"]; var Es: Vector3 = sky_E[sky_now]; var h := maxf(d.y, 0.0)
		Lg = Vector3(bc[0]*(E_TOP*T[0]*h + Es.x), bc[1]*(E_TOP*T[1]*h + Es.y), bc[2]*(E_TOP*T[2]*h + Es.z))/PI
		if hz: hz.set_ground(Lg)                                     # 地平线 GI：被地形挡住的方向看到的平均地面
	sky_mat.set_shader_parameter("ground_radiance", Lg if args.get("下半球", "1") == "1" else Vector3(-1, -1, -1))


# ———————————————————— 地面
func load_near_fine() -> void:
	"""近景细化（72_近景细化.py）：4 mm 反照率、2 mm 工作区贴片、每纹素数据分辨率、片元细坡度；CDLOD 高度改正在 地形LOD.gd 里叠。
	--近细=0 关（着色器 fine_half = 0，高度层不改）。"""
	if not J.has("near_fine") or args.get("近细", "1") == "0":
		print("[实景] 近景细化：关"); return
	var NF: Dictionary = J["near_fine"]; var t0 := Time.get_ticks_msec()
	ground_mat.set_shader_parameter("fine_alb", tex(NF["albedo"]["file"]))
	ground_mat.set_shader_parameter("fine_patch", tex(NF["patch"]["file"]))
	ground_mat.set_shader_parameter("fine_res", tex(NF["res"]["file"]))
	var b := FileAccess.get_file_as_bytes(D + NF["slope"]["file"])      # int32 宽、高 + float16 RG
	var hd := b.slice(0, 8).to_int32_array()
	var img := Image.create_from_data(hd[0], hd[1], false, Image.FORMAT_RGH, b.slice(8))
	img.generate_mipmaps()
	ground_mat.set_shader_parameter("fine_slope", ImageTexture.create_from_image(img))
	var r: Array = NF["patch"]["rect"]
	ground_mat.set_shader_parameter("fine_patch_rect", Vector4(r[0], r[1], r[2], r[3]))
	ground_mat.set_shader_parameter("fine_patch_res", float(NF["patch"]["res"]))
	var fd: Array = NF.get("slope_fade", [0.01, 0.03])
	if args.get("近细坡度", "1") == "0": fd = [-2.0, -1.0]               # --近细坡度=0：不加片元细坡度（A/B）
	ground_mat.set_shader_parameter("fine_slope_fade", Vector2(fd[0], fd[1]))
	ground_mat.set_shader_parameter("fine_half", float(NF["albedo"]["half"]))
	print("[实景] 近景细化：±%.2f m，%d ms" % [float(NF["albedo"]["half"]), Time.get_ticks_msec() - t0])


func tex(name: String) -> Texture2D:
	return load(环境.资源目录() + name)                                 # 导入过的贴图在 PCK 里：导出包也走 res://


func float_tex(file: String) -> ImageTexture:
	var b := FileAccess.get_file_as_bytes(D + file)
	var hd := b.slice(0, 8).to_int32_array()
	var img := Image.create_from_data(hd[0], hd[1], false, Image.FORMAT_RF, b.slice(8))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func shader_of(path: String) -> Shader:
	"""--材质=旧（或材质数据不全）：同一份代码前加 #define MAT_OLD 另编一份——两份各自编译，寄存器互不拖累，A/B 才公平。"""
	var s: Shader = load(path)
	var defs := ""                                                      # 诊断：--着色器定义=A,B → 代码前加 #define A、#define B（测帧比编译期开关）
	for d in String(args.get("着色器定义", "")).split(",", false): defs += "#define %s\n" % d
	if args.get("材质缓存", "1") == "1" and mat_sys != null: defs += "#define MAT_CACHE\n"
	if mat_sys != null and mat_sys.fmt == 4: defs += "#define MAT_N16\n"           # 中景版：4 槽控制图、16 种材质累加、逐材质增益；--中景=0 时不定义 = 原来的代码，性能同前
	if mat_sys != null and defs == "": return s
	var o := Shader.new(); o.code = ("" if mat_sys != null else "#define MAT_OLD\n") + defs + s.code
	return o


func build_ground() -> void:
	ground_mat = ShaderMaterial.new(); ground_mat.shader = load("res://着色器/地形.gdshader")
	if args.get("材质", "新") != "旧":                                   # 材质表 + 控制图 + 纹理数组（材质.gd）；数据不全时退回旧材质
		mat_sys = load("res://材质.gd").new()
		if not mat_sys.setup(D, args, ground_mat): mat_sys = null
	ground_mat.shader = shader_of("res://着色器/地形.gdshader")
	if mat_sys != null and args.get("材质缓存", "1") == "1":              # 材质缓存（原型）：远处的材质烘进相机中心 clipmap
		mcache = load("res://材质缓存.gd").new()
		if not mcache.setup(ground_mat, args): mcache = null
	if mat_sys == null: print("[实景] 地面材质：旧（4 槽中观）")
	var T: Dictionary = J["tex"]
	for k in ["albedo_ctx", "albedo_hirise", "albedo_mid", "albedo_near", "class_mid", "class_hirise"]:
		ground_mat.set_shader_parameter(k, tex(T[k]["file"]))
	ground_mat.set_shader_parameter("half_size", Vector4(T["albedo_ctx"]["half"], T["albedo_hirise"]["half"], T["albedo_mid"]["half"], T["albedo_near"]["half"]))
	ground_mat.set_shader_parameter("class_half", Vector2(T["class_mid"]["half"], T["class_hirise"]["half"]))
	var r: Dictionary = J["data_res"]
	ground_mat.set_shader_parameter("data_res", Vector4(r["albedo_ctx"], r["albedo_hirise"], r["albedo_mid"], r["albedo_near"]))
	var bc: Array = J["base_color"]; ground_mat.set_shader_parameter("base_color", Vector3(bc[0], bc[1], bc[2]))
	var det: Dictionary = J["detail"]
	for lv in (["meso", "micro"] if mat_sys == null else []):           # 旧材质的 4 槽细节图块（新材质不读，省显存）
		var alb: Array[Texture2D] = []; var hh: Array[Texture2D] = []; var sz := Vector4(); var gn := Vector4()
		for k in 4:
			var dd: Dictionary = det["%s_%d" % [lv, k]]
			alb.append(tex(dd["albedo"])); hh.append(float_tex(dd["height"])); sz[k] = dd["size"]
			gn[k] = float(dd.get("gain", 2.0))                        # 反照率细节 8 位里存 1/gain×（老图块没有这个键 = 2）
		ground_mat.set_shader_parameter(lv + "_size", sz); ground_mat.set_shader_parameter(lv + "_gain", gn)
		ground_mat.set_shader_parameter(lv + "_alb", alb); ground_mat.set_shader_parameter(lv + "_h", hh)
	load_near_fine()
	if args.get("网格", "LOD") == "LOD":
		lod = Node3D.new(); lod.set_script(load("res://地形LOD.gd")); lod.name = "地形LOD"; add_child(lod)
		lod.setup(J, D, ground_mat, args)
		ground_mat.set_shader_parameter("lod_dbg", int(args.get("LOD诊断", "0")))
		ground_mat.set_shader_parameter("perf_dbg", int(args.get("着色诊断", "0")))
		ground_mat.set_shader_parameter("geo_dbg", int(args.get("地貌诊断", "0")))
		ground_mat.set_shader_parameter("geo_frag", int(args.get("地貌片元", "0")))
		ground_mat.set_shader_parameter("prepass_cheap", int(args.get("预通道简化", "1" if mat_sys else "0")))   # 自编引擎 0004：法线预通道走简化分支。新材质默认开：不开时预通道把整套材质再算一遍（远足 +2.7 ms，阶段1.md §10）
		ground_mat.set_shader_parameter("disp_gain", float(args.get("位移", "1")))
		ground_mat.set_shader_parameter("disp_far", float(args.get("位移距", "25")))
		if J.has("geo"):
			geo = load("res://地貌.gd").new()
			geo.setup(J, D, args, 环境.地貌参数())
			geo.apply(ground_mat); lod.geo = geo
			if lod.core: lod.core.configure_geo(geo)
		if mat_sys:                                                     # 中观位移的 CPU 版：h_cpu（车轮、撒石、相机）和画出来的地面一致
			lod.mdisp = mat_sys
			if lod.core: lod.core.configure_mat(mat_sys)
		return
	var nv := 0
	for g in J["ground"]:
		var b := FileAccess.get_file_as_bytes(D + g["file"])
		var hd := b.slice(0, 12).to_int32_array(); var n: int = hd[0]; var ni: int = hd[1]
		var o := 12
		var arr := []; arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = b.slice(o, o + n*12).to_vector3_array(); o += n*12
		arr[Mesh.ARRAY_NORMAL] = b.slice(o, o + n*12).to_vector3_array(); o += n*12
		arr[Mesh.ARRAY_INDEX] = b.slice(o, o + ni*4).to_int32_array()
		var m := ArrayMesh.new(); m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		var mi := MeshInstance3D.new(); mi.mesh = m; mi.material_override = ground_mat; mi.name = g["file"].get_basename()
		if g["half"] > 200.0 or args.get("地影", "1") == "0": mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi); nv += n
	print("[实景] 地面 %d 环 %d 顶点" % [J["ground"].size(), nv])


# ———————————————————— 石块
func hash01(x: float, salt: float) -> float:
	return fposmod(sin(x*12.9898 + salt*78.233)*43758.5453, 1.0)


func enu_basis(rx: float, ry: float, rz: float, sx: float, sy: float, sz: float) -> Basis:
	"""ENU 里 R = Rz·Ry·Rx（Blender 欧拉 XYZ）再缩放 → Godot 基：G·M·Gᵀ。"""
	var M := Basis.from_euler(Vector3(rx, ry, rz), EULER_ORDER_XYZ)*Basis.from_scale(Vector3(sx, sy, sz))
	var G := Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0))   # 列：E→x、N→−z、U→y
	return G*M*G.transposed()


func build_rocks() -> void:
	rk_lod = args.get("石块分级", "1") == "1"
	var R: Dictionary = J["rocks"]
	var b := FileAccess.get_file_as_bytes(D + R["file"])
	var hd := b.slice(0, 12).to_int32_array(); var nv: int = hd[0]; var ns: int = hd[1]
	var o := 12
	var P := b.slice(o, o + nv*12).to_vector3_array(); o += nv*12
	var N := b.slice(o, o + nv*12).to_vector3_array(); o += nv*12
	var S := b.slice(o, o + ns*28).to_float32_array()
	rock_mat = ShaderMaterial.new(); rock_mat.shader = shader_of("res://着色器/石块.gdshader")
	var d2: Dictionary = J["detail"]["micro_2"]
	rock_mat.set_shader_parameter("detail_alb", tex(d2["albedo"])); rock_mat.set_shader_parameter("detail_h", float_tex(d2["height"]))
	rock_mat.set_shader_parameter("detail_size", d2["size"]); rock_mat.set_shader_parameter("detail_gain", float(d2.get("gain", 2.0)))
	rock_mat.set_shader_parameter("dbg", int(args.get("石块诊断", "0")))
	rock_mat.set_shader_parameter("rock_dust", float(args.get("石尘", "1")))
	if args.has("石净"):                                              # 诊断：干净岩面 / 积尘反照率比，--石净=1,1,1 = 不分两色（改前）
		var q := String(args["石净"]).split(","); rock_mat.set_shader_parameter("clean_ratio", Vector3(float(q[0]), float(q[1]), float(q[2])))
	var meshes: Array = R["meshes"]; var nm := meshes.size()
	var bc: Array = R["base"]; var base := Color(bc[0], bc[1], bc[2])
	var xf: Array = []; var cl: Array = []
	for i in nm: xf.append([]); cl.append([])
	var tint := func(sd: float, c: Color) -> Color:
		var r := hash01(sd, 3.1)
		return Color(c.r*lerp(0.75, 1.2, r), c.g*lerp(0.75, 1.15, r), c.b*lerp(0.75, 1.1, r))
	for i in nm:                                                     # 实测：位置 + (D, D, H)，对象色
		var m: Dictionary = meshes[i]; var p: Array = m["pos"]; var c: Array = m["color"]
		xf[i].append(Transform3D(enu_basis(0, 0, 0, m["D"], m["D"], m["H"]), Vector3(p[0], p[1], p[2])))
		var oc := Color(c[0], c[1], c[2])
		if Vector3(c[0], c[1], c[2]).length() <= 0.01: oc = base       # 同 58：没取到颜色的实测石块用全局石色
		cl[i].append(tint.call(float(i)*7.77, oc))
	if rk_lod and geo and args.get("撒石", "实时") == "实时":           # 实时撒石取代固定表
		var yr := []
		for i in nm:
			var m: Dictionary = meshes[i]; var lo := INF; var hi := -INF
			for v in P.slice(m["off"], m["off"] + m["n"]): lo = minf(lo, v.y); hi = maxf(hi, v.y)
			yr.append([lo, hi])
		scat = load("res://撒石.gd").new(); scat.setup(self, lod, geo, J, nm, base, yr); ns = 0
		if lod and lod.core: lod.core.configure_scatter(scat)
		if args.has("撒石统计"):
			for pt in String(args["撒石统计"]).split(";"):
				var q := pt.split(","); print("[撒石] 统计 (%s)：%s" % [pt, scat.stats(float(q[0]), -float(q[1]), 20.0)])
	for j in ns:                                                     # 统计：x y z D 偏航 种子 高宽比（Godot 坐标的位置）
		var q := j*7
		var sd := S[q + 5]; var i := int(fposmod(sd, nm))
		var D_ := S[q + 3]
		var B := enu_basis((hash01(sd, 1.0) - 0.5)*0.7, (hash01(sd, 2.0) - 0.5)*0.7, S[q + 4], D_, D_, D_*S[q + 6])
		xf[i].append(Transform3D(B, Vector3(S[q], S[q + 1], S[q + 2])))
		cl[i].append(tint.call(sd, base))
	var t0 := Time.get_ticks_msec(); var lod_tris := [0, 0, 0]
	for i in nm:
		var m: Dictionary = meshes[i]; var a: int = m["off"]; var n: int = m["n"]
		var ms: Array = rock_lods(P.slice(a, a + n)) if rk_lod else [flat_mesh(P.slice(a, a + n), N.slice(a, a + n))]
		var ab := AABB(P[a], Vector3.ZERO)
		for v in P.slice(a, a + n): ab = ab.expand(v)
		rk_aabb.append_array([ab.get_center().x, ab.get_center().y, ab.get_center().z, ab.size.x/2.0, ab.size.y/2.0, ab.size.z/2.0])
		var T := {"buf": PackedFloat32Array(), "pos": PackedVector3Array(), "D": PackedFloat32Array(), "mm": []}
		for k in xf[i].size():                                         # MultiMesh 缓冲：每块 12 个变换数（按行）+ 4 个颜色数
			var x: Transform3D = xf[i][k]; var c: Color = cl[i][k]; var bb := x.basis
			T["buf"].append_array([bb.x.x, bb.y.x, bb.z.x, x.origin.x, bb.x.y, bb.y.y, bb.z.y, x.origin.y, bb.x.z, bb.y.z, bb.z.z, x.origin.z, c.r, c.g, c.b, c.a])
			T["pos"].append(x.origin); T["D"].append(maxf(bb.x.length(), bb.z.length()))
		for l in ms.size():
			var mm := MultiMesh.new(); mm.transform_format = MultiMesh.TRANSFORM_3D; mm.use_colors = true; mm.mesh = ms[l]
			var mmi := MultiMeshInstance3D.new(); mmi.multimesh = mm; mmi.material_override = rock_mat; mmi.name = "石块_%02d_%d" % [i, l]
			if args.get("石影", "1") == "0" or (l > int(args.get("石影级", "1" if scat else "2"))): mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF   # 撒石时最远一级不投影
			add_child(mmi); T["mm"].append(mm)
			lod_tris[l] += ms[l].surface_get_array_len(0)/3
		rk_types.append(T)
	if not rk_lod:                                                     # 老做法：全部实例、全精度
		for T in rk_types:
			T["mm"][0].instance_count = T["pos"].size(); T["mm"][0].buffer = T["buf"]
	for k in ["albedo_mid", "albedo_near", "half_size", "data_res", "class_mid", "class_hirise", "class_half", "meso_h", "meso_size",
			"lod_c0", "lod_range0", "disp_far", "disp_gain", "mat_ctrl_n", "mat_ctrl_f", "mat_gate", "mat_grid", "mat_out_id", "mat_out_w",
			"mat_meso_h16", "mat_me", "mat_bl", "mat_lay", "mat_hexp", "mat_k", "mat_cpu_cell", "mat_fmt"]:   # 中观位移：石块和地面用同一套参数
		rock_mat.set_shader_parameter(k, ground_mat.get_shader_parameter(k))
	if lod: lod.mats.append(rock_mat)
	if scat and mat_sys and args.get("砾石", "1") == "1":
		pebbles = load("res://砾石.gd").new()
		if not pebbles.setup(self, lod, geo, mat_sys, J, rock_mat, base, args): pebbles = null
	print("[实景] 石块 %d 种，统计 %d 块；分级 %s（平均每种 %s 面），%d ms" % [nm, ns, "开" if rk_lod else "关",
		str([lod_tris[0]/nm, lod_tris[1]/nm, lod_tris[2]/nm]), Time.get_ticks_msec() - t0])


# 石块远近分级：每种石块 3 级网格（meshoptimizer 简化到约 1/4、1/16），按屏幕上的直径（像素）选级，太小的不画。
# 分级在后台线程里算（28k 块 GDScript 要几十 ms），相机挪动超过 RK_MOVE 才重算；离线渲染每帧同步算。
const RK_PX := [48.0, 12.0, 1.0]                                      # 直径 > 48 px 用 0 级，> 12 px 1 级，> 1 px 2 级，否则不画
const RK_MOVE := 0.5
var rk_lod := true
var rk_types: Array = []
var rk_task := -1
var rk_result: Array = []
var rk_cam := Vector3(INF, INF, INF)
var rk_applied := 0                                                   # 测帧诊断：本帧换了几次石块缓冲


func _exit_tree() -> void:
	if rk_task >= 0: WorkerThreadPool.wait_for_task_completion(rk_task); rk_task = -1   # 后台撒石没收完就退出会 abort
	if sky_task >= 0: WorkerThreadPool.wait_for_task_completion(sky_task); sky_task = -1
	if hz: hz.wait_all()
	if pebbles: pebbles.wait_all()


func flat_mesh(Pv: PackedVector3Array, Nv: PackedVector3Array) -> ArrayMesh:
	var arr := []; arr.resize(Mesh.ARRAY_MAX); arr[Mesh.ARRAY_VERTEX] = Pv; arr[Mesh.ARRAY_NORMAL] = Nv
	var am := ArrayMesh.new(); am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return am


func rock_lods(Pv: PackedVector3Array) -> Array:
	"""单位石块（平直着色、不共用顶点）→ [原网格, 约 1/4, 约 1/16]，都还原成平直着色。"""
	var idx := {}; var V := PackedVector3Array(); var I := PackedInt32Array()
	for p in Pv:
		var key := p.snappedf(1e-5)
		if not idx.has(key): idx[key] = V.size(); V.append(p)
		I.append(idx[key])
	var Nn := PackedVector3Array(); Nn.resize(V.size())
	for t in range(0, I.size(), 3):
		var fn := (V[I[t + 2]] - V[I[t]]).cross(V[I[t + 1]] - V[I[t]])
		for q in 3: Nn[I[t + q]] += fn
	for k in Nn.size(): Nn[k] = Nn[k].normalized()
	var arr := []; arr.resize(Mesh.ARRAY_MAX); arr[Mesh.ARRAY_VERTEX] = V; arr[Mesh.ARRAY_NORMAL] = Nn; arr[Mesh.ARRAY_INDEX] = I
	var im := ImporterMesh.new(); im.add_surface(Mesh.PRIMITIVE_TRIANGLES, arr)
	im.generate_lods(180.0, 180.0, [])                                   # 法线角度不设限：只看形状误差
	var n0 := I.size()/3; var out := [unindex(V, I)]
	for target in [n0/4, n0/16]:
		var best := I
		for k in im.get_surface_lod_count(0):
			var li := im.get_surface_lod_indices(0, k)
			if absf(log(float(li.size()/3)/target)) < absf(log(float(best.size()/3)/target)): best = li
		out.append(unindex(V, best))
	return out


func unindex(V: PackedVector3Array, I: PackedInt32Array) -> ArrayMesh:
	var Pv := PackedVector3Array(); var Nv := PackedVector3Array()
	for t in range(0, I.size(), 3):
		var a := V[I[t]]; var b := V[I[t + 1]]; var c := V[I[t + 2]]
		var fn := (c - a).cross(b - a).normalized()                       # 61 里三角形已反绕序：外法线 = (c−a)×(b−a)
		Pv.append_array([a, b, c]); Nv.append_array([fn, fn, fn])
	return flat_mesh(Pv, Nv)


func rock_bucket(cam: Vector3, pa: float, budget_ms := 0.0) -> Array:
	if lod and lod.core:                                              # 固定石块分级 + 撒石收集，一次在 C++ 里做完（多线程，结果逐位相同）
		var fixed := []
		for T in rk_types: fixed.append({"pos": T["pos"], "D": T["D"], "buf": T["buf"]})
		var cres: Array = lod.core.rock_bucket(cam, pa, budget_ms, fixed)
		if scat:
			var st: Dictionary = lod.core.get_scatter_stats()
			scat.pending = st["pending"]; scat.n_tiles = st["tiles"]; scat.n_rocks = st["rocks"]; scat.n_band = st["band"]; scat.n_lv = st["level"]
			scat.n_gen += int(st["generated"])                          # C++ 每次调用单独计数，这里累计（同 GDScript 版的含义）
		return cres
	var res := []
	var lists := []                                                   # 实时撒石：lists[类型][级] = 区块缓冲的列表
	if scat:
		for i in rk_types.size(): lists.append([[], [], []])
		scat.collect(cam, pa, lists, budget_ms)
	for i in rk_types.size():
		var T: Dictionary = rk_types[i]
		var pos: PackedVector3Array = T["pos"]; var Dm: PackedFloat32Array = T["D"]; var buf: PackedFloat32Array = T["buf"]
		var o0 := PackedFloat32Array(); var o1 := PackedFloat32Array(); var o2 := PackedFloat32Array()
		for k in pos.size():
			var s := Dm[k]/(maxf(pos[k].distance_to(cam), 0.01)*pa)
			if s > RK_PX[0]: o0.append_array(buf.slice(k*16, k*16 + 16))
			elif s > RK_PX[1]: o1.append_array(buf.slice(k*16, k*16 + 16))
			elif s > RK_PX[2]: o2.append_array(buf.slice(k*16, k*16 + 16))
		if scat:
			for a in lists[i][0]: o0.append_array(a)
			for a in lists[i][1]: o1.append_array(a)
			for a in lists[i][2]: o2.append_array(a)
		res.append([o0, o1, o2])
	return res


func rock_apply(res: Array) -> void:
	for i in res.size():
		for l in 3:
			var mm: MultiMesh = rk_types[i]["mm"][l]; var b: PackedFloat32Array = res[i][l]
			mm.instance_count = b.size()/16
			if b.size(): mm.buffer = b


func rocks_update(cam: Vector3, pa: float, sync: bool) -> void:
	"""sync：当场算完换上（离线渲染）；否则后台算、算完下一帧换上（漫游 / 测帧）。"""
	if not rk_lod: return
	if pebbles:
		if sync: pebbles.sync(cam, pa)
		else: pebbles.update(cam, pa)
	if sync:
		var t0 := Time.get_ticks_usec(); var r := rock_bucket(cam, pa); rock_apply(r); rk_cam = cam
		if hz:
			var t1 := Time.get_ticks_usec(); hz.rock_occ_apply(hz.rock_occ_compute(r, cam, true))
			print("[实景] 石块遮地面 %.0f ms" % ((Time.get_ticks_usec() - t1)/1000.0))
		if args.has("测帧"): print("[实景] 石块分级 %.1f ms（同步）" % ((Time.get_ticks_usec() - t0)/1000.0))
		if scat: print("[实景] 撒石 %d 块，各档 %s，各级 %s" % [scat.n_rocks, str(scat.n_band), str(scat.n_lv)])
		if scat and args.has("撒石统计近"):                           # 诊断：已上 MultiMesh 的石块里，离相机 7.5 m 内有多少、在视野里有多少
			var near := 0; var vis := 0; var cam3 := get_viewport().get_camera_3d()
			for T in rk_types:
				for l in 3:
					var mm: MultiMesh = T["mm"][l]
					for k in mm.instance_count:
						var o := mm.get_instance_transform(k).origin
						if o.distance_to(cam) < 7.5:
							near += 1
							if cam3 and cam3.is_position_in_frustum(o): vis += 1
			print("[实景] 撒石 7.5 m 内 %d 块，视野内 %d 块；相机 %s" % [near, vis, str(cam)])
		return
	if rk_task >= 0:
		if not WorkerThreadPool.is_task_completed(rk_task): return
		WorkerThreadPool.wait_for_task_completion(rk_task); rk_task = -1
		rock_apply(rk_result); rk_applied += 1
		if hz: hz.rock_occ_apply(rk_occ)
	if cam.distance_to(rk_cam) < RK_MOVE and not (scat and scat.pending): return
	rk_cam = cam
	rk_task = WorkerThreadPool.add_task(func():
		rk_result = rock_bucket(cam, pa, 30.0)
		rk_occ = hz.rock_occ_compute(rk_result, cam) if hz else [])


# ———————————————————— 毅力号
func build_rover() -> void:
	var R: Dictionary = J["rover"]
	var doc := GLTFDocument.new(); var st := GLTFState.new()
	# 车的自遮挡 AO（scripts/Godot/67_车AO.py 烘）：rover_ao.glb = 原模型 + 第二套 UV，rover_ao.png = 灰度 AO 图集。--车AO=0 用原模型
	var ao_arg: String = args.get("车AO", "1")                         # 1 = 开；0 = 原模型；glb = 新模型但不开 AO（核对导出没改坏材质）
	var has_ao := FileAccess.file_exists(D + "rover_ao.glb") and FileAccess.file_exists(D + "rover_ao.png")
	var use_ao: bool = ao_arg == "1" and has_ao
	var gfile: String = "rover_ao.glb" if (has_ao and ao_arg != "0") else R["file"]
	if doc.append_from_buffer(FileAccess.get_file_as_bytes(D + gfile), 环境.资源目录(), st) != OK: push_error("毅力号 glb 读不了：" + gfile); return
	var model: Node3D = doc.generate_scene(st)
	var root := Node3D.new(); root.name = "毅力号"; add_child(root); root.add_child(model)
	var nav := model.find_child("NavCams", true, false) as MeshInstance3D
	var pc := Vector3(-0.56, 1.97, 0.77)
	if nav:
		var ab := nav.get_aabb(); var xf := model.global_transform.affine_inverse()*nav.global_transform
		pc = Vector3.ZERO
		for k in 8: pc += xf*ab.get_endpoint(k)
		pc /= 8.0
	var c: Array = R["basis_cols"]
	var Bm := Basis(Vector3(c[0][0], c[0][1], c[0][2]), Vector3(c[1][0], c[1][1], c[1][2]), Vector3(c[2][0], c[2][1], c[2][2]))
	var mast := Vector3(R["mast"][0], R["mast"][1], R["mast"][2])
	root.transform = Transform3D(Bm, mast - Bm*pc)
	var names: Array = R["hide_in_ref"]
	for n in model.find_children("*", "Node3D", true, false):
		if String(n.name).replace(".", "_") in names:
			for g in [n] + n.find_children("*", "GeometryInstance3D", true, false):
				if g is GeometryInstance3D and not hide_parts.has(g): hide_parts.append(g)
	print("[实景] 毅力号：NavCams 中心 %s → 桅杆头 %s，对照机位藏 %d 件" % [pc, mast, hide_parts.size()])
	var ao_tex: Texture2D = null
	if use_ao:
		var ao_img := Image.load_from_file(ProjectSettings.globalize_path(D + "rover_ao.png"))
		ao_img.convert(Image.FORMAT_L8); ao_img.generate_mipmaps()
		ao_tex = ImageTexture.create_from_image(ao_img)
		var seen := {}
		for g in model.find_children("*", "MeshInstance3D", true, false):
			var mi := g as MeshInstance3D
			for si in mi.mesh.get_surface_count():
				var m := mi.get_active_material(si) as BaseMaterial3D
				if m == null or seen.has(m): continue
				seen[m] = true
				m.ao_enabled = true; m.ao_texture = ao_tex; m.ao_on_uv2 = true
				m.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED; m.ao_light_affect = 0.0   # 只压环境光和环境反射
		print("[实景] 车 AO：%d 个材质，图 %d²" % [seen.size(), ao_img.get_width()])
	rover_root = root
	var cd := float(args.get("车尘", "0.35"))                          # 积尘量（§15；§17 起默认由车材质着色器按位置落尘）
	var car_mat: bool = args.get("车材质", "1") == "1" and FileAccess.file_exists(D + "rover_材质.json")
	if car_mat: rover_materials(model, ao_tex, cd)                     # 换材质要在 rig_rover 之前：split_mesh 复制网格自带的表面材质
	if FileAccess.file_exists(D + "rover_rig.json"): rig_rover(model)
	if cd > 0.0 and not car_mat:                                       # --车材质=0：旧做法，叠加层（着色器/车尘.gdshader）
		var dm := ShaderMaterial.new(); dm.shader = load("res://着色器/车尘.gdshader")
		var bc: Array = J["base_color"]
		dm.set_shader_parameter("dust", cd); dm.set_shader_parameter("dust_col", Vector3(bc[0]*1.25, bc[1]*1.15, bc[2]))
		var n_on := 0; var n_all := 0
		for g in root.find_children("*", "GeometryInstance3D", true, false):
			var ab: AABB = (g as GeometryInstance3D).get_aabb(); var sc: Vector3 = (g as Node3D).global_transform.basis.get_scale()
			n_all += 1
			if ab.size.x*sc.x*ab.size.z*sc.z < float(args.get("车尘面", "0.03")): continue   # 小零件不加（每件一次绘制，看不出尘）
			(g as GeometryInstance3D).material_overlay = dm; n_on += 1
		rover_dust = dm
		print("[实景] 车尘 %.2f：%d / %d 件" % [cd, n_on, n_all])
	if args.has("收臂"):                                               # 行驶时机械臂收起：肩偏航、肩俯仰、肘、腕（°，在模型姿态上加）
		var q := (args["收臂"] as String).split(",")
		stow_arm(model, float(q[0]), float(q[1]), float(q[2]), float(q[3]))
	if FileAccess.file_exists(D + "车辙.bin") and args.has("视频"):        # 车辙图（66_车辆动画.py）；track_time 每帧由 pose_rover 给
		var tj: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(D + "车辙.json"))
		var b := FileAccess.get_file_as_bytes(D + "车辙.bin"); var hd := b.slice(0, 8).to_int32_array()
		var img := Image.create_from_data(hd[0], hd[1], false, Image.FORMAT_RGF, b.slice(8))
		ground_mat.set_shader_parameter("track_tex", ImageTexture.create_from_image(img))
		ground_mat.set_shader_parameter("track_rect", Vector4(tj["E0"], tj["N0"], tj["E1"], tj["N1"]))


# 车材质（§17）：glb 导入的 StandardMaterial3D → 着色器/车材质.gdshader，参数按 数据/sol0530/rover_材质.json 的「规则」（材质名 × 节点名，
# 通配符，第一条命中的算）分到「组」。组里的反照率是线性值；没写的项沿用 glb。透明件（玻璃）除非规则点名，不换。--车材质=0 回到导入的原样 + 旧尘叠加层。
# --材质高亮=材质名[@节点名][,…]：把命中的面涂色（通配符；依次品红、青、黄、绿、橙、蓝；诊断：看某个材质在车上哪里）。
var rover_mats: Array[ShaderMaterial] = []
const HL_COL := [Color(1, 0, 1), Color(0, 1, 1), Color(1, 1, 0), Color(0, 1, 0), Color(1, 0.3, 0), Color(0.2, 0.3, 1)]


func rover_materials(model: Node3D, ao_tex: Texture2D, dust: float) -> void:
	var cfg: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(D + args.get("材质表", "rover_材质.json")))   # --材质表=别的 json（A/B 试参数）
	var groups: Dictionary = cfg["组"]; var rules: Array = cfg["规则"]
	var dimg := Image.load_from_file(ProjectSettings.globalize_path(D + "rover_detail.png"))   # 不走导入（导入可能压成 VRAM 格式，法线通道会坏）
	dimg.generate_mipmaps(); var det := ImageTexture.create_from_image(dimg)
	var sh: Shader = load("res://着色器/车材质.gdshader")
	var hl: String = args.get("材质高亮", "")
	var made := {}; var count := {}
	var dc: Array = cfg.get("尘色", [0.38, 0.22, 0.09])
	var dpar: Dictionary = cfg.get("尘参数", {})                       # 全车默认（组里同名项覆盖）
	var ndust: Dictionary = cfg.get("节点挂尘", {})                     # 节点名式样 → 挂尘倍率（桅杆头高、竖直多，照片里明显比甲板干净）
	var KV := [["增益", "albedo_gain"], ["金属度", "metallic"], ["粗糙度", "roughness"], ["高光", "specular"], ["细节米", "detail_m"],
		["微法线", "micro_n"], ["拉丝", "brush"], ["粗糙起伏", "rough_var"], ["护标", "guard"], ["挂尘", "dust_k"], ["底尘", "dust_base"], ["法线强度", "normal_scale"],
		["尘膜", "dust_film"], ["缝尘", "dust_crev"], ["侧尘", "dust_side"], ["尘起伏", "dust_var"], ["砂粒", "grain_k"], ["饱和", "sat"], ["自动护标", "auto_guard"],
		["各向异性", "aniso"], ["清漆", "clearcoat"], ["清漆粗糙", "clearcoat_rough"], ["轮内AO", "wheel_in_ao"], ["槽AO", "wheel_groove_ao"]]
	# §17.1 法线贴图：同一张基色图集的材质共用法线图（glb 里只有 *_n 那几个材质挂了，同图集的兄弟材质没挂）；
	# 没有法线图的图集（03、04）用 69_车法线.py 从基色图生成的（「生成法线」：材质名式样 → 文件）
	var nmap := {}                                                     # 基色贴图 → [法线贴图, 强度]
	for g in model.find_children("*", "MeshInstance3D", true, false):
		for s in (g as MeshInstance3D).mesh.get_surface_count():
			var m := (g as MeshInstance3D).mesh.surface_get_material(s) as BaseMaterial3D
			if m and m.albedo_texture and m.normal_enabled and m.normal_texture: nmap[m.albedo_texture] = [m.normal_texture, m.normal_scale]
	var gen_n := {}
	for pat in cfg.get("生成法线", {}):
		var f: String = cfg["生成法线"][pat]
		if not FileAccess.file_exists(D + f): continue
		var ni := Image.load_from_file(ProjectSettings.globalize_path(D + f)); ni.generate_mipmaps()
		gen_n[pat] = ImageTexture.create_from_image(ni)
	var share_n: bool = args.get("借法线", "1") == "1"
	for g in model.find_children("*", "MeshInstance3D", true, false):
		var mi := g as MeshInstance3D; var node := String(mi.name)
		for s in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(s) as BaseMaterial3D
			if m == null: continue
			var nm := m.resource_name; var gname := ""; var named := false
			for r in rules:
				if (r[0] == "*" or nm.match(r[0])) and (r[1] == "*" or node.match(r[1])): gname = r[2]; named = not String(r[0]).contains("*"); break
			if m.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED and not named: continue   # 透明件（玻璃）只有规则点名（材质名不带通配符）才换
			var lit := -1                                          # --材质高亮=式样[,式样…]，式样 = 材质名[@节点名]，可用通配符；第 k 个式样涂 HL_COL[k]
			if hl != "":
				var pats := hl.split(",")
				for k in pats.size():
					var pp := pats[k].split("@"); var pm: String = pp[0] if pp[0] != "" else "*"; var pn: String = pp[1] if pp.size() > 1 else "*"
					if nm.match(pm) and node.match(pn): lit = k; break
			var nk := 1.0
			for pat in ndust:
				if node.match(pat): nk = float(ndust[pat]); break
			var key := "%d|%s|%d|%.3f" % [m.get_instance_id(), gname, lit, nk]
			if not made.has(key) and (groups.get(gname, {}) as Dictionary).has("玻璃"):   # 玻璃组：还用导入的透明材质，只改成电介质（glb 里 glass_2 是半透明的白色全金属镜面，镜头看着像一块平的亮盘）
				var G0: Dictionary = groups[gname]; var gm := m.duplicate() as BaseMaterial3D
				var a: Array = G0.get("反照率", [0.0, 0.0, 0.0])
				gm.metallic = 0.0; gm.roughness = float(G0.get("粗糙度", 0.03)); gm.metallic_specular = float(G0.get("高光", 0.5))
				gm.albedo_color = Color(Color(a[0], a[1], a[2]).linear_to_srgb(), float(G0["玻璃"]))
				made[key] = gm
			if not made.has(key):
				var q := ShaderMaterial.new(); q.shader = sh; q.resource_name = nm + "·" + gname
				q.set_shader_parameter("albedo_col", m.albedo_color)
				if m.albedo_texture: q.set_shader_parameter("albedo_tex", m.albedo_texture)
				q.set_shader_parameter("metallic", m.metallic); q.set_shader_parameter("roughness", m.roughness)
				q.set_shader_parameter("specular", m.metallic_specular)
				if m.roughness_texture:
					q.set_shader_parameter("use_mr", true); q.set_shader_parameter("mr_tex", m.roughness_texture)
				if m.normal_enabled and m.normal_texture:
					q.set_shader_parameter("use_normal", true); q.set_shader_parameter("normal_tex", m.normal_texture)
					q.set_shader_parameter("normal_scale", m.normal_scale)
				elif share_n and m.albedo_texture and nmap.has(m.albedo_texture):
					q.set_shader_parameter("use_normal", true); q.set_shader_parameter("normal_tex", nmap[m.albedo_texture][0])
					q.set_shader_parameter("normal_scale", nmap[m.albedo_texture][1])
				elif share_n and m.albedo_texture:
					for pat in gen_n:
						if nm.match(pat):
							q.set_shader_parameter("use_normal", true); q.set_shader_parameter("normal_tex", gen_n[pat]); q.set_shader_parameter("normal_scale", 1.0); break
				q.set_shader_parameter("cf_normal", args.get("切线", "1") == "1")   # --切线=0：法线贴图回到 Godot 默认切线（旧做法，对比用）
				if ao_tex:
					q.set_shader_parameter("use_ao", true); q.set_shader_parameter("ao_tex", ao_tex)
				q.set_shader_parameter("detail_tex", det)
				q.set_shader_parameter("dust", dust); q.set_shader_parameter("dust_col", Vector3(dc[0], dc[1], dc[2]))
				var G: Dictionary = groups.get(gname, {})
				if G.has("反照率"):
					var a: Array = G["反照率"]; q.set_shader_parameter("albedo_col", Color(a[0], a[1], a[2]).linear_to_srgb())
				for kv in KV:
					if dpar.has(kv[0]): q.set_shader_parameter(kv[1], float(dpar[kv[0]]))
					if G.has(kv[0]): q.set_shader_parameter(kv[1], float(G[kv[0]]))
				q.set_shader_parameter("dust_k", float(G.get("挂尘", dpar.get("挂尘", 1.0)))*nk)
				if G.has("丝向"): q.set_shader_parameter("aniso_mode", {"直": 0, "圆": 1, "径": 2}.get(G["丝向"], 0))
				if args.get("各向异性", "1") == "0": q.set_shader_parameter("aniso", 0.0)
				if args.get("清漆", "1") == "0": q.set_shader_parameter("clearcoat", 0.0)
				if G.has("轮半径"): q.set_shader_parameter("wheel_r", float(G["轮半径"]))
				if G.get("车AO", 1) == 0: q.set_shader_parameter("use_ao", false)      # 这组的 AO 图集不可信（车轮）
				if lit >= 0:
					q.set_shader_parameter("albedo_col", HL_COL[lit % HL_COL.size()]); q.set_shader_parameter("albedo_tex", null)
					q.set_shader_parameter("metallic", 0.0); q.set_shader_parameter("dust", 0.0)
				if args.has("材质调试"): q.set_shader_parameter("dbg", {"ao": 1, "尘": 2, "远": 3, "半径": 4, "法线": 5, "镜面": 6}.get(args["材质调试"], 0))
				made[key] = q; rover_mats.append(q)
			mi.mesh.surface_set_material(s, made[key])
			count[gname] = count.get(gname, 0) + 1
	print("[实景] 车材质：%d 个着色器材质，各组面数 %s" % [made.size(), str(count)])
	var cr: String = args.get("车反射", "0")                              # §17.1：0（默认）/ ssr / 探针 / 探针+ssr；探针每走 2 m 重画一帧要多约 5 ms（开车时顿一下），收益只在特写里看得出，先默认关
	if cr.contains("探针"):
		var rf: Node = load("res://车反射.gd").new(); rf.name = "车反射"; add_child(rf); rf.setup(self)


func set_rover_dust(x: float) -> void:                                # 运行时改尘量（模块用）
	for q in rover_mats: q.set_shader_parameter("dust", x)
	if rover_dust: rover_dust.set_shader_parameter("dust", x)


# 机械臂：五个关节（肩偏航、肩俯仰、肘、腕、转塔），角度（°）是在 NASA 模型姿态上加的。模型的臂是一串节点：
# arm_003（肩偏航，绕模型竖轴）→ arm_002（肩俯仰）→ arm（肘）→ arm_004（腕），这三个绕各自的局部 z 轴（= 模型横轴）→ turret_obj（转塔，绕自己的局部 y 轴）。
const ARM_NODES := ["arm_003", "arm_002", "arm", "arm_004", "turret_obj"]
var arm_nodes: Array[Node3D] = []
var arm_base: Array[Basis] = []
var arm_sph_local := Vector3()                                       # G5 遮挡球「臂端」在转塔局部坐标里的位置（地平线GI.gd set_rover 用）


func set_arm(model: Node3D, q: Array) -> void:
	"""绝对设置（同一组 q 调几次结果一样）。q = [肩偏航, 肩俯仰, 肘, 腕, 转塔]（°，在模型姿态上加；转塔可省）。"""
	if arm_nodes.is_empty():
		for nm in ARM_NODES:
			var n := model.find_child(nm, true, false) as Node3D
			if n == null: push_warning("机械臂节点没找到：" + nm); arm_nodes.clear(); return
			arm_nodes.append(n); arm_base.append(n.basis)
		arm_sph_local = rel(arm_nodes[4], model).affine_inverse()*Vector3(0.28, 1.88, 1.98)
	arm_nodes[0].basis = Basis(Vector3.UP, deg_to_rad(q[0]))*arm_base[0]
	for k in [1, 2, 3]: arm_nodes[k].basis = arm_base[k]*Basis(Vector3(0, 0, 1), deg_to_rad(q[k]))
	arm_nodes[4].basis = arm_base[4]*Basis(Vector3.UP, deg_to_rad(q[4] if q.size() > 4 else 0.0))
	if hz: hz.set_rover(self)


func stow_arm(model: Node3D, az: float, sh: float, el: float, wr: float) -> void:   # 老接口（--收臂、视频）
	set_arm(model, [az, sh, el, wr, 0.0])


func rel(n: Node3D, top: Node3D) -> Transform3D:
	var t := Transform3D()
	while n != top:
		t = n.transform*t
		n = n.get_parent() as Node3D
	return t


# 摇臂-转向架（rover_rig.json 的 joints，--摇臂=0 回到老做法：悬架整块不动、每个轮子上下补偿）。
# rb：rocker / bogie / link = [左, 右] 节点，diff = 差速杆节点；hub / bog / lever / bar = 各侧关节静止时的模型坐标，D = 差速杆轴。
# pose_rover 的 rv 带 "rk"（左摇臂角，右侧 = −左：差速杆让两边反着转）、"bg"（[左, 右] 转向架角，相对摇臂）时摆这些关节。
var rb := {}


func rig_rover(model: Node3D) -> void:
	"""把模型里整块的 Wheels_objs 拆成六个轮子；suspension 按连通块分给转向叉、摇臂、转向架、差速杆、连杆，
	各挂在以关节为原点的节点上：模型 → 摇臂（绕模型 x）→ 转向架（绕 x）→ 转向节点（角轮绕竖轴）→ 轮（绕轮轴）；
	差速杆绕竖轴，连杆每帧按两端摆。rover_rig.json 由 工具/量车轮.gd 量轮子，joints 由连通块的顶点包围盒量出（模型坐标 +y 上、+z 前、+x 左）。"""
	var R: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(D + "rover_rig.json"))
	var C: Array[Vector3] = []; var corner: Array[bool] = []
	for w in R["wheels"]: C.append(Vector3(w["c"][0], w["c"][1], w["c"][2])); corner.append(w["corner"])
	var Jt: Dictionary = R.get("joints", {})
	var use_rb: bool = not Jt.is_empty() and args.get("摇臂", "1") == "1"
	var v3 := func(a: Array, sg: float) -> Vector3: return Vector3(sg*float(a[0]), float(a[1]), float(a[2]))
	if use_rb:
		rb = {"rocker": [], "bogie": [], "link": [], "hub": [], "bog": [], "lever": [], "bar": []}
		for sg in [1.0, -1.0]:
			var side := "左" if sg > 0.0 else "右"
			var hub: Vector3 = v3.call(Jt["hub"], sg); var bog: Vector3 = v3.call(Jt["bogie"], sg); var lev: Vector3 = v3.call(Jt["link_lever"], sg)
			var rk := Node3D.new(); rk.name = "摇臂_" + side; model.add_child(rk); rk.position = hub
			var bg := Node3D.new(); bg.name = "转向架_" + side; rk.add_child(bg); bg.position = bog - hub
			var lk := Node3D.new(); lk.name = "连杆_" + side; model.add_child(lk); lk.position = lev
			rb["rocker"].append(rk); rb["bogie"].append(bg); rb["link"].append(lk)
			rb["hub"].append(hub); rb["bog"].append(bog); rb["lever"].append(lev); rb["bar"].append(v3.call(Jt["link_bar"], sg))
		var df := Node3D.new(); df.name = "差速杆"; model.add_child(df); df.position = v3.call(Jt["diff"], 1.0)
		rb["diff"] = df; rb["D"] = df.position; rb["C"] = C
	for k in 6:
		var par: Node3D = model; var base := Vector3.ZERO
		if use_rb:
			var si := 0 if C[k].x > 0.0 else 1
			if C[k].z > 0.5: par = rb["rocker"][si]; base = rb["hub"][si]               # 前角轮挂摇臂
			else: par = rb["bogie"][si]; base = rb["bog"][si]                          # 中轮、后角轮挂转向架
		var st := Node3D.new(); st.name = "转向_%d" % k; par.add_child(st); st.position = C[k] - base
		var sp := Node3D.new(); sp.name = "轮_%d" % k; st.add_child(sp)
		steer_nodes.append(st); spin_nodes.append(sp); steer_base.append(st.transform)
	var wm := model.find_child("Wheels_objs", true, false) as MeshInstance3D
	var nearest := func(c: Vector3) -> int:
		var best := 0; var bd := 1e9
		for k in 6:
			var d := Vector2(c.x - C[k].x, c.z - C[k].z).length()
			if d < bd: bd = d; best = k
		return best
	split_mesh(wm, model, nearest, C, spin_nodes)
	var sm := model.find_child("suspension", true, false) as MeshInstance3D
	var lab := sus_labels(sm, model, C, corner, use_rb)
	var parents: Array[Node3D] = steer_nodes.duplicate(); var origins: Array[Vector3] = C.duplicate()
	if use_rb:                                                       # 部件号：0–5 转向叉（只有角轮），6/7 摇臂，8/9 转向架，10 差速杆，11/12 连杆
		parents.append_array([rb["rocker"][0], rb["rocker"][1], rb["bogie"][0], rb["bogie"][1], rb["diff"], rb["link"][0], rb["link"][1]])
		origins.append_array([rb["hub"][0], rb["hub"][1], rb["bog"][0], rb["bog"][1], rb["D"], rb["lever"][0], rb["lever"][1]])
	split_mesh(sm, model, func(c: Vector3) -> int: return lab.get(c, -1), origins, parents)
	print("[实景] 毅力号拆出六个轮子、四个转向叉%s" % ("，摇臂、转向架、差速杆、连杆" if use_rb else ""))


func rb_fk(a: float, bl: float, br: float) -> Array[Vector3]:
	"""摇臂角 a（左；右 = −a）、转向架角 bl / br → 六个轮心（模型坐标）。和 rig_rover 的节点层级一致：绕模型 x 轴转。"""
	var out: Array[Vector3] = []
	var C: Array[Vector3] = rb["C"]
	for k in 6:
		var si := 0 if C[k].x > 0.0 else 1
		var ra := Basis(Vector3.RIGHT, a if si == 0 else -a)
		var hub: Vector3 = rb["hub"][si]
		if C[k].z > 0.5: out.append(hub + ra*(C[k] - hub))
		else:
			var bog: Vector3 = rb["bog"][si]
			out.append(hub + ra*(bog - hub) + (ra*Basis(Vector3.RIGHT, bl if si == 0 else br))*(C[k] - bog))
	return out


func sus_labels(mi: MeshInstance3D, model: Node3D, C: Array[Vector3], corner: Array[bool], full: bool) -> Dictionary:
	"""suspension 网格按共用顶点位置连成块，按块分部件（部件号见 rig_rover）；返回 {三角形重心（模型坐标，和 split_mesh 算法相同）: 部件号}。
	转向叉：整块在轮心以上 0.41 m 以内、离转向轴（过轮心的竖线）0.37 m 以内（上面的电机外壳、夹摇臂管子的卡箍不转）。
	full = false（没有 joints）时只挑转向叉。分法和 /tmp/rig_vis.py 的 Blender 上色图一致（2026-10-07 看过）。"""
	var M := rel(mi, model); var keyid := {}; var parent := PackedInt32Array(); var tris := []
	for s in mi.mesh.get_surface_count():
		var arr: Array = mi.mesh.surface_get_arrays(s)
		var V: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]; var I: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		if I.is_empty():
			I = PackedInt32Array(); I.resize(V.size())
			for i in V.size(): I[i] = i
		for t in range(0, I.size(), 3):
			var c := M*((V[I[t]] + V[I[t + 1]] + V[I[t + 2]])/3.0)
			if not full:
				var near := false
				for k in 6: if corner[k] and Vector2(c.x - C[k].x, c.z - C[k].z).length() < 0.5 and c.y < C[k].y + 0.8: near = true
				if not near: continue
			var ids := PackedInt32Array()
			for q in 3:
				var key := (M*V[I[t + q]]).snappedf(1e-4)
				if not keyid.has(key): keyid[key] = parent.size(); parent.append(parent.size())
				ids.append(keyid[key])
			tris.append([ids, c])
	var root := func(a: int) -> int:
		while parent[a] != a:
			parent[a] = parent[parent[a]]; a = parent[a]
		return a
	for t in tris:
		var a: int = root.call(t[0][0])
		for q in [1, 2]:
			var b: int = root.call(t[0][q])
			if a != b: parent[b] = a; a = root.call(a)
	var isl := {}                                                      # 块 → [面数, 重心和, 包围盒低, 高, 每个轮子的最远水平距离]
	for t in tris:
		var r: int = root.call(t[0][0]); var c: Vector3 = t[1]
		if not isl.has(r): isl[r] = [0, Vector3(), Vector3(INF, INF, INF), Vector3(-INF, -INF, -INF), [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]]
		var e: Array = isl[r]; e[0] += 1; e[1] += c; e[2] = (e[2] as Vector3).min(c); e[3] = (e[3] as Vector3).max(c)
		for k in 6: e[4][k] = maxf(e[4][k], Vector2(c.x - C[k].x, c.z - C[k].z).length())
	var pick := {}; var cnt := {}
	for r in isl:
		var e: Array = isl[r]; var lo: Vector3 = e[2]; var hi: Vector3 = e[3]; var c: Vector3 = e[1]/e[0]
		var ax := absf(c.x); var si := 0 if c.x > 0.0 else 1; var lbl := -1
		if full and lo.x < -0.3 and hi.x > 0.3: lbl = 10                                   # 差速杆主体（横跨两边）
		else:
			for k in 6:
				if corner[k] and hi.y <= C[k].y + 0.41 and e[4][k] <= 0.37: lbl = k; break   # 转向叉
			if lbl < 0 and full:
				if ax < 0.45 and lo.y > 1.0: lbl = 10
				elif ax >= 0.58 and ax <= 0.68 and lo.y > 1.08 and hi.z - lo.z > 0.2: lbl = 11 + si   # 连杆（甲板高度，前后走向）
				elif ax >= 0.38 and ax <= 0.68 and lo.y > 1.1 and c.z >= -0.2 and c.z <= -0.08: lbl = 10   # 差速杆两端的接头
				elif ax >= 0.86 and hi.z < 0.0: lbl = 8 + si                                # 转向架：转向架轴外侧、车身后半
				elif c.z < -1.0: lbl = 8 + si                                               # 后角轮的电机外壳、卡箍
				elif ax >= 0.45: lbl = 6 + si                                               # 其余都是摇臂（含前角轮外壳、摇臂轴、转向架轴的叉耳）
		if lbl >= 0: pick[r] = lbl; cnt[lbl] = cnt.get(lbl, 0) + 1
	var out := {}
	for t in tris:
		var r: int = root.call(t[0][0])
		if pick.has(r): out[t[1]] = pick[r]
	print("[实景] 悬架分块：%s（部件号：0–5 转向叉，6/7 摇臂，8/9 转向架，10 差速杆，11/12 连杆）" % str(cnt))
	return out


func split_mesh(mi: MeshInstance3D, model: Node3D, pick: Callable, C: Array[Vector3], parents: Array[Node3D]) -> void:
	"""按三角形重心（模型坐标）分组：pick 返回部件号，−1 留在原网格。分出去的部分顶点换成以 C[k]（该部件节点的静止位置）为原点的模型坐标，挂到 parents[k] 下。"""
	var M := rel(mi, model); var keep := ArrayMesh.new(); var parts: Array[ArrayMesh] = []
	var np := parents.size()
	for k in np: parts.append(ArrayMesh.new())
	for s in mi.mesh.get_surface_count():
		var arr: Array = mi.mesh.surface_get_arrays(s); var mat := mi.mesh.surface_get_material(s)
		var V: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]; var I: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		if I.is_empty():
			I = PackedInt32Array(); I.resize(V.size())
			for i in V.size(): I[i] = i
		var buckets := []
		for k in np + 1: buckets.append([])
		for t in range(0, I.size(), 3):
			var k: int = pick.call(M*((V[I[t]] + V[I[t + 1]] + V[I[t + 2]])/3.0))
			buckets[k + 1].append_array([I[t], I[t + 1], I[t + 2]])
		for k in range(-1, np):
			var b: Array = buckets[k + 1]
			if b.is_empty(): continue
			var a2 := arr.duplicate(); a2[Mesh.ARRAY_INDEX] = PackedInt32Array(b)
			if k >= 0:                                                 # 顶点、法线、切线换到「以轮心为原点的模型坐标」
				var V2 := PackedVector3Array(); V2.resize(V.size())
				for i in V.size(): V2[i] = M*V[i] - C[k]
				a2[Mesh.ARRAY_VERTEX] = V2
				if a2[Mesh.ARRAY_NORMAL] != null:
					var N: PackedVector3Array = a2[Mesh.ARRAY_NORMAL]; var N2 := PackedVector3Array(); N2.resize(N.size())
					for i in N.size(): N2[i] = (M.basis*N[i]).normalized()
					a2[Mesh.ARRAY_NORMAL] = N2
				if a2[Mesh.ARRAY_TANGENT] != null:
					var Tg: PackedFloat32Array = a2[Mesh.ARRAY_TANGENT]; var T2 := Tg.duplicate()
					for i in range(0, Tg.size(), 4):
						var v := (M.basis*Vector3(Tg[i], Tg[i + 1], Tg[i + 2])).normalized(); T2[i] = v.x; T2[i + 1] = v.y; T2[i + 2] = v.z
					a2[Mesh.ARRAY_TANGENT] = T2
			var dst: ArrayMesh = keep if k < 0 else parts[k]
			dst.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a2); dst.surface_set_material(dst.get_surface_count() - 1, mat)
	mi.mesh = keep
	for k in np:
		if parts[k].get_surface_count() == 0: continue
		var n := MeshInstance3D.new(); n.mesh = parts[k]; parents[k].add_child(n)


func pose_rover(rv: Dictionary) -> void:
	"""一帧的车：车身位姿（b 的三行＝模型 x、y、z 轴在世界里的方向，o＝模型原点＝轮底中心）、六轮转角、角轮转向、上下补偿。"""
	var b: Array = rv["b"]; var o: Array = rv["o"]
	rover_root.transform = Transform3D(Basis(Vector3(b[0][0], b[0][1], b[0][2]), Vector3(b[1][0], b[1][1], b[1][2]), Vector3(b[2][0], b[2][1], b[2][2])), Vector3(o[0], o[1], o[2]))
	if rv.has("t"): ground_mat.set_shader_parameter("track_time", rv["t"])
	if steer_nodes.is_empty():
		if hz: hz.set_rover(self)
		return
	for k in 6:
		steer_nodes[k].transform = steer_base[k].translated_local(Vector3(0, rv["dy"][k], 0))*Transform3D(Basis(Vector3.UP, rv["steer"][k]))
		spin_nodes[k].transform = Transform3D(Basis(Vector3.RIGHT, rv["spin"][k]))
	if not rb.is_empty():
		var a: float = rv.get("rk", 0.0); var bgv: Array = rv.get("bg", [0.0, 0.0])
		var tops: Array[Vector3] = []
		for si in 2:
			var ra := Basis(Vector3.RIGHT, a if si == 0 else -a)
			(rb["rocker"][si] as Node3D).basis = ra; (rb["bogie"][si] as Node3D).basis = Basis(Vector3.RIGHT, float(bgv[si]))
			var hub: Vector3 = rb["hub"][si]; tops.append(hub + ra*((rb["lever"][si] as Vector3) - hub))
		# 差速杆绕竖轴转 ψ，让两根连杆长度不变（小角度：杆端前后位移 −x·ψ = 摇臂上杠杆顶的前后位移，两边取平均）
		var psi := 0.0
		for si in 2: psi += -(tops[si].z - (rb["lever"][si] as Vector3).z)/(rb["bar"][si] as Vector3).x*0.5
		var dfb := Basis(Vector3.UP, psi); (rb["diff"] as Node3D).basis = dfb
		for si in 2:                                                   # 连杆：杠杆顶那端跟着摇臂，另一端指向差速杆端
			var Dp: Vector3 = rb["D"]; var bar: Vector3 = Dp + dfb*((rb["bar"][si] as Vector3) - Dp)
			var d0: Vector3 = (rb["bar"][si] as Vector3) - (rb["lever"][si] as Vector3); var d1: Vector3 = bar - tops[si]
			(rb["link"][si] as Node3D).transform = Transform3D(Basis(Quaternion(d0.normalized(), d1.normalized())), tops[si])
	if hz: hz.set_rover(self)


# ———————————————————— 相机与渲染
func use_cam(c: Dictionary, cam: Camera3D) -> void:
	var p: Array = c["pos"]; var f: Array = c["fwd"]; var u: Array = c["up"]
	var fw := Vector3(f[0], f[1], f[2]).normalized(); var up := Vector3(u[0], u[1], u[2]).normalized()
	var r := fw.cross(up).normalized()
	cam.transform = Transform3D(Basis(r, r.cross(fw), -fw), Vector3(p[0], p[1], p[2]))
	cam.keep_aspect = Camera3D.KEEP_WIDTH; cam.fov = c["hfov"]
	cam.near = 0.02; cam.far = 200000.0
	ground_mat.set_shader_parameter("pixel_angle", c["pixel_angle"])


func rt_shots() -> void:
	"""诊断：--实时截图=<目录>（--等帧=150）：窗口里的真实时画面（TAA、材质缓存、后处理都在；窗口大小 = --resolution）。
	每台相机（含 --远机位 / --俯机位 / --相机）等 N 帧后存窗口画面。颗粒图案固定（可比）。"""
	var out := String(args["实时截图"]); DirAccess.make_dir_recursive_absolute(out)
	var vp := get_viewport()
	if post: post.t_fixed = 1.0
	if args.has("贴图高"):                                               # 诊断（贴图随视角变化）：--贴图高=E,N[;E,N…]：打印每点周围 ±1.5 m、0.75 m 格的地面高（拟合局部平面、矫正斜视图用）
		for pq in String(args["贴图高"]).split(";"):
			var q: PackedStringArray = pq.split(","); var E := float(q[0]); var Nn := float(q[1]); var row := []
			for j in 5:
				for i in 5: row.append("%.4f" % (lod.h_cpu(E + (i - 2)*0.75, -(Nn + (j - 2)*0.75), 0) if lod else 0.0))
			print("[贴图高] %s,%s " % [q[0], q[1]] + " ".join(row))
	for c in cams:
		use_cam(c, fly)
		for k in int(args.get("等帧", "150")): await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var path := out.path_join("%s_%s.png" % [c["name"], ltst.replace(":", "")])
		vp.get_texture().get_image().save_png(path)
		print("[实景] 实时截图 %s → %s" % [c["name"], path])
	print("[实景] 全部渲染完")
	await quit_clean()


func rt_record() -> void:
	"""诊断：--实时录=<目录> --录路径=远足|地面|低日|转头 --录帧=N（默认 120）：按固定步长 1/60 s 驱动相机，实时画面逐帧存 PNG
	（量帧间稳定性、看动起来闪不闪）。先等 150 帧让 TAA / SDFGI / 缓存稳定。路径同 bench()。"""
	var out := String(args["实时录"]); DirAccess.make_dir_recursive_absolute(out)
	var vp := get_viewport(); var sc: String = args.get("录路径", "远足"); var n := int(args.get("录帧", "120"))
	var c0 := fly.global_transform
	var fwd := -c0.basis.z; fwd.y = 0; fwd = fwd.normalized()
	for k in 150: await get_tree().process_frame
	for i in n:
		var t := float(i)/60.0
		if post: post.t_fixed = t
		match sc:
			"地面": fly.global_transform = Transform3D(c0.basis, c0.origin + fwd*1.5*t)
			"低日":                                                     # 2 m 高、4 m/s 横移（低太阳下近处颗粒、微阴影在动）
				var rr := c0.basis.x; rr.y = 0; rr = rr.normalized()
				var p := c0.origin + rr*4.0*t
				p.y = (lod.h_cpu(p.x, p.z, 0) if lod else 0.0) + 2.0
				fly.global_transform = Transform3D(c0.basis, p)
			"转头": fly.global_transform = Transform3D(c0.basis.rotated(Vector3.UP, deg_to_rad(30.0)*t), c0.origin)
			"升", "俯仰":                                                 # 贴图随视角变化：--录点=E,N（盯住的地面点）。升：从 1.6 m 指数升到 --录高（默认 40 m），正下方俯拍；俯仰：离点 --录R（默认 8 m）的球面上仰角 5° → 89.5°，始终看着那个点
				var q := String(args.get("录点", "4,3")).split(","); var E := float(q[0]); var Nn := float(q[1])
				var g0: float = lod.h_cpu(E, -Nn, 0) if lod else 0.0
				var fr := float(i)/float(maxi(n - 1, 1)); var cp: Vector3; var fw: Vector3; var upv := Vector3(0, 1, 0)
				if sc == "升":
					cp = Vector3(E, g0 + 1.6*pow(float(args.get("录高", "40"))/1.6, fr), -Nn); fw = Vector3(0, -1, 0); upv = Vector3(0, 0, -1)
				else:
					var el := deg_to_rad(lerpf(5.0, 89.5, fr)); var R := float(args.get("录R", "8"))
					cp = Vector3(E, g0, -Nn) + Vector3(-cos(el), 0.0, 0.0)*R + Vector3(0, sin(el), 0)*R   # 从西边看过去（太阳在南偏西，不顶光）
					fw = (Vector3(E, g0, -Nn) - cp).normalized()
					if el > 1.4: upv = Vector3(1, 0, 0)
				use_cam({"pos": [cp.x, cp.y, cp.z], "fwd": [fw.x, fw.y, fw.z], "up": [upv.x, upv.y, upv.z], "hfov": float(args.get("录视场", "60")), "pixel_angle": deg_to_rad(float(args.get("录视场", "60")))/float(vp.size.x)}, fly)
			"升俯":                                                       # 中景材质验收：--录点=E,N 上空，2 m 平视（朝北）→ 指数升到 --录高（默认 30 m）并下俯到 89°（缓入缓出）
				var q := String(args.get("录点", "-150,60")).split(","); var E := float(q[0]); var Nn := float(q[1])
				var fr := float(i)/float(maxi(n - 1, 1)); var sm := fr*fr*(3.0 - 2.0*fr)
				var hh := 2.0*pow(float(args.get("录高", "30"))/2.0, sm); var pit := deg_to_rad(lerpf(2.0, 89.0, sm))
				var cp := Vector3(E, (lod.h_cpu(E, -Nn, 0) if lod else 0.0) + hh, -Nn)
				var fw := Vector3(0, -sin(pit), -cos(pit)); var upv := Vector3(0, cos(pit), -sin(pit))
				use_cam({"pos": [cp.x, cp.y, cp.z], "fwd": [fw.x, fw.y, fw.z], "up": [upv.x, upv.y, upv.z], "hfov": float(args.get("录视场", "60")), "pixel_angle": deg_to_rad(float(args.get("录视场", "60")))/float(vp.size.x)}, fly)
			"沿路":                                                       # 中景材质验收：从 --录点 出发沿一条缓弯的路走 --录长（默认 120 m）米，1.7 m 高、下俯 4°（像车上桅杆的视角）
				var q := String(args.get("录点", "0,0")).split(","); var E := float(q[0]); var Nn := float(q[1])
				var L := float(args.get("录长", "120")); var fr := float(i)/float(maxi(n - 1, 1)); var th := deg_to_rad(float(args.get("录向", "225")))
				var ds := L*fr/200.0
				for kk in 200:
					var sq := ds*float(kk)
					var thk := th + 0.45*sin(sq/35.0)
					E += sin(thk)*ds; Nn += cos(thk)*ds
				var thf := th + 0.45*sin(L*fr/35.0)
				var cp := Vector3(E, (lod.h_cpu(E, -Nn, 0) if lod else 0.0) + 1.7, -Nn)
				var pt := deg_to_rad(4.0); var fw := Vector3(sin(thf)*cos(pt), -sin(pt), -cos(thf)*cos(pt))
				use_cam({"pos": [cp.x, cp.y, cp.z], "fwd": [fw.x, fw.y, fw.z], "up": [0, 1, 0], "hfov": float(args.get("录视场", "60")), "pixel_angle": deg_to_rad(float(args.get("录视场", "60")))/float(vp.size.x)}, fly)
			_:
				var p := Vector3(100, 0, 100).lerp(Vector3(60, 0, 60), clampf(t/10.0, 0.0, 1.0))
				p.y = (lod.h_cpu(p.x, p.z, 0) if lod else 0.0) + 1.6
				fly.global_transform = Transform3D.IDENTITY.translated(p).looking_at(Vector3(0, p.y - 4.0, 0), Vector3.UP)
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		vp.get_texture().get_image().save_png(out.path_join("%05d.png" % i))
	print("[实景] 实时录 %s %d 帧 → %s" % [sc, n, out])
	print("[实景] 全部渲染完")
	await quit_clean()


func render_all(out: String, ss: int) -> void:
	DirAccess.make_dir_recursive_absolute(out)
	for c in cams:
		var is_ref := String(c["name"]).begins_with("对照")
		for g in hide_parts:
			g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY if is_ref else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		var sv := SubViewport.new(); sv.size = Vector2i(c["W"]*ss, c["H"]*ss)
		sv.msaa_3d = Viewport.MSAA_4X; sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		sv.anisotropic_filtering_level = Viewport.ANISOTROPY_16X
		var cam := Camera3D.new(); sv.add_child(cam); add_child(sv)
		use_cam(c, cam); cam.current = true
		if lod: lod.update(cam.position, float(c["pixel_angle"])/ss)
		if mcache: mcache.update(cam.position, true)
		rocks_update(cam.position, float(c["pixel_angle"])/ss, true)
		var t0 := Time.get_ticks_msec()
		for k in int(args.get("等帧", "60")): await RenderingServer.frame_post_draw
		var img := sv.get_texture().get_image()
		if ss > 1: img.resize(c["W"], c["H"], Image.INTERPOLATE_LANCZOS)
		var path := out.path_join("%s_%s.png" % [c["name"], ltst.replace(":", "")])
		img.save_png(path)
		print("[实景] 渲染 %s → %s（%.1f s）" % [c["name"], path, (Time.get_ticks_msec() - t0)/1000.0])
		sv.queue_free()
		await get_tree().process_frame


func render_video(path_file: String, out: String, ss: int) -> void:
	"""逐帧渲染 65_视频路径.py 写的路径：<出>/<镜头>/%05d.png。每个镜头第一帧多等 90 帧让 SDFGI 收敛，之后每帧等 --每帧 帧（默认 2）。"""
	var P: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path_file))
	for g in hide_parts: g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	var sv := SubViewport.new(); sv.size = Vector2i(int(P["W"])*ss, int(P["H"])*ss)
	sv.msaa_3d = Viewport.MSAA_4X; sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.anisotropic_filtering_level = Viewport.ANISOTROPY_16X
	var cam := Camera3D.new(); sv.add_child(cam); add_child(sv); cam.current = true
	cam.keep_aspect = Camera3D.KEEP_WIDTH; cam.near = 0.02; cam.far = 200000.0
	var per := int(args.get("每帧", "2"))
	for shot in P["shots"]:
		if args.has("只") and not String(args["只"]).split(",").has(shot["name"]): continue
		var dir := out.path_join(shot["name"]); DirAccess.make_dir_recursive_absolute(dir)
		var t0 := Time.get_ticks_msec(); var n: int = shot["frames"].size()
		for i in n:
			var f: Dictionary = shot["frames"][i]
			var fw := Vector3(f["fwd"][0], f["fwd"][1], f["fwd"][2]); var up := Vector3(f["up"][0], f["up"][1], f["up"][2])
			cam.transform = Transform3D(Basis(fw.cross(up).normalized(), up, -fw), Vector3(f["pos"][0], f["pos"][1], f["pos"][2]))
			cam.fov = f["hfov"]
			if lod: lod.update(cam.position, deg_to_rad(f["hfov"])/(float(P["W"])*ss))
			if mcache: mcache.update(cam.position)
			rocks_update(cam.position, deg_to_rad(f["hfov"])/(float(P["W"])*ss), true)
			ground_mat.set_shader_parameter("pixel_angle", deg_to_rad(f["hfov"])/float(P["W"]))
			set_time_f(minutes(f["t"]))
			if f.has("rover"): pose_rover(f["rover"])
			for k in (90 if i == 0 else per): await RenderingServer.frame_post_draw
			var img := sv.get_texture().get_image()
			if ss > 1: img.resize(int(P["W"]), int(P["H"]), Image.INTERPOLATE_LANCZOS)
			img.save_png(dir.path_join("%05d.png" % i))
			if i % 60 == 0: print("[实景] %s %d/%d（%.1f s）" % [shot["name"], i, n, (Time.get_ticks_msec() - t0)/1000.0])
		print("[实景] 镜头 %s 完：%d 帧 %.0f s" % [shot["name"], n, (Time.get_ticks_msec() - t0)/1000.0])
	sv.queue_free()


# ———————————————————— 漫游
var cam_i := 2

func _unhandled_input(ev: InputEvent) -> void:
	if fly == null or has_node("控制"): return
	if ev is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		fly.rotate_y(-ev.relative.x*0.002)
		fly.rotate_object_local(Vector3.RIGHT, -ev.relative.y*0.002)
	elif ev is InputEventKey and ev.pressed:
		match ev.keycode:
			KEY_ESCAPE: Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			KEY_1, KEY_2, KEY_3, KEY_4:
				cam_i = mini(ev.keycode - KEY_1, cams.size() - 1); use_cam(cams[cam_i], fly)
			KEY_T:
				var ks: Array = J["sky"].keys(); ks.sort()
				set_time(ks[(ks.find(ltst) + 1) % ks.size()])
			KEY_F12:
				var p := "user://截图_%d.png" % Time.get_unix_time_from_system()
				get_viewport().get_texture().get_image().save_png(p); print("[实景] 截图 ", ProjectSettings.globalize_path(p))
	elif ev is InputEventMouseButton and ev.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _process(dt: float) -> void:
	if fly == null: return
	if not has_node("控制"): fly_move(dt)
	var cam := get_viewport().get_camera_3d()                          # 地面 LOD、石块分级跟着当前相机（控制模块可以换相机；fov 按水平算）
	if cam == null: return
	var pa: float = deg_to_rad(cam.fov)/get_viewport().size.x
	poll_sky()
	if hz: hz.poll()
	ground_mat.set_shader_parameter("pixel_angle", pa)
	if lod: lod.update(cam.global_position, pa)
	if mcache: mcache.update(cam.global_position)
	rocks_update(cam.global_position, pa, false)


func fly_move(dt: float) -> void:
	var v := Vector3(Input.get_axis("ui_left", "ui_right"), 0, Input.get_axis("ui_up", "ui_down"))
	if Input.is_key_pressed(KEY_A): v.x -= 1
	if Input.is_key_pressed(KEY_D): v.x += 1
	if Input.is_key_pressed(KEY_W): v.z -= 1
	if Input.is_key_pressed(KEY_S): v.z += 1
	if Input.is_key_pressed(KEY_E): v.y += 1
	if Input.is_key_pressed(KEY_Q): v.y -= 1
	var sp := 15.0 if Input.is_key_pressed(KEY_SHIFT) else 1.5
	fly.translate(v*sp*dt)
