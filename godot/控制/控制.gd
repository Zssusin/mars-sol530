# 控制：实时开毅力号 + 相机模式。实景.gd 实时模式下自动加载成子节点「控制」，有它时 实景.gd 的自由飞行让出输入。
#   运动学照 scripts/Godot/66_车辆动画.py（离线版）搬到每帧：
#     行驶：油门 + 转向 → 阿克曼弧线，转动中心在中轮轴线上（中轮不转向、不打滑）；原地转：角轮转到切线方向、中轮打滑（同真车）。
#           换行驶方式先停车、再打方向（角轮离目标 > 8° 不走）；转向、加减速都有速率限制。
#     车身：六个轮底的接地高（地面 h_cpu + 石块穹顶；轮子当半径 r 的圆柱，沿轮向取 5 点）最小二乘平面 → 俯仰、横滚；
#           平面按走过的距离平滑（3 cm），各轮剩下的高差（限 ±12 cm）给该轮上下补偿，轮子陷 1 cm。转角＝轮心沿轮子朝向走过的距离 / r。
#   相机：自由（同 实景.gd 漫游）、跟车（绕车、滚轮远近、软跟随、不入地）、桅杆（Navcam，随车身俯仰横滚、鼠标转头）、俯视（北朝上）。
# 自动驾驶接口（玩法 B）：自动驾驶(驾) / 停自驾() / signal 自驾结束；运动学抽成静态 运动步()（手动、预演、自驾共用），见 docs/玩法B.md §6–7。
# 给界面：状态() → 字典、signal 模式改变。车辙：控制/车辙.gd（--车辙=0 关）。自测：控制/测试.sh（--控制测试，见 控制/自测.gd）。
extends Node

signal 模式改变(模式: String)

const MODES := ["自由", "跟车", "桅杆", "俯视"]
const V_REAL := 0.042                     # 真车直行 m/s
const W_REAL := 0.0244                    # 真车原地转 rad/s（1.4°/s；66 里按 10.7 倍显示 15°/s）
const RATES := [1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0]
const K_MAX := 0.4                        # 最大曲率 1/m（中轴转弯半径 2.5 m，内侧前轮约 39°）
const K_RATE := 0.5                       # 曲率变化速率 1/m/s（打满约 0.8 s）
const STEER_RATE := 1.6                   # 角轮转向 rad/s（约 90°/s）
const ALIGN := 0.14                       # 角轮离目标超过 8°：先停车打方向
const T_ACC := 0.6                        # 起步到全速 / 刹停 s
const SINK := 0.01
const DY_MAX := 0.12
const ROCK_MIN := 0.1                     # 直径 ≥ 10 cm 的石块才垫轮子
const CELL := 1.0                         # 石块空间哈希格 m
const TS := [-0.2, -0.1, 0.0, 0.1, 0.2]   # 轮底沿轮向的取样点 m
const HALF_W := 0.168                     # 轮宽一半

var P: Node3D                             # 实景.gd
var model: Node3D
var W: Array[Vector3] = []                # 六个轮心（模型坐标：+x 左、+y 上、+z 前）
var corner: Array[bool] = []
var r := 0.263
var G: Array[Vector3] = []                # 平面拟合：(h0, a, b) = Σ h_i·G_i
var ZC := -0.09                           # 阿克曼转动中心所在的横线（中轮轴）
var ZP := -0.035                          # 原地转中心（角轮中间）
var park: Transform3D                     # 停车位姿（scene.json）
var mast_local := Vector3()               # 桅杆头（模型坐标）
var head_parts: Array[GeometryInstance3D] = []

# 车的状态
var p := Vector3()                        # 车体原点水平位置（y 不用）
var psi := 0.0                            # 航向角：前 f = (cos ψ, 0, sin ψ)，左 l = (sin ψ, 0, −cos ψ)，左转 ψ 减小（同 66）
var kappa := 0.0                          # 曲率，左正
var pivot := false                        # 当前行驶方式：原地转
var v := 0.0                              # 中轴中点速度 m/s（含倍率）
var w := 0.0                              # 原地转角速度 rad/s（含倍率，左正）
var steer := PackedFloat32Array([0, 0, 0, 0, 0, 0])
var spin := PackedFloat32Array([0, 0, 0, 0, 0, 0])
var dy := PackedFloat32Array([0, 0, 0, 0, 0, 0])
var hc := PackedFloat32Array([0, 0, 0, 0, 0, 0])     # 各轮接地高
var last_c: Array[Vector3] = []
var body := Transform3D()                 # 当前车身（模型原点）
var fit_s := Vector3(); var fit_p := Vector3(); var fit_psi := 0.0; var fit_ok := false   # 平面按走过的距离平滑（压上石块边不顿）
const FIT_L := 0.03                       # 平滑长度 m
var odo := 0.0
var thr_in := 0.0                         # 当前油门输入 −1…1
var rate_i := 3                           # 默认 10 倍
# 机械臂（L 切换臂模式）：五个关节，↑/↓ 选关节、←/→ 转（不是自由相机时 W/S/A/D 也行，Shift 快 3 倍），O 展开（模型姿态）、I 收起（与天气 B/G、界面 H 错开）。
# 开车时臂没收好就先自动收臂、收好才走（同真车：行驶时臂必须收起）。角度是在 NASA 模型姿态上加的（°），见 实景.gd set_arm。
const ARM_J := ["肩·偏航", "肩·俯仰", "肘", "腕", "转塔"]
const ARM_LIM := [[-100.0, 100.0], [-50.0, 75.0], [-160.0, 160.0], [-120.0, 120.0], [-180.0, 180.0]]
const ARM_STOW := [-90.0, 0.0, 90.0, -90.0, 0.0]
const ARM_RATE := 20.0                     # °/s
var arm_q := [0.0, 0.0, 0.0, 0.0, 0.0]; var arm_t := [0.0, 0.0, 0.0, 0.0, 0.0]
var arm_mode := false; var arm_sel := 0
var 自动 := {}                            # 自测用：{"油": ±1, "转": ±1, "原地": ±1} 代替键盘
var 几何 := {}                            # {W, corner, ZC, ZP, G, r}：运动步()、玩法 B 的预演用（_ready 里填）

