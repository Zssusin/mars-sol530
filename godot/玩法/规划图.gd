# 全屏规划图（docs/玩法B.md §8、§9）：俯视，底图和投影复用小地图（界面.gd 的 HiRISE / CTX 纹理和着色器，北向上），
#   叠可通行性层（已知图：轨道上看得见的 + Navcam 30 m 内），航点 / 禁行区编辑，每段驾驶方式，预演结果（轨迹、事件、预计到达），
#   右侧计划表和两条预算（电量、驾驶时窗），底部 sol 时间线（日照、时窗、现在、预计结束）。
#   这是全屏页：可以有暗底和暗框（HUD 的「不加暗底」规矩管的是开车时叠在画面上的仪表）。
extends Node

const 自驾脚本 := preload("res://控制/自驾.gd")

var B: Node
var 玩: Node
var P: Node
var 风: RefCounted
var 开着 := false
var 层: CanvasLayer
var 根: Control
var 图: Control
var 底远: Control
var 底高: Control
var 叠: Control
var 标: Control
var 侧: Control
var 时: Control
var 尺寸 := Vector2i.ZERO
var 心 := Vector2()                                # 图中心 (E, N)
var ppm := 3.0                                    # 像素 / m
var 选段 := -1
var 拖点 := -1
var 画禁 := false; var 禁心 := Vector2(); var 禁半 := 0.0
var 右按 := false; var 右起 := Vector2(); var 右移 := false
var 鼠 := Vector2(-1, -1)
var 层开 := true
var 闪 := 0.0                                     # 上传被拒时问题列表闪一下
var 日出 := 360.0; var 日落 := 1080.0


func _ready() -> void:
	B = get_parent(); 玩 = B.玩; P = B.P; 风 = B.风
	process_mode = Node.PROCESS_MODE_ALWAYS
	层 = CanvasLayer.new(); 层.layer = 45; 层.visible = false; add_child(层)
	算日照()


func 算日照() -> void:
	"""日出、日落：太阳高度过 0° 的时刻（相邻两张天空之间线性插值）。天空数据没盖到地平线时（老数据）退回用最早两张和最晚两张线性外推。"""
	var ks: Array = P.J["sky"].keys(); ks.sort_custom(func(a, b): return P.minutes(a) < P.minutes(b))
	if ks.size() < 4: return
	var rise := -1.0; var set_ := -1.0
	for i in ks.size() - 1:
		var e0: float = P.J["sky"][ks[i]]["elev"]; var e1: float = P.J["sky"][ks[i + 1]]["elev"]
		var m0: float = P.minutes(ks[i]); var m1: float = P.minutes(ks[i + 1])
		if e0 <= 0.0 and e1 > 0.0 and rise < 0.0: rise = m0 + (0.0 - e0)/(e1 - e0)*(m1 - m0)
		if e0 > 0.0 and e1 <= 0.0 and set_ < 0.0: set_ = m0 + (0.0 - e0)/(e1 - e0)*(m1 - m0)
	if rise >= 0.0 and set_ >= 0.0: 日出 = rise; 日落 = set_; return
	var f := func(a: String, b: String) -> float:
		var ea: float = P.J["sky"][a]["elev"]; var eb: float = P.J["sky"][b]["elev"]
		var ma: float = P.minutes(a); var mb: float = P.minutes(b)
		return ma - ea*(mb - ma)/(eb - ea) if absf(eb - ea) > 1e-3 else ma
	日出 = f.call(ks[0], ks[1]); 日落 = f.call(ks[-2], ks[-1])


func 界() -> Node:
	return P.get_node_or_null("界面")


