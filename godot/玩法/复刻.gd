# 复刻 NASA 照片（本项目独有：照片定标数据让我们知道每张真照片是在哪、朝哪拍的）。docs/玩法A.md §5。
#   在图鉴的「挑战」页选一张 → 右上角显示原图缩略图、航向带和小地图上出现琥珀方框（拍摄时车的位置）；
#   开到附近 → C 进拍照模式（N 是这张照片的 Navcam 视场）→ 调到相近的时刻 → Enter 交卷。
#   评分（宽松版）：Δp 水平位置差、Δa 视线夹角、Δt LTST 差、S 图像相似度（16×12 灰度梯度幅值的相关系数，负的算 0；见 相似()）；
#     f(x; a, b) = x ≤ a 得 1、x ≥ b 得 0、中间线性；
#     得分 = 100 × [0.30·f(Δp; 2 m, 15 m) + 0.40·f(Δa; 3°, 25°) + 0.10·f(Δt; 20 min, 120 min) + 0.20·S]；60 一星、75 两星、90 三星。
#   原图用 75 去畸变成针孔的版本（和游戏的 Navcam 取景同一几何），评分和并排都用它；并排下面写原图的产品号和署名。
extends Node

const 件 := preload("res://界面/件.gd")
const 权 := {"位置": 0.30, "方向": 0.40, "时刻": 0.10, "相似": 0.20}

var 玩: Node
var P: Node
var 风: RefCounted
var 层: CanvasLayer
var 角: Control                                    # 开车时右上的原图缩略图
var 结果层: Control
var 结果 := {}                                     # 最近一次交卷：{挑战, 分, 项, 玩家图, …}
var 结果开着 := false
var 图缓存 := {}
var 版本 := 0
var 累 := 0.0
var 悬 := -1
var 按过 := false
var 鼠标位 := Vector2.ZERO
var 结果框: Array = []


func _ready() -> void:
	玩 = get_parent(); P = 玩.P; 风 = 玩.风
	层 = CanvasLayer.new(); 层.layer = 13; add_child(层)
	角 = Control.new(); 角.mouse_filter = Control.MOUSE_FILTER_IGNORE; 角.draw.connect(_画角); 层.add_child(角)
	var 层2 := CanvasLayer.new(); 层2.layer = 45; add_child(层2)
	结果层 = Control.new(); 结果层.set_anchors_preset(Control.PRESET_FULL_RECT); 结果层.mouse_filter = Control.MOUSE_FILTER_STOP
	结果层.visible = false; 结果层.draw.connect(_画结果); 结果层.gui_input.connect(_结果鼠标)
	层2.add_child(结果层)


func 图(path: String) -> Texture2D:
	if not 图缓存.has(path): 图缓存[path] = 风.图(path)
	return 图缓存[path]


func 当前() -> Dictionary:
	return 玩.挑战(String(玩.进度.get("当前挑战", "")))


func 进行中() -> bool:
	return not 当前().is_empty()


func 视场() -> float:
	var c := 当前()
	return float(c["位姿"]["hfov"]) if not c.is_empty() else -1.0


# ———————————————————— 图鉴「挑战」页
func 条目() -> Array:
	var out: Array = []
	for c in 玩.数据["挑战"]:
		var best: Dictionary = 玩.进度["挑战"].get(c["id"], {})
		var 分 := int(best.get("最高分", -1))
		out.append({"类": "挑", "id": c["id"], "题": c["名"], "进行": 玩.进度.get("当前挑战", "") == c["id"],
			"副": "sol %d · %s · %s" % [int(c["sol"]), c["ltst"], ("%d %s" % [分, 星(分)]) if 分 >= 0 else "—"],
			"图": 玩.图路径(c["图针孔"]), "提示": "%s\n%s · %s" % [c["提示"], c["产品"], c["署名"]], "键": [int(c["sol"]), 0.0]})
	return out


func 选择(e: Dictionary) -> void:
	玩.进度["当前挑战"] = e["id"]; 玩.存进度(); 版本 += 1; 角.queue_redraw()
	print("[玩法] 开始复刻挑战：", 当前()["名"])


func 放弃() -> void:
	玩.进度["当前挑战"] = ""; 玩.存进度(); 版本 += 1; 角.queue_redraw()


