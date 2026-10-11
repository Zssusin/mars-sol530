# 地图台自测（--地图台测试[=目录]，界面/地图台/测试.sh）：逐项记 ✓ / ✗，存截图，最后打印汇总并退出。
#   覆盖：打开 / 关闭状态、§2 标记表、标签不重叠 ≤ 7、鼠标手感（滚轮锚点 × 三档 × 画面四角 / 地平线之上、拖动全程抓点、惯性衰减、软界弹回、双击、转台吸附）、
#         相机和软界不越界（数据方边进不了画面）、面板对比度、关闭后不漏节点、帧时间 / 三角形 / 绘制调用（最近 / 最宽）。
#   键盘和鼠标走真实输入通道（Input.parse_input_event）。--地图台样张=1 时用样张的已发现集合和选中目标。--地图台只=图：只截图 + 量性能（快）。
extends Node

var M: Node
var P: Node
var 目录 := ""
var 结果: Array = []
var 只图 := false
var 只鼠 := false
var 录 := ""
var 光标位 := Vector2(-50, -50)
var 光标层: Control = null
var k := 1.0                                         # 屏幕尺寸 / 2560（测试里的像素位置都按 2560×1440 写）


func _ready() -> void:
	M = get_parent(); P = M.P
	目录 = String(P.args.get("地图台测试", ""))
	只图 = P.args.get("地图台只", "") == "图"
	只鼠 = P.args.get("地图台只", "") == "鼠"
	录 = String(P.args.get("地图台录", ""))
	if 录 != "":
		var cl := CanvasLayer.new(); cl.layer = 120; cl.process_mode = Node.PROCESS_MODE_ALWAYS; add_child(cl)
		光标层 = Control.new(); 光标层.set_script(load("res://界面/地图台/光标.gd")); 光标层.T = self; 光标层.set_anchors_preset(Control.PRESET_FULL_RECT); 光标层.mouse_filter = Control.MOUSE_FILTER_IGNORE; cl.add_child(光标层)
	if 目录 == "" or 目录 == "1": 目录 = ProjectSettings.globalize_path("res://界面/地图台/截图")
	DirAccess.make_dir_recursive_absolute(目录)
	await get_tree().create_timer(3.0).timeout
	if 录 == "开场": await 录开场()
	elif 录 == "鼠标": await 录鼠标()
	elif 录 == "缩放": await 录缩放()
	else: await 跑()


func 等(t: float) -> void:
	await get_tree().create_timer(t, true, false, true).timeout


func 记(名: String, ok: bool, 注 := "") -> void:
	结果.append([名, ok, 注]); print("[地图台] %s %s  %s" % ["✓" if ok else "✗", 名, 注])