# 石块：每块 5 个数（x、z、半径、底高、高）+ 1 m 格的空间哈希。固定石块 + 车周围的实时撒石（撒石取代固定统计表后，
# 只用固定表的话撒出来的石块都没有碰撞）
var rk := PackedFloat32Array()
var grid := {}
var rk_fixed := []; var grid_fixed := {}
var rk_ab: Array[AABB] = []                # 每种石块网格的包围盒
const SC_R := 40.0                         # 取车周围 ±40 m 的撒石
const SC_MOVE := 15.0                      # 车走出 15 m 就重取（后台）
var sc_ctr := Vector3(INF, 0, INF); var sc_task := -1; var sc_res := []

# 相机
var mode := ""
var cam: Camera3D
var c_yaw := 0.0; var yaw_off := 0.0; var c_pitch := 0.32; var c_dist := 9.0
var c_pos := Vector3(); var c_tgt := Vector3(); var c_init := false
var m_pan := 0.0; var m_tilt := -0.3; var m_fov := 80.0
var top_h := 25.0
var preset_i := 2
var track: Node = null                    # 车辙.gd
var cpu_ms := 0.0                         # 本节点 _process 用时


func _ready() -> void:
	P = get_parent()
	model = P.rover_root.get_child(0)
	park = P.rover_root.transform
	var R: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(P.D + "rover_rig.json"))
	for wh in R["wheels"]: W.append(Vector3(wh["c"][0], wh["c"][1], wh["c"][2])); corner.append(wh["corner"])
	r = 0.0
	for wh in R["wheels"]: r += float(wh["r"])/6.0
	ZC = W[1].z; var zs := 0.0
	for i in 6: if corner[i]: zs += W[i].z/4.0
	ZP = zs
	var A := Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)          # UᵀU（U 的行 = (1, z, x)）
	for i in 6:
		var u := Vector3(1, W[i].z, W[i].x)
		A.x += u*u.x; A.y += u*u.y; A.z += u*u.z
	var Ai := A.inverse()
	for i in 6: G.append(Ai*Vector3(1, W[i].z, W[i].x))
	几何 = {"W": W, "corner": corner, "ZC": ZC, "ZP": ZP, "G": G, "r": r}
	var ms: Array = P.J["rover"]["mast"]
	mast_local = park.affine_inverse()*Vector3(ms[0], ms[1], ms[2])
	for g in model.find_children("*", "GeometryInstance3D", true, false):  # 桅杆头附近的小件：桅杆视角只投影
		var gi := g as GeometryInstance3D
		var ab: AABB = P.rel(gi, model)*gi.get_aabb()
		if ab.size.length() < 1.2 and ab.grow(0.05).has_point(mast_local): head_parts.append(gi)
	var f0 := park.basis.z; psi = atan2(f0.z, f0.x); p = Vector3(park.origin.x, 0, park.origin.z)
	build_rocks()
	setup_input()
	cam = Camera3D.new(); cam.name = "相机"; cam.keep_aspect = Camera3D.KEEP_WIDTH
	cam.near = 0.02; cam.far = 200000.0; add_child(cam)
	if P.args.has("收臂"):
		var q := String(P.args["收臂"]).split(",")
		for k in 4: arm_q[k] = float(q[k]); arm_t[k] = arm_q[k]
	pose()
	set_mode(String(P.args.get("相机模式", "跟车")))
	if P.args.get("车辙", "1") == "1" and ResourceLoader.exists("res://控制/车辙.gd"):
		track = load("res://控制/车辙.gd").new(); track.name = "车辙"; add_child(track)
	if P.args.has("控制测试"):
		var t: Node = load("res://控制/自测.gd").new(); t.name = "自测"; add_child(t)
	print("[控制] 轮半径 %.3f，石块 %d 块（D ≥ %.1f m），桅杆头 %s，头部 %d 件" % [r, rk.size()/5, ROCK_MIN, mast_local, head_parts.size()])


# ———————————————————— 输入（运行时注册到 InputMap，不改 project.godot）
const ACTS := {
	"控制_前": [KEY_UP], "控制_后": [KEY_DOWN], "控制_左": [KEY_LEFT], "控制_右": [KEY_RIGHT],
	"控制_原地左": [KEY_Z], "控制_原地右": [KEY_X],
	"控制_W": [KEY_W], "控制_S": [KEY_S], "控制_A": [KEY_A], "控制_D": [KEY_D], "控制_Q": [KEY_Q], "控制_E": [KEY_E],
	"控制_快": [KEY_SHIFT],
	"控制_切换": [KEY_V], "控制_1": [KEY_1], "控制_2": [KEY_2], "控制_3": [KEY_3], "控制_4": [KEY_4],
	"控制_倍率加": [KEY_EQUAL, KEY_KP_ADD], "控制_倍率减": [KEY_MINUS, KEY_KP_SUBTRACT],
	"控制_复位": [KEY_R], "控制_臂": [KEY_L], "控制_展开": [KEY_O], "控制_收起": [KEY_I], "控制_时刻": [KEY_T], "控制_截图": [KEY_F12], "控制_预设": [KEY_P], "控制_放开鼠标": [KEY_ESCAPE],
}

