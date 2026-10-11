# 界面组件库（docs/界面/UI体系.md §2）：HUD（界面.gd）、玩法 A 导览卡、B 整屏页、拍照模式、主菜单共用的一套画法。
#   全是静态函数，用法：const 件 := preload("res://界面/件.gd")；在 CanvasItem 的 _draw 里 件.字串(self, …)。
#   - 颜色、字号、线宽、描边、时长都从令牌（autoload「令」，界面/令牌.gd）取；这里不写颜色常数。
#   - 尺寸参数一律按 1440p 像素给，函数里乘 令.s（字号再乘 令.字倍）。坐标参数是屏幕像素（已经乘过 s）。
#   - 可读性（没有暗底板）：字 = 下移阴影 + 宽淡外圈 + 内圈；线 = 下移阴影 + 外扩 + 芯；图标垫外扩。
#     外扩颜色由 令.边(色) 决定：「活」色在 NASA 色板里配白边（深蓝芯 + 白边，再外一圈淡暗色），其余配暗色。
#   - 出现 / 消失：带 出 参数（0–1）的组件自己按令牌的节奏画出部分（线从一端画出、小标先落点再长杆、字闪一下再稳）；
#     进度由调用方用 件.进(表, 键, 要显, dt) 推（每个元素一条记录，没有循环动画）。
#   组件目录：线 折 弧 点 字串 段落描边 段落 图标 键帽 键提示 小标 题 节 条 钮 页框 面板 渐线 数到 页题 组头 行标 选项 滑条 引线 左渐变。
#   界面 5（规范 §3 §4 §5）加的：趋（指数趋近，所有动画的底层，受「界面动效」控制）悬度 滑竖 命中 提示更 提示画 告警；选项 / 滑条 / 行标 多了可选参数（旧调用不变）。
extends RefCounted

const 图标脚本 := preload("res://界面/图标.gd")
static var _标: RefCounted = null


static func S() -> float:
	return 令.s


static func 标() -> RefCounted:
	if _标 == null: _标 = 图标脚本.new()
	return _标


static func 字号(size: float) -> int:
	return int(round(size*令.s*令.字倍))


static func 宽度(t: String, size: float, fk := "中") -> float:
	return (令.字[fk] as Font).get_string_size(令.译(t), HORIZONTAL_ALIGNMENT_LEFT, -1, 字号(size)).x


# ———————————————————— 线（一条 / 折线 / 弧 / 点）
static func 线(c: CanvasItem, a: Vector2, b: Vector2, col: Color, w := 2.0, 影 := true) -> void:
	var s := 令.s; var D: Dictionary = 令.描; var 边色 := 令.边(col); var 活 := 令.有活边 and 令.是活(col)
	if 活: w += D["活加宽"]
	w *= s
	if 影: c.draw_line(a + Vector2(0, D["影移"]*s), b + Vector2(0, D["影移"]*s), Color(令.色["暗"], D["影a"]*col.a), w + D["线影"]*s, true)
	if 活:
		c.draw_line(a, b, Color(令.色["暗"], 0.45*col.a), w + (2.0*D["活边"] + D["线外"])*s, true)
		c.draw_line(a, b, Color(边色, col.a), w + 2.0*D["活边"]*s, true)
	else:
		c.draw_line(a, b, Color(边色, D["线a"]*col.a), w + D["线外"]*s, true)
	c.draw_line(a, b, col, w, true)


static func 折(c: CanvasItem, pts: PackedVector2Array, col: Color, w := 2.0) -> void:
	var s := 令.s; var D: Dictionary = 令.描; var 活 := 令.有活边 and 令.是活(col)
	if pts.size() < 2: return
	if 活:
		w += D["活加宽"]
		c.draw_polyline(pts, Color(令.色["暗"], 0.45*col.a), (w + 2.0*D["活边"])*s + D["线外"]*s, true)
		c.draw_polyline(pts, Color(令.色["活边"], col.a), (w + 2.0*D["活边"])*s, true)
	else:
		c.draw_polyline(pts, Color(令.色["暗"], D["线a"]*col.a), w*s + D["线外"]*s, true)
	c.draw_polyline(pts, col, w*s, true)


static func 弧(c: CanvasItem, o: Vector2, r: float, a0: float, a1: float, col: Color, w := 2.0, n := 32) -> void:
	var s := 令.s; var D: Dictionary = 令.描; var 活 := 令.有活边 and 令.是活(col)
	if 活:
		w += D["活加宽"]
		c.draw_arc(o, r, a0, a1, n, Color(令.色["暗"], 0.45*col.a), (w + 2.0*D["活边"])*s + D["线外"]*s, true)
		c.draw_arc(o, r, a0, a1, n, Color(令.色["活边"], col.a), (w + 2.0*D["活边"])*s, true)
	else:
		c.draw_arc(o, r, a0, a1, n, Color(令.色["暗"], D["线a"]*col.a), w*s + D["线外"]*s, true)
	c.draw_arc(o, r, a0, a1, n, col, w*s, true)


static func 点(c: CanvasItem, p: Vector2, r: float, col: Color) -> void:
	var s := 令.s
	if 令.有活边 and 令.是活(col): c.draw_circle(p, (r + 1.6 + 令.描["活边"])*s, Color(令.色["活边"], col.a))
	else: c.draw_circle(p, (r + 令.描["点外"])*s, Color(令.色["暗"], 0.55*col.a))
	c.draw_circle(p, r*s, col)


static func 渐线(c: CanvasItem, pts: PackedVector2Array, 出: float, col: Color, w := 2.0) -> void:
	"""线从第一个点「画」出来：按长度截到 出（0–1）。"""
	if 出 >= 0.999: 折(c, pts, col, w); return
	if 出 <= 0.001 or pts.size() < 2: return
	var L := 0.0
	for i in pts.size() - 1: L += pts[i].distance_to(pts[i + 1])
	var 要 := L*令.缓(出); var out := PackedVector2Array([pts[0]]); var 走 := 0.0
	for i in pts.size() - 1:
		var d := pts[i].distance_to(pts[i + 1])
		if 走 + d >= 要: out.append(pts[i].lerp(pts[i + 1], (要 - 走)/maxf(d, 1e-6))); break
		out.append(pts[i + 1]); 走 += d
	折(c, out, col, w)


