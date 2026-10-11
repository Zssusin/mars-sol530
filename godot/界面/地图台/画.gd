# 全息地形台的 2D 层：页头、档位、工具栏、右表、状态栏、地图标记（渐进出现、不重叠、≤ 7 个文字标签）、读数光标。
#   版式按 docs/界面/地图样张/生成/全息.py 模式 F 的坐标（2560×1440 逻辑像素，乘 令.s）；颜色字号线宽全走令牌和件。
extends Control

const 件 := preload("res://界面/件.gd")
const 杆长 := {"observation_mountain": 40, "amalik": 40, "enchanted_lake": 40, "three_forks": 55, "hawksbill_gap": 120, "butler_landing": 95}
const 文字上限 := 7
var M: Node
var s := 1.0
var 命中表: Array = []                              # [[Rect2, 键]]（后画的在上）
var 悬停键: Variant = null
var 悬停时 := 0.0
var 进表: Dictionary = {}                           # 件.进：元素出现进度
var 悬停表: Dictionary = {}
var 数字组: Array = []                              # 本帧放下的文字标签外框（排重）
var 本帧文字 := 0
var 可见缓: Dictionary = {}
var 帧号 := 0
var 等高数: Array = []                              # [{E, N, 字, 层}]
var 等高签 := ""
var 等高算时 := 0.0
var 引线点: PackedVector3Array = PackedVector3Array()
var 引线签 := ""
var 路点表: Array = []
var 统计 := {"文字": 0, "重叠": 0, "框": []}        # 自测读
var 上次dt := 0.016
var 开始 := 0
var 显示: Dictionary = {}                         # 本帧各类标记画了几个（自测对规范 §2 的表）


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR


func 命中(p: Vector2) -> Variant:
	for i in range(命中表.size() - 1, -1, -1):
		var r: Rect2 = 命中表[i][0]
		var e := r
		if e.size.x < 44*s: e = e.grow_individual((44*s - e.size.x)*0.5, 0, (44*s - e.size.x)*0.5, 0)
		if e.size.y < 44*s: e = e.grow_individual(0, (44*s - e.size.y)*0.5, 0, (44*s - e.size.y)*0.5)
		if e.grow(8.0*s).has_point(p): return 命中表[i][1]
	return null


func 在地图上(p: Vector2) -> bool:
	return p.x > 140*s and p.x < 2040*s and p.y > 190*s and p.y < 1330*s


func 点(x: float, y: float) -> Vector2:
	return Vector2(x, y)*s


func 色(k: String, a := 1.0) -> Color:
	var c: Color = 令.色[k]; return Color(c, c.a*a)


# ———————————————————— 入口
func _draw() -> void:
	if M == null or not M.开着: return
	s = 令.s; 帧号 += 1
	命中表.clear(); 数字组.clear(); 本帧文字 = 0
	显示 = {"路点": 0, "发现": 0, "未发现": 0, "地名": [], "等高数": 0, "簇": 0, "簇员": 0, "圈": 0}
	var dt: float = get_process_delta_time(); 上次dt = dt
	var 钟: float = M.钟; var 动: bool = M.态 != "开"
	if not 动: 钟 = M.总长
	var a页 = M.段内(0.0, 0.3) if 动 else 1.0
	var 悬: Variant = null
	if M.态 == "开" and M.鼠.x >= 0: 悬 = 命中(M.鼠)
	var 悬s := str(悬)
	悬停点 = 悬s.substr(2) if (悬s.begins_with("点:") or 悬s.begins_with("行:")) else ""
	if str(悬) != str(悬停键): 悬停键 = 悬; 悬停时 = 0.0
	else: 悬停时 += dt
	var 样: bool = M.样张
	北向 = _北向()
	_垫板(a页)
	_页头(a页)
	_工具栏(a页)
	_表(M.段内(1.7, 2.3) if 动 else 1.0)
	_状态栏(a页)
	if M.态 != "关中" or true: _标记层(dt, 钟, 动)
	_光标(M.段内(3.4, 3.6) if 动 else 1.0)
	if M.图层页: _图层页()
	if M.帮助页: _帮助页()
	if M.吐司时 > 0.0: 件.字串(self, 点(1280, 1290), M.吐司, 26, 色("主"), "中", HORIZONTAL_ALIGNMENT_CENTER)
	if M.测:
		统计["文字"] = 本帧文字


# ———————————————————— 页头、档位
func _页头(a: float) -> void:
	if a <= 0.0: return
	var ph := Color(1, 1, 1, a)
	件.图标(self, "地图", 点(90, 122), 52, 色("主", a))
	件.字距(self, 点(132, 136), "地图", 40, 色("主", a), "细", 6.0*s)
	var wtitle: float = 件.宽度("地图", 40, "细")/s + 12.0
	var ltst: String = String(M.P.ltst) if "ltst" in M.P else "14:10"
	件.字串(self, 点(132 + wtitle + 40, 136), "SOL 530 · " + ltst, 22, 色("次", a*0.9), "等", HORIZONTAL_ALIGNMENT_LEFT, -1.0, true)
	件.线(self, 点(132, 152), 点(182, 152), 色("强", a), 3.0, false)
	# 三档：只写范围；当前档下划线（活色）滑到位
	var 档名 := [["200 m", "1", 200.0], ["2 km", "2", 2000.0], ["25 km", "3", 25000.0]]
	var ox := 1060.0
	var 当前 := -1
	var bd := 9.0
	for i in 3:
		var d: float = absf(log(M.半/档名[i][2]))
		if d < bd: bd = d; 当前 = i
	if bd > 0.5: 当前 = -1
	var 下划x := 0.0; var 下划w := 0.0
	for i in 3:
		var t: String = 档名[i][0]; var w: float = 件.宽度(t, 26, "等")/s
		var sel := i == 当前
		件.字串(self, 点(ox, 136), t, 26, 色("活亮" if 令.有活边 else "活", a) if sel else 色("次", a), "等中" if sel else "等")
		命中表.append([Rect2(点(ox - 6, 108), 点(w + 12, 40)), "档:" + 档名[i][1]])
		if sel: 下划x = ox; 下划w = w
		ox += w + 56
	if 当前 >= 0:
		进表["下划x"] = lerpf(进表.get("下划x", 下划x), 下划x, 1.0 - exp(-上次dt/0.06))
		进表["下划w"] = lerpf(进表.get("下划w", 下划w), 下划w, 1.0 - exp(-上次dt/0.06))
		件.线(self, 点(进表["下划x"], 148), 点(进表["下划x"] + 进表["下划w"], 148), 色("活亮" if 令.有活边 else "活", a), 3.0, false)
	# 关闭
	var 关悬: bool = M.态 == "开" and 悬停键 == "关"
	件.图标(self, "关闭", 点(2464, 120), 40, 色("主", a*(1.0 if 关悬 else 0.9)))
	var kw: float = 件.键帽(self, 点(2376, 130), "Esc", 色("主", a), 17)
	命中表.append([Rect2(点(2340, 90), 点(150, 60)), "关"])