func setup_input() -> void:
	for a in ACTS:
		if InputMap.has_action(a): continue
		InputMap.add_action(a)
		for k in ACTS[a]:
			var e := InputEventKey.new(); e.keycode = k; InputMap.action_add_event(a, e)


func 按键() -> Array:
	return [["W/S  ↑/↓", "前进 / 后退"], ["A/D  ←/→", "左 / 右转向（阿克曼）"], ["Q/E  Z/X", "原地左 / 右转"],
		["- / =", "倍率 ÷ / ×（%s）" % ", ".join(RATES.map(func(x): return "%d×" % x))], ["R", "车回停车位"],
		["L", "机械臂模式（↑↓ 选关节、←→ 转、Shift 快）"], ["O / I", "机械臂展开 / 收起（开车前自动收）"],
		["V", "切换相机"], ["1 2 3 4", "自由 / 跟车 / 桅杆 / 俯视"],
		["鼠标", "跟车：绕车；桅杆：转头；自由：看"], ["滚轮", "跟车：远近；桅杆：视场；俯视：高度"],
		["自由模式", "WASD 走、Q/E 降 / 升、Shift 快；开车只用方向键和 Z/X"],
		["P", "自由相机跳到预设机位"], ["T", "换时刻"], ["F12", "截图"], ["Esc", "放开鼠标（点一下抓回）"]]


func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var d: Vector2 = ev.relative*0.002
		match mode:
			"自由": P.fly.rotate_y(-d.x); P.fly.rotate_object_local(Vector3.RIGHT, -d.y)
			"跟车": yaw_off -= d.x*2.0; c_yaw -= d.x*2.0; c_pitch = clampf(c_pitch + d.y*2.0, -0.1, 1.5)
			"桅杆": m_pan = clampf(m_pan - d.x, -PI, PI); m_tilt = clampf(m_tilt - d.y, -1.4, 1.2)
		return
	if ev is InputEventMouseButton and ev.pressed:
		var z := 0
		if ev.button_index == MOUSE_BUTTON_WHEEL_UP: z = -1
		elif ev.button_index == MOUSE_BUTTON_WHEEL_DOWN: z = 1
		else: Input.mouse_mode = Input.MOUSE_MODE_CAPTURED; return
		match mode:
			"跟车": c_dist = clampf(c_dist*pow(1.12, z), 2.5, 80.0)
			"桅杆": m_fov = clampf(m_fov + 5.0*z, 15.0, 110.0)
			"俯视": top_h = clampf(top_h*pow(1.15, z), 4.0, 400.0)
		return
	if not (ev is InputEventKey and ev.pressed and not ev.echo): return
	if 自驾 != null and (ev.is_action("控制_臂") or ev.is_action("控制_展开") or ev.is_action("控制_收起") or ev.is_action("控制_复位")): return   # 自驾中不收
	if ev.is_action("控制_臂"): arm_mode = not arm_mode; print("[控制] 机械臂模式 ", "开" if arm_mode else "关"); return
	if ev.is_action("控制_展开"): arm_t = [0.0, 0.0, 0.0, 0.0, 0.0]; return
	if ev.is_action("控制_收起"): arm_t = ARM_STOW.duplicate(); return
	if arm_mode and (ev.is_action("控制_前") or (mode != "自由" and ev.is_action("控制_W"))): arm_sel = (arm_sel + 4) % 5; return
	if arm_mode and (ev.is_action("控制_后") or (mode != "自由" and ev.is_action("控制_S"))): arm_sel = (arm_sel + 1) % 5; return
	if ev.is_action("控制_切换"): set_mode(MODES[(MODES.find(mode) + 1) % MODES.size()])
	elif ev.is_action("控制_1"): set_mode("自由")
	elif ev.is_action("控制_2"): set_mode("跟车")
	elif ev.is_action("控制_3"): set_mode("桅杆")
	elif ev.is_action("控制_4"): set_mode("俯视")
	elif ev.is_action("控制_倍率加"): rate_i = mini(rate_i + 1, RATES.size() - 1)
	elif ev.is_action("控制_倍率减"): rate_i = maxi(rate_i - 1, 0)
	elif ev.is_action("控制_复位"): teleport(Vector3(park.origin.x, 0, park.origin.z), atan2(park.basis.z.z, park.basis.z.x))
	elif ev.is_action("控制_放开鼠标"): Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif ev.is_action("控制_时刻"):
		var ks: Array = P.J["sky"].keys(); ks.sort()
		P.set_time(ks[(ks.find(P.ltst) + 1) % ks.size()])
	elif ev.is_action("控制_截图"):
		var path := "user://截图_%d.png" % Time.get_unix_time_from_system()
		get_viewport().get_texture().get_image().save_png(path); print("[控制] 截图 ", ProjectSettings.globalize_path(path))
	elif ev.is_action("控制_预设"):
		set_mode("自由"); preset_i = (preset_i + 1) % P.cams.size(); P.use_cam(P.cams[preset_i], P.fly)