func 存(名: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(目录 + "/" + 名 + ".png")


func 键(kc: Key, shift := false) -> void:
	var e := InputEventKey.new(); e.keycode = kc; e.physical_keycode = kc; e.pressed = true; e.shift_pressed = shift
	Input.parse_input_event(e)
	await get_tree().process_frame
	var u := InputEventKey.new(); u.keycode = kc; u.physical_keycode = kc; u.pressed = false
	Input.parse_input_event(u)


func 滚(pos: Vector2, up: bool) -> void:
	光标位 = pos
	if 光标层: 光标层.点(pos, 0)
	var e := InputEventMouseButton.new(); e.position = pos; e.global_position = pos; e.button_index = MOUSE_BUTTON_WHEEL_UP if up else MOUSE_BUTTON_WHEEL_DOWN; e.pressed = true
	Input.parse_input_event(e)
	await get_tree().process_frame
	e = e.duplicate(); e.pressed = false; Input.parse_input_event(e)


var 上鼠 := Vector2()
func 动鼠(pos: Vector2, 键们 := 0) -> void:
	光标位 = pos
	var e := InputEventMouseMotion.new(); e.relative = pos - 上鼠; 上鼠 = pos; e.position = pos; e.global_position = pos; e.button_mask = 键们
	Input.parse_input_event(e)
	await get_tree().process_frame


func 按(pos: Vector2, btn: int, down: bool, 双 := false) -> void:
	光标位 = pos
	if down and 光标层: 光标层.点(pos, btn)
	var e := InputEventMouseButton.new(); e.position = pos; e.global_position = pos; e.button_index = btn; e.pressed = down; e.double_click = 双
	e.button_mask = (1 << (btn - 1)) if down else 0
	Input.parse_input_event(e)
	await get_tree().process_frame
	上鼠 = pos


func 设档(h: float, f: Vector2) -> void:
	M.置焦(f); M.半 = h; M.半目标 = h; M.缓动 = {}; M.锚 = null; M.滚锚 = []; M.惯 = Vector2.ZERO
	await 等(0.5)


func 设视角(az: float, el: float) -> void:
	M.方位 = az; M.方位目标 = az; M.俯仰 = el; M.俯仰目标 = el


func 文字框们() -> Array:
	return M.叠.统计["框"]


func 重叠数() -> int:
	var b: Array = 文字框们(); var n := 0
	for i in b.size():
		for j in range(i + 1, b.size()): if (b[i] as Rect2).intersects(b[j]): n += 1
	return n


func 屏点(g: Vector3) -> Vector2:
	var q: Vector3 = M.投(Vector3(g.x, g.y*M.垂放, -g.z))
	return Vector2(q.x, q.y)


func 亮度(c: Color) -> float:
	var f := func(x: float) -> float: return x/12.92 if x <= 0.04045 else pow((x + 0.055)/1.055, 2.4)
	return 0.2126*f.call(c.r) + 0.7152*f.call(c.g) + 0.0722*f.call(c.b)


func 性能(名: String) -> void:
	var rid := get_viewport().get_viewport_rid(); var vrid: RID = M.视口.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true); RenderingServer.viewport_set_measure_render_time(vrid, true)
	await 等(0.5)
	var ts: Array[float] = []; var gs: Array[float] = []
	var t0 := Time.get_ticks_usec(); var last := t0
	while (Time.get_ticks_usec() - t0) < 3000000:
		await get_tree().process_frame
		var now := Time.get_ticks_usec(); ts.append((now - last)/1000.0); last = now
		gs.append(RenderingServer.viewport_get_measured_render_time_gpu(rid) + RenderingServer.viewport_get_measured_render_time_gpu(vrid))
	ts.sort(); var 平 := 0.0
	for x in ts: 平 += x
	平 /= ts.size()
	var gp := 0.0
	for x in gs: gp += x
	gp /= gs.size()
	var tri := RenderingServer.viewport_get_render_info(vrid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)
	var dc := RenderingServer.viewport_get_render_info(vrid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)
	var tri2 := RenderingServer.viewport_get_render_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)
	var dc2 := RenderingServer.viewport_get_render_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)
	记("地图打开时每帧 < 16.7 ms（%s，%d×%d）" % [名, get_viewport().size.x, get_viewport().size.y], 平 < 16.7,
		"平均 %.2f ms，95%% %.2f ms，GPU 约 %.2f ms，脚本 %.2f ms；地图视口 %d 个三角形 %d 次绘制，界面层 %d 个三角形 %d 次绘制" % [平, ts[int(ts.size()*0.95)], gp, M.渲染时, tri, dc, tri2, dc2])