# ———————————————————— 左工具栏
func _工具栏(a: float) -> void:
	if a <= 0.0: return
	var 项 := [["指针", "", "选择"], ["剖面", "P", "剖面"], ["航点", "Enter", "航点"], ["图层", "Tab", "图层"], null, ["立体", "V", "垂直放大"], ["指北", "N", "指北"], ["放大", "+", "放大"], ["缩小", "-", "缩小"], null, ["帮助", "F1", "帮助"]]
	var x := 64.0; var y := 250.0
	for it in 项:
		if it == null:
			件.线(self, 点(x + 4, y + 4), 点(x + 44, y + 4), 色("次", a*0.4), 1.0, false); y += 22; continue
		var 名: String = it[0]; var 当前 := 名 == "指针"
		var 键名 := "工具:" + 名
		var 悬 := 悬停键 != null and str(悬停键) == 键名
		var 禁 := 名 == "剖面"
		var 进: float = 件.进(悬停表, 键名, 悬, 上次dt, 令.时["闪"]*0.8, 令.时["闪"]*0.8)
		var 亮 := 1.0 if (当前 or 悬) else 0.82
		var 活 := 当前 or (悬 and not 禁)
		var col: Color = 色("活亮" if 令.有活边 else "活", a) if 活 else 色("主", a*(0.5 if 禁 else lerpf(0.82, 1.0, 进)))
		var c := Vector2(x + 24, y + 24)*s
		if 悬 and not 禁 and 进 > 0.0 and not 当前: c.y -= 0.0
		if 名 == "指北": _罗盘(c, 19.0*s, col, false)
		else: 件.图标(self, 名, c, 48, col)
		if 当前: 件.线(self, 点(x - 14, y + 2), 点(x - 14, y + 46), 色("活亮" if 令.有活边 else "活", a), 4.0, false)
		命中表.append([Rect2(点(x - 4, y), 点(56, 48)), 键名])
		if 悬 and 悬停时 >= 0.35 and M.态 == "开":
			var ta := minf(1.0, (悬停时 - 0.35)/0.1)
			件.线(self, 点(x + 56, y + 24), 点(x + 74, y + 24), 色("主", a*0.7*ta), 1.5, false)
			件.字串(self, 点(x + 84, y + 32), it[2], 24, 色("主", a*ta), "细")
			if it[1] != "": 件.键帽(self, 点(x + 84 + 件.宽度(it[2], 24, "细")/s + 14, y + 34), it[1], 色("主", a*ta), 17)
		y += 66


func _罗盘(c: Vector2, r: float, col: Color, 字: bool) -> void:
	"""圆环 + 指向地图上真北的针（尖端实心，尾部空心）；字 = 真时在环上方写「北」。"""
	var nd := 北向; var nr := Vector2(-nd.y, nd.x)
	件.弧(self, c, r, 0.0, TAU, Color(col, col.a*0.7), 1.5, 28)
	var tip := c + nd*(r*0.86); var tail := c - nd*(r*0.62)
	draw_colored_polygon(PackedVector2Array([tip, c + nr*(r*0.34), c - nd*(r*0.1), c - nr*(r*0.34)]), col)
	件.折(self, PackedVector2Array([tail, c + nr*(r*0.34), c - nd*(r*0.1), c - nr*(r*0.34), tail]), Color(col, col.a*0.8), 1.5)
	if 字: 件.字串(self, c + Vector2(r + 10*s, 7*s), "北", 20, col, "粗")


# ———————————————————— 右表
func 短名(p: Dictionary) -> String:
	match p["id"]:
		"butler_landing": return "着陆点"
		"jezero_rim": return "坑缘"
		"sol535_tracks": return "车辙"
	var 词: PackedStringArray = String(p["名"]).split(" ")
	var o: String = 词[0]
	if 词.size() > 1 and 词[1].unicode_at(0) < 128: o += " " + 词[1]
	return o


func 车U() -> float:
	return M.数.高(M.车E, M.车N)


func 点列() -> Array:
	var rows: Array = []
	for p in M.点表():
		var d := Vector2(p["E"] - M.车E, p["N"] - M.车N).length()
		rows.append([d, p])
	rows.sort_custom(func(a, b): return a[0] < b[0])
	return rows


func 高差标(x: float, y: float, U: float, 号: float, col: Color) -> float:
	"""▲12 m / ▼22 m / —（x 左端、y 基线，逻辑像素）；返回宽度（逻辑像素）。"""
	if not is_finite(U):
		print("[地图台] 高差 NaN"); return 0.0
	if absf(U) < 1.5:
		件.字串(self, 点(x, y), "—", 号, col, "等", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 号 <= 20); return 号*0.7
	var t := "%d m" % roundi(absf(U))
	var tx := x + 号*0.3; var ty := y - 号*0.08; var sz := 号*0.6; var h := sz*0.9
	var pts := PackedVector2Array()
	if U > 0: pts = PackedVector2Array([点(tx - sz*0.5, ty), 点(tx + sz*0.5, ty), 点(tx, ty - h)])
	else: pts = PackedVector2Array([点(tx - sz*0.5, ty - h), 点(tx + sz*0.5, ty - h), 点(tx, ty)])
	if absf((pts[1] - pts[0]).x) > 0.5 and absf(pts[2].y - pts[0].y) > 0.5: draw_colored_polygon(pts, col)
	件.字串(self, 点(x + 号*0.75, y), t, 号, col, "等中", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 号 <= 20)
	return 号*0.75 + 件.宽度(t, 号, "等中")/s


func 菱形(p: Vector2, r: float, col: Color, 实: bool, w := 2.0) -> void:
	var pts := PackedVector2Array([p + Vector2(0, -r), p + Vector2(r, 0), p + Vector2(0, r), p + Vector2(-r, 0)])
	if 实 and r > 2.0: draw_colored_polygon(pts, col)
	var cl := pts.duplicate(); cl.append(pts[0])
	件.折(self, cl, col, w) if not 实 else 件.折(self, cl, col, w*0.5)


func _表(a: float) -> void:
	if a <= 0.0: return
	var x := 2070.0; var y := 250.0
	var c距 := x + 280.0; var c高 := x + 372.0; var c方 := x + 236.0
	var 活: Color = 色("活亮" if 令.有活边 else "活")
	var 主 := 色("主", a)
	件.图标(self, "兴趣点_已发现", 点(x - 4 + 15, y - 28 + 15), 30, Color(主, 0.8*a)); 件.图标(self, "指北", 点(c方 - 12 + 12, y - 26 + 12), 24, Color(主, 0.7*a))
	件.图标(self, "距离", 点(c距 + 6 + 14, y - 28 + 14), 28, Color(主, 0.8*a)); 件.图标(self, "剖面", 点(c高 + 6 + 14, y - 28 + 14), 28, Color(主, 0.8*a))
	件.线(self, 点(x, y + 12), 点(x + 440, y + 12), 色("次", a*0.4), 1.0, false)
	var yy := y + 54.0
	var clipA := a
	var 行 := 点列()
	for r in 行:
		var p: Dictionary = r[1]; var d: float = r[0]
		var 键 := "行:" + str(p["id"]); var sel: bool = p["id"] == M.选中
		var 悬: bool = 悬停键 != null and str(悬停键) == 键
		var 地悬: bool = M.态 == "开" and 悬停点 == p["id"]
		var hv: float = 件.进(悬停表, 键, 悬 or 地悬, 上次dt, 0.08, 0.08)
		var 发 = M.已发现(p)
		var col: Color = (活 if sel else 主)
		col.a *= a
		var ta := (1.0 if 发 else 0.6)
		if hv > 0.0 and not sel: draw_rect(Rect2(点(x - 24, yy - 30), 点(488, 40)), Color(色("主"), 0.08*hv*a))
		if sel: 件.线(self, 点(x - 18, yy - 26), 点(x - 18, yy + 10), Color(活, a), 4.0, false)
		var pc := 点(x + 7, yy - 8)
		菱形(pc, 7.0*s, Color(col, col.a*ta), 发, 1.8)
		var 名 := 短名(p) if 发 else "?"
		件.字串(self, 点(x + 28, yy), 名, 22, Color(col, col.a*ta), "粗" if sel else "正")
		# 方位箭头
		var 方 := atan2(p["E"] - M.车E, p["N"] - M.车N)
		var pts := PackedVector2Array()
		for q in [Vector2(0, -9), Vector2(5, 7), Vector2(0, 3.5), Vector2(-5, 7)]: pts.append(点(c方, yy - 8) + (q*s).rotated(方))
		draw_colored_polygon(pts, Color(col, col.a*ta))
		var dtxt: String = 令.距字(件.数到(d, M.选中新) if sel else d)
		件.字串(self, 点(c距 + 78, yy), dtxt, 20, Color(col, col.a*ta), "等", HORIZONTAL_ALIGNMENT_RIGHT, -1.0, true)
		var dU: float = M.数.高(p["E"], p["N"]) - 车U()
		高差标(c高 + 4, yy, 件.数到(dU, M.选中新) if sel else dU, 20, Color(col, col.a*ta))
		命中表.append([Rect2(点(x - 24, yy - 32), 点(488, 44)), 键])
		yy += 46.0
	yy += 8.0
	件.线(self, 点(x, yy - 22), 点(x + 440, yy - 22), 色("次", a*0.4), 1.0, false)
	var bx := x
	for b in [["航点", "Enter", "按钮:航点"], ["相册", "Space", ""], ["相机_自由", "F", "按钮:飞"]]:
		var cy := yy + 22.0
		var en = b[2] != "" 
		件.图标(self, b[0], 点(bx + 22, cy), 44, 色("主", a*(1.0 if en else 0.5)))
		var kw: float = 件.键帽(self, 点(bx + 52, cy + 10), b[1], 色("主", a*(1.0 if en else 0.5)), 17)
		if en: 命中表.append([Rect2(点(bx, yy), 点(52 + kw/s, 44)), b[2]])
		bx += 52 + kw/s + 34
