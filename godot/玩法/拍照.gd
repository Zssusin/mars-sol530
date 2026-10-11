# 拍照模式（界面调研 §3.4、§5.9）：C 进出。世界暂停、HUD 隐藏；相机独立于 控制.gd（控制模块暂停后它的相机也停）。
#   相机：以车为圆心、半径 30 m，不钻地；鼠标转头，WASD 走、Q/E 降升（Shift 快、Ctrl 慢），滚轮焦距。
#   参数（↑↓ 选、←→ 调，Shift 大步）：焦距（35 mm 等效 10–300 mm）、横滚、对焦（自动 / 手动）、景深、EV、太阳时刻、τ、三分线、取景。
#     对焦、景深、EV 用 CameraAttributesPractical，挂在 WorldEnvironment 上（出图的 SubViewport 相机也吃到）。
#     不换 Physical：曝光已经折进了灯光（实景.gd expo_in_lights），Physical 会接管曝光和视场，打乱标定。
#     时刻用 实景.gd set_time_f（相邻天空插值），τ 用 天气.gd set_tau（天空整套换）；暂停期间由 玩法.世界更新 替 实景 跑 poll_sky 等。
#   N：Navcam 取景（桅杆头位置、scene.json 对照机位的视场 81.9°、4:3 取景框，桅杆头零件只投影）；G 三分线；Tab 隐藏面板。
#   空格拍照：复用 实景.gd render_all（临时把 cams 换成这一台）→ 2× 超采样 SubViewport、LANCZOS 缩回；
#     加水印（左下小字：sol、LTST、坐标、署名，无任何 NASA 标志）→ user://相册/<时间>.png、_小.jpg、.json。
#   Enter：交卷（有当前复刻挑战时，见 复刻.gd）。
extends Node

const 件 := preload("res://界面/件.gd")

signal 拍了(meta: Dictionary)

const 项 := ["焦距", "横滚", "对焦", "景深", "曝光", "时刻", "τ", "三分线", "取景"]
const 半径 := 30.0
const 焦档 := [0.5, 0.8, 1.2, 2.0, 3.0, 5.0, 8.0, 12.0, 20.0, 35.0, 60.0, 100.0, 200.0, 500.0, 2000.0]
var 相册 := "user://相册/"                         # 自测时换成 相册_自测/

var 玩: Node
var P: Node
var 风: RefCounted
var 开着 := false
var cam: Camera3D
var 前相机: Camera3D = null
var 属性: CameraAttributesPractical
var we: WorldEnvironment = null
var 原属性: CameraAttributes = null
var yaw := 0.0
var pitch := 0.0
var 横滚 := 0.0                                   # °
var 焦距 := 24.0                                  # 35 mm 等效 mm
var 自动焦 := true
var 焦距离 := 10.0                                # 对焦距离 m
var 测得 := 10.0                                  # 自动对焦测到的距离
var 景深 := 0.0                                   # 0–1（界面上叫「景深」，0 = 全清晰）
var EV := 0.0
var 网格 := true
var 面板 := true
var navcam := false
var 选 := 0
var 出图中 := false
var 提示 := ""
var 提示时 := 0.0
var 层: CanvasLayer
var 画: Control
var 隐层 := {}
var mast_local := Vector3(0, 2.0, 0)
var nav_hfov := 81.9
var 测累 := 0.0
var ss := 2
var 悬 := -1                                      # 鼠标指着的东西：0–8 参数行、100 快门、101 退出、110+ 页底键
var 按 := -1
var 框: Array = []                                # 画的时候记下 [[号, 矩形], …]（点击判定）
var 鼠标位 := Vector2.ZERO
var 右键转 := false
var 面板x中 := 0.0