func 跑() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var 原鼠 := Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	var 能抓 := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	var 车 := Vector2(M.车E, M.车N)
	var 节0 := get_tree().get_node_count()
	k = M.尺.x/2560.0 if M.尺.x > 64 else 1.0
	await 键(KEY_M)
	await 等(0.3)
	记("M 打开：世界暂停、鼠标放开、主 3D 关闭", M.开着 and get_tree().paused and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE and get_tree().root.disable_3d)
	await 等(2.6)
	记("打开动画走完", M.态 == "开", "钟 %.2f" % M.钟)
	await 等(0.5)
	await 存("默认视角")
	var 默方 := M.默认方位() as float
	if 只鼠:
		await 鼠标手感(车)
		var 败0 := 0
		for r in 结果: if not r[1]: 败0 += 1
		print("[地图台] 汇总：%d 项，%d 项没过" % [结果.size(), 败0])
		P.quit_clean(); return
	# ——— 五档 + 低俯朝坑缘（截图）
	var t样 := [["100m", 100.0], ["200m", 200.0], ["500m", 500.0], ["2km", 2000.0], ["10km", 10000.0], ["25km", 25000.0], ["最宽", -1.0]]
	var 档表: Dictionary = {}
	for it in t样:
		设视角(默方, M.默认俯仰)
		var h: float = it[1]
		if h < 0.0: M.置焦(车); h = M.半上限()
		elif h > M.半上限(): h = M.半上限()
		await 设档(h, 车)
		await 等(0.5)
		await 存("档_" + it[0])
		var 显: Dictionary = M.叠.显示.duplicate(true)
		档表[it[0]] = 显
		var n: int = M.叠.统计["文字"]
		记("文字标签 ≤ 7（%s，半宽 %.0f m）" % [it[0], M.半], n <= 7, "%d 个" % n)
		记("标签 / 簇徽不重叠（%s）" % it[0], 重叠数() == 0, "%d 对重叠" % 重叠数())
		print("[地图台] 显示 %s：%s" % [it[0], str(显)])
	设视角(默方, 10.0); await 设档(6000.0, 车); await 等(0.4); await 存("低俯_朝坑缘")
	设视角(180.0, 56.0); await 设档(M.半上限(), 车); await 等(0.4); await 存("指北_最宽")
	设视角(180.0, 85.0); await 设档(M.半上限(), 车); await 等(0.4); await 存("正俯_最宽")
	var 界 := M.焦界() as float
	设视角(默方, 16.0); await 设档(M.半上限(), Vector2(界, 界)); await 等(0.4); await 存("边角_最宽")
	设视角(默方 + 180.0, 12.0); await 设档(M.半上限(), Vector2(-界, 界)); await 等(0.4); await 存("边角_背向")
	# ——— 相机 / 软界不越界（数据方边进不了画面）：全部俯仰 × 方位 × 焦点位置，把半宽拉到 半上限() 后相机的位置和高度
	var 越界 := 0; var 组合 := 0; var 最远 := 0.0; var 最高 := 0.0
	for el in [10.0, 16.0, 30.0, 56.0, 85.0]:
		for az in [0.0, 90.0, 180.0, 270.0, 45.0]:
			for f in [Vector2.ZERO, Vector2(界, 界), Vector2(-界, 界), Vector2(界, -界), Vector2(0, 界)]:
				M.置焦(f); M.俯仰 = el; M.俯仰目标 = el; M.方位 = az; M.方位目标 = az
				var up: float = M.半上限(); M.半 = up; M.半目标 = up; M.摆机()
				var 平远: float = maxf(absf(M.机位.x), absf(M.机位.z)); var 高: float = M.机位.y - M.焦高
				最远 = maxf(最远, 平远); 最高 = maxf(最高, 高); 组合 += 1
				if 平远 > M.机位界比*M.数据半宽 + 50.0 or 高 > M.高界比*M.数据半宽 + 50.0: 越界 += 1
	记("相机最远处不出界（%d 种俯仰 × 方位 × 焦点）" % 组合, 越界 == 0, "相机离中心最远 %.1f km（界 %.0f），最高 %.1f km（界 %.0f）" % [最远/1000.0, M.机位界比*M.数据半宽/1000.0, 最高/1000.0, M.高界比*M.数据半宽/1000.0])
	设视角(默方, M.默认俯仰)
	# ——— §2 表（只验「某类有没有」）
	var 远: Dictionary = 档表["25km"]; var 中: Dictionary = 档表["2km"]; var 近: Dictionary = 档表["200m"]
	记("§2 远档：路线上不画 sol 点、不画兴趣点菱形", 远["路点"] == 0 and 远["发现"] == 0 and 远["未发现"] == 0, str(远))
	记("§2 中档：有 sol 点（100 的倍数，≤ 5）和兴趣点", 中["路点"] >= 1 and 中["路点"] <= 5 and (中["发现"] + 中["未发现"] + 中["簇员"]) >= 1, "sol 点 %d，兴趣点 %d 簇 %d（%d 个）" % [中["路点"], 中["发现"] + 中["未发现"], 中["簇"], 中["簇员"]])
	记("§2 中档地名：三角洲前缘、陨石坑底；远档：杰泽罗陨石坑；近档：无", ("三角洲前缘" in 中["地名"]) and ("陨石坑底" in 中["地名"]) and ("杰泽罗陨石坑" in 远["地名"]) and 近["地名"].is_empty(), "中 %s 远 %s 近 %s" % [中["地名"], 远["地名"], 近["地名"]])
	记("§2 等高线数字：远 0、中 ≤ 6、近 ≤ 8", 远["等高数"] == 0 and 中["等高数"] <= 6 and 近["等高数"] <= 8, "%d / %d / %d" % [远["等高数"], 中["等高数"], 近["等高数"]])
	var 近点 := 0
	for p in M.点表():
		if p["类"] != "远" and Vector2(p["E"] - 车.x, p["N"] - 车.y).length() < 200.0: 近点 += 1
	var 近见: int = 近["发现"] + 近["未发现"] + 近["簇员"]
	记("§2 近档（半宽 200 m）：车周围 200 m 内的兴趣点都有菱形 / 簇徽，不再整体消失", 近见 >= 近点 and 近点 > 0, "应有 %d，画了菱形 %d + 簇内 %d" % [近点, 近["发现"] + 近["未发现"], 近["簇员"]])
	记("§2 近档：车是真实尺寸脚印（画面上有 3 对轮子、车头箭头）——见截图 档_100m / 档_200m", true, "目视项")
	if not 只图:
		await 鼠标手感(车)
	# ——— 性能：最近 / 最宽
	设视角(默方, M.默认俯仰)
	await 设档(M.半最小, 车); await 性能("最近 ±100 m")
	await 设档(M.半上限(), 车); await 性能("最宽 ±%.0f km" % (M.半上限()/1000.0))
	await 设档(M.半默认, 车); await 性能("默认 ±2 km")
	if not 只图:
		# ——— 对比度：面板后面的地图压暗之后，文字对背景 p95 的比值
		await 对比度()
		# ——— 开关泄漏
		await 键(KEY_ESCAPE); await 等(1.0)
		记("Esc 关闭：世界继续、鼠标状态还原、主 3D 恢复", (not M.开着) and (not get_tree().paused) and (Input.mouse_mode == 原鼠 or (not 能抓)) and not get_tree().root.disable_3d, "鼠标 %d（原 %d，虚拟显示能抓：%s）" % [Input.mouse_mode, 原鼠, 能抓])
		var 节1 := get_tree().get_node_count()
		for i in 4:
			await 键(KEY_M); await 等(3.0); await 键(KEY_ESCAPE); await 等(1.0)
		var 节2 := get_tree().get_node_count()
		记("开关 4 次不漏节点", 节2 <= 节1 + 2, "节点 %d → %d → %d" % [节0, 节1, 节2])
	var 败 := 0
	for r in 结果: if not r[1]: 败 += 1
	print("[地图台] 汇总：%d 项，%d 项没过" % [结果.size(), 败])
	P.quit_clean()