var 悬停点 := ""
var 北向 := Vector2(0, -1)
var 徽框们: Array = []
var 圈标: Array = []
var 垫板们: Array = []                                # 自测量对比度：[Rect2, 说明]


func _北向() -> Vector2:
	var 焦屏: Vector3 = M.地屏(M.焦.x, M.焦.y); var 北屏: Vector3 = M.地屏(M.焦.x, M.焦.y + M.半*0.2)
	var nd := Vector2(北屏.x - 焦屏.x, 北屏.y - 焦屏.y)
	return nd.normalized() if nd.length() > 1e-3 else Vector2(0, -1)


func 软块(r: Rect2, 淡: float, 边: String) -> void:
	"""实心矩形，指定的边（l t r b）向外淡出 淡 像素（4×4 个顶点的双线性渐变，九块拼成），没指定的边贴屏幕边、不淡。"""
	var 底: Color = 垫色; var c1 := Color(底, 0.88)
	var xs := [r.position.x, r.position.x + (淡 if "l" in 边 else 0.0), r.end.x - (淡 if "r" in 边 else 0.0), r.end.x]
	var ys := [r.position.y, r.position.y + (淡 if "t" in 边 else 0.0), r.end.y - (淡 if "b" in 边 else 0.0), r.end.y]
	for j in 3:
		for i in 3:
			if xs[i + 1] - xs[i] < 0.5 or ys[j + 1] - ys[j] < 0.5: continue
			var 角 := [[i, j], [i + 1, j], [i + 1, j + 1], [i, j + 1]]
			var pts := PackedVector2Array(); var cols := PackedColorArray()
			for c in 角:
				pts.append(Vector2(xs[c[0]], ys[c[1]]))
				var 外 := false
				if c[0] == 0 and "l" in 边: 外 = true
				if c[0] == 3 and "r" in 边: 外 = true
				if c[1] == 0 and "t" in 边: 外 = true
				if c[1] == 3 and "b" in 边: 外 = true
				cols.append(Color(底, 0.0) if 外 else c1)
			draw_polygon(pts, cols)


var 垫色 := Color(0.04, 0.045, 0.055)


func _垫板(a: float) -> void:
	"""页头、左工具栏、右表、状态栏后面压暗地图：字对它所在区域背景的亮度 ≥ 7:1（地图线再亮也只有 ≈ 12 % 透出）。颜色取地图底色（去饱和），边缘渐隐、不留硬边。"""
	if a <= 0.0: return
	var 底: Color = 色("页底"); var g := 底.get_luminance()
	垫色 = Color(lerpf(底.r, g, 0.75), lerpf(底.g, g, 0.75), lerpf(底.b, g, 0.75)).darkened(0.1)
	垫色.a = a
	软块(Rect2(点(0, -10), 点(2560, 270)), 70.0*s, "b")
	软块(Rect2(点(0, 1250), 点(2560, 200)), 70.0*s, "t")
	软块(Rect2(点(-10, 150), 点(260, 1140)), 90.0*s, "rtb")
	软块(Rect2(点(1960, 150), 点(620, 840)), 90.0*s, "ltb")
	垫板们 = [[Rect2(点(0, 0), 点(2560, 176)), "页头"], [Rect2(点(0, 1296), 点(2560, 144)), "状态栏"], [Rect2(点(0, 232), 点(150, 1018)), "工具栏"], [Rect2(点(2030, 232), 点(530, 700)), "右表"]]


# ———————————————————— 状态栏
func _状态栏(a: float) -> void:
	if a <= 0.0: return
	var y := 1372.0
	件.线(self, 点(64, y - 44), 点(2496, y - 44), 色("次", a*0.35), 1.0, false)
	var g: Variant = M.悬停地
	var fa: float = M.悬停淡
	if M.样张: g = Vector3(-180, M.数.高(-180, -680), -680); fa = 1.0
	var 主 := 色("主", a)
	var x := 64.0
	if g != null or fa > 0.0:
		var gg: Vector3 = g if g != null else 上读数
		if g != null: 上读数 = gg
		var fc := a*fa
		var E := gg.x; var N := gg.z
		件.图标(self, "坐标", 点(64 + 17, y - 30 + 17), 34, 色("主", fc*0.85)); x += 46
		var t := ("E %+d  N %+d" % [roundi(E), roundi(N)]).replace("-", "−")
		件.字串(self, 点(x, y), t, 22, 色("主", fc), "等", HORIZONTAL_ALIGNMENT_LEFT, -1.0, false)
		x += 件.宽度(t, 22, "等")/s + 48
		var dU: float = gg.y - 车U()
		x += 高差标(x, y, dU, 22, 色("主", fc)) + 48
		件.图标(self, "坡度", 点(x + 17, y - 30 + 17), 34, 色("主", fc*0.85)); x += 44
		var sl: float = M.数.坡(E, N, maxf(5.0, M.每像素米()*2.0))
		var t2 := "%d°" % roundi(sl)
		件.字串(self, 点(x, y), t2, 22, 色("主", fc), "等"); x += 件.宽度(t2, 22, "等")/s + 48
		件.图标(self, "距离", 点(x + 17, y - 30 + 17), 34, 色("主", fc*0.85)); x += 44
		件.字串(self, 点(x, y), 令.距字(Vector2(E - M.车E, N - M.车N).length()), 22, 色("主", fc), "等")
	# 图例小片
	x = 1180.0
	件.线(self, 点(x, y - 8), 点(x + 44, y - 8), 色("活亮" if 令.有活边 else "活", a), 4.0, false)
	件.字串(self, 点(x + 56, y), "SOL 0–530", 20, 色("主", a*0.9), "等", HORIZONTAL_ALIGNMENT_LEFT, -1.0, true)
	x += 56 + 件.宽度("SOL 0–530", 20, "等")/s + 44
	for k in 5: draw_circle(点(x + 4 + k*9, y - 8 + (k % 2)*4), 1.8*s, Color(主, 0.9))
	件.图标(self, "眼", 点(x + 52 + 14, y - 26 + 14), 28, 色("主", a*0.85)); x += 52 + 28 + 44
	for k in 3: draw_circle(点(x + 6 + k*14, y - 8), (2 + k)*s, 色("注意", a*0.9))
	件.字串(self, 点(x + 52, y), "> 20°", 20, 色("主", a*0.9), "等", HORIZONTAL_ALIGNMENT_LEFT, -1.0, true)
	# 比例尺：取 1、2、5 × 10ⁿ 米，长度约 120–250 px
	var mpp: float = M.每像素米()
	var 目标 := 160.0*mpp
	var e := pow(10.0, floor(log(目标)/log(10.0))); var m := 目标/e
	var 整 := (5.0 if m >= 5.0 else (2.0 if m >= 2.0 else 1.0))*e
	var L := 整/mpp/s
	var x0 := 2496.0 - L - 130.0
	件.线(self, 点(x0, y - 8), 点(x0 + L, y - 8), 色("主", a), 2.0, false); 件.线(self, 点(x0, y - 16), 点(x0, y), 色("主", a), 2.0, false); 件.线(self, 点(x0 + L, y - 16), 点(x0 + L, y), 色("主", a), 2.0, false)
	件.字串(self, 点(x0 - 14, y), 令.距字(整), 20, 色("主", a*0.9), "等", HORIZONTAL_ALIGNMENT_RIGHT, -1.0, true)
	_罗盘(点(1800, y - 8), 17.0*s, 色("主", a*0.95), true)
	件.图标(self, "立体", 点(2496 - 100 + 15, y - 30 + 15), 30, 色("主", a*0.8))
	件.字串(self, 点(2496, y), "×%d" % roundi(M.垂放), 20, 色("主", a*0.9), "等", HORIZONTAL_ALIGNMENT_RIGHT, -1.0, true)
