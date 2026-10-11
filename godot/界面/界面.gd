# 界面 v3「丙 · 极简 + 叙事内」（实景地形系统.md §22；样张 docs/界面/风格样张/样张_丙_*，说明.md「丙」）。
#   实景.gd 实时漫游时自动加载为子节点「界面」；--界面=旧 换回 v2 仪表式（界面_v2.gd），做 A/B 对比。
#   屏幕上常驻的只剩三样：左上时刻（太阳图标 + sol 号）、底部居中按情境出现的按键提示、右下圆形小地图；
#     顶部居中的相机模式只在切换后显示 2 秒（完整档常驻淡显）。
#   其余画进世界：
#     地面（Decal，界面/地面.gd）：车脚下的罗盘环（北向固定、30° 一格）和车头三角；路径人字箭头——玩法 B 的航线（按驾驶方式着色）、
#       手动驾驶时的阿克曼预测弧（原地转时是绕车的箭头）。地面图形被车身和石块挡住，不投到车上。
#     锚在世界里的 2D 字和图标（3D 只算锚点，Camera3D.unproject_position 投到屏幕再画，字清晰、大小稳定；锚点在相机背后时不画）：
#       环外的 北 东 南 西（被车身挡住时不画）、环下的航向读数、兴趣点小标（竖线落地）、航点标、
#       车体读数牌（从桅杆头引出：速度、倍率、电量、里程）、倾角弧（以车身为圆心，从竖直量到车身竖轴）。
#     桅杆视角里车不在画面中：方位字立在地平线上，读数印在画面下方，倾角告警画成两侧随横滚转的水平标 + 中央图标和字。
#   可读性：不加成片的暗底（用户的硬规矩）；字和线都是 深色外扩描边 + 下移阴影（同 甲：#140E0A），图标垫一层深色外扩。
#   颜色：白常态、琥珀 #FFB000 注意、红 #FF4B3A 警告；告警同时换形状（三角 / 八边形）并写字。字：Inter Medium + Noto Sans SC。
#   图标：甲套（界面/图标/，界面/图标.gd 运行时栅格化）。
#   令牌和组件（docs/界面/UI体系.md）：颜色按角色从 令（界面/令牌.gd）取，换色板时重画；线、字、图标、键帽、小标都是 件（界面/件.gd）的组件。
# 分档（H 循环）：精简（默认）→ 完整 → 关。精简：读数牌只在开车 / 换倍率时出现，倾角弧只在接近阈值（≥ 15°）时出现；
#   完整：读数牌、倾角弧常驻，相机模式常驻淡显。关：屏幕和地面图形全藏。
#   地面图形按需出现（参照 Dead Space 的定位线、Death Stranding 的扫描）：箭头只在开车 / 执行时有，停下 2 s 后淡出；车停着 3 s 后罗盘环调暗。
#   预测弧像倒车影像的轨迹线：5 m、10 m 写距离，箭头按脚下坡度分段着色（≥ 20° 琥珀、≥ 30° 红）。
# 键：H 分档、F1 帮助、M 全屏地图、Shift+M 小地图换档、F3 性能、[ ] 上 / 下一个天空时刻。
# 给别的模块：visible（藏 / 显，地面图形跟着）、帮助(on)、锚屏(E, N, 高)（玩法 A 导览卡锚在兴趣点旁边）、
#   底图高 / 底图远 / 高半 / 远半 / 图码（规划图、下行卡复用小地图底图和着色器）。
# 自测：godot --path godot -- --界面测试[=目录]（界面/测试.sh）：同 v2 的七张截图 + 完整档 + 兴趣点，量开销后退出。
# 开销：屏幕层按签名重画；锚定层每帧重画（字十几行）；地面 Decal 只在车动 / 状态变时挪。
extends CanvasLayer

const 版 := 3
const 地面脚本 := preload("res://界面/地面.gd")
const 地线脚本 := preload("res://界面/地线.gd")
const 件 := preload("res://界面/件.gd")
var 素材: String = 环境.外置("界面/素材/")
const SOL := 530
const 档位 := [20.0, 50.0, 150.0, 500.0, 1500.0, 5000.0, 20000.0]   # 小地图半径（m）；> HiRISE 范围换 CTX
const 倾近 := 15.0                                # 倾角弧开始出现（精简档）
const 倾黄 := 20.0                                # 注意（本游戏的设定，不是真车参数；同 v2）
const 倾红 := 30.0                                # 警告
const 模式序 := ["自由", "跟车", "桅杆", "俯视"]
const 模式图标 := {"自由": "相机_自由", "跟车": "相机_跟车", "桅杆": "相机_桅杆", "俯视": "相机_俯视"}
const 方式名 := ["盲开", "视觉里程计", "自主导航"]
const 档名 := ["关", "精简", "完整"]
const 方位名 := {0: "北", 90: "东", 180: "南", 270: "西"}
const 车盒lo := Vector3(-1.25, 0.05, -1.5)         # 车身遮挡盒（车坐标：x 左、y 上、z 前；到车顶甲板，不含桅杆）
const 车盒hi := Vector3(1.25, 1.35, 1.6)

var 白 := Color.WHITE                              # 颜色都从令牌取（取色()，换色板时重取）：白 = 主（常态字和线）
var 活 := Color.WHITE                              # 活：当前路线、航点、车标（NASA 色板：深蓝 + 白边）
var 琥珀 := Color.WHITE                            # 注意
var 红 := Color.WHITE                              # 警告
var 暗 := Color.BLACK                              # 描边和阴影

var P: Node                                       # 实景.gd
var 控: Node = null
var 已连 := false
var 扫: Node                                      # 扫描.gd
var 环线: Node3D = null                           # 罗盘环、刻度（屏宽线，界面 6 替掉 Decal）
var 刻线: Node3D = null
var 环脏 := true
var 环建位 := Vector3(INF, 0, 0)
var 环建k := -1.0
var 地: Node3D                                    # 地面.gd
var s := 1.0
var 尺寸 := Vector2i.ZERO
var 根: Control
var 屏: Control                                   # 时刻、相机模式、按键提示、性能
var 锚: Control                                   # 锚在世界里的字和图标（每帧重画）
var 图: Control                                   # 小地图（圆）
var 轨迹层: Node2D
var 图标层: Control
var 帮助层: ColorRect
var 帮助格: VBoxContainer
var 底图高: Texture2D
var 底图远: Texture2D
var 高半 := 1000.0
var 远半 := 40000.0
var 档 := 1
var 档提示 := 0.0
var 显档 := 1                                     # 0 关、1 精简、2 完整
var 天时: Array = []
var 时分 := 0.0
var 上次ltst := ""
var 采累 := 0.0
var 慢累 := 0.0
var 起时 := 0.0
var 模式 := ""
var 提示时 := 0.0
var 按键: Array = []
# 状态（15 Hz）
var 速 := NAN
var 倍 := NAN
var 旧倍 := NAN
var 倍变时 := 0.0
var 里程 := NAN
var 油 := 0.0
var 臂文 := ""
var 自驾 := false
var 标记: Array = []
var B态 := {}
# 位姿（每帧）
var 车xf := Transform3D()
var 有车 := false
var 车航 := 0.0                                   # rad，0 = 北、顺时针
var 俯 := 0.0
var 滚 := 0.0
var 倾 := 0.0
var cam: Camera3D
var 心 := Vector2.ZERO
var 轨迹 := PackedVector2Array()
var 轨迹脏 := true
# 淡入淡出
var 读淡 := 0.0
var 倾淡 := 0.0
var 弧淡 := 0.0
var 环淡 := 1.0
var 弧标: Array = []                               # 预测弧上的距离刻度 [[世界点, 字], …]
var 动停 := 99.0                                  # 停下多久了（s）
# 地面箭头
var 箭签 := []
var 箭源 := ""
# 屏幕层签名
var 签屏 := ""
var 签图 := Vector4(INF, 0, 0, 0)
var 签标 := Vector4.ZERO
var 提示表: Array = []
var 屏占: Array[Rect2] = []                          # 屏幕层占的地方（左上时刻、相机模式、按键提示、小地图），_画屏 里更新
var 占: Array[Rect2] = []                            # 锚定层这一帧已经占的地方（避让用）
# 性能
var 测 := false
var 帧和 := 0.0
var gpu和 := 0.0
var 界和 := 0.0
var 帧数 := 0
var 窗 := 0.0
var 性能字 := ""
var 界总 := 0.0
var 帧总 := 0


func _ready() -> void:
	P = get_parent()
	layer = 10
	取色()
	令.变了.connect(_换色)
	var T: Dictionary = P.J["tex"]
	底图高 = load(环境.资源目录() + T["albedo_hirise"]["file"]); 高半 = T["albedo_hirise"]["half"]
	底图远 = load(环境.资源目录() + T["albedo_ctx"]["file"]); 远半 = T["albedo_ctx"]["half"]
	for k in P.J["sky"].keys(): 天时.append(P.minutes(k))
	天时.sort()
	上次ltst = P.ltst; 时分 = P.minutes(P.ltst)
	地 = 地面脚本.new(P); add_child(地); 地.用线环 = true
	环线 = 地线脚本.new(3.0, 4.0, 0); 刻线 = 地线脚本.new(2.0, 4.0, 0)
	for n: Node3D in [环线, 刻线]: 地.add_child(n); n.visible = false
	扫 = load("res://界面/扫描.gd").new(self); add_child(扫)                  # 扫描脉冲（界面/扫描.gd；按 令.扫.键）
	搭()
	get_viewport().size_changed.connect(func(): call_deferred("搭"))
	visibility_changed.connect(_显隐)
	性能开(P.args.get("性能", "0") == "1")
	if P.args.has("界面档"): 设档(clampi(int(P.args["界面档"]), 0, 2))
	if P.args.has("界面测试"): 自测(String(P.args["界面测试"]))


func _显隐() -> void:
	地.visible = visible                                               # 拍照模式、全屏页藏 HUD 时，地面图形一起藏