func _ready() -> void:
	玩 = get_parent(); P = 玩.P; 风 = 玩.风
	ss = int(P.args.get("拍照超采样", "2"))
	if P.args.has("玩法测试"): 相册 = "user://相册_自测/"
	cam = Camera3D.new(); cam.name = "拍照相机"; cam.keep_aspect = Camera3D.KEEP_WIDTH; cam.near = 0.02; cam.far = 200000.0
	add_child(cam)
	属性 = CameraAttributesPractical.new()
	for c in P.get_children(): if c is WorldEnvironment: we = c
	for c in P.J["cameras"]:
		if String(c["name"]).begins_with("对照"): nav_hfov = float(c["hfov"]); break
	var 控: Node = P.get_node_or_null("控制")
	if 控 and 控.get("mast_local") is Vector3: mast_local = 控.mast_local
	elif P.rover_root:
		var ms: Array = P.J["rover"]["mast"]; mast_local = P.rover_root.global_transform.affine_inverse()*Vector3(ms[0], ms[1], ms[2])
	层 = CanvasLayer.new(); 层.layer = 30; 层.visible = false; add_child(层)
	画 = Control.new(); 画.set_anchors_preset(Control.PRESET_FULL_RECT); 画.mouse_filter = Control.MOUSE_FILTER_IGNORE
	画.draw.connect(_画); 层.add_child(画)


# ———————————————————— 进出
func 进入() -> void:
	if 开着: return
	前相机 = get_viewport().get_camera_3d()
	if 前相机 == null: return
	开着 = true
	var t := 前相机.global_transform; var f := -t.basis.z
	yaw = atan2(-f.x, -f.z); pitch = asin(clampf(f.y, -0.999, 0.999)); 横滚 = 0.0
	cam.global_position = 限位(t.origin)
	var hf := deg_to_rad(前相机.fov)
	if 前相机.keep_aspect == Camera3D.KEEP_HEIGHT:
		var vs := get_viewport().get_visible_rect().size; hf = 2.0*atan(tan(hf*0.5)*vs.x/vs.y)
	焦距 = clampf(18.0/tan(hf*0.5), 10.0, 300.0); 自动焦 = true
	navcam = false
	更新相机(); cam.current = true
	隐层.clear()
	for c in P.find_children("*", "CanvasLayer", true, false):
		if c != 层 and c.layer < 40: 隐层[c] = c.visible; c.visible = false   # 界面、天气提示、导览卡都藏（≥ 40 是图鉴、复刻结果这类全屏页）
	if we: 原属性 = we.camera_attributes; we.camera_attributes = 属性
	更新属性()
	玩.暂停("拍照", true)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE; 右键转 = false; 悬 = -1; 按 = -1        # 界面 6：默认鼠标可见（点面板、点快门）；按住右键转头
	层.visible = true; 画.queue_redraw()


func 退出() -> void:
	if not 开着 or 出图中: return
	开着 = false; 右键转 = false; Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if navcam: 设navcam(false)
	if 前相机 and is_instance_valid(前相机): 前相机.current = true
	for c in 隐层: if is_instance_valid(c): c.visible = 隐层[c]
	if we: we.camera_attributes = 原属性
	层.visible = false
	玩.暂停("拍照", false)


# ———————————————————— 相机
func 限位(p: Vector3) -> Vector3:
	"""车周 30 m 内、离地 ≥ 0.25 m。"""
	var c: Vector3 = 玩.车位() + Vector3.UP
	var d := p - c
	if d.length() > 半径: p = c + d.normalized()*半径
	p.y = maxf(p.y, 玩.地高(p.x, p.z) + 0.25)
	return p


func 帧() -> Rect2:
	"""输出画幅在窗口里的位置：自由取景 = 整个窗口；Navcam = 居中的 4:3。"""
	var vs := get_viewport().get_visible_rect().size
	if not navcam: return Rect2(Vector2.ZERO, vs)
	var w := minf(vs.x, vs.y*4.0/3.0); var h := w*0.75
	return Rect2((vs - Vector2(w, h))*0.5, Vector2(w, h))


func 输出视场() -> float:
	"""输出画幅的水平视场（°）：Navcam 用对照机位的 81.9°（有复刻挑战时用那张原图去畸变后的视场），自由取景按 35 mm 等效焦距（36 mm 宽）。"""
	return nav视场() if navcam else rad_to_deg(2.0*atan(18.0/焦距))


func nav视场() -> float:
	var v: float = 玩.复刻.视场() if 玩.复刻 and 玩.复刻.has_method("视场") else -1.0
	return v if v > 0.0 else nav_hfov