# ———————————————————— 字
static func 字串(c: CanvasItem, p: Vector2, t: String, size: float, col: Color, fk := "中", 对齐 := HORIZONTAL_ALIGNMENT_LEFT, 宽 := -1.0, 细 := false) -> void:
	"""描边文字。p：左对齐为左端基线；居中为中点基线；右对齐为右端基线。宽：> 0 时在这么宽里对齐。"""
	t = 令.译(t)                                                      # 英文界面：原文是中文，这里换成英文（中文模式原样）
	if 记字:
		字记.append(t)
		var fz: Font = 令.字[fk]; var pz := 字号(size); var wz := fz.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, pz).x
		var xz := p.x - (0.0 if 对齐 == HORIZONTAL_ALIGNMENT_LEFT else (wz*0.5 if 对齐 == HORIZONTAL_ALIGNMENT_CENTER else wz))
		字框记.append([t, Rect2(xz, p.y - fz.get_ascent(pz)*0.95, wz, (fz.get_ascent(pz) + fz.get_descent(pz))*0.95), col, size, Vector2(xz, p.y), fk])
	var s := 令.s; var D: Dictionary = 令.描
	var f: Font = 令.字[fk]; var px := 字号(size); var W := 宽 if 宽 > 0.0 else 1600.0*s
	var x := p.x if 对齐 == HORIZONTAL_ALIGNMENT_LEFT else (p.x - W*0.5 if 对齐 == HORIZONTAL_ALIGNMENT_CENTER else p.x - W)
	var q := Vector2(x, p.y); var wd := -1.0 if 对齐 == HORIZONTAL_ALIGNMENT_LEFT and 宽 <= 0.0 else W
	var 暗: Color = 令.色["暗"]; var 内: Color = 令.边(col)
	var 活 := 令.有活边 and 令.是活(col)
	var 内px := maxi(2, int(ceil(描宽(size)*令.描系)))                  # 界面 6：压在 3D 上的字，描边是不透明的深色，外扩 ≥ max(3 px, 字高 × 8 %)（规范 §5），字对它自己的描边量
	if 细:                                                          # 小字（≤ 20 px）：不要宽淡外圈，只有阴影 + 同样宽的不透明描边（描边画在字芯底下，不会吃笔画）
		c.draw_string_outline(f, q + Vector2(0, 2.0*s), t, 对齐, wd, px, 内px + 1, Color(暗, 0.35*col.a))
		c.draw_string_outline(f, q, t, 对齐, wd, px, 内px, Color(内, col.a))
		c.draw_string(f, q, t, 对齐, wd, px, col)
		return
	c.draw_string_outline(f, q + Vector2(0, D["影移"]*s), t, 对齐, wd, px, maxi(3, int(round(D["字影"]*s))) + 内px, Color(暗, D["字影a"]*col.a))
	c.draw_string_outline(f, q, t, 对齐, wd, px, maxi(6, int(round((D["字外"] + (4.0 if 活 else 0.0))*s))) + 内px, Color(暗, (0.5 if 活 else D["字外a"])*col.a))
	c.draw_string_outline(f, q, t, 对齐, wd, px, 内px, Color(内, col.a))
	c.draw_string(f, q, t, 对齐, wd, px, col)


static func 描宽(size: float) -> float:
	"""压在 3D 画面上的字的描边外扩宽度（屏幕像素，已乘界面缩放）：max(3 px, 字号 × 8 %)。规范 §5 要 ≥ max(2 px, 字高 × 8 %)。"""
	return maxf(4.0, 0.10*size)*令.s


static func _段(t: String, size: float, 宽: float, fk: String) -> TextParagraph:
	var tl := TextParagraph.new(); tl.add_string(令.译(t), 令.字[fk], 字号(size)); tl.width = 宽
	tl.break_flags = TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | (TextServer.BREAK_ADAPTIVE if 令.英() else TextServer.BREAK_GRAPHEME_BOUND)   # 英文：在空格处折行，单词放不下才拆
	return tl


static func 段落描边(c: CanvasItem, p: Vector2, t: String, size: float, col: Color, 宽: float, fk := "正", 行距 := 1.45) -> float:
	"""自动换行、带描边的一段字（不放面板时用，导览卡），返回画完后的 y（下一行的顶）。"""
	var s := 令.s; var D: Dictionary = 令.描; var 暗: Color = 令.色["暗"]
	var tl := _段(t, size, 宽, fk); var px := 字号(size)
	var y := p.y; var ci := c.get_canvas_item()
	for i in tl.get_line_count():
		var lh := px*行距; var q := Vector2(p.x, y + (lh - tl.get_line_size(i).y)*0.5)
		tl.draw_line_outline(ci, q + Vector2(0, D["影移"]*s), i, maxi(3, int(round(D["字影"]*s))), Color(暗, D["字影a"]*col.a))
		tl.draw_line_outline(ci, q, i, maxi(6, int(round(D["字外"]*s))), Color(暗, D["字外a"]*col.a))
		tl.draw_line_outline(ci, q, i, maxi(3, int(round(D["字内"]*s))), Color(令.边(col), D["字内a"]*col.a))
		tl.draw_line(ci, q, i, col)
		y += lh
	return y


static func 段落(c: CanvasItem, p: Vector2, t: String, size: float, col: Color, 宽: float, fk := "正", 行距 := 1.45) -> float:
	"""自动换行的一段字（不描边，放在面板 / 整屏页上），返回画完后的 y。"""
	var tl := _段(t, size, 宽, fk); var px := 字号(size)
	var y := p.y
	for i in tl.get_line_count():
		var lh := px*行距
		tl.draw_line(c.get_canvas_item(), Vector2(p.x, y + (lh - tl.get_line_size(i).y)*0.5), i, col)
		y += lh
	return y


static func 段高(t: String, size: float, 宽: float, fk := "正", 行距 := 1.45) -> float:
	return _段(t, size, 宽, fk).get_line_count()*字号(size)*行距


static func 数到(目标: float, 出: float) -> float:
	"""数字从 0 数到目标（出 0–1，ease-out）。"""
	return 目标*令.缓(出)


# ———————————————————— 图标（甲套，界面/图标.gd）
static func 图标(c: CanvasItem, 名: String, 心: Vector2, px: float, col := Color(-1, 0, 0)) -> void:
	"""px 按 1440p 给；col 默认令牌主色。外扩颜色按 令.边(col)。"""
	if col.r < 0.0: col = 令.色["主"]
	标().画(c, 名, 心, px*令.s, col, 令.边(col), 令.有活边 and 令.是活(col))