func 标记() -> Array:
	var c := 当前()
	if c.is_empty(): return []
	return [{"E": float(c["车"]["E"]), "N": float(c["车"]["N"]), "名": c["名"], "已发现": false, "远": false, "挑战": true}]


func _process(dt: float) -> void:
	if 结果开着: 件.提示更(str(悬) if 悬 >= 0 else "", dt); 结果层.queue_redraw()
	累 += dt
	if 累 > 0.5 and 进行中(): 累 = 0.0; 角.queue_redraw()                 # 距离读数 2 Hz


# ———————————————————— 开车时的缩略图（右上，太阳表下面）
func _画角() -> void:
	var c := 当前()
	if c.is_empty() or (玩.拍照 and 玩.拍照.开着): return
	var s: float = 风.s; var vs := 角.get_viewport_rect().size
	var w := 340.0*s; var t := 图(玩.图路径(c["图针孔"])); var ih := w*0.75
	var r := Rect2(vs.x - w - 40*s, 290*s, w, ih + 60*s)
	风.面板(角, r, 0.9)
	if t: 角.draw_texture_rect(t, Rect2(r.position + Vector2(0, 2*s), Vector2(w, ih)), false)
	var p: Vector3 = 玩.车位(); var d := Vector2(float(c["车"]["E"]) - p.x, float(c["车"]["N"]) + p.z).length()
	件.图标(角, "拍照", r.position + Vector2(26, ih + 32)*s, 32.0, 风.琥珀)
	风.字串(角, r.position + Vector2(52*s, ih + 40*s), ("%.0f m" % d) if d < 1000 else ("%.1f km" % (d/1000.0)), 24, 风.琥珀, "等中")
	风.字串(角, r.position + Vector2(w - 12*s, ih + 40*s), String(c["ltst"]), 24, 风.白, "等中", HORIZONTAL_ALIGNMENT_RIGHT, w*0.5)


func 画参考(c: Control) -> void:
	"""拍照模式叠加层（不进照片）：左上角原图，便于对着取景。"""
	var ch := 当前()
	if ch.is_empty(): return
	var s: float = 风.s; var w := 420.0*s; var t := 图(玩.图路径(ch["图针孔"]))
	var r := Rect2(30*s, 90*s, w, w*0.75)
	风.面板(c, Rect2(r.position - Vector2(0, 40*s), r.size + Vector2(0, 40*s)), 0.85)
	件.图标(c, "图鉴", r.position + Vector2(24*s, -20*s), 28.0, 风.白)
	风.字串(c, r.position + Vector2(48*s, -12*s), "%s · %s" % [ch["名"], ch["ltst"]], 20, 风.白, "中")
	if t: c.draw_texture_rect(t, r, false)


# ———————————————————— 交卷
func f(x: float, a: float, b: float) -> float:
	return clampf((b - x)/(b - a), 0.0, 1.0)


func 星(分: int) -> String:
	return "★★★" if 分 >= 90 else ("★★☆" if 分 >= 75 else ("★☆☆" if 分 >= 60 else "☆☆☆"))


func 相似(a: Image, b: Image) -> float:
	"""两张图各取居中 4:3、缩成 16×12 灰度，算梯度幅值（中心差分），再算两张梯度图的相关系数。
	看的是天际线、机械臂、大石块这类轮廓在画面里的位置。试过 64×48 灰度直接相关（转开 90° 也有 0.79）、
	64×48 去低频（原位只有 0.04，渲染和照片的细节对不上），16×12 梯度在原位 0.58、转开 90° 0.40，区分度最好但仍然弱。"""
	var v: Array = []
	for im0: Image in [a, b]:
		var im := im0.duplicate() as Image
		var w := im.get_width(); var h := im.get_height(); var cw := mini(w, h*4/3); var chh := cw*3/4
		im = im.get_region(Rect2i((w - cw)/2, (h - chh)/2, cw, chh)); im.convert(Image.FORMAT_L8)
		im.resize(64, 48, Image.INTERPOLATE_LANCZOS); im.resize(16, 12, Image.INTERPOLATE_LANCZOS)
		var d := im.get_data(); var g := PackedFloat32Array(); g.resize(16*12)
		for y in 12:
			for x in 16:
				var gx := (float(d[y*16 + mini(x + 1, 15)]) - float(d[y*16 + maxi(x - 1, 0)]))/(2.0 if x > 0 and x < 15 else 1.0)
				var gy := (float(d[mini(y + 1, 11)*16 + x]) - float(d[maxi(y - 1, 0)*16 + x]))/(2.0 if y > 0 and y < 11 else 1.0)
				g[y*16 + x] = sqrt(gx*gx + gy*gy)
		var m := 0.0
		for q in g: m += q
		m /= g.size(); var sd := 0.0
		for i2 in g.size(): g[i2] -= m; sd += g[i2]*g[i2]
		sd = sqrt(sd/g.size()) + 1e-6
		for i2 in g.size(): g[i2] /= sd
		v.append(g)
	var r := 0.0
	for i2 in v[0].size(): r += v[0][i2]*v[1][i2]
	return r/v[0].size()