func 更新相机() -> void:
	var B := Basis.from_euler(Vector3(pitch, yaw, 0.0))*Basis(Vector3(0, 0, 1), deg_to_rad(-横滚))
	cam.global_basis = B
	var vs := get_viewport().get_visible_rect().size; var fr := 帧()
	var hf := deg_to_rad(输出视场())
	cam.fov = rad_to_deg(2.0*atan(tan(hf*0.5)*vs.x/fr.size.x))          # 相机按窗口宽算视场，Navcam 的 4:3 框里正好是 81.9°


func 设navcam(on: bool) -> void:
	navcam = on
	var 控: Node = P.get_node_or_null("控制")
	if on:
		cam.global_position = P.rover_root.global_transform*mast_local if P.rover_root else cam.global_position
		横滚 = 0.0
		for g in P.hide_parts: g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		说("Navcam 取景：桅杆头 %.2f m 高，视场 %.1f° × %.1f°（4:3）" % [(P.rover_root.global_transform*mast_local).y - 玩.地高(cam.global_position.x, cam.global_position.z) if P.rover_root else 2.0,
			nav视场(), rad_to_deg(2.0*atan(tan(deg_to_rad(nav视场())*0.5)*0.75))])
	else:
		for g in P.hide_parts: g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if 控 and String(控.get("mode")) == "桅杆" and 控.get("head_parts") is Array:
			for g in 控.head_parts: g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	更新相机(); 画.queue_redraw()


func 测距() -> float:
	"""自动对焦：沿视线步进找地面（h_cpu），再看车（车体中心 1.3 m 内）；看天给 2000 m。"""
	var o := cam.global_position; var d := -cam.global_basis.z
	var t := 0.3; var prev := 0.3; var hit := 2000.0
	while t < 2000.0:
		var p := o + d*t
		if p.y < 玩.地高(p.x, p.z):
			var a := prev; var b := t
			for k in 8:
				var m := (a + b)*0.5; var q := o + d*m
				if q.y < 玩.地高(q.x, q.z): b = m
				else: a = m
			hit = (a + b)*0.5; break
		prev = t; t = t*1.05 + 0.05
	var c: Vector3 = 玩.车位() + Vector3.UP*0.9; var tc := (c - o).dot(d)
	if tc > 0.0 and (o + d*tc).distance_to(c) < 1.3 and tc < hit: hit = maxf(tc - 0.6, 0.3)
	return hit


func 更新属性() -> void:
	属性.exposure_multiplier = pow(2.0, EV)
	var on := 景深 > 0.001
	属性.dof_blur_far_enabled = on; 属性.dof_blur_near_enabled = on
	if not on: return
	var d := 测得 if 自动焦 else 焦距离
	var k := lerpf(1.5, 0.05, 景深)*clampf(35.0/焦距, 0.15, 3.0)       # 焦外起点（相对对焦距离）：长焦、大光圈景深浅
	属性.dof_blur_far_distance = d*(1.0 + k); 属性.dof_blur_far_transition = d*(1.0 + k)
	属性.dof_blur_near_distance = d/(1.0 + k); 属性.dof_blur_near_transition = d/(1.0 + k)*0.6
	属性.dof_blur_amount = lerpf(0.04, 0.25, 景深)


# ———————————————————— 每帧
func _process(dt: float) -> void:
	if not 开着: return
	if 提示时 > 0.0:
		提示时 -= dt
		if 提示时 <= 0.0: 画.queue_redraw()
	件.提示更(str(悬) if 悬 >= 0 else "", dt); 画.queue_redraw()
	if 出图中: return
	var mv := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): mv.z -= 1
	if Input.is_key_pressed(KEY_S): mv.z += 1
	if Input.is_key_pressed(KEY_A): mv.x -= 1
	if Input.is_key_pressed(KEY_D): mv.x += 1
	var up := 0.0
	if Input.is_key_pressed(KEY_E): up += 1
	if Input.is_key_pressed(KEY_Q): up -= 1
	if mv != Vector3.ZERO or up != 0.0:
		if navcam: 设navcam(false); 说("离开 Navcam 取景")
		var sp := 3.0*(5.0 if Input.is_key_pressed(KEY_SHIFT) else (0.2 if Input.is_key_pressed(KEY_CTRL) else 1.0))
		var p := cam.global_position + (cam.global_basis*mv.normalized() + Vector3.UP*up)*sp*dt
		cam.global_position = 限位(p)
	更新相机()
	测累 += dt
	if 测累 > 0.1:
		测累 = 0.0
		var d := 测距()
		if absf(d - 测得) > 0.01*测得 + 0.01:
			测得 = d
			if 自动焦: 更新属性(); 画.queue_redraw()
	玩.世界更新(cam)