func 设档(k: int) -> void:
	显档 = k; visible = k != 0
	签屏 = ""; 箭签 = []
	if 屏: 屏.queue_redraw()


# ———————————————————— 颜色（令牌）
func 取色() -> void:
	白 = 令.色["主"]; 活 = 令.色["活"]; 琥珀 = 令.色["注意"]; 红 = 令.色["警告"]; 暗 = 令.色["暗"]


func _换色() -> void:
	"""换色板 / 字倍：重取颜色，屏幕层、小地图、地面贴图都重画。"""
	取色(); 签屏 = ""; 签图.x = INF; 签标 = Vector4.ZERO; 轨迹脏 = true; 箭签 = []
	if 地: 地.重贴()
	环脏 = true
	if 帮助层: 帮助层.color = Color(暗, 0.55)
# ———————————————————— 搭（窗口大小变了重搭）
func 新层(f: Callable, 鼠 := false) -> Control:
	var c := Control.new(); c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_STOP if 鼠 else Control.MOUSE_FILTER_IGNORE
	c.draw.connect(f); 根.add_child(c)
	return c


func 搭() -> void:
	var vs := get_viewport().get_visible_rect().size
	if Vector2i(vs) == 尺寸 and 根: return
	尺寸 = Vector2i(vs)
	var 帮 := false
	if 根: 帮 = 帮助层.visible; remove_child(根); 根.queue_free()
	s = 令.s                                                           # 以 1440 高为 1（令牌统一算）
	根 = Control.new(); 根.name = "根"; 根.set_anchors_preset(Control.PRESET_FULL_RECT); 根.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var th := Theme.new(); th.default_font = 令.字["正"]; th.default_font_size = int(20*s); 根.theme = th
	add_child(根)
	锚 = 新层(_画锚)
	屏 = 新层(_画屏)
	搭地图(Vector2(vs.x - 174*s, vs.y - 174*s), 120*s)
	搭帮助()
	帮助层.visible = 帮
	轨迹脏 = true; 签屏 = ""; 签图.x = INF


func 搭地图(o: Vector2, r: float) -> void:
	图 = Control.new(); 图.position = o - Vector2(r, r); 图.size = Vector2(2*r, 2*r)
	图.mouse_filter = Control.MOUSE_FILTER_STOP; 图.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	图.draw.connect(_画底图); 图.gui_input.connect(_图输入)
	var sh := Shader.new(); sh.code = 圆码
	var sm := ShaderMaterial.new(); sm.shader = sh
	sm.set_shader_parameter("base", Vector3(0.55, 0.41, 0.32)*0.80); sm.set_shader_parameter("size", Vector2(2*r, 2*r))
	图.material = sm
	根.add_child(图)
	轨迹层 = Node2D.new(); 轨迹层.draw.connect(_画轨迹); 图.add_child(轨迹层)
	图标层 = Control.new(); 图标层.set_anchors_preset(Control.PRESET_FULL_RECT); 图标层.mouse_filter = Control.MOUSE_FILTER_IGNORE
	图标层.draw.connect(_画图标); 图.add_child(图标层)


const 图码 := """shader_type canvas_item;
// 小地图（v2 方形，规划图、下行卡复用）：反照率图反差很小，按图拉伸（再压暗、加一点反差）；只在最外 3% 淡出
uniform vec3 mid; uniform vec3 base; uniform float k = 4.0; uniform vec2 size = vec2(400.0);
varying vec2 lp;
void vertex() { lp = VERTEX; }
void fragment() {
	COLOR.rgb = clamp(base + (COLOR.rgb - mid)*k*1.2, 0.0, 1.0);
	vec2 e = abs(lp/size*2.0 - 1.0);
	COLOR.a *= 0.96*(1.0 - smoothstep(0.97, 1.0, max(e.x, e.y)));
}
"""

const 圆码 := """shader_type canvas_item;
// 圆形小地图（丙）：同 图码 的拉伸，圆形遮罩、边上 1.5 px 抗锯齿
uniform vec3 mid; uniform vec3 base; uniform float k = 4.0; uniform vec2 size = vec2(240.0);
varying vec2 lp;
void vertex() { lp = VERTEX; }
void fragment() {
	COLOR.rgb = clamp(base + (COLOR.rgb - mid)*k*1.2, 0.0, 1.0);
	float r = length(lp - size*0.5); float R = size.x*0.5;
	COLOR.a *= 0.92*(1.0 - smoothstep(R - 1.5, R, r));
}
"""


func 搭帮助() -> void:
	帮助层 = ColorRect.new(); 帮助层.color = Color(暗, 0.55); 帮助层.set_anchors_preset(Control.PRESET_FULL_RECT)
	帮助层.mouse_filter = Control.MOUSE_FILTER_STOP                    # 全屏页：可以有整屏的底
	根.add_child(帮助层)
	var cc := CenterContainer.new(); cc.set_anchors_preset(Control.PRESET_FULL_RECT); cc.mouse_filter = Control.MOUSE_FILTER_IGNORE; 帮助层.add_child(cc)
	var pc := PanelContainer.new(); pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new(); sb.bg_color = Color(暗, 0.90); sb.border_color = Color(白, 0.5)
	sb.border_width_top = int(maxf(1.0, round(2*s))); sb.set_content_margin_all(40*s)
	pc.add_theme_stylebox_override("panel", sb); cc.add_child(pc)
	帮助格 = VBoxContainer.new(); 帮助格.add_theme_constant_override("separation", int(12*s)); 帮助格.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pc.add_child(帮助格)


func 签(text: String, fk: String, size: float, col: Color) -> Label:
	var l := Label.new(); l.set_meta("原", text); l.text = 令.译(text); 令.变了.connect(func(): if is_instance_valid(l): l.text = 令.译(String(l.get_meta("原")))); l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_override("font", 令.字[fk]); l.add_theme_font_size_override("font_size", int(round(size*s)))
	l.add_theme_color_override("font_color", col)
	return l


func 帮助内容() -> void:
	for c in 帮助格.get_children(): c.queue_free()
	帮助格.add_child(签("按键　F1", "粗", 32, 白))
	var 左: Array = 按键 if 控 and not 按键.is_empty() else [["W A S D", "移动"], ["鼠标", "看"], ["Shift", "快"], ["Q / E", "降 / 升"],
		["T", "天空时刻"], ["F12", "截图"], ["Esc", "放开鼠标"]]
	var 右 := [["H", "界面分档"], ["F1", "帮助"], ["M", "地图"], ["Shift+M", "小地图换档"], ["滚轮", "小地图缩放"],
		["F3", "性能"], ["[  ]", "天空时刻"]]
	if P.has_node("天气"):
		右 += [["N", "尘埃 τ"], ["U", "风速"], ["B", "尘卷风"],
			["J", "扬尘"], ["Y", "放尘卷风"], ["G", "自动曝光"]]
	if P.has_node("声音") and P.get_node("声音").has_method("按键"): 右 += P.get_node("声音").按键()
	if P.has_node("玩法") and P.get_node("玩法").has_method("按键"): 左 = 左 + P.get_node("玩法").按键()
	var hb := HBoxContainer.new(); hb.add_theme_constant_override("separation", int(72*s)); hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	帮助格.add_child(hb)
	帮助列(hb, "驾驶 · 相机" if 控 else "自由飞行（无控制模块）", 左)
	帮助列(hb, "界面", 右)
	var e := 签("非 NASA / JPL 官方产品 · 数据 NASA/JPL-Caltech/ASU/MSSS/UArizona/USGS · 字体 Inter、IBM Plex Mono、Noto Sans SC（SIL OFL 1.1）· " + 环境.一行(), "正", 16, Color(白, 0.85))
	e.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; e.custom_minimum_size.x = 1500*s; 帮助格.add_child(e)


func 帮助列(父: Control, 题: String, 表: Array) -> void:
	var v := VBoxContainer.new(); v.add_theme_constant_override("separation", int(6*s)); v.mouse_filter = Control.MOUSE_FILTER_IGNORE; 父.add_child(v)
	v.add_child(签(题, "粗", 24, 白))
	var g := GridContainer.new(); g.columns = 2; g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	g.add_theme_constant_override("h_separation", int(20*s)); g.add_theme_constant_override("v_separation", int(5*s)); v.add_child(g)
	for kv in 表:
		var k := 签(String(kv[0]), "中", 22, 白); k.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT; g.add_child(k)
		g.add_child(签(String(kv[1]), "正", 22, Color(白, 0.8)))


# ———————————————————— 键
func _unhandled_input(ev: InputEvent) -> void:
	if not (ev is InputEventKey and ev.pressed and not ev.echo): return
	match ev.keycode:
		KEY_H: 设档((显档 + 1) % 3)
		KEY_F1: 帮助(not (帮助层.visible and visible))
		KEY_M:
			if not ev.shift_pressed: return                                  # 单按 M 是全屏地图（界面/地图台/地图台.gd）；Shift+M 才换小地图档
			换档(1, true)
		KEY_F3: 性能开(not 测)
		KEY_BRACKETLEFT: 跳时(-1)
		KEY_BRACKETRIGHT: 跳时(1)
		_: return
	get_viewport().set_input_as_handled()


func 帮助(on: bool) -> void:
	if on:
		if 显档 == 0: 设档(1)
		visible = true; 帮助内容()
	帮助层.visible = on


func 换档(d: int, 绕: bool) -> void:
	档 = posmod(档 + d, 档位.size()) if 绕 else clampi(档 + d, 0, 档位.size() - 1)
	轨迹脏 = true; 档提示 = 2.0; 签图.x = INF


func _图输入(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed:
		if ev.button_index == MOUSE_BUTTON_WHEEL_UP: 换档(-1, false); 图.accept_event()
		elif ev.button_index == MOUSE_BUTTON_WHEEL_DOWN: 换档(1, false); 图.accept_event()


func 性能开(on: bool) -> void:
	测 = on; 性能字 = ""
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), on)
	帧和 = 0; gpu和 = 0; 界和 = 0; 帧数 = 0; 窗 = 0; 签屏 = ""