# ———————————————————— 搭
func 搭() -> void:
	var vs := 层.get_viewport().get_visible_rect().size
	if Vector2i(vs) == 尺寸 and 根: return
	尺寸 = Vector2i(vs)
	if 根: 根.get_parent().remove_child(根); 根.queue_free()                 # 先摘出树：旧节点不能再收到「变可见」的重画，它的 draw 信号不会再触发
	var s: float = 风.s; var W := vs.x; var H := vs.y
	根 = Control.new(); 根.set_anchors_preset(Control.PRESET_FULL_RECT); 根.mouse_filter = Control.MOUSE_FILTER_IGNORE; 层.add_child(根)
	var 底 := ColorRect.new(); 底.color = 风.页底; 底.set_anchors_preset(Control.PRESET_FULL_RECT); 底.mouse_filter = Control.MOUSE_FILTER_STOP; 根.add_child(底)
	var 侧宽 := 560.0*s
	图 = Control.new(); 图.position = Vector2(36, 36)*s; 图.size = Vector2(W - 36*s - 侧宽 - 28*s, H - 36*s - 210*s); 图.clip_contents = true
	图.mouse_filter = Control.MOUSE_FILTER_STOP; 图.gui_input.connect(_图输入); 图.mouse_exited.connect(func(): 鼠 = Vector2(-1, -1); 标.queue_redraw())
	根.add_child(图)
	var 界n := 界()
	底远 = 子(图, _画底远); 底高 = 子(图, _画底高)
	for k in [[底远, false], [底高, true]]:
		var c: Control = k[0]
		c.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		if 界n:
			var sh := Shader.new(); sh.code = 界n.图码
			var sm := ShaderMaterial.new(); sm.shader = sh
			sm.set_shader_parameter("base", Vector3(0.55, 0.41, 0.32)*0.80); sm.set_shader_parameter("size", 图.size)
			sm.set_shader_parameter("mid", Vector3(0.518, 0.435, 0.388) if k[1] else Vector3(0.522, 0.439, 0.388)); sm.set_shader_parameter("k", 4.0 if k[1] else 8.0)
			c.material = sm
	叠 = 子(图, _画叠); 叠.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	标 = 子(图, _画标)
	侧 = Control.new(); 侧.position = Vector2(W - 侧宽 - 12*s, 36*s); 侧.size = Vector2(侧宽 - 24*s, H - 36*s - 210*s); 侧.mouse_filter = Control.MOUSE_FILTER_IGNORE
	侧.draw.connect(_画侧.bind(侧)); 根.add_child(侧)
	时 = Control.new(); 时.position = Vector2(36*s, H - 186*s); 时.size = Vector2(W - 72*s, 150*s); 时.mouse_filter = Control.MOUSE_FILTER_IGNORE
	时.draw.connect(_画时.bind(时)); 根.add_child(时)


func 子(父: Control, f: Callable) -> Control:
	var c := Control.new(); c.set_anchors_preset(Control.PRESET_FULL_RECT); c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.draw.connect(f.bind(c)); 父.add_child(c)                              # 处理函数画「发信号的那个节点」（参数 c），不画成员变量：重搭以后成员指向新节点，旧节点的信号会画到新节点上
	return c


func 打开() -> void:
	开着 = true
	搭(); 层.visible = true
	B.暂停页(true)
	心 = Vector2(float(B.车["E"]), float(B.车["N"]))
	if 选段 >= B.计划.段数(): 选段 = -1
	B.备通()
	刷新()


func 关() -> void:
	开着 = false; 层.visible = false; 拖点 = -1; 画禁 = false; 右按 = false


func 藏(on: bool) -> void:
	if 开着: 层.visible = not on


func 刷新() -> void:
	if not 根: return
	for c in [底远, 底高, 叠, 标, 侧, 时]: c.queue_redraw()


func 刷标() -> void:
	if 标: 标.queue_redraw()


# ———————————————————— 投影（北向上，同小地图）
func 地到屏(e: Vector2) -> Vector2:
	return 图.size*0.5 + Vector2(e.x - 心.x, 心.y - e.y)*ppm


func 屏到地(q: Vector2) -> Vector2:
	return 心 + Vector2((q.x - 图.size.x*0.5)/ppm, -(q.y - 图.size.y*0.5)/ppm)


# ———————————————————— 底图（复用小地图的纹理和投影：u = E/(2·half) + 0.5，v = 0.5 − N/(2·half)）
func _画底远(c: Control) -> void:
	var 界n := 界()
	if 界n: 画底(c, 界n.底图远, 界n.远半)


func _画底高(c: Control) -> void:
	var 界n := 界()
	if 界n: 画底(c, 界n.底图高, 界n.高半)


func 画底(c: Control, T: Texture2D, th: float) -> void:
	if T == null: return
	var sz := 图.size; var hw := sz.x*0.5/ppm; var hh := sz.y*0.5/ppm
	var e0 := maxf(心.x - hw, -th); var e1 := minf(心.x + hw, th); var n0 := maxf(心.y - hh, -th); var n1 := minf(心.y + hh, th)
	if e1 <= e0 or n1 <= n0: return
	var W := float(T.get_width()); var H := float(T.get_height())
	var a := 地到屏(Vector2(e0, n1)); var b := 地到屏(Vector2(e1, n0))
	var src := Rect2((e0/(2.0*th) + 0.5)*W, (0.5 - n1/(2.0*th))*H, (e1 - e0)/(2.0*th)*W, (n1 - n0)/(2.0*th)*H)
	c.draw_texture_rect_region(T, Rect2(a, b - a), src)