func 对比度() -> void:
	"""面板区域：地图（不含 2D 层）按垫板的不透明度压暗后的 p95 亮度，对正文白字 / 次要文字。"""
	var 底: Color = 令.色["页底"]; var 主: Color = 令.色["主"]; var 次: Color = 令.色["次"]
	var a := 0.9
	for 档 in [["2 km", 2000.0], ["200 m", 200.0], ["最宽", -1.0]]:
		var h: float = 档[1]
		if h < 0.0: h = M.半上限()
		await 设档(h, Vector2(M.车E, M.车N)); await 等(0.4)
		await RenderingServer.frame_post_draw
		var img: Image = M.视口.get_texture().get_image()
		for pb in M.叠.垫板们:
			var r: Rect2 = pb[0]; var ls: Array[float] = []
			var x0 := int(r.position.x); var y0 := int(r.position.y)
			var x1 := mini(int(r.end.x), img.get_width() - 1); var y1 := mini(int(r.end.y), img.get_height() - 1)
			var step := 4
			for y in range(maxi(y0, 0), y1, step):
				for x in range(maxi(x0, 0), x1, step):
					var c := img.get_pixel(x, y)
					var m := Color(c.r*(1.0 - a) + 底.r*a, c.g*(1.0 - a) + 底.g*a, c.b*(1.0 - a) + 底.b*a)
					ls.append(亮度(m))
			ls.sort(); var p95: float = ls[int(ls.size()*0.95)]
			var 比主 := (亮度(主) + 0.05)/(p95 + 0.05); var 比次 := (亮度(次) + 0.05)/(p95 + 0.05)
			记("对比度 %s·%s：正文 ≥ 7:1、次要文字 ≥ 4.5:1" % [档[0], pb[1]], 比主 >= 7.0 and 比次 >= 4.5, "p95 亮度 %.3f，正文 %.1f:1，次要 %.1f:1" % [p95, 比主, 比次])


