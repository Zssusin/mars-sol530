# 下行卡和报告卡（docs/玩法B.md §1）。全屏页（可以有暗底）。
#   下行卡：上个 sol 结束时的状态 + 车上 Navcam 环视（游戏内从桅杆头渲染 6 张 60° 视场、按方位排成一条，代替真实下行图像）
#           + 车周围 ±150 m 的 HiRISE 小图（带可通行性层）。Enter 进规划图。
#   报告卡：走了多远、耗电、用时、到没到、为什么停；新发现的兴趣点（衔接玩法 A：Tab 图鉴、C 拍照）。Enter 进下一个 sol。
extends Node

const 件 := preload("res://界面/件.gd")
const 张 := 6
const 张宽 := 640
const 张高 := 400

var B: Node
var 玩: Node
var P: Node
var 风: RefCounted
var 开着 := false
var 类 := ""                                      # 下行 / 报告
var 层: CanvasLayer
var 页: Control
var 环视: ImageTexture = null
var 环视sol := -1
var 拍中 := false
var vp: SubViewport
var vcam: Camera3D
var 框: Array = []                                # [[号, 矩形, 提示文字（可空）], …]；号 ≥ 900 = 页底键
var 悬 := -1
var 按 := -1
var 鼠标位 := Vector2.ZERO


func _ready() -> void:
	B = get_parent(); 玩 = B.玩; P = B.P; 风 = B.风
	process_mode = Node.PROCESS_MODE_ALWAYS
	层 = CanvasLayer.new(); 层.layer = 45; 层.visible = false; add_child(层)
	页 = Control.new(); 页.set_anchors_preset(Control.PRESET_FULL_RECT); 页.mouse_filter = Control.MOUSE_FILTER_STOP; 页.draw.connect(_画); 页.gui_input.connect(_鼠标); 层.add_child(页)


func _process(dt: float) -> void:
	if not 开着: return
	件.提示更(("%d" % 悬) if 悬 >= 0 else "", dt); 页.queue_redraw()


func 点中(p: Vector2) -> int:
	var rs: Array = []
	for q in 框: rs.append(q[1])
	return 件.命中(rs, p)