# ———————————————————— 每帧
func _process(dt: float) -> void:
	var t0 := Time.get_ticks_usec()
	dt = minf(dt, 0.1)
	if 自驾 != null:                                                   # 自动驾驶（玩法 B 执行）
		if mode == "自由": fly_move(dt)
		自驾一帧(dt)
		scatter_update(); pose(); update_cam(dt)
		if track: track.stamp(self)
		cpu_ms = (Time.get_ticks_usec() - t0)/1000.0
		return
	var thr := 0.0; var st := 0.0; var pv := 0.0
	if not 自动.is_empty():
		thr = 自动.get("油", 0.0); st = 自动.get("转", 0.0); pv = 自动.get("原地", 0.0)
	else:
		thr = Input.get_axis("控制_后", "控制_前"); st = Input.get_axis("控制_右", "控制_左"); pv = Input.get_axis("控制_原地右", "控制_原地左")
		if mode != "自由":
			thr = clampf(thr + Input.get_axis("控制_S", "控制_W"), -1, 1); st = clampf(st + Input.get_axis("控制_D", "控制_A"), -1, 1)
			pv = clampf(pv + Input.get_axis("控制_E", "控制_Q"), -1, 1)
		else: fly_move(dt)
	var rot := 0.0
	if arm_mode:                                                       # 臂模式：←/→（A/D）转当前关节，不开车
		rot = -Input.get_axis("控制_右", "控制_左")
		if mode != "自由": rot = clampf(rot - Input.get_axis("控制_D", "控制_A"), -1, 1)
		thr = 0.0; st = 0.0; pv = 0.0
	elif (thr != 0.0 or st != 0.0 or pv != 0.0) and not arm_stowed():  # 要开车：先收臂，收好才走
		arm_t = ARM_STOW.duplicate(); thr = 0.0; st = 0.0; pv = 0.0
	arm_update(dt, rot)
	thr_in = thr
	drive(dt, thr, st, pv)
	scatter_update()
	pose()
	update_cam(dt)
	if track: track.stamp(self)
	cpu_ms = (Time.get_ticks_usec() - t0)/1000.0


func fly_move(dt: float) -> void:
	var d := Vector3(Input.get_axis("控制_A", "控制_D"), Input.get_axis("控制_Q", "控制_E"), Input.get_axis("控制_W", "控制_S"))
	P.fly.translate(d*(15.0 if Input.is_action_pressed("控制_快") else 1.5)*dt)


func fl() -> Array:
	return [Vector3(cos(psi), 0, sin(psi)), Vector3(sin(psi), 0, -cos(psi))]


func wheel_target(i: int) -> float:
	"""角轮目标转角（左正）：转动中心 (x_c, z_c) 下轮心速度方向和车头的夹角，限在 ±90°（超过就倒着转）。"""
	return 轮目标(W[i], corner[i], pivot, kappa, ZC, ZP)


static func 轮目标(c: Vector3, 角轮: bool, 原地: bool, k: float, zc: float, zp: float) -> float:
	if not 角轮: return 0.0
	if 原地: return wrap90(atan2(c.z - zp, -c.x))
	return atan2(k*(c.z - zc), 1.0 - k*c.x)


static func wrap90(a: float) -> float:
	if a > PI/2: a -= PI
	if a < -PI/2: a += PI
	return a


func drive(dt: float, thr: float, st: float, pv: float) -> void:
	var s := 运动态()
	运动步(s, 几何, dt, thr, st, pv, RATES[rate_i])
	取运动态(s)


func 运动态() -> Dictionary:
	return {"p": p, "psi": psi, "kappa": kappa, "pivot": pivot, "v": v, "w": w, "steer": steer.duplicate(), "odo": odo}


func 取运动态(s: Dictionary) -> void:
	p = s["p"]; psi = s["psi"]; kappa = s["kappa"]; pivot = s["pivot"]; v = s["v"]; w = s["w"]; steer = s["steer"]; odo = s["odo"]