# ———————————————————— 鼠标手感
func 鼠标手感(车: Vector2) -> void:
	var 默方 := M.默认方位() as float
	var 角 := [Vector2(1280, 800), Vector2(260, 330), Vector2(1960, 330), Vector2(260, 1260), Vector2(1960, 1260)]
	# 滚轮锚点：三档 × 中心 + 画面四角（低俯角时上面两角是远处 / 地平线之上：用「沿视线、半×8 处的地面点」当锚）
	for 半0 in [200.0, 2000.0, 20000.0]:
		设视角(默方, M.默认俯仰)
		var 最大 := 0.0; var 次数 := 0; var 兜底 := 0; var 缩了 := true; var 坏 := ""
		for c in 角:
			var pos: Vector2 = c*k
			await 设档(minf(半0, M.半上限()), 车); await 等(0.2)
			await 动鼠(pos); await 等(0.15)
			var a: Array = M.取锚(pos)
			if a.is_empty(): 兜底 += 1; continue
			if (a[1] as Vector2).distance_to(pos) > 0.5: 兜底 += 1
			var g: Vector3 = a[0]; var 目屏: Vector2 = a[1]
			var h0: float = M.半
			for dir in [true, true, false, false]:
				await 滚(pos, dir)
				await 等(0.6)
				var d := 屏点(g).distance_to(目屏)
				if not is_finite(d): d = 1e9
				if d > 最大: 最大 = d; 坏 = "%s %s" % [str(c), "进" if dir else "出"]
				if d > 2.0: print("[地图台] 调试：位置 %s %s g=%s 目屏=%s 现屏=%s 半=%.1f 半目标=%.1f 焦=%s 俯仰=%.1f 锚=%s 滚锚空=%s" % [str(c), "进" if dir else "出", str(g), str(目屏), str(屏点(g)), M.半, M.半目标, str(M.焦), M.俯仰, str(M.锚), str(M.滚锚.is_empty())])
				次数 += 1
			if absf(M.半/h0 - 1.0) > 0.02 and M.半目标 > M.半上限()*0.97 == false and 半0 < 15000.0: 缩了 = false
		记("滚轮缩放：钉住的地面点位移 < 2 px（半宽 %.0f m，中心 + 四角 × 进出各 2 格）" % minf(半0, M.半上限()), 最大 < 2.0 and 缩了, "最大 %.2f px（%s），%d 次，其中 %d 次因地平线 / 太远用兜底锚，缩放回到原值：%s" % [最大, 坏, 次数, 兜底, str(缩了)])
	# 光标在地平线之上
	设视角(默方, 10.0)
	await 设档(2000.0, 车); await 等(0.3)
	var 天 := Vector2(1280, 150)*k
	await 动鼠(天); await 等(0.2)
	var 屏天: Variant = M.屏到地(天)
	var 半前: float = M.半
	var 锚天: Array = M.取锚(天)
	var 有锚 := not 锚天.is_empty()
	await 滚(天, true); await 等(0.6)
	var 漂: float = 屏点(锚天[0]).distance_to(锚天[1]) if 有锚 else 0.0
	记("光标在地平线之上滚轮：光标下没有地面（%s），改用沿视线 半×8 处的点缩放，不抖不炸" % ("null" if 屏天 == null else "有"), 屏天 == null and 有锚 and is_finite(M.半) and M.半 < 半前*0.9 and 漂 < 2.0, "半宽 %.0f → %.0f，锚点漂 %.2f px" % [半前, M.半, 漂])
	var 焦前: Vector2 = M.焦
	await 按(天, MOUSE_BUTTON_LEFT, true)
	for i in 10: await 动鼠(天 + Vector2(-12, 8)*(i + 1)*k, 1)
	await 按(天 + Vector2(-120, 80)*k, MOUSE_BUTTON_LEFT, false); await 等(0.3)
	记("光标在地平线之上拖动：焦点不被甩飞（位移有界、数值有限）", M.焦.is_finite() and (M.焦 - 焦前).length() < M.半*6.0, "焦点动了 %.0f m（半宽 %.0f m）" % [(M.焦 - 焦前).length(), M.半])
	# 左键拖动全程抓点：两档
	for 半0 in [2000.0, 200.0]:
		设视角(默方, M.默认俯仰)
		await 设档(半0, 车); await 等(0.3)
		var p0 := Vector2(1200, 1000)*k; var g0: Variant = M.屏到地(p0)
		await 动鼠(p0); await 按(p0, MOUSE_BUTTON_LEFT, true)
		var 最大 := 0.0
		for i in 24:
			var pp := p0 + Vector2(-10, -7)*(i + 1)*k
			await 动鼠(pp, 1)
			最大 = maxf(最大, 屏点(g0).distance_to(pp))
		记("左键拖动：抓住的点全程跟着光标 < 2 px（半宽 %.0f m，24 步）" % 半0, 最大 < 2.0, "最大偏差 %.2f px" % 最大)
		# 惯性：松手前速度稳定，松手后 0.25 s 剩 ≈ 37 %
		var 末 := p0 + Vector2(-240, -168)*k
		await 按(末, MOUSE_BUTTON_LEFT, false)
		var v0: float = M.惯.length(); var 焦后: Vector2 = M.焦
		await 等(0.25)
		var v1: float = M.惯.length()
		await 等(0.75)
		var v2: float = M.惯.length()
		var 滑: float = (M.焦 - 焦后).length()
		var 比 := v1/maxf(v0, 1e-6)
		记("松手有惯性，速度按 0.25 s 衰减（半宽 %.0f m）" % 半0, v0 > 1.0 and 比 > 0.28 and 比 < 0.48 and v2/maxf(v0, 1e-6) < 0.03 and 滑 > 1.0, "初速 %.0f m/s，0.25 s 后 %.0f %%，1 s 后 %.1f %%，滑了 %.0f m" % [v0, 比*100.0, v2/maxf(v0, 1e-6)*100.0, 滑])
	# 软界回弹
	设视角(180.0, 56.0)
	var L: float = M.焦界()
	await 设档(2000.0, Vector2(L - 100.0, 0.0)); await 等(0.3)
	var q0 := Vector2(1500, 900)*k
	await 动鼠(q0); await 按(q0, MOUSE_BUTTON_LEFT, true)
	for i in 30: await 动鼠(q0 + Vector2(-24, 0)*(i + 1)*k, 1)
	var 外拖: float = M.软界外
	await 等(0.25)                                                 # 停住不动再松手，免得惯性混进来
	await 按(q0 + Vector2(-720, 0)*k, MOUSE_BUTTON_LEFT, false)
	var 外松: float = M.软界外
	await 等(0.2)
	var 外后: float = M.软界外
	await 等(0.1)
	var 外三: float = M.软界外
	await 等(0.6)
	var 外终: float = M.软界外
	记("拖过软界：有阻力（超出量 < 无阻力的 60 %）、松手 0.3 s 内弹回 90 %、之后回到界内", 外拖 > 1.0 and 外松 > 1.0 and 外三 < 外松*0.1 and 外终 < 1.0, "拖到超出 %.0f m，松手时 %.0f m，0.2 s 后 %.0f m，0.3 s 后 %.0f m，0.9 s 后 %.1f m（界 %.0f m；τ = 0.07 s，理论 0.2 s 剩 6 %%，测得偶尔慢于理论，原因没查）" % [外拖, 外松, 外后, 外三, 外终, L])
	# 双击
	设视角(默方, M.默认俯仰)
	await 设档(2000.0, 车); await 等(0.3)
	var dp := Vector2(1000, 1000)*k; var dg: Variant = M.屏到地(dp); var 半d: float = M.半
	await 动鼠(dp)
	await 按(dp, MOUSE_BUTTON_LEFT, true, true); await 按(dp, MOUSE_BUTTON_LEFT, false)
	await 等(0.5)
	var 到 := Vector2(dg.x, dg.z) if dg != null else Vector2.ZERO
	记("双击地面：缩放一档（×0.64）并把该点移到中心（0.3 s）", dg != null and absf(M.半/半d - 0.64) < 0.03 and (M.焦 - 到).length() < 3.0, "半宽 %.0f → %.0f，焦点离目标 %.1f m" % [半d, M.半, (M.焦 - 到).length() if dg != null else -1.0])
	# 右键转台、吸附
	设视角(170.0, M.默认俯仰); M.缓动 = {}
	var 方0: float = M.方位
	await 动鼠(Vector2(1200, 700)*k)
	await 按(Vector2(1200, 700)*k, MOUSE_BUTTON_RIGHT, true)
	for i in 6: await 动鼠(Vector2(1200 + 8*(i + 1), 700)*k, 2)
	await 存("右键转台中")
	记("右键拖动转台", absf(M.方位 - 方0) > 3.0 and absf(M.方位 - 方0) < 20.0, "方位 %.1f° → %.1f°" % [方0, M.方位])
	await 按(Vector2(1248, 700)*k, MOUSE_BUTTON_RIGHT, false)
	await 等(0.5)
	记("松手离正北 5° 内吸附正北", absf(M.方位 - 180.0) < 0.5, "方位 %.2f°" % M.方位)
	# 选中
	设视角(默方, M.默认俯仰)
	await 设档(2000.0, 车); await 等(0.4)
	M.选("three_forks"); await 等(0.6); await 存("选中_Three_Forks")
	记("选中目标：镜头缓动到能同时看见车和目标", M.选中 == "three_forks" and M.半目标 < 2000.0, "半宽 %.0f" % M.半目标)


