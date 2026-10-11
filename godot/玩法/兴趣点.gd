# 兴趣点：发现判定 + 导览卡（数据 数据/sol0530/兴趣点.json，75_兴趣点.py 生成；docs/玩法A.md）。
#   近点：车（没有车就是相机）离它水平 ≤ 发现半径就发现；远点（坑缘、着陆点）：拍照时它在画面中央一半视场里就发现。
#   发现后弹导览卡：标题、两三句说明、真实照片、出处；F 收起 / 展开，30 s 后自动收起。
#     界面 v3「丙」：没有底板，锚在兴趣点小标旁边（界面.锚屏），字靠描边，照片一道细框；小标不在画面里时放在左侧。收起时只在底部提示「F 导览卡」。
#     界面 v2（--界面=旧）：左侧中部的暗底卡片（宽 480 px@1440p），收起成一行。
#   给界面：标记()（航向带、小地图；没发现的画问号）。
extends Node

const 卡宽 := 480.0
const 自动收 := 30.0

var 玩: Node
var P: Node
var 风: RefCounted
var 点表: Array = []
var 层: CanvasLayer
var 卡: Control
var 当前 := ""                                     # 卡上显示的兴趣点 id
var 展开 := false
var 展开时 := 0.0
var 图缓存 := {}
var 累 := 0.0
var 版本 := 0                                      # 发现一个就 +1（界面用来判断要不要重画）
var 未读 := false                                  # 丙：执行中发现、卡没弹出来
var 前驾中 := false


func _ready() -> void:
	玩 = get_parent(); P = 玩.P; 风 = 玩.风
	点表 = 玩.数据["兴趣点"]
	层 = CanvasLayer.new(); 层.layer = 12; add_child(层)
	卡 = Control.new(); 卡.mouse_filter = Control.MOUSE_FILTER_IGNORE; 卡.draw.connect(_画卡); 层.add_child(卡)
	if 玩.拍照: 玩.拍照.拍了.connect(_拍了)


func 图(rel: String) -> Texture2D:
	if not 图缓存.has(rel): 图缓存[rel] = 风.图(玩.图路径(rel))
	return 图缓存[rel]


# ———————————————————— 发现
func _process(dt: float) -> void:
	if get_tree().paused: return
	if 展开 and 当前 != "" and 风.丙(P): 卡.queue_redraw()                  # 锚在世界里：每帧跟着小标走
	var 驾中: bool = 玩.B != null and 玩.B.get("驾") != null
	if 驾中 and not 前驾中 and 展开 and 风.丙(P): 展开 = false; 卡.queue_redraw()   # 丙：开始自动驾驶时先把卡收起来（F 再打开）
	前驾中 = 驾中
	if 展开 and 展开时 > 0.0:
		展开时 -= dt
		if 展开时 <= 0.0: 展开 = false; 卡.queue_redraw()
	累 += dt
	if 累 < 0.25: return
	累 = 0.0
	var p: Vector3 = 玩.车位(); var E := p.x; var N := -p.z
	for q in 点表:
		if q["类"] != "近" or 玩.进度["已发现"].has(q["id"]): continue
		if Vector2(float(q["E"]) - E, float(q["N"]) - N).length() <= float(q["发现半径"]): 发现(q["id"])


func _拍了(meta: Dictionary) -> void:
	"""远点：照片视线（水平）和兴趣点方位差 ≤ 视场的 1/4（画面中央一半），仰角差 ≤ 视场的 1/4 + 5°。"""
	var c: Dictionary = meta["相机"]; var f := Vector3(c["fwd"][0], c["fwd"][1], c["fwd"][2])
	var o := Vector3(c["pos"][0], c["pos"][1], c["pos"][2]); var hf: float = float(c["hfov"])
	for q in 点表:
		if q["类"] != "远" or 玩.进度["已发现"].has(q["id"]): continue
		var d := Vector3(float(q["E"]) - o.x, float(q["N"]) - o.y, float(q["U"]) - o.z)
		var 方差 := absf(wrapf(rad_to_deg(atan2(d.x, d.y) - atan2(f.x, f.y)), -180.0, 180.0))
		var 仰差 := absf(rad_to_deg(asin(clampf(f.z, -1, 1)) - atan2(d.z, Vector2(d.x, d.y).length())))
		if 方差 <= hf*0.25 and 仰差 <= hf*0.25 + 5.0: 发现(q["id"])