static func 运动步(s: Dictionary, g: Dictionary, dt: float, thr: float, st: float, pv: float, M: float) -> void:
	"""运动学一步（手动驾驶、玩法 B 的预演和自驾共用一份）：油门 thr、转向 st、原地 pv（−1…1）→ 阿克曼弧 / 原地转。
	s：运动态 {p, psi, kappa, pivot, v, w, steer, odo}，就地改；g：几何 {W, corner, ZC, ZP}（_ready 里填的 几何）。
	M：速度倍率（手动 = 倍率表；自驾按模拟秒走，M = 1）。转向、加减速的速率限制按 dt 走。"""
	var W: Array = g["W"]; var corner: Array = g["corner"]; var zc: float = g["ZC"]; var zp: float = g["ZP"]
	var pivot: bool = s["pivot"]; var v: float = s["v"]; var w: float = s["w"]; var kappa: float = s["kappa"]
	var steer: PackedFloat32Array = s["steer"]; var p: Vector3 = s["p"]; var psi: float = s["psi"]
	var want_pivot := absf(pv) > 0.01
	var still := absf(v) < 1e-4 and absf(w) < 1e-5
	if want_pivot != pivot and still: pivot = want_pivot                 # 停稳才换行驶方式
	kappa = move_toward(kappa, 0.0 if pivot else st*K_MAX, K_RATE*dt)
	var err := 0.0
	for i in 6:
		var tg := 轮目标(W[i], corner[i], pivot, kappa, zc, zp)
		steer[i] = move_toward(steer[i], tg, STEER_RATE*dt)
		err = maxf(err, absf(tg - steer[i]))
	var vt := 0.0; var wt := 0.0
	if err < ALIGN and want_pivot == pivot:
		if pivot: wt = pv*W_REAL*M
		else: vt = thr*V_REAL*M
	v = move_toward(v, vt, V_REAL*M/T_ACC*dt); w = move_toward(w, wt, W_REAL*M/T_ACC*dt)

	var f := Vector3(cos(psi), 0, sin(psi)); var l := Vector3(sin(psi), 0, -cos(psi))
	var p0 := p; var th := 0.0; var C := Vector3()
	if pivot: th = w*dt; C = p + f*zp
	elif absf(kappa) > 1e-5: th = v*kappa*dt; C = p + f*zc + l/kappa
	else: p += f*v*dt
	if th != 0.0:                                                        # 绕转动中心转 th（左转＝绕 +y 正转，ψ 减小）
		var d := p - C
		p = C + Vector3(d.x*cos(th) + d.z*sin(th), 0, -d.x*sin(th) + d.z*cos(th)); psi -= th
	s["odo"] = float(s["odo"]) + (p - p0).length()
	s["p"] = p; s["psi"] = psi; s["kappa"] = kappa; s["pivot"] = pivot; s["v"] = v; s["w"] = w; s["steer"] = steer


# ———————————————————— 自动驾驶接口（玩法 B 的执行；见 控制/自驾.gd、docs/玩法B.md §6–7）
# 自动驾驶(驾)：驾 是 控制/自驾.gd 的实例（跟踪航点、AutoNav 选弧、记账、判故障）。每帧把 dt × 倍率 换成模拟秒，
#   切成 ≤ 自驾步 的小步，逐步调 驾.步(运动态, h)（它自己调 运动步，M = 1：整个时间快进，转向也按真时间走）；
#   驾.完 时停车并发 自驾结束(原因)。自驾期间不收方向键、R、机械臂键；开动前先收臂。
signal 自驾结束(原因: String)
const 自驾步 := 0.5
var 自驾: RefCounted = null
var 自驾秒 := 0.0                                  # 本次自驾累计的模拟秒（火星上过去的时间）


func 自动驾驶(驾: RefCounted) -> void:
	自驾 = 驾; 自驾秒 = 0.0; arm_mode = false; 自动 = {}


func 停自驾(原因 := "") -> void:
	if 自驾 == null: return
	自驾 = null; v = 0.0; w = 0.0; thr_in = 0.0
	自驾结束.emit(原因)


func 自驾一帧(dt: float) -> void:
	if not arm_stowed():                                               # 同手动：臂收好才走
		arm_t = ARM_STOW.duplicate(); arm_update(dt*float(RATES[rate_i]), 0.0); return   # 收臂也快进
	var T := dt*float(RATES[rate_i])
	var n := maxi(1, ceili(T/自驾步)); var h := T/n
	var s := 运动态()
	for k in n:
		自驾.步(s, h)
		if 自驾.完: break
		自驾秒 += h
	取运动态(s)
	thr_in = float(自驾.油门)
	if 自驾.完: 停自驾(String(自驾.原因))


func arm_stowed() -> bool:
	for k in 5: if absf(arm_q[k] - ARM_STOW[k]) > 0.5: return false
	return true


func arm_update(dt: float, rot: float) -> void:
	"""rot：臂模式下当前关节的转动输入 −1…1。目标角按 ARM_RATE 走，当前角追目标（同速）。"""
	var sp := ARM_RATE*(3.0 if Input.is_action_pressed("控制_快") else 1.0)
	if arm_mode and rot != 0.0:
		arm_t[arm_sel] = clampf(arm_t[arm_sel] + rot*sp*dt, ARM_LIM[arm_sel][0], ARM_LIM[arm_sel][1])
	var moved := false
	for k in 5:
		var nq: float = move_toward(arm_q[k], arm_t[k], sp*dt)
		if nq != arm_q[k]: arm_q[k] = nq; moved = true
	if moved: P.set_arm(model, arm_q)


func teleport(np: Vector3, npsi: float) -> void:
	p = Vector3(np.x, 0, np.z); psi = npsi; v = 0.0; w = 0.0; kappa = 0.0; pivot = false
	for i in 6: steer[i] = 0.0
	last_c.clear(); c_init = false; fit_ok = false; rbq_ok = false
	if track: track.reset()


# ———————————————————— 车身：接地、拟合平面、上下补偿、轮转角
func ground(x: float, z: float) -> float:
	return P.lod.h_cpu(x, z, 0) if P.lod else 0.0


func build_rocks() -> void:
	"""固定石块（实测 + 固定撒石表）建一次；实时撒石的石块按车的位置取 ±SC_R（scatter_update），和固定的合在一起。"""
	var t0 := Time.get_ticks_msec()
	var bufs := []
	for T in P.rk_types:
		bufs.append(T["buf"]); rk_ab.append((T["mm"][0] as MultiMesh).mesh.get_aabb())
	rocks_from(bufs, rk_fixed, grid_fixed)
	var res := with_scatter(p, rk_fixed.duplicate(), grid_fixed.duplicate(true))
	rk = res[0]; grid = res[1]; sc_ctr = p
	print("[控制] 石块哈希 %d 块（固定 %d）、%d 格，%d ms" % [rk.size()/5, rk_fixed.size()/5, grid.size(), Time.get_ticks_msec() - t0])


