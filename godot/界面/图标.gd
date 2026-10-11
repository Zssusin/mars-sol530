# 界面图标（甲套 32 个，原件在 docs/界面/风格样张/图标/甲/，原样拷到 界面/图标/）：界面 v3「丙」和玩法模块共用。
#   运行时用 Image.load_svg_from_string 按要的像素栅格化（不经 Godot 导入：哪个尺寸都清晰）；目录有 .gdignore，导出时走 环境.外置()（工具/导出.sh 复制到 data/）。
#   可读性同 甲：先画一层外扩（线宽 + 2×1.8 px），再画本体；本体和外扩都烤成白色，画的时候用 modulate 上色：
#   本体 = 前景色（令牌角色），外扩 = 令.边(前景色)（一般是暗色；NASA 色板的「活」深蓝配白边）。
extends RefCounted

var 目录: String = 环境.外置("界面/图标/")
var 源 := {}
var 缓存 := {}


func 有(名: String) -> bool:
	return 文(名) != ""


func 文(名: String) -> String:
	if not 源.has(名):
		var p := 目录 + 名 + ".svg"
		源[名] = FileAccess.get_file_as_string(p) if FileAccess.file_exists(p) else ""
		if 源[名] == "": push_warning("[界面] 没有图标 %s" % p)
	return 源[名]


func 纹(名: String, px: int, 晕 := false) -> Texture2D:
	"""名：文件名（不带 .svg）；px：边长（像素）；晕：外扩版（垫在底下，白色，画时着色）。"""
	px = maxi(px, 8)
	var k := "%s|%d|%d" % [名, px, int(晕)]
	if 缓存.has(k): return 缓存[k]
	var t := 文(名)
	if t == "": 缓存[k] = null; return null
	var sc := px/24.0
	if 晕:
		var add := 2.0*2.5/sc                                            # 屏幕上外扩 2.5 px（界面 6：不透明，图标对自己的外扩量 ≥ 3:1），换算到 24 网格
		t = t.replace('stroke-width="1.5"', 'stroke-width="%.2f"' % (1.5 + add))
		t = t.replace('stroke="none"', 'stroke="#FFFFFF" stroke-width="%.2f"' % add)
	var img := Image.new()
	if img.load_svg_from_string(t, sc) != OK: 缓存[k] = null; return null
	var tex := ImageTexture.create_from_image(img)
	缓存[k] = tex
	return tex


func 画(c: CanvasItem, 名: String, 心: Vector2, px: float, col := Color.WHITE, 边色 := Color(-1, 0, 0), 活 := false, 晕a := 1.0) -> void:
	"""以 心 为中心画一个图标（px 为边长，屏幕像素）：阴影（下移）+ 外扩（边色，默认令牌暗色）+ 本体。活：外扩不透明（白边）。"""
	var n := roundi(px)
	var a := 纹(名, n, true); var b := 纹(名, n, false)
	if b == null: return
	var 暗: Color = 令.色["暗"]
	if 边色.r < 0.0: 边色 = 暗
	var r := Rect2((心 - Vector2(n, n)*0.5).round(), Vector2(n, n))
	if a:
		c.draw_texture_rect(a, Rect2(r.position + Vector2(0, maxf(1.0, n/18.0)), r.size), false, Color(暗, 0.30*col.a))
		c.draw_texture_rect(a, r, false, Color(边色, (1.0 if 活 else 晕a)*col.a))
	c.draw_texture_rect(b, r, false, col)
