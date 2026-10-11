# 玩法模块的风格（玩法 A 导览卡、拍照、图鉴、复刻、暂停菜单；玩法 B 规划图、下行卡、报告卡）：
#   界面体系（docs/界面/UI体系.md）在玩法模块里的入口。颜色、字号、线宽从令牌（autoload「令」，界面/令牌.gd）取，
#   画法都转给组件库（界面/件.gd）；这里只留玩法 B 自己的「数据色」（驾驶方式、预演、可通行性层这些图上的编码色）和兼容的旧名字。
#   面板（菜单、图鉴）是「要读一段字」的地方，可以有底；全屏页（规划图、下行卡、报告卡）可以有整屏的底。HUD 和导览卡不加底板。
extends RefCounted

const 件 := preload("res://界面/件.gd")

# 角色色（换色板时 取色() 重取；旧名字：白 = 主、灰 / 淡 = 主色降不透明度、暗色 = 暗、底 = 面板底、页底 = 整屏页底）
var 白 := Color.WHITE
var 灰 := Color(1, 1, 1, 0.82)
var 淡 := Color(1, 1, 1, 0.62)
var 活 := Color.WHITE
var 琥珀 := Color(1.0, 0.690, 0.0)
var 红 := Color(1.0, 0.294, 0.227)
var 暗色 := Color(0.078, 0.055, 0.039)
var 底 := Color(0.03, 0.025, 0.02, 0.86)
var 页底 := Color(0.03, 0.025, 0.02, 0.96)

# 玩法 B 的数据色（图上的编码，不随色板换）：规划图、sol 时间线、下行卡、报告卡、路径带、影子车。
#   HUD 上的 B 元素（小地图路径、地面航线箭头）在 界面.gd，用令牌的「活」色。
const 方式色 := [Color(0.97, 0.95, 0.91), Color(0.97, 0.95, 0.91), Color(1.0, 0.72, 0.22)]   # 盲开（虚线）、视觉里程计、AutoNav
const 预演色 := Color(0.75, 0.90, 1.0, 0.90)      # 预演轨迹、影子车图标
const 影子色 := Color(0.78, 0.88, 1.0, 0.30)      # 3D 影子车（半透明、不受光）
const 带透明 := 0.55                               # 3D 路径带的不透明度
const 带宽 := 0.16                                 # 3D 路径带宽（m）
const 险中 := Color(1.0, 0.72, 0.22)              # 可通行性层：风险中（琥珀）→ 高（红）；不可通行深红
const 险高 := Color(0.93, 0.25, 0.20)
const 险堵 := Color(0.62, 0.05, 0.04, 0.78)
const 险透明 := 0.55
const 夜色 := Color(0.0, 0.0, 0.02, 0.6)          # sol 时间线：夜、日照
const 日照色 := Color(0.55, 0.42, 0.30, 0.55)
const 宽 := {"航段": 3.0, "选中": 5.0, "细": 1.5, "框": 2.5, "粗": 3.0}           # 线宽（1440p 像素，乘 s；令.宽 的别名 + 航段）
const 号 := {"大题": 42, "题": 32, "中题": 28, "正": 22, "次": 20, "小": 18, "注": 16}   # 字号（令.号 的子集）

var 字: Dictionary = 令.字
var s: float:                                      # 以 1440 高为 1（就是 令.s）
	get: return 令.s


func _init() -> void:
	取色()
	令.变了.connect(取色)


func 取色() -> void:
	var C: Dictionary = 令.色
	白 = C["主"]; 灰 = Color(C["主"], 令.透["灰"]); 淡 = Color(C["主"], 令.透["三"]); 活 = C["活"]
	琥珀 = C["注意"]; 红 = C["警告"]; 暗色 = C["暗"]; 底 = C["底"]; 页底 = C["页底"]


static func 丙(P: Node) -> bool:
	"""界面是不是 v3 以后（--界面=旧 时是 v2）。"""
	var 界: Node = P.get_node_or_null("界面") if P else null
	return 界 != null and int(界.get("版")) >= 3