func rocks_from(bufs: Array, out_rk: Array, out_grid: Dictionary) -> void:
	"""bufs[类型] = 每块 16 个数的缓冲（同 MultiMesh）→ 每块 5 个数（x、z、平面半径、底高、石顶离地）+ 1 m 格哈希。可在后台线程调。"""
	for ty in mini(bufs.size(), rk_ab.size()):
		var buf: PackedFloat32Array = bufs[ty]; var ab: AABB = rk_ab[ty]
		for q in range(0, buf.size() - 15, 16):
			var sx := Vector3(buf[q], buf[q + 4], buf[q + 8]).length(); var sy := Vector3(buf[q + 1], buf[q + 5], buf[q + 9]).length()
			var sz := Vector3(buf[q + 2], buf[q + 6], buf[q + 10]).length()
			var a := 0.25*(ab.size.x*sx + ab.size.z*sz)                    # 平面上的半径（网格实际外形）
			if 2.0*a < ROCK_MIN: continue
			var x := buf[q + 3]; var y := buf[q + 7]; var z := buf[q + 11]
			var g := ground(x, z)
			var H := y + ab.end.y*sy - g                                     # 石顶离地
			if H < 0.02: continue
			var n := out_rk.size()/5
			out_rk.append_array([x, z, a, g, H])
			var m := a + 0.4                                                 # 轮子取样范围（±0.2 m 沿轮向、±0.17 m 横向）
			for jj in range(floori((z - m)/CELL), floori((z + m)/CELL) + 1):
				for ii in range(floori((x - m)/CELL), floori((x + m)/CELL) + 1):
					var key := Vector2i(ii, jj)
					if not out_grid.has(key): out_grid[key] = []
					out_grid[key].append(n)


func with_scatter(c: Vector3, base_rk: Array, base_grid: Dictionary) -> Array:
	"""固定石块 + 车周围 ±SC_R 的实时撒石石块（C++ scatter_rocks：和画出来的同一套区块播种，D ≥ 10 cm 的档）。可在后台线程调。"""
	var core: RefCounted = P.lod.core if P.lod else null
	if P.scat != null and core != null and core.has_method("scatter_rocks"):
		rocks_from(core.scatter_rocks(c.x - SC_R, c.z - SC_R, c.x + SC_R, c.z + SC_R, 1), base_rk, base_grid)
	return [PackedFloat32Array(base_rk), base_grid]


func scatter_update() -> void:
	"""车离上次取撒石的中心超过 SC_MOVE：后台重取，算完换上（期间用旧的：旧的覆盖 ±SC_R，比 SC_MOVE 大得多）。"""
	if sc_task >= 0:
		if not WorkerThreadPool.is_task_completed(sc_task): return
		WorkerThreadPool.wait_for_task_completion(sc_task); sc_task = -1
		rk = sc_res[0]; grid = sc_res[1]; sc_res = []
	if Vector2(p.x - sc_ctr.x, p.z - sc_ctr.z).length() < SC_MOVE: return
	sc_ctr = p
	var c := p; var brk: Array = rk_fixed.duplicate(); var bg: Dictionary = grid_fixed.duplicate(true)
	sc_task = WorkerThreadPool.add_task(func(): sc_res = with_scatter(c, brk, bg))


func _exit_tree() -> void:
	if sc_task >= 0: WorkerThreadPool.wait_for_task_completion(sc_task); sc_task = -1


func contact(c: Vector3, hw: Vector3, lw: Vector3) -> float:
	"""轮底接地高：轮子当半径 r、宽 2·HALF_W 的圆柱，沿轮向 TS 各点取（地面、石块穹顶）减去圆周下垂，取最高。
	石块穹顶：底高 + H·√(1 − (d/a)²)，d＝石心到该横截线（轮宽内）最近点的水平距离。"""
	var cands: Array = grid.get(Vector2i(floori(c.x/CELL), floori(c.z/CELL)), [])
	var best := -INF
	for t: float in TS:
		var q := c + hw*t
		var h := ground(q.x, q.z)
		for n: int in cands:
			var o := n*5
			var d := Vector3(rk[o] - q.x, 0, rk[o + 1] - q.z)
			var e := (d - lw*clampf(d.dot(lw), -HALF_W, HALF_W)).length()/rk[o + 2]
			if e < 1.0: h = maxf(h, rk[o + 3] + rk[o + 4]*sqrt(1.0 - e*e))
		best = maxf(best, h - (r - sqrt(r*r - t*t)))
	return best