func 发现(id: String) -> void:
	if 玩.进度["已发现"].has(id): return
	var q: Dictionary = 玩.点(id)
	if q.is_empty(): return
	var m: float = P.time_m if P.time_m >= 0.0 else P.minutes(P.ltst)
	玩.进度["已发现"][id] = {"sol": 530, "ltst": "%02d:%02d" % [int(m)/60, int(m)%60], "时间": Time.get_datetime_string_from_system()}
	玩.存进度(); 版本 += 1
	print("[玩法] 发现兴趣点：%s（%d / %d）" % [q["名"], 玩.进度["已发现"].size(), 点表.size()])
	显示(id)


func 显示(id: String) -> void:
	当前 = id; 展开 = true; 展开时 = 自动收
	if 风.丙(P) and 玩.B and 玩.B.get("驾") != null:                     # 丙：自动驾驶执行中不弹卡挡视野，底部提示「F 导览卡」
		展开 = false; 未读 = true
	卡.queue_redraw()


func 切卡() -> void:
	if 当前 == "": return
	展开 = not 展开; 展开时 = 自动收 if 展开 else 0.0; 未读 = false; 卡.queue_redraw()


# ———————————————————— 导览卡
func _画卡() -> void:
	if 当前 == "": return
	var q: Dictionary = 玩.点(当前)
	if q.is_empty(): return
	var c := 卡; var s: float = 风.s; var vs := c.get_viewport_rect().size
	if 风.丙(P): 画卡丙(q); return
	var x0 := 30.0*s; var y0 := 150.0*s; var w := 卡宽*s; var pad := 16.0*s
	if not 展开:                                                         # 收起：一行
		风.面板(c, Rect2(x0, y0, w, 46*s), 0.8)
		风.字串(c, Vector2(x0 + pad, y0 + 31*s), "▸ 导览卡：%s　F 展开" % q["名"], 20, 风.灰, "正")
		return
	var 照: Array = q.get("照片", [])
	var tex: Texture2D = 图(照[0]["文件"]) if not 照.is_empty() else null
	var ih := 0.0
	if tex: ih = (w - 2*pad)*tex.get_height()/tex.get_width()
	var 说明: String = q["说明"]
	var h: float = pad + 26*s + 28*s + 12*s + (ih + 6*s + 40*s if tex else 0.0) + 风.段高(说明, 20, w - 2*pad) + 44*s
	h = minf(h, vs.y - y0 - 400*s)
	风.面板(c, Rect2(x0, y0, w, h), 1.0)
	var y := y0 + pad + 26*s
	风.字串(c, Vector2(x0 + pad, y), q["名"], 26, 风.白, "粗")
	风.字串(c, Vector2(x0 + w - pad, y), "F 收起", 18, 风.淡, "正", HORIZONTAL_ALIGNMENT_RIGHT, 200*s)
	y += 28*s
	风.字串(c, Vector2(x0 + pad, y), "%sE %+.0f N %+.0f m" % [("%s · " % q["英"]) if not 令.英() else "", float(q["E"]), float(q["N"])], 18, 风.淡, "正")
	y += 12*s
	if tex:
		c.draw_texture_rect(tex, Rect2(x0 + pad, y, w - 2*pad, ih), false); y += ih + 6*s
		var f: Dictionary = 照[0]
		风.段落(c, Vector2(x0 + pad, y), "%s · sol %d · %s · %s" % [f["相机"], int(f["sol"]), f["产品"], f["署名"]], 14, 风.淡, w - 2*pad)
		y += 40*s
	y = 风.段落(c, Vector2(x0 + pad, y), 说明, 20, 风.白, w - 2*pad)
	var n: int = 玩.进度["已发现"].size()
	风.字串(c, Vector2(x0 + pad, minf(y + 24*s, y0 + h - 12*s)), "已发现 %d / %d · Tab 图鉴" % [n, 点表.size()], 18, 风.琥珀, "正")