var 上读数 := Vector3.ZERO


# ———————————————————— 光标
func _光标(a: float) -> void:
	var g: Variant = M.悬停地
	var fa: float = M.悬停淡
	if M.样张: g = Vector3(-180, M.数.高(-180, -680), -680); fa = 1.0
	if g == null or a <= 0.0: return
	var p: Vector3 = M.投(Vector3(g.x, g.y*M.垂放 + 2.0, -g.z))
	if p.z <= 0: return
	var c := Vector2(p.x, p.y); var col := 色("主", 0.95*a*fa)
	件.弧(self, c, 11.0, 0.0, TAU, col, 2.0, 24)
	for d in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
		件.线(self, c + d*16.0*s, c + d*28.0*s, col, 2.0, false)


# ———————————————————— 标记
func 可见(id: String, E: float, N: float, 抬 := 2.0) -> bool:
	var c: Array = 可见缓.get(id, [-99, true])
	if 帧号 - c[0] < 6: return c[1]
	var zs: float = maxf(M.半/M.半默认, 0.6)                      # 贴近时抬高和容差不再随比例缩到几厘米（地面抖动会把标记当成被挡住）
	if Vector2(E - M.焦.x, N - M.焦.y).length() < M.半*0.6:      # 焦点附近的标记总是可见（低俯角下近处的小起伏不该把它们藏掉）
		可见缓[id] = [帧号 + (hash(id) % 6), true]; return true
	var P1: Vector3 = M.地世(E, N, 抬*zs); var o: Vector3 = M.机位
	var ok := true
	var n := 18
	for i in range(1, n):
		var t := float(i)/n; var q := o.lerp(P1, t)
		if q.y < M.数.高(q.x, -q.z)*M.垂放 - 0.6*zs - (1.0 - t)*0.0:
			ok = false; break
	可见缓[id] = [帧号 + (hash(id) % 6), ok]
	return ok


func 平字(E: float, N: float, 字: String, 号m: float, col: Color, 距m := 0.0) -> Rect2:
	"""贴地平躺的字（跟透视）：在锚点把地面线性化成仿射矩阵。号m = 字高（米）。返回屏幕外框。"""
	var zs: float = M.半/M.半默认
	var 抬 := 4.0*zs
	var p0: Vector3 = M.地屏(E, N, 抬); var pu: Vector3 = M.地屏(E + 1.0, N, 抬); var pv: Vector3 = M.地屏(E, N + 1.0, 抬)
	if p0.z <= 0.0: return Rect2()
	var A := Vector2(pu.x - p0.x, pu.y - p0.y); var B := -Vector2(pv.x - p0.x, pv.y - p0.y)
	var px := 64.0; var k := 号m/px
	字 = 令.译(字)
	var f: Font = 令.字["细"]
	var w := 0.0
	for ch in 字: w += f.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, int(px)).x + 距m/k
	draw_set_transform_matrix(Transform2D(A*k, B*k, Vector2(p0.x, p0.y)))
	var x := -w*0.5
	for ch in 字:
		draw_string(f, Vector2(x, px*0.35), ch, HORIZONTAL_ALIGNMENT_LEFT, -1, int(px), col)
		x += f.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, int(px)).x + 距m/k
	draw_set_transform_matrix(Transform2D.IDENTITY)
	var cs := [Vector2(-w*0.5, -px*0.7), Vector2(w*0.5, -px*0.7), Vector2(w*0.5, px*0.35), Vector2(-w*0.5, px*0.35)]
	var r := Rect2(Vector2(p0.x, p0.y), Vector2.ZERO)
	for q in cs:
		var wp = Vector2(p0.x, p0.y) + A*k*q.x + B*k*q.y
		r = r.expand(wp)
	return r


func 放文字(r: Rect2) -> bool:
	"""标签排重：和已放的外接框相交就不放；超过上限不放。"""
	if 本帧文字 >= 文字上限: return false
	var e := r.grow(3.0*s)
	for q in 数字组: if e.intersects(q): return false
	数字组.append(e); 本帧文字 += 1
	return true


func 求文字框(p: Vector2, t: String, 号: float, fk: String, 左 := true) -> Rect2:
	var w: float = 件.宽度(t, 号, fk); var h: float = 号*s*1.2
	return Rect2(p + Vector2(0 if 左 else -w, -号*s*0.95), Vector2(w, h))


func 虚折线(pts0: PackedVector2Array, col: Color, w: float, 段: float, 空: float) -> void:
	"""屏幕折线画成虚线：所有短划攒进一次 draw_multiline（外扩 + 芯两次），免得一帧几百个绘制项。"""
	var pts := PackedVector2Array()
	for p in pts0:
		if absf(p.x) < 6000.0 and absf(p.y) < 6000.0: pts.append(p)
	if pts.size() < 2: return
	var seg := PackedVector2Array(); var 周 := (段 + 空)*s; var 累 := 0.0
	for i in range(1, pts.size()):
		var a := pts[i - 1]; var b := pts[i]; var L := a.distance_to(b)
		if L < 0.01: continue
		var d := (b - a)/L; var t := 0.0
		while t < L and seg.size() < 400:
			var ph := fposmod(累 + t, 周)
			var 到 := minf(L - t, (段*s - ph) if ph < 段*s else (周 - ph))
			if ph < 段*s: seg.append(a + d*t); seg.append(a + d*(t + 到))
			t += maxf(到, 0.5)
		累 += L
	if seg.is_empty(): return
	var 暗: Color = 令.色["暗"]
	draw_multiline(seg, Color(暗, 0.45*col.a), w*s + 3.0*s, true)
	draw_multiline(seg, col, w*s, true)