func pose() -> void:
	var b := fl(); var f: Vector3 = b[0]; var l: Vector3 = b[1]
	var c: Array[Vector3] = []
	var fit := Vector3()
	for i in 6:
		c.append(p + f*W[i].z + l*W[i].x)
		var d := steer[i]; var hw := f*cos(d) + l*sin(d); var lw := -f*sin(d) + l*cos(d)
		hc[i] = contact(c[i], hw, lw)
		fit += G[i]*hc[i]
		if last_c.size() == 6: spin[i] += (c[i] - last_c[i]).dot(hw)/r     # 各轮沿自己朝向走过的距离
	last_c = c
	var mv := (p - fit_p).length() + absf(wrapf(psi - fit_psi, -PI, PI))*1.2      # 走过的距离（原地转按轮子的弧长算）
	fit_s = fit_s.lerp(fit, 1.0 - exp(-mv/FIT_L)) if fit_ok else fit
	fit_ok = true; fit_p = p; fit_psi = psi; fit = fit_s                          # 各轮的上下补偿对着平滑后的平面算，轮子照样着地
	if not P.rb.is_empty():                                                       # 摇臂-转向架：解出关节角，轮子靠关节着地
		var qt := rb_solve(rbq if rbq_ok else PackedFloat32Array([fit.x, fit.y, fit.z, 0.0, 0.0, 0.0]), f, l)
		if rbq_ok:
			var wq := 1.0 - exp(-mv/FIT_L)
			for j in 6: rbq[j] = lerpf(rbq[j], qt[j], wq)
		else: rbq = qt
		rbq_ok = true
		body = rb_body(rbq, f, l)
		var e := rb_res(rbq, f, l)
		for i in 6: dy[i] = clampf(-e[i]/body.basis.y.y, -DY_MAX, DY_MAX)        # 平滑、限位剩下的一点点仍由上下补偿兜住
		var B := body.basis
		P.pose_rover({"b": [v3a(B.x), v3a(B.y), v3a(B.z)], "o": v3a(body.origin), "steer": steer, "dy": dy, "spin": spin,
			"rk": rbq[3], "bg": [rbq[4], rbq[5]]})
		return
	var F := (f + Vector3.UP*fit.y).normalized(); var L := (l + Vector3.UP*fit.z).normalized()
	var Y := F.cross(L).normalized(); L = Y.cross(F)
	body = Transform3D(Basis(L, Y, F), Vector3(p.x, fit.x, p.z))
	for i in 6:
		var res := hc[i] - (body*Vector3(W[i].x, 0, W[i].z)).y
		dy[i] = clampf(res/Y.y, -DY_MAX, DY_MAX) - SINK
	P.pose_rover({"b": [v3a(L), v3a(Y), v3a(F)], "o": v3a(body.origin), "steer": steer, "dy": dy, "spin": spin})


# 摇臂-转向架（实景.gd rb_fk）：未知数 q = (车身原点高 h0, 前向坡 sa, 左向坡 sb, 摇臂角 a, 左 / 右转向架角)，
# 方程 = 六个轮底正好落在接地高上（陷 SINK）：6 个方程 6 个未知数（差速杆让左右摇臂反着转，所以摇臂只有一个角）。
# 高斯-牛顿、数值雅可比，从上一帧的解出发迭代 3 次；关节限位。
const RK_LIM := 0.45                       # 摇臂 ±26°
const BG_LIM := 0.7                        # 转向架 ±40°
var rbq := PackedFloat32Array(); var rbq_ok := false


func rb_body(q: PackedFloat32Array, f: Vector3, l: Vector3) -> Transform3D:
	var F := (f + Vector3.UP*q[1]).normalized(); var L := (l + Vector3.UP*q[2]).normalized()
	var Y := F.cross(L).normalized(); L = Y.cross(F)
	return Transform3D(Basis(L, Y, F), Vector3(p.x, q[0], p.z))


func rb_res(q: PackedFloat32Array, f: Vector3, l: Vector3) -> PackedFloat32Array:
	var B := rb_body(q, f, l); var wc: Array[Vector3] = P.rb_fk(q[3], q[4], q[5])
	var e := PackedFloat32Array(); e.resize(6)
	for i in 6: e[i] = (B*(wc[i] - Vector3(0, r, 0))).y - (hc[i] - SINK)
	return e


func rb_solve(q0: PackedFloat32Array, f: Vector3, l: Vector3) -> PackedFloat32Array:
	var q := q0.duplicate()
	for it in 3:
		var e := rb_res(q, f, l)
		var A := []                                                              # 增广矩阵 [J | −e]
		for i in 6: A.append(PackedFloat64Array([0, 0, 0, 0, 0, 0, -e[i]]))
		for j in 6:
			var qd := q.duplicate(); qd[j] += 1e-4
			var ed := rb_res(qd, f, l)
			for i in 6: A[i][j] = (ed[i] - e[i])/1e-4
		for c in 6:                                                              # 高斯消元（列主元）
			var piv := c
			for i in range(c + 1, 6): if absf(A[i][c]) > absf(A[piv][c]): piv = i
			if absf(A[piv][c]) < 1e-9: return q0                                 # 奇异：不动
			var tmp = A[c]; A[c] = A[piv]; A[piv] = tmp
			for i in range(c + 1, 6):
				var m: float = A[i][c]/A[c][c]
				for k in range(c, 7): A[i][k] -= m*A[c][k]
		var dq := PackedFloat64Array([0, 0, 0, 0, 0, 0])
		for c in range(5, -1, -1):
			var sum: float = A[c][6]
			for k in range(c + 1, 6): sum -= A[c][k]*dq[k]
			dq[c] = sum/A[c][c]
		for j in 6: q[j] += dq[j]
		q[3] = clampf(q[3], -RK_LIM, RK_LIM); q[4] = clampf(q[4], -BG_LIM, BG_LIM); q[5] = clampf(q[5], -BG_LIM, BG_LIM)
	return q


