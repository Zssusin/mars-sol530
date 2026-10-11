# 扫描脉冲（界面 3 重做，参考和参数见 docs/界面/UI体系.md §7）：按一个键，车身向外扩一道细亮环，环后面的表面上世界坐标点阵依次亮起
# （坡度到注意 / 警告线的换琥珀 / 红）、起伏边缘有短促高光（界面/扫描.gdshader，全屏后处理 + 深度重建世界坐标；车不参与）；
# 环扫到的兴趣点和险坡出小标（件.小标：落点 → 立杆 → 图标 → 字），停 令.扫.留 秒后收回。
#   键：令.扫["键"]（Space）和鼠标中键，都在令牌里改；Tab 被玩法 A 的相册占了。
#   开销：空闲 = 0（后处理四边形 visible = false；_process 只倒数）；扫描中 +0.17 ms GPU。主菜单进游戏后自动放一次。
# 自测：--扫描测试=<目录>（界面/扫描测试.sh）：先量开销（不截图），再触发一次截图、断言险坡小标在屏内。--扫描录：Movie Maker 录片。
extends Node

const 着色器 := preload("res://界面/扫描.gdshader")
const 件 := preload("res://界面/件.gd")

var 界: Node
var P: Node
var 面: MeshInstance3D
var 材: ShaderMaterial
var 扫中 := false                                   # 后处理在跑
var t := 99.0                                       # 放了以后的秒数（小标比后处理活得久）
var 冷 := 0.0
var 揭: Array = []                                  # [{g, 名, 图, 行2, 色, 到, 高, 兴趣点: Dictionary / null}]
var 曝基 := 1.0
var 测 := ""


func _init(h: Node) -> void:
	界 = h; name = "扫描"


func _ready() -> void:
	P = 界.P
	process_mode = Node.PROCESS_MODE_PAUSABLE
	曝基 = P.env.tonemap_exposure if P.get("env") else 1.0
	var q := QuadMesh.new(); q.size = Vector2(2, 2)
	面 = MeshInstance3D.new(); 面.name = "扫描面"; 面.mesh = q; 面.extra_cull_margin = 16384.0
	面.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF; 面.visible = false
	材 = ShaderMaterial.new(); 材.shader = 着色器; 材.render_priority = 120
	面.material_override = 材
	P.add_child.call_deferred(面)
	令.变了.connect(设色)
	if P.args.has("扫描录"): 录.call_deferred()
	elif P.args.has("扫描测试"): 测 = String(P.args["扫描测试"]); 自测.call_deferred()


func 设色() -> void:
	if 材 == null: return
	var e: float = P.env.tonemap_exposure if P.get("env") else 1.0
	var k: float = float(令.扫["强"])*曝基/maxf(e, 1e-4)                  # 曝光补偿：自动曝光变了亮度不变（同 地面.gd）
	var 芯: Color = 令.色["主"]                                           # 环芯：主（NASA / 龙舱 / 丙 = 白）
	var 晕: Color = (令.色["活"] as Color).lerp(Color.WHITE, float(令.扫["晕白"]))
	var 点: Color = (令.色["活"] as Color).lerp(Color.WHITE, 0.4)      # 点：比环晕再亮一点的冷蓝（白点在亮橙地上对比不够）
	var 注: Color = 令.色["注意"]; var 警: Color = 令.色["警告"]
	var f := func(c: Color) -> Vector3: return Vector3(c.r, c.g, c.b)*k
	材.set_shader_parameter("u_col_core", f.call(芯)); 材.set_shader_parameter("u_col_glow", f.call(晕)*0.8)
	材.set_shader_parameter("u_col_dot", f.call(点)); 材.set_shader_parameter("u_col_edge", f.call(晕))
	var 描: Color = 令.色["活"]; 材.set_shader_parameter("u_col_out", Vector3(描.r, 描.g, 描.b)*0.8)         # 环的描边：「活」（NASA 深蓝），不乘强
	材.set_shader_parameter("u_col_warn", f.call(注)); 材.set_shader_parameter("u_col_red", f.call(警))