# ———————————————————— 按键提示
static func 键帽(c: CanvasItem, p: Vector2, k: String, col := Color(-1, 0, 0), size := 24.0) -> float:
	"""直角细框的键帽：p 为左端基线；返回宽度（屏幕像素）。"""
	var s := 令.s
	if col.r < 0.0: col = 令.色["主"]
	var w := maxf(40*s, 宽度(k, size) + 22*s); var h := 40*s
	var r := Rect2(p + Vector2(0, -30*s), Vector2(w, h))
	c.draw_rect(r.grow(1.6*s), Color(令.边(col), 0.5*col.a), false, 3.2*s)
	c.draw_rect(r, col, false, 2*s)
	字串(c, Vector2(p.x + w*0.5, p.y - 1*s), k, size, col, "中", HORIZONTAL_ALIGNMENT_CENTER)
	return w


static func 键提示(c: CanvasItem, 心: Vector2, 表: Array, size := 28.0, 键号 := 24.0, 间 := 44.0, 左 := false, 字透 := 1.0) -> Rect2:
	"""一行按键提示（键帽 + 说明），以 心 为中点基线居中；表 [[键, 说明], …]；返回占的矩形。"""
	var s := 令.s; var 主: Color = 令.色["主"]
	var ws: Array = []; var tot := 0.0
	for h: Array in 表:
		var w := maxf(40*s, 宽度(h[0], 键号) + 22*s) + 12*s + 宽度(h[1], size); ws.append(w); tot += w
	tot += 间*s*(表.size() - 1)
	var x := 心.x if 左 else 心.x - tot*0.5                                # 左：心.x 是左端
	for i in 表.size():
		var h: Array = 表[i]
		var kw := 键帽(c, Vector2(x, 心.y), h[0], 主, 键号)
		字串(c, Vector2(x + kw + 12*s, 心.y), h[1], size, Color(主, 字透), "中", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 字透 < 1.0)
		x += ws[i] + 间*s
	return Rect2((心.x if 左 else 心.x - tot*0.5) - 12*s, 心.y - 42*s, tot + 24*s, 64*s)


# ———————————————————— 世界锚定小标（Tag）：落地点 + 立杆 + 图标 + 一 / 两行字
static func 小标框(pt: Vector2, 行1: String, 行2: String, 字号1 := 26.0) -> Rect2:
	var s := 令.s
	var tw := maxf(maxf(宽度(行1, 字号1), 宽度(行2, 22)), 40*s) + 16*s
	var top := pt.y - 32*s - (30*s if 行1 != "" else 0.0) - (26*s if 行2 != "" else 0.0) - 6*s
	return Rect2(pt.x - tw*0.5, top, tw, pt.y + 22*s - top)


static func 小标(c: CanvasItem, pg: Vector3, pt: Vector3, 图名: String, 行1: String, 行2: String, col: Color, 字号1 := 26.0, 出 := 1.0, 杆色 := Color(-1, 0, 0), 字位 := "上") -> void:
	"""pg：落地点屏幕 (x, y, z>0 可见)；pt：图标中心。出（0–1）：0–0.35 落点 + 立杆从地面长上去，0.3–0.6 图标，0.55–1 字（闪一下再稳）。
	字位：上（兴趣点：名字在图标上方、距离再上一行）/ 右（主菜单项：名字在图标右边）。"""
	var s := 令.s
	if 杆色.r < 0.0: 杆色 = Color(col, 0.85*col.a)
	var 杆 := clampf(出/0.35, 0.0, 1.0); var 标t := clampf((出 - 0.3)/0.3, 0.0, 1.0); var 字t := clampf((出 - 0.55)/0.45, 0.0, 1.0)
	var 顶 := Vector2(pt.x, pt.y + 20*s)
	if pg.z > 0.0:
		var g := Vector2(pg.x, pg.y)
		if 杆 > 0.0: 线(c, g, g.lerp(顶, 令.缓(杆)), 杆色, 2)
		点(c, g, 3.5, col)
	if 标t <= 0.0: return
	var k := 令.缓(标t, "弹") if 标t < 1.0 else 1.0
	图标(c, 图名, Vector2(pt.x, pt.y), 36*maxf(k, 0.2), Color(col, col.a*minf(1.0, 标t*2.0)))
	if 字t <= 0.0: return
	var a := col.a*(1.0 if 字t >= 1.0 else (0.4 if 字t < 0.35 else 令.缓(字t)))     # 闪：先 40 % 两帧，再淡到 100 %
	if 字位 == "右":
		字串(c, Vector2(pt.x + 28*s, pt.y + 字号1*0.36*s), 行1, 字号1, Color(col, a), "中")
		if 行2 != "": 字串(c, Vector2(pt.x + 30*s, pt.y + 字号1*0.36*s + 30*s), 行2, 20, Color(col, 0.85*a), "中")
		return
	var y := pt.y - 32*s
	if 行1 != "": 字串(c, Vector2(pt.x, y), 行1, 字号1, Color(col, a), "中", HORIZONTAL_ALIGNMENT_CENTER); y -= 30*s
	if 行2 != "": 字串(c, Vector2(pt.x, y), 行2, 22, Color(col, 0.9*a), "中", HORIZONTAL_ALIGNMENT_CENTER)


# ———————————————————— 页面元素
static func 题(c: CanvasItem, p: Vector2, 图名: String, t: String, size := 42.0, col := Color(-1, 0, 0)) -> void:
	"""页标题：甲套图标 + 粗字。p：图标左端、字的基线。"""
	var s := 令.s
	if col.r < 0.0: col = 令.色["主"]
	图标(c, 图名, p + Vector2(size*0.5*s, -size*0.36*s), size*0.95, col)
	字串(c, p + Vector2(size*1.2*s, 0), t, size, col, "粗")


static func 节(c: CanvasItem, p: Vector2, w: float, t: String, 图名 := "", size := 28.0) -> void:
	"""小节标题：上方一道 2 px 细线，下面图标 + 标签。"""
	var s := 令.s; var 主: Color = 令.色["主"]
	c.draw_line(p + Vector2(0, -30*s), p + Vector2(w, -30*s), Color(主, 0.55), maxf(1.0, 2*s))
	var x := p.x
	if 图名 != "": 图标(c, 图名, Vector2(x + 13*s, p.y - 9*s), 26); x += 34*s
	字串(c, Vector2(x, p.y), t, size, 主, "中")