func _标记层(dt: float, 钟: float, 动: bool) -> void:
	var w: Vector3 = M.权(); var zs: float = M.半/M.半默认
	var 活: Color = 色("活亮" if 令.有活边 else "活")
	var rc: Vector4 = M.台矩形()
	var 车位 := Vector2(M.车E, M.车N)
	var 进路 := 1.0
	var a标 = M.段内(1.9, 2.3) if 动 else 1.0
	var a圈 = M.段内(0.8, 1.2) if 动 else 1.0
	var a名 = M.段内(1.5, 1.9) if 动 else 1.0
	var a数 = M.段内(1.7, 2.0) if 动 else 1.0
	var 线进 = M.段内(2.7, 3.2) if 动 else 1.0
	var 字进 = M.段内(3.1, 3.3) if 动 else 1.0
	var 屏框 := Rect2(点(150, 190), 点(1800, 1100))
	var 队: Array = []                                           # 文字请求：[优先, 键, 框, 绘制 Callable]
	# ——— 距离圈数字（先收集，文字放完后再画：不和任何标签、也不和彼此叠）
	圈标 = []
	var 圈字 := [["25 m", "50 m", "100 m"], ["250 m", "500 m", "1 km"], ["5 km", "10 km", "20 km"]]
	var cw := [w.x, w.y, w.z]
	for k in 3:
		var ak: float = cw[k]*a圈
		if ak < 0.02: continue
		for i in 3:
			var R: float = M.圈半径[k][i]
			var q: Vector3 = M.地屏(sin(deg_to_rad(325.0))*R, cos(deg_to_rad(325.0))*R, 4.0*zs)
			if q.z <= 0 or not 屏框.has_point(Vector2(q.x, q.y)) or not 可见("圈%d_%d" % [k, i], sin(deg_to_rad(325.0))*R, cos(deg_to_rad(325.0))*R): continue
			圈标.append([Vector2(q.x + 10*s, q.y + 22*s), 圈字[k][i], 0.9*ak])
	# ——— 区域地名（平躺字）
	if M.层开["地名"] and a名 > 0.0:
		var 名表 := [[w.z, "杰泽罗陨石坑", 3500.0, -2300.0, 420.0, 0.5, 60.0], [w.y, "三角洲前缘", -800.0, 60.0, 130.0, 0.5, 30.0], [w.y, "陨石坑底", 2050.0, -1400.0, 150.0, 0.4, 40.0]]
		for it in 名表:
			var ak: float = it[0]*a名
			if ak < 0.02: continue
			var k := (1.0 if it[0] != w.z else 1.0)
			var size_m: float = it[4]*(zs if it[0] != w.z else 1.0)*(1.0 if it[0] != w.z else 1.0)
			if it[0] == w.z: size_m = it[4]*zs/ 6.0
			var 框: Rect2 = Rect2(M.地屏(it[2], it[3]).x - 80, M.地屏(it[2], it[3]).y - 30, 160, 60)
			if not 屏框.has_point(框.get_center()): continue
			显示["地名"].append(it[1])
			队.append([6, "名" + it[1], 框, func(): 平字(it[2], it[3], it[1], size_m, 色("主", it[5]*ak), it[6]*size_m/it[4])])
	# ——— 路线上的 sol 点
	if M.层开["路线"] and (w.y + w.x) > 0.02 and a标 > 0.0:
		var 步 := 10 if w.x > 0.5 else 100
		for rec in _路点(步):
			var al := (w.x + w.y) if rec.sol % 100 == 0 else w.x
			if al < 0.02: continue
			var q: Vector3 = M.地屏(rec.E, rec.N, 6.0*zs)
			if q.z <= 0 or not 屏框.has_point(Vector2(q.x, q.y)) or not 可见("s%d" % rec.sol, rec.E, rec.N, 6.0): continue
			var 键 := "s%d" % rec.sol
			var fa: float = 件.进(进表, 键, true, dt, 0.15, 0.15)*al*a标
			if fa > 0.5: 显示["路点"] += 1
			var ctr := Vector2(q.x, q.y)
			draw_circle(ctr, 6.0*s + 2.0*s, Color(色("暗"), 0.7*fa)); 件.弧(self, ctr, 6.0*s, 0.0, TAU, Color(活, fa), 2.5, 16)
			if rec.sol % 100 == 0 or w.x > 0.5:
				var 左: bool = rec.sol % 300 == 0 and rec.sol > 0
				var tp := ctr + Vector2((-14 if 左 else 14)*s, 26*s)
				var txt := "SOL %d" % rec.sol
				var fr := 求文字框(tp, txt, 19, "等", not 左)
				队.append([5 if rec.sol % 100 == 0 else 7, 键, fr, func(): 件.字串(self, tp, txt, 19, Color(活, 0.95*fa), "等", HORIZONTAL_ALIGNMENT_RIGHT if 左 else HORIZONTAL_ALIGNMENT_LEFT, -1.0, true)])
	# ——— 兴趣点、车、选中
	var 点画: Array = []
	var 已用簇: Dictionary = {}
	var 簇 := _聚类(w, 屏框)
	var 排位 := _排位(簇, zs)
	if M.层开["兴趣点"]:
		for p in M.点表():
			var id: String = p["id"]; var sel: bool = id == M.选中
			var 发 = M.已发现(p)
			var 远: bool = p["类"] == "远"
			var 目标 := 0.0
			if id == "butler_landing" or id == "jezero_rim": 目标 = 1.0
			elif sel: 目标 = 1.0
			elif 发: 目标 = w.x + w.y
			else: 目标 = w.x + w.y
			var d := Vector2(p["E"] - M.车E, p["N"] - M.车N).length()
			if d < 6.0*zs and not sel and 目标 < 1.0 and d < 1.0: 目标 = 0.0
			var in台 := true
			var q: Vector3 = M.地屏(p["E"], p["N"], 2.0*zs)
			var ok := q.z > 0 and in台 and 屏框.grow(60*s).has_point(Vector2(q.x, q.y)) and 可见("p" + id, p["E"], p["N"])
			var 簇内 := 簇.has(id) and not sel
			var fa: float = 件.进(进表, "p" + id, ok and 目标 > 0.0 and not 簇内, dt, 0.15, 0.15)*minf(1.0, 目标)*a标
			if fa <= 0.01: continue
			if fa > 0.5 and not sel and id != "butler_landing" and id != "jezero_rim": 显示["发现" if 发 else "未发现"] += 1
			var g := Vector2(q.x, q.y); var 长: float = (杆长.get(id, 90) + 排位.get(id, 0)*46)*1.0
			var top := g + Vector2(0, -长*s + 6*s*(1.0 - fa))
			var col: Color = Color(活 if sel else 色("主"), fa)
			var 键 := "点:" + id
			var hv: float = 件.进(悬停表, 键, (悬停键 != null and str(悬停键) == 键) or 悬停点 == id, dt, 0.08, 0.08)
			draw_circle(g, (5.0 if sel else 3.5)*s + 1.0*s, Color(色("暗"), 0.6*fa)); draw_circle(g, (5.0 if sel else 3.5)*s, col)
			件.线(self, g, top + Vector2(0, (14 if sel else 10)*s), Color(col, fa*(1.0 if sel else 0.75)), 2.5 if sel else 1.5, false)
			var dr := (14.0 if sel else 10.0 + 2.0*hv)*s
			if 发: 菱形(top, dr, col, sel, 2.5)
			else:
				菱形(top, dr, Color(col, fa*0.7), false, 2.0)
				件.字串(self, top + Vector2(0, 7*s), "?", 16, Color(col, 0.8*fa), "中", HORIZONTAL_ALIGNMENT_CENTER)
			命中表.append([Rect2(top - Vector2(dr + 6*s, dr + 6*s), Vector2(2*dr + 12*s, 长*s + dr + 6*s + 6*s)), 键])
			var 字 := ""
			if 发: 字 = "着陆点" if id == "butler_landing" else 短名(p)
			if sel and not 发: 字 = "?"
			if 字 != "" and (sel or id == "butler_landing" or (发 and (w.x > 0.5 or _最近三(id)))):
				var tp := top + Vector2((24 if sel else 20)*s, (13 if sel else 9)*s)
				var 号 := 34.0 if sel else 26.0
				var fk := "粗" if sel else "中"
				var 优 := 1 if sel else (3 if id == "butler_landing" else 4)
				队.append([优, 键, 求文字框(tp, 字, 号, fk), func(): 件.字串(self, tp, 字, 号, col, fk)])
			elif hv > 0.0 and 悬停点 == id or (悬停键 != null and str(悬停键) == 键 and 悬停时 > 0.15):
				var tp := top + Vector2(20*s, 9*s)
				var tip := "%s  %s" % [短名(p), 令.距字(d)]
				队.append([0, 键 + "提", 求文字框(tp, tip, 22, "中"), func(): 件.字串(self, tp, tip, 22, Color(色("主"), fa), "中")])
	# 车
	_车(队, dt, a标, zs, 活)
	# 引线（车 → 选中）
	_引线(线进, 字进, 活, 队)
	# 坑缘箭头
	_坑缘(队, rc, a标, zs)
	# ——— 文字按优先级排重放下
	队.sort_custom(func(a, b): return a[0] < b[0])
	统计["框"] = []
	for it in 队:
		var r: Rect2 = it[2]
		if it[0] == 0 or 放文字(r):
			(it[3] as Callable).call()
			if it[0] != 0: 统计["框"].append(r)
	for t in 圈标:
		var fr := 求文字框(t[0], t[1], 19, "等中").grow(2.0*s)
		var 撞 := false
		for q in 数字组: if fr.intersects(q): 撞 = true; break
		if 撞: continue
		数字组.append(fr)
		件.字串(self, t[0], t[1], 19, 色("主", t[2]), "等中", HORIZONTAL_ALIGNMENT_LEFT, -1.0, true)
	_簇徽(簇, a标, zs)
	_等高数字(a数*(w.x + w.y), 屏框)                                 # 数字最后放：不和任何标签抢位置