# ———————————————————— 可通行性层
func _画叠(c: Control) -> void:
	var t: RefCounted = B.通
	if t == null or not t.好了: return
	var tl := 地到屏(Vector2(t.x0, -t.z0)); var L: float = t.N*ppm
	if 层开 and B.叠图: c.draw_texture_rect(B.叠图, Rect2(tl, Vector2(L, L)), false)
	var s: float = 风.s
	if 层开: B.画险标(c, tl, ppm, Rect2(Vector2(0, 84*s), 图.size - Vector2(0, 84*s)))   # 顶上两行（标题、图例）不画
	c.draw_rect(Rect2(tl, Vector2(L, L)), Color(1, 1, 1, 0.35), false, maxf(1.0, 1.5*s))     # 网格范围（外面：未知）
	var k := Vector2(t.知心.x, -t.知心.y)                                       # Navcam 环视看清的范围
	虚圆(c, 地到屏(k), t.已知半径*ppm, Color(1, 1, 1, 0.6), 1.6*s)


func 虚圆(c: CanvasItem, o: Vector2, r: float, col: Color, w: float) -> void:
	var n := 48
	for i in n:
		if i % 2 == 1: continue
		c.draw_arc(o, r, TAU*i/n, TAU*(i + 1)/n, 4, col, w, true)


func 虚线(c: CanvasItem, a: Vector2, b: Vector2, col: Color, w: float, 节: float) -> void:
	var L := a.distance_to(b)
	if L < 1.0: return
	var d := (b - a)/L; var x := 0.0
	while x < L:
		var y := minf(x + 节, L)
		c.draw_line(a + d*x, a + d*y, Color(风.暗色, 0.6*col.a), w + 3.0*风.s, true)
		c.draw_line(a + d*x, a + d*y, col, w, true)
		x += 节*2.0