func 交卷() -> void:
	var c := 当前()
	if c.is_empty() or 玩.拍照 == null or not 玩.拍照.开着: return
	var 位: Dictionary = 玩.拍照.当前位姿()
	var tp := Vector3(c["位姿"]["pos"][0], c["位姿"]["pos"][1], c["位姿"]["pos"][2]); var tf := Vector3(c["位姿"]["fwd"][0], c["位姿"]["fwd"][1], c["位姿"]["fwd"][2])
	var pp: Vector3 = 位["pos"]; var pf: Vector3 = 位["fwd"]
	var dp := Vector2(pp.x - tp.x, pp.y - tp.y).length()
	var da := rad_to_deg(acos(clampf(pf.normalized().dot(tf.normalized()), -1.0, 1.0)))
	var 目: float = P.minutes(String(c["ltst"])); var dt := absf(float(位["分"]) - 目)
	var meta: Dictionary = await 玩.拍照.拍(true)
	if meta.is_empty(): return
	var 玩家 := Image.load_from_file(ProjectSettings.globalize_path(meta["文件"]))
	var 原 := Image.load_from_file(玩.图路径(c["图针孔"]))
	var S := maxf(0.0, 相似(玩家, 原)) if 玩家 and 原 else 0.0
	var 项 := {"位置": f(dp, 2.0, 15.0), "方向": f(da, 3.0, 25.0), "时刻": f(dt, 20.0, 120.0), "相似": S}
	var 分 := 0.0
	for k in 项: 分 += 100.0*权[k]*项[k]
	var n := roundi(分)
	var 旧: Dictionary = 玩.进度["挑战"].get(c["id"], {})
	var best := maxi(int(旧.get("最高分", -1)), n)
	玩.进度["挑战"][c["id"]] = {"最高分": best, "次数": int(旧.get("次数", 0)) + 1, "最好": meta["文件"] if n >= int(旧.get("最高分", -1)) else 旧.get("最好", ""), "时间": Time.get_datetime_string_from_system()}
	玩.存进度(); 版本 += 1
	meta["挑战"] = c["id"]; meta["挑战名"] = c["名"]; meta["得分"] = n
	meta["评分"] = {"Δp_m": snappedf(dp, 0.01), "Δa_deg": snappedf(da, 0.01), "Δt_min": snappedf(dt, 0.1), "相似": snappedf(S, 0.001), "各项": 项}
	var fj := FileAccess.open(String(meta["文件"]).replace(".png", ".json"), FileAccess.WRITE); fj.store_string(JSON.stringify(meta, "\t")); fj.close()
	结果 = {"挑战": c, "分": n, "项": 项, "dp": dp, "da": da, "dt": dt, "S": S, "玩家": meta["文件"]}
	print("[玩法] 复刻交卷 %s：%d 分（Δp %.1f m、Δa %.1f°、Δt %.0f min、S %.2f）" % [c["名"], n, dp, da, dt, S])
	结果开着 = true; 结果层.visible = true; 结果层.queue_redraw()


func 关结果() -> void:
	结果开着 = false; 结果层.visible = false