func _簇徽(簇: Dictionary, a标: float, zs: float) -> void:
	"""挤在一起的兴趣点合成带数字的圆。近的两个圆合并；圆的位置避开已放的文字、车和别的圆（挪不开就不画）。"""
	var 列: Array = []
	var 见: Dictionary = {}
	for id in 簇:
		var 组: Array = 簇[id]
		var 键 := "簇:%d,%d" % [roundi(组[0].x), roundi(组[0].y)]
		if 见.has(键): continue
		见[键] = true
		列.append({"键": 键, "屏": Vector2(组[1].x, 组[1].y), "n": int(组[2]), "e": Vector2(组[0].x, 组[0].y)})
	var 并: Array = []
	for c in 列:
		var 合 := false
		for o in 并:
			if (o["屏"] - c["屏"]).length() < 40.0*s:
				o["屏"] = (o["屏"]*o["n"] + c["屏"]*c["n"])/float(o["n"] + c["n"]); o["e"] = (o["e"]*o["n"] + c["e"]*c["n"])/float(o["n"] + c["n"]); o["n"] += c["n"]; 合 = true; break
		if not 合: 并.append(c)
	var 占: Array = 数字组.duplicate()
	var 车q: Vector3 = M.地屏(M.车E, M.车N, 2.0*zs)
	if 车q.z > 0: 占.append(Rect2(Vector2(车q.x - 64*s, 车q.y - 128*s), Vector2(250*s, 190*s)))
	徽框们 = []
	for c in 并:
		var 键: String = "簇:%d,%d" % [roundi(c["e"].x), roundi(c["e"].y)]
		var fa: float = 件.进(进表, 键, true, 上次dt, 0.15, 0.15)*a标
		var 试 := [Vector2(0, 0), Vector2(40, 0), Vector2(-40, 0), Vector2(0, -40), Vector2(40, -40), Vector2(-40, -40), Vector2(0, 40), Vector2(80, 0)]
		var 放 := false; var cen: Vector2 = c["屏"]; var 框 := Rect2()
		for d in 试:
			var 中: Vector2 = c["屏"] + d*s
			框 = Rect2(中 - Vector2(17, 17)*s, Vector2(34, 34)*s)
			var 撞 := false
			for r2 in 占: if 框.grow(2.0*s).intersects(r2): 撞 = true; break
			if not 撞: 放 = true; cen = 中; break
		if not 放: continue
		占.append(框); 徽框们.append(框)
		显示["簇"] += 1; 显示["簇员"] += int(c["n"])
		draw_circle(cen, 15.0*s, Color(色("暗"), 0.75*fa)); 件.弧(self, cen, 13.0*s, 0.0, TAU, Color(色("主"), fa), 2.0, 24)
		件.字串(self, cen + Vector2(0, 7*s), str(c["n"]), 20, Color(色("主"), fa), "等中", HORIZONTAL_ALIGNMENT_CENTER, -1.0, true)
		命中表.append([Rect2(cen - Vector2(22, 22)*s, Vector2(44, 44)*s), "簇:%d,%d" % [roundi(c["e"].x), roundi(c["e"].y)]])
	统计["框"].append_array(徽框们); 数字组.append_array(徽框们)


func _最近三(id: String) -> bool:
	if 最近三缓.is_empty() or 帧号 % 30 == 0:
		var rows := 点列(); 最近三缓 = []
		for r in rows:
			if M.已发现(r[1]) and r[1]["id"] != "butler_landing" and r[1]["id"] != "jezero_rim" and 最近三缓.size() < 3: 最近三缓.append(r[1]["id"])
	return id in 最近三缓
var 最近三缓: Array = []


func _聚类(w: Vector3, 屏框: Rect2) -> Dictionary:
	"""屏幕上靠得太近的兴趣点合成一个带数字的圆。返回 {id: [代表 E/N, 屏位, 个数]}；选中的不进簇。"""
	var 表: Dictionary = {}
	if (w.x + w.y) < 0.05: return 表
	var 项: Array = []
	var zs: float = M.半/M.半默认
	for p in M.点表():
		if p["id"] == M.选中 or p["id"] == "butler_landing" or p["id"] == "jezero_rim": continue
		var q: Vector3 = M.地屏(p["E"], p["N"], 2.0*zs)
		if q.z <= 0 or not 屏框.grow(60*s).has_point(Vector2(q.x, q.y)): continue
		项.append([p["id"], Vector2(q.x, q.y), p])
	var 用: Dictionary = {}
	var 近 := w.x > 0.5                                           # 800 m 以内：先用杆的高低错开（_排位），实在 ≥ 5 个叠在一起才合并
	for i in 项.size():
		if 用.has(项[i][0]): continue
		var 组: Array = [项[i]]
		for j in range(i + 1, 项.size()):
			if not 用.has(项[j][0]) and (项[j][1] - 项[i][1]).length() < 26.0*s: 组.append(项[j])
		if 组.size() >= (5 if 近 else 2):
			var cen := Vector2.ZERO; var e := Vector2.ZERO
			for g in 组: cen += g[1]; e += Vector2(g[2]["E"], g[2]["N"])
			cen /= 组.size(); e /= 组.size()
			for g in 组: 用[g[0]] = true; 表[g[0]] = [e, cen, 组.size()]
	return 表


func _排位(簇: Dictionary, zs: float) -> Dictionary:
	"""站得近的标记（屏幕上 < 40 px）按离车由近到远排 0、1、2、3 档，杆高每档加 46 px，菱形和名字就不叠在一起。车本身占第 0 档。"""
	var 项: Array = []
	var 车q: Vector3 = M.地屏(M.车E, M.车N, 2.0*zs)
	var 出: Dictionary = {}
	var 已放: Array = []
	if 车q.z > 0: 已放.append([Vector2(车q.x, 车q.y), 0])
	var 行 := 点列()
	for r in 行:
		var p: Dictionary = r[1]
		if 簇.has(p["id"]) and p["id"] != M.选中: continue
		var q: Vector3 = M.地屏(p["E"], p["N"], 2.0*zs)
		if q.z <= 0: continue
		var g := Vector2(q.x, q.y); var used := {}
		for o in 已放:
			if absf(o[0].x - g.x) < 40.0*s and absf(o[0].y - g.y) < 40.0*s: used[o[1]] = true
		var k := 0
		while used.has(k) and k < 4: k += 1
		出[p["id"]] = k
		已放.append([g, k])
	return 出


func _路点(步: int) -> Array:
	if 路点表.is_empty():
		var seen := {}
		for i in M.数.路sol.size():
			var sl: int = M.数.路sol[i]
			if sl % 10 == 0 and not seen.has(sl):
				seen[sl] = true; 路点表.append({"sol": sl, "E": M.数.路E[i], "N": M.数.路N[i], "i": i})
	var out: Array = []
	for r in 路点表:
		if r.sol % 步 == 0 and r.sol > 0: out.append(r)
	return out