func 量尺(_vp: Viewport) -> void:
	pass                                           # 尺度由令牌统一算（令.量尺）


# ———————————————————— 转给组件库（界面/件.gd）
func 图标(c: CanvasItem, 名: String, 心: Vector2, px: float, col := Color(-1, 0, 0)) -> void:
	件.图标(c, 名, 心, px, col)


func 字串(c: CanvasItem, p: Vector2, t: String, size: float, col: Color, fk := "正", 对齐 := HORIZONTAL_ALIGNMENT_LEFT, 宽_ := -1.0) -> void:
	件.字串(c, p, t, size, col, fk, 对齐, 宽_)


func 段落描边(c: CanvasItem, p: Vector2, t: String, size: float, col: Color, 宽_: float, fk := "正", 行距 := 1.45) -> float:
	return 件.段落描边(c, p, t, size, col, 宽_, fk, 行距)


func 段落(c: CanvasItem, p: Vector2, t: String, size: float, col: Color, 宽_: float, fk := "正", 行距 := 1.45) -> float:
	return 件.段落(c, p, t, size, col, 宽_, fk, 行距)


func 段高(t: String, size: float, 宽_: float, fk := "正", 行距 := 1.45) -> float:
	return 件.段高(t, size, 宽_, fk, 行距)


func 宽度(t: String, size: float, fk := "中") -> float:
	return 件.宽度(t, size, fk)


func 键提示(c: CanvasItem, 心: Vector2, 表: Array, size := 24.0) -> void:
	件.键提示(c, 心, 表, size, size - 2, 40)


func 题(c: CanvasItem, p: Vector2, 图名: String, t: String, size := 42.0) -> void:
	件.题(c, p, 图名, t, size)


func 节(c: CanvasItem, p: Vector2, w: float, t: String, 图名 := "") -> void:
	件.节(c, p, w, t, 图名, 号["中题"])


func 面板(c: CanvasItem, r: Rect2, a := 1.0) -> void:
	件.面板(c, r, a)


func 线(c: CanvasItem, a: Vector2, b: Vector2, col: Color, w: float) -> void:
	"""w 是屏幕像素（老接口；件.线 的 w 按 1440p）。"""
	c.draw_line(a, b, Color(令.边(col), 0.62*col.a), w + 3.0*s, true)
	c.draw_line(a, b, col, w, true)


func 主题() -> Theme:
	"""菜单按钮（暂停菜单、图鉴）：常态透明，悬停 / 焦点时淡底 + 左侧一道活色竖条。"""
	var th := Theme.new(); th.default_font = 字["正"]; th.default_font_size = int(26*s)
	var n := StyleBoxEmpty.new(); n.content_margin_left = 28*s; n.content_margin_right = 28*s; n.content_margin_top = 10*s; n.content_margin_bottom = 10*s
	var h := StyleBoxFlat.new(); h.bg_color = Color(白, 令.透["面"]); h.border_color = 活 if 令.有活边 else 白; h.border_width_left = int(maxf(2.0, 4*s))
	h.content_margin_left = 28*s; h.content_margin_right = 28*s; h.content_margin_top = 10*s; h.content_margin_bottom = 10*s
	for k in ["normal", "disabled"]: th.set_stylebox(k, "Button", n)
	for k in ["hover", "pressed", "focus", "hover_pressed"]: th.set_stylebox(k, "Button", h)
	th.set_color("font_color", "Button", 灰); th.set_color("font_hover_color", "Button", 白); th.set_color("font_focus_color", "Button", 白)
	th.set_color("font_pressed_color", "Button", 白); th.set_color("font_disabled_color", "Button", Color(淡, 0.5))
	th.set_constant("outline_size", "Button", 0)
	return th


func 图(path: String) -> ImageTexture:
	"""读一张磁盘上的图（不经 Godot 导入：数据目录的 兴趣点/ 有 .gdignore；相册在 user://）。"""
	var img := Image.load_from_file(path if not path.begins_with("user://") else ProjectSettings.globalize_path(path))
	return ImageTexture.create_from_image(img) if img else null
