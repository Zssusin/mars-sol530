# 影子车和 3D 路径带（docs/玩法B.md §7、§8）。
#   路带：计划的航点折线贴地画成 0.16 m 宽的半透明带（不受光照；按驾驶方式着色：盲开白虚、视觉里程计白、AutoNav 琥珀）。
#         执行中只画车头前 2–62 m、两头淡出，车走 1.5 m 重画（就是阿克曼预测弧延伸成整条路径）；3D 预演里画整条。
#   影子车：预演结果的轨迹上跑一辆半透明的车（复制车模型、换成半透明材质）。播放约 12 s 跑完全程；
#           规划图上的影子车图标也跟着 播 走。V：在 3D 里看（世界暂停，独立追车相机），再按 V / Esc 回规划图，空格重播。
extends Node

const 播放秒 := 12.0

var B: Node
var 玩: Node
var P: Node
var 风: RefCounted
var 结果 := {}
var 播 := 0.0                                     # 0–1
var 播放 := false
var 预演中 := false
var 影车: Node3D = null
var 带: MeshInstance3D
var 带位 := Vector3(INF, 0, 0)
var 带段 := -1
var cam: Camera3D
var 前相机: Camera3D = null
var 界显 := true
var 兴卡层: CanvasLayer = null
var 层: CanvasLayer
var 字: Control
var c_pos := Vector3()


func _ready() -> void:
	B = get_parent(); 玩 = B.玩; P = B.P; 风 = B.风
	process_mode = Node.PROCESS_MODE_ALWAYS
	带 = MeshInstance3D.new(); 带.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF; P.add_child.call_deferred(带)
	var m := StandardMaterial3D.new(); m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED; m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA; m.cull_mode = BaseMaterial3D.CULL_DISABLED
	带.material_override = m
	cam = Camera3D.new(); cam.name = "预演相机"; cam.fov = 55.0; cam.near = 0.05; cam.far = 200000.0; cam.keep_aspect = Camera3D.KEEP_WIDTH
	add_child(cam)
	层 = CanvasLayer.new(); 层.layer = 46; 层.visible = false; add_child(层)
	字 = Control.new(); 字.set_anchors_preset(Control.PRESET_FULL_RECT); 字.mouse_filter = Control.MOUSE_FILTER_IGNORE; 字.draw.connect(_画字); 层.add_child(字)


# ———————————————————— 路径带
func 路带(计划: RefCounted, on: bool) -> void:
	"""整条计划（3D 预演里看）。"""
	if not on or 计划.段数() == 0: 带.mesh = null; return
	画带(计划.航点, 计划.方式, 0.0, INF)


func 执行带() -> void:
	"""执行中：从车往前沿剩下的计划画 60 m（车头前 2 m 起），车走 1.5 m 重画一次。界面 v3「丙」：航线由界面画成地面人字箭头，这里不画。"""
	var d: RefCounted = B.驾
	if d == null or B.控 == null: return
	if 风.丙(P): 带.mesh = null; 带位 = B.控.p; 带段 = int(d.段); return
	var p: Vector3 = B.控.p
	var pts: Array = [Vector2(p.x, -p.z)]; var ms: Array = []
	for i in range(int(d.段), B.计划.航点.size()):
		pts.append(B.计划.航点[i]); ms.append(B.计划.方式[i - 1])
	画带(pts, ms, 2.0, 60.0)
	带位 = p; 带段 = int(d.段)