# ———————————————————— 标注：禁行区、航线、航点、预演、影子车、读数
func _画标(c: Control) -> void:
	var s: float = 风.s; var sz := 图.size; var 计: RefCounted = B.计划
	for z: Vector3 in 计.禁: 画禁区(c, Vector2(z.x, z.y), z.z)
	if 画禁 and 禁半 > 0.0: 画禁区(c, 禁心, 禁半)
	# 预演轨迹（细）和事件
	var r: Dictionary = B.预演
	if not r.is_empty():
		var pts := PackedVector2Array()
		for q: Array in r["轨迹"]: pts.append(地到屏(Vector2(q[0], q[1])))
		if pts.size() >= 2:
			c.draw_polyline(pts, Color(风.暗色, 0.55), 4.5*s, true); c.draw_polyline(pts, 风.预演色, 2.0*s, true)
	# 航段
	for i in 计.段数():
		var a := 地到屏(计.航点[i]); var b := 地到屏(计.航点[i + 1]); var m: int = int(计.方式[i]); var L: float = 计.段长(i)
		var col: Color = 风.红 if L > 计.间距上限 else 风.方式色[m]
		var w: float = (风.宽["选中"] if i == 选段 else 风.宽["航段"])*s
		if i == 选段: c.draw_line(a, b, Color(1, 1, 1, 0.25), w + 10*s, true)
		if m == 0: 虚线(c, a, b, col, w, 10*s)
		else: 风.线(c, a, b, col, w)
		var mid := (a + b)*0.5; var nv := (b - a).normalized().orthogonal()*18*s
		if a.distance_to(b) > 90*s or L > 计.间距上限 or i == 选段:
			var t := "%s %.0f m" % [自驾脚本.方式名[m].replace("AutoNav", "自主导航"), L]
			if L > 计.间距上限: t = "%.0f m > %d m" % [L, int(计.间距上限)]
			风.字串(c, mid + nv + Vector2(0, 6*s), t, 风.号["小"], col, "中", HORIZONTAL_ALIGNMENT_CENTER)
	# 预演事件
	if not r.is_empty():
		for e: Dictionary in r["事件"]:
			var q := 地到屏(Vector2(e["E"], e["N"]))
			match String(e["类"]):
				"高风险": 三角(c, q, 9*s, 风.琥珀)
				"绕行": c.draw_arc(q, 7*s, 0.3, TAU - 0.3, 16, 风.琥珀, 风.宽["框"]*s, true)
				"到航点": pass
				_:
					c.draw_rect(Rect2(q - Vector2(9, 9)*s, Vector2(18, 18)*s), Color(风.暗色, 0.6)); c.draw_rect(Rect2(q - Vector2(7, 7)*s, Vector2(14, 14)*s), 风.红)
					风.字串(c, q + Vector2(14*s, 6*s), String(e["类"]), 风.号["次"], 风.红, "中")
	# 航点：0 号是车（V 形），其余带序号的圈；预演过的写预计到达
	for i in 计.航点.size():
		var q := 地到屏(计.航点[i])
		if i == 0:
			var h := deg_to_rad(float(B.车["航向"])); var d := Vector2(sin(h), -cos(h)); var n := Vector2(-d.y, d.x)
			风.线(c, q - d*9*s + n*11*s, q + d*13*s, 风.白, 风.宽["粗"]*s); 风.线(c, q + d*13*s, q - d*9*s - n*11*s, 风.白, 风.宽["粗"]*s)
			continue
		c.draw_circle(q, 13*s, Color(风.暗色, 0.7)); c.draw_arc(q, 12*s, 0, TAU, 24, 风.白 if i != 拖点 else 风.琥珀, 风.宽["框"]*s, true)
		风.字串(c, q + Vector2(0, 7*s), str(i), 风.号["小"], 风.白, "粗", HORIZONTAL_ALIGNMENT_CENTER)
		if not r.is_empty() and i - 1 < r["段"].size():
			风.字串(c, q + Vector2(18*s, -12*s), B.分到字(float(r["段"][i - 1]["到达_ltst"])), 风.号["小"], 风.灰, "等")
	# 影子车图标
	if not r.is_empty() and (B.影.播放 or B.影.播 > 0.0):
		var q: Array = B.影.当前点()
		if not q.is_empty():
			var p := 地到屏(Vector2(q[0], q[1])); var psi: float = q[5]
			var d := Vector2(cos(psi), sin(psi)); var n := Vector2(-d.y, d.x)                 # (x, z) 和屏幕同向（x 右、z 下）
			c.draw_colored_polygon(PackedVector2Array([p + d*14*s, p - d*9*s + n*10*s, p - d*9*s - n*10*s]), Color(风.预演色, 0.75))
	# 暗框、比例尺、北、读数
	c.draw_rect(Rect2(Vector2.ZERO, sz).grow(-2.5*s), Color(风.暗色, 0.6), false, 5.0*s)
	c.draw_rect(Rect2(Vector2.ZERO, sz).grow(-5.5*s), Color(1, 1, 1, 0.25), false, maxf(1.0, 1.2*s))
	var 长 := 整(sz.x*0.18/ppm); var px := 长*ppm; var b0 := Vector2(24*s, sz.y - 24*s)
	风.线(c, b0, b0 + Vector2(px, 0), 风.白, 风.宽["框"]*s); 风.线(c, b0, b0 + Vector2(0, -7*s), 风.白, 风.宽["框"]*s); 风.线(c, b0 + Vector2(px, 0), b0 + Vector2(px, -7*s), 风.白, 风.宽["框"]*s)
	风.字串(c, b0 + Vector2(px + 10*s, 2*s), 距(长), 风.号["次"], 风.白, "等")
	风.字串(c, Vector2(sz.x*0.5, 34*s), "北", 风.号["正"], 风.白, "粗", HORIZONTAL_ALIGNMENT_CENTER)
	var 半宽 := sz.x*0.5/ppm
	var 源 := "CTX" if 半宽 > 1200.0 else "HiRISE"
	风.字串(c, Vector2(24*s, 36*s), "规划图 · %s · 可通行性：已知图（坡度全知；石块只知轨道可见的 ≥ 1 m 和 Navcam 30 m 内）%s" % [源, "" if 层开 else "（L 关）"], 风.号["小"], 风.灰, "正")
	if 层开 and not B.险片:                                             # 图例
		var gy := 66*s
		B.画险标图例(c, Vector2(24*s, gy))
	if not B.通好了(): 风.字串(c, sz*0.5, "计算可通行性…", 风.号["中题"], 风.白, "中", HORIZONTAL_ALIGNMENT_CENTER)
	if 鼠.x >= 0.0:
		var g := 屏到地(鼠); var t := "东 %+.1f  北 %+.1f" % [g.x, g.y]
		if B.通好了():
			var k: int = B.通.格号(g.x, -g.y)
			if k >= 0: t += "   坡度 %.1f°   风险 %.2f%s" % [B.通.坡[k], B.通.知.风险(g.x, -g.y), "   不可通行" if B.通.知.堵(g.x, -g.y) else ""]
			else: t += "   网格外（未知）"
		风.字串(c, Vector2(sz.x - 24*s, sz.y - 22*s), t, 风.号["次"], 风.白, "等", HORIZONTAL_ALIGNMENT_RIGHT)


func 画禁区(c: CanvasItem, e: Vector2, r: float) -> void:
	var o := 地到屏(e); var R := r*ppm; var s: float = 风.s
	c.draw_arc(o, R, 0, TAU, 48, Color(风.暗色, 0.6), 5*s, true); c.draw_arc(o, R, 0, TAU, 48, 风.红, 风.宽["框"]*s, true)
	var 距 := 12.0*s; var k := -R
	while k < R:                                                       # 斜线（45°）
		var h := sqrt(maxf(R*R - k*k, 0.0))
		var a := o + Vector2(k, -h).rotated(PI*0.25); var b := o + Vector2(k, h).rotated(PI*0.25)
		c.draw_line(a, b, Color(风.红, 0.45), 1.5*s, true)
		k += 距


