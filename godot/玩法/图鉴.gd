# 图鉴 / 相册页（Tab 开关；世界暂停、放开鼠标）：docs/玩法A.md。
#   「图鉴」：已发现的兴趣点（配真实照片）和自己拍的照片排在一条时间线上，按 sol / 时刻排序：
#     兴趣点按那张真实照片的 sol 和当地时间，玩家照片是 sol 530 和拍摄时的 LTST；没发现的兴趣点排在最后，画成问号。
#   「挑战」：复刻 NASA 照片（复刻.gd 有的话）。
#   键：←→↑↓ 选、Enter / 单击 全屏看大图（全屏里 ←→ 翻、Esc / 单击 关），Q / E 换页签，滚轮滚动，Tab / Esc 关。
extends Node

var 玩: Node
var P: Node
var 风: RefCounted
var 开着 := false
var 层: CanvasLayer
var 页: Control
var 页签 := 0                                     # 0 图鉴、1 挑战
var 条目: Array = []                              # [{类: 点/照/未, 题, 副, 图, 说明, 出处, 键}]
var 选 := 0
var 滚 := 0.0
var 大图 := -1                                    # 全屏看的条目号；-1 = 不在全屏
var 框: Array = []                                # 画的时候记下每个条目的矩形（点选用）
var 图缓存 := {}
var 列 := 5
var 开a := 0.0                                     # 打开动画（0.25 s 淡入 + 上移）
var 悬 := -99                                      # 鼠标指着的框号（≥ 0 条目；-10 / -11 页签；≤ -20 页底键）
var 按 := -99                                      # 按下还没抬起的框号
var 提示键 := ""
var 鼠标位 := Vector2.ZERO
const 件 := preload("res://界面/件.gd")


func _ready() -> void:
	玩 = get_parent(); P = 玩.P; 风 = 玩.风
	层 = CanvasLayer.new(); 层.layer = 40; 层.visible = false; add_child(层)
	页 = Control.new(); 页.set_anchors_preset(Control.PRESET_FULL_RECT); 页.mouse_filter = Control.MOUSE_FILTER_STOP
	页.draw.connect(_画); 页.gui_input.connect(_鼠标); 层.add_child(页)


func 打开(签 := 0) -> void:
	if 开着: return
	开着 = true; 页签 = 签; 大图 = -1; 选 = 0; 滚 = 0.0; 开a = 0.0; 悬 = -99; 按 = -99
	玩.暂停("图鉴", true); 玩.放鼠标()
	整理(); 层.visible = true; 页.queue_redraw()


func 关() -> void:
	if not 开着: return
	开着 = false; 层.visible = false
	玩.暂停("图鉴", false); 玩.还鼠标()


func 图(path: String) -> Texture2D:
	if not 图缓存.has(path): 图缓存[path] = 风.图(path)
	return 图缓存[path]