# ———————————————————— 键
func 输入(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var k := 0.002*clampf(输出视场()/60.0, 0.1, 1.5)
		yaw -= ev.relative.x*k; pitch = clampf(pitch - ev.relative.y*k, deg_to_rad(-89.0), deg_to_rad(89.0))
		return
	if ev is InputEventMouseMotion:
		鼠标位 = ev.position
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			var i := 点中(ev.position); 悬 = int(框[i][0]) if i >= 0 else -1
			if 悬 >= 0 and 悬 < 项.size() and 选 != 悬: 选 = 悬
		return
	if ev is InputEventMouseButton:
		var 大2 := Input.is_key_pressed(KEY_SHIFT)
		if ev.pressed:
			match ev.button_index:
				MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
					var d := 1 if ev.button_index == MOUSE_BUTTON_WHEEL_UP else -1
					if 面板 and 悬 >= 1 and 悬 < 项.size(): 调(悬, d, 大2)               # 滚轮在哪一行上就调哪一行，别处调焦距
					else: 调(0, d, false)
				MOUSE_BUTTON_RIGHT: 右键转 = true; Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				MOUSE_BUTTON_LEFT:
					var i := 点中(ev.position); 按 = int(框[i][0]) if i >= 0 else -1
		else:
			match ev.button_index:
				MOUSE_BUTTON_RIGHT:
					if 右键转: 右键转 = false; Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				MOUSE_BUTTON_LEFT:
					var i := 点中(ev.position); var 起 := 按; 按 = -1
					if i >= 0 and int(框[i][0]) == 起 and 起 >= 0: 点击(起, ev.position)         # 抬起才触发，移出再抬起取消
		画.queue_redraw(); return
	if not (ev is InputEventKey and ev.pressed): return
	var 大 := (ev as InputEventKey).shift_pressed
	match ev.keycode:
		KEY_UP: 选 = posmod(选 - 1, 项.size())
		KEY_DOWN: 选 = posmod(选 + 1, 项.size())
		KEY_LEFT: 调(选, -1, 大)
		KEY_RIGHT: 调(选, 1, 大)
		_:
			if ev.echo: return
			match ev.keycode:
				KEY_ESCAPE, KEY_C: 退出(); return
				KEY_SPACE: 拍()
				KEY_ENTER, KEY_KP_ENTER:
					if 玩.复刻 and 玩.复刻.进行中(): 玩.复刻.交卷()
					else: 说("没有复刻挑战")
				KEY_N: 设navcam(not navcam)
				KEY_G: 网格 = not 网格
				KEY_TAB: 面板 = not 面板
				KEY_R: 横滚 = 0.0
				_: return
	画.queue_redraw()


func 点中(p: Vector2) -> int:
	var rs: Array = []
	for q in 框: rs.append(q[1])
	return 件.命中(rs, p)


func 点击(id: int, p: Vector2) -> void:
	if id < 项.size():
		选 = id
		if 项[id] == "三分线" or 项[id] == "取景": 调(id, 1, false)
		else: 调(id, 1 if p.x > 面板x中 else -1, false)               # 点值的右半 = 加，左半 = 减
	elif id == 100: 拍()
	elif id == 101: 退出()
	elif id == 110: 拍()
	elif id == 111: 设navcam(not navcam)
	elif id == 112: 网格 = not 网格
	elif id == 113: 面板 = not 面板
	elif id == 114: 退出()
	elif id == 115 and 玩.复刻 and 玩.复刻.进行中(): 玩.复刻.交卷()
	画.queue_redraw()


func 调(i: int, d: int, 大: bool) -> void:
	match 项[i]:
		"焦距":
			if navcam: 设navcam(false)
			焦距 = clampf(焦距*pow(1.25 if 大 else 1.08, d), 10.0, 300.0)
		"横滚": 横滚 = clampf(横滚 + d*(5.0 if 大 else 1.0), -45.0, 45.0)
		"对焦":                                                          # 档位：自动、0.5 m … 500 m、∞
			var i0 := 0 if 自动焦 else 1 + 焦档.find(焦距离)
			var i1 := clampi(i0 + d*(3 if 大 else 1), 0, 焦档.size())
			自动焦 = i1 == 0
			if not 自动焦: 焦距离 = 焦档[i1 - 1]
		"景深": 景深 = clampf(景深 + d*(0.25 if 大 else 0.05), 0.0, 1.0)
		"曝光": EV = clampf(snappedf(EV + d*(1.0 if 大 else 1.0/3.0), 1.0/3.0), -3.0, 3.0)
		"时刻":
			var ks: Array = P.J["sky"].keys().map(func(k): return P.minutes(k))
			var lo: float = ks.min(); var hi: float = ks.max()
			var m: float = P.time_m if P.time_m >= 0.0 else P.minutes(P.ltst)
			P.set_time_f(clampf(snappedf(m, 10.0) + d*(60.0 if 大 else 10.0), lo, hi))
		"τ":
			var w: Node = P.get_node_or_null("天气")
			if w and w.get("taus") is Array and not w.taus.is_empty():
				var i2: int = w.taus.find(w.tau_key); w.set_tau(w.taus[clampi(i2 + d, 0, w.taus.size() - 1)], false)
		"三分线": 网格 = not 网格
		"取景": 设navcam(not navcam)
	更新属性(); 画.queue_redraw()


func 说(t: String, 秒 := 3.0) -> void:
	提示 = t; 提示时 = 秒; print("[拍照] ", t)
	if 画: 画.queue_redraw()


func 值(i: int) -> String:
	match 项[i]:
		"焦距": return "%d mm · %.0f°" % [roundi(焦距), 输出视场()] if not navcam else "%.1f°" % nav视场()
		"横滚": return "%+.0f°" % 横滚
		"对焦": return ("自动 %s" if 自动焦 else "手动 %s") % 米(测得 if 自动焦 else 焦距离)
		"景深": return "关" if 景深 <= 0.001 else "%d%%" % roundi(景深*100.0)
		"曝光": return "%+.1f" % EV
		"时刻": return 时刻文()
		"τ":
			var w: Node = P.get_node_or_null("天气")
			return String(w.tau_key) if w else "0.67"
		"三分线": return "开" if 网格 else "关"
		"取景": return "Navcam" if navcam else "自由"
	return ""


func 米(x: float) -> String:
	return "∞" if x >= 1999.0 else ("%.1f m" % x if x < 100.0 else "%d m" % roundi(x))


func 时刻文() -> String:
	var m: float = P.time_m if P.time_m >= 0.0 else P.minutes(P.ltst)
	return "%02d:%02d" % [int(m)/60, int(m)%60]


func τ值() -> float:
	var w: Node = P.get_node_or_null("天气")
	return float(w.tau_key) if w else 0.67


# ———————————————————— 叠加层（不进照片）
func _画() -> void:
	var c := 画; var vs := c.size; var s: float = 风.s; var fr := 帧()
	if navcam:                                                          # 4:3 框外压暗
		var k := Color(风.暗色, 0.55)
		c.draw_rect(Rect2(0, 0, fr.position.x, vs.y), k); c.draw_rect(Rect2(fr.end.x, 0, vs.x - fr.end.x, vs.y), k)
		c.draw_rect(fr, Color(风.白, 0.7), false, maxf(1.0, 2.0*s))
		件.图标(c, "相机_桅杆", fr.position + Vector2(34, 36)*s, 32.0, 风.白)
		风.字串(c, fr.position + Vector2(62*s, 44*s), "%.1f° × %.1f°" % [nav视场(), rad_to_deg(2.0*atan(tan(deg_to_rad(nav视场())*0.5)*0.75))], 22, 风.白, "等中")
	if 网格:
		for k: float in [1.0/3.0, 2.0/3.0]:
			var x := fr.position.x + fr.size.x*k; var y := fr.position.y + fr.size.y*k
			c.draw_line(Vector2(x, fr.position.y), Vector2(x, fr.end.y), Color(1, 1, 1, 0.30), maxf(1.0, 1.5*s))
			c.draw_line(Vector2(fr.position.x, y), Vector2(fr.end.x, y), Color(1, 1, 1, 0.30), maxf(1.0, 1.5*s))
	var o := vs*0.5; var r := 9.0*s                                     # 中心对焦点
	风.线(c, o - Vector2(r, 0), o - Vector2(r*0.4, 0), 风.白, 2.0*s); 风.线(c, o + Vector2(r*0.4, 0), o + Vector2(r, 0), 风.白, 2.0*s)
	风.线(c, o - Vector2(0, r), o - Vector2(0, r*0.4), 风.白, 2.0*s); 风.线(c, o + Vector2(0, r*0.4), o + Vector2(0, r), 风.白, 2.0*s)
	if 景深 > 0.001: 风.字串(c, o + Vector2(16*s, 30*s), 米(测得 if 自动焦 else 焦距离), 20, 风.灰, "等")
	框.clear()
	件.图标(c, "暂停", Vector2(vs.x*0.5, 40*s), 36.0, 风.白)                  # 世界暂停了（图标，不写句子）
	var 退r := Rect2(30*s, 24*s, 60*s, 60*s); 框.append([101, 退r])
	var 退h := 件.悬度("拍退", 悬 == 101); if 退h > 0.01: c.draw_rect(退r, Color(风.白, 0.14*退h))
	件.图标(c, "关闭", 退r.get_center(), 36.0, 风.白)
	if 面板:
		var w := 440.0*s; var rh := 50.0*s; var x0 := vs.x - w - 40*s; var y0 := vs.y*0.22
		面板x中 = x0 + w*0.62
		风.面板(c, Rect2(x0, y0, w, rh*项.size() + 28*s), 0.9)
		件.滑竖(c, "拍行竖", Vector2(x0 + 2*s, y0 + 14*s + rh*选 + 6*s), Vector2(x0 + 2*s, y0 + 14*s + rh*(选 + 1) - 6*s), 风.白, 4.0)
		for i in 项.size():
			var yr := y0 + 14*s + rh*i; var y := yr + rh*0.68; var 亮 := i == 选; var hv := 件.悬度("拍行%d" % i, i == 悬)
			var 行r := Rect2(x0, yr, w, rh); 框.append([i, 行r])
			if hv > 0.01 or 亮: c.draw_rect(行r, Color(风.白, 0.06 + 0.08*hv if 亮 else 0.10*hv))
			var col := Color(风.白 if 亮 else 令.色["次"].lerp(风.白, hv), 1.0)
			风.字串(c, Vector2(x0 + 22*s, y), 项[i], 22, col, "正")
			var vr := 值(i)
			风.字串(c, Vector2(x0 + w - 56*s, y), vr, 22, col, "等中", HORIZONTAL_ALIGNMENT_RIGHT, w - 140*s)
			if 项[i] != "三分线" and 项[i] != "取景" and (亮 or hv > 0.3):                       # 左右小箭头：点左半减、点右半加
				var ay := yr + rh*0.5; var ax0 := x0 + w*0.62 - 14*s; var ax1 := x0 + w - 22*s
				件.折(c, PackedVector2Array([Vector2(ax0 + 6*s, ay - 8*s), Vector2(ax0, ay), Vector2(ax0 + 6*s, ay + 8*s)]), col, 2.0)
				件.折(c, PackedVector2Array([Vector2(ax1 - 6*s, ay - 8*s), Vector2(ax1, ay), Vector2(ax1 - 6*s, ay + 8*s)]), col, 2.0)
	# 快门（鼠标点）和页底键
	var 快c := Vector2(vs.x*0.5, vs.y - 128*s); var 快hv := 件.悬度("拍快门", 悬 == 100); var 快k := 令.点击["按缩"] if 按 == 100 else 1.0
	框.append([100, Rect2(快c - Vector2(48, 48)*s, Vector2(96, 96)*s)])
	c.draw_circle(快c, (46 + 4*快hv)*s*快k, Color(风.暗色, 0.55)); c.draw_arc(快c, 40*s*快k, 0, TAU, 48, Color(风.白, 1.0), 4.0*s, true)
	c.draw_circle(快c, 30*s*快k, Color(风.白, 0.85 + 0.15*快hv)); 件.图标(c, "拍照", 快c, 34.0*快k, 风.暗色)
	var 键表 := [["空格", "拍照", "拍照"], ["N", "相机_桅杆", "Navcam 取景"], ["G", "", "三分线"], ["Tab", "设置", "显示 / 隐藏面板"], ["Esc", "关闭", "退出"]]
	if 玩.复刻 and 玩.复刻.has_method("进行中") and 玩.复刻.进行中(): 键表.append(["Enter", "执行", "交卷"])
	var 行 := 件.键图行(c, Vector2(vs.x*0.5, vs.y - 34*s), 键表, (悬 - 110) if 悬 >= 110 else -1, (按 - 110) if 按 >= 110 else -1)
	for i in 行.size(): 框.append([110 + i, 行[i]])
	if 提示时 > 0.0 or 出图中:
		风.字串(c, Vector2(vs.x*0.5, vs.y - 210*s), "冲洗中…" if 出图中 else 提示, 24, 风.白, "中", HORIZONTAL_ALIGNMENT_CENTER)
	var 提 := ""
	if 悬 >= 0 and 悬 < 项.size(): 提 = String({"焦距": "焦距（滚轮）", "横滚": "横滚（R 归零）", "对焦": "对焦：自动或手动距离", "景深": "景深：0 = 全清晰", "曝光": "曝光补偿 EV", "时刻": "太阳时刻", "τ": "尘埃光学厚度 τ", "三分线": "三分线", "取景": "自由取景 / Navcam 4:3"}.get(项[悬], ""))
	elif 悬 >= 110: 提 = String(键表[悬 - 110][2]) if 悬 - 110 < 键表.size() else ""
	elif 悬 == 100: 提 = "拍照（空格）"
	elif 悬 == 101: 提 = "退出（Esc）"
	件.提示画(c, 提, 鼠标位, vs)
	if 玩.复刻 and 玩.复刻.has_method("画参考"): 玩.复刻.画参考(c)


# ———————————————————— 出图
func 拍(交卷 := false) -> Dictionary:
	"""出一张照片，返回元数据（失败返回空）。交卷：复刻.gd 调，元数据里带上挑战号。"""
	if 出图中: return {}
	出图中 = true; 画.queue_redraw()
	await RenderingServer.frame_post_draw
	var fr := 帧(); var W := int(fr.size.x); var H := int(fr.size.y); var hf := 输出视场()
	var B := cam.global_basis; var fw := -B.z; var up := B.y; var p := cam.global_position
	var 名 := Time.get_datetime_string_from_system().replace("-", "").replace(":", "").replace("T", "_") + "_%03d" % (Time.get_ticks_msec() % 1000)
	var 临时 := ProjectSettings.globalize_path(相册 + "_冲洗")
	var c := {"name": ("对照_玩家_" if navcam else "相册_") + 名, "pos": [p.x, p.y, p.z], "fwd": [fw.x, fw.y, fw.z], "up": [up.x, up.y, up.z],
		"hfov": hf, "W": W, "H": H, "pixel_angle": deg_to_rad(hf)/W}
	var 旧: Array = P.cams; P.cams = [c]
	var t0 := Time.get_ticks_msec()
	await P.render_all(临时, ss)                                       # 实景.gd：ss 倍 SubViewport、等帧、LANCZOS 缩回 W×H
	P.cams = 旧
	if navcam: for g in P.hide_parts: g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	else: 设navcam(false)                                               # render_all 改过车头零件的投影，按当前取景还原
	var f := 临时.path_join("%s_%s.png" % [c["name"], String(P.ltst).replace(":", "")])
	var img := Image.load_from_file(f)
	DirAccess.remove_absolute(f)
	if img == null: 出图中 = false; 说("出图失败"); return {}
	img.convert(Image.FORMAT_RGBA8)
	var E := p.x; var N := -p.z
	var lat := 18.45864728 + rad_to_deg(N/3396190.0); var lon := 77.40592495 + rad_to_deg(E/(3396190.0*cos(deg_to_rad(lat))))
	var el := -2523.168 + p.y + (E*E + N*N)/(2.0*3396190.0)
	var meta := {"sol": 530, "ltst": 时刻文(), "τ": τ值(), "E": snappedf(E, 0.01), "N": snappedf(N, 0.01), "U": snappedf(p.y, 0.01),
		"纬度": snappedf(lat, 0.0000001), "经度": snappedf(lon, 0.0000001), "高程": snappedf(el, 0.1),
		"相机": {"pos": [snappedf(E, 0.001), snappedf(N, 0.001), snappedf(p.y, 0.001)], "fwd": [fw.x, -fw.z, fw.y], "up": [up.x, -up.z, up.y],
			"hfov": hf, "焦距_mm": snappedf(焦距, 0.1), "横滚_deg": 横滚, "EV": EV, "对焦_m": snappedf(测得 if 自动焦 else 焦距离, 0.01),
			"自动对焦": 自动焦, "景深": 景深, "取景": "Navcam" if navcam else "自由"},
		"车": {"E": snappedf(玩.车位().x, 0.01), "N": snappedf(-玩.车位().z, 0.01)},
		"尺寸": [W, H], "超采样": ss, "时间": Time.get_datetime_string_from_system(), "名": 名}
	await 水印(img, ["SOL 530 · LTST %s · %.6f°N %.6f°E · %.1f m · τ %.2f" % [meta["ltst"], lat, lon, el, meta["τ"]],
		"毅力号 · 杰泽罗陨石坑 · 数据 NASA/JPL-Caltech/ASU/MSSS/UArizona/USGS · 非 NASA 官方图像"])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(相册))
	img.save_png(相册 + 名 + ".png")
	var th := img.duplicate() as Image; th.resize(480, int(480.0*H/W), Image.INTERPOLATE_LANCZOS); th.save_jpg(相册 + 名 + "_小.jpg", 0.85)
	meta["文件"] = 相册 + 名 + ".png"; meta["缩略图"] = 相册 + 名 + "_小.jpg"
	var ff := FileAccess.open(相册 + 名 + ".json", FileAccess.WRITE); ff.store_string(JSON.stringify(meta, "\t")); ff.close()
	出图中 = false
	说("已存入相册：%s.png（%d×%d，%d× 超采样，%.1f s）" % [名, W, H, ss, (Time.get_ticks_msec() - t0)/1000.0], 4.0)
	拍了.emit(meta)
	return meta