func 三角(c: CanvasItem, q: Vector2, r: float, col: Color) -> void:
	var t := PackedVector2Array([q + Vector2(0, -r*1.1), q + Vector2(r, r*0.8), q + Vector2(-r, r*0.8)])
	c.draw_colored_polygon(t, col); t.append(t[0]); c.draw_polyline(t, Color(风.暗色, 0.7), 2.0*风.s, true)


func 整(x: float) -> float:
	var e := pow(10.0, floor(log(maxf(x, 1e-3))/log(10.0))); var m := x/e
	return (5.0 if m >= 5.0 else (2.0 if m >= 2.0 else 1.0))*e


func 距(x: float) -> String:
	return ("%.1f km" % (x/1000.0)) if x >= 1000.0 else ("%d m" % int(x))


# ———————————————————— 右侧：计划表、预算、问题、按键
func _画侧(c: Control) -> void:
	var s: float = 风.s; var w := c.size.x; var 计: RefCounted = B.计划; var r: Dictionary = B.预演
	风.面板(c, Rect2(Vector2.ZERO, c.size), 0.9)
	var x := 24*s; var y := 52*s
	风.题(c, Vector2(x, y), "地图", "火星日 %d · 规划" % B.sol, 风.号["题"]); y += 38*s
	风.字串(c, Vector2(x, y), "当地时 %s · 驾驶时窗 %s–%s" % [B.分到字(B.时刻), B.分到字(B.窗.x), B.分到字(B.窗.y)], 风.号["次"], 风.灰, "中"); y += 46*s
	# 计划表（按列对齐：中文方式名不等宽）
	var 列 := [0.0, 40.0, 236.0, 258.0, 410.0, 506.0]
	var 表头 := ["段", "方式", "长度", "到达", "耗电", "倾角"]
	for k in 6: 风.字串(c, Vector2(x + 列[k]*s, y), 表头[k], 风.号["小"], 风.淡, "中", HORIZONTAL_ALIGNMENT_RIGHT if k in [2, 4, 5] else HORIZONTAL_ALIGNMENT_LEFT)
	y += 30*s
	for i in 计.段数():
		var m: int = int(计.方式[i]); var L: float = 计.段长(i)
		var 格 := [str(i + 1), 自驾脚本.方式名[m].replace("AutoNav", "自主导航"), "%.0f m" % L, "", "", ""]
		if not r.is_empty() and i < r["段"].size():
			var g: Dictionary = r["段"][i]
			格[3] = B.分到字(float(g["到达_ltst"])); 格[4] = "%.0f Wh" % float(g["耗电_Wh"]); 格[5] = "%.1f°" % float(g["最大倾角"])
		elif not r.is_empty(): 格[3] = "—"
		if i == 选段: c.draw_rect(Rect2(x - 10*s, y - 22*s, w - 2*x + 20*s, 30*s), Color(1, 1, 1, 0.10))
		var 色: Color = 风.红 if L > 计.间距上限 else 风.方式色[m]
		for k in 6: 风.字串(c, Vector2(x + 列[k]*s, y), 格[k], 风.号["小"], 色, "中", HORIZONTAL_ALIGNMENT_RIGHT if k in [2, 4, 5] else HORIZONTAL_ALIGNMENT_LEFT)
		y += 30*s
		if y > c.size.y*0.42: 风.字串(c, Vector2(x, y), "…", 风.号["小"], 风.灰, "等"); y += 30*s; break
	if 计.段数() == 0: 风.字串(c, Vector2(x, y), "左键在图上放航点（间距 ≤ 100 m）", 风.号["次"], 风.灰, "正"); y += 30*s
	else: 风.字串(c, Vector2(x, y), "共 %d 段 · %.0f m" % [计.段数(), 计.总长()], 风.号["次"], 风.白, "等中"); y += 30*s
	y += 20*s
	# 预算：电量
	var 容: float = B.能源脚本.容量; var 下: float = 容*B.能源脚本.下限比; var 电: float = B.账.电量
	var 预电 := float(r["账"]["期末_Wh"]) if not r.is_empty() else -1.0
	风.图标(c, "电池", Vector2(x + 12*s, y - 8*s), 26); 风.字串(c, Vector2(x + 36*s, y), "电量 %.0f Wh（%d%%）" % [电, roundi(电/容*100.0)], 风.号["正"], 风.白, "中"); y += 14*s
	var bw := w - 2*x; var bh := 16*s
	条(c, Rect2(x, y, bw, bh), 电/容, 预电/容 if 预电 >= 0.0 else -1.0, 下/容); y += bh + 28*s
	var 发: float = B.能源脚本.发电功率(B.sol)
	var t2 := "下限 %d%% · 发电 %.0f W · 日常 %.0f W" % [roundi(B.能源脚本.下限比*100), 发, B.能源脚本.日常]
	if 预电 >= 0.0: t2 = "预演后 %.0f Wh（%d%%）· " % [预电, roundi(预电/容*100.0)] + t2
	风.字串(c, Vector2(x, y), t2, 风.号["小"], 风.红 if (预电 >= 0.0 and 预电 < 下) else 风.灰, "正"); y += 40*s
	# 预算：时窗
	var 完 := float(r.get("结束_ltst", -1.0))
	风.图标(c, "时刻", Vector2(x + 12*s, y - 8*s), 26); 风.字串(c, Vector2(x + 36*s, y), "时窗 %s–%s" % [B.分到字(B.窗.x), B.分到字(B.窗.y)], 风.号["正"], 风.白, "中"); y += 14*s
	var 窗长: float = B.窗.y - B.窗.x
	条(c, Rect2(x, y, bw, bh), (完 - B.窗.x)/窗长 if 完 >= 0.0 else 0.0, -1.0, -1.0); y += bh + 28*s
	if 完 >= 0.0: 风.字串(c, Vector2(x, y), "预计 %s 结束 · 剩 %.0f 分钟" % [B.分到字(完), maxf(0.0, B.窗.y - 完)], 风.号["小"], 风.灰, "正")
	else: 风.字串(c, Vector2(x, y), "空格预演，算出预计结束时刻和耗电", 风.号["小"], 风.灰, "正")
	y += 44*s
	# 预演摘要和问题
	var 问题: Array = 计.校验()
	var 注: Array = []
	if not r.is_empty():
		var n险 := 0; var n绕 := 0
		for e: Dictionary in r["事件"]:
			if e["类"] == "高风险": n险 += 1
			elif e["类"] == "绕行": n绕 += 1
		var 到 := String(r["停因"]) == "到达"
		风.图标(c, "预演" if 到 else "倾角_警告", Vector2(x + 12*s, y - 8*s), 26, 风.白 if 到 else 风.红)
		风.字串(c, Vector2(x + 36*s, y), "预演：%s" % ("到达终点" if 到 else "警告 · 停车 · " + String(r["停因"])), 风.号["正"], 风.白 if 到 else 风.红, "中"); y += 30*s
		风.字串(c, Vector2(x, y), "%.0f m · %.0f 分钟 · 最大倾角 %.1f° · 高风险 %d 处 · 绕行 %d 次" % [float(r["里程_m"]), float(r["用时_s"])/60.0, float(r["最大倾角"]), n险, n绕], 风.号["小"], 风.灰, "正"); y += 28*s
		if float(r["最大倾角"]) >= 20.0: 注.append("预计倾角 %.1f°（上限 %.0f°）" % [float(r["最大倾角"]), B.倾角上限])
		if float(r.get("偏_m", 0.0)) > 0.5: 注.append("盲开打滑：预计停在航点前 %.1f m" % float(r["偏_m"]))
		if n险 > 0: 注.append("高风险段 %d 处（看图上琥珀 ▲）" % n险)
	elif B.预演任务 >= 0: 风.字串(c, Vector2(x, y), "预演中…", 风.号["正"], 风.白, "中"); y += 30*s
	y += 6*s
	for q in 问题:
		风.字串(c, Vector2(x, y), "✗ " + String(q), 风.号["小"], Color(风.红, 1.0 if 闪 <= 0.0 else 0.4 + 0.6*float(int(闪*6.0) % 2)), "正"); y += 28*s
	for q in 注:
		风.字串(c, Vector2(x, y), "! " + String(q), 风.号["小"], 风.琥珀, "正"); y += 28*s
	# 按键
	var ky := c.size.y - 230*s
	for kv in [["左键", "放航点 · 拖航点 · 点航段选中"], ["右键", "删航点 / 禁行区 · 拖动地图"], ["Shift+拖", "画禁行区"], ["1 2 3", "盲开 / 视觉里程计 / 自主导航（Shift：全部）"],
			["空格 · V", "预演 · 在 3D 里看"], ["Enter", "上传并执行"], ["L · ⌫", "可通行性层 · 删最后航点"], ["F2 · Esc", "回手动驾驶（草稿保留）"]]:
		风.字串(c, Vector2(x, ky), String(kv[0]), 风.号["小"], 风.白, "中"); 风.字串(c, Vector2(x + 120*s, ky), String(kv[1]), 风.号["小"], 风.灰, "正"); ky += 27*s


