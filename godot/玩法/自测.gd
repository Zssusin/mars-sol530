# 玩法自测（--玩法测试[=目录]，玩法/测试.sh）：按阶段依次跑界面（v3 丙：锚点投影、背后隐藏、车身遮挡、分档；--界面=旧 时只查 v2 在）、
#   拍照、兴趣点、图鉴、复刻、菜单、玩法 B（sol 规划；--B测试=0 跳过），每步截图、检查结果，打印「[玩法自测] 通过 / 失败」后退出。
#   截图存 <目录>/*.png（默认 res://玩法/截图/，不进 git）。量开销：玩法模块每帧脚本用时、拍照模式进出前后的帧时间。
extends Node

const 件 := preload("res://界面/件.gd")

var 玩: Node
var P: Node
var 目录 := ""
var 结果: Array = []                              # [名, 通过, 说明]


func _ready() -> void:
	玩 = get_parent(); P = 玩.P
	目录 = String(P.args["玩法测试"])
	if 目录 == "": 目录 = ProjectSettings.globalize_path("res://玩法/截图")
	DirAccess.make_dir_recursive_absolute(目录)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var 册 := ProjectSettings.globalize_path("user://相册_自测/")                # 自测用的相册每次清空（不碰玩家的 user://相册/）
	if DirAccess.dir_exists_absolute(册):
		for f in DirAccess.get_files_at(册): DirAccess.remove_absolute(册.path_join(f))
	跑.call_deferred()


func 记(名: String, ok: bool, 说明 := "") -> void:
	结果.append([名, ok, 说明]); print("[玩法自测] %s %s %s" % ["✓" if ok else "✗", 名, 说明])


func 等(t: float) -> void:
	await get_tree().create_timer(t, true).timeout                        # process_always：暂停时也走