func v3a(x: Vector3) -> Array:
	return [x.x, x.y, x.z]


# ———————————————————— 相机
func set_mode(m: String) -> void:
	if not MODES.has(m): m = "跟车"
	if m == mode: return
	var cur := get_viewport().get_camera_3d()
	for g in head_parts:
		g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY if m == "桅杆" else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	mode = m
	if m == "自由":
		if cur and cur != P.fly: P.fly.global_transform = cur.global_transform; P.fly.fov = cur.fov
		P.fly.keep_aspect = Camera3D.KEEP_WIDTH; P.fly.current = true
	else:
		c_init = false; cam.current = true; update_cam(0.0)
	模式改变.emit(m)


func update_cam(dt: float) -> void:
	if mode == "自由": return
	var k := 1.0 - exp(-dt*8.0) if c_init else 1.0
	match mode:
		"跟车":
			var F := body.basis.z; var behind := atan2(-F.x, -F.z)
			var tgt := body.origin + Vector3.UP*1.0
			if not c_init: c_yaw = behind + yaw_off; c_tgt = tgt
			c_yaw += wrapf(behind + yaw_off - c_yaw, -PI, PI)*(1.0 - exp(-dt*2.5))   # 软跟随：慢慢转到车后
			c_tgt = c_tgt.lerp(tgt, k)
			var want := c_tgt + Vector3(sin(c_yaw)*cos(c_pitch), sin(c_pitch), cos(c_yaw)*cos(c_pitch))*c_dist
			want.y = maxf(want.y, ground(want.x, want.z) + 0.5)
			c_pos = c_pos.lerp(want, k) if c_init else want
			c_pos.y = maxf(c_pos.y, ground(c_pos.x, c_pos.z) + 0.4)               # 不入地
			cam.fov = 60.0
			cam.global_transform = Transform3D(Basis.IDENTITY, c_pos).looking_at(c_tgt, Vector3.UP)
		"桅杆":
			var B := body.basis*Basis(Vector3.UP, m_pan)*Basis(Vector3.UP, PI)*Basis(Vector3.RIGHT, m_tilt)
			cam.fov = m_fov
			cam.global_transform = Transform3D(B, body*mast_local)
		"俯视":
			var want := body.origin + Vector3.UP*top_h
			c_pos = c_pos.lerp(want, k) if c_init else want
			cam.fov = 60.0
			cam.global_transform = Transform3D(Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)), c_pos)
	c_init = true


# ———————————————————— 给界面
func 状态() -> Dictionary:
	"""模式：相机模式；车位置：车体原点（轮底中心，Godot 坐标）；航向_deg：0 = 北、顺时针；
	速度_mps：真车等效速度＝显示速度 / 倍率（负＝倒车；原地转为 0）；俯仰_deg：车头抬为正；横滚_deg：右侧低为正；
	里程_m：显示里程（含倍率，即场景里真走过的距离）；转向_deg：两个前角轮实际转角的平均（左正，原地转时约 0）；倍率：速度倍数。
	轮转向_deg / 轮升降_m：六个轮各自的转角（左正）、上下补偿（m，即 pose_rover 的 dy）；轮序：这六个数对应的轮子名；
	倾角_deg：车身总倾角 acos(车身上方向·世界上)；油门：当前油门输入 −1…1。
	机械臂：{模式, 关节（当前选中）, 角度_deg（五个关节，在模型姿态上加）, 收好}；摇臂_deg（左，右 = −左）、转向架_deg（[左, 右]）。"""
	var F := body.basis.z; var L := body.basis.x
	return {"模式": mode, "车位置": body.origin, "航向_deg": fposmod(rad_to_deg(atan2(F.x, -F.z)), 360.0),
		"速度_mps": v if 自驾 != null else v/RATES[rate_i], "自驾": 自驾 != null, "俯仰_deg": rad_to_deg(asin(clampf(F.y, -1, 1))), "横滚_deg": rad_to_deg(asin(clampf(L.y, -1, 1))),
		"里程_m": odo, "转向_deg": rad_to_deg(0.5*(steer[0] + steer[3])), "倍率": RATES[rate_i],
		"相机": P.fly if mode == "自由" else cam, "按键": 按键(),
		"轮转向_deg": Array(steer).map(func(x): return rad_to_deg(x)), "轮升降_m": Array(dy), "轮序": wheel_names(),
		"倾角_deg": rad_to_deg(acos(clampf(body.basis.y.normalized().y, -1, 1))), "油门": thr_in,
		"机械臂": {"模式": arm_mode, "关节": ARM_J[arm_sel], "关节号": arm_sel, "角度_deg": arm_q.duplicate(), "收好": arm_stowed()},
		"摇臂_deg": rad_to_deg(rbq[3]) if rbq_ok else 0.0, "转向架_deg": [rad_to_deg(rbq[4]), rad_to_deg(rbq[5])] if rbq_ok else [0.0, 0.0]}


func wheel_names() -> Array[String]:
	"""按 rover_rig.json 的轮序：模型 x > 0 为左，z 最大为前、最小为后。"""
	var out: Array[String] = []
	for i in 6:
		var zs: Array = []
		for k in 6: if signf(W[k].x) == signf(W[i].x): zs.append(W[k].z)
		zs.sort()
		out.append(("左" if W[i].x > 0 else "右") + ["后", "中", "前"][zs.find(W[i].z)])
	return out