func 条(c: CanvasItem, r: Rect2, v: float, 预: float, 限: float) -> void:
	"""预算条：细框 + 实心（当前）；预 ≥ 0 时，当前到预计之间画斜线（要用掉的）；限 ≥ 0 画一道下限刻度。"""
	var s: float = 风.s
	c.draw_rect(r, Color(风.暗色, 0.5)); c.draw_rect(r, Color(风.白, 0.6), false, maxf(1.0, 1.5*s))
	var fv := clampf(v, 0.0, 1.0)
	if 预 >= 0.0:
		var fp := clampf(预, 0.0, 1.0)
		c.draw_rect(Rect2(r.position, Vector2(r.size.x*fp, r.size.y)), Color(风.白, 0.85))
		var x := r.position.x + r.size.x*fp
		while x < r.position.x + r.size.x*fv:
			c.draw_line(Vector2(x, r.end.y), Vector2(minf(x + r.size.y, r.position.x + r.size.x*fv), r.position.y), Color(风.琥珀, 0.9), 2.0*s)
			x += 8*s
	else: c.draw_rect(Rect2(r.position, Vector2(r.size.x*fv, r.size.y)), Color(风.白, 0.85))
	if 限 >= 0.0:
		var lx := r.position.x + r.size.x*限
		c.draw_line(Vector2(lx, r.position.y - 6*s), Vector2(lx, r.end.y + 6*s), 风.红, 风.宽["粗"]*s)