# ———————————————————— 录屏（--地图台录=开场|鼠标，配合 Movie Maker；见 录.sh）。光标是画上去的（光标.gd）。
func 移到(目标: Vector2, 秒: float, 键们 := 0) -> void:
	var 起 := 光标位 if 光标位.x > 0 else 目标
	var n := maxi(2, int(秒*30.0))
	for i in n:
		var t := float(i + 1)/n; t = t*t*(3.0 - 2.0*t)
		await 动鼠(起.lerp(目标, t), 键们)


func 录开场() -> void:
	k = M.尺.x/2560.0
	await 等(0.8)
	await 键(KEY_M)
	await 等(4.4)
	await 键(KEY_ESCAPE); await 等(0.6)
	P.quit_clean()


func 找(前缀: String) -> Vector2:
	for e in M.叠.命中表:
		if str(e[1]) == 前缀: return (e[0] as Rect2).get_center()
	return Vector2(-1, -1)


func 录缩放() -> void:
	"""查缩放时画面抖不抖：滚轮进 5 格、出 5 格，每格之间隔 3 帧存一张（缩_NNN.png），拿来逐帧对比。"""
	k = M.尺.x/2560.0
	设视角(M.默认方位(), M.默认俯仰)
	await 键(KEY_M)
	await 等(4.0)
	var c := Vector2(1100, 760)*k; var n := 0
	for up in [true, false]:
		for i in 5:
			await 滚(c, up)
			for j in 4:
				for f in 3: await get_tree().process_frame
				await 存("缩_%03d" % n); n += 1
	get_tree().quit()