func 可放() -> bool:
	if 冷 > 0.0 or 扫中 or get_tree().paused or not (界 as CanvasLayer).visible: return false
	var m: Node = P.get_node_or_null("主菜单")
	return not (m != null and m.has_method("开着") and m.开着())


func _unhandled_input(ev: InputEvent) -> void:
	var 按 := false
	if ev is InputEventKey and ev.pressed and not ev.echo and ev.keycode == int(令.扫["键"]): 按 = true
	elif ev is InputEventMouseButton and ev.pressed and ev.button_index == int(令.扫["鼠标"]): 按 = true
	if 按 and 可放():
		放(); get_viewport().set_input_as_handled()


func 放() -> void:
	"""从车身放一次脉冲（键、主菜单进游戏时调）。"""
	if 扫中 or 冷 > 0.0: return
	var rr: Node3D = P.rover_root
	if rr == null: return
	var o := rr.global_position + Vector3(0, 0.8, 0)
	var t0 := Time.get_ticks_usec()
	算揭(o)
	var 算ms := (Time.get_ticks_usec() - t0)/1000.0
	材.set_shader_parameter("u_origin", o)
	var gy: float = 界.地高(rr.global_position.x, rr.global_position.z)
	材.set_shader_parameter("u_rover", Vector4(rr.global_position.x, gy, rr.global_position.z, float(令.扫["排车"])))
	材.set_shader_parameter("u_radius", float(令.扫["半径"]))
	材.set_shader_parameter("u_ring_t", float(令.扫["环时"]))
	材.set_shader_parameter("u_total", float(令.扫["时长"]))
	材.set_shader_parameter("u_pitch", float(令.扫["点距"]))
	材.set_shader_parameter("u_dot_r", float(令.扫["点径"]))
	材.set_shader_parameter("u_life", float(令.扫["命"])); 材.set_shader_parameter("u_trail", float(令.扫["尾"]))
	材.set_shader_parameter("k_ring", float(令.扫["环强"])); 材.set_shader_parameter("k_dot", float(令.扫["点强"])); 材.set_shader_parameter("k_edge", float(令.扫["边强"]))
	材.set_shader_parameter("u_slope_cos", Vector2(cos(deg_to_rad(界.倾黄)), cos(deg_to_rad(界.倾红))))
	材.set_shader_parameter("dbg", int(P.args.get("扫描调试", "0")))
	设色()
	t = 0.0; 扫中 = true; 面.visible = true
	冷 = float(令.扫["冷却"])
	print("[扫描] 放：揭 %d 个（兴趣点 %d、险坡 %d），算 %.2f ms" % [揭.size(), 揭.filter(func(r): return r["兴趣点"] != null).size(), 揭.filter(func(r): return r["兴趣点"] == null).size(), 算ms])


func 算揭(o: Vector3) -> void:
	"""环要扫到的东西：半径内的兴趣点（≥ 6 m）+ 险坡（坡度 ≥ 黄线、同一处只留最陡的，最多 4 处）。到 = 环到那里的时刻。"""
	揭.clear()
	var R := float(令.扫["半径"]); var 环t := float(令.扫["环时"])
	var o2 := Vector2(o.x, o.z)
	for m: Dictionary in 界.标记:
		if m.get("远", false): continue
		var g := Vector3(float(m["E"]), 0, -float(m["N"])); g.y = 界.地高(g.x, g.z)
		var d := Vector2(g.x, g.z).distance_to(o2)
		if d < 6.0 or d > R: continue
		var 挑 := bool(m.get("挑战", false)); var 发 := bool(m["已发现"])
		揭.append({"g": g, "名": String(m["名"]) if (发 or 挑) else "未发现", "图": "拍照" if 挑 else ("兴趣点_已发现" if 发 else "兴趣点_未发现"),
			"行2": 界.距(d), "色": 界.琥珀 if 挑 else 界.白, "到": 到时(d, R, 环t), "高": 2.2, "兴趣点": m, "距": d})
	var 候: Array = []
	var 步 := 3.0; var n := int(R/步)
	for i in range(-n, n + 1):
		for j in range(-n, n + 1):
			var x := o.x + i*步; var z := o.z + j*步
			var d := Vector2(x, z).distance_to(o2)
			if d < 5.0 or d > R*0.95: continue
			var sl: float = 界.坡度(x, z)
			if sl >= 界.倾黄: 候.append([sl, x, z, d])
	候.sort_custom(func(a, b): return a[0] > b[0])
	var 取: Array = []
	for c: Array in 候:
		var 近 := false
		for q: Array in 取:
			if Vector2(c[1], c[2]).distance_to(Vector2(q[1], q[2])) < 10.0: 近 = true; break
		if 近: continue
		取.append(c)
		if 取.size() >= 4: break
	for c: Array in 取:
		var 红: bool = c[0] >= 界.倾红
		揭.append({"g": Vector3(c[1], 界.地高(c[1], c[2]), c[2]), "名": "坡 %d°" % roundi(c[0]), "图": "倾角_警告" if 红 else "倾角_注意",
			"行2": 界.距(c[3]), "色": 界.红 if 红 else 界.琥珀, "到": 到时(c[3], R, 环t), "高": 1.6, "兴趣点": null, "距": c[3]})