func 跳时(d: int) -> void:
	var m := 时分
	if d > 0:
		for t in 天时:
			if t > 时分 + 0.5: m = t; break
	else:
		for i in range(天时.size() - 1, -1, -1):
			if 天时[i] < 时分 - 0.5: m = 天时[i]; break
	时分 = m; P.set_time_f(m); 签屏 = ""


func _模式变(m) -> void:
	模式 = String(m); 提示时 = 2.6; 箭签 = []


# ———————————————————— 每帧
func _process(dt: float) -> void:
	var t0 := Time.get_ticks_usec()
	起时 += dt
	取位姿()
	采累 += dt
	if 采累 >= 1.0/15.0: 采累 = 0.0; 采状态()
	慢累 += dt
	if 慢累 >= 0.1:
		慢累 = 0.0
		if P.ltst != 上次ltst: 上次ltst = P.ltst; 时分 = P.minutes(P.ltst)
		elif P.time_m >= 0.0 and absf(P.time_m - 时分) > 0.5: 时分 = P.time_m
	if visible: 更新(dt)
	界总 += (Time.get_ticks_usec() - t0)/1000.0; 帧总 += 1
	if 测:
		var rid := get_viewport().get_viewport_rid()
		帧和 += dt*1000.0; gpu和 += RenderingServer.viewport_get_measured_render_time_gpu(rid); 帧数 += 1; 窗 += dt
		界和 += (Time.get_ticks_usec() - t0)/1000.0
		if 窗 >= 0.5:
			var n := float(帧数)
			性能字 = "%d FPS · %.1f ms · GPU %.1f · 界面 %.3f ms" % [roundi(1000.0*n/帧和), 帧和/n, gpu和/n, 界和/n]
			帧和 = 0; gpu和 = 0; 界和 = 0; 帧数 = 0; 窗 = 0


func 取位姿() -> void:
	var rr: Node3D = P.rover_root
	有车 = rr != null and is_instance_valid(rr) and rr.visible
	if 有车:
		车xf = rr.global_transform; var B := 车xf.basis
		var f := B.z                                                     # 模型 +z 朝前、+x 朝左
		车航 = atan2(f.x, -f.z)
		俯 = rad_to_deg(asin(clampf(B.z.normalized().y, -1.0, 1.0)))
		滚 = rad_to_deg(asin(clampf(B.x.normalized().y, -1.0, 1.0)))
		倾 = rad_to_deg(acos(clampf(B.y.normalized().y, -1.0, 1.0)))
	cam = get_viewport().get_camera_3d()
	var p := Vector2(车xf.origin.x, -车xf.origin.z) if 有车 and 控 != null else (Vector2(cam.global_position.x, -cam.global_position.z) if cam else Vector2.ZERO)
	心 = p
	var q := Vector2(p.x, -p.y)
	if 轨迹.is_empty() or 轨迹[-1].distance_squared_to(q) > 0.25:
		if not 轨迹.is_empty() and 轨迹[-1].distance_squared_to(q) > 400.0: 轨迹.clear()
		轨迹.append(q); 轨迹脏 = true
		if 轨迹.size() > 4000: 轨迹 = 轨迹.slice(1000)


func 采状态() -> void:
	控 = P.get_node_or_null("控制")
	if 控 and not 已连 and 控.has_signal("模式改变"): 控.connect("模式改变", _模式变); 已连 = true
	var st: Dictionary = 控.call("状态") if 控 and 控.has_method("状态") else {}
	模式 = String(st.get("模式", "自由" if 控 == null else 模式))
	if st.has("按键") and st["按键"] is Array: 按键 = st["按键"]
	速 = float(st["速度_mps"]) if st.has("速度_mps") else NAN
	倍 = float(st["倍率"]) if st.has("倍率") else NAN
	if not is_nan(倍) and not is_nan(旧倍) and 倍 != 旧倍: 倍变时 = 3.0
	旧倍 = 倍
	里程 = float(st["里程_m"]) if st.has("里程_m") else NAN
	油 = float(st.get("油门", 0.0))
	自驾 = bool(st.get("自驾", false))
	臂文 = ""
	if st.has("机械臂") and st["机械臂"] is Dictionary:
		var am: Dictionary = st["机械臂"]; var q: Array = am.get("角度_deg", [])
		if bool(am.get("模式", false)) and q.size() == 5:
			var j := clampi(int(am.get("关节号", 0)), 0, 4)
			臂文 = "%s %+.0f°" % [String(am.get("关节", "")), float(q[j])]
	var 玩: Node = P.get_node_or_null("玩法")
	标记 = 玩.标记() if 玩 and 玩.has_method("标记") else []
	B态 = {}
	var Bn: Node = 玩.get_node_or_null("B") if 玩 else null
	if Bn and Bn.has_method("B状态"):
		var bs: Dictionary = Bn.B状态()
		if bs["开"] or bs["执行"]: B态 = bs


func 更新(dt: float) -> void:
	if 提示时 > 0.0: 提示时 -= dt
	if 倍变时 > 0.0: 倍变时 -= dt
	if 档提示 > 0.0: 档提示 -= dt
	var 动 := (not is_nan(速) and absf(速) > 1e-5) or absf(油) > 0.01 or 自驾
	动停 = 0.0 if 动 else 动停 + dt
	var 桅 := 模式 == "桅杆"
	读淡 = move_toward(读淡, 1.0 if (显档 == 2 or 动停 < 1.5 or 倍变时 > 0.0 or 臂文 != "") else 0.0, dt*(4.0 if 读淡 < 0.5 else 1.5))
	倾淡 = move_toward(倾淡, 1.0 if (显档 == 2 or 倾 >= 倾近) and 有车 else 0.0, dt*3.0)
	弧淡 = move_toward(弧淡, 1.0 if 动停 < 2.0 else 0.0, dt*(5.0 if 弧淡 < 0.5 else 1.0))   # 按需出现：开着车才有，停下 2 s 后淡出（各档都一样）
	环淡 = move_toward(环淡, 1.0 if 动停 < 3.0 or 显档 == 2 else 0.45, dt*(3.0 if 环淡 < 0.9 else 0.6))   # 停着时罗盘环调暗
	地.每帧(dt, 车xf, 有车, 车航, not 桅, 环淡)
	更环线()
	更箭()
	锚.queue_redraw()
	# 屏幕层：内容变了才重画
	var 提 := 算提示()
	var 模a := 模式淡()
	var sig := "%s|%d|%.2f|%s|%s|%d|%s" % [时字(), int(B态.get("sol", SOL)), 模a, str(提), 性能字 if 测 else "", 显档, B行()]
	if sig != 签屏: 签屏 = sig; 提示表 = 提; 屏.queue_redraw()
	更地图()


func 时字() -> String:
	return "%02d:%02d" % [int(时分)/60, int(时分) % 60]


func 模式淡() -> float:
	if 显档 == 2: return 1.0 if 提示时 > 0.0 else 0.6
	return clampf(提示时/0.6, 0.0, 1.0)


func 算提示() -> Array:
	"""按情境出现的按键提示（最多三个）。"""
	var out: Array = []
	var 玩: Node = P.get_node_or_null("玩法")
	var 兴: Node = 玩.get_node_or_null("兴趣") if 玩 else null
	if not B态.is_empty() and B态["执行"]:
		out.append(["F2", "中止"]); out.append(["− / =", "快进"])
		out.append(["F", "导览卡"] if 兴 and bool(兴.get("未读")) else ["C", "拍照"]); return out
	if 臂文 != "": out.append(["L", "退出机械臂"]); out.append(["↑ ↓ ← →", "选关节 / 转"]); return out
	if 兴 and 兴.has_method("当前点") and not bool(兴.get("展开")):
		var q: Dictionary = 兴.当前点()
		if not q.is_empty() and Vector2(float(q["E"]) - 心.x, float(q["N"]) - 心.y).length() < 60.0: out.append(["F", "导览卡"])
	out.append(["C", "拍照"])
	if 起时 < 20.0: out.append(["F1", "帮助"])
	return out


func B行() -> String:
	if B态.is_empty() or not B态["执行"]: return ""
	var m := clampi(int(B态.get("方式", 1)), 0, 2)
	var 航: PackedVector2Array = B态["航点"]
	var t := "%s · 第 %d / %d 段" % [方式名[m], mini(int(B态["段"]), maxi(航.size() - 1, 1)), maxi(航.size() - 1, 1)]
	var 完 := float(B态["预计完"])
	if 完 >= 0.0: t += " · 预计 %02d:%02d 到" % [int(完)/60, int(完) % 60]
	return t