func 录鼠标() -> void:
	k = M.尺.x/2560.0
	设视角(M.默认方位(), M.默认俯仰)
	await 键(KEY_M)
	await 等(4.0)
	var c := Vector2(1100, 880)*k
	await 移到(c, 0.6)
	await 等(0.3)
	for i in 4:                                               # 滚轮放大（光标下的点不动）
		await 滚(c, true); await 等(0.35)
	await 等(0.5)
	for i in 5:
		await 滚(c, false); await 等(0.3)
	await 等(0.6)
	var c2 := Vector2(1500, 900)*k                            # 左键拖动，松手有惯性
	await 移到(c2, 0.4); await 按(c2, MOUSE_BUTTON_LEFT, true)
	await 移到(c2 + Vector2(-520, -150)*k, 0.35, 1)
	await 按(c2 + Vector2(-520, -150)*k, MOUSE_BUTTON_LEFT, false)
	await 等(1.4)
	var r0 := Vector2(1100, 700)*k                            # 右键转台，离正北 5° 内吸附
	await 移到(r0, 0.4); await 按(r0, MOUSE_BUTTON_RIGHT, true)
	await 移到(r0 + Vector2(-320, 40)*k, 0.9, 2)
	await 按(r0 + Vector2(-320, 40)*k, MOUSE_BUTTON_RIGHT, false)
	await 等(1.0)
	await 键(KEY_N); await 等(1.2)
	await 键(KEY_N); await 等(1.0)
	var 点位 := 找("点:hawksbill_gap")                        # 悬停标记
	if 点位.x < 0: 点位 = 找("点:three_forks")
	if 点位.x > 0:
		await 移到(点位, 0.6); await 等(1.2)
	var 行位 := 找("行:three_forks")                           # 点表格行
	if 行位.x > 0:
		await 移到(行位, 0.7); await 等(0.4)
		await 按(行位, MOUSE_BUTTON_LEFT, true); await 按(行位, MOUSE_BUTTON_LEFT, false)
		await 等(1.6)
	var d := Vector2(900, 800)*k                              # 双击放大
	await 移到(d, 0.6); await 等(0.2)
	await 按(d, MOUSE_BUTTON_LEFT, true, true); await 按(d, MOUSE_BUTTON_LEFT, false)
	await 等(1.4)
	await 键(KEY_ESCAPE); await 等(0.8)
	P.quit_clean()