# ———————————————————— 条目
func 整理() -> void:
	条目.clear()
	if 页签 == 1:
		if 玩.复刻 and 玩.复刻.has_method("条目"): 条目 = 玩.复刻.条目()
		return
	var 有: Array = []
	for q in 玩.数据["兴趣点"]:
		var 照: Array = q.get("照片", [])
		var f: Dictionary = 照[0] if not 照.is_empty() else {}
		if not 玩.进度["已发现"].has(q["id"]):
			有.append({"类": "未", "题": "未发现", "副": "", "提示": ("远处：拍照发现" if q["类"] == "远" else "开到附近发现"), "键": [99999, 0.0]}); continue
		var d: Dictionary = 玩.进度["已发现"][q["id"]]
		有.append({"类": "点", "题": q["名"], "副": "sol %d · %s" % [int(f.get("sol", 0)), f.get("lmst", "")], "提示": String(q["说明"]),
			"图": 玩.图路径(f["文件"]) if f.has("文件") else "", "说明": q["说明"],
			"出处": "%s · %s · %s" % [f.get("相机", ""), f.get("产品", ""), f.get("署名", "")],
			"注": "游戏里发现于 sol 530 LTST %s" % d.get("ltst", "?"),
			"键": [int(f.get("sol", 0)), 分(String(f.get("lmst", "00:00")))]})
	var 相册: String = 玩.拍照.相册 if 玩.拍照 else "user://相册/"
	var dir := DirAccess.open(相册)
	if dir:
		for fn in dir.get_files():
			if not fn.ends_with(".json"): continue
			var m = JSON.parse_string(FileAccess.get_file_as_string(相册 + fn))
			if not (m is Dictionary) or not m.has("缩略图"): continue
			var c: Dictionary = m.get("相机", {})
			有.append({"类": "照", "题": String(m["挑战名"]) if m.has("挑战名") else "sol %d" % int(m.get("sol", 530)), "副": "%s · τ %.2f" % [m.get("ltst", ""), float(m.get("τ", 0.67))],
				"图": String(m["缩略图"]), "大": String(m["文件"]),
				"说明": "%s 取景，焦距 %s mm，横滚 %+.0f°，EV %+.1f。位置 E %+.1f N %+.1f m（%.6f°N %.6f°E，高程 %.1f m）。%s" % [
					c.get("取景", "自由"), str(c.get("焦距_mm", "")), float(c.get("横滚_deg", 0.0)), float(c.get("EV", 0.0)), float(m.get("E", 0.0)), float(m.get("N", 0.0)),
					float(m.get("纬度", 0.0)), float(m.get("经度", 0.0)), float(m.get("高程", 0.0)), ("得分 %d" % int(m["得分"])) if m.has("得分") else ""],
				"出处": "本游戏渲染 · 数据 NASA/JPL-Caltech/ASU/MSSS/UArizona/USGS · %s" % String(m["文件"]).get_file(),
				"键": [int(m.get("sol", 530)), 分(String(m.get("ltst", "00:00"))) + float(String(m.get("名", "0")).hash() % 100)/1000.0]})
	有.sort_custom(func(a, b): return a["键"][0] < b["键"][0] or (a["键"][0] == b["键"][0] and a["键"][1] < b["键"][1]))
	条目 = 有


func 分(t: String) -> float:
	var p := t.split(":")
	return float(p[0])*60.0 + (float(p[1]) if p.size() > 1 else 0.0)


# ———————————————————— 键鼠（界面 6：悬停高亮、按下 / 抬起才触发、滚轮平滑滚动、悬停提示；键盘照旧）
func _process(dt: float) -> void:
	if not 开着: return
	开a = minf(1.0, 开a + dt/maxf(令.时["中"]*令.动倍, 1e-3)) if 令.动倍 > 0.0 else 1.0
	件.提示更(提示键, dt)
	页.queue_redraw()                                                    # 悬停、滚动、淡入都是动画：开着就每帧画（世界暂停，页面便宜）