func 画卡丙(q: Dictionary) -> void:
	"""丙：一组字加照片缩略图，锚在兴趣点小标旁边，没有底板。
	位置：小标右 / 左、车框右 / 左、左侧固定位几个候选里，挑和车（白车身最亮，压在上面字看不清）、小地图重叠最少的。"""
	if not 展开: return
	var c := 卡; var s: float = 风.s; var vs := c.get_viewport_rect().size
	var 界: Node = P.get_node_or_null("界面")
	var w := 440.0*s
	var 照: Array = q.get("照片", [])
	var tex: Texture2D = 图(照[0]["文件"]) if not 照.is_empty() else null
	var tw := 360.0*s; var ih := tw*tex.get_height()/tex.get_width() if tex else 0.0
	var 说明: String = q["说明"]
	var h: float = 40*s + 30*s + (ih + 16*s + 26*s if tex else 0.0) + 风.段高(说明, 20, w, "中") + 40*s
	var a: Vector3 = 界.锚屏(float(q["E"]), float(q["N"]), 2.2) if 界 else Vector3(0, 0, -1)
	var 引 := a.z > 0.0 and a.x > 0.0 and a.x < vs.x and a.y > 0.0 and a.y < vs.y
	var 车框: Rect2 = 界.车屏框() if 界 and 界.has_method("车屏框") else Rect2()
	if 车框.has_area(): 车框 = 车框.grow(28*s)
	var 图框 := Rect2(vs.x - 340*s, vs.y - 340*s, 340*s, 340*s)          # 右下小地图
	var 候: Array = []                                                 # [x0, y0]
	if 引:
		var yc := clampf(a.y - 60*s, 190*s, vs.y - h - 190*s)
		候.append([a.x + 56*s, yc]); 候.append([a.x - 56*s - w, yc])
		if 车框.has_area(): 候.append([车框.end.x + 24*s, yc]); 候.append([车框.position.x - 24*s - w, yc])
	候.append([96.0*s, 260.0*s])
	var x0 := 96.0*s; var y0 := 260.0*s; var 最 := INF
	for k in 候.size():
		var r := Rect2(候[k][0], 候[k][1], w, h)
		var 出 := maxf(0.0, 60*s - r.position.x) + maxf(0.0, r.end.x - (vs.x - 60*s))
		var 分 := 出*h*4.0 + r.intersection(车框).get_area()*1.0 + r.intersection(图框).get_area()*0.5 + k*400.0*s*s
		if 分 < 最: 最 = 分; x0 = 候[k][0]; y0 = 候[k][1]
	引 = 引 and absf(x0 - a.x) < vs.x*0.6                                 # 离小标太远就不画引线
	if 引:                                                             # 引线：小标 → 卡的标题
		var ex := x0 - 10*s if x0 > a.x else x0 + w + 10*s
		风.线(c, Vector2(a.x + (22*s if x0 > a.x else -22*s), a.y), Vector2(ex, y0 + 26*s), Color(风.白, 0.8), 2.0*s)
	var y := y0 + 34*s
	风.字串(c, Vector2(x0, y), q["名"], 风.号["题"], 风.白, "粗")
	y += 30*s
	风.字串(c, Vector2(x0, y), "%s东 %+.0f 北 %+.0f m" % [("%s · " % q["英"]) if not 令.英() else "", float(q["E"]), float(q["N"])], 风.号["小"], 风.灰, "中")
	y += 16*s
	if tex:
		var r := Rect2(x0, y, tw, ih)
		c.draw_rect(r.grow(2.5*s), Color(风.暗色, 0.5), false, 3*s)
		c.draw_texture_rect(tex, r, false)
		c.draw_rect(r.grow(0.75*s), Color(风.白, 0.85), false, 1.5*s)
		y += ih + 26*s
		var f: Dictionary = 照[0]
		风.字串(c, Vector2(x0, y - 4*s), "%s · 火星日 %d · %s" % [f["相机"], int(f["sol"]), f["署名"]], 风.号["注"], 风.淡, "正")
		y += 6*s
	y = 风.段落描边(c, Vector2(x0, y), 说明, 20, 风.白, w, "中")
	var n: int = 玩.进度["已发现"].size()
	风.图标(c, "图鉴", Vector2(x0 + 12*s, y + 14*s), 24, 风.灰)
	风.字串(c, Vector2(x0 + 32*s, y + 22*s), "已发现 %d / %d · Tab 图鉴 · F 收起" % [n, 点表.size()], 风.号["小"], 风.灰, "中")


# ———————————————————— 给界面
func 当前点() -> Dictionary:
	return 玩.点(当前) if 当前 != "" else {}


func 标记() -> Array:
	var out: Array = []
	for q in 点表:
		out.append({"E": float(q["E"]), "N": float(q["N"]), "名": q["名"], "已发现": 玩.进度["已发现"].has(q["id"]), "远": q["类"] == "远"})
	if 玩.复刻 and 玩.复刻.has_method("标记"): out.append_array(玩.复刻.标记())
	return out