func 画带(pts: Array, ms: Array, 起: float, 长: float) -> void:
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var 走 := 0.0; var n顶 := 0
	for i in pts.size() - 1:
		var a := Vector2(pts[i].x, -pts[i].y); var b := Vector2(pts[i + 1].x, -pts[i + 1].y)
		var m: int = int(ms[i]); var L := a.distance_to(b)
		if L < 0.01: continue
		var d := (b - a)/L; var n: Vector2 = Vector2(-d.y, d.x)*风.带宽*0.5
		var k := maxi(1, ceili(L/0.5))
		for j in k:
			var u0 := 走 + L*j/k; var u1 := 走 + L*(j + 1)/k
			if u1 < 起: continue
			if u0 > 起 + 长: break
			if m == 0 and int(u0) % 2 == 1: continue                          # 盲开：虚线（1 m 一节）
			var p0 := a + d*(L*j/k); var p1 := a + d*(L*(j + 1)/k)
			var 淡 := clampf((u0 - 起)/3.0, 0.0, 1.0)*clampf((起 + 长 - u1)/10.0, 0.0, 1.0)   # 两头淡出
			var c := Color(风.方式色[m], 风.带透明*淡)
			var q := [p0 - n, p0 + n, p1 + n, p1 - n]
			var v: Array[Vector3] = []
			for e: Vector2 in q: v.append(Vector3(e.x, 高(e.x, e.y) + 0.10, e.y))
			for t in [0, 1, 2, 0, 2, 3]: st.set_color(c); st.add_vertex(v[t])
			n顶 += 6
		走 += L
		if 走 > 起 + 长: break
	带.mesh = st.commit() if n顶 > 0 else null


func 高(x: float, z: float) -> float:
	return P.lod.h_cpu(x, z, 0) if P.lod else 0.0


# ———————————————————— 影子车
func 放(r: Dictionary, 进3D: bool) -> void:
	结果 = r; 播 = 0.0; 播放 = not r.is_empty()
	if 进3D: 进预演()


func 清() -> void:
	结果 = {}; 播放 = false; 播 = 0.0
	if 影车: 影车.visible = false
	if B.驾 == null: 带.mesh = null