static func 面板(c: CanvasItem, r: Rect2, a := 1.0) -> void:
	"""要读一段字的面板（菜单、图鉴；不用在 HUD 上）：半透明底 + 顶上一道细亮线，不画圆角和四周边框。"""
	var 底: Color = 令.色["底"]
	c.draw_rect(r, Color(底, 底.a*a))
	c.draw_line(r.position, r.position + Vector2(r.size.x, 0), Color(令.色["主"], 0.55*a), maxf(1.0, 2.0*令.s))


static func 页框(c: CanvasItem, vs: Vector2, 题字: String, 图名 := "", 副 := "", a := 1.0) -> float:
	"""整屏页（规划图、下行卡、报告卡、设置、关于、图鉴）：整屏底 + 左上标题（+ 副题）。返回内容区的顶（y）。"""
	var s := 令.s; var 底: Color = 令.色["页底"]
	c.draw_rect(Rect2(Vector2.ZERO, vs), Color(底, 底.a*a))
	var p := Vector2(令.距["页边"]*s, 150*s)
	if 题字 != "": 题(c, p, 图名, 题字, 令.号["大题"])
	if 副 != "": 字串(c, p + Vector2(0, 44*s), 副, 令.号["次"], Color(令.色["次"], a), "正")
	return p.y + (90.0 if 副 != "" else 56.0)*s


static func 条(c: CanvasItem, r: Rect2, v: float, col := Color(-1, 0, 0), 标线 := -1.0, 出 := 1.0) -> void:
	"""条 / 量表：细框 + 实心填充到 v（0–1）；标线：下限等刻度（0–1，< 0 不画）。出：填充从左往右长出来。"""
	var s := 令.s
	if col.r < 0.0: col = 令.色["主"]
	c.draw_rect(r.grow(1.2*s), Color(令.边(col), 0.5), false, 3.0*s)
	c.draw_rect(r, Color(col, 0.6), false, maxf(1.0, 1.5*s))
	var f := clampf(v, 0.0, 1.0)*令.缓(出)
	if f > 0.0: c.draw_rect(Rect2(r.position, Vector2(r.size.x*f, r.size.y)), Color(col, 0.85))
	if 标线 >= 0.0:
		var x := r.position.x + r.size.x*标线
		c.draw_line(Vector2(x, r.position.y - 4*s), Vector2(x, r.end.y + 4*s), 令.色["注意"], 2*s)


static func 钮(c: CanvasItem, p: Vector2, t: String, 态 := "常", size := 30.0, 副 := "", 出 := 1.0) -> Rect2:
	"""菜单项（整屏页 / 暂停菜单 / 设置；主菜单的地上小标用 小标）：p 为左端基线。
	态：常 / 悬 / 选 / 禁 / 注意 / 警告。选中：活色 + 左侧一道竖线；悬：主色 + 细下划线。返回占的矩形。"""
	var s := 令.s; var col := 令.态色(态); col.a *= 令.缓(出)
	var 粗 := 态 == "选"
	var sz := size*(1.15 if 粗 else 1.0)
	var w := 宽度(t, sz, "粗" if 粗 else "中")
	if 态 == "选": 线(c, Vector2(p.x - 22*s, p.y - sz*0.85*s), Vector2(p.x - 22*s, p.y + 8*s), col, 4, false)
	elif 态 == "悬": c.draw_line(Vector2(p.x, p.y + 8*s), Vector2(p.x + w, p.y + 8*s), Color(col, 0.6*col.a), maxf(1.0, 2*s))
	字串(c, p, t, sz, col, "粗" if 粗 else "中")
	var h := sz*1.25*s
	if 副 != "" and 态 == "选": 字串(c, p + Vector2(0, 34*s), 副, 令.号["次"], Color(令.色["次"], col.a), "正"); h += 34*s
	return Rect2(p.x - 30*s, p.y - sz*s, w + 40*s, h)


# ———————————————————— 设置页组件（界面 4；位置、字号、线宽 1:1 取自 docs/界面/主菜单样张/生成/a.py 的 页头 / 节 / 选项行 / 滑条，2560×1440）
#   选中 = 主（最亮）+ 粗 + 活亮下划线；其余 = 次 × 0.8；强调线 = 活亮；页题下短线 = 强。
static func 字距(c: CanvasItem, p: Vector2, t: String, size: float, col: Color, fk: String, 距px: float) -> float:
	"""逐字加字距（样张的 letter-spacing）；p：左端基线，距px 按 1440p 给。返回结束 x。"""
	var x := p.x
	t = 令.译(t)
	for ch in t:
		字串(c, Vector2(x, p.y), ch, size, col, fk)
		x += 宽度(ch, size, fk) + 距px*令.s
	return x


static func 页题(c: CanvasItem, p: Vector2, t: String, 面包屑: String, a := 1.0, size := 56.0) -> void:
	"""样张页头：Noto 300、字距 10 的大题（p = 左端基线）、其下 2 px…短下划线（强色）、面包屑（次，20，p + (4, 44)）。"""
	var s := 令.s
	字距(c, p, t, size, Color(令.色["主"], a), "片", 10)
	线(c, p + Vector2(2*s, 16*s), p + Vector2(62*s, 16*s), Color(令.色["强"], a), 3.0, false)
	字串(c, p + Vector2(4*s, 44*s), 面包屑, 令.号["次"], Color(令.色["次"], 0.85*a), "正")


static func 组头(c: CanvasItem, p: Vector2, w: float, t: String, 图名: String, a := 1.0) -> void:
	"""样张「节」：28 px 图标（左上角在 p + (0, −24)）+ 22 px 粗标签（字距 4，x + 42）+ 下面（y + 18）一道 1 px 次色细线（40 %）。p：左端基线。"""
	var s := 令.s
	图标(c, 图名, p + Vector2(14*s, -10*s), 28.0, Color(令.色["主"], a))
	字距(c, p + Vector2(42*s, 0), t, 令.号["正"], Color(令.色["主"], 0.8*a), "粗", 4)
	c.draw_line(p + Vector2(0, 18*s), p + Vector2(w, 18*s), Color(令.色["次"], 0.4*a), maxf(1.0, s))