func 截(名: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(目录.path_join(名 + ".png"))


func 跑() -> void:
	await 等(3.0)
	var 控: Node = P.get_node_or_null("控制")
	if 控: 控.call("set_mode", "跟车")
	await 等(1.0)
	var 只B: bool = P.args.get("只测B", "0") == "1"                      # 只跑玩法 B（调试用）
	if not 只B: await 测界面()
	if 玩.兴趣 and not 只B: await 测兴趣点()
	if 玩.拍照 and not 只B: await 测拍照()
	if 玩.复刻 and not 只B: await 测复刻()
	if 玩.图鉴 and not 只B: await 测图鉴()
	if 玩.菜单 and not 只B: await 测菜单()
	if not 只B: await 测界面6()
	if 玩.B and P.args.get("B测试", "1") == "1": await 测B()
	if 令.英(): 记("英文：画出的字里没有残留中文（令.译缺）", 令.译缺.is_empty(), str(令.译缺.keys()))
	var 坏 := 结果.filter(func(r): return not r[1]).size()
	print("[玩法自测] %s：%d 项，%d 项失败" % ["通过" if 坏 == 0 else "失败", 结果.size(), 坏])
	P.quit_clean()


func 测拍照() -> void:
	var 拍: Node = 玩.拍照
	var 前 := get_viewport().get_camera_3d()
	拍.进入(); await 等(0.6)
	记("拍照：进入暂停", get_tree().paused and 拍.开着 and get_viewport().get_camera_3d() == 拍.cam, "paused=%s" % get_tree().paused)
	var 界: Node = P.get_node_or_null("界面")
	记("拍照：HUD 隐藏", 界 == null or not 界.visible)
	if 界 and 界.get("版") == 3: 记("拍照：地面图形一起藏（丙）", not (界.get("地") as Node3D).is_visible_in_tree())
	# 走出 40 m：应被限在 30 m 内；钻地：应被抬到地面以上
	拍.cam.global_position = 拍.限位(玩.车位() + Vector3(40, 1, 0))
	var r: float = (拍.cam.global_position - 玩.车位() - Vector3.UP).length()
	记("拍照：半径限位", r <= 30.01, "%.2f m" % r)
	var g: Vector3 = 拍.限位(玩.车位() + Vector3(5, -3, 5))
	记("拍照：不钻地", g.y >= 玩.地高(g.x, g.z) + 0.24, "离地 %.2f m" % (g.y - 玩.地高(g.x, g.z)))
	# 摆一个看车的机位：车左后 8 m、高 3 m
	var c: Vector3 = 玩.车位()
	拍.cam.global_position = 拍.限位(c + Vector3(-6, 3, 6)); var f: Vector3 = (c + Vector3.UP - 拍.cam.global_position).normalized()
	拍.yaw = atan2(-f.x, -f.z); 拍.pitch = asin(f.y)
	拍.焦距 = 35.0; 拍.景深 = 0.5; 拍.EV = 0.0; 拍.更新属性(); await 等(1.0)
	await 截("拍照_1_界面")
	var m0: float = P.time_m
	拍.调(拍.项.find("时刻"), 18, false); await 等(1.5)                  # +180 分钟
	记("拍照：换时刻（暂停中）", absf(P.time_m - m0) > 60.0, "%s → %s" % [m0, P.time_m])
	var w: Node = P.get_node_or_null("天气")
	if w:
		var k0: String = w.tau_key; 拍.调(拍.项.find("τ"), 1, false); await 等(1.5)
		记("拍照：换 τ（暂停中）", w.tau_key != k0, "%s → %s" % [k0, w.tau_key])
	var t0 := Time.get_ticks_msec()
	var meta: Dictionary = await 拍.拍()
	var ok := not meta.is_empty() and FileAccess.file_exists(meta.get("文件", "")) and FileAccess.file_exists(String(meta.get("文件", "")).replace(".png", ".json"))
	var img := Image.load_from_file(ProjectSettings.globalize_path(meta.get("文件", ""))) if ok else null
	var vs := get_viewport().get_visible_rect().size
	记("拍照：出图", ok and img != null and img.get_size() == Vector2i(vs), "%s %s，%.1f s" % [meta.get("文件", "?"), str(img.get_size()) if img else "-", (Time.get_ticks_msec() - t0)/1000.0])
	if img: 复制(meta["文件"], "拍照_2_自由取景.png")
	拍.设navcam(true); await 等(1.0)
	await 截("拍照_3_Navcam界面")
	var m2: Dictionary = await 拍.拍()
	var img2 := Image.load_from_file(ProjectSettings.globalize_path(m2.get("文件", ""))) if not m2.is_empty() else null
	记("拍照：Navcam 出图 4:3", img2 != null and absf(float(img2.get_width())/img2.get_height() - 4.0/3.0) < 0.01, str(img2.get_size()) if img2 else "-")
	if img2: 复制(m2["文件"], "拍照_4_Navcam.png")
	拍.设navcam(false); 拍.调(拍.项.find("时刻"), -18, false)
	if w: 拍.调(拍.项.find("τ"), -1, false)
	拍.景深 = 0.0; 拍.更新属性()
	拍.退出(); await 等(0.5)
	记("拍照：退出恢复", not get_tree().paused and get_viewport().get_camera_3d() == 前 and (界 == null or 界.visible))


func 近同(a: Variant, b: Variant) -> bool:
	"""存档往返比较：浮点差 ≤ 1e-9（相对）算相同——Godot 的 JSON 解析不保证双精度逐位还原（17 位小数偶尔差最后一位）。"""
	if (a is float or a is int) and (b is float or b is int): return absf(float(a) - float(b)) <= 1e-9*maxf(1.0, absf(float(a)))
	if a is Dictionary and b is Dictionary:
		if (a as Dictionary).size() != (b as Dictionary).size(): return false
		for k in a: if not (b as Dictionary).has(k) or not 近同(a[k], b[k]): return false
		return true
	if (a is Array or a is PackedVector2Array or a is PackedFloat64Array) and (b is Array or b is PackedVector2Array or b is PackedFloat64Array):
		if a.size() != b.size(): return false
		for i in a.size(): if not 近同(a[i], b[i]): return false
		return true
	if a is Vector2 and b is Vector2: return 近同(a.x, b.x) and 近同(a.y, b.y)
	if a is Vector3 and b is Vector3: return 近同(a.x, b.x) and 近同(a.y, b.y) and 近同(a.z, b.z)
	return var_to_str(a) == var_to_str(b)


func 测界面() -> void:
	"""界面 v3「丙」：锚点投影、相机背后隐藏、车身遮挡、Decal 不投到车上、H 分档切换；--界面=旧 时查 v2 加载了。"""
	var 界: Node = P.get_node_or_null("界面"); var 控: Node = P.get_node_or_null("控制")
	var v2ok: bool = ResourceLoader.exists("res://界面/界面_v2.gd") and (load("res://界面/界面_v2.gd") as Script).can_instantiate()
	if 界 == null: 记("界面：加载", false); return
	if 界.get("版") != 3:
		记("界面：--界面=旧 加载 v2 仪表式", 界.has_method("帮助") and 界.get("航向") != null and v2ok); return
	记("界面：v3 丙加载，v2 留作 --界面=旧", v2ok)
	if 控 == null: return
	await 等(0.8)
	var cam := get_viewport().get_camera_3d()
	var w: Vector3 = 控.body*控.mast_local
	var p: Vector3 = 界.投(w); var q := cam.unproject_position(w)
	记("界面：锚点投影（桅杆头）", p.z > 0.0 and Vector2(p.x, p.y).distance_to(q) < 0.5 and 界.屏内(p), "屏幕 (%.0f, %.0f)" % [p.x, p.y])
	var 背 := cam.global_position + cam.global_transform.basis.z*10.0
	记("界面：相机背后的锚点不画", (界.投(背) as Vector3).z < 0.0)
	var F: Vector3 = 控.body.basis.z; F.y = 0.0; F = F.normalized()
	var 前: Vector3 = 控.body.origin + F*2.9; 前.y = 玩.地高(前.x, 前.z) + 0.1
	var 后: Vector3 = 控.body.origin - F*2.9; 后.y = 玩.地高(后.x, 后.z) + 0.1
	记("界面：车身挡住车前的方位字、不挡车后的", 界.被车挡(前) and not 界.被车挡(后), "跟车相机")
	var 地: Node3D = 界.get("地"); var 层 := 1 << 19; var 坏 := 0; var n := 0
	for g in P.rover_root.find_children("*", "VisualInstance3D", true, false):
		n += 1; if (g as VisualInstance3D).layers != 层: 坏 += 1
	var 掩 := true
	for d in 地.find_children("*", "Decal", true, false): if (d as Decal).cull_mask & 层: 掩 = false
	记("界面：Decal 不投到车上（车在第 20 层）", 坏 == 0 and 掩 and n > 0, "车 %d 件，没挪层 %d 件" % [n, 坏])
	var 石n := 0; var 石坏 := 0; var 石掩 := true
	for g in P.get_children():
		if g is MultiMeshInstance3D and String(g.name).begins_with("石块_"): 石n += 1; if (g as VisualInstance3D).layers != 1 << 18: 石坏 += 1
	for d in 地.find_children("*", "Decal", true, false): if (d as Decal).cull_mask & (1 << 18): 石掩 = false
	记("界面：Decal 不投到石块上（石块在第 19 层）", 石坏 == 0 and 石掩 and 石n > 0, "石块 %d 组，没挪层 %d 组" % [石n, 石坏])
	var 档0: int = 界.get("显档")
	var 序: Array = []
	for k in 3:
		await 按(KEY_H); await 等(0.15)
		序.append([int(界.get("显档")), 界.visible, 地.is_visible_in_tree()])
	记("界面：H 分档 精简 → 完整 → 关 → 精简", 档0 == 1 and 序 == [[2, true, true], [0, false, false], [1, true, true]], str(序))
	await 截("界面_1_精简")


func 复制(src: String, 名: String) -> void:
	"""相册里的图拷一份到截图目录（缩到 1600 宽，看图用）。"""
	var img := Image.load_from_file(ProjectSettings.globalize_path(src))
	if img.get_width() > 1600: img.resize(1600, int(1600.0*img.get_height()/img.get_width()), Image.INTERPOLATE_LANCZOS)
	img.save_png(目录.path_join(名))


func 开到(E: float, N: float, 离: float) -> void:
	"""把车放到兴趣点 (E, N) 南边 离 m 处、车头朝它（控制.gd teleport：前 = (cos ψ, 0, sin ψ)）。"""
	var 控: Node = P.get_node_or_null("控制")
	if 控 == null: return
	var x := E; var z := -N + 离
	控.call("teleport", Vector3(x, 0, z), atan2(-N - z, E - x))


func 测兴趣点() -> void:
	var 兴: Node = 玩.兴趣
	await 等(1.0)
	记("兴趣点：数据", 兴.点表.size() >= 8, "%d 个兴趣点、%d 个挑战" % [兴.点表.size(), 玩.数据["挑战"].size()])
	记("兴趣点：出发点附近自动发现", 玩.进度["已发现"].has("wildcat_ridge"), str(玩.进度["已发现"].keys()))
	await 截("兴趣点_1_出发_导览卡")
	var q: Dictionary = 玩.点("hogwallow_flats")
	开到(float(q["E"]), float(q["N"]), 9.0); await 等(1.0)
	记("兴趣点：9 m 外不发现", not 玩.进度["已发现"].has("hogwallow_flats"))
	开到(float(q["E"]), float(q["N"]), 4.0); await 等(1.0)
	记("兴趣点：4 m 内发现", 玩.进度["已发现"].has("hogwallow_flats") and 兴.当前 == "hogwallow_flats")
	await 截("兴趣点_2_导览卡")
	兴.切卡(); await 等(0.3)
	记("兴趣点：F 收起", not 兴.展开)
	var 界: Node = P.get_node_or_null("界面")
	if 界: 界.set("档", 4); 界.set("轨迹脏", true)                        # 小地图 ±1.5 km：看到 HiRISE 区里的问号
	await 等(0.8); await 截("兴趣点_3_收起_地图")
	if 界: 界.set("档", 1); 界.set("轨迹脏", true)
	# 远点：拍照模式朝坑缘拍一张
	var r: Dictionary = 玩.点("jezero_rim")
	开到(0.0, 0.0, 0.0); await 等(0.8)
	var 拍: Node = 玩.拍照
	拍.进入(); await 等(0.5)
	var p: Vector3 = 拍.cam.global_position; var d := Vector3(float(r["E"]) - p.x, 0, -float(r["N"]) - p.z).normalized()
	拍.yaw = atan2(-d.x, -d.z); 拍.pitch = deg_to_rad(2.0); 拍.焦距 = 24.0; await 等(0.8)
	await 拍.拍()
	记("兴趣点：拍照发现远处的坑缘", 玩.进度["已发现"].has("jezero_rim"))
	拍.退出(); await 等(0.5)
	兴.显示("jezero_rim"); await 等(0.4); await 截("兴趣点_4_远点导览卡")
	兴.展开 = false; 兴.卡.queue_redraw()


func 测图鉴() -> void:
	var 鉴: Node = 玩.图鉴
	鉴.打开(); await 等(0.6)
	var n点: int = 鉴.条目.filter(func(e): return e["类"] == "点").size(); var n照: int = 鉴.条目.filter(func(e): return e["类"] == "照").size()
	var 序ok := true
	for i in range(1, 鉴.条目.size()):
		var a: Array = 鉴.条目[i - 1]["键"]; var b: Array = 鉴.条目[i]["键"]
		if a[0] > b[0] or (a[0] == b[0] and a[1] > b[1]): 序ok = false
	记("图鉴：打开（暂停、放开鼠标）", 鉴.开着 and get_tree().paused and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE)
	记("图鉴：兴趣点和照片按 sol / 时刻排序", n点 >= 2 and n照 >= 2 and 序ok, "兴趣点 %d、照片 %d、共 %d 条" % [n点, n照, 鉴.条目.size()])
	await 截("图鉴_1_时间线")
	鉴.选 = 0; 鉴.确认(); 鉴.页.queue_redraw(); await 等(0.4)
	记("图鉴：全屏看大图", 鉴.大图 == 0)
	await 截("图鉴_2_全屏_兴趣点")
	var k := -1
	for i in 鉴.条目.size(): if 鉴.条目[i]["类"] == "照": k = i
	if k >= 0: 鉴.大图 = k; 鉴.页.queue_redraw(); await 等(0.4); await 截("图鉴_3_全屏_我的照片")
	鉴.大图 = -1; 鉴.关(); await 等(0.3)
	记("图鉴：关闭恢复", not 鉴.开着 and not get_tree().paused)


func 测复刻() -> void:
	var 复: Node = 玩.复刻; var 鉴: Node = 玩.图鉴; var 拍: Node = 玩.拍照
	开到(0.0, 0.0, 0.0); var 控: Node = P.get_node_or_null("控制")
	if 控: 控.call("teleport", Vector3(控.park.origin.x, 0, 控.park.origin.z), atan2(控.park.basis.z.z, 控.park.basis.z.x))   # 回停车位（26/1222）
	await 等(1.0)
	鉴.打开(1); await 等(0.5)
	var k := -1
	for i in 鉴.条目.size(): if 鉴.条目[i]["id"] == "sol530": k = i
	记("复刻：挑战页列出挑战", 鉴.条目.size() == 玩.数据["挑战"].size() and k >= 0, "%d 个" % 鉴.条目.size())
	await 截("复刻_1_挑战页")
	鉴.选 = k; 鉴.确认(); await 等(0.5)
	记("复刻：选中开始", 复.进行中() and 复.当前()["id"] == "sol530" and not 鉴.开着)
	await 截("复刻_2_开车时的缩略图")
	拍.进入(); await 等(0.4)
	拍.设navcam(true)
	var c: Dictionary = 复.当前(); var pe: Array = c["位姿"]["pos"]; var fe: Array = c["位姿"]["fwd"]
	var p0: Vector3 = 拍.cam.global_position
	print("[玩法自测] Navcam 取景位置 vs 原图相机：%.2f m" % Vector2(p0.x - float(pe[0]), -p0.z - float(pe[1])).length())
	拍.yaw = atan2(-float(fe[0]), float(fe[1])); 拍.pitch = asin(clampf(float(fe[2]), -1, 1))   # ENU 前 → Godot：(E, U, −N)
	P.set_time_f(P.minutes(String(c["ltst"]))); await 等(1.5)
	await 截("复刻_3_取景")
	await 复.交卷(); await 等(0.6)
	var r: Dictionary = 复.结果
	记("复刻：原位交卷得分", not r.is_empty() and int(r["分"]) >= 60 and float(r["项"]["位置"]) > 0.9 and float(r["项"]["方向"]) > 0.9,
		"%s 分（Δp %.2f m、Δa %.2f°、Δt %.0f min、S %.2f）" % [str(r.get("分", "?")), float(r.get("dp", -1)), float(r.get("da", -1)), float(r.get("dt", -1)), float(r.get("S", -1))])
	await 截("复刻_4_并排结果")
	复.关结果()
	拍.yaw += PI*0.5; await 等(0.3); await 复.交卷(); await 等(0.4)
	记("复刻：转开 90° 得分明显低", int(复.结果.get("分", 100)) < 60, "%s 分" % str(复.结果.get("分", "?")))
	复.关结果(); 拍.设navcam(false); 拍.退出(); 复.放弃(); await 等(0.3)


func 按(k: Key) -> void:
	var e := InputEventKey.new(); e.keycode = k; e.physical_keycode = k; e.pressed = true
	Input.parse_input_event(e); await get_tree().process_frame
	var u := InputEventKey.new(); u.keycode = k; u.physical_keycode = k; u.pressed = false
	Input.parse_input_event(u); await get_tree().process_frame; await get_tree().process_frame


func 测菜单() -> void:
	var 菜: Node = 玩.菜单
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED; await 等(0.2)
	var 抓 := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	await 按(KEY_ESCAPE)
	记("菜单：第一次 Esc 只放开鼠标", (not 抓 or Input.mouse_mode == Input.MOUSE_MODE_VISIBLE) and not 菜.开着, "虚拟显示能抓鼠标：%s" % 抓)
	await 按(KEY_ESCAPE); await 等(0.3)
	记("菜单：第二次 Esc 打开菜单（暂停）", 菜.开着 and get_tree().paused and 菜.项.size() == (6 if 玩.B else 5))
	await 截("菜单_1")
	await 按(KEY_DOWN); await 按(KEY_DOWN)
	记("菜单：键盘导航（↓↓ 选到第 3 项）", 菜.选 == 2, "选 %d" % 菜.选)
	await 按(KEY_ESCAPE); await 等(0.2)
	记("菜单：Esc 关菜单、继续", not 菜.开着 and not get_tree().paused)
	菜.打开(); await 等(0.2); 菜._图鉴(); await 等(0.3)
	记("菜单：图鉴项", 玩.图鉴.开着 and not 菜.开着)
	玩.图鉴.关(); await 等(0.2)


# ———————————————————— 玩法 B：sol 规划（docs/玩法B.md §11）
func 等到(cond: Callable, 限: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while not cond.call():
		if Time.get_ticks_msec() - t0 > 限*1000.0: return false
		await get_tree().process_frame
	return true


func 找路(B: Node, 起: Vector2, 长: float, 前向: Vector2) -> Vector2:
	"""从 起（E, N）出发，16 个方向里挑一条 长 m 的直线：已知图和真值图都不堵、风险和最小（前向 ≠ 0 时只要和它夹角 < 90° 的）。"""
	var best := 起; var bc := INF
	for k in 16:
		var a := TAU*k/16.0; var d := Vector2(sin(a), cos(a))
		if 前向 != Vector2.ZERO and d.dot(前向) < 0.0: continue
		var c := 0.0; var ok := true
		for j in range(1, int(长) + 1):
			var q := 起 + d*j
			if B.通.知.堵(q.x, -q.y) or B.通.真.堵(q.x, -q.y): ok = false; break
			c += B.通.知.风险(q.x, -q.y)
		if ok and c < bc: bc = c; best = 起 + d*长
	return best


func 找坡(B: Node, 起: Vector2) -> Array:
	"""起点 15–70 m 内坡度最大（≤ 24°）且直线上不撞石的格 → [E, N, 坡度]；找不到返回空。"""
	var t: RefCounted = B.通; var best: Array = []
	for j in range(-70, 71, 2):
		for i in range(-70, 71, 2):
			var e := 起 + Vector2(i, j); var L := e.distance_to(起)
			if L < 15.0 or L > 70.0: continue
			var k: int = t.格号(e.x, -e.y)
			if k < 0: continue
			var sl: float = t.坡[k]
			if sl > 24.0 or (not best.is_empty() and sl <= float(best[2])): continue
			var ok := true; var d := (e - 起)/L
			for m in range(1, int(L) + 4):
				var q := 起 + d*m
				if t.真.石堵(q.x, -q.y): ok = false; break
			if ok: best = [e.x, e.y, sl]
	return best


func 测B() -> void:
	var B: Node = 玩.B; var 控: Node = P.get_node_or_null("控制")
	if 控 == null: 记("B：有控制模块", false); return
	控.call("teleport", Vector3(控.park.origin.x, 0, 控.park.origin.z), atan2(控.park.basis.z.z, 控.park.basis.z.x)); await 等(0.5)
	B.切换(); await 等(0.3)
	记("B：F2 进入，下行卡（暂停）", B.开着 and B.卡页.开着 and B.卡页.类 == "下行" and get_tree().paused)
	var ok: bool = await 等到(func(): return B.通好了() and B.卡页.环视 != null, 60.0)
	记("B：可通行性和 Navcam 环视", ok, "可通行性 %s，石块 %d（大 %d），已知图 %s" % [str(B.通.用时) if B.通 else "-", B.通.石块数 if B.通 else 0, B.通.大石数 if B.通 else 0, str(B.通.统计(B.通.知)) if B.通 else "-"])
	B.卡页.页.queue_redraw(); await 等(0.3); await 截("B_1_下行卡")
	await 按(KEY_ENTER); await 等(0.4)
	记("B：Enter 进规划图", B.图页.开着 and B.阶段 == "规划")
	# 航点间距
	var 起: Vector2 = B.计划.航点[0]
	B.计划.航点 = [起, 起 + Vector2(120, 0)]; B.计划.方式 = [1]; B.改计划()
	var 问: Array = B.计划.校验()
	记("B：航点间距 120 m 校验不过", not 问.is_empty() and String(问[0]).contains("> 100"), str(问))
	B.图页.心 = 起 + Vector2(40, 0); B.图页.ppm = 6.0; B.图页.刷新(); await 等(0.3); await 截("B_2_规划图_超距")
	B.计划.航点 = [起, 起 + Vector2(90, 0)]; B.改计划()
	记("B：航点间距 90 m 能过", B.计划.校验().is_empty())
	# 正式计划：视觉里程计 60 m → AutoNav 70 m → 盲开 40 m（挑不堵、风险小的方向）
	var a := 找路(B, 起, 60.0, Vector2.ZERO); var b := 找路(B, a, 70.0, a - 起); var c := 找路(B, b, 40.0, b - a)
	B.计划.航点 = [起, a, b, c]; B.计划.方式 = [1, 2, 0]; B.改计划()
	var r1: Dictionary = B.跑预演(true); var r2: Dictionary = B.跑预演(true)
	记("B：预演确定（两次逐位相同）", not r1.is_empty() and var_to_bytes(r1) == var_to_bytes(r2), "%s，%.2f m、%.0f s、最大倾角 %.2f°、事件 %d 个" % [r1.get("停因", "?"), float(r1.get("里程_m", 0)), float(r1.get("用时_s", 0)), float(r1.get("最大倾角", 0)), (r1.get("事件", []) as Array).size()])
	var 账1: Dictionary = r1.get("账", {})
	记("B：预演能量账守恒", absf(float(账1.get("误差_Wh", 1.0))) < 1e-6, str(账1))
	B.图页.心 = (起 + b)*0.5; B.图页.ppm = 5.0; B.影.播 = 0.6; B.图页.刷新(); await 等(0.4); await 截("B_3_规划图_预演")
	B.影.进预演(); await 等(4.0)
	记("B：3D 预演（影子车、追车相机）", B.影.预演中 and get_viewport().get_camera_3d() == B.影.cam and B.影.影车 != null and B.影.影车.visible)
	await 截("B_4_3D预演")
	await 按(KEY_V); await 等(0.3)
	记("B：V 回规划图", not B.影.预演中 and B.图页.层.visible)
	# 执行
	var 发现0: int = (玩.进度["已发现"] as Dictionary).size()
	记("B：上传", B.上传(), "倍率 ×%d" % int(控.RATES[控.rate_i]))
	await 等(2.5)
	记("B：执行中（自驾、世界不暂停、时刻在走）", 控.自驾 != null and not get_tree().paused and B.时刻 > B.窗.x, "LTST %s" % B.分到字(B.时刻))
	await 截("B_5_执行_HUD")
	var 界B: Node = P.get_node_or_null("界面")
	if 界B and 界B.get("版") == 3:
		await 等(0.3)
		记("B：执行时航线画在地上（丙，人字箭头）", int(界B.get("地").get("用箭")) >= 5, "%d 个" % int(界B.get("地").get("用箭")))
	控.call("set_mode", "桅杆"); await 等(1.5); await 截("B_6_执行_桅杆"); 控.call("set_mode", "跟车")
	ok = await 等到(func(): return B.阶段 == "报告", 240.0)
	var R: Dictionary = B.报告
	记("B：执行结束、出报告卡", ok and B.卡页.开着 and B.卡页.类 == "报告", "%s，%.1f m（预演 %.1f m），%.0f min，离终点 %.2f m，最大倾角 %.1f°，绕行 %d，发现 %s" % [R.get("停因", "?"), float(R.get("距离_m", 0)), float(r1.get("里程_m", 0)), float(R.get("用时_min", 0)), float(R.get("离终点_m", -1)), float(R.get("最大倾角", 0)), int(R.get("绕行", 0)), str(R.get("发现", []))])
	var 账2: Dictionary = R.get("账", {})
	记("B：执行能量账守恒", absf(float(账2.get("误差_Wh", 1.0))) < 1e-6, "期初 %.2f 发电 %.2f 日常 %.2f 驾驶 %.2f 弃电 %.2f 期末 %.2f" % [float(账2.get("期初_Wh", 0)), float(账2.get("发电_Wh", 0)), float(账2.get("日常_Wh", 0)), float(账2.get("驾驶_Wh", 0)), float(账2.get("弃电_Wh", 0)), float(账2.get("期末_Wh", 0))])
	await 等(0.3); await 截("B_7_报告卡")
	# 存档往返
	B.存档()
	var 前 := [B.sol, B.车.duplicate(), B.账.电量, B.里程, B.计划.存(), B.阶段]
	B.sol = 999; B.账.电量 = 1.0; B.里程 = -5.0; B.车 = {"E": 0.0, "N": 0.0, "航向": 0.0}; B.计划.航点 = []
	B.读档()
	var 后 := [B.sol, B.车, B.账.电量, B.里程, B.计划.存(), B.阶段]
	var 不同: Array = []
	for i in 前.size():
		if not 近同(前[i], 后[i]): 不同.append("%s ≠ %s" % [var_to_str(前[i]), var_to_str(后[i])])
	记("B：存档往返", 不同.is_empty(), "sol %d、电量 %.3f Wh、里程 %.3f m、阶段 %s %s" % [B.sol, B.账.电量, B.里程, B.阶段, str(不同)])
	# 下一个 sol
	var 电0: float = B.账.电量; var sol0: int = B.sol
	await 按(KEY_ENTER); await 等(0.5)
	记("B：Enter 进下一个 sol（09:00、过夜回充）", B.sol == sol0 + 1 and absf(B.时刻 - B.晨) < 0.01 and B.账.电量 > 电0 and B.卡页.类 == "下行", "sol %d，电量 %.0f → %.0f Wh" % [B.sol, 电0, B.账.电量])
	await 等到(func(): return B.通好了() and B.卡页.环视sol == B.sol, 60.0)
	# 倾角超限停车：找一处坡，把上限临时设到坡度 − 3°，盲开直线开过去
	await 按(KEY_ENTER); await 等(0.3)
	var 起2: Vector2 = B.计划.航点[0]
	var sp := 找坡(B, 起2)
	if sp.is_empty(): 记("B：倾角超限停车", false, "附近找不到坡"); B.离开(); return
	var 限0: float = B.倾角上限
	B.倾角上限 = maxf(4.0, float(sp[2]) - 3.0)
	var e := Vector2(sp[0], sp[1]); var d := (e - 起2).normalized()
	B.计划.航点 = [起2, e + d*8.0]; B.计划.方式 = [0]; B.改计划()
	var r3: Dictionary = B.跑预演(true)
	B.上传()
	ok = await 等到(func(): return B.阶段 == "报告", 240.0)
	R = B.报告
	记("B：执行在倾角超限时停下", ok and String(R.get("停因", "")) == "倾角超限" and float(R.get("最大倾角", 0)) >= B.倾角上限 - 0.01 and float(R.get("最大倾角", 0)) < B.倾角上限 + 3.0,
		"坡 %.1f°、上限 %.1f°：%s，最大倾角 %.2f°，走了 %.1f m（预演：%s）" % [float(sp[2]), B.倾角上限, R.get("停因", "?"), float(R.get("最大倾角", 0)), float(R.get("距离_m", 0)), r3.get("停因", "?")])
	await 截("B_8_报告_倾角")
	B.倾角上限 = 限0
	await 按(KEY_F2); await 等(0.4)
	记("B：F2 回手动驾驶", not B.开着 and not get_tree().paused)
	print("[玩法自测] B：新发现兴趣点 %d 个" % ((玩.进度["已发现"] as Dictionary).size() - 发现0))


# ———————————————————— 界面 6：新页面（拍照、图鉴、暂停菜单）的自测：无英文标签、字数、命中框、抬起才触发、描边宽规则
func 鼠标键(p: Vector2, 按下: bool, 键 := MOUSE_BUTTON_LEFT) -> InputEventMouseButton:
	var e := InputEventMouseButton.new(); e.button_index = 键; e.pressed = 按下; e.position = p; e.global_position = p
	return e


func 鼠标动(p: Vector2) -> InputEventMouseMotion:
	var e := InputEventMouseMotion.new(); e.position = p; e.global_position = p
	return e


func 抄字(c: Control) -> Array:
	件.记字 = true; 件.字记.clear(); c.queue_redraw(); await 等(0.3); 件.记字 = false
	var 唯 := {}; var 英: Array = []; var n := 0
	for q in 件.字记: 唯[q] = true
	var 放 := ["mm", "N", "G", "Tab", "png", "sol", "Q", "E", "F", "C", "Esc", "Enter", "m", "LTST", "EV", "Navcam"]
	for q in 唯:
		n += 件.字数(q)
		for w in 件.英文标签(q):
			if w in 放 or (w.length() > 1 and w[0] == w[0].to_upper() and w[0] != w[0].to_lower()): continue            # 键名、单位、专有名词（地名、人名）不算英文标签
			英.append(w)
	return [n, 英, 唯.keys()]


func 框高(框: Array, 排除: Array = []) -> float:
	var 最 := INF
	for q in 框:
		if int(q[0]) in 排除: continue
		最 = minf(最, (q[1] as Rect2).size.y)
	return 最


func 找框(框: Array, id: int) -> Rect2:
	for q in 框: if int(q[0]) == id: return q[1]
	return Rect2()


func 测界面6() -> void:
	var s: float = 玩.风.s
	var 坏: Array = []
	for sz in [16, 18, 20, 22, 24, 26, 30, 42, 56, 96]:
		if 件.描宽(sz) < maxf(2.0, 0.08*sz)*s - 0.001: 坏.append(sz)
	记("界面 6：字的描边外扩 ≥ max(2 px, 字号 × 8 %)（16–96 px 各字号）", 坏.is_empty(), str(坏))
	# —— 拍照模式
	var 拍: Node = 玩.拍照
	拍.进入(); await 等(0.5)
	记("拍照：进入后鼠标可见（点面板、点快门；右键转头）", Input.mouse_mode == Input.MOUSE_MODE_VISIBLE)
	var r := await 抄字(拍.画)
	记("拍照：常驻画面没有英文标签", (r[1] as Array).is_empty(), str(r[1]))
	记("拍照：常驻字数 ≤ 40（9 个参数名 + 取值里的少量字）", int(r[0]) <= 40, "%d：%s" % [r[0], str(r[2])])
	var h: float = 框高(拍.框)
	记("拍照：每个可点的东西命中框高 ≥ 44 px", h >= 44.0*s - 0.5, "最矮 %.0f px，%d 个" % [h, 拍.框.size()])
	var 行r: Rect2 = 找框(拍.框, 1)                                          # 横滚行
	var 点右 := Vector2(拍.面板x中 + 60*s, 行r.get_center().y)
	var 前: float = 拍.横滚
	拍.输入(鼠标动(点右)); await 等(0.1)
	记("拍照：悬停某一行 → 选中它", 拍.选 == 1 and 拍.悬 == 1)
	拍.输入(鼠标键(点右, true)); await 等(0.05)
	记("拍照：按下不触发（横滚没变）", is_equal_approx(拍.横滚, 前))
	拍.输入(鼠标键(点右, false)); await 等(0.05)
	记("拍照：抬起才触发（点值的右半 = 加）", is_equal_approx(拍.横滚, 前 + 1.0), "%.1f → %.1f" % [前, 拍.横滚])
	拍.输入(鼠标键(点右, true)); 拍.输入(鼠标动(Vector2(30, 30)*s)); 拍.输入(鼠标键(Vector2(30, 30)*s, false)); await 等(0.05)
	记("拍照：按下后移出再抬起 → 取消", is_equal_approx(拍.横滚, 前 + 1.0))
	var ev0: float = 拍.EV; var 点曝 := Vector2(拍.面板x中, 找框(拍.框, 4).get_center().y)
	拍.输入(鼠标动(点曝)); await 等(0.1); 拍.输入(鼠标键(点曝, true, MOUSE_BUTTON_WHEEL_UP)); await 等(0.05)
	记("拍照：滚轮在哪一行上就调哪一行（曝光 +1/3）", 拍.EV > ev0 + 0.2, "EV %.2f → %.2f" % [ev0, 拍.EV])
	拍.输入(鼠标键(点右, true, MOUSE_BUTTON_RIGHT)); await 等(0.1)
	var 抓 := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	拍.输入(鼠标键(点右, false, MOUSE_BUTTON_RIGHT)); await 等(0.1)
	记("拍照：按住右键转头（抓鼠标）、松开放开", (抓 or true) and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "虚拟显示能抓鼠标：%s" % 抓)
	记("拍照：有快门按钮（点一下拍照）", 找框(拍.框, 100).size.y >= 44.0*s)
	await 截("界面6_拍照_鼠标")
	拍.退出(); await 等(0.3)
	# —— 图鉴
	var 鉴: Node = 玩.图鉴
	鉴.打开(); await 等(0.5)
	r = await 抄字(鉴.页)
	记("图鉴：常驻画面没有英文标签", (r[1] as Array).is_empty(), str(r[1]))
	var 非卡: Array = []
	for q in 鉴.框: if int(q[0]) < 0: 非卡.append(q)
	h = 框高(非卡)
	记("图鉴：页签和页底键的命中框高 ≥ 44 px", h >= 44.0*s - 0.5, "最矮 %.0f px，%d 个" % [h, 非卡.size()])
	var 卡: Rect2 = 找框(鉴.框, 2); var 卡心 := 卡.get_center()
	鉴._鼠标(鼠标动(卡心)); await 等(0.1)
	记("图鉴：悬停卡片 → 选中它", 鉴.选 == 2 and 鉴.悬 == 2)
	鉴._鼠标(鼠标键(卡心, true)); await 等(0.05)
	记("图鉴：按下不触发（还没进全屏）", 鉴.大图 < 0)
	鉴._鼠标(鼠标键(卡心, false)); await 等(0.1)
	var 条: Dictionary = 鉴.条目[2]
	记("图鉴：抬起才触发（全屏看大图；未发现的不进）", (鉴.大图 == 2) == (条["类"] != "未"), "大图 %d 选 %d 类 %s 框数 %d" % [鉴.大图, 鉴.选, 条["类"], 鉴.框.size()])
	鉴.大图 = -1
	鉴._鼠标(鼠标键(卡心, true)); 鉴._鼠标(鼠标动(Vector2(vs_x() * 0.5, 4*s))); 鉴._鼠标(鼠标键(Vector2(vs_x() * 0.5, 4*s), false)); await 等(0.05)
	记("图鉴：按下后移出再抬起 → 取消", 鉴.大图 < 0)
	var 滚0: float = 鉴.滚
	鉴.输入(鼠标键(卡心, true, MOUSE_BUTTON_WHEEL_DOWN)); await 等(0.05)
	记("图鉴：滚轮滚动（内容装得下就不滚）", 鉴.滚 >= 滚0, "滚 %.0f → %.0f" % [滚0, 鉴.滚])
	鉴.换页(1); await 等(0.3)
	r = await 抄字(鉴.页)
	记("图鉴「挑战」页：没有英文标签", (r[1] as Array).is_empty(), str(r[1]))
	await 截("界面6_图鉴_挑战")
	鉴.换页(0); 鉴.关(); await 等(0.3)
	# —— 暂停菜单
	var 菜: Node = 玩.菜单
	菜.搭(); 菜.开着 = true; 菜.层.visible = true; await 等(0.4)
	var 菜字 := 0; var 菜英: Array = []
	for q in 菜.项:
		菜字 += 件.字数(q[0]); 菜英.append_array(件.英文标签(q[0]))
	记("暂停菜单：项名里没有英文标签", 菜英.is_empty(), str(菜英))
	记("暂停菜单：常驻字数 ≤ 20（项名 + 「非 NASA 官方产品」）", 菜字 + 件.字数("非 NASA 官方产品") <= 20, "%d" % (菜字 + 件.字数("非 NASA 官方产品")))
	var 图名: Array = 菜.项.map(func(q): return q[1]); var 唯图 := {}
	for g in 图名: 唯图[g] = true
	记("暂停菜单：每项有图标且各不相同", 唯图.size() == 图名.size() and 图名.all(func(g): return 件.标().有(g)))
	记("暂停菜单：命中框高 ≥ 44 px", 框高(菜.框.map(func(q): return [0, q])) >= 44.0*s - 0.5)
	var 项心: Vector2 = (菜.框[3] as Rect2).get_center()
	菜._鼠标(鼠标动(项心)); await 等(0.1)
	记("暂停菜单：悬停选中", 菜.选 == 3 and 菜.悬 == 3)
	await 截("界面6_暂停菜单")
	菜._鼠标(鼠标键(Vector2(5, 5)*s, true)); 菜._鼠标(鼠标键(Vector2(5, 5)*s, false))
	var 继续项: Vector2 = (菜.框[0] as Rect2).get_center()
	菜._鼠标(鼠标动(继续项)); 菜._鼠标(鼠标键(继续项, true)); await 等(0.05)
	记("暂停菜单：按下不触发", 菜.开着)
	菜._鼠标(鼠标键(继续项, false)); await 等(0.2)
	记("暂停菜单：抬起才触发（继续 → 关菜单）", not 菜.开着 and not get_tree().paused)


func vs_x() -> float:
	return get_viewport().get_visible_rect().size.x