func 水印(img: Image, 行: Array) -> void:
	"""左下角两行小字：2D SubViewport 透明底画双描边字，取回后 blend 到照片上（图里不出现任何标志）。"""
	var k := img.get_height()/1440.0; var h := int(78*k); var w := int(img.get_width()*0.9)
	var sv := SubViewport.new(); sv.size = Vector2i(w, h); sv.transparent_bg = true; sv.disable_3d = true
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var cc := Control.new(); cc.size = Vector2(w, h)
	cc.draw.connect(func():
		var s0: float = 风.s; 风.s = k
		风.字串(cc, Vector2(4*k, 30*k), 行[0], 20, Color(风.白, 0.92), "等")
		风.字串(cc, Vector2(4*k, 62*k), 行[1], 18, Color(风.灰, 0.92), "正")
		风.s = s0)
	sv.add_child(cc); add_child(sv)
	await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	var wm := sv.get_texture().get_image(); wm.convert(Image.FORMAT_RGBA8)
	img.blend_rect(wm, Rect2i(Vector2i.ZERO, wm.get_size()), Vector2i(int(28*k), img.get_height() - h - int(18*k)))
	sv.queue_free()


func 当前位姿() -> Dictionary:
	"""复刻评分用：相机（ENU）、输出视场、LTST 分钟。"""
	var B := cam.global_basis; var p := cam.global_position; var f := -B.z
	return {"pos": Vector3(p.x, -p.z, p.y), "fwd": Vector3(f.x, -f.z, f.y), "hfov": 输出视场(),
		"分": P.time_m if P.time_m >= 0.0 else P.minutes(P.ltst), "navcam": navcam}