static func 行标(c: CanvasItem, p: Vector2, t: String, 选中: bool, 禁 := false, a := 1.0, 画竖 := true) -> void:
	"""设置项名（28 px）：焦点行 = 中 + 全亮、左边 28 px 处一道 4 px 活亮竖线；其余 = 正 + 90 %。画竖 = false 时竖线交给 滑竖（竖线从旧行滑到新行）。"""
	var s := 令.s; var col: Color = Color(令.色["主"], 1.0 if 选中 else 0.9)
	if 禁: col = Color(令.色["主"], 令.透["禁"])
	col.a *= a
	if 选中 and 画竖: 线(c, p + Vector2(-28*s, -30*s), p + Vector2(-28*s, 12*s), Color(令.色["活亮"], a), 4.0, false)
	字串(c, p, t, 令.号["大读"], col, "中" if 选中 else "正")
	if 禁: c.draw_line(p + Vector2(0, -9*s), p + Vector2(宽度(t, 令.号["大读"], "正"), -9*s), Color(col, col.a), maxf(1.0, 2.0*s))     # 禁用：划线（不只靠变暗）


static func 选项(c: CanvasItem, p: Vector2, 表: Array, 当前: int, a := 1.0, 禁: Array = [], size := 26.0, 悬 := -1, 按 := -1, 键 := "") -> Array:
	"""内联选项（全部摆在一行，间隔 44）：当前 = 主（最亮）+ 粗体 + 3 px 活亮下划线（y + 12），其余 = 次（颜色区分，不透明度 1），禁用项 = 次 × 0.5 + 划线。
	界面 5：下划线从旧选项滑到新选项（键 非空时，0.12 s）；悬 = 鼠标指着的选项（变主色 + 细下划线，0.08 s）；按 = 正按着的选项（缩到 0.97）。
	命中框相邻、无死缝，高 ≥ 44（1440p），用 件.命中 判定。p：第一项左端基线。返回每项的命中矩形（屏幕像素）。"""
	var s := 令.s; var x := p.x; var 框: Array = []; var xs: Array = []; var ws: Array = []
	for i in 表.size():
		var w := 宽度(表[i], size, "粗" if i == 当前 else "正")
		xs.append(x); ws.append(w); x += w + 44*s
	for i in 表.size():
		var t: String = 表[i]; var cur := i == 当前; var 禁用 := i in 禁
		var h := 悬度("%s|h%d" % [键, i], i == 悬 and not 禁用 and not cur) if 键 != "" else (1.0 if i == 悬 and not cur and not 禁用 else 0.0)
		var col: Color = 令.色["次"].lerp(令.色["主"], h)
		if cur: col = 令.色["主"]
		if 禁用: col = Color(令.色["次"], 令.透["禁"])
		col.a *= a
		var kk := 令.点击["按缩"] if i == 按 and not 禁用 else 1.0
		var 心 := Vector2(xs[i] + ws[i]*0.5, p.y - size*0.3*s)
		if kk < 1.0: c.draw_set_transform_matrix(Transform2D(0.0, Vector2(kk, kk), 0.0, 心*(1.0 - kk)))
		字串(c, Vector2(xs[i], p.y), t, size, col, "粗" if cur else "正")
		if 禁用: c.draw_line(Vector2(xs[i], p.y - size*0.32*s), Vector2(xs[i] + ws[i], p.y - size*0.32*s), col, maxf(1.0, 2.0*s))
		if h > 0.01 and not cur: c.draw_line(Vector2(xs[i], p.y + 12*s), Vector2(xs[i] + ws[i], p.y + 12*s), Color(令.色["主"], 0.55*h*a), maxf(1.0, 2.0*s))
		if kk < 1.0: c.draw_set_transform_matrix(Transform2D.IDENTITY)
		框.append(Rect2(xs[i] - 22*s, p.y - (size + 12)*s, ws[i] + 44*s, 52*s))
	if 当前 >= 0 and 当前 < 表.size() and 当前 not in 禁:
		var ux: float = xs[当前]; var uw: float = ws[当前]
		if 键 != "": ux = 趋(键 + "|ux", ux, 令.时["滑"]); uw = 趋(键 + "|uw", uw, 令.时["滑"])
		线(c, Vector2(ux, p.y + 12*s), Vector2(ux + uw, p.y + 12*s), Color(令.色["活亮"], a), 3.0, false)
	return 框


static func 滑条(c: CanvasItem, r: Rect2, v: float, 选中: bool, a := 1.0, 悬 := false, 拖 := false, 值字 := "", 键 := "") -> void:
	"""样张滑条：轨道在 r 的垂直中线（次 × 50 %，2 px）+ 已填（活亮，3 px）+ 竖线拇指（±12，3 px）；v 0–1。数值另画（等宽 22 px，x1 + 24）。
	界面 5：悬 = 鼠标在上面（拇指加高、轨道变亮）；拖 = 正在拖（拇指上方显示 值字）；键 非空时拇指位置 0.08 s 趋近（点轨道时是「滑」过去，不是跳）。"""
	var s := 令.s; var y := r.position.y + r.size.y*0.5
	var vv := clampf(v, 0.0, 1.0)
	if 键 != "": vv = 趋(键 + "|v", vv, 令.时["悬"]*(0.5 if 拖 else 1.0))
	var h := 悬度(键 + "|h", 悬 or 拖) if 键 != "" else (1.0 if 悬 or 拖 else 0.0)
	var x1 := r.position.x + r.size.x*vv
	线(c, Vector2(r.position.x, y), Vector2(r.end.x, y), Color(令.色["次"], (0.5 + 0.3*h)*a), 2.0, false)
	线(c, Vector2(r.position.x, y), Vector2(x1, y), Color(令.色["活亮"], a), 3.0 + h, false)
	var th := 12.0 + 4.0*h
	线(c, Vector2(x1, y - th*s), Vector2(x1, y + th*s), Color(令.色["活亮"], a), 3.0 + h, false)
	if 拖 and 值字 != "":
		字串(c, Vector2(x1, y - (th + 12)*s), 值字, 22.0, Color(令.色["主"], a), "等中", HORIZONTAL_ALIGNMENT_CENTER)


static func 引线(c: CanvasItem, 锚: Vector2, 折: Vector2, 字左: Vector2, col: Color, 出 := 1.0) -> void:
	"""样张标注引线：锚（车上的点）→ 折点 → 水平线到 字左（字的左端），锚上一个 6 px 的点。"""
	var s := 令.s
	渐线(c, PackedVector2Array([锚, 折, Vector2(字左.x, 折.y)]), 出, col, 2.5)
	if 出 >= 0.99: 点(c, 锚, 6*s/s, col)