func _鼠标(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion:
		鼠标位 = ev.position; var i := 点中(ev.position); 悬 = int(框[i][0]) if i >= 0 else -1
	elif ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		var i := 点中(ev.position)
		if ev.pressed: 按 = int(框[i][0]) if i >= 0 else -1
		else:
			var 起 := 按; 按 = -1
			if i >= 0 and 起 >= 900 and int(框[i][0]) == 起:
				match 起:
					900: _键(KEY_ENTER)
					901: _键(KEY_TAB if 类 == "报告" else KEY_ESCAPE)
					902: _键(KEY_ESCAPE)


func _键(k: int) -> void:
	var e := InputEventKey.new(); e.keycode = k as Key; e.pressed = true
	输入(e)


func 行画(c: Control, s: float, x: float, y: float, w: float, 图名: String, 文: String, 提 := "", col := Color(-1, 0, 0), 字号 := 22.0) -> void:
	"""一行：图标 + 数字串（没有标签字）；有 提 时可悬停，悬停高亮 + 0.35 s 出提示。"""
	if col.r < 0.0: col = 风.白
	var r := Rect2(x - 12*s, y - 30*s, w, 40*s)
	if 提 != "":
		框.append([框.size(), r, 提]); var hv := 件.悬度("下行行%d" % (框.size() - 1), 悬 == 框.size() - 1)
		if hv > 0.01: c.draw_rect(r, Color(风.白, 0.10*hv))
	件.图标(c, 图名, Vector2(x + 13*s, y - 8*s), 28.0, col)
	风.字串(c, Vector2(x + 44*s, y), 文, 字号, col, "等中" if 字号 >= 22.0 else "等")


func 底键(c: Control, vs: Vector2, s: float, 表: Array, y: float) -> void:
	var 行 := 件.键图行(c, Vector2(vs.x*0.5, y), 表, (悬 - 900) if 悬 >= 900 else -1, (按 - 900) if 按 >= 900 else -1)
	for i in 行.size(): 框.append([900 + i, 行[i], String(表[i][2])])


func 下行() -> void:
	类 = "下行"; 开(); B.图页.关()
	if 环视sol != B.sol and not 拍中: 拍环视()


func 报告卡() -> void:
	类 = "报告"; 开(); B.图页.关()


func 开() -> void:
	开着 = true; 层.visible = true; B.暂停页(true); 页.queue_redraw()


func 关() -> void:
	开着 = false; 层.visible = false


func 输入(ev: InputEvent) -> void:
	if not (ev is InputEventKey and ev.pressed and not ev.echo): return
	match ev.keycode:
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			if 类 == "下行": 关(); B.阶段 = "规划"; B.存档(); B.图页.打开()
			else: 关(); B.下一个sol()
		KEY_ESCAPE, KEY_F2: B.离开()
		KEY_TAB:
			if 类 == "报告" and 玩.图鉴: 关(); B.离开(); 玩.图鉴.打开()
		_: return
	get_viewport().set_input_as_handled()


# ———————————————————— Navcam 环视（游戏内渲染）
func 拍环视() -> void:
	"""桅杆头位置，方位 0°（北）起每 60° 一张，俯 10°；SubViewport 共用主世界，各渲一帧，拼成一条。"""
	var 控: Node = B.控
	if 控 == null: return
	拍中 = true
	if vp == null:
		vp = SubViewport.new(); vp.size = Vector2i(张宽, 张高); vp.msaa_3d = Viewport.MSAA_4X; vp.use_taa = false
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		vcam = Camera3D.new(); vcam.fov = 360.0/张; vcam.keep_aspect = Camera3D.KEEP_WIDTH; vcam.near = 0.05; vcam.far = 200000.0
		var ca := CameraAttributesPractical.new(); ca.auto_exposure_enabled = false     # 固定曝光：各张一致（曝光已折进灯光）
		vcam.attributes = ca
		vp.add_child(vcam); add_child(vp)
	var 头: Vector3 = 控.body*控.mast_local
	for g: GeometryInstance3D in 控.head_parts: g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY   # 桅杆头附近的小件只投影（同桅杆视角）
	var img := Image.create(张宽*张, 张高, false, Image.FORMAT_RGBA8)
	for k in 张:
		var az := deg_to_rad(360.0*k/张 + 360.0/张*0.5)               # 每张中心的方位
		vcam.global_transform = Transform3D(Basis.IDENTITY, 头).looking_at(头 + Vector3(sin(az), -0.09, -cos(az)), Vector3.UP)
		玩.世界更新(vcam)
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS          # 连渲几帧：自动曝光、天光收敛（只渲一帧时各张亮度不一）
		for f in 30: await RenderingServer.frame_post_draw                # 体积雾有时域重投影：帧少了会带着上一张的雾色
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		var t := vp.get_texture().get_image()
		if t: t.convert(Image.FORMAT_RGBA8); img.blit_rect(t, Rect2i(0, 0, 张宽, 张高), Vector2i(张宽*k, 0))
	if 控.mode != "桅杆":
		for g: GeometryInstance3D in 控.head_parts: g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	环视 = ImageTexture.create_from_image(img); 环视sol = B.sol; 拍中 = false
	页.queue_redraw()


# ———————————————————— 画
func _画() -> void:
	var c := 页; var vs := c.size; var s: float = 风.s
	框.clear()
	c.draw_rect(Rect2(Vector2.ZERO, vs), 风.页底)
	if 类 == "下行": 画下行(c, vs, s)
	else: 画报告(c, vs, s)
	if 悬 >= 0:
		for q in 框:
			if int(q[0]) == 悬 and String(q[2]) != "": 件.提示画(c, String(q[2]), 鼠标位, vs)


func 画下行(c: Control, vs: Vector2, s: float) -> void:
	var x := 80*s; var y := 90*s
	风.题(c, Vector2(x, y), "桅杆相机", "火星日 %d" % B.sol)
	件.图标(c, "时刻", Vector2(x + 13*s, y + 36*s), 28.0, 风.灰)
	风.字串(c, Vector2(x + 44*s, y + 44*s), B.分到字(B.时刻), 24, 风.灰, "等中")
	# 环视条
	var sw := vs.x - 2*x; var sh := sw/(张*float(张宽)/张高)
	var r := Rect2(x, y + 80*s, sw, sh)
	if 环视: c.draw_texture_rect(环视, r, false)
	else: c.draw_rect(r, Color(风.暗色, 0.5)); 风.字串(c, r.get_center(), "渲染环视…", 风.号["中题"], 风.灰, "正", HORIZONTAL_ALIGNMENT_CENTER)
	c.draw_rect(r, Color(风.白, 0.4), false, maxf(1.0, 1.5*s))
	for k in 张 + 1:                                                  # 方位刻度
		var px := r.position.x + sw*k/张
		var az := 360*k/张
		c.draw_line(Vector2(px, r.end.y), Vector2(px, r.end.y + 10*s), Color(风.白, 0.7), 1.5*s)
		var nm: String = {0: "北", 90: "东", 180: "南", 270: "西", 360: "北"}.get(az, "%03d°" % az)
		风.字串(c, Vector2(px, r.end.y + 34*s), nm, 风.号["小"], 风.灰, "中", HORIZONTAL_ALIGNMENT_CENTER)
	风.字串(c, Vector2(r.end.x, r.end.y + 34*s), "游戏内渲染", 风.号["注"], 风.灰, "正", HORIZONTAL_ALIGNMENT_RIGHT)
	# 状态
	var y2 := r.end.y + 100*s
	var 上: Dictionary = B.上次
	var 节宽 := vs.x*0.55
	风.节(c, Vector2(x, y2), 节宽, "", "桅杆相机"); y2 += 44*s
	行画(c, s, x, y2, 节宽, "航点", "东 %+.1f 北 %+.1f m · %03d°" % [float(B.车["E"]), float(B.车["N"]), roundi(float(B.车["航向"])) % 360], "位置和航向（0 = 北，顺时针）"); y2 += 40*s
	行画(c, s, x, y2, 节宽, "电池", "%.0f Wh · %d%% · %.0f W" % [B.账.电量, roundi(B.账.电量/B.能源脚本.容量*100.0), B.能源脚本.发电功率(B.sol)], "电量 · 发电（MMRTG）· 下限 %d%%" % roundi(B.能源脚本.下限比*100)); y2 += 40*s
	行画(c, s, x, y2, 节宽, "里程", "%.1f m · %d" % [B.里程, B.历史.size()], "累计里程 · 已规划的火星日数"); y2 += 40*s
	if 上.is_empty(): 行画(c, s, x, y2, 节宽, "时刻", "sol 530", "上个火星日：停车点（第一次规划）")
	else: 行画(c, s, x, y2, 节宽, "时刻", "%d · %s · %.1f m · %.0f 分 · %.0f Wh" % [int(上["sol"]), String(上["停因"]), float(上["距离_m"]), float(上["用时_min"]), float(上["耗电_Wh"])], "上个火星日：停车原因 · 距离 · 用时 · 耗电"); y2 += 40*s
	y2 += 20*s
	风.节(c, Vector2(x, y2), 节宽, "", "时刻"); y2 += 44*s
	行画(c, s, x, y2, 节宽, "时刻", "%s–%s" % [B.分到字(B.窗.x), B.分到字(B.窗.y)], "驾驶时窗（结束时刻参照好奇号的时间限制；开始时刻是游戏设定）"); y2 += 40*s
	行画(c, s, x, y2, 节宽, "倾角_注意", "≤ 100 m · ≤ %.0f°" % B.倾角上限, "航点间距上限 · 倾角上限（游戏设定）"); y2 += 40*s
	行画(c, s, x, y2, 节宽, "禁行区", "≥ 40 cm", "石块高于 40 cm 算撞石；规划图上的石块只有直径 ≥ 1 m 的，和 Navcam 30 m 内的"); y2 += 40*s
	# 右下：小图
	var L := minf(vs.y - r.end.y - 160*s, vs.x*0.3)
	if L > 120*s: 小图(c, Rect2(vs.x - x - L, r.end.y + 70*s, L, L), 150.0)
	底键(c, vs, s, [["Enter", "地图", "进规划图"], ["Esc", "关闭", "回手动驾驶"]], vs.y - 50*s)


func 小图(c: Control, r: Rect2, half: float) -> void:
	"""车周围 ±half m 的 HiRISE（复用小地图纹理）+ 可通行性层 + 车。"""
	var 界: Node = P.get_node_or_null("界面")
	var e := Vector2(float(B.车["E"]), float(B.车["N"]))
	if 界 and 界.底图高:
		var T: Texture2D = 界.底图高; var th: float = 界.高半; var W := float(T.get_width()); var H := float(T.get_height())
		var src := Rect2(((e.x - half)/(2.0*th) + 0.5)*W, (0.5 - (e.y + half)/(2.0*th))*H, half/th*W, half/th*H)
		c.draw_texture_rect_region(T, r, src, Color(0.80, 0.80, 0.80))
	if B.叠图 and B.通好了():
		var t: RefCounted = B.通; var ppm := r.size.x/(2.0*half)
		var tl := r.position + r.size*0.5 + Vector2(t.x0 - e.x, e.y + t.z0)*ppm
		var 剪 := Rect2(tl, Vector2(t.N, t.N)*ppm).intersection(r)
		if 剪.has_area():
			var src2 := Rect2((剪.position - tl)/ppm, 剪.size/ppm)
			c.draw_texture_rect_region(B.叠图, 剪, src2)
			B.画险标(c, tl, ppm, 剪)
	var o := r.get_center(); var h := deg_to_rad(float(B.车["航向"])); var d := Vector2(sin(h), -cos(h)); var n := Vector2(-d.y, d.x)
	风.线(c, o - d*9*风.s + n*10*风.s, o + d*12*风.s, 风.白, 风.宽["粗"]*风.s); 风.线(c, o + d*12*风.s, o - d*9*风.s - n*10*风.s, 风.白, 风.宽["粗"]*风.s)
	c.draw_rect(r, Color(风.暗色, 0.6), false, 5*风.s); c.draw_rect(r.grow(-3*风.s), Color(风.白, 0.3), false, 1.2*风.s)
	风.字串(c, r.position + Vector2(10, 28)*风.s, "HiRISE ±%d m" % int(half), 风.号["小"], 风.白, "中")


func 画报告(c: Control, vs: Vector2, s: float) -> void:
	var R: Dictionary = B.报告
	var 新n: int = (R.get("发现", []) as Array).size()
	var 高 := (70 + 56 + 8*40 + 16 + 40 + maxi(1, 新n)*34 + (34 if 新n > 0 else 0) + 150)*s
	var x := vs.x*0.5 - 560*s; var y := vs.y*0.5 - 高*0.5 + 40*s; var w := 1120*s
	风.面板(c, Rect2(x - 40*s, y - 70*s, w + 80*s, 高), 1.0)
	风.题(c, Vector2(x, y), "执行", "火星日 %d" % int(R.get("sol", B.sol))); y += 70*s
	var 到 := bool(R.get("到达", false)); var 因 := String(R.get("停因", ""))
	var 注 := 因 in ["时窗用完", "玩家中止"]
	var 色: Color = 风.白 if 到 else (风.琥珀 if 注 else 风.红)
	var 图名 := "航点" if 到 else ("倾角_注意" if 注 else "倾角_警告")                # 告警：形状（三角 / 八边形）+ 字，不只靠颜色
	风.图标(c, 图名, Vector2(x + 17*s, y - 11*s), 34, 色)
	风.字串(c, Vector2(x + 44*s, y), ("到达终点" if 到 else ("注意 · 停车：" if 注 else "警告 · 停车：") + 因), 风.号["题"], 色, "中"); y += 56*s
	var 账: Dictionary = R.get("账", {})
	var 驾电 := float(账.get("驾驶_Wh", 0.0)); var 净 := float(账.get("期初_Wh", 0.0)) - float(R.get("电量_Wh", 0.0))
	var 行: Array = [
		["里程", "%.1f m / %.0f m / %.0f m" % [float(R.get("距离_m", 0)), float(R.get("计划_m", 0)), float(R.get("预演里程_m", 0))], "走了 / 计划 / 预演"],
		["时刻", "%s → %s · %.0f 分" % [B.分到字(float(R.get("起_ltst", 0))), B.分到字(float(R.get("止_ltst", 0))), float(R.get("用时_min", 0))], "当地时 起 → 止 · 用时"],
		["电池", "%.0f · %.0f · %.0f Wh · %d%%" % [驾电, 净, float(R.get("电量_Wh", 0)), roundi(float(R.get("电量_Wh", 0))/B.能源脚本.容量*100.0)], "驾驶耗电 · 今天净用 · 剩余"],
		["MMRTG", "= %.1f Wh" % float(账.get("期末_Wh", 0)), "期初 %.1f + 发电 %.1f − 日常 %.1f − 驾驶 %.1f − 弃电 %.1f = 期末 %.1f Wh（误差 %s）" % [float(账.get("期初_Wh", 0)), float(账.get("发电_Wh", 0)),
			float(账.get("日常_Wh", 0)), 驾电, float(账.get("弃电_Wh", 0)), float(账.get("期末_Wh", 0)), str(snappedf(float(账.get("误差_Wh", 0)), 1e-9))]],
		["航点", "%.1f m" % float(R.get("离终点_m", 0)), "离终点"],
		["倾角_注意", "%.1f° / %.0f°" % [float(R.get("最大倾角", 0)), B.倾角上限], "最大倾角 / 上限"],
		["自主导航", "%d · %d" % [int(R.get("绕行", 0)), int(R.get("高风险", 0))], "绕行次数 · 经过高风险格次数"]]
	if R.has("预演停因"): 行.append(["预演", String(R.get("预演停因", "")), "预演为什么停"])
	for kv in 行:
		行画(c, s, x, y, w, String(kv[0]), String(kv[1]), String(kv[2]), 风.白); y += 40*s
	y += 16*s
	var 新: Array = R.get("发现", [])
	风.节(c, Vector2(x, y + 14*s), w, "", "兴趣点_已发现"); y += 54*s
	if 新.is_empty(): 件.图标(c, "兴趣点_未发现", Vector2(x + 13*s, y - 8*s), 28.0, 风.灰); y += 34*s
	else:
		for id in 新:
			var q: Dictionary = 玩.点(String(id))
			件.图标(c, "兴趣点_已发现", Vector2(x + 13*s, y - 8*s), 28.0, 风.白); 风.字串(c, Vector2(x + 44*s, y), String(q.get("名", id)), 风.号["正"], 风.白, "正"); y += 34*s
	var 夜: float = (1440.0 - B.时刻 + B.晨)*B.能源脚本.LTST分/3600.0
	var 回: float = (B.能源脚本.发电功率(B.sol) - B.能源脚本.日常)*夜
	底键(c, vs, s, [["Enter", "执行", "下一个火星日 %d（过夜约 %.0f 小时，回充约 %+.0f Wh）" % [B.sol + 1, 夜, 回]], ["Tab", "图鉴", "图鉴"], ["Esc", "关闭", "回手动驾驶"]], y + 70*s)