func _车(队: Array, dt: float, a标: float, zs: float, 活: Color) -> void:
	"""远处：箭头 + 环（符号，大小跟缩放）；800 m 以内渐变成按真实尺寸（3.0 × 2.7 m，不小于 24 px 长）画的脚印 + 车头箭头。"""
	var 地 := Vector2(M.车E, M.车N)
	var mpp: float = M.每像素米()
	var w: Vector3 = M.权()
	var q: Vector3 = M.地屏(地.x, 地.y, 2.0*zs)
	if q.z <= 0: return
	var yaw := deg_to_rad(M.车航)
	var fwd := Vector2(sin(yaw), cos(yaw)); var rt := Vector2(cos(yaw), -sin(yaw))
	var 抬 := maxf(6.0*zs, 0.6)
	var 远a := 1.0 - w.x
	if 远a > 0.01:
		var 尺m := maxf(70.0*zs, 12.0*mpp)
		var k := 尺m/70.0
		var P := func(dE: float, dN: float) -> Vector2:
			var v: Vector3 = M.地屏(地.x + dE*k, 地.y + dN*k, 6.0*zs); return Vector2(v.x, v.y)
		var pts := PackedVector2Array([P.call(fwd.x*45, fwd.y*45), P.call(-fwd.x*25 + rt.x*30, -fwd.y*25 + rt.y*30), P.call(-fwd.x*8, -fwd.y*8), P.call(-fwd.x*25 - rt.x*30, -fwd.y*25 - rt.y*30)])
		if not Geometry2D.triangulate_polygon(pts).is_empty(): draw_colored_polygon(pts, Color(活, 远a))
		var cl := pts.duplicate(); cl.append(pts[0]); 件.折(self, cl, Color(活, 远a), 2.5)
		var ring := PackedVector2Array()
		for d in 73: ring.append(P.call(sin(deg_to_rad(d*5.0))*70.0, cos(deg_to_rad(d*5.0))*70.0))
		件.折(self, ring, Color(活, 0.9*远a), 2.5)
	if w.x > 0.01:
		var ks := maxf(1.0, 36.0*mpp/3.0*s)                 # 真实尺寸的倍数（< 36 px 长时放大到 36 px，低俯角下才看得见；真实尺寸 3.0 × 2.7 m）
		var G := func(f: float, r: float) -> Vector2:       # 车体坐标（前 f m、右 r m）→ 屏幕
			var v: Vector3 = M.地屏(地.x + (fwd.x*f + rt.x*r)*ks, 地.y + (fwd.y*f + rt.y*r)*ks, 抬); return Vector2(v.x, v.y)
		var 体 := PackedVector2Array([G.call(1.5, -1.35), G.call(1.5, 1.35), G.call(-1.5, 1.35), G.call(-1.5, -1.35)])
		var fa := w.x
		if not Geometry2D.triangulate_polygon(体).is_empty(): draw_colored_polygon(体, Color(活, 0.45*fa))
		var 框线 := 体.duplicate(); 框线.append(体[0]); 件.折(self, 框线, Color(色("暗"), 0.7*fa), 5.5); 件.折(self, 框线, Color(活, fa), 2.5)
		for sd in [-1.0, 1.0]:                              # 三对轮子（6 轮摇臂）：每侧 3 条短线
			for f in [1.2, 0.0, -1.2]:
				件.线(self, G.call(f - 0.3, sd*1.5), G.call(f + 0.3, sd*1.5), Color(活, 0.8*fa), 3.0, false)
		var L := maxf(2.0, 40.0*mpp/maxf(ks, 1.0)*s)         # 车头箭头：从车头向前，至少 40 px
		var a0: Vector2 = G.call(1.5, 0.0); var a1: Vector2 = G.call(1.5 + L, 0.0)
		件.线(self, a0, a1, Color(活, fa), 3.0, false)
		var dir: Vector2 = (a1 - a0)
		if dir.length() > 1.0:
			dir = dir.normalized(); var nr := Vector2(-dir.y, dir.x)
			draw_colored_polygon(PackedVector2Array([a1 + dir*14*s, a1 - dir*6*s + nr*10*s, a1 - dir*6*s - nr*10*s]), Color(活, fa))
	var g := Vector2(q.x, q.y); var top := g + Vector2(0, -110*s)
	件.线(self, g + Vector2(0, -18*s), top, Color(活, 1.0), 2.5, false)
	var tp := top + Vector2(22*s, 12*s)
	队.append([1, "车", 求文字框(tp, "毅力号", 32, "粗"), func(): 件.字串(self, tp, "毅力号", 32, Color(活, 1.0), "粗")])
	命中表.append([Rect2(g - Vector2(30, 120)*s, Vector2(60, 140)*s), "车"])


func _引线(线进: float, 字进: float, 活: Color, 队: Array) -> void:
	if M.选中 == "": return
	var p: Dictionary = M.取点(M.选中)
	if p.is_empty(): return
	var 签 := "%s|%d|%d" % [M.选中, roundi(M.车E), roundi(M.车N)]
	if 签 != 引线签:
		引线签 = 签; 引线点.resize(0)
		for i in 121:
			var t := i/120.0; var E: float = lerpf(M.车E, p["E"], t); var N: float = lerpf(M.车N, p["N"], t)
			引线点.append(Vector3(E, N, 0))
	var zs: float = M.半/M.半默认
	var 出: float = minf(线进, M.选中新*3.0 if not M.样张 else 1.0) if M.态 == "开" else 线进
	var n := maxi(2, int(120.0*clampf(出, 0.0, 1.0)))
	var 屏点 := PackedVector2Array(); var 全 := PackedVector2Array()
	for i in 引线点.size():
		var q: Vector3 = M.地屏(引线点[i].x, 引线点[i].y, 5.0*zs)
		全.append(Vector2(q.x, q.y))
	if 全.size() < 2: return
	屏点 = 全.slice(0, n + 1)
	虚折线(屏点, Color(活, 0.95), 2.5, 12.0, 8.0)
	var m := 全[60]; var d := Vector2(p["E"] - M.车E, p["N"] - M.车N).length()
	var dU: float = M.数.高(p["E"], p["N"]) - 车U()
	var fa := 字进 if M.态 != "开" else 1.0
	var tp := m + Vector2(14*s, -10*s)
	var dd: float = 件.数到(d, M.选中新)
	var txt: String = 令.距字(dd)
	队.append([1, "引线字", 求文字框(tp, txt + "  ▼48 m", 22, "等中"), func():
		件.字串(self, tp, txt, 22, Color(活, fa), "等中")
		高差标(tp.x/s + 件.宽度(txt, 22, "等中")/s + 18, tp.y/s, 件.数到(dU, M.选中新), 22, Color(活, fa))])


func _坑缘(队: Array, rc: Vector4, a: float, zs: float) -> void:
	return                                                              # 没有台边了：坑缘就是地平线上的一个普通兴趣点
	var rim: Dictionary = M.取点("jezero_rim")
	if rim.is_empty(): return
	var d := Vector2(rim["E"] - M.车E, rim["N"] - M.车N)
	var L := d.length()
	if L < 1.0: return
	d /= L
	var 车 := Vector2(M.车E, M.车N)
	var tt := 1e9
	if d.x < 0: tt = minf(tt, (rc.x - 车.x)/d.x)
	if d.x > 0: tt = minf(tt, (rc.y - 车.x)/d.x)
	if d.y < 0: tt = minf(tt, (rc.z - 车.y)/d.y)
	if d.y > 0: tt = minf(tt, (rc.w - 车.y)/d.y)
	if tt > 1e8 or tt > L: return                                        # 坑缘就在台里：直接当兴趣点画（由兴趣点层负责）；这里只画台外的
	var e := 车 + d*tt*0.97
	var S: Vector3 = M.地屏(e.x, e.y, 4.0*zs); var T: Vector3 = M.地屏(e.x + d.x*60*zs, e.y + d.y*60*zs, 4.0*zs)
	var A := Vector2(S.x, S.y); var B := Vector2(T.x, T.y)
	var col := 色("主", 0.85*a)
	件.线(self, A, B, col, 2.5, false)
	var dir := (B - A).normalized(); var nr := Vector2(-dir.y, dir.x)
	件.折(self, PackedVector2Array([B - dir*14*s + nr*8*s, B, B - dir*14*s - nr*8*s]), col, 2.5)
	var 左 := B.x < 420*s
	var tp := B + Vector2((24 if 左 else -18)*s, (78 if 左 else -34)*s)
	var txt := "坑缘 %d km" % roundi(L/1000.0)
	队.append([3, "坑缘", 求文字框(tp, txt, 22, "细", 左), func(): 件.字串(self, tp, txt, 22, col, "细", HORIZONTAL_ALIGNMENT_LEFT if 左 else HORIZONTAL_ALIGNMENT_RIGHT)])