# ———————————————————— 屏幕层：左上时刻、顶部相机模式、底部按键提示、性能
func _画屏() -> void:
	var c := 屏; var W := c.size.x; var H := c.size.y
	屏占.clear()
	var 左宽 := 件.宽度(时字(), 34) + 18*s + 件.宽度("SOL %d" % int(B态.get("sol", SOL)), 22)
	件.图标(c, "时刻", Vector2(90, 84)*s, 36)
	件.字串(c, Vector2(120, 98)*s, 时字(), 34, 白, "中")
	件.字串(c, Vector2(120*s + 件.宽度(时字(), 34) + 18*s, 98*s), "SOL %d" % int(B态.get("sol", SOL)), 22, Color(白, 0.85), "中")
	var y := 138.0*s
	var bl := B行()
	if bl != "":                                                       # 玩法 B 执行中：和时刻放在一起（不另占屏幕中间）
		件.图标(c, "自主导航" if int(B态.get("方式", 1)) == 2 else "执行", Vector2(90*s, y - 8*s), 28)
		件.字串(c, Vector2(120*s, y), bl, 22, 白, "中"); y += 32*s; 左宽 = maxf(左宽, 件.宽度(bl, 22))
	if not B态.is_empty():
		var 窗: Vector2 = B态["窗"]
		件.字串(c, Vector2(120*s, y), "驾驶时窗 %02d:00–%02d:00" % [int(窗.x)/60, int(窗.y)/60], 20, Color(白, 0.8), "中"); y += 30*s
		左宽 = maxf(左宽, 件.宽度("驾驶时窗 00:00–00:00", 20))
	屏占.append(Rect2(60*s, 50*s, 60*s + 左宽 + 24*s, y - 50*s))
	屏占.append(Rect2(W - 340*s, H - 340*s, 340*s, 340*s))                # 小地图
	if 测 and 性能字 != "":
		件.字串(c, Vector2(72*s, y), 性能字, 18, Color(白, 0.8), "中"); y += 26*s
		件.字串(c, Vector2(72*s, y), 环境.一行(), 16, Color(白, 0.7), "正")
	# 相机模式（切换后 2 秒淡出；完整档常驻淡显）
	var 模a := 模式淡()
	if 模a > 0.01:
		var 名 := 模式 if 控 else "自由飞行"
		var tw := 件.宽度(名, 28); var x0 := W*0.5 - (tw + 46*s)*0.5
		件.图标(c, String(模式图标.get(模式, "相机_自由")), Vector2(x0 + 16*s, 84*s), 32, Color(白, 模a))
		件.字串(c, Vector2(x0 + 46*s, 96*s), 名, 28, Color(白, 模a), "中")
		屏占.append(Rect2(x0 - 12*s, 56*s, tw + 70*s, 56*s))
	if 档提示 > 0.0: 件.字串(c, Vector2(W - 174*s, H - 174*s + 150*s), 距(档位[档]), 18, Color(白, clampf(档提示, 0.0, 1.0)), "中", HORIZONTAL_ALIGNMENT_CENTER)
	# 按键提示
	if not 提示表.is_empty():
		var ws: Array = []; var tot := 0.0
		for h: Array in 提示表:
			var w := maxf(40*s, 件.宽度(h[0], 24) + 22*s) + 12*s + 件.宽度(h[1], 28); ws.append(w); tot += w
		tot += 44*s*(提示表.size() - 1)
		var x := W*0.5 - tot*0.5
		屏占.append(Rect2(x - 12*s, H - 116*s, tot + 24*s, 64*s))
		for i in 提示表.size():
			var h: Array = 提示表[i]
			var kw := 件.键帽(c, Vector2(x, H - 74*s), h[0])
			件.字串(c, Vector2(x + kw + 12*s, H - 74*s), h[1], 28, 白, "中")
			x += ws[i] + 44*s


# ———————————————————— 锚在世界里的字和图标
func 投(w: Vector3) -> Vector3:
	"""世界点 → 屏幕 (x, y, 1)；在相机背后或离屏太远 → z = −1。"""
	if cam == null or cam.is_position_behind(w): return Vector3(0, 0, -1)
	var p := cam.unproject_position(w); var vs := 锚.size
	if p.x < -0.5*vs.x or p.x > 1.5*vs.x or p.y < -0.5*vs.y or p.y > 1.5*vs.y: return Vector3(p.x, p.y, -1)
	return Vector3(p.x, p.y, 1)


func 锚屏(E: float, N: float, 高 := 2.2) -> Vector3:
	"""给玩法模块：ENU 地面点上方 高 m → 屏幕 (x, y, 1)；看不到 → z = −1。"""
	return 投(Vector3(E, 地高(E, -N) + 高, -N))


func 地高(x: float, z: float) -> float:
	return P.lod.h_cpu(x, z, 0) if P.lod else 0.0


func 被车挡(w: Vector3) -> bool:
	"""相机到 w 的线段穿过车身盒（车坐标）就算被挡。"""
	if not 有车 or cam == null: return false
	var inv := 车xf.affine_inverse()
	var a := inv*cam.global_position; var b := inv*w; var d := b - a
	var t0 := 0.0; var t1 := 1.0
	for i in 3:
		if absf(d[i]) < 1e-6:
			if a[i] < 车盒lo[i] or a[i] > 车盒hi[i]: return false
		else:
			var u := (车盒lo[i] - a[i])/d[i]; var v := (车盒hi[i] - a[i])/d[i]
			t0 = maxf(t0, minf(u, v)); t1 = minf(t1, maxf(u, v))
			if t0 > t1: return false
	return true


func 空(r: Rect2) -> bool:
	for q in 占:
		if q.intersects(r): return false
	return true


func 屏内(p: Vector3, m := 0.0) -> bool:
	return p.z > 0.0 and p.x > m and p.y > m and p.x < 锚.size.x - m and p.y < 锚.size.y - m


func 车屏框() -> Rect2:
	"""给玩法模块（导览卡避让）：车（含桅杆，到 2.3 m 高）在屏幕上的外接矩形；看不到车或有角在相机背后 → 空矩形。"""
	if not 有车 or cam == null: return Rect2()
	var lo := Vector3(-1.4, 0.0, -1.7); var hi := Vector3(1.4, 2.3, 1.8)
	var r := Rect2(); var 有 := false
	for i in 8:
		var w := 车xf*Vector3(hi.x if i & 1 else lo.x, hi.y if i & 2 else lo.y, hi.z if i & 4 else lo.z)
		if cam.is_position_behind(w): return Rect2()
		var p := cam.unproject_position(w)
		if 有: r = r.expand(p)
		else: r = Rect2(p, Vector2.ZERO); 有 = true
	return r.intersection(Rect2(Vector2.ZERO, 锚.size))


func _画锚() -> void:
	if cam == null: return
	var c := 锚
	var 桅 := 模式 == "桅杆"
	占 = 屏占.duplicate()                                              # 避让顺序：屏幕层 > 方位字 > 航点 > 兴趣点（近到远）
	if 桅: 画地平方位(c)
	elif 有车: 画环字(c)
	if not B态.is_empty(): 画航点(c)
	画兴趣点(c)
	if 扫: 扫.画标(c)                                                    # 扫描脉冲揭出来的兴趣点和险坡
	if 弧淡 > 0.05 and 箭源 == "弧": 画弧标(c)
	if 读淡 > 0.01 and 控 != null: 画读数(c, 桅)
	if 倾淡 > 0.01: 画倾角(c, 桅)


func 更环线() -> void:
	"""罗盘环 + 刻度（屏宽线：线宽不随透视变、不被地形投影弄断；走深度测试，车和石块照常挡住）。环从车身往外长（地面.gd 的 环出）。"""
	var 显: bool = 有车 and 模式 != "桅杆" and 地.环出 > 0.0 and 地.visible
	环线.visible = 显; 刻线.visible = 显
	if not 显: 环建位.x = INF; return
	var ek: float = 令.缓(地.环出); var k := lerpf(0.35, 1.0, ek); var o := 车xf.origin
	if 环脏 or 环建位.x == INF or 环建位.distance_to(o) > 0.12 or absf(k - 环建k) > 0.004: 建环线(o, k)
	var 挪 := o - 环建位                                                   # 两次重建之间整圈跟着车平移：以前车走 12 cm 环才跳一次，看着一卡一卡
	环线.position = 挪; 刻线.position = 挪
	var a := 环淡*ek
	环线.着色参(令.色["主"], a*0.95, Color(令.色["暗"], 0.85*a)); 刻线.着色参(令.色["主"], a*0.9, Color(令.色["暗"], 0.85*a))


func 建环线(o: Vector3, k: float) -> void:
	环脏 = false; 环建位 = o; 环建k = k
	var R: float = 地面脚本.环R*k; var 环段: Array = []; var 短: Array = []
	for i in 120:
		var a0 := deg_to_rad(i*3.0); var a1 := deg_to_rad((i + 1)*3.0)
		var p0 := Vector3(o.x + sin(a0)*R, 0, o.z - cos(a0)*R); var p1 := Vector3(o.x + sin(a1)*R, 0, o.z - cos(a1)*R)
		p0.y = 地高(p0.x, p0.z) + 0.03; p1.y = 地高(p1.x, p1.z) + 0.03; 环段.append([p0, p1, 1.0])
	for b in range(0, 360, 10):
		var a := deg_to_rad(b); var 北 := b % 90 == 0; var 中 := b % 30 == 0
		var r1 := R + k*(0.42 if 北 else (0.24 if 中 else 0.10))
		var q0 := Vector3(o.x + sin(a)*R, 0, o.z - cos(a)*R); var q1 := Vector3(o.x + sin(a)*r1, 0, o.z - cos(a)*r1)
		q0.y = 地高(q0.x, q0.z) + 0.03; q1.y = 地高(q1.x, q1.z) + 0.03
		(环段 if 北 else 短).append([q0, q1, 1.0])
	环线.设(环段, 令.色["主"], 1.0); 刻线.设(短, 令.色["主"], 1.0)


func 画弧标(c: CanvasItem) -> void:
	"""预测弧的距离刻度（倒车影像那样）：5 m、10 m 处写在箭头旁边。"""
	for q: Array in 弧标:
		var p := 投(q[0])
		if 屏内(p, 20*s) and not 被车挡(q[0]): 件.字串(c, Vector2(p.x + 34*s, p.y + 7*s), q[1], 20, Color(白, 0.9*弧淡), "中")


