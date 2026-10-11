# 启动载入画面（主菜单 a 的第一段；docs/界面/主菜单样张/说明.md「载入」，docs/界面/UI体系.md §4）：
#   黑底 + 左上图标位和片名块 + 屏幕中下一圈 2D 细环当进度（顺时针画满）+ 一行「正在载入 · 地形」。
#   场景是 实景.gd _ready 里同步搭的（约 5 s，中间没有空帧），_draw 要等消息队列、这时候不会被调，
#   所以直接往 RenderingServer 的画布项里画；实景.gd 每搭完一步调 环境.进度() → 这里 进度() → RenderingServer.force_draw() 画一帧。
#   不改成线程加载：载入时间不变（只多几次 2D 画帧）。3D 搭好以后主菜单（界面/主菜单.gd）接手：环「落地」成地面罗盘环。
#   由令牌（界面/令牌.gd）在 令.要菜单() 时建，挂在根上（autoload 之后、主场景之前）。
extends CanvasLayer

const 环心 := Vector2(0.5, 0.64)                  # 屏幕比例：和主菜单首帧地面罗盘环投影的中心大致对上（主菜单再把它变形过去）
const 环半 := 0.20                                 # × 屏宽

var ci: RID
var 比 := 0.0                                      # 0–1
var 步名 := "引擎"
var 起 := 0
var 记: Array = []                                 # [[步, 到这一步的 ms], …]
var 图标: Texture2D = null


func _ready() -> void:
	if not 令.要菜单() or not 环境.数据问题.is_empty(): queue_free(); return                          # 不走主菜单（自测、测帧、渲染……）：什么都不做
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	ci = RenderingServer.canvas_item_create()
	RenderingServer.canvas_item_set_parent(ci, get_canvas())
	图标 = 令.图标贴图(); 令.载入层 = self
	起 = Time.get_ticks_msec()
	画()


func _exit_tree() -> void:
	令.载入记 = 记.duplicate()
	if ci.is_valid(): RenderingServer.free_rid(ci)


func 进度(名: String, x: float) -> void:
	"""实景.gd（经 环境.进度）每搭完一步调一次：记时间、画一帧。"""
	记.append([名, Time.get_ticks_msec() - 起]); 比 = clampf(x, 比, 1.0); 步名 = 名
	画()
	if DisplayServer.get_name() != "headless": RenderingServer.force_draw()
	var 录: String = 令.菜单录()
	if 录 != "":
		DirAccess.make_dir_recursive_absolute(录)
		get_viewport().get_texture().get_image().save_png("%s/载入_%02d.png" % [录, 记.size()])


func 画(底a := 1.0, 环a := 1.0) -> void:
	"""底a / 环a：主菜单接手前后淡出用。"""
	RenderingServer.canvas_item_clear(ci)
	var vs := get_viewport().get_visible_rect().size
	var s := vs.y/1440.0
	var 主: Color = 令.色["主"]
	RenderingServer.canvas_item_add_rect(ci, Rect2(Vector2.ZERO, vs), Color(0, 0, 0, 底a))
	标题块(ci, Vector2(120, 100)*s, s, 底a)
	# 进度环：一圈淡的底环 + 顺时针画满的亮弧（从正上方开始）
	var o := Vector2(vs.x*环心.x, vs.y*环心.y); var r := vs.x*环半
	var 底环 := PackedVector2Array(); var 亮 := PackedVector2Array()
	for i in 129:
		var a := -PI*0.5 + TAU*i/128.0; 底环.append(o + Vector2(cos(a), sin(a))*r)
	var n := maxi(2, int(128*比) + 1)
	for i in n:
		var a := -PI*0.5 + TAU*比*i/float(n - 1); 亮.append(o + Vector2(cos(a), sin(a))*r)
	RenderingServer.canvas_item_add_polyline(ci, 底环, PackedColorArray([Color(主, 0.18*环a)]), maxf(1.0, 1.5*s), true)
	if 比 > 0.002: RenderingServer.canvas_item_add_polyline(ci, 亮, PackedColorArray([Color(主, 0.95*环a)]), maxf(1.5, 2.0*s), true)
	var f: Font = 令.字["中"]
	var t := "%s · %s　%d %%" % [令.译("正在载入"), 令.译(步名), roundi(比*100.0)]
	f.draw_string(ci, Vector2(o.x - 400*s, o.y + r + 46*s), t, HORIZONTAL_ALIGNMENT_CENTER, 800*s, int(18*s), Color(令.色["次"], 0.9*环a))


static func 标题块(item: RID, p: Vector2, s: float, a := 1.0, 图: Texture2D = null) -> void:
	"""左上图标位 + 片名块（载入画面和主菜单共用同一个位置；片名只在 令.片名 / 令.片名中 改）。"""
	var 主: Color = 令.色["主"]
	if 图 == null: 图 = 令.图标贴图()
	var 边 := 128.0*s
	if 图: 图.draw_rect(item, Rect2(p, Vector2(边, 边)), false, Color(1, 1, 1, a))
	else:                                                              # 图标位占位：虚线框打叉
		var r := Rect2(p, Vector2(边, 边))
		for k in [[r.position, r.position + Vector2(边, 0)], [r.position + Vector2(边, 0), r.end], [r.end, r.position + Vector2(0, 边)], [r.position + Vector2(0, 边), r.position], [r.position, r.end], [r.position + Vector2(边, 0), r.position + Vector2(0, 边)]]:
			RenderingServer.canvas_item_add_line(item, k[0], k[1], Color(主, 0.4*a), maxf(1.0, s))
	var x := p.x + 边 + 36*s
	(令.字["正"] as Font).draw_string(item, Vector2(x, p.y + 70*s), 令.译(令.片名), HORIZONTAL_ALIGNMENT_LEFT, -1, int(64*s), Color(主, a))
	(令.字["中"] as Font).draw_string(item, Vector2(x + 2*s, p.y + 112*s), 令.片名中, HORIZONTAL_ALIGNMENT_LEFT, -1, int(26*s), Color(令.色["次"], a))