func 到时(d: float, R: float, 环t: float) -> float:
	return 环t*(1.0 - pow(1.0 - clampf(d/R, 0.0, 1.0), 1.0/1.5))               # 同着色器：环到这个距离的时刻（R(t) = R·(1-(1-t/T)^1.5) 的反函数）


func 已揭(m: Dictionary) -> bool:
	for r: Dictionary in 揭:
		if r["兴趣点"] == m: return true
	return false


func _process(dt: float) -> void:
	if 冷 > 0.0 and not 扫中: 冷 = maxf(0.0, 冷 - dt)
	if t > float(令.扫["留"]) + 0.6 and not 揭.is_empty(): 揭.clear()
	if t < 1000.0: t += dt
	if 扫中:
		材.set_shader_parameter("u_t", t)
		var x := clampf(t/float(令.扫["环时"]), 0.0, 1.0)
		材.set_shader_parameter("u_speed", float(令.扫["半径"])*1.5*pow(1.0 - x, 0.5)/float(令.扫["环时"]))   # R(t) 的导数
		设色()
		面.visible = (界 as CanvasLayer).visible
		if t >= float(令.扫["时长"]):
			扫中 = false; 面.visible = false


func 画标(c: CanvasItem) -> void:
	"""界面.gd _画锚 调：画已扫到的小标。出现 = 环到了以后 0.45 s（落点 → 立杆 → 图标 → 字）；留满以后 0.3 s 收回。"""
	if 揭.is_empty(): return
	var 留 := float(令.扫["留"])
	for r: Dictionary in 揭:
		var 出 := clampf((t - float(r["到"]))/(0.45*maxf(令.动倍, 0.01)) if 令.动倍 > 0.0 else 1.0, 0.0, 1.0)
		if t > 留: 出 *= 1.0 - clampf((t - 留)/0.3, 0.0, 1.0)
		if 出 <= 0.001: continue
		var g: Vector3 = r["g"]; var 高: float = r["高"]
		var pt: Vector3 = 界.投(g + Vector3(0, 高, 0))
		if not 界.屏内(pt, 20*界.s): continue
		var 框: Rect2 = 界.杆框(pt, String(r["名"]), String(r["行2"]))
		if not 界.空(框): continue
		界.占.append(框)
		界.杆标(c, g, 高, String(r["名"]), String(r["图"]), String(r["名"]), String(r["行2"]), r["色"], 26, 0.0, 出)


# ———————————————————— 录短片（--扫描录，界面/扫描录.sh）：相机转向最近的险坡 → 放 → 看完退出
func 录() -> void:
	await get_tree().create_timer(1.5).timeout
	转向险坡()
	await get_tree().create_timer(1.5).timeout
	放()
	await get_tree().create_timer(float(令.扫["留"]) + 1.5).timeout
	P.quit_clean()