func 画环字(c: CanvasItem) -> void:
	var o := 车xf.origin
	for b: int in 方位名:
		var a := deg_to_rad(b); var d := Vector3(sin(a), 0, -cos(a))
		var w := o + d*(地面脚本.环R + 0.85); w.y = 地高(w.x, w.z) + 0.1
		var p := 投(w)
		if not 屏内(p, 10*s) or 被车挡(w): continue
		if b != 0 and 显档 != 2: continue                                   # 界面 5：常态只写「北」（字数预算 ≤ 6）；东南西在完整档
		件.字串(c, Vector2(p.x, p.y + 11*s), 方位名[b], 30, 白, "粗", HORIZONTAL_ALIGNMENT_CENTER)
	# 航向读数：环的近侧（屏幕下方）偏右 40°，避开底部的按键提示
	var u := cam.global_transform.basis.y; var g := Vector3(-u.x, 0, -u.z)
	if g.length() < 1e-3: g = Vector3(0, 0, 1)
	g = g.normalized().rotated(Vector3.UP, deg_to_rad(-40.0))
	var w := o + g*(地面脚本.环R + 0.55); w.y = 地高(w.x, w.z) + 0.05
	var p := 投(w)
	if 屏内(p, 10*s) and not 被车挡(w):
		var t := "%03d°" % (roundi(fposmod(rad_to_deg(车航), 360.0)) % 360)
		var y := minf(p.y + 30*s, 锚.size.y - 150*s)
		件.字串(c, Vector2(p.x, y), t, 26, 白, "中", HORIZONTAL_ALIGNMENT_CENTER)


func 画地平方位(c: CanvasItem) -> void:
	"""桅杆视角：北东南西立在地平线上（相机高度水平方向 2 km 外的点）。"""
	var o := cam.global_position
	for b: int in 方位名:
		var a := deg_to_rad(b); var p := 投(o + Vector3(sin(a), 0, -cos(a))*2000.0)
		if not 屏内(p, 40*s): continue
		var r := Rect2(p.x - 24*s, p.y - 84*s, 48*s, 76*s)
		if not 空(r): continue                                          # 压到时刻 / 相机模式就不画（小地图上有北）
		占.append(r)
		件.线(c, Vector2(p.x, p.y - 36*s), Vector2(p.x, p.y - 12*s), 白, 3)
		件.字串(c, Vector2(p.x, p.y - 48*s), 方位名[b], 30, 白, "粗", HORIZONTAL_ALIGNMENT_CENTER)


func 杆框(pt: Vector3, 行1: String, 行2: String, 字号 := 26) -> Rect2:
	"""杆标() 的图标 + 两行字占的屏幕矩形。"""
	return 件.小标框(Vector2(pt.x, pt.y), 行1, 行2, 字号)


func 杆标(c: CanvasItem, g: Vector3, 高: float, 名: String, 图名: String, 行1: String, 行2: String, col := Color(-1, 0, 0), 字号 := 26, 抬 := 0.0, 出 := 1.0) -> Vector3:
	"""悬空小标（组件 件.小标）：地面点 g 上方 高 m 一个图标，竖线落到地面；行1（名字）写在图标上方，行2（距离）再上一行。
	抬：图标再往上挪的像素（避让）；出：出现进度。返回图标的屏幕位置。"""
	if col.r < 0.0: col = 白
	var pg := 投(g); var pt := 投(g + Vector3(0, 高, 0))
	if pt.z < 0.0: return pt
	pt.y -= 抬
	件.小标(c, pg, pt, 图名, 行1, 行2, col, 字号, 出)
	return pt


func 画兴趣点(c: CanvasItem) -> void:
	"""兴趣点小标：近点 400 m 内、远点都画；按距离从近到远，最多 8 个；挑战（复刻）画琥珀的拍照图标。"""
	var 表: Array = []
	for m: Dictionary in 标记:
		var d := Vector2(float(m["E"]) - 心.x, float(m["N"]) - 心.y).length()
		if d < 6.0 or (d > 400.0 and not m.get("远", false)): continue          # 就在脚下的不画（导览卡会出来）
		if 扫 and 扫.已揭(m): continue                                        # 扫描脉冲正在用动画画它
		表.append([d, m])
	表.sort_custom(func(a, b): return a[0] < b[0])
	for k in mini(表.size(), 8):
		var d: float = 表[k][0]; var m: Dictionary = 表[k][1]
		var E := float(m["E"]); var N := float(m["N"])
		var g := Vector3(E, 地高(E, -N), -N)
		var 挑 := bool(m.get("挑战", false)); var 发 := bool(m["已发现"])
		var 名 := String(m["名"]) if (发 or 挑) else "未发现"
		var pt := 投(g + Vector3(0, 2.2, 0))
		if not 屏内(pt, 20*s): continue
		var 抬 := -1.0
		for h: float in [0.0, 64.0, 128.0]:                                # 和已占的地方叠了：先把标往上抬（竖线拉长），抬两档还叠就降级
			var r := 杆框(Vector3(pt.x, pt.y - h*s, 1), 名, 距(d))
			if r.position.y > 40*s and 空(r): 抬 = h*s; 占.append(r); break
		if 抬 >= 0.0:
			杆标(c, g, 2.2, 名, "拍照" if 挑 else ("兴趣点_已发现" if 发 else "兴趣点_未发现"), 名, 距(d), 琥珀 if 挑 else 白, 26, 抬)
			continue
		var ri := Rect2(pt.x - 16*s, pt.y - 16*s, 32*s, 32*s)
		if 空(ri) and (d < 400.0 or 挑):                                    # 只画图标（远处的点叠了就不画）
			占.append(ri); 件.图标(c, "兴趣点_已发现" if 发 else "兴趣点_未发现", Vector2(pt.x, pt.y), 28, Color(白, 0.8))


func 画航点(c: CanvasItem) -> void:
	"""玩法 B：下一个航点和终点（航点上竖 1.4 m 的标杆）。"""
	var 路: PackedVector2Array = B态["路"]
	if 路.size() < 2: return
	var 段 := int(B态["段"]); var 执行: bool = B态["执行"]
	var 号 := [1] if 路.size() == 2 else [1, 路.size() - 1]
	for i: int in 号:
		var e := 路[i]; var g := Vector3(e.x, 地高(e.x, -e.y), -e.y)
		var d := e.distance_to(心)
		var n := (段 + i - 1 if 执行 else i)
		var 名 := "终点" if i == 路.size() - 1 else "航点 %d" % n
		var pt := 投(g + Vector3(0, 1.4, 0))
		if not 屏内(pt, 20*s): continue
		var pg := 投(g)
		if pg.z > 0.0: 件.线(c, Vector2(pg.x, pg.y), Vector2(pt.x, pt.y + 18*s), 活, 2); 件.点(c, Vector2(pg.x, pg.y), 4, 活)
		件.图标(c, "航点", Vector2(pt.x, pt.y), 32, 活)
		var t := "%s · %s" % [名, 距(d)]
		件.字串(c, Vector2(pt.x + 24*s, pt.y + 9*s), t, 24, 活, "中")
		占.append(Rect2(pt.x - 18*s, pt.y - 20*s, 50*s + 件.宽度(t, 24), 40*s))


func 画读数(c: CanvasItem, 桅: bool) -> void:
	"""车体读数牌：从桅杆头引出（桅杆视角印在画面下方）。速度（真车等效）、倍率；电量（玩法 B）或里程；机械臂。"""
	var a := 读淡
	var 数k := 令.缓(读淡)                                                # 动效：数字从 0 数到目标（随出现进度），行错开 0.2
	var a1 := a*clampf((读淡 - 0.2)/0.8, 0.0, 1.0); var a2 := a*clampf((读淡 - 0.4)/0.6, 0.0, 1.0)
	var 速字 := "—" if is_nan(速) else 令.速字(速*数k)
	var 倍字 := "" if is_nan(倍) else "×%s%s" % [数(倍), " 快进" if 自驾 else ""]
	var 电 := -1.0
	if not B态.is_empty(): 电 = float(B态["电量"])/maxf(float(B态["容量"]), 1.0)*100.0
	var 程 := "%s" % ("—" if is_nan(里程) else ("%.1f m" % (里程*数k) if 令.单位 == 0 else "%.1f ft" % (里程*数k*3.28084)))
	var o: Vector2; var 左 := false
	if 桅:
		o = Vector2(锚.size.x*0.5 + 250*s, 锚.size.y - 190*s)
	else:
		var m := 投(控.body*控.mast_local) if 控.get("mast_local") != null else Vector3(0, 0, -1)
		if not 屏内(m, 0.0): return
		左 = m.x + 480*s > 锚.size.x
		var sx := -1.0 if 左 else 1.0
		var k := Vector2(m.x + sx*150*s, m.y - 80*s); var e := Vector2(k.x + sx*320*s, k.y)
		件.线(c, Vector2(m.x, m.y), k, Color(白, a), 2); 件.线(c, k, e, Color(白, a), 2)
		件.点(c, Vector2(m.x, m.y), 3, Color(白, a))
		o = Vector2(minf(k.x, e.x) + 10*s, k.y)
	var 色 := Color(白, a)
	件.图标(c, "速度", o + Vector2(15, -37)*s, 30, 色)
	件.字串(c, o + Vector2(38, -24)*s, 速字, 28, 色, "中")
	if 倍字 != "": 件.字串(c, o + Vector2(52*s + 件.宽度(速字, 28), -24*s), 倍字, 28, 色, "粗")
	var y := 36.0
	if 电 >= 0.0:
		var 低: bool = float(B态["电量"]) < float(B态["下限"]) + 0.05*float(B态["容量"])
		件.图标(c, "电池", o + Vector2(15, y - 11)*s, 30, Color(琥珀 if 低 else 白, a1))
		件.字串(c, o + Vector2(38, y)*s, "%d %%" % roundi(电*数k), 26, Color(琥珀 if 低 else 白, a1), "中")
		件.字串(c, o + Vector2(52*s + 件.宽度("%d %%" % roundi(电*数k), 26), y*s), 程, 22, Color(白, 0.85*a1), "中")
	else:
		件.图标(c, "里程", o + Vector2(15, y - 11)*s, 30, Color(白, a1))
		件.字串(c, o + Vector2(38, y)*s, 程, 26, Color(白, a1), "中")
	if 臂文 != "":
		件.图标(c, "机械臂", o + Vector2(15, y + 30)*s, 30, Color(白, a2))
		件.字串(c, o + Vector2(38, y + 42)*s, 臂文, 24, Color(白, a2), "中")