# ———————————————————— 底部 sol 时间线（00–24 LTST）
func _画时(c: Control) -> void:
	var s: float = 风.s; var w := c.size.x; var y0 := 46*s; var h := 34*s
	var X := func(m: float) -> float: return w*clampf(m/1440.0, 0.0, 1.0)
	c.draw_rect(Rect2(0, y0, w, h), 风.夜色)                          # 夜
	c.draw_rect(Rect2(X.call(日出), y0, X.call(日落) - X.call(日出), h), 风.日照色)   # 日照
	var 完 := float(B.预演.get("结束_ltst", -1.0)); var 起: float = maxf(B.时刻, B.窗.x)
	if 完 >= 0.0: c.draw_rect(Rect2(X.call(起), y0 + h*0.25, X.call(完) - X.call(起), h*0.5), Color(风.白, 0.9))
	c.draw_rect(Rect2(X.call(B.窗.x), y0 - 4*s, X.call(B.窗.y) - X.call(B.窗.x), h + 8*s), 风.琥珀, false, 风.宽["框"]*s)   # 驾驶时窗
	for hh in 25:
		var x: float = X.call(hh*60.0); var L := 12.0*s if hh % 3 == 0 else 6.0*s
		c.draw_line(Vector2(x, y0 + h), Vector2(x, y0 + h + L), Color(风.白, 0.7), 1.5*s)
		if hh % 3 == 0: 风.字串(c, Vector2(x, y0 + h + 34*s), "%02d" % hh, 风.号["小"], 风.灰, "等", HORIZONTAL_ALIGNMENT_CENTER)
	var xn: float = X.call(B.时刻)
	c.draw_colored_polygon(PackedVector2Array([Vector2(xn, y0 - 2*s), Vector2(xn - 8*s, y0 - 16*s), Vector2(xn + 8*s, y0 - 16*s)]), 风.白)
	风.字串(c, Vector2(xn, y0 - 22*s), "现在 %s" % B.分到字(B.时刻), 风.号["小"], 风.白, "等中", HORIZONTAL_ALIGNMENT_CENTER)
	风.字串(c, Vector2((X.call(B.窗.x) + X.call(B.窗.y))*0.5, y0 - 22*s), "驾驶时窗", 风.号["小"], 风.琥珀, "中", HORIZONTAL_ALIGNMENT_CENTER)
	if 完 >= 0.0: 风.字串(c, Vector2(X.call(完) + 8*s, y0 + h*0.5 + 7*s), "预计 %s" % B.分到字(完), 风.号["小"], 风.白, "等中")
	风.字串(c, Vector2(0, y0 - 22*s), "火星日 %d 时间线（当地时）· 日照约 %s–%s" % [B.sol, B.分到字(日出), B.分到字(日落)], 风.号["小"], 风.灰, "正")


# ———————————————————— 输入
func 命中点(q: Vector2) -> int:
	var 计: RefCounted = B.计划; var best := -1; var bd: float = 16.0*风.s
	for i in range(1, 计.航点.size()):
		var d := 地到屏(计.航点[i]).distance_to(q)
		if d < bd: bd = d; best = i
	return best


func 命中段(q: Vector2) -> int:
	var 计: RefCounted = B.计划; var best := -1; var bd: float = 9.0*风.s
	for i in 计.段数():
		var d: float = 计.线距(q, 地到屏(计.航点[i]), 地到屏(计.航点[i + 1]))
		if d < bd: bd = d; best = i
	return best