static func 左渐变(c: CanvasItem, vs: Vector2, 底: Color, a := 1.0, 止 := 0.62, 深 := 0.84, n := 48) -> void:
	"""样张「渐暗」：整屏左侧渐变（不是底板）：t = clamp((止 − x/W)/止)^1.4 × 深，颜色 = 页底。n 段一次画完。"""
	for i in n:
		var u0 := 止*float(i)/n; var u1 := 止*float(i + 1)/n
		var t0 := pow(clampf((止 - u0)/止, 0.0, 1.0), 1.4)*深*a; var t1 := pow(clampf((止 - u1)/止, 0.0, 1.0), 1.4)*深*a
		c.draw_polygon(PackedVector2Array([Vector2(vs.x*u0, 0), Vector2(vs.x*u1, 0), Vector2(vs.x*u1, vs.y), Vector2(vs.x*u0, vs.y)]),
			PackedColorArray([Color(底, t0), Color(底, t1), Color(底, t1), Color(底, t0)]))


static func 上下渐变(c: CanvasItem, vs: Vector2, 底: Color, a := 1.0, 上深 := 0.5, 上止 := 0.32, 下深 := 0.8, 下止 := 0.78, n := 40) -> void:
	"""整屏上下渐暗（整屏页用，不是底板）：顶上 上深 → 0（到 上止·H），底下 下深 → 0（到 1 − 下止·H）。界面 5：压住亮地面，正文对背景 ≥ 7:1。"""
	for i in n:
		var u0 := float(i)/n; var u1 := float(i + 1)/n
		var 上0 := pow(clampf(1.0 - u0/上止, 0.0, 1.0), 1.3)*上深*a; var 上1 := pow(clampf(1.0 - u1/上止, 0.0, 1.0), 1.3)*上深*a
		if 上0 > 0.002 or 上1 > 0.002:
			c.draw_polygon(PackedVector2Array([Vector2(0, vs.y*u0*上止), Vector2(vs.x, vs.y*u0*上止), Vector2(vs.x, vs.y*u1*上止), Vector2(0, vs.y*u1*上止)]),
				PackedColorArray([Color(底, 上0), Color(底, 上0), Color(底, 上1), Color(底, 上1)]))
		var y0 := vs.y*(1.0 - 下止*(1.0 - u0)); var y1 := vs.y*(1.0 - 下止*(1.0 - u1))        # 下：u 从 0（渐变的顶）到 1（屏底）
		var d0 := pow(u0, 1.3)*下深*a; var d1 := pow(u1, 1.3)*下深*a
		c.draw_polygon(PackedVector2Array([Vector2(0, y0), Vector2(vs.x, y0), Vector2(vs.x, y1), Vector2(0, y1)]), PackedColorArray([Color(底, d0), Color(底, d0), Color(底, d1), Color(底, d1)]))


# ———————————————————— 出现 / 消失的进度（每个元素一条记录）
static func 进(表: Dictionary, 键: Variant, 要显: bool, dt: float, 出时 := -1.0, 退时 := -1.0) -> float:
	"""推一个元素的出现进度（0–1）并返回：要显时按 出时（默认 令.时.慢）涨到 1，不显时按 退时（默认 令.时.中）退到 0。"""
	if 出时 < 0.0: 出时 = 令.时["慢"]
	if 退时 < 0.0: 退时 = 令.时["中"]
	出时 *= 令.动倍; 退时 *= 令.动倍                                     # 动倍 = 0：直接到终态
	var v: float = 表.get(键, 0.0)
	if 出时 <= 0.0 or 退时 <= 0.0:
		v = 1.0 if 要显 else 0.0
		if v <= 0.0: 表.erase(键)
		else: 表[键] = v
		return v
	v = minf(1.0, v + dt/出时) if 要显 else maxf(0.0, v - dt/退时)
	if v <= 0.0 and not 要显: 表.erase(键)
	else: 表[键] = v
	return v


# ———————————————————— 界面 5：字数统计（自测用：记字 = true 时 字串 把画出的每一串记进 字记）
static var 记字 := false
static var 字记: Array = []
static var 字框记: Array = []                                      # 界面 6：每串字的 [文, 屏幕矩形（字芯，不含描边）, 颜色, 字号]，对比度自测用
const 字白 := ["SOL", "AutoNav", "MMRTG", "FSR", "TAA", "SSAO", "AA", "D", "NASA", "JPL", "HiRISE", "CTX", "MOLA", "Enter", "Esc", "FPS", "GPU", "ms", "m", "km", "ft", "mi", "s", "F", "C", "H", "M", "Shift", "English", "LTST", "UTC", "ASU", "MSSS", "UArizona", "USGS", "Caltech", "Inter", "Godot", "HUD", "HRSC", "ESA", "DLR"]   # 专有名词、单位、键名：不算「字」，也不算英文标签


static func 字数(t: String) -> int:
	"""规范 §1.4 的「字」：汉字每个 1，英文单词（不在 字白 里的）每个 1；数字、符号、单位不算。"""
	var n := 0
	for ch in t:
		var u := ch.unicode_at(0)
		if u >= 0x4E00 and u <= 0x9FFF: n += 1
	var re := RegEx.create_from_string("[A-Za-z]+")
	for m in re.search_all(t):
		if m.get_string() not in 字白: n += 1
	return n


static func 英文标签(t: String) -> Array:
	"""t 里不在白名单里的英文单词（自测：界面不该画英文标签）。英文界面里英文是正文，不查（改查 令.译缺）。"""
	var out: Array = []
	if 令.英(): return out
	for m in RegEx.create_from_string("[A-Za-z]+").search_all(t):
		if m.get_string() not in 字白: out.append(m.get_string())
	return out


# ———————————————————— 界面 5：动画底层、命中、悬停提示、告警（规范 §3 §4）
#   所有动画都是「指数趋近」：每个元素一个键，值每次画时向目标靠一步；「界面动效」= 减半 → 时间 × 0.5，关 → 直接到目标。
static var _动: Dictionary = {}                                    # 键 → [当前值, 上次时刻 us]
static var _提键 := ""                                             # 悬停提示：当前指着的东西（空 = 没有）
static var _提t := 0.0


static func 趋(键: Variant, 目标: float, 时 := 0.12) -> float:
	"""值向 目标 靠近，「到位」≈ 时 秒（ease-out 的感觉）。第一次出现或 0.5 s 没被问过 → 直接是目标（页面刚打开不从零滑）。"""
	var now := Time.get_ticks_usec(); var e: Variant = _动.get(键)
	if e == null or (now - int(e[1])) > 500000 or 令.动倍 <= 0.0 or 时 <= 0.0:
		_动[键] = [目标, now]; return 目标
	var dt := clampf(float(now - int(e[1]))/1e6, 0.0, 0.1)
	var v: float = e[0]
	v = lerpf(v, 目标, 1.0 - exp(-dt/maxf(时*0.33*令.动倍, 1e-4)))
	if absf(v - 目标) < 1e-3*maxf(1.0, absf(目标)): v = 目标
	_动[键] = [v, now]
	return v