func 造车() -> void:
	if 影车 or B.控 == null: return
	影车 = Node3D.new(); 影车.name = "影子车"
	var m: Node3D = B.控.model.duplicate()
	影车.add_child(m); P.add_child(影车)
	var mat := StandardMaterial3D.new(); mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = 风.影子色; mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	for g in m.find_children("*", "GeometryInstance3D", true, false):
		(g as GeometryInstance3D).material_override = mat
		(g as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func 当前点() -> Array:
	"""轨迹上 播 处的点（插值）：[E, N, t, 倾角, 电量, ψ, 风险]。"""
	var tr: Array = 结果.get("轨迹", [])
	if tr.is_empty(): return []
	var T: float = float(tr[-1][2])*播
	var i := 0
	while i < tr.size() - 2 and float(tr[i + 1][2]) < T: i += 1
	var a: Array = tr[i]; var b: Array = tr[mini(i + 1, tr.size() - 1)]
	var u := clampf((T - float(a[2]))/maxf(float(b[2]) - float(a[2]), 1e-6), 0.0, 1.0)
	var out: Array = []
	for k in a.size():
		if k == 5: out.append(lerp_angle(float(a[5]), float(b[5]), u))
		else: out.append(lerpf(float(a[k]), float(b[k]), u))
	return out


func 摆车(q: Array) -> void:
	造车()
	if 影车 == null: return
	var g: Dictionary = B.控.几何; var W: Array = g["W"]; var G: Array = g["G"]
	var x: float = q[0]; var z: float = -float(q[1]); var psi: float = q[5]
	var f := Vector3(cos(psi), 0, sin(psi)); var l := Vector3(sin(psi), 0, -cos(psi))
	var fit := Vector3()
	for i in 6:
		var c: Vector3 = Vector3(x, 0, z) + f*W[i].z + l*W[i].x
		fit += (G[i] as Vector3)*高(c.x, c.z)
	var F := (f + Vector3.UP*fit.y).normalized(); var L := (l + Vector3.UP*fit.z).normalized()
	var Y := F.cross(L).normalized(); L = Y.cross(F)
	影车.transform = Transform3D(Basis(L, Y, F), Vector3(x, fit.x, z))


func _process(dt: float) -> void:
	if B.驾 != null and not get_tree().paused and B.控 and ((B.控.p as Vector3).distance_to(带位) > 1.5 or int(B.驾.段) != 带段): 执行带()
	if 播放:
		播 = minf(1.0, 播 + dt/播放秒)
		if 播 >= 1.0: 播放 = false
		if B.图页.开着: B.图页.刷标()
	if 预演中:
		var q := 当前点()
		if not q.is_empty():
			摆车(q)
			var o := 影车.global_position + Vector3.UP*1.0
			var back := -影车.global_transform.basis.z
			var want := o + Vector3(back.x, 0, back.z).normalized()*9.0 + Vector3.UP*4.5
			want.y = maxf(want.y, 高(want.x, want.z) + 1.0)
			c_pos = c_pos.lerp(want, 1.0 - exp(-dt*3.0)) if c_pos != Vector3.ZERO else want
			cam.global_transform = Transform3D(Basis.IDENTITY, c_pos).looking_at(o, Vector3.UP)
		玩.世界更新(cam)
		字.queue_redraw()


func 进预演() -> void:
	if 结果.is_empty() or 预演中: return
	预演中 = true; 播 = 0.0; 播放 = true; c_pos = Vector3.ZERO
	造车(); 影车.visible = true
	路带(B.计划, true)
	前相机 = get_viewport().get_camera_3d(); cam.current = true
	var 界: Node = P.get_node_or_null("界面")
	if 界: 界显 = 界.visible; 界.visible = false
	B.图页.藏(true)
	兴卡层 = 玩.兴趣.层 if 玩.兴趣 else null
	if 兴卡层: 兴卡层.visible = false                                      # 导览卡先收起来
	层.visible = true


func 停预演() -> void:
	if not 预演中: return
	预演中 = false; 层.visible = false
	if 影车: 影车.visible = false
	if B.驾 == null: 带.mesh = null
	if 兴卡层: 兴卡层.visible = true
	if 前相机 and is_instance_valid(前相机): 前相机.current = true
	var 界: Node = P.get_node_or_null("界面")
	if 界: 界.visible = 界显
	B.图页.藏(false)


func 输入(ev: InputEvent) -> void:
	if not (ev is InputEventKey and ev.pressed and not ev.echo): return
	match ev.keycode:
		KEY_V, KEY_ESCAPE: 停预演()
		KEY_SPACE: 播 = 0.0; 播放 = true
	get_viewport().set_input_as_handled()


func _画字() -> void:
	var c := 字; var vs := c.size; var s: float = 风.s
	var q := 当前点()
	风.字串(c, Vector2(vs.x*0.5, 60*s), "预演 · 影子车（简化版 SSim：已知图、定步长）", 风.号["中题"], 风.白, "中", HORIZONTAL_ALIGNMENT_CENTER)
	if not q.is_empty():
		var 色q: Color = 风.红 if float(q[3]) >= B.倾角上限 else (风.琥珀 if float(q[3]) >= 20.0 else 风.白)
		风.字串(c, Vector2(vs.x*0.5, 100*s), "当地时 %s   倾角 %.1f°   电量 %.0f Wh   风险 %.2f" % [B.分到字(float(结果["结束_ltst"]) - (float(结果["用时_s"]) - float(q[2]))/B.能源脚本.LTST分),
			float(q[3]), float(q[4]), float(q[6])], 风.号["正"], 色q, "等中", HORIZONTAL_ALIGNMENT_CENTER)
	风.字串(c, Vector2(vs.x*0.5, 136*s), "停因：%s   %.0f m   用时 %.0f min" % [结果.get("停因", ""), float(结果.get("里程_m", 0)), float(结果.get("用时_s", 0))/60.0],
		20, 风.灰, "正", HORIZONTAL_ALIGNMENT_CENTER)
	风.字串(c, Vector2(vs.x*0.5, vs.y - 50*s), "V / Esc 回规划图 · 空格 重播", 风.号["次"], 风.灰, "正", HORIZONTAL_ALIGNMENT_CENTER)