func 画倾角(c: CanvasItem, 桅: bool) -> void:
	"""倾角弧：以车身为圆心，从竖直量到车身竖轴（屏幕上的真实夹角）。≥ 20° 琥珀三角「注意」，≥ 30° 红八边形「警告」（字慢闪 1 Hz）。"""
	var 色 := 红 if 倾 >= 倾红 else (琥珀 if 倾 >= 倾黄 else 白)
	var 呼 := 1.0                                                      # 警告（红）呼吸：0.55–1，一周期 令.时.呼；动效关 = 常亮（不再硬闪）
	if 倾 >= 倾红 and 令.动倍 > 0.0: 呼 = 0.775 + 0.225*cos(TAU*Time.get_ticks_msec()/1000.0/(令.时["呼"]*令.动倍 if 令.动倍 > 0.0 else 1.0))
	var a := 倾淡
	var 图名 := "倾角_警告" if 倾 >= 倾红 else "倾角_注意"
	var 坡 := "横坡" if absf(滚) >= absf(俯) else "纵坡"
	var 级 := "警告" if 倾 >= 倾红 else ("注意" if 倾 >= 倾黄 else "")
	if 桅:
		var W := 锚.size.x; var H := 锚.size.y; var r := deg_to_rad(-滚)   # 画面跟车身横滚；真地平线在画面上转 −横滚
		for sd: float in [-1.0, 1.0]:
			var o := Vector2(W*0.5 + sd*(W*0.5 - 220*s), H*0.5); var d := Vector2(cos(r), sin(r))*70*s
			件.线(c, o - d, o + d, Color(色, a), 5)
		if 倾 >= 倾黄:
			件.图标(c, 图名, Vector2(W*0.5, H*0.5 - 110*s), 60, Color(色, a))
			件.字串(c, Vector2(W*0.5, H*0.5 - 40*s), "倾角 %.0f° · %s" % [倾, ("超过 %.0f°" % 倾红) if 倾 >= 倾红 else 坡], 30, Color(色, a*呼), "粗", HORIZONTAL_ALIGNMENT_CENTER)
			件.字串(c, Vector2(W*0.5, H*0.5 - 6*s), 级, 24, Color(色, a), "中", HORIZONTAL_ALIGNMENT_CENTER)
		return
	var o3 := 车xf*Vector3(0, 1.0, 0)
	var C := 投(o3); var U := 投(o3 + Vector3.UP*2.0); var Bp := 投(o3 + 车xf.basis.y.normalized()*2.0)
	if C.z < 0.0 or U.z < 0.0 or Bp.z < 0.0: return
	var cc := Vector2(C.x, C.y)
	var R := clampf((Vector2(U.x, U.y) - cc).length()*1.25, 160*s, 560*s)
	var a0 := (Vector2(U.x, U.y) - cc).angle(); var a1 := (Vector2(Bp.x, Bp.y) - cc).angle()
	a1 = a0 + wrapf(a1 - a0, -PI, PI)
	var col := Color(色, a)
	件.线(c, cc + Vector2.from_angle(a0)*(R - 30*s), cc + Vector2.from_angle(a0)*(R + 10*s), col, 3)
	var 终 := a0 + (a1 - a0)*令.缓(a)                                    # 动效：弧从竖直基线画到车身倾斜的位置
	if absf(终 - a0) > 0.003: 件.弧(c, cc, R, minf(a0, 终), maxf(a0, 终), col, 4, 24)
	件.线(c, cc + Vector2.from_angle(a1)*(R - 30*s), cc + Vector2.from_angle(a1)*(R + 24*s), col, 5)
	var q := cc + Vector2.from_angle(a0)*(R + 10*s)
	var 右 := a1 > a0                                                  # 车身竖轴偏到哪边，字写在另一边
	var tx := q.x + (24*s if not 右 else -24*s)
	var 对 := HORIZONTAL_ALIGNMENT_LEFT if not 右 else HORIZONTAL_ALIGNMENT_RIGHT
	var 字色 := Color(色, a*呼)
	var t1 := "倾角 %.0f°" % 倾; var t2 := ("%s · %s" % [级, 坡]) if 级 != "" else 坡
	var ix := (tx + 22*s) if not 右 else (tx - 22*s)
	件.图标(c, 图名, Vector2(ix, q.y - 16*s), 36, col)
	var x2 := (tx + 48*s) if not 右 else (tx - 48*s)
	件.字串(c, Vector2(x2, q.y - 6*s), t1, 28, 字色, "粗", 对)
	件.字串(c, Vector2(x2, q.y + 24*s), t2, 22, col, "中", 对)


# ———————————————————— 地面箭头（地面.gd 的 Decal 池）
func 更箭() -> void:
	var 点s: Array = []
	var 源 := ""
	if not B态.is_empty() and (B态["路"] as PackedVector2Array).size() >= 2:
		源 = "B"
	elif 控 != null and 有车 and 弧淡 > 0.01 and not 自驾:
		源 = "弧"
	var sig: Array = [源]
	if 源 == "B":
		sig += [snappedf(心.x, 0.25), snappedf(心.y, 0.25), B签()]
	elif 源 == "弧":
		sig += [snappedf(车xf.origin.x, 0.02), snappedf(车xf.origin.z, 0.02), snappedf(车航, 0.003), snappedf(float(控.kappa), 0.002), bool(控.pivot), signf(float(控.v)) if absf(float(控.v)) > 1e-5 else signf(油), snappedf(弧淡, 0.05), snappedf(float(控.w), 0.01)]
	箭源 = 源
	if sig == 箭签: return
	箭签 = sig
	if 源 == "B": 点s = B箭()
	elif 源 == "弧": 点s = 弧箭()
	地.摆箭(点s)


func 坡度(x: float, z: float) -> float:
	"""地面坡度（°，1.5 m 基线）。"""
	var e := 0.75
	var gx := (地高(x + e, z) - 地高(x - e, z))/(2.0*e); var gz := (地高(x, z + e) - 地高(x, z - e))/(2.0*e)
	return rad_to_deg(atan(Vector2(gx, gz).length()))


func B签() -> int:
	var 路: PackedVector2Array = B态["路"]
	return 7*路.size() + 131*int(B态["段"]) + (5003 if B态["执行"] else 0) + (int(路[-1].x*10.0 + 路[-1].y*3.0) if not 路.is_empty() else 0)


func 弧箭() -> Array:
	"""手动驾驶的阿克曼预测弧（转动中心在中轮轴线上，同 控制.gd）：车前 3–10 m 每 0.9 m 一个人字；原地转：绕车 2 m 的四个人字。"""
	var out: Array = []
	var ps: float = float(控.psi)
	var f := Vector3(cos(ps), 0, sin(ps)); var l := Vector3(sin(ps), 0, -cos(ps))
	var p: Vector3 = 控.p
	if bool(控.pivot):
		var sg := -1.0 if float(控.w) < 0.0 else 1.0                       # 左转（w > 0）：俯视逆时针
		for k in 4:
			var a := 车航 + PI*0.25 + k*PI*0.5
			var d := Vector3(sin(a), 0, -cos(a)); var t := Vector3(cos(a), 0, sin(a))*(-sg)
			var w := p + d*3.05; w.y = 地高(w.x, w.z)
			out.append([w, t, 白, false, 弧淡])
		return out
	var kap: float = float(控.kappa); var zc: float = float(控.ZC)
	var dir := -1.0 if (float(控.v) < -1e-5 or (absf(float(控.v)) <= 1e-5 and 油 < -0.01)) else 1.0
	var s0 := 3.2; var L := 10.0; var sp := 0.9
	var sd := s0
	弧标.clear()
	while sd <= L + 1e-3:
		var sg := sd*dir
		var x := (1.0 - cos(kap*sg))/kap if absf(kap) > 1e-4 else 0.0
		var z := sin(kap*sg)/kap if absf(kap) > 1e-4 else sg
		var w := p + f*(zc + z) + l*x; w.y = 地高(w.x, w.z)
		var t := (f*cos(kap*sg) + l*sin(kap*sg))*dir
		var 淡 := 弧淡*(1.0 - smoothstep(L - 2.5, L + 0.5, sd))
		var 坡 := 坡度(w.x, w.z)                                           # 分段着色：前面的地面坡度 ≥ 20° 琥珀、≥ 30° 红
		out.append([w, t, 红 if 坡 >= 倾红 else (琥珀 if 坡 >= 倾黄 else 白), false, 淡])
		for m: float in [5.0, 10.0]:
			if absf(sd - m) < sp*0.5: 弧标.append([w + Vector3(0, 0.05, 0), "%d m" % int(m)])
		sd += sp
	return out


func B箭() -> Array:
	"""玩法 B 的航线：剩下的计划沿地面每 1 m 一个人字（第一段从下一个航点往回量，箭头钉在地上、不随车滑动），车前 3–45 m；
	白＝视觉里程计、虚线＝盲开、琥珀＝自主导航（同 风格.gd 方式色）。"""
	var 路: PackedVector2Array = B态["路"]; var 式: Array = B态.get("路式", [])
	var out: Array = []
	var 走 := 0.0                                                      # 从车沿路径量的距离
	for i in range(路.size() - 1):
		var a := 路[i]; var b := 路[i + 1]; var L := a.distance_to(b)
		if L < 1e-3: continue
		var u := (b - a)/L
		var m := int(式[i]) if i < 式.size() else int(B态.get("方式", 1))
		var col := 琥珀 if m == 2 else 活
		var t := fposmod(L, 1.0) if i == 0 else 0.5                          # 第一段：从 b 往回每 1 m
		while t < L:
			var dd := 走 + t
			if dd > 45.0: return out
			if dd >= 3.0 and Vector2(a + u*t).distance_to(心) >= 2.9:
				var e := a + u*t
				var w := Vector3(e.x, 地高(e.x, -e.y), -e.y)
				out.append([w, Vector3(u.x, 0, -u.y), col, m == 0, 1.0 - smoothstep(32.0, 45.0, dd)])
			t += 1.0
		走 += L
	return out