static func 悬度(键: Variant, 悬: bool) -> float:
	"""悬停高亮 0–1（0.08 s）。"""
	return 趋(键, 1.0 if 悬 else 0.0, 令.时["悬"])


static func 滑竖(c: CanvasItem, 键: String, 上: Vector2, 下: Vector2, col: Color, w := 4.0) -> void:
	"""列表选中行左侧的竖线：从旧行滑到新行（0.12 s）。上 / 下 = 竖线两端（屏幕像素）。"""
	var y0 := 趋(键 + "|y0", 上.y, 令.时["滑"]); var y1 := 趋(键 + "|y1", 下.y, 令.时["滑"])
	线(c, Vector2(上.x, y0), Vector2(下.x, y1), col, w, false)


static func 命中(框: Array, 点: Vector2) -> int:
	"""哪一个矩形被点中：每个矩形外扩 容差（8 px）；几个都含时取中心最近的；没有 → −1。相邻矩形之间不留死缝。"""
	var 最 := -1; var bd := INF; var g: float = 令.点击["容差"]*令.s
	for i in 框.size():
		var r: Rect2 = 框[i]
		if r.size.x <= 0.0 or not r.grow(g).has_point(点): continue
		var d := (r.get_center() - 点).length_squared()
		if r.has_point(点): d *= 0.25                                           # 真正在框里的优先于只在容差里的
		if d < bd: bd = d; 最 = i
	return 最


static func 提示更(键: String, dt: float) -> void:
	"""悬停提示的计时：键 = 鼠标现在指着的东西（空串 = 没指着）；换了键就重新计 0.35 s。"""
	if 键 != _提键: _提键 = 键; _提t = 0.0
	elif 键 != "": _提t += dt


static func 提示可见() -> bool:
	return _提键 != "" and _提t >= 令.时["提示延"]


static func 提示画(c: CanvasItem, 文: String, 位: Vector2, vs: Vector2) -> void:
	"""悬停 0.35 s 后在鼠标旁淡入 0.1 s；移开立即消失（提示更 换键即重置）。整屏页用，带一块小面板。"""
	if 文 == "" or not 提示可见(): return
	var s := 令.s; var a := 1.0
	if 令.动倍 > 0.0: a = clampf((_提t - 令.时["提示延"])/maxf(令.时["提示淡"]*令.动倍, 1e-3), 0.0, 1.0)
	var W := 520.0*s; var px := 20.0
	var h := 段高(文, px, W, "正") + 24*s
	var r := Rect2(位 + Vector2(18, 26)*s, Vector2(W + 28*s, h))
	r.position.x = clampf(r.position.x, 8*s, vs.x - r.size.x - 8*s)
	if r.end.y > vs.y - 8*s: r.position.y = 位.y - 18*s - h
	面板(c, r, a)
	c.draw_rect(r, Color(令.色["次"], 0.35*a), false, maxf(1.0, s))
	段落(c, r.position + Vector2(14*s, 6*s), 文, px, Color(令.色["主"], a), W, "正")


static func 告警(c: CanvasItem, 心: Vector2, 红: bool, 亮 := true, 弹 := 1.0, size := 24.0) -> float:
	"""告警（规范 §1.5）：图标 + 中文「注意」/「警告」；图标弹出（弹 0–1，0.2 s）；红色警告 1 Hz 慢闪由调用方给 亮。返回占的宽度（屏幕像素）。
	心 = 图标中心；字在图标右边。"""
	var s := 令.s; var col: Color = 令.色["警告"] if 红 else 令.色["注意"]
	col.a *= 1.0 if 亮 else 0.35
	var k := 令.缓(clampf(弹, 0.0, 1.0), "弹") if 弹 < 1.0 else 1.0
	图标(c, "倾角_警告" if 红 else "倾角_注意", 心, 40.0*maxf(k, 0.2), col)
	var t := "警告" if 红 else "注意"
	字串(c, 心 + Vector2(30*s, size*0.36*s), t, size, col, "粗")
	return 30*s + 宽度(t, size, "粗")


# ———————————————————— 界面 6：页底的「键帽 + 图标」按钮行（代替「键 + 一句话」）
static func 键图行(c: CanvasItem, 心: Vector2, 表: Array, 悬 := -1, 按 := -1, a := 1.0, 左 := false) -> Array:
	"""表 [[键, 图名（空 = 只有键帽）, 提示], …]；心 = 一行的中点基线（左 = true 时是左端）。每项可点：悬停变亮 0.08 s，按下缩 0.97；
	返回每项命中矩形（高 ≥ 44 px，相邻）。提示文字由调用方在 悬 == i 时用 提示更 / 提示画 画。"""
	var s := 令.s; var 主: Color = 令.色["主"]; var ws: Array = []; var tot := 0.0
	for h: Array in 表:
		var 键w := maxf(40*s, 宽度(h[0], 24) + 22*s); var w := 键w + (46*s if String(h[1]) != "" else 0.0); ws.append(w); tot += w + 36*s
	tot -= 36*s
	var x := 心.x if 左 else 心.x - tot*0.5; var out: Array = []
	for i in 表.size():
		var h: Array = 表[i]; var hv := 悬度("键图|%s" % h[0], i == 悬)
		var col := Color(主.lerp(Color.WHITE, 0.0), (0.85 + 0.15*hv)*a)
		var 缩 := 令.点击["按缩"] if i == 按 else 1.0
		var 中 := Vector2(x + ws[i]*0.5, 心.y - 10*s)
		if hv > 0.01: c.draw_rect(Rect2(x - 8*s, 心.y - 44*s, ws[i] + 16*s, 56*s), Color(主, 0.12*hv*a))
		var kw := 键帽(c, Vector2(x + ws[i]*0.5*(1.0 - 缩), 心.y), h[0], col, 24.0*缩)
		if String(h[1]) != "": 图标(c, String(h[1]), Vector2(x + kw + 28*s, 心.y - 10*s), 32.0*缩, col)
		out.append(Rect2(x - 18*s, 心.y - 44*s, ws[i] + 36*s, 56*s)); x += ws[i] + 36*s
	return out