func _图输入(ev: InputEvent) -> void:
	var 计: RefCounted = B.计划
	if ev is InputEventMouseMotion:
		鼠 = ev.position
		if 拖点 >= 1: 计.航点[拖点] = 屏到地(鼠); B.改计划(); 侧.queue_redraw(); 时.queue_redraw()
		elif 画禁: 禁半 = 屏到地(鼠).distance_to(禁心)
		elif 右按 or (ev.button_mask & MOUSE_BUTTON_MASK_MIDDLE):
			if 右起.distance_to(鼠) > 4.0: 右移 = true
			if 右移: 心 -= Vector2(ev.relative.x, -ev.relative.y)/ppm; 底远.queue_redraw(); 底高.queue_redraw(); 叠.queue_redraw()
		标.queue_redraw()
		return
	if not (ev is InputEventMouseButton): return
	var q: Vector2 = ev.position
	if ev.pressed and (ev.button_index == MOUSE_BUTTON_WHEEL_UP or ev.button_index == MOUSE_BUTTON_WHEEL_DOWN):
		var g := 屏到地(q)
		ppm = clampf(ppm*(1.25 if ev.button_index == MOUSE_BUTTON_WHEEL_UP else 0.8), 0.05, 40.0)
		心 = g - Vector2((q.x - 图.size.x*0.5)/ppm, -(q.y - 图.size.y*0.5)/ppm)
		刷新(); return
	if ev.button_index == MOUSE_BUTTON_LEFT:
		if ev.pressed:
			if ev.shift_pressed: 画禁 = true; 禁心 = 屏到地(q); 禁半 = 0.0; return
			var k := 命中点(q)
			if k >= 1: 拖点 = k; return
			var sg := 命中段(q)
			if sg >= 0: 选段 = sg; 刷新(); return
			加航点(屏到地(q))
		else:
			if 画禁 and 禁半 >= 2.0: 计.禁.append(Vector3(禁心.x, 禁心.y, 禁半)); B.改计划()
			画禁 = false; 拖点 = -1; 刷新()
	elif ev.button_index == MOUSE_BUTTON_RIGHT or ev.button_index == MOUSE_BUTTON_MIDDLE:
		if ev.pressed: 右按 = true; 右起 = q; 右移 = false; return
		if ev.button_index == MOUSE_BUTTON_RIGHT and not 右移:
			var k := 命中点(q)
			if k >= 1: 删航点(k)
			else:
				var g := 屏到地(q)
				for i in range(计.禁.size() - 1, -1, -1):
					if Vector2(计.禁[i].x, 计.禁[i].y).distance_to(g) < 计.禁[i].z: 计.禁.remove_at(i); B.改计划(); break
		右按 = false; 右移 = false; 刷新()


func 加航点(e: Vector2) -> void:
	var 计: RefCounted = B.计划
	计.航点.append(e)
	计.方式.append(int(计.方式[-1]) if not 计.方式.is_empty() else 1)
	选段 = 计.段数() - 1
	B.改计划(); 刷新()


func 删航点(k: int) -> void:
	var 计: RefCounted = B.计划
	if k < 1 or k >= 计.航点.size(): return
	if k < 计.航点.size() - 1: 计.方式.remove_at(k)
	else: 计.方式.remove_at(k - 1)
	计.航点.remove_at(k)
	选段 = mini(选段, 计.段数() - 1)
	B.改计划(); 刷新()


func 设方式(m: int, 全部: bool) -> void:
	var 计: RefCounted = B.计划
	if 全部:
		for i in 计.段数(): 计.方式[i] = m
	elif 选段 >= 0 and 选段 < 计.段数(): 计.方式[选段] = m
	elif 计.段数() > 0: 计.方式[-1] = m
	B.改计划(); 刷新()


func 输入(ev: InputEvent) -> void:
	if not (ev is InputEventKey and ev.pressed and not ev.echo): return
	match ev.keycode:
		KEY_1, KEY_KP_1: 设方式(0, ev.shift_pressed)
		KEY_2, KEY_KP_2: 设方式(1, ev.shift_pressed)
		KEY_3, KEY_KP_3: 设方式(2, ev.shift_pressed)
		KEY_BACKSPACE: 删航点(B.计划.航点.size() - 1)
		KEY_L: 层开 = not 层开; 刷新()
		KEY_SPACE:
			if B.预演.is_empty(): B.跑预演()
			else: B.影.放(B.预演, false)
			刷新()
		KEY_V:
			if not B.预演.is_empty(): B.影.进预演()
			else: B.提示 = "先按空格预演"; B.提示时 = 2.0
		KEY_ENTER, KEY_KP_ENTER:
			if not B.上传(): 闪 = 1.2; 侧.queue_redraw()
		KEY_ESCAPE, KEY_F2: B.离开()
		_: return
	get_viewport().set_input_as_handled()


func _process(dt: float) -> void:
	if 闪 > 0.0: 闪 -= dt; 侧.queue_redraw()
	if 开着 and B.预演任务 >= 0: 侧.queue_redraw()