# ———————————————————— 小地图（圆，北朝上）
func 半() -> float:
	return 档位[档]


func 地到屏(E: float, N: float, ppm: float) -> Vector2:
	return 图.size*0.5 + Vector2(E - 心.x, 心.y - N)*ppm


func 更地图() -> void:
	var half := 半(); var ppm := 图.size.x/(2.0*half)
	var 键 := Vector4(snappedf(心.x, 0.5/ppm), snappedf(心.y, 0.5/ppm), half, 图.size.x)
	if 键 != 签图: 签图 = 键; 图.queue_redraw()
	轨迹层.transform = Transform2D(0.0, Vector2(ppm, ppm), 0.0, 图.size*0.5 + Vector2(-心.x, 心.y)*ppm)
	if 轨迹脏: 轨迹脏 = false; 轨迹层.queue_redraw()
	var b := Vector4(snappedf(心.x, 0.3/ppm), snappedf(心.y, 0.3/ppm), snappedf(车航, 0.01), half + 标记.size()*1e5 + (B签() if not B态.is_empty() else 0))
	if b != 签标: 签标 = b; 图标层.queue_redraw()


func 整(x: float) -> float:
	var e := pow(10.0, floor(log(x)/log(10.0))); var m := x/e
	return (5.0 if m >= 5.0 else (2.0 if m >= 2.0 else 1.0))*e


func 数(v: float) -> String:
	return str(roundi(v)) if is_equal_approx(v, roundf(v)) else "%.1f" % v


func 距(x: float) -> String:
	return 令.距字(x)                                                  # 公制 / 英制（设置页「单位」）


func _画底图() -> void:
	var sz := 图.size; var half := 半(); var ppm := sz.x/(2.0*half)
	var 远 := half > 高半*0.95
	var T: Texture2D = 底图远 if 远 else 底图高; var th := 远半 if 远 else 高半
	var sm := 图.material as ShaderMaterial
	sm.set_shader_parameter("mid", Vector3(0.522, 0.439, 0.388) if 远 else Vector3(0.518, 0.435, 0.388))
	sm.set_shader_parameter("k", 8.0 if 远 else 4.0)
	var W := float(T.get_width()); var H := float(T.get_height())
	var e0 := maxf(心.x - half, -th); var e1 := minf(心.x + half, th)
	var n0 := maxf(心.y - half, -th); var n1 := minf(心.y + half, th)
	if e1 > e0 and n1 > n0:
		var dst := Rect2((e0 - 心.x + half)*ppm, (心.y + half - n1)*ppm, (e1 - e0)*ppm, (n1 - n0)*ppm)
		var src := Rect2((e0/(2.0*th) + 0.5)*W, (0.5 - n1/(2.0*th))*H, (e1 - e0)/(2.0*th)*W, (n1 - n0)/(2.0*th)*H)
		图.draw_texture_rect_region(T, dst, src)


func _画轨迹() -> void:
	if 轨迹.size() < 2: return
	var ppm := 图.size.x/(2.0*半())
	轨迹层.draw_polyline(轨迹, Color(暗, 0.5), 4.5*s/ppm)
	轨迹层.draw_polyline(轨迹, Color(白, 0.8), 2.0*s/ppm)


func _画图标() -> void:
	var c := 图标层; var sz := 图.size; var R := sz.x*0.5; var o := sz*0.5; var ppm := sz.x/(2.0*半())
	var 内 := func(p: Vector2, m: float) -> bool: return p.distance_to(o) < R - m
	if not B态.is_empty():
		for z: Vector3 in B态["禁"]:
			var q: Vector2 = 地到屏(z.x, z.y, ppm)
			if 内.call(q, -z.z*ppm): c.draw_arc(q, z.z*ppm, 0, TAU, 32, 红, 1.6*s, true)
		var 路: PackedVector2Array = B态["路"]
		if 路.size() >= 2:
			var pts := PackedVector2Array()
			for e: Vector2 in 路:
				var q := 地到屏(e.x, e.y, ppm); pts.append(o + (q - o).limit_length(R - 2*s))
			件.折(c, pts, Color(琥珀 if int(B态.get("方式", -1)) == 2 else 活, 0.95), 2)
	for m: Dictionary in 标记:
		var q := 地到屏(float(m["E"]), float(m["N"]), ppm)
		if not 内.call(q, 12*s): continue
		件.图标(c, "拍照" if m.get("挑战", false) else ("兴趣点_已发现" if m["已发现"] else "兴趣点_未发现"), q, 20, 琥珀 if m.get("挑战", false) else 白)
	if 有车:                                                              # 车：实心箭头
		var p := 地到屏(车xf.origin.x, -车xf.origin.z, ppm); var d := Vector2(sin(车航), -cos(车航)); var n := Vector2(-d.y, d.x)
		var tri := PackedVector2Array([p + d*13*s, p - d*8*s + n*8*s, p - d*8*s - n*8*s])
		var t2 := tri.duplicate(); t2.append(tri[0])
		if 令.有活边: c.draw_polyline(t2, Color(暗, 0.45), 7*s, true); c.draw_polyline(t2, 令.边(活), 4*s, true)
		else: c.draw_polyline(t2, Color(暗, 0.6), 4*s, true)
		c.draw_colored_polygon(tri, 活)
	c.draw_arc(o, R - 1*s, 0, TAU, 96, Color(暗, 0.5), 4.2*s, true)
	c.draw_arc(o, R - 1*s, 0, TAU, 96, Color(白, 0.9), 2*s, true)
	件.线(c, Vector2(o.x, -4*s), Vector2(o.x, 10*s), 白, 3)
	件.字串(c, Vector2(o.x, -12*s), "北", 20, 白, "粗", HORIZONTAL_ALIGNMENT_CENTER)


func 找石(c: Node) -> Vector4:
	"""自测用：车附近直径 0.4–1.6 m、高 0.2–0.7 m 的石块里最高的 → (x, 直径, z, 高)；没有 → w = 0。
	（控制.rk 是固定石块 + 车周围的实时撒石，按车的位置取。）"""
	var rk: PackedFloat32Array = c.get("rk")
	var best := Vector4.ZERO; var hm := 0.0; var Hmax := 0.0
	for n in rk.size()/5:
		var o := n*5; var a := rk[o + 2]; var H := rk[o + 4]
		Hmax = maxf(Hmax, H)
		if a >= 0.2 and a <= 0.8 and H >= 0.2 and H <= 0.7 and H > hm: hm = H; best = Vector4(rk[o], 2.0*a, rk[o + 1], H)
	print("[界面] 找石：控制.rk %d 块，最高 %.2f m，挑中 %s" % [rk.size()/5, Hmax, str(best)])
	return best