# ———————————————————— 界面 6：对比度量法（规范 §5）
static func 亮度(c: Color) -> float:
	var f := func(v: float) -> float: return v/12.92 if v <= 0.03928 else pow((v + 0.055)/1.055, 2.4)
	return 0.2126*f.call(c.r) + 0.7152*f.call(c.g) + 0.0722*f.call(c.b)


static func 对比Y(a: float, b: float) -> float:
	return (maxf(a, b) + 0.05)/(minf(a, b) + 0.05)


static var _膜缓: Dictionary = {}


static func 字膜(文: String, size: float, fk: String) -> Image:
	"""自测（协程，要 await）：把这串字单独画进透明的 SubViewport，得到字的笔画 alpha（左端 = 像素 (8, 8 + 上伸)，基线在 y = 8 + 上伸）。"""
	var 键 := "%s|%.0f|%s" % [文, size, fk]
	if _膜缓.has(键): return _膜缓[键]
	var f: Font = 令.字[fk]; var px := 字号(size); var pad := 8
	var asc := int(ceil(f.get_ascent(px)))
	var vp := SubViewport.new(); vp.size = Vector2i(int(ceil(f.get_string_size(文, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x)) + 2*pad, asc + int(ceil(f.get_descent(px))) + 2*pad)
	vp.transparent_bg = true; vp.disable_3d = true; vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	var c := Control.new(); vp.add_child(c)
	c.draw.connect(func(): c.draw_string(f, Vector2(pad, pad + asc), 文, HORIZONTAL_ALIGNMENT_LEFT, -1, px, Color.WHITE))
	var 根: Node = Engine.get_main_loop().root; 根.add_child(vp)
	await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	var 图 := vp.get_texture().get_image(); vp.queue_free()
	_膜缓[键] = 图
	return 图


static func 膜原点(q: Array) -> Vector2i:
	"""字框记里的一条 → 它的 字膜 在屏幕上的左上角（像素）。"""
	var f: Font = 令.字[q[5]]; var px := 字号(q[3])
	return Vector2i(roundi((q[4] as Vector2).x) - 8, roundi((q[4] as Vector2).y) - 8 - int(ceil(f.get_ascent(px))))


static func 描边测(图: Image, 膜: Image, 原点: Vector2i, 前: Color, 旧矩形: Rect2) -> Dictionary:
	"""压在 3D 画面上的字 / 图标的量法（规范 §5）：膜 = 笔画的 alpha 图（字膜 / 图标贴图），原点 = 它的左上角在截图上的像素，前 = 字色。
	字芯 = 膜 alpha > 0.04 的像素（含抗锯齿的边）；带 = 离字芯 1–3 px 的一圈；对比 = 前景亮度对带的 p95 亮度（WCAG）；
	宽 = 描边宽（从字芯边缘向外，连续「深色」像素的个数，各边缘点取四向最大，取中位数）；
	旧 = 旧量法（旧矩形外 3–14 px 一圈背景的 p95 亮度），只作对照。截图和界面 1:1（2560×1440、缩放 1）时才准。"""
	var 暗: Color = 令.色["暗"]; var Lo := 亮度(暗)
	var 有效 := Color(前.r*前.a + 暗.r*(1.0 - 前.a), 前.g*前.a + 暗.g*(1.0 - 前.a), 前.b*前.a + 暗.b*(1.0 - 前.a))
	var Lf := 亮度(有效)
	var g := 16; var w := 图.get_width(); var h := 图.get_height()
	var x0 := maxi(0, 原点.x - g); var y0 := maxi(0, 原点.y - g); var x1 := mini(w, 原点.x + 膜.get_width() + g); var y1 := mini(h, 原点.y + 膜.get_height() + g)
	var W := x1 - x0; var H := y1 - y0
	if W <= 4 or H <= 4: return {}
	var L := PackedFloat32Array(); L.resize(W*H)
	for y in H:
		for x in W: L[y*W + x] = 亮度(图.get_pixel(x0 + x, y0 + y))
	var D := PackedByteArray(); D.resize(W*H); D.fill(99)
	var 芯 := 0
	for my in 膜.get_height():
		for mx in 膜.get_width():
			if 膜.get_pixel(mx, my).a <= 0.04: continue
			var x := 原点.x + mx - x0; var y := 原点.y + my - y0
			if x >= 0 and x < W and y >= 0 and y < H: D[y*W + x] = 0; 芯 += 1
	if 芯 < 6: return {}
	for k in range(1, 4):
		var 新: Array = []
		for y in range(1, H - 1):
			for x in range(1, W - 1):
				if D[y*W + x] != 99: continue
				var 近 := false
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						if D[(y + dy)*W + x + dx] == k - 1: 近 = true
				if 近: 新.append(y*W + x)
		for i: int in 新: D[i] = k
	var 带: Array = []
	for i in W*H:
		if D[i] >= 1 and D[i] <= 3: 带.append(L[i])
	带.sort(); var 带95: float = 带[int(带.size()*0.95)] if not 带.is_empty() else 1.0
	var 外: Array = []                                                 # 旧量法
	for y in H:
		for x in W:
			var p := Vector2(x0 + x, y0 + y)
			if 旧矩形.grow(14.0).has_point(p) and not 旧矩形.grow(3.0).has_point(p): 外.append(L[y*W + x])
	外.sort(); var 旧95: float = 外[int(外.size()*0.95)] if not 外.is_empty() else 1.0
	var 宽s: Array = []; var 暗阈 := Lo + 0.12*absf(Lf - Lo) + 0.02
	for y in range(2, H - 2):
		for x in range(2, W - 2):
			if D[y*W + x] != 0: continue
			var 边 := false
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				if D[(y + d.y)*W + x + d.x] != 0: 边 = true
			if not 边: continue
			var 最 := 0
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var 走 := 0; var xx := x + d.x; var yy := y + d.y
				while 走 < 10 and xx >= 0 and xx < W and yy >= 0 and yy < H and D[yy*W + xx] != 0 and L[yy*W + xx] < 暗阈:
					走 += 1; xx += d.x; yy += d.y
				最 = maxi(最, 走)
			宽s.append(最)
	宽s.sort(); var 宽: float = float(宽s[宽s.size()/2]) if not 宽s.is_empty() else 0.0
	return {"对比": 对比Y(Lf, 带95), "旧": 对比Y(亮度(前), 旧95), "宽": 宽, "带95": 带95}