func 输入(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed and ev.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		if 大图 < 0: 滚 = maxf(0.0, 滚 + (-1.0 if ev.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0)*120.0*风.s)
		return
	if not (ev is InputEventKey and ev.pressed): return
	if 大图 >= 0:
		match ev.keycode:
			KEY_LEFT: 大图 = posmod(大图 - 1, 条目.size())
			KEY_RIGHT: 大图 = posmod(大图 + 1, 条目.size())
			KEY_ESCAPE, KEY_ENTER, KEY_KP_ENTER, KEY_SPACE: 大图 = -1
			KEY_TAB: 大图 = -1; 关(); return
		页.queue_redraw(); return
	match ev.keycode:
		KEY_TAB, KEY_ESCAPE: 关(); return
		KEY_LEFT: 选 = maxi(0, 选 - 1)
		KEY_RIGHT: 选 = mini(条目.size() - 1, 选 + 1)
		KEY_UP: 选 = maxi(0, 选 - 列)
		KEY_DOWN: 选 = mini(条目.size() - 1, 选 + 列)
		KEY_Q, KEY_E: 换页(1 - 页签)
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE: 确认()
		_: return
	页.queue_redraw()


func 换页(k: int) -> void:
	页签 = k; 选 = 0; 滚 = 0.0; 整理()


func 确认() -> void:
	if 选 < 0 or 选 >= 条目.size(): return
	var e: Dictionary = 条目[选]
	if 页签 == 1:
		if 玩.复刻 and 玩.复刻.has_method("选择"): 玩.复刻.选择(e); 关()
		return
	if e["类"] != "未": 大图 = 选


func _鼠标(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed and ev.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		输入(ev); return                                                  # 页面挡住了鼠标，滚轮在这里收
	if ev is InputEventMouseMotion:
		鼠标位 = ev.position; var id := 点中(ev.position); 悬 = id
		if id >= 0 and 选 != id: 选 = id                                    # 鼠标一动，焦点跟鼠标；一按方向键回键盘位置
		提示键 = "" if id == -99 else str(id)
	elif ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		if ev.pressed:
			if 大图 >= 0: 按 = -50; return                                 # 全屏看大图时，任意处按下 → 抬起关闭
			按 = 点中(ev.position)
		else:
			var 抬 := 点中(ev.position) if 大图 < 0 else -50
			var 起 := 按; 按 = -99
			if 起 == -99 or 抬 != 起: return                                # 移出再抬起：取消
			if 起 == -50: 大图 = -1
			elif 起 == -10:                                                  # 内层 if 不能和 elif 写在同一行：后面的 elif 会被归到内层 if 下，点卡片、点页签、点关闭全都不执行
				if 页签 != 0: 换页(0)
			elif 起 == -11:
				if 页签 != 1: 换页(1)
			elif 起 <= -20: 底键(-20 - 起)
			elif 起 >= 0: 选 = 起; 确认()


func 点中(p: Vector2) -> int:
	var rs: Array = []; var ids: Array = []
	for q in 框: rs.append(q[1]); ids.append(q[0])
	var i := 件.命中(rs, p)
	return int(ids[i]) if i >= 0 else -99


func 底键(k: int) -> void:
	match k:
		1: 确认()
		2: 换页(1 - 页签)
		3: 关()


# ———————————————————— 画
func _画() -> void:
	var c := 页; var s: float = 风.s; var vs := c.size; var 主: Color = 令.色["主"]
	c.draw_rect(Rect2(Vector2.ZERO, vs), 风.页底)                       # 整屏页底（令牌）
	框.clear()
	var a := 令.缓(开a)
	if 大图 >= 0 and 大图 < 条目.size(): 画大图(c, 条目[大图], vs, s); return
	var x0 := 80.0*s; var y0 := 70.0*s + (1.0 - a)*14.0*s
	var 签s := ["图鉴", "挑战"]; var 签图 := ["图鉴", "拍照"]
	var tx := x0; var 签x: Array = []; var 签w: Array = []
	for k in 2:
		var on := 页签 == k; var hv := 件.悬度("鉴签%d" % k, 悬 == -10 - k)
		var tw: float = 风.字["粗"].get_string_size(令.译(签s[k]), HORIZONTAL_ALIGNMENT_LEFT, -1, int(30*s)).x
		var col := Color(主, (1.0 if on else 0.85)*a); if not on: col = Color(令.色["次"].lerp(主, hv), a)
		件.图标(c, 签图[k], Vector2(tx + 16*s, y0 - 11*s), 32.0, col)
		风.字串(c, Vector2(tx + 42*s, y0), 签s[k], 30, col, "粗")
		签x.append(tx); 签w.append(tw + 42*s)
		框.append([-10 - k, Rect2(tx - 10*s, y0 - 36*s, tw + 42*s + 20*s, 56*s)])
		tx += tw + 42*s + 48*s
	var ux := 件.趋("鉴签x", 签x[页签], 令.时["滑"]); var uw := 件.趋("鉴签w", 签w[页签], 令.时["滑"])
	c.draw_line(Vector2(ux, y0 + 12*s), Vector2(ux + uw, y0 + 12*s), Color(令.色["活亮"], a), 3.0*s)       # 下划线从旧页签滑到新页签
	var n发 := 0
	for q in 玩.数据["兴趣点"]: if 玩.进度["已发现"].has(q["id"]): n发 += 1
	var 右x := vs.x - x0
	if 页签 == 0:
		var n照 := 条目.filter(func(e): return e["类"] == "照").size()
		var t2 := "%d" % n照; 风.字串(c, Vector2(右x, y0), t2, 24, Color(主, a), "等中", HORIZONTAL_ALIGNMENT_RIGHT, 200*s)
		件.图标(c, "相册", Vector2(右x - 件.宽度(t2, 24, "等中") - 22*s, y0 - 9*s), 30.0, Color(主, a))
		var t1 := "%d / %d" % [n发, 玩.数据["兴趣点"].size()]; var x1 := 右x - 件.宽度(t2, 24, "等中") - 80*s
		风.字串(c, Vector2(x1, y0), t1, 24, Color(主, a), "等中", HORIZONTAL_ALIGNMENT_RIGHT, 300*s)
		件.图标(c, "兴趣点_已发现", Vector2(x1 - 件.宽度(t1, 24, "等中") - 22*s, y0 - 9*s), 30.0, Color(主, a))
	else:
		var 完 := 0
		for cc in 玩.数据["挑战"]:
			if int(玩.进度["挑战"].get(cc["id"], {}).get("最高分", -1)) >= 60: 完 += 1
		var t3 := "%d / %d" % [完, 玩.数据["挑战"].size()]
		风.字串(c, Vector2(右x, y0), t3, 24, Color(主, a), "等中", HORIZONTAL_ALIGNMENT_RIGHT, 300*s)
		件.图标(c, "拍照", Vector2(右x - 件.宽度(t3, 24, "等中") - 22*s, y0 - 9*s), 30.0, Color(主, a))
	if 条目.is_empty():
		件.图标(c, "图鉴" if 页签 == 0 else "拍照", vs*0.5, 64.0, Color(令.色["次"], a)); 画底(c, vs, s, a); return
	var gx := x0; var gy := y0 + 50*s; var gw := vs.x - 2*x0; var gap := 28.0*s
	列 = 5 if 页签 == 0 else 2
	var cw := (gw - gap*(列 - 1))/列; var ih := cw*0.75; var ch := ih + 96.0*s
	var 行 := 选/列; var 可见高 := vs.y - gy - 110*s
	var 总: float = ceilf(float(条目.size())/列)*(ch + gap) - gap
	滚 = clampf(滚, 0.0, maxf(0.0, 总 - 可见高))
	var 目标 := 行*(ch + gap)                                               # 键盘选中的那行滚进视野
	if 目标 - 滚 > 可见高 - ch: 滚 = 目标 - 可见高 + ch
	if 目标 < 滚: 滚 = 目标
	var 显滚 := 件.趋("鉴滚", 滚, 0.09)                                        # 滚轮平滑滚动（时间常数 0.09 s）
	var 悬文 := ""
	for i in 条目.size():
		var e: Dictionary = 条目[i]
		var r := Rect2(gx + (i % 列)*(cw + gap), gy + (i/列)*(ch + gap) - 显滚, cw, ch)
		var 下界 := vs.y - 120*s                                             # 格子区的下沿：再往下是底部键帽，卡片和它的字不许进去
		if r.position.y < gy - 36*s or r.end.y > 下界 + 0.4*ch: continue
		var ta: float = a*clampf(1.0 - (gy - r.position.y)/(36*s), 0.0, 1.0)*clampf(1.0 - (r.end.y - 下界)/(0.4*ch), 0.0, 1.0)   # 滚出格子区的那一行淡出
		框.append([i, r])
		var on := i == 选; var hv := 件.悬度("鉴卡%d" % i, i == 悬)
		if hv > 0.01: c.draw_rect(r.grow(8*s), Color(主, 0.10*hv*ta))
		if on: c.draw_rect(r.grow(8*s), Color(主, ta), false, 2.0*s)
		var ir := Rect2(r.position, Vector2(cw, ih))
		if e["类"] == "未":
			c.draw_rect(ir, Color(1, 1, 1, 0.04*ta/maxf(a, 0.001))); 件.图标(c, "兴趣点_未发现", ir.get_center(), 72.0, Color(令.色["次"], 0.85*ta))
		else:
			var t: Texture2D = 图(e["图"]) if e.get("图", "") != "" else null
			if t:
				var k: float = minf(cw/t.get_width(), ih/t.get_height()); var sz := Vector2(t.get_width(), t.get_height())*k
				c.draw_rect(ir, Color(风.暗色, 0.5*ta/maxf(a, 0.001))); c.draw_texture_rect(t, Rect2(ir.position + (ir.size - sz)*0.5, sz), false, Color(1, 1, 1, ta))
			if e["类"] == "照": 件.图标(c, "拍照", ir.position + Vector2(24, 24)*s, 32.0, Color(风.琥珀, ta))
			if e.get("进行", false): 件.图标(c, "执行", ir.end - Vector2(24, 24)*s, 32.0, Color(风.琥珀, ta))
		风.字串(c, Vector2(r.position.x, ir.end.y + 34*s), e["题"], 22, Color(主 if on else 令.色["次"].lerp(主, hv), ta), "粗")
		if e["副"] != "": 风.字串(c, Vector2(r.position.x, ir.end.y + 64*s), e["副"], 18, Color(令.色["次"], ta), "正")
		if i == 悬: 悬文 = String(e.get("提示", ""))
	c.draw_rect(Rect2(0.0, vs.y - 112*s, vs.x, 112*s), 风.页底)                # 底部键帽后面垫页底色：淡出中的卡片也压不到键帽
	画底(c, vs, s, a)
	var 提 := ""
	if 悬 >= 0: 提 = 悬文
	elif 悬 == -11: 提 = "复刻 NASA 照片：选一张，开到附近，按 C 取景，Enter 交卷"
	elif 悬 == -10: 提 = "兴趣点和我拍的照片，按时间排"
	elif 悬 <= -20: 提 = String(["选", "全屏看" if 页签 == 0 else "开始挑战", "换页", "关闭"][mini(-20 - 悬, 3)])
	件.提示画(c, 提, 鼠标位, vs)


func 画底(c: Control, vs: Vector2, s: float, a: float) -> void:
	c.draw_rect(Rect2(0, vs.y - 100*s, vs.x, 100*s), 风.页底)              # 盖住滚到页底的卡片
	var 键行 := 件.键图行(c, Vector2(vs.x*0.5, vs.y - 34*s), [["←→↑↓", "", "选"], ["Enter", "图鉴" if 页签 == 0 else "拍照", "全屏看" if 页签 == 0 else "开始挑战"], ["Q E", "", "换页"], ["Esc", "关闭", "关闭"]], 底悬(), (-20 - 按) if 按 <= -20 else -1, a)
	for i in 键行.size(): 框.append([-20 - i, 键行[i]])


func 底悬() -> int:
	return -1 if 悬 > -20 else -20 - 悬


func 画大图(c: Control, e: Dictionary, vs: Vector2, s: float) -> void:
	var t: Texture2D = 图(e.get("大", e.get("图", "")))
	var 下 := 230.0*s
	if t:
		var k: float = minf((vs.x - 120*s)/t.get_width(), (vs.y - 下 - 60*s)/t.get_height()); var sz := Vector2(t.get_width(), t.get_height())*k
		c.draw_texture_rect(t, Rect2(Vector2((vs.x - sz.x)*0.5, 40*s), sz), false)
	var y := vs.y - 下 + 30*s; var x := 120.0*s; var w := vs.x - 240*s
	风.字串(c, Vector2(x, y), e["题"], 30, 风.白, "粗")
	风.字串(c, Vector2(x + w, y), "%d / %d" % [大图 + 1, 条目.size()], 22, 风.白, "等中", HORIZONTAL_ALIGNMENT_RIGHT, w*0.5)
	件.键图行(c, Vector2(x + w - 170*s, y + 40*s), [["←→", "", ""], ["Esc", "关闭", ""]], -1, -1, 1.0, true)
	y += 36*s
	风.字串(c, Vector2(x, y), e["副"] + ("　" + e["注"] if e.has("注") else ""), 20, 风.灰, "正")
	y = 风.段落(c, Vector2(x, y + 14*s), e.get("说明", ""), 20, 风.白, w - 260*s)
	风.段落(c, Vector2(x, y + 4*s), e.get("出处", ""), 16, 风.淡, w - 260*s)