# ———————————————————— 自测（--界面测试[=目录]，界面/测试.sh）：同 v2 的七张 + 完整档 + 兴趣点，量开销
func 自测(目录: String) -> void:
	if 目录 == "": 目录 = ProjectSettings.globalize_path("res://界面/截图")
	DirAccess.make_dir_recursive_absolute(目录)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	print("[界面] 丙 自测 %s，s = %.2f，控制模块 %s" % [str(尺寸), s, "有" if P.has_node("控制") else "无"])
	await 等(2.5)
	var c: Node = P.get_node_or_null("控制")
	if c:
		print("[界面] 车层 %d 件（Decal 不投到车上）" % 地.层件)
		c.set("rate_i", 5)
		c.call("set_mode", "跟车")
		c.set("自动", {"油": 1.0}); await 等(3.0); await 存(目录, "1_直行"); await 对比量("1 直行（13:07 亮沙地）")
		件.记字 = true; 件.字记.clear(); 签图.x = INF; 签屏 = ""; await 等(0.6); 件.记字 = false          # 字数统计（规范 §1.4）：常态跟车画出的每一串字
		var 唯: Dictionary = {}
		for q in 件.字记: 唯[q] = true
		var 字总 := 0; var 英: Array = []
		for q in 唯: 字总 += 件.字数(q); 英.append_array(件.英文标签(q))
		print("[界面] %s 常态跟车字数 %d（预算 6）：%s" % ["✓" if 字总 <= 6 else "✗", 字总, str(唯.keys())])
		print("[界面] %s 常态跟车没有英文标签 %s" % ["✓" if 英.is_empty() else "✗", str(英)])
		c.set("自动", {"油": 1.0, "转": 1.0}); await 等(2.5); await 存(目录, "2_阿克曼左弧")
		c.set("自动", {"原地": -1.0}); await 等(3.0); await 存(目录, "3_原地右转")
		c.set("自动", {})
		var sp := 找坡()
		if sp.z > 0.0:
			print("[界面] 斜坡 E %.1f N %.1f，坡度 %.1f°" % [sp.x, -sp.y, rad_to_deg(sp.z)])
			c.call("teleport", Vector3(sp.x, 0, sp.y), sp.w); c.set("自动", {"油": 0.4})
			await 等(1.2); c.set("自动", {}); await 等(1.0)
		await 存(目录, "4_斜坡倾角")
		c.call("set_mode", "桅杆"); c.set("自动", {"油": 1.0, "转": -1.0}); await 等(1.0); await 存(目录, "5_桅杆_右弧"); await 对比量("5 桅杆（天空 / 地平线）")
		c.set("自动", {})
		帮助(true); await 等(0.4); await 存(目录, "6_帮助"); 帮助(false)
		c.call("set_mode", "俯视"); 档 = 5; 轨迹脏 = true; 签图.x = INF; 时分 = 600.0; P.set_time_f(600.0); await 等(1.2); await 存(目录, "7_俯视_远图_上午")
		档 = 1; 轨迹脏 = true; 签图.x = INF; c.call("set_mode", "跟车")
		c.call("teleport", Vector3(c.park.origin.x, 0, c.park.origin.z), atan2(c.park.basis.z.z, c.park.basis.z.x))
		设档(2); await 等(1.5); await 存(目录, "8_完整档"); await 对比量("8 完整档"); 设档(1)
		var 近 := 最近兴趣点()
		if not 近.is_empty():
			var E := float(近["E"]); var N := float(近["N"]); var x := E + 14.0; var z := -N + 14.0
			var 俯0: float = c.get("c_pitch"); c.set("c_pitch", 0.10)          # 跟车相机放平一点：20 m 外的小标在画面里
			c.call("teleport", Vector3(x, 0, z), atan2(-N - z, E - x)); await 等(1.5)
			print("[界面] 兴趣点 %s（E %.0f N %.0f），离车 %.1f m，小标屏幕 %s" % [近["名"], E, N, Vector2(E - 心.x, N - 心.y).length(), str(锚屏(E, N))])
			await 存(目录, "9_兴趣点"); await 对比量("9 兴趣点小标"); c.set("c_pitch", 俯0)
		var 石 := 找石(c)                                                 # 罗盘环压在一块石头上：石块挡住环（新）/ 环投到石块上（旧）
		if 石.w > 0.0:
			var psi: float = c.get("psi"); var l := Vector3(sin(psi), 0, -cos(psi))
			c.call("teleport", Vector3(石.x, 0, 石.z) + l*地面脚本.环R, psi); 设档(2); await 等(1.5)
			print("[界面] 石块 直径 %.2f m、高 %.2f m，在环的右侧" % [石.y, 石.w])
			await 存(目录, "10_石块挡环")
			设档(1)
		c.call("teleport", Vector3(c.park.origin.x, 0, c.park.origin.z), atan2(c.park.basis.z.z, c.park.basis.z.x)); await 等(1.0)
	else:
		await 存(目录, "1_自由飞行")
	await 等(1.0)
	var r0 := [0.0, 0.0, 0.0, 0.0]; var r1 := [0.0, 0.0, 0.0, 0.0]; var r2 := [0.0, 0.0, 0.0, 0.0]
	var 差s: Array[float] = []; var 帧差s: Array[float] = []; var 屏差s: Array[float] = []
	if c: c.set("自动", {"油": 1.0, "转": 0.5}); c.set("rate_i", 3)       # 开着车量：预测弧、读数牌都在
	for k in 4:
		var a: Array = await 量(false); var b: Array = await 量(true); var q: Array = await 量(true, false)
		print("[界面]   第 %d 轮 GPU 关 %.3f / 开 %.3f / 只屏幕 %.3f ms，帧 关 %.2f / 开 %.2f ms" % [k + 1, a[1], b[1], q[1], a[0], b[0]])
		for i in 4: r0[i] += a[i]/4.0; r1[i] += b[i]/4.0; r2[i] += q[i]/4.0
		差s.append(b[1] - a[1]); 帧差s.append(b[0] - a[0]); 屏差s.append(q[1] - a[1])
	if c: c.set("自动", {})
	地.visible = visible
	差s.sort(); 帧差s.sort(); 屏差s.sort()
	print("[界面] GPU 差 各轮中位数 %+.3f ms（其中屏幕和锚定字 %+.3f，地面 Decal 约 %+.3f）；帧时间差 中位数 %+.3f ms" % [0.5*(差s[1] + 差s[2]), 0.5*(屏差s[1] + 屏差s[2]), 0.5*(差s[1] + 差s[2]) - 0.5*(屏差s[1] + 屏差s[2]), 0.5*(帧差s[1] + 帧差s[2])])
	print("[界面] 开销 界面关：帧 %.2f ms，GPU %.3f ms，CPU 渲染 %.3f ms" % r0.slice(0, 3))
	print("[界面] 开销 界面开：帧 %.2f ms，GPU %.3f ms，CPU 渲染 %.3f ms；界面脚本 %.4f ms/帧" % r1)
	print("[界面] 差：GPU %+.3f ms，CPU 渲染 %+.3f ms，箭头 %d 个" % [r1[1] - r0[1], r1[2] - r0[2], 地.用箭])
	print("[界面] 自测完")
	get_tree().quit()


func 最近兴趣点() -> Dictionary:
	var best := {}; var bd := INF
	for m: Dictionary in 标记:
		if m.get("远", false) or m.get("挑战", false): continue
		var d := Vector2(float(m["E"]) - 心.x, float(m["N"]) - 心.y).length()
		if d > 30.0 and d < bd: bd = d; best = m
	return best


func 等(t: float) -> void:
	await get_tree().create_timer(t).timeout


func 找坡() -> Vector4:
	"""停车位 40 m 内 2 m 一格找坡度最大（≤ 24°）的地方 → (x, z, 坡度 rad, 车头 ψ)（同 v2）。"""
	if P.lod == null: return Vector4(0, 0, -1, 0)
	var best := Vector4(0, 0, -1, 0); var e := 1.5
	for i in range(-20, 21):
		for j in range(-20, 21):
			var x := i*2.0; var z := j*2.0
			var gx: float = (P.lod.h_cpu(x + e, z, 0) - P.lod.h_cpu(x - e, z, 0))/(2.0*e)
			var gz: float = (P.lod.h_cpu(x, z + e, 0) - P.lod.h_cpu(x, z - e, 0))/(2.0*e)
			var sl := atan(Vector2(gx, gz).length())
			if sl > best.z and sl < deg_to_rad(24.0): best = Vector4(x, z, sl, atan2(gz, gx) + PI*0.25)
	return best


func 量(on: bool, 地显 := true) -> Array:
	visible = on
	if on and not 地显: 地.visible = false                             # 只量屏幕层（地面 Decal 藏起来）
	await 等(0.4)
	var rid := get_viewport().get_viewport_rid()
	var n := 0; var fs := 0.0; var gs := 0.0; var cs := 0.0; var t0 := Time.get_ticks_usec(); var last := t0
	var 界0 := 界总; var 数0 := 帧总
	while Time.get_ticks_usec() - t0 < 1500000:
		await get_tree().process_frame
		var now := Time.get_ticks_usec(); fs += (now - last)/1000.0; last = now
		gs += RenderingServer.viewport_get_measured_render_time_gpu(rid); cs += RenderingServer.viewport_get_measured_render_time_cpu(rid); n += 1
	return [fs/n, gs/n, cs/n, (界总 - 界0)/maxf(1.0, float(帧总 - 数0))]


func 对比量(名: String) -> void:
	"""自测（规范 §5 新量法）：当前画面里每串字对自己的描边（紧贴笔画外 1–3 px）的对比度；正文（≥ 22 px）要 ≥ 7，次要要 ≥ 4.5；描边宽 ≥ max(2, 字号 × 8 %) px。同时打旧量法数字（背景 p95）作对照。"""
	件.记字 = true; 件.字框记.clear(); 签屏 = ""; 签图.x = INF; await 等(0.5); await RenderingServer.frame_post_draw; 件.记字 = false
	var 图 := get_viewport().get_texture().get_image(); var 缩 := float(图.get_width())/屏.size.x
	var 新s: Array = []; var 旧s: Array = []; var 坏: Array = []; var 窄: Array = []
	var 看 := {}; var 位串 := {}; var 动 := 0                                   # 同一个位置画过不同的字（数字在数 / 在变）：截图里是哪一版不知道，不量，计数
	for q: Array in 件.字框记:
		var pk := Vector2i(roundi((q[4] as Vector2).x/6.0), roundi((q[4] as Vector2).y/6.0))
		if not 位串.has(pk): 位串[pk] = {}
		位串[pk][q[0]] = true
	for q: Array in 件.字框记:
		var pk := Vector2i(roundi((q[4] as Vector2).x/6.0), roundi((q[4] as Vector2).y/6.0))
		if (位串[pk] as Dictionary).size() > 1:
			if not 看.has(q[0]): 看[q[0]] = true; 动 += 1
			continue
		var col: Color = q[2]; var sz: float = q[3]; var r: Rect2 = q[1]
		if col.a < 0.5 or r.size.x < 12.0 or 看.has(q[0]): continue
		看[q[0]] = true
		var 膜: Image = await 件.字膜(q[0], sz, q[5])
		var d := 件.描边测(图, 膜, 件.膜原点(q), col, r)
		if d.is_empty(): continue
		var 阈 := 7.0 if sz >= 22.0 else 4.5
		新s.append(d["对比"]); 旧s.append(d["旧"])
		if d["对比"] < 阈: 坏.append("%s %.1f" % [q[0], d["对比"]])
		var 要 := maxf(2.0, 0.08*sz)*s
		if d["宽"] < 要 - 0.01: 窄.append("%s %.0f<%.1f" % [q[0], d["宽"], 要])
		print("[界面]   字「%s」%.0f px：新法 %.1f:1 描边宽 %.0f px｜旧法 %.1f:1" % [q[0], sz, d["对比"], d["宽"], d["旧"]])
	新s.sort(); 旧s.sort()
	if 新s.is_empty(): print("[界面] ✗ 对比度 %s：没量到字" % 名); return
	print("[界面] %s 对比度 %s：新法 最低 %.1f 中位 %.1f（%d 串）｜旧法 最低 %.1f 中位 %.1f｜动态数字不量 %d 串｜不达标 %s" % ["✓" if 坏.is_empty() else "✗", 名, 新s[0], 新s[新s.size()/2], 新s.size(), 旧s[0], 旧s[旧s.size()/2], 动, str(坏)])
	print("[界面] %s 描边宽 %s ≥ max(2 px, 字号 × 8 %%)：%s" % ["✓" if 窄.is_empty() else "✗", 名, str(窄)])


func 存(目录: String, 名: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(目录.path_join(名 + ".png"))
	print("[界面] 截图 %s ｜ 模式 %s 航向 %.1f° 俯仰 %+.1f° 横滚 %+.1f° 倾角 %.1f° 速 %s 箭头 %d 档 %s" % [名, 模式, fposmod(rad_to_deg(车航), 360.0), 俯, 滚, 倾, str(速), 地.用箭, 档名[显档]])
