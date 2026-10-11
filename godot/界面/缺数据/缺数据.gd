# 数据不可用时的提示页（环境.gd 的 数据问题 非空时由 环境._ready 建；docs/发布流程.md「数据包」）。
#   三种：缺（没找到 data/）、版本（数据包版本和程序要的不一样）、不全（文件缺 / 大小不对，多半少解压了一卷）。
#   风格跟载入画面 / 主菜单一致：黑底，左上图标 + 片名，字少，不加深色底板，没有任何 NASA 徽标。
#   字体用 PCK 里的子集（界面/缺数据/，因为 data/界面/素材 里的字体这时读不到）；路径是这台机器上的真实路径。
#   按任意键 / 点击 / 关窗退出（退出码 0）。带自动化参数（--首帧退出、--渲染、--玩法测试……）或无头时不等人：写完日志直接退出（退出码 3）。
#   --缺数据截图=<png>：画好后存一张图再退出（自测用）。
extends CanvasLayer

var 问题 := {}
var 版本 := ""
var 下载页 := ""
var c: Control
var 自动 := false
var 截图 := ""
var 帧 := 0


func _ready() -> void:
	layer = 200
	var 参 := " ".join(OS.get_cmdline_user_args())
	for a in OS.get_cmdline_user_args(): if a.begins_with("--缺数据截图="): 截图 = a.trim_prefix("--缺数据截图=")
	for k in ["--首帧退出", "--渲染", "--视频", "--玩法测试", "--测帧", "--界面测试", "--控制测试", "--菜单测试"]:
		if 参.contains(k): 自动 = true
	if 截图 != "": 自动 = true
	if DisplayServer.get_name() == "headless": get_tree().quit(3); return
	c = Control.new(); c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.draw.connect(_画); c.resized.connect(c.queue_redraw)
	add_child(c)
	get_tree().root.size_changed.connect(c.queue_redraw)


func _process(_dt: float) -> void:
	if not 自动: return
	帧 += 1
	if 帧 == 6:
		if 截图 != "":
			DirAccess.make_dir_recursive_absolute(截图.get_base_dir())
			get_viewport().get_texture().get_image().save_png(截图)
			print("[数据] 提示页截图 ", 截图)
		get_tree().quit(3)


func _input(e: InputEvent) -> void:
	if 自动: return
	if (e is InputEventKey and e.pressed and not e.echo) or (e is InputEventMouseButton and e.pressed):
		get_tree().quit(0)


func _画() -> void:
	var vs := c.size
	var s := clampf(vs.y/1440.0, 0.75, 3.0)
	var ci := c.get_canvas_item()
	var 主: Color = 令.色["主"]; var 次: Color = 令.色["次"]; var 强: Color = 令.色["注意"]
	var 字: Font = 令.字["正"]; var 粗: Font = 令.字["粗"]
	c.draw_rect(Rect2(Vector2.ZERO, vs), Color.BLACK)
	载入.标题块(ci, Vector2(120, 100)*s, s)
	var x := 120.0*s
	var w := vs.x - 2.0*x
	var y := 400.0*s
	var 题 := ""
	var 说 := ""
	var 种: String = 问题.get("种类", "缺")
	match 种:
		"缺":
			题 = "没有找到游戏数据"
			if 问题.get("来", "") != "": 说 = "%s 指到的目录里没有数据" % 问题["来"]
		"版本":
			题 = "数据版本不对"
			说 = "现有 %s　　需要 %s" % [问题.get("现有", "?"), 问题.get("需要", "?")]
		"不全":
			题 = "数据不完整"
			var 卷: Array = 问题.get("卷", [])
			说 = "缺 %d 个文件" % int(问题.get("缺", 0))
			if not 卷.is_empty(): 说 += "　　第 %s 卷没解压或没解完" % "、".join(PackedStringArray(卷.map(func(v): return str(v))))
	y = _行(ci, 粗, 题, Vector2(x, y), w, int(42.0*s), 主)
	y += 14.0*s
	if 说 != "": y = _行(ci, 字, 说, Vector2(x, y), w, int(24.0*s), 强) + 10.0*s
	y += 34.0*s
	var 包名 := "mars-realtime-drive-data-%s-*.zip" % (版本 if 版本 != "" else "?")
	var 下 := "下载全部数据包（几卷都要）" if 种 != "版本" else "下载新的数据包（几卷都要）"
	y = _步(ci, 字, 粗, "1", 下, 包名 + "\n" + 下载页, Vector2(x, y), w, s, 主, 次)
	var 解 := "都解压到这个文件夹" if 种 != "版本" else "都解压到这个文件夹，覆盖原来的 data"
	y = _步(ci, 字, 粗, "2", 解, str(问题.get("应放", "")), Vector2(x, y), w, s, 主, 主)
	var 末 := "重新打开游戏"
	if 问题.get("translocated", false): 末 = "先在终端运行 xattr -dr com.apple.quarantine 加 .app 的路径，再打开"
	y = _步(ci, 字, 粗, "3", 末, "", Vector2(x, y), w, s, 主, 次)
	if not 自动: _行(ci, 字, "按任意键退出", Vector2(x, vs.y - 110.0*s), w, int(20.0*s), 次)


func _步(ci: RID, 字: Font, 粗: Font, 号: String, 主句: String, 副: String, p: Vector2, w: float, s: float, 主: Color, 副色: Color) -> float:
	var 大 := int(26.0*s)
	粗.draw_string(ci, Vector2(p.x, p.y + 大), 号, HORIZONTAL_ALIGNMENT_LEFT, -1, 大, Color(令.色["注意"]))
	var x := p.x + 56.0*s
	var y := _行(ci, 粗, 主句, Vector2(x, p.y), w - 56.0*s, 大, 主)
	if 副 != "": y = _行(ci, 字, 副, Vector2(x, y + 8.0*s), w - 56.0*s, int(22.0*s), 副色)
	return y + 30.0*s


func _行(ci: RID, f: Font, t: String, p: Vector2, w: float, 号: int, 色: Color) -> float:
	"""画一段（自动折行，长路径在任意字符处断）；返回下一行的顶端 y。"""
	var 断 := TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_GRAPHEME_BOUND
	f.draw_multiline_string(ci, Vector2(p.x, p.y + f.get_ascent(号)), t, HORIZONTAL_ALIGNMENT_LEFT, w, 号, -1, 色, 断)
	return p.y + f.get_multiline_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, w, 号, -1, 断).y