func 转向险坡() -> void:
	"""测试 / 录片用：换一台测试相机，在车后方看向最近的险坡（险坡都在高处，跟车相机抬不到那么高；这样车、环、险坡小标都在画面里）。"""
	算揭(P.rover_root.global_position + Vector3(0, 0.8, 0))
	var 近: Dictionary = {}
	for r: Dictionary in 揭:
		if String(r["图"]).begins_with("倾角") and (近.is_empty() or float(r["距"]) < float(近["距"])): 近 = r
	if 近.is_empty(): return
	var rp: Vector3 = P.rover_root.global_position; var g: Vector3 = 近["g"]
	var d := Vector3(g.x - rp.x, 0, g.z - rp.z).normalized()
	var cp := rp - d*5.0; cp.y = 界.地高(cp.x, cp.z) + 4.2
	var cam := Camera3D.new(); cam.name = "扫描测试相机"
	cam.fov = get_viewport().get_camera_3d().fov if get_viewport().get_camera_3d() else 70.0
	P.add_child(cam); cam.global_position = cp
	cam.look_at(Vector3(rp.x, 界.地高(rp.x, rp.z), rp.z).lerp(g, 0.28) + Vector3(0, 0.3, 0), Vector3.UP)   # 看向车和险坡的中间：前景是地面，险坡小标在上半屏
	cam.current = true


# ———————————————————— 自测
func 中位(a: Array) -> float:
	if a.is_empty(): return 0.0
	var b := a.duplicate(); b.sort(); return float(b[b.size()/2])


func 自测() -> void:
	await get_tree().create_timer(2.0).timeout
	DirAccess.make_dir_recursive_absolute(测)
	转向险坡(); await get_tree().create_timer(1.0).timeout
	var rid := get_viewport().get_viewport_rid(); RenderingServer.viewport_set_measure_render_time(rid, true)
	# 第一遍：只量开销（不截图，截图的回读会拖慢那几帧）；每帧 GPU 时间取中位数，扫描前后各量一次
	var 空: Array = []
	for i in 90:
		await get_tree().process_frame
		空.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
	放()
	var 扫: Array = []
	while t < float(令.扫["时长"]) - 0.1:
		await get_tree().process_frame
		if t > 0.1: 扫.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
	while 扫中: await get_tree().process_frame
	await get_tree().create_timer(float(令.扫["留"]) + 1.0).timeout                   # 小标收回
	var 后: Array = []
	for i in 90:
		await get_tree().process_frame
		后.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
	print("[扫描测试] GPU 中位数：空闲 %.3f ms；扫描中 %.3f ms（+%.3f）；扫完 %.3f ms；面 visible=%s" % [中位(空), 中位(扫), 中位(扫) - 中位(空), 中位(后), str(面.visible)])
	# 第二遍：截图
	while 冷 > 0.0: await get_tree().process_frame
	放()
	for r: Dictionary in 揭:
		var q: Vector3 = 界.投(r["g"] + Vector3(0, float(r["高"]), 0))
		print("[扫描测试]   %s %s 距 %s 到 %.2f s，屏幕 (%.0f, %.0f) z %.0f" % [r["图"], r["名"], r["行2"], r["到"], q.x, q.y, q.z])
	var 张 := 0; var 险屏 := -1; var 下一 := [0.15, 0.4, 0.7, 1.0, 1.3, 1.7, 2.4, 4.0]
	while t < 4.4:
		await get_tree().process_frame
		if 险屏 < 0 and t >= 1.8:
			险屏 = 0; var vs := get_viewport().get_visible_rect().size
			for r: Dictionary in 揭:
				if not String(r["图"]).begins_with("倾角"): continue
				var q: Vector3 = 界.投(r["g"] + Vector3(0, float(r["高"]), 0))
				if q.z > 0 and q.x > 0 and q.x < vs.x and q.y > 0 and q.y < vs.y: 险屏 += 1
		if 张 < 下一.size() and t >= 下一[张]:
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png("%s/扫描_%d_%.1fs.png" % [测, 张, t]); 张 += 1
	print("[扫描测试] %s 险坡小标在屏内 %d 个（测试相机看向最近的险坡）" % ["✓" if 险屏 >= 1 else "✗", 险屏])
	P.quit_clean()
