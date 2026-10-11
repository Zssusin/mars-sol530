# 最小暂停菜单（docs/工程化方案.md §6.3）：Esc 第一次放开鼠标（控制.gd），第二次打开本菜单。
#   菜单项：继续、sol 规划（玩法 B）、拍照模式、图鉴、帮助、退出。设置页等外壳那一轮。打开时世界暂停、焦点在「继续」上（键盘 ↑↓ Enter，手柄同 ui_*）。
extends Node

var 玩: Node
var P: Node
var 风: RefCounted
var 开着 := false
var 层: CanvasLayer
var 根: Control
var 项: Array = []
var 选 := 0
var 悬 := -1
var 按 := -1
var 开a := 0.0
var 框: Array = []
var 鼠标位 := Vector2.ZERO
const 件 := preload("res://界面/件.gd")


func _ready() -> void:
	玩 = get_parent(); P = 玩.P; 风 = 玩.风
	层 = CanvasLayer.new(); 层.layer = 50; 层.visible = false; add_child(层)


func 搭() -> void:
	if 根: 根.queue_free()
	项 = [["继续", "执行", "Esc", _继续], ["拍照", "拍照", "C", _拍照], ["图鉴", "图鉴", "Tab", _图鉴], ["帮助", "帮助", "F1", _帮助], ["退出", "关闭", "", _退出]]
	if 玩.B: 项.insert(1, ["火星日规划", "地图", "F2", _规划])
	根 = Control.new(); 根.set_anchors_preset(Control.PRESET_FULL_RECT); 根.mouse_filter = Control.MOUSE_FILTER_STOP; 层.add_child(根)
	根.draw.connect(_画); 根.gui_input.connect(_鼠标)
	选 = 0; 悬 = -1; 按 = -1; 开a = 0.0; 框.clear()


func _process(dt: float) -> void:
	if not 开着: return
	开a = minf(1.0, 开a + dt/maxf(令.时["中"]*令.动倍, 1e-3)) if 令.动倍 > 0.0 else 1.0
	件.提示更(str(悬) if 悬 >= 0 else "", dt)
	根.queue_redraw()


func _画() -> void:
	var c := 根; var vs := c.size; var s: float = 风.s; var a := 令.缓(开a); var 主: Color = 令.色["主"]
	c.draw_rect(Rect2(Vector2.ZERO, vs), Color(风.页底, 令.透["页暗"]*a))
	框.clear()
	var x0 := vs.x*0.5 - 260*s; var rh := 64.0*s; var y0 := vs.y*0.5 - 150*s
	件.图标(c, "暂停", Vector2(x0 + 24*s, y0 - 86*s + (1.0 - a)*10*s), 56.0, Color(主, a))
	件.滑竖(c, "暂停竖", Vector2(x0 - 14*s, y0 + rh*选 + 10*s), Vector2(x0 - 14*s, y0 + rh*(选 + 1) - 10*s), Color(令.色["活亮"], a), 4.0)
	for i in 项.size():
		var q: Array = 项[i]; var hv := 件.悬度("暂停%d" % i, i == 悬); var 亮 := i == 选
		var 进 := clampf(a*1.6 - 0.1*i, 0.0, 1.0); var 缩 := 令.点击["按缩"] if i == 按 else 1.0
		var r := Rect2(x0 - 16*s, y0 + rh*i, 520*s, rh); 框.append(r)
		if hv > 0.01: c.draw_rect(r, Color(主, 0.10*hv*进))
		var col := Color(主 if 亮 else 令.色["次"].lerp(主, hv), 进)
		件.图标(c, q[1], Vector2(x0 + 24*s, r.get_center().y), 40.0*缩, col)
		风.字串(c, Vector2(x0 + 70*s, r.get_center().y + 10*s), q[0], 30 if 亮 else 28, col, "粗" if 亮 else "中")
		if q[2] != "": 件.键帽(c, Vector2(x0 + 440*s, r.get_center().y + 10*s), q[2], Color(令.色["次"], 进), 22.0)
	件.字串(c, Vector2(vs.x - 60*s, vs.y - 40*s), "非 NASA 官方产品", 18, Color(主, 0.9*a), "中", HORIZONTAL_ALIGNMENT_RIGHT, -1.0, true)
	if 悬 >= 0 and 悬 < 项.size():
		var 说 := {"继续": "回到游戏", "火星日规划": "规划一个火星日的行程", "拍照": "拍照模式（世界暂停）", "图鉴": "兴趣点和我拍的照片", "帮助": "按键和界面说明", "退出": "关闭游戏"}
		件.提示画(c, String(说.get(项[悬][0], "")), 鼠标位, vs)


func _鼠标(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion:
		鼠标位 = ev.position; 悬 = 件.命中(框, ev.position)
		if 悬 >= 0: 选 = 悬                                               # 鼠标一动，焦点跟鼠标
	elif ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		if ev.pressed: 按 = 件.命中(框, ev.position)
		else:
			var 起 := 按; 按 = -1
			if 起 >= 0 and 件.命中(框, ev.position) == 起: 项[起][3].call()      # 抬起才触发，移出再抬起取消


func 打开() -> void:
	var 主: Node = P.get_node_or_null("主菜单")                         # 走主菜单启动时：回到主菜单（活沙盘，世界暂停），代替本菜单
	if 主 and 主.has_method("回来"):
		主.回来(); return
	if 开着: return
	开着 = true; 玩.暂停("菜单", true); 玩.放鼠标()
	搭(); 层.visible = true


func 关() -> void:
	if not 开着: return
	开着 = false; 层.visible = false; 玩.暂停("菜单", false)


func 输入(ev: InputEvent) -> void:
	if not (ev is InputEventKey and ev.pressed): return
	match ev.keycode:
		KEY_ESCAPE: if not ev.echo: _继续()
		KEY_UP: 选 = posmod(选 - 1, 项.size())
		KEY_DOWN: 选 = posmod(选 + 1, 项.size())
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE: if not ev.echo: 项[选][3].call()
		_: return
	get_viewport().set_input_as_handled()


func _继续() -> void:
	关(); 玩.还鼠标()


func _规划() -> void:
	关()
	if 玩.B: 玩.B.切换()


func _拍照() -> void:
	关()
	if 玩.拍照: 玩.拍照.进入()


func _图鉴() -> void:
	关()
	if 玩.图鉴: 玩.图鉴.打开()


func _帮助() -> void:
	关(); 玩.还鼠标()
	var 界: Node = P.get_node_or_null("界面")
	if 界 and 界.has_method("帮助"): 界.帮助(true)


func _退出() -> void:
	关(); P.quit_clean()