func 输入(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not ev.echo and ev.keycode in [KEY_ESCAPE, KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]: 关结果()


func _画结果() -> void:
	if 结果.is_empty(): return
	var c := 结果层; var s: float = 风.s; var vs := c.size; var ch: Dictionary = 结果["挑战"]
	c.draw_rect(Rect2(Vector2.ZERO, vs), 风.页底)                       # 整屏页底（令牌）
	var n: int = 结果["分"]
	风.字串(c, Vector2(vs.x*0.5, 80*s), "%s　%d　%s" % [ch["名"], n, 星(n)], 34, 风.琥珀 if n >= 60 else 风.白, "粗", HORIZONTAL_ALIGNMENT_CENTER)
	var gap := 40.0*s; var w := (vs.x - 3*gap)*0.5; var h := w*0.75
	if h > vs.y - 420*s: h = vs.y - 420*s; w = h/0.75
	var x0 := (vs.x - 2*w - gap)*0.5; var y0 := 120*s
	var a := 图(结果["玩家"]); var b := 图(玩.图路径(ch["图针孔"]))
	for k in 2:
		var t: Texture2D = a if k == 0 else b; var r := Rect2(x0 + k*(w + gap), y0, w, h)
		c.draw_rect(r, Color(风.暗色, 0.6))
		if t:
			var kk: float = minf(w/t.get_width(), h/t.get_height()); var sz := Vector2(t.get_width(), t.get_height())*kk
			c.draw_texture_rect(t, Rect2(r.position + (r.size - sz)*0.5, sz), false)
		件.图标(c, "拍照" if k == 0 else "图鉴", Vector2(r.position.x + 18*s, r.end.y + 26*s), 30.0, 风.白)
		风.字串(c, Vector2(r.position.x + 46*s, r.end.y + 36*s), ("%s" % 玩.拍照.时刻文()) if k == 0 else "sol %d · %s" % [int(ch["sol"]), ch["ltst"]], 22, 风.白, "等中")
	var y := y0 + h + 80*s
	var 项: Dictionary = 结果["项"]
	var 格 := [["航点", "%.1f m" % 结果["dp"], 项["位置"], "位置：差 2 m 内满分，15 m 外为 0（占 30 %）"], ["转向", "%.1f°" % 结果["da"], 项["方向"], "方向：差 3° 内满分，25° 外为 0（占 40 %）"],
		["时刻", "%.0f 分" % 结果["dt"], 项["时刻"], "时刻：差 20 分钟内满分，120 分钟外为 0（占 10 %）"], ["图鉴", "%.2f" % 结果["S"], 项["相似"], "画面轮廓相似度（占 20 %）；总分 60 通过"]]
	var 列w := (2*w + gap)/4.0; 结果框.clear()
	for i in 4:
		var q: Array = 格[i]; var cx := x0 + 列w*i; var hv := 件.悬度("复刻项%d" % i, 悬 == i)
		var 框 := Rect2(cx - 10*s, y - 40*s, 列w - 10*s, 96*s); 结果框.append(框)
		if hv > 0.01: c.draw_rect(框, Color(风.白, 0.10*hv))
		件.图标(c, q[0], Vector2(cx + 20*s, y - 8*s), 36.0, 风.白)
		风.字串(c, Vector2(cx + 54*s, y), q[1], 26, 风.白, "等中")
		件.条(c, Rect2(cx, y + 18*s, 列w - 40*s, 8*s), q[2])
		风.字串(c, Vector2(cx + 列w - 40*s, y), "%.0f%%" % (q[2]*100.0), 22, 风.灰, "等", HORIZONTAL_ALIGNMENT_RIGHT)
	y += 96*s
	风.段落(c, Vector2(x0, y), "%s · %s · sol %d（%s）· %s · %s" % [ch["相机"], ch["产品"], int(ch["sol"]), ch["utc"], ch["署名"], ch["url"]], 16, 风.灰, 2*w + gap)
	件.键图行(c, Vector2(vs.x*0.5, vs.y - 34*s), [["Enter", "关闭", ""]], 悬 == 9, 0)
	if 悬 >= 0 and 悬 < 4: 件.提示画(c, String(格[悬][3]), 鼠标位, vs)


func _结果鼠标(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion:
		鼠标位 = ev.position; 悬 = 件.命中(结果框, ev.position); 结果层.queue_redraw()
	elif ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		if ev.pressed: 按过 = true
		elif 按过: 按过 = false; 关结果()