# ———————————————————— 等高线数字（粗线上标「比车高 / 低多少米」）
func _等高数字(a: float, 屏框: Rect2) -> void:
	var w: Vector3 = M.权()
	var 粗 := 5.0 if w.x > 0.5 else (25.0 if w.y > 0.5 else 250.0)
	var rc: Vector4 = M.台矩形()
	var 签 := "%d|%d|%d" % [roundi(log(M.半)*6.0), roundi(M.焦.x/(M.半*0.3)), roundi(M.焦.y/(M.半*0.3))]
	if 签 != 等高签 and Time.get_ticks_msec()/1000.0 - 等高算时 > 0.3 and M.态 == "开":
		等高签 = 签; 等高算时 = Time.get_ticks_msec()/1000.0; _算等高(粗, rc)
	if a <= 0.01: return
	var 上限 := 8 if w.x > 0.5 else 6
	var n := 0
	for c in 等高数:
		if n >= 上限: break
		if absf(c["步"] - 粗) > 0.01: continue
		var q: Vector3 = M.地屏(c["E"], c["N"], 0.5)
		var p := Vector2(q.x, q.y)
		if q.z <= 0 or not 屏框.has_point(p): continue
		if not 可见("c%d" % c["i"], c["E"], c["N"], 0.5): continue
		var 字: String = c["字"]
		var fr := 求文字框(p + Vector2(0, 6*s), 字, 17, "等中", false)
		fr.position.x -= fr.size.x*0.5
		var ok := true
		for r2 in 数字组: if fr.grow(6*s).intersects(r2): ok = false; break
		if not ok: continue
		var fa: float = 件.进(进表, "c%d" % c["i"], true, 上次dt, 0.15, 0.15)*a
		件.字串(self, p + Vector2(0, 6*s), 字, 17, 色("次", 0.9*fa), "等中", HORIZONTAL_ALIGNMENT_CENTER, -1.0, true)
		数字组.append(fr); n += 1; 显示["等高数"] += 1


func _算等高(粗: float, rc: Vector4) -> void:
	等高数 = []
	var nx := 36; var ny := 24
	var H := PackedFloat32Array(); H.resize((nx + 1)*(ny + 1))
	for j in ny + 1:
		for i in nx + 1: H[j*(nx + 1) + i] = M.数.高(lerpf(rc.x, rc.y, float(i)/nx), lerpf(rc.z, rc.w, float(j)/ny))
	var cand: Array = []
	for st in [5.0, 25.0, 250.0]:
		for j in ny + 1:
			for i in nx:
				var a := H[j*(nx + 1) + i]; var b := H[j*(nx + 1) + i + 1]
				var la := floorf(a/st); var lb := floorf(b/st)
				if la != lb:
					var lv = maxf(la, lb)*st; var t = (lv - a)/(b - a)
					cand.append({"E": lerpf(rc.x, rc.y, (i + t)/nx), "N": lerpf(rc.z, rc.w, float(j)/ny), "步": st, "lv": lv})
		for j in ny:
			for i in nx + 1:
				var a := H[j*(nx + 1) + i]; var b := H[(j + 1)*(nx + 1) + i]
				var la := floorf(a/st); var lb := floorf(b/st)
				if la != lb:
					var lv = maxf(la, lb)*st; var t = (lv - a)/(b - a)
					cand.append({"E": lerpf(rc.x, rc.y, float(i)/nx), "N": lerpf(rc.z, rc.w, (j + t)/ny), "步": st, "lv": lv})
	# 只留粗线（整数倍 粗×5 的才标；细一级的另算）：每套取 lv 是它「粗」的整倍数
	var out: Array = []; var idx := 0
	for c in cand:
		var 粗k: float = c["步"]
		if fmod(absf(c["lv"]), 粗k) > 0.001: continue
		var lv: float = c["lv"]
		c["字"] = "0" if is_zero_approx(lv) else ("%+d" % roundi(lv)).replace("-", "−")
		c["i"] = idx; idx += 1
		out.append(c)
	# 稀疏化：同一级别里挑彼此隔得远的（最远点采样，起点是离焦点最近的）
	var 选: Array = []
	for st in [5.0, 25.0, 250.0]:
		var pool: Array = out.filter(func(c): return c["步"] == st)
		var 己: Array = []
		while pool.size() > 0 and 己.size() < 14:
			var best := -1; var bd := -1.0
			for i in pool.size():
				var dmin := 1e12
				if 己.is_empty(): dmin = Vector2(pool[i]["E"] - M.焦.x, pool[i]["N"] - M.焦.y).length()
				else:
					for g in 己: dmin = minf(dmin, Vector2(pool[i]["E"] - g["E"], pool[i]["N"] - g["N"]).length())
				if dmin > bd: bd = dmin; best = i
			if bd < M.半*0.45 and not 己.is_empty(): break
			己.append(pool[best]); pool.remove_at(best)
		选.append_array(己)
	等高数 = 选


# ———————————————————— 图层页、帮助页
func _图层页() -> void:
	var x := 150.0; var y := 790.0
	var 项 := [["路线", "SOL 0–530"], ["兴趣点", ""], ["坡度", "> 20°"], ["地名", ""], ["已探索", ""]]
	var 名 := {"路线": "路线", "兴趣点": "兴趣点", "坡度": "坡度", "地名": "地名", "已探索": "已探索"}
	draw_rect(Rect2(点(x - 20, y - 50), 点(340, 60 + 项.size()*50)), Color(色("页底"), 0.9))
	for i in 项.size():
		var yy := y + i*50.0; var k: String = 项[i][0]; var on: bool = M.层开[k]
		draw_rect(Rect2(点(x, yy - 22), 点(24, 24)), 色("主", 0.9), false, 2.0*s)
		if on: draw_rect(Rect2(点(x + 5, yy - 17), 点(14, 14)), 色("活亮" if 令.有活边 else "活"))
		件.字串(self, 点(x + 40, yy), 名[k], 24, 色("主"), "细")
		命中表.append([Rect2(点(x - 6, yy - 30), 点(320, 44)), "层:" + k])


func _帮助页() -> void:
	var 表 := [["拖动", "平移"], ["滚轮", "缩放"], ["右键拖动", "转台"], ["双击", "放大"], ["1 2 3", "200 m · 2 km · 25 km"], ["方向键 + −", "平移 缩放"], ["N", "指北"], ["V", "垂直放大"], ["Enter", "设为航点"], ["F", "镜头飞到"], ["Tab", "图层"], ["Esc", "返回"]]
	var x := 760.0; var y := 360.0
	draw_rect(Rect2(点(x - 40, y - 70), 点(960, 90 + 表.size()*52)), Color(色("页底"), 0.92))
	for i in 表.size():
		var yy := y + i*52.0
		件.键帽(self, 点(x, yy), 表[i][0], 色("主"), 20)
		件.字串(self, 点(x + 260, yy), 表[i][1], 24, 色("主"), "细")
