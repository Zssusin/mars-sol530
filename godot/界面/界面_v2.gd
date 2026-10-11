# 界面 v2（HUD，仪表式，2026-10-05 起；10-08 起默认换成 v3「丙」界面.gd，这一版留着用 --界面=旧 做 A/B 对比）：实景.gd 加载为子节点「界面」；有没有 控制/控制.gd 都能用。
#   仪表直接用 _draw() 画矢量细线叠在画面上（不用卡片、表格、标签栏、网页滑条）。可读性（2026-10-08，界面调研 P0）：
#     不加成片的暗底（试过柔边暗底，用户嫌像烟熏，2026-10-08 删了），可读性全靠描边：
#     文字双描边（宽淡外圈 + 加厚的深色内圈），线条两道暗影（宽淡 + 窄深），线宽 1440p ≥ 2 px；字号以 1440p 为准主读数 ≥ 24 px、标签 ≥ 20 px；
#     小地图暗框 + 底图压暗；倾角告警除颜色外加形状和文字（琥珀 ▲ CAUTION，红 ■ WARNING 1 Hz 慢闪）。
#     顶部居中 航向带（5° 刻度、30° 标数、☉ 太阳方位、◇ 停车点（站点原点）方位、▽ 相机朝向、相机模式一行）；
#     中下 姿态仪（地平线 + 俯仰梯 + 横滚刻度，下弧＝车身总倾角，琥珀 ≥ 20°、红 ≥ 30°，阈值是本游戏的设定）；
#     左下 六轮俯视示意（角轮按各自转角转、轮旁竖条＝悬架升降 ±12 cm、阿克曼预测弧 / 原地转箭头）+ 速度弧表 + 里程；
#     右上 太阳弧表（LTST、弧上小点＝预算天空时刻，可点）；右下 小地图（暗框、四角刻度、V 形车标）；左上 性能小字（F3 或 --性能=1）。
#   参照：Orion / 航天飞机 MEDS 玻璃座舱的 ADI 与航向带、JPL RSVP/HyperDrive 的车体姿态与车轮表达（见 素材来源.md）。
#   颜色：浅暖白为主；琥珀＝注意，NASA 红只用于警告。数字等宽。中文只在帮助层。不用 NASA / JPL 任何标志。
# 键：H 显隐界面、F1 帮助、M 小地图换档（Shift+M 反向；鼠标放开时地图上滚轮也行）、F3 性能（默认关）、[ ] 上 / 下一个天空时刻。
# 玩法模块（玩法/玩法.gd，有就用）：航向带和小地图上画它给的兴趣点标记（标记()），帮助页加它的按键（按键()）。
#   玩法 B（sol 规划，玩法/sol.gd 的 B状态()）：速度表旁的能量条、太阳弧上的驾驶时窗和预计结束、小地图上的计划路径和禁行区、
#   六轮示意里自驾时阿克曼预测弧延伸成接下来的计划路径、倍率后面加 FFWD。都只用描边，不加暗底。
# 自测：godot --path godot -- --界面测试[=目录]   直行 / 阿克曼 / 原地转 / 斜坡 / 桅杆 / 帮助 各截一张、量开销后退出（界面/测试.sh）。
#   日志里打印各仪表区域（「[界面] 区域」），界面/对比度.py 拿它和截图量文字对周围的对比度。
# 开销：每个仪表一个 CanvasItem，输入变了（按显示精度取整后）才重画；控制模块状态 15 Hz 取一次；不每帧新建节点或纹理。
extends CanvasLayer

var 素材: String = 环境.外置("界面/素材/")         # 字体（目录有 .gdignore，导出包里在 data/界面/素材/）
const LAT0 := 18.45864728                      # ENU 原点（站 26_1222）纬度、东经，同 57_实景重建.py
const LON0 := 77.40592495
const E0 := -2523.168                           # 原点高程（m，相对大地水准面）；地面数据已减去曲率下沉 d²/2R
const R_MARS := 3396190.0                       # 57 的 enu_to_lonlat 用这个半径（底图按它投影，这里跟着用）
const SOL := 530
const 尘τ := 0.67                              # 当天 Mastcam-Z 测的尘埃光学厚度
const 档位 := [20.0, 50.0, 150.0, 500.0, 1500.0, 5000.0, 20000.0]   # 小地图半宽（m）；> HiRISE 范围换 CTX
const 倾黄 := 20.0                              # 车身倾角提示阈值（本游戏的设定，不是真车参数）
const 倾红 := 30.0
const 升降限 := 0.12                            # 控制模块的上下补偿限幅（m）
const 真速 := 0.042                             # 控制模块的真车直行速度（m/s），速度表上标一道
const 模式英 := {"自由": "自由", "跟车": "跟车", "桅杆": "桅杆", "俯视": "俯视"}      # 界面 5：不再中英对照，只写中文
const 模式序 := ["自由", "跟车", "桅杆", "俯视"]

const 白 := Color(0.97, 0.95, 0.91)            # 浅暖白
const 灰 := Color(0.84, 0.81, 0.76)
const 淡 := Color(0.70, 0.67, 0.63)
const 琥珀 := Color(1.0, 0.72, 0.22)
const 红 := Color(0.93, 0.25, 0.20)             # NASA 红（PMS 179 屏幕近似），只做警告
const 日色 := Color(1.0, 0.92, 0.74)
const 影a := 0.80                               # 线条窄暗影的不透明度（亮天空上也要看得清；外面还有一道宽淡的）
const 暗色 := Color(0.04, 0.03, 0.025)           # 暗角的颜色（暖黑）

var P: Node                                     # 实景.gd
var 控: Node = null                             # 控制.gd（可能没有）
var 已连 := false
var s := 1.0                                    # 以 1440 高为 1
var 线宽 := 2.0
var 尺寸 := Vector2i.ZERO
var 字 := {}
var 根: Control
var 暗角: Control
var 航向: Control
var 姿态: Control
var 车轮: Control
var 太阳: Control
var 角标: Control
var 图: Control
var 轨迹层: Node2D
var 标层: Control
var 图注: Control
var 帮助层: ColorRect
var 帮助格: VBoxContainer
var 底图高: Texture2D
var 底图远: Texture2D
var 高半 := 1000.0
var 远半 := 40000.0
var 档 := 1
var 天时: Array = []                            # 天空时刻（分钟，升序）
var 时分 := 0.0
var 上次ltst := ""
var 悬停 := -1                                   # 太阳表上鼠标指着的天空点
var 累 := 0.0
var 采累 := 0.0
var 模式 := ""
var 提示时 := 0.0
var 按键: Array = []
# 车轮（rover_rig.json，模型坐标 x 左、z 前）
var 轮心: Array[Vector2] = []
var 轮角: Array[bool] = []
var 轮r := 0.263
var 轮w := 0.336
var 轮转 := PackedFloat32Array([0, 0, 0, 0, 0, 0])     # rad，左正，按 rig 顺序
var 轮升 := PackedFloat32Array([0, 0, 0, 0, 0, 0])     # m
var 原地 := false
var 速 := NAN                                   # 真车等效 m/s
var 倍 := NAN
var 里程 := NAN
var 油 := NAN
var 臂文 := ""; var 臂文画 := "~"                    # 机械臂读数（控制.gd 状态()["机械臂"]），画在速度表下面
# 每帧位姿
var 车E := 0.0
var 车N := 0.0
var 车航 := 0.0
var 航显 := 0.0                                 # 航向带显示值（平滑）
var 俯 := 0.0
var 转速 := 0.0                                 # 航向变化率（°/s，右转为正，平滑）
var 旧航 := 0.0
var 滚 := 0.0
var 倾 := 0.0
var 有车 := false
var 机E := 0.0
var 机N := 0.0
var 机航 := 0.0
var 机视 := 1.0
var 机足 := Vector2.ZERO                         # 近似朝下的相机：地面足迹半宽、半高（m）；否则 0
var 日方 := 0.0                                 # 太阳方位、高度（°）
var 日高 := 0.0
var 心 := Vector2.ZERO
var 轨迹 := PackedVector2Array()               # (E, −N)，直接当画布坐标
var 轨迹源 := ""
var 轨迹脏 := true
# 重画签名
var 签航 := Vector4(INF, 0, 0, 0)
var 签姿 := Vector3(INF, 0, 0)
var 签轮 := PackedFloat64Array()
var 签图 := Vector4(INF, 0, 0, 0)
var 签日 := Vector3(INF, 0, 0)
var 签标A := Vector4.ZERO
var 签标B := Vector4.ZERO
var 签记 := Vector3(INF, 0, 0)                      # 兴趣点标记：车位（0.5 m）+ 玩法模块的版本
var 签B轮 := -2.0
var 标记: Array = []                               # 玩法模块给的兴趣点标记 [{E, N, 名, 已发现, 远, 挑战?}]
var B态 := {}                                     # 玩法 B 的状态（sol.gd B状态()；没有 B 或不在 B 里时为空）
var 自驾 := false
var 路局部 := PackedVector2Array()                 # 自驾时接下来的计划路径（车体坐标：x 左、z 前，m）
var 标版 := 0
# 复用缓冲
var 楔 := PackedVector2Array()
var 框 := PackedVector2Array()
var 弧点 := PackedVector2Array()
var 轮框 := PackedVector2Array()
# 性能
var 测 := false
var 帧和 := 0.0
var gpu和 := 0.0
var 界和 := 0.0
var 帧数 := 0
var 窗 := 0.0
var 性能字 := ""
var 界总 := 0.0                                  # 界面脚本累计耗时（ms）与帧数，自测用，不清零
var 帧总 := 0


func _ready() -> void:
	P = get_parent()
	layer = 10
	载字()
	var T: Dictionary = P.J["tex"]
	底图高 = load(环境.资源目录() + T["albedo_hirise"]["file"]); 高半 = T["albedo_hirise"]["half"]   # 和地面材质同一份资源，不多占显存
	底图远 = load(环境.资源目录() + T["albedo_ctx"]["file"]); 远半 = T["albedo_ctx"]["half"]
	for k in P.J["sky"].keys(): 天时.append(P.minutes(k))
	天时.sort()
	上次ltst = P.ltst; 时分 = P.minutes(P.ltst)
	读轮()
	楔.resize(8); 框.resize(5); 弧点.resize(13); 轮框.resize(5)
	搭()
	get_viewport().size_changed.connect(func(): call_deferred("搭"))
	性能开(P.args.get("性能", "0") == "1")                       # 默认关；F3 或 --性能=1 打开（界面调研 §2.3）
	if P.args.has("界面测试"): 自测(String(P.args["界面测试"]))


func 载字() -> void:
	var cjk := FontFile.new(); cjk.load_dynamic_font(素材 + "NotoSansSC-VF.ttf")
	for k in [["正", "Inter-Regular.ttf"], ["中", "Inter-Medium.ttf"], ["粗", "Inter-SemiBold.ttf"]]:
		var f := FontFile.new(); f.load_dynamic_font(素材 + k[1])
		var fb: Array[Font] = [cjk]; f.fallbacks = fb
		字[k[0]] = f
	for k in [["等", "IBMPlexMono-Regular.ttf"], ["等中", "IBMPlexMono-Medium.ttf"]]:
		var f := FontFile.new(); f.load_dynamic_font(素材 + k[1])
		var fb: Array[Font] = [字["正"], cjk]; f.fallbacks = fb               # τ、°、☉ 等从后备里取
		字[k[0]] = f
	var sp := FontVariation.new(); sp.base_font = 字["中"]; sp.spacing_glyph = 2   # 英文小标签：加字距
	字["标"] = sp


func 读轮() -> void:
	var p := String(P.D) + "rover_rig.json"
	if FileAccess.file_exists(p):
		var R: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(p))
		for w in R["wheels"]:
			轮心.append(Vector2(w["c"][0], w["c"][2])); 轮角.append(bool(w["corner"])); 轮r = w["r"]; 轮w = w["w"]
	else:                                                                # 没量过：用毅力号的大致轮位
		for q in [[1.06, 1.09, true], [1.18, -0.09, false], [1.06, -1.16, true], [-1.06, 1.09, true], [-1.18, -0.09, false], [-1.06, -1.16, true]]:
			轮心.append(Vector2(q[0], q[1])); 轮角.append(q[2])


# ———————————————————— 画线、画字（都带深色描边，叠在亮的火星地面 / 天空上也看得清）
func 线(c: CanvasItem, a: Vector2, b: Vector2, col: Color, w := -1.0) -> void:
	if w < 0.0: w = 线宽
	c.draw_line(a, b, Color(0, 0, 0, 0.30*col.a), w + 7.0*s, true)
	c.draw_line(a, b, Color(0, 0, 0, 影a*col.a), w + 3.0*s, true)
	c.draw_line(a, b, col, w, true)


func 折(c: CanvasItem, pts: PackedVector2Array, col: Color, w := -1.0) -> void:
	if w < 0.0: w = 线宽
	c.draw_polyline(pts, Color(0, 0, 0, 0.30*col.a), w + 7.0*s, true)
	c.draw_polyline(pts, Color(0, 0, 0, 影a*col.a), w + 3.0*s, true)
	c.draw_polyline(pts, col, w, true)


func 弧(c: CanvasItem, o: Vector2, r: float, a0: float, a1: float, col: Color, w := -1.0, n := 32) -> void:
	if w < 0.0: w = 线宽
	c.draw_arc(o, r, a0, a1, n, Color(0, 0, 0, 0.30*col.a), w + 7.0*s, true)
	c.draw_arc(o, r, a0, a1, n, Color(0, 0, 0, 影a*col.a), w + 3.0*s, true)
	c.draw_arc(o, r, a0, a1, n, col, w, true)


func 字串(c: CanvasItem, p: Vector2, t: String, size: float, col: Color, fk := "等中", 对齐 := HORIZONTAL_ALIGNMENT_LEFT) -> void:
	"""p：左对齐时为左端基线；居中时为中点基线；右对齐时为右端基线。"""
	var f: Font = 字[fk]; var px := int(round(size*s)); var W := 900.0*s
	var x := p.x if 对齐 == HORIZONTAL_ALIGNMENT_LEFT else (p.x - W*0.5 if 对齐 == HORIZONTAL_ALIGNMENT_CENTER else p.x - W)
	var q := Vector2(x, p.y); var wd := -1.0 if 对齐 == HORIZONTAL_ALIGNMENT_LEFT else W
	c.draw_string_outline(f, q, t, 对齐, wd, px, maxi(7, int(round(14*s))), Color(0.03, 0.02, 0.015, 0.40*col.a))   # 双描边：宽淡外圈
	c.draw_string_outline(f, q, t, 对齐, wd, px, maxi(4, int(round(8*s))), Color(0.03, 0.02, 0.015, 0.90*col.a))    # 加厚的深色内圈
	c.draw_string(f, q, t, 对齐, wd, px, col)


func 方(a: float) -> Vector2:
	return Vector2(cos(a), sin(a))


# ———————————————————— 搭界面（窗口大小变了重搭；状态在脚本变量里，不丢）
func 件(pos: Vector2, sz: Vector2, f: Callable, 鼠 := false) -> Control:
	var c := Control.new(); c.position = pos; c.size = sz
	c.mouse_filter = Control.MOUSE_FILTER_STOP if 鼠 else Control.MOUSE_FILTER_IGNORE
	c.draw.connect(f); 根.add_child(c)
	return c


func 搭() -> void:
	var vs := get_viewport().get_visible_rect().size
	if Vector2i(vs) == 尺寸 and 根: return
	尺寸 = Vector2i(vs)
	var 显 := true; var 帮 := false
	if 根: 显 = 根.visible; 帮 = 帮助层.visible; 根.queue_free()
	s = clampf(vs.y/1440.0, 0.8, 3.0); 线宽 = maxf(1.5, 2.6*s)          # 1080 高用 0.8：小字不至于太小；线宽 ×0.8 在 1440p 也 ≥ 2 px
	var W := vs.x; var H := vs.y
	根 = Control.new(); 根.name = "根"; 根.set_anchors_preset(Control.PRESET_FULL_RECT); 根.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var th := Theme.new(); th.default_font = 字["正"]; th.default_font_size = int(20*s); 根.theme = th
	add_child(根)
	暗角 = 件(Vector2.ZERO, vs, _画暗角)
	航向 = 件(Vector2((W - 1100*s)*0.5, 10*s), Vector2(1100, 200)*s, _画航向)
	姿态 = 件(Vector2((W - 360*s)*0.5, H - 330*s), Vector2(360, 320)*s, _画姿态)
	车轮 = 件(Vector2(26*s, H - 372*s), Vector2(640, 356)*s, _画车轮)
	太阳 = 件(Vector2(W - 400*s, 6*s), Vector2(380, 260)*s, _画太阳, true)
	太阳.gui_input.connect(_太阳输入); 太阳.mouse_exited.connect(func(): if 悬停 != -1: 悬停 = -1; 太阳.queue_redraw())
	角标 = 件(Vector2(30*s, 22*s), Vector2(900, 100)*s, _画角标)
	搭地图(Vector2(W - 456*s, H - 530*s), 420*s)
	搭帮助()
	根.visible = 显; 帮助层.visible = 帮
	轨迹脏 = true; 签航.x = INF; 签姿.x = INF; 签轮.clear(); 签图.x = INF


func 搭地图(pos: Vector2, L: float) -> void:
	图 = Control.new(); 图.position = pos; 图.size = Vector2(L, L); 图.clip_contents = true
	图.mouse_filter = Control.MOUSE_FILTER_STOP; 图.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	图.draw.connect(_画底图); 图.gui_input.connect(_图输入)
	var sh := Shader.new(); sh.code = 图码
	var sm := ShaderMaterial.new(); sm.shader = sh
	sm.set_shader_parameter("base", Vector3(0.55, 0.41, 0.32)*0.74); sm.set_shader_parameter("size", Vector2(L, L))   # 底图压暗 26%（P0 #4）
	图.material = sm
	根.add_child(图)
	轨迹层 = Node2D.new(); 轨迹层.draw.connect(_画轨迹); 图.add_child(轨迹层)
	标层 = Control.new(); 标层.set_anchors_preset(Control.PRESET_FULL_RECT); 标层.mouse_filter = Control.MOUSE_FILTER_IGNORE
	标层.draw.connect(_画标记); 图.add_child(标层)
	图注 = 件(pos + Vector2(-160*s, L + 4*s), Vector2(L + 160*s, 130*s), _画图注)


const 图码 := """shader_type canvas_item;
// 小地图：反照率图反差很小（1–99% 只差 ±0.04），按图拉伸（再压暗、加一点反差）；方形，只在最外 3% 淡出，外面有暗框
uniform vec3 mid; uniform vec3 base; uniform float k = 4.0; uniform vec2 size = vec2(400.0);
varying vec2 lp;
void vertex() { lp = VERTEX; }
void fragment() {
	COLOR.rgb = clamp(base + (COLOR.rgb - mid)*k*1.2, 0.0, 1.0);      // COLOR 进来已经乘过纹理
	vec2 e = abs(lp/size*2.0 - 1.0);
	COLOR.a *= 0.96*(1.0 - smoothstep(0.97, 1.0, max(e.x, e.y)));
}
"""


func 搭帮助() -> void:
	帮助层 = ColorRect.new(); 帮助层.color = Color(0, 0, 0, 0.5); 帮助层.set_anchors_preset(Control.PRESET_FULL_RECT)
	帮助层.mouse_filter = Control.MOUSE_FILTER_STOP                # 帮助开着时挡住鼠标（相机不跟着转）
	根.add_child(帮助层)
	var cc := CenterContainer.new(); cc.set_anchors_preset(Control.PRESET_FULL_RECT); cc.mouse_filter = Control.MOUSE_FILTER_IGNORE; 帮助层.add_child(cc)
	var pc := PanelContainer.new(); pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new(); sb.bg_color = Color(0.02, 0.02, 0.022, 0.88); sb.border_color = Color(白, 0.55)
	sb.set_border_width_all(int(maxf(1.0, round(1.5*s)))); sb.set_content_margin_all(32*s)
	pc.add_theme_stylebox_override("panel", sb); cc.add_child(pc)
	帮助格 = VBoxContainer.new(); 帮助格.add_theme_constant_override("separation", int(10*s)); 帮助格.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pc.add_child(帮助格)


func 签(text: String, fk: String, size: float, col: Color) -> Label:
	var l := Label.new(); l.text = text; l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_override("font", 字[fk]); l.add_theme_font_size_override("font_size", int(round(size*s)))
	l.add_theme_color_override("font_color", col)
	return l


func 帮助内容() -> void:
	for c in 帮助格.get_children(): c.queue_free()
	帮助格.add_child(签("KEYS · 按键与仪表          F1 关闭", "粗", 24, 白))
	var 左: Array = 按键 if 控 and not 按键.is_empty() else [["W A S D", "移动"], ["鼠标", "看"], ["Shift", "快"], ["Q / E", "降 / 升"],
		["1 – 4", "起点机位"], ["T", "下一个天空时刻"], ["F12", "截图"], ["Esc", "放开鼠标（再点一下抓回）"]]
	var 右 := [["H", "显示 / 隐藏界面"], ["F1", "本帮助"], ["M", "小地图换档（Shift+M 反向）"], ["滚轮", "小地图缩放（鼠标放开时，指着地图）"],
		["F3", "性能读数"], ["[  ]", "上 / 下一个天空时刻"], ["点太阳表", "跳到那张天空（Esc 放开鼠标后）"]]
	if P.has_node("天气"):                                           # 天气模块（天气/说明.md）
		右 += [["N / Shift+N", "尘埃光学厚度 τ 下 / 上一档"], ["U / Shift+U", "风速换档 / 回到随 τ"], ["B", "尘卷风 开 / 关"],
			["J", "扬尘 开 / 关"], ["Y", "眼前放一个尘卷风"], ["G", "自动曝光 开 / 关"]]
	if P.has_node("声音") and P.get_node("声音").has_method("按键"): 右 += P.get_node("声音").按键()
	if P.has_node("玩法") and P.get_node("玩法").has_method("按键"): 左 = 左 + P.get_node("玩法").按键()   # 玩法模块（拍照、图鉴、菜单）
	var hb := HBoxContainer.new(); hb.add_theme_constant_override("separation", int(64*s)); hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	帮助格.add_child(hb)
	帮助列(hb, "驾驶 · 相机" if 控 else "自由飞行（无控制模块）", 左)
	帮助列(hb, "界面", 右)
	帮助格.add_child(签("仪表", "粗", 20, 琥珀))
	for t in ["顶部航向带：中间方框是车头航向（0 = 北，顺时针）；☉ 太阳方位，◇ 停车点（站点原点）方位，▽ 当前相机朝向；下一行是相机模式。",
			"中下姿态仪：地平线随横滚倾斜、随俯仰上下；上弧是横滚刻度；下弧是车身总倾角，琥珀 ≥ 20°、红 ≥ 30°（本游戏设定的提示阈值，不是真车参数）。",
			"左下车轮：俯视的车体与六个轮子，角轮按各自转角画，细线是轮子朝向；轮旁竖条是悬架升降（±12 cm，上＝轮子抬起）；虚弧是阿克曼预测轨迹，圆箭头是原地转。",
			"速度表：真车等效速度（m/s，±5 cm/s 满刻度，短刻度＝真车直行 4.2 cm/s），×N 是动画倍率；ODO 是场景里实际走过的里程。",
			"右上太阳表：半圆是 06:00–18:00 的当地真太阳时，小点是预算好的天空时刻（落在点上就是那张天空本身）。",
			"右下小地图：北向上；HiRISE 底图（远档换 CTX）；V 形是车，细线是走过的轨迹，扇形 / 方框是相机视野。"]:
		var l := 签(t, "正", 18, 灰); l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; l.custom_minimum_size.x = 1500*s; 帮助格.add_child(l)
	帮助格.add_child(签(环境.一行() + "\n渲染 NASA 公开数据的毅力号 sol 530 停车点（杰泽罗陨石坑三角洲前缘）。非 NASA / JPL 官方产品。数据与影像：NASA/JPL-Caltech/ASU/MSSS/University of Arizona/USGS。字体：Inter、IBM Plex Mono、Noto Sans SC（SIL OFL 1.1）。", "正", 16, 淡))
	(帮助格.get_child(-1) as Label).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	(帮助格.get_child(-1) as Label).custom_minimum_size.x = 1500*s


func 帮助列(父: Control, 题: String, 表: Array) -> void:
	var v := VBoxContainer.new(); v.add_theme_constant_override("separation", int(6*s)); v.mouse_filter = Control.MOUSE_FILTER_IGNORE; 父.add_child(v)
	v.add_child(签(题, "粗", 20, 琥珀))
	var g := GridContainer.new(); g.columns = 2; g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	g.add_theme_constant_override("h_separation", int(20*s)); g.add_theme_constant_override("v_separation", int(5*s)); v.add_child(g)
	for kv in 表:
		var k := 签(String(kv[0]), "等中", 20, 白); k.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT; g.add_child(k)
		g.add_child(签(String(kv[1]), "正", 20, 灰))


# ———————————————————— 键、操作
func _unhandled_input(ev: InputEvent) -> void:
	if not (ev is InputEventKey and ev.pressed and not ev.echo): return
	match ev.keycode:
		KEY_H: 根.visible = not 根.visible
		KEY_F1: 帮助(not (帮助层.visible and 根.visible))
		KEY_M: 换档(-1 if ev.shift_pressed else 1, true)
		KEY_F3: 性能开(not 测)
		KEY_BRACKETLEFT: 跳时(-1)
		KEY_BRACKETRIGHT: 跳时(1)
		_: return
	get_viewport().set_input_as_handled()


func 帮助(on: bool) -> void:
	if on: 根.visible = true; 帮助内容()
	帮助层.visible = on


func 换档(d: int, 绕: bool) -> void:
	档 = posmod(档 + d, 档位.size()) if 绕 else clampi(档 + d, 0, 档位.size() - 1)
	轨迹脏 = true; 图注.queue_redraw()


func _图输入(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed:
		if ev.button_index == MOUSE_BUTTON_WHEEL_UP: 换档(-1, false); 图.accept_event()
		elif ev.button_index == MOUSE_BUTTON_WHEEL_DOWN: 换档(1, false); 图.accept_event()


func 性能开(on: bool) -> void:
	测 = on; 性能字 = ""
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), on)
	帧和 = 0; gpu和 = 0; 界和 = 0; 帧数 = 0; 窗 = 0
	if 角标: 角标.queue_redraw()


func 跳时(d: int) -> void:
	"""上 / 下一张预算天空的时刻（正好落在天空上，不插值）。"""
	var m := 时分
	if d > 0:
		for t in 天时:
			if t > 时分 + 0.5: m = t; break
	else:
		for i in range(天时.size() - 1, -1, -1):
			if 天时[i] < 时分 - 0.5: m = 天时[i]; break
	设时(m)


func 设时(m: float) -> void:
	时分 = m; P.set_time_f(m)
	if 太阳: 太阳.queue_redraw()


func _模式变(m) -> void:
	模式 = String(m); 提示时 = 2.0


# ———————————————————— 每帧
func _process(dt: float) -> void:
	var t0 := Time.get_ticks_usec()
	取位姿(dt)
	采累 += dt
	if 采累 >= 1.0/15.0: 采累 = 0.0; 采状态()
	if 根.visible: 更新(dt)
	累 += dt
	if 累 >= 0.1:
		累 = 0.0
		if P.ltst != 上次ltst:                                           # 别处（T 键、控制模块）换了时刻
			上次ltst = P.ltst; 时分 = P.minutes(P.ltst); 太阳.queue_redraw()
		elif P.time_m >= 0.0 and absf(P.time_m - 时分) > 0.5:          # 别处用 set_time_f 换了时刻（拍照模式）
			时分 = P.time_m; 太阳.queue_redraw()
		if 根.visible: 图注.queue_redraw()
	界总 += (Time.get_ticks_usec() - t0)/1000.0; 帧总 += 1
	if 测:
		var rid := get_viewport().get_viewport_rid()
		帧和 += dt*1000.0; gpu和 += RenderingServer.viewport_get_measured_render_time_gpu(rid); 帧数 += 1; 窗 += dt
		界和 += (Time.get_ticks_usec() - t0)/1000.0
		if 窗 >= 0.5:
			var n := float(帧数)
			性能字 = "%3d FPS  %4.1f ms  GPU %4.1f  HUD %.3f" % [roundi(1000.0*n/帧和), 帧和/n, gpu和/n, 界和/n]
			帧和 = 0; gpu和 = 0; 界和 = 0; 帧数 = 0; 窗 = 0
			if 根.visible: 角标.queue_redraw()


func 取位姿(dt: float) -> void:
	var rr: Node3D = P.rover_root
	有车 = rr != null and is_instance_valid(rr)
	if 有车:
		var t := rr.global_transform; var B := t.basis
		var f := B.z                                                     # 模型 +z 朝前、+x 朝左
		车E = t.origin.x; 车N = -t.origin.z; 车航 = atan2(f.x, -f.z)
		俯 = rad_to_deg(asin(clampf(B.z.normalized().y, -1.0, 1.0)))     # 车头抬为正
		滚 = rad_to_deg(asin(clampf(B.x.normalized().y, -1.0, 1.0)))     # 右侧低为正
		倾 = rad_to_deg(acos(clampf(B.y.normalized().y, -1.0, 1.0)))
	var 新 := rad_to_deg(车航)
	if dt > 0.0: 转速 = lerpf(转速, wrapf(新 - 旧航, -180.0, 180.0)/dt, minf(1.0, dt*8.0))
	旧航 = 新
	var 目标 := fposmod(新, 360.0)
	航显 = fposmod(航显 + wrapf(目标 - 航显, -180.0, 180.0)*minf(1.0, dt*14.0), 360.0)
	var cam := get_viewport().get_camera_3d()
	if cam:
		var t := cam.global_transform; var f := -t.basis.z
		机E = t.origin.x; 机N = -t.origin.z; 机航 = atan2(f.x, -f.z)
		var vs := get_viewport().get_visible_rect().size
		机视 = deg_to_rad(cam.fov) if cam.keep_aspect == Camera3D.KEEP_WIDTH else 2.0*atan(tan(deg_to_rad(cam.fov)*0.5)*vs.x/vs.y)
		机足 = Vector2.ZERO
		if f.y < -0.9:                                                   # 朝下看：视锥换成地面足迹，朝向按相机「上」
			var u := t.basis.y; 机航 = atan2(u.x, -u.z)
			var g: float = P.lod.h_cpu(t.origin.x, t.origin.z, 0) if P.lod else 0.0
			var h := maxf(t.origin.y - g, 0.1); var a := h*tan(机视*0.5)
			机足 = Vector2(a, a*vs.y/vs.x)
	var d: Vector3 = P.sun.global_transform.basis.z                       # 指向太阳
	日高 = rad_to_deg(asin(clampf(d.y, -1.0, 1.0))); 日方 = fposmod(rad_to_deg(atan2(d.x, -d.z)), 360.0)
	var 跟车 := 控 != null and 有车                                      # 有控制模块：轨迹记车、地图跟车（自由相机模式跟相机）；否则都跟相机
	心 = Vector2(车E, 车N) if 跟车 and 模式 != "自由" else Vector2(机E, 机N)
	var 源 := "车" if 跟车 else "机"
	if 源 != 轨迹源: 轨迹.clear(); 轨迹源 = 源; 轨迹脏 = true
	var p := Vector2(车E, -车N) if 跟车 else Vector2(机E, -机N)
	if 轨迹.is_empty() or 轨迹[-1].distance_squared_to(p) > 0.25:
		if not 轨迹.is_empty() and 轨迹[-1].distance_squared_to(p) > 400.0: 轨迹.clear()   # 瞬移（复位、跳机位）：断开重记
		轨迹.append(p); 轨迹脏 = true
		if 轨迹.size() > 4000: 轨迹 = 轨迹.slice(1000)


func 采状态() -> void:
	var 旧 := 控 != null
	控 = P.get_node_or_null("控制")
	var 有控 := 控 != null
	if 有控 and not 已连 and 控.has_signal("模式改变"): 控.connect("模式改变", _模式变); 已连 = true
	if 有控 != 旧: 轨迹脏 = true
	var st: Dictionary = {}
	if 有控 and 控.has_method("状态"): st = 控.call("状态")
	模式 = String(st.get("模式", "自由" if not 有控 else 模式))
	if st.has("按键") and st["按键"] is Array: 按键 = st["按键"]
	速 = float(st["速度_mps"]) if st.has("速度_mps") else NAN
	倍 = float(st["倍率"]) if st.has("倍率") else NAN
	里程 = float(st["里程_m"]) if st.has("里程_m") else NAN
	油 = float(st["油门"]) if st.has("油门") else NAN
	臂文 = ""
	if st.has("机械臂") and st["机械臂"] is Dictionary:
		var am: Dictionary = st["机械臂"]; var q: Array = am.get("角度_deg", [])
		if bool(am.get("模式", false)) or not bool(am.get("收好", true)):
			var JN := ["肩转", "肩俯仰", "肘", "腕", "转台"]
			臂文 = "机械臂 > %s" % JN[clampi(int(am.get("关节号", 0)), 0, 4)]
			if q.size() == 5: 臂文 += "\n%+.0f  %+.0f  %+.0f  %+.0f  %+.0f" % [q[0], q[1], q[2], q[3], q[4]]
		else: 臂文 = ""                                   # 收好时不写字
	var 玩: Node = P.get_node_or_null("玩法")                              # 玩法模块：兴趣点标记
	if 玩 and 玩.has_method("标记"):
		标记 = 玩.标记(); var 兴: Node = 玩.get_node_or_null("兴趣"); var 复: Node = 玩.get_node_or_null("复刻")
		标版 = (int(兴.版本) if 兴 else 0) + 1000*(int(复.get("版本")) if 复 and 复.get("版本") != null else 0)
	B态 = {}; 自驾 = bool(st.get("自驾", false))
	var Bn: Node = 玩.get_node_or_null("B") if 玩 else null
	if Bn and Bn.has_method("B状态"):
		var bs: Dictionary = Bn.B状态()
		if bs["开"] or bs["执行"]: B态 = bs
	算路局部()
	var 序 := [0, 1, 2, 3, 4, 5]                                          # 状态 的第 i 个数 → rig 里第 序[i] 个轮
	if st.has("轮序") and st["轮序"] is Array and st["轮序"].size() == 6:
		for i in 6:
			var n := String(st["轮序"][i])
			序[i] = (0 if n.contains("左") else 3) + (0 if n.contains("前") else (1 if n.contains("中") else 2))
	for i in 6: 轮转[i] = 0.0; 轮升[i] = 0.0
	if st.has("轮转向_deg"):
		for i in mini(6, st["轮转向_deg"].size()): 轮转[序[i]] = deg_to_rad(float(st["轮转向_deg"][i]))
	elif 有控 and 控.get("steer") is PackedFloat32Array:                  # 老版本控制模块：直接读它的数组（只读）
		var a: PackedFloat32Array = 控.get("steer")
		for i in mini(6, a.size()): 轮转[i] = a[i]
	if st.has("轮升降_m"):
		for i in mini(6, st["轮升降_m"].size()): 轮升[序[i]] = float(st["轮升降_m"][i])
	elif 有控 and 控.get("dy") is PackedFloat32Array:
		var a: PackedFloat32Array = 控.get("dy")
		for i in mini(6, a.size()): 轮升[i] = a[i]
	var pv = 控.get("pivot") if 有控 else null                            # 原地转：有 pivot 标志用它，否则看前两个角轮是否反向大角度
	原地 = bool(pv) if pv is bool else (signf(轮转[0]) != signf(轮转[3]) and absf(轮转[0]) > 0.35 and absf(轮转[3]) > 0.35)


func 更新(dt: float) -> void:
	# 航向带
	if 提示时 > 0.0: 提示时 -= dt
	var a := Vector4(snappedf(航显, 0.02), snappedf(日方, 0.25), snappedf(机航, 0.004), snappedf(rad_to_deg(atan2(-车E, -车N)), 0.25) + (1000.0 if 提示时 > 0.0 else 0.0))
	var 记 := Vector3(snappedf(车E, 0.5), snappedf(车N, 0.5), 标版 + 标记.size()*100000 + (B签() if not B态.is_empty() else 0))
	if 记 != 签记: 签记 = 记; 航向.queue_redraw(); 标层.queue_redraw()
	if a != 签航 or 提示时 > 0.0: 签航 = a; 航向.queue_redraw()
	var b := Vector3(snappedf(俯, 0.05), snappedf(滚, 0.05), snappedf(倾, 0.05) + (1000.0*float(fposmod(Time.get_ticks_msec()/1000.0, 1.0) < 0.6) if 倾 >= 倾红 else 0.0))
	if b != 签姿: 签姿 = b; 姿态.queue_redraw()
	var e := Vector3(snappedf(日高, 0.1), snappedf(日方, 0.5), 时分 + (snappedf(float(B态["预计完"]), 1.0)*1e4 + int(B态["sol"])*1e8 if not B态.is_empty() else 0.0))
	if e != 签日: 签日 = e; 太阳.queue_redraw()
	# 车轮 + 速度：转角 0.2°、升降 2 mm、速度 0.5 mm/s 精度
	var 变 := 签轮.size() != 15
	if 变: 签轮.resize(15)
	for i in 6:
		var q := snappedf(轮转[i], 0.0035); var r := snappedf(轮升[i], 0.002)
		if 签轮[i] != q or 签轮[i + 6] != r: 签轮[i] = q; 签轮[i + 6] = r; 变 = true
	var 速签 := snappedf(速, 0.0005) if not is_nan(速) else -999.0
	var 油签 := snappedf(油, 0.01) if not is_nan(油) else -999.0
	var 余签 := (snappedf(里程, 0.01) if not is_nan(里程) else -1.0) + (倍 if not is_nan(倍) else 0.0)*1e6 + (1e9 if 原地 else 0.0) + (1e10 if 转速 >= 0.0 else 0.0)
	if 签轮[12] != 速签 or 签轮[13] != 油签 or 签轮[14] != 余签: 签轮[12] = 速签; 签轮[13] = 油签; 签轮[14] = 余签; 变 = true
	if 臂文 != 臂文画: 臂文画 = 臂文; 变 = true
	var b签 := (snappedf(float(B态["电量"]), 1.0) + snappedf(float(B态["预计电量"]), 1.0)*1e5 + (0.5 if 自驾 else 0.0) + float(路局部.size())*1e11 + (路局部[-1].x + 路局部[-1].y*7.0 if not 路局部.is_empty() else 0.0)) if not B态.is_empty() else -1.0
	if b签 != 签B轮: 签B轮 = b签; 变 = true
	if 变: 车轮.queue_redraw()
	更地图()


# ———————————————————— 暗角
func _画暗角() -> void:
	var W := 暗角.size.x; var H := 暗角.size.y
	var 顶 := 190.0*s; var 底 := 320.0*s
	var c0 := Color(暗色, 0.42); var c1 := Color(暗色, 0.0)
	暗角.draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(W, 0), Vector2(W, 顶), Vector2(0, 顶)]), PackedColorArray([c0, c0, c1, c1]))
	var c2 := Color(0.04, 0.03, 0.025, 0.34)
	暗角.draw_polygon(PackedVector2Array([Vector2(0, H - 底), Vector2(W, H - 底), Vector2(W, H), Vector2(0, H)]), PackedColorArray([c1, c1, c2, c2]))


# ———————————————————— 航向带
func _画航向() -> void:
	var c := 航向; var w := c.size.x; var cx := w*0.5; var by := 70.0*s; var ppd := 9.0*s; var 半 := 55.0
	var h := 航显
	var d0 := int(floor((h - 半)/5.0))*5
	for d in range(d0, int(h + 半) + 5, 5):
		var x := cx + (d - h)*ppd
		var t := absf(x - cx)/(半*ppd)
		if t > 1.0: continue
		var al := 1.0 - t*t*t
		var dd := posmod(d, 360)
		var L := 16.0*s if dd % 30 == 0 else (10.0*s if dd % 10 == 0 else 5.0*s)
		线(c, Vector2(x, by), Vector2(x, by - L), Color(白, 0.9*al), 线宽)
		if dd % 30 == 0:
			var 名: String = {0: "北", 90: "东", 180: "南", 270: "西"}.get(dd, "%03d" % dd)
			字串(c, Vector2(x, by - 24*s), 名, 24 if 名.length() == 1 else 20, Color(白 if 名.length() == 1 else 灰, al), "等中", HORIZONTAL_ALIGNMENT_CENTER)
	# 标记：▽ 相机朝向（带上方）、☉ 太阳、◇ 停车点（带下方）
	var 机x := 带位(rad_to_deg(机航), h, cx, ppd, 半)
	var ca := 1.0 if absf(wrapf(rad_to_deg(机航) - h, -180, 180)) <= 半 else 0.45
	var cy := by - 50*s
	折(c, PackedVector2Array([Vector2(机x - 6*s, cy - 8*s), Vector2(机x + 6*s, cy - 8*s), Vector2(机x, cy), Vector2(机x - 6*s, cy - 8*s)]), Color(白, 0.85*ca), 线宽*0.85)
	var 日x := 带位(日方, h, cx, ppd, 半); var 日a := 1.0 if absf(wrapf(日方 - h, -180, 180)) <= 半 else 0.45
	弧(c, Vector2(日x, by + 12*s), 6.5*s, 0, TAU, Color(日色, 日a), 线宽*0.9, 20); c.draw_circle(Vector2(日x, by + 12*s), 1.8*s, Color(日色, 日a))
	if Vector2(车E, 车N).length() > 1.0:
		var 停 := fposmod(rad_to_deg(atan2(-车E, -车N)), 360.0)
		var 停x := 带位(停, h, cx, ppd, 半); var 停a := 1.0 if absf(wrapf(停 - h, -180, 180)) <= 半 else 0.45
		var q := Vector2(停x, by + 12*s); var r := 6.5*s
		折(c, PackedVector2Array([q + Vector2(0, -r), q + Vector2(r, 0), q + Vector2(0, r), q + Vector2(-r, 0), q + Vector2(0, -r)]), Color(白, 0.9*停a), 线宽*0.9)
	# 兴趣点（玩法模块）：没发现的 = 圈里一个问号，发现了的 = 实心小圆，挑战 = 琥珀方框；带外的夹到两端、变淡
	var 近名 := ""; var 近距 := INF
	for m: Dictionary in 标记:
		var dE: float = float(m["E"]) - 车E; var dN: float = float(m["N"]) - 车N; var dd := Vector2(dE, dN).length()
		if dd < 1.0: continue
		var az := fposmod(rad_to_deg(atan2(dE, dN)), 360.0)
		var mx := 带位(az, h, cx, ppd, 半); var ma := 1.0 if absf(wrapf(az - h, -180, 180)) <= 半 else 0.45
		var mq := Vector2(mx, by + 12*s)
		if m.get("挑战", false):
			c.draw_rect(Rect2(mq - Vector2(6, 6)*s, Vector2(12, 12)*s), Color(0, 0, 0, 0.6*ma), false, 5.0*s)
			c.draw_rect(Rect2(mq - Vector2(6, 6)*s, Vector2(12, 12)*s), Color(琥珀, ma), false, 2.0*s)
		elif m["已发现"]:
			c.draw_circle(mq, 6.5*s, Color(0, 0, 0, 0.6*ma)); c.draw_circle(mq, 4.5*s, Color(白, 0.9*ma))
		else:
			弧(c, mq, 8.0*s, 0, TAU, Color(白, 0.9*ma), 线宽*0.8, 20)
			字串(c, mq + Vector2(0, 6.5*s), "?", 18, Color(白, ma), "粗", HORIZONTAL_ALIGNMENT_CENTER)
			if not m["远"] and dd < 近距: 近距 = dd; 近名 = String(m["名"])
	# 中间：指针 + 航向读数框
	var p0 := Vector2(cx, by + 4*s)
	折(c, PackedVector2Array([p0 + Vector2(-7, 9)*s, p0, p0 + Vector2(7, 9)*s]), 白, 线宽*1.2)
	var bw := 92.0*s; var bh := 38.0*s; var bt := by + 18*s
	c.draw_rect(Rect2(cx - bw*0.5, bt, bw, bh), Color(0, 0, 0, 0.32))
	折(c, PackedVector2Array([Vector2(cx - bw*0.5, bt), Vector2(cx - 7*s, bt), Vector2(cx, bt - 0.5*s), Vector2(cx + 7*s, bt), Vector2(cx + bw*0.5, bt),
		Vector2(cx + bw*0.5, bt + bh), Vector2(cx - bw*0.5, bt + bh), Vector2(cx - bw*0.5, bt)]), 白, 线宽)
	字串(c, Vector2(cx, bt + bh - 9*s), "%03d" % (roundi(h) % 360), 26, 白, "等中", HORIZONTAL_ALIGNMENT_CENTER)
	# 相机模式一行；刚切换时放大、带括号，2 s 后回到常态
	var i := 模式序.find(模式)
	var 行 := String(模式英.get(模式, 模式))
	if 控 == null: 行 = "自由飞行"
	var 闪 := clampf(提示时/0.6, 0.0, 1.0)
	var my := bt + bh + 32*s
	字串(c, Vector2(cx, my), 行, lerpf(20.0, 24.0, 闪), Color(白 if 闪 > 0.0 else 灰, 1.0), "标" if 闪 <= 0.0 else "粗", HORIZONTAL_ALIGNMENT_CENTER)
	if 近名 != "":                                                       # 最近的未发现兴趣点（只说距离，名字等发现后才揭晓）
		字串(c, Vector2(cx, my + 28*s), "? 最近的兴趣点 %s" % 距(近距), 20, Color(灰, 0.95), "正", HORIZONTAL_ALIGNMENT_CENTER)
	if 闪 > 0.0:
		var hw := 120.0*s
		for sg: float in [-1.0, 1.0]:
			折(c, PackedVector2Array([Vector2(cx + sg*(hw - 10*s), my - 22*s), Vector2(cx + sg*hw, my - 22*s), Vector2(cx + sg*hw, my + 6*s), Vector2(cx + sg*(hw - 10*s), my + 6*s)]), Color(白, 闪), 线宽)


func 带位(az: float, h: float, cx: float, ppd: float, 半: float) -> float:
	"""方位 az 在航向带上的 x；带外的夹到两端。"""
	return cx + clampf(wrapf(az - h, -180.0, 180.0), -半, 半)*ppd


# ———————————————————— 姿态仪
func _画姿态() -> void:
	var c := 姿态; var o := Vector2(c.size.x*0.5, 140*s); var R := 78.0*s; var ppd := 3.0*s
	弧(c, o, R, 0, TAU, Color(白, 0.28), 线宽*0.8, 64)
	# 地平线与俯仰梯：在以横滚转过的坐标系里，沿法向偏 俯仰×ppd；只画落在圆里的部分
	var th := deg_to_rad(-滚); var u := 方(th); var n := Vector2(-u.y, u.x)
	var off := 俯*ppd
	for k in range(-4, 5):                                               # 俯仰梯：每 5°，k = 0 是地平线
		var y := off - k*5.0*ppd
		var lim := R*(0.98 if k == 0 else 0.78)
		if absf(y) >= lim: continue
		var 半长 := sqrt(R*R - y*y) if k == 0 else (26.0*s if k % 2 == 0 else 13.0*s)
		var m := o + n*y
		if k == 0:
			线(c, m - u*半长, m + u*半长, 白, 线宽*1.3)
		elif k > 0:
			线(c, m - u*半长, m + u*半长, Color(白, 0.75), 线宽*0.8)
		else:                                                            # 负俯仰：断开的线
			线(c, m - u*半长, m - u*半长*0.35, Color(白, 0.6), 线宽*0.8); 线(c, m + u*半长*0.35, m + u*半长, Color(白, 0.6), 线宽*0.8)
		if k != 0 and k % 2 == 0:
			c.draw_set_transform(m + u*(半长 + 12*s), 0.0, Vector2.ONE)
			字串(c, Vector2(0, 7*s), "%d" % (k*5), 20, Color(白, 0.8), "等", HORIZONTAL_ALIGNMENT_CENTER)
			c.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# 固定车标：两短横 + 中心小方块
	for sg: float in [-1.0, 1.0]: 线(c, o + Vector2(sg*20*s, 0), o + Vector2(sg*46*s, 0), 白, 线宽*1.4)
	c.draw_rect(Rect2(o - Vector2(3, 3)*s, Vector2(6, 6)*s), 白)
	# 上弧：横滚刻度 ±60°，指针随地平线转
	var R2 := R + 9*s
	弧(c, o, R2, deg_to_rad(-150), deg_to_rad(-30), Color(白, 0.55), 线宽*0.8, 40)
	for a in [-60, -45, -30, -20, -10, 0, 10, 20, 30, 45, 60]:
		var v := 方(deg_to_rad(-90.0 + a)); var L := 10.0*s if a % 30 == 0 else 6.0*s
		线(c, o + v*R2, o + v*(R2 + L), Color(白, 0.7), 线宽*0.8)
	var pv := 方(deg_to_rad(-90.0) + th); var pn := Vector2(-pv.y, pv.x)
	var tip := o + pv*(R2 - 2*s)
	c.draw_colored_polygon(PackedVector2Array([tip, tip - pv*11*s + pn*6*s, tip - pv*11*s - pn*6*s]), 白)
	# 下弧：车身总倾角 0–40°，从左（0°）走到右（40°）；20° 起琥珀、30° 起红
	var R3 := R + 9*s; var A0 := deg_to_rad(150.0); var A1 := deg_to_rad(30.0)
	var 角于 := func(v: float) -> float: return lerpf(A0, A1, clampf(v/40.0, 0.0, 1.0))
	弧(c, o, R3, A0, 角于.call(倾黄), Color(白, 0.4), 线宽*0.8, 20)
	弧(c, o, R3, 角于.call(倾黄), 角于.call(倾红), Color(琥珀, 0.8), 线宽*1.1, 10)
	弧(c, o, R3, 角于.call(倾红), A1, Color(红, 0.85), 线宽*1.1, 10)
	for v: int in [0, 10, 20, 30, 40]:
		var dv := 方(角于.call(float(v))); 线(c, o + dv*R3, o + dv*(R3 + (9.0 if v % 20 == 0 else 5.0)*s), Color(白, 0.7), 线宽*0.8)
	var 色 := 红 if 倾 >= 倾红 else (琥珀 if 倾 >= 倾黄 else 白)
	if 倾 > 0.05: 弧(c, o, R3 - 5*s, A0, 角于.call(倾), 色, 线宽*2.2, 24)
	var tv := 方(角于.call(倾)); c.draw_circle(o + tv*(R3 - 5*s), 3.2*s, 色)
	字串(c, o + Vector2(0, R + 50*s), "%4.1f°" % 倾, 24, 色, "等中", HORIZONTAL_ALIGNMENT_CENTER)
	字串(c, o + Vector2(0, R + 78*s), "%+5.1f°  %+5.1f°" % [俯, 滚], 20, 灰, "等", HORIZONTAL_ALIGNMENT_CENTER)
	# 告警不只靠颜色（XAG 103 / GAG）：琥珀 ▲ CAUTION；红 ■ WARNING，1 Hz 慢闪（亮 0.6 s、暗 0.4 s，≤ 3 Hz）
	if 倾 >= 倾黄:
		var 红警 := 倾 >= 倾红
		var 亮 := not 红警 or fposmod(Time.get_ticks_msec()/1000.0, 1.0) < 0.6
		var 字色 := Color(红 if 红警 else 琥珀, 1.0 if 亮 else 0.35)
		var by := o.y - R - 42*s; var tx := "警告" if 红警 else "注意"
		var ic := Vector2(o.x - 70*s, by - 8*s); var r := 11.0*s
		if 红警:
			c.draw_rect(Rect2(ic - Vector2(r, r) - Vector2(2, 2)*s, Vector2(2*r, 2*r) + Vector2(4, 4)*s), Color(0, 0, 0, 0.6))
			c.draw_rect(Rect2(ic - Vector2(r, r), Vector2(2*r, 2*r)), 字色)
		else:
			var tri := PackedVector2Array([ic + Vector2(0, -r*1.1), ic + Vector2(r*1.1, r*0.9), ic + Vector2(-r*1.1, r*0.9)])
			c.draw_colored_polygon(tri, 字色); tri.append(tri[0]); c.draw_polyline(tri, Color(0, 0, 0, 0.6), 2.0*s, true)
			字串(c, ic + Vector2(0, r*0.75), "!", 18, Color(0.05, 0.04, 0.03), "粗", HORIZONTAL_ALIGNMENT_CENTER)
		字串(c, Vector2(ic.x + r + 10*s, by), tx, 24, 字色, "粗")


# ———————————————————— 六轮示意 + 速度
func 轮到屏(o: Vector2, k: float, x: float, z: float) -> Vector2:
	return o + Vector2(-x, -z)*k                                          # 模型 x 左 → 屏幕左；z 前 → 屏幕上


func _画车轮() -> void:
	var c := 车轮; var o := Vector2(180*s, 170*s); var k := 84.0*s
	# 车体轮廓（俯视，前端两角切角）+ 两侧摇臂
	var bx := 0.70; var zf := 0.95; var zr := -0.92
	折(c, PackedVector2Array([轮到屏(o, k, bx, zf - 0.14), 轮到屏(o, k, bx - 0.14, zf), 轮到屏(o, k, -bx + 0.14, zf), 轮到屏(o, k, -bx, zf - 0.14),
		轮到屏(o, k, -bx, zr), 轮到屏(o, k, bx, zr), 轮到屏(o, k, bx, zf - 0.14)]), Color(白, 0.8), 线宽)
	for sd in [0, 3]:
		折(c, PackedVector2Array([轮到屏(o, k, 轮心[sd].x, 轮心[sd].y), 轮到屏(o, k, 轮心[sd + 1].x, 轮心[sd + 1].y), 轮到屏(o, k, 轮心[sd + 2].x, 轮心[sd + 2].y)]), Color(白, 0.35), 线宽*0.8)
	var fa := 轮到屏(o, k, 0, zf + 0.12)                                  # 车头小箭
	折(c, PackedVector2Array([fa + Vector2(-6, 6)*s, fa, fa + Vector2(6, 6)*s]), Color(白, 0.8), 线宽)
	# 阿克曼预测弧（转动中心在中轮轴线上）/ 原地转圆箭头
	var zm := 轮心[1].y
	if 原地:
		var r := 0.42*k; var sg := 1.0 if 转速 >= 0.0 else -1.0             # 屏幕上顺时针＝航向变大＝右转
		var a0 := deg_to_rad(-60.0); var a1 := deg_to_rad(200.0)
		var cc := 轮到屏(o, k, 0, zm)
		弧(c, cc, r, a0, a1, Color(白, 0.85), 线宽, 28)
		var ae := a1 if sg > 0 else a0; var tp := cc + 方(ae)*r; var tg := 方(ae + PI*0.5*(1.0 if sg > 0 else -1.0))
		var nn := Vector2(-tg.y, tg.x)
		c.draw_colored_polygon(PackedVector2Array([tp + tg*9*s, tp - tg*3*s + nn*6*s, tp - tg*3*s - nn*6*s]), 白)
		字串(c, 轮到屏(o, k, 0, zr - 0.66), "原地转", 20, 白, "标", HORIZONTAL_ALIGNMENT_CENTER)
	else:
		var δ := 0.5*(轮转[0] + 轮转[3])
		if 自驾 and 路局部.size() >= 2:                                    # 玩法 B 自驾：预测弧延伸成接下来的计划路径
			var 路屏 := PackedVector2Array()
			for q: Vector2 in 路局部:                                        # 从车头起，画到示意框顶为止（同一比例）
				if q.y < zf: continue
				var qs := 轮到屏(o, k, q.x, q.y)
				if qs.y < 6*s or qs.x < 6*s or qs.x > c.size.x - 6*s: break
				路屏.append(qs)
			if 路屏.size() >= 2: 折(c, 路屏, Color(琥珀 if int(B态.get("方式", 1)) == 2 else 白, 0.9), 线宽*0.9)
			字串(c, 轮到屏(o, k, 0, zr - 0.66), ["盲开", "视觉里程计", "AutoNav"][clampi(int(B态.get("方式", 1)), 0, 2)], 20, 白, "标", HORIZONTAL_ALIGNMENT_CENTER)
		var 前z := 轮心[0].y - zm
		var kap := tan(δ)/前z if absf(δ) > 0.002 else 0.0                    # 中轴中点的曲率（左正）
		var dir := -1.0 if (not is_nan(速) and 速 < -1e-5) else 1.0
		for i in 13:
			var t := dir*1.6*i/12.0
			var x := (1.0 - cos(kap*t))/kap if absf(kap) > 1e-4 else 0.0
			var z := sin(kap*t)/kap if absf(kap) > 1e-4 else t
			弧点[i] = 轮到屏(o, k, x, zm + z)
		c.draw_polyline(弧点, Color(白, 0.4), 线宽*0.8, true)
		if not (自驾 and 路局部.size() >= 2): 字串(c, 轮到屏(o, k, 0, zr - 0.66), "STEER %+5.1f°" % rad_to_deg(δ), 20, 灰, "等", HORIZONTAL_ALIGNMENT_CENTER)
	# 六个轮子：角轮按各自转角转；细线＝轮子朝向；外侧竖条＝悬架升降
	for i in 6:
		var p := 轮到屏(o, k, 轮心[i].x, 轮心[i].y)
		var ang := -轮转[i] if 轮角[i] else 0.0
		var ax := Vector2(0, -1).rotated(ang); var ay := Vector2(1, 0).rotated(ang)
		var hl := 轮r*k; var hw := 轮w*0.5*k
		轮框[0] = p - ax*hl - ay*hw; 轮框[1] = p - ax*hl + ay*hw; 轮框[2] = p + ax*hl + ay*hw; 轮框[3] = p + ax*hl - ay*hw; 轮框[4] = 轮框[0]
		c.draw_colored_polygon(轮框.slice(0, 4), Color(0, 0, 0, 0.35))
		折(c, 轮框, 白, 线宽)
		if 轮角[i]: 线(c, p + ax*hl, p + ax*(hl + 0.32*k), Color(白, 0.5), 线宽*0.7)
		var 外 := -1.0 if 轮心[i].x > 0 else 1.0                               # 左轮在屏幕左
		var bxp := p.x + 外*(hw + 16*s); var bh := 24.0*s
		线(c, Vector2(bxp, p.y - bh), Vector2(bxp, p.y + bh), Color(白, 0.3), 线宽*0.6)
		线(c, Vector2(bxp - 4*s, p.y), Vector2(bxp + 4*s, p.y), Color(白, 0.6), 线宽*0.6)
		var v := clampf(轮升[i]/升降限, -1.0, 1.0)
		var 色 := 红 if absf(v) >= 0.96 else (琥珀 if absf(v) >= 0.75 else 白)
		if absf(v) > 0.01: c.draw_rect(Rect2(bxp - 2.5*s, minf(p.y, p.y - v*bh), 5*s, absf(v*bh)), 色)
	# 速度弧表：0 在正上方，顺时针前进、逆时针倒车，满刻度 ±5 cm/s；短刻度＝真车直行速度
	var g := Vector2(500*s, 150*s); var R := 74.0*s; var 满 := 0.05; var 扫 := deg_to_rad(120.0); var 上 := deg_to_rad(-90.0)
	弧(c, g, R, 上 - 扫, 上 + 扫, Color(白, 0.45), 线宽*0.8, 48)
	for j in range(-5, 6):
		var a := 上 + 扫*j/5.0; var L := 10.0*s if j % 5 == 0 else 5.0*s
		线(c, g + 方(a)*R, g + 方(a)*(R - L), Color(白, 0.7), 线宽*0.8)
	for sg: float in [-1.0, 1.0]:
		var a := 上 + 扫*sg*真速/满; 线(c, g + 方(a)*(R + 3*s), g + 方(a)*(R + 12*s), Color(白, 0.8), 线宽)
	if not is_nan(速):
		var a := 上 + 扫*clampf(速/满, -1.0, 1.0)
		if absf(速) > 0.0002: 弧(c, g, R - 6*s, minf(上, a), maxf(上, a), 白, 线宽*2.4, 32)
		线(c, g + 方(a)*(R*0.25), g + 方(a)*(R - 2*s), 白, 线宽*1.2)
	if not is_nan(油) and absf(油) > 0.01:                                # 油门：外圈小三角
		var a := 上 + 扫*clampf(油*真速/满, -1.0, 1.0); var q := g + 方(a)*(R + 16*s)
		c.draw_colored_polygon(PackedVector2Array([q - 方(a)*1*s, q + 方(a)*9*s + 方(a + PI*0.5)*5*s, q + 方(a)*9*s - 方(a + PI*0.5)*5*s]), 白)
	c.draw_circle(g, 3*s, 白)
	字串(c, g + Vector2(0, 42*s), "—" if is_nan(速) else "%.3f" % 速, 26, 白, "等中", HORIZONTAL_ALIGNMENT_CENTER)
	字串(c, g + Vector2(0, 66*s), "m/s", 20, 灰, "等", HORIZONTAL_ALIGNMENT_CENTER)
	字串(c, g + Vector2(0, 100*s), "×%s%s" % [数(倍) if not is_nan(倍) else "—", "  FFWD" if 自驾 else ""], 24, 白, "等中", HORIZONTAL_ALIGNMENT_CENTER)
	if not B态.is_empty(): 画能量(c, Vector2(606*s, 72*s), 160*s)
	字串(c, g + Vector2(0, 128*s), "%s" % ("—" if is_nan(里程) else "%.2f m" % 里程), 20, 灰, "等", HORIZONTAL_ALIGNMENT_CENTER)
	var 臂行 := 臂文.split("\n")
	for j in 臂行.size(): 字串(c, g + Vector2(0, (158 + 26*j)*s), 臂行[j], 20, 白 if j == 0 else 灰, "等", HORIZONTAL_ALIGNMENT_CENTER)


# ———————————————————— 太阳弧表
func 时角(m: float) -> float:
	return PI + clampf((m - 360.0)/720.0, -0.1, 1.1)*PI                    # 06:00 在左地平线、12:00 正上、18:00 右地平线；日出前日落后（暮光）落到地平线下面


func 表心() -> Vector2:
	return Vector2(太阳.size.x*0.5, 150*s)


func _画太阳() -> void:
	var c := 太阳; var o := 表心(); var R := 118.0*s
	线(c, o + Vector2(-R - 30*s, 0), o + Vector2(R + 30*s, 0), Color(白, 0.6), 线宽*0.9)
	弧(c, o, R, PI, TAU, Color(白, 0.4), 线宽*0.8, 48)
	for hh in range(6, 19):
		var a := 时角(hh*60.0); var L := 9.0*s if hh % 6 == 0 else 5.0*s
		线(c, o + 方(a)*R, o + 方(a)*(R + L), Color(白, 0.6), 线宽*0.8)
	字串(c, o + 方(时角(360))*(R + 4*s) + Vector2(-6*s, 26*s), "06", 20, 灰, "等", HORIZONTAL_ALIGNMENT_CENTER)
	字串(c, o + Vector2(0, -R - 16*s), "12", 20, 灰, "等", HORIZONTAL_ALIGNMENT_CENTER)
	字串(c, o + 方(时角(1080))*(R + 4*s) + Vector2(6*s, 26*s), "18", 20, 灰, "等", HORIZONTAL_ALIGNMENT_CENTER)
	for i in 天时.size():                                                # 预算天空：弧上小点（指着的那个画圈）
		var q := o + 方(时角(天时[i]))*R
		c.draw_circle(q, 2.6*s, Color(白, 0.85))
		if i == 悬停: 弧(c, q, 7*s, 0, TAU, 白, 线宽*0.8, 16)
	var sp := o + 方(时角(时分))*R
	线(c, o, sp, Color(日色, 0.28), 线宽*0.7)
	c.draw_circle(sp, 9*s, Color(0, 0, 0, 0.35))
	弧(c, sp, 9*s, 0, TAU, 日色, 线宽*1.1, 24); c.draw_circle(sp, 2.6*s, 日色)
	if not B态.is_empty():                                             # 玩法 B：驾驶时窗（弧外一道琥珀粗弧）+ 预计结束刻度
		var 窗: Vector2 = B态["窗"]
		弧(c, o, R + 14*s, 时角(窗.x), 时角(窗.y), Color(琥珀, 0.95), 线宽*1.5, 24)
		for m: float in [窗.x, 窗.y]: 线(c, o + 方(时角(m))*(R + 8*s), o + 方(时角(m))*(R + 22*s), 琥珀, 线宽*0.9)
		var 完 := float(B态["预计完"])
		if 完 >= 0.0: 线(c, o + 方(时角(完))*(R + 4*s), o + 方(时角(完))*(R + 26*s), 白, 线宽*1.3)
		字串(c, o + Vector2(0, 122*s), "DRIVE %02d–%02d%s" % [int(窗.x)/60, int(窗.y)/60, ("  ETA %02d:%02d" % [int(完)/60, int(完)%60]) if 完 >= 0.0 else ""], 20, 琥珀, "等", HORIZONTAL_ALIGNMENT_CENTER)
	字串(c, o + Vector2(0, 42*s), "LTST %02d:%02d" % [int(时分)/60, int(时分)%60], 26, 白, "等中", HORIZONTAL_ALIGNMENT_CENTER)
	字串(c, o + Vector2(0, 70*s), "SOL %d  τ %.2f" % [int(B态["sol"]) if not B态.is_empty() else SOL, float(P.get_node("天气").状态()["τ"]) if P.has_node("天气") else 尘τ], 20, 灰, "等", HORIZONTAL_ALIGNMENT_CENTER)
	字串(c, o + Vector2(0, 96*s), "SUN EL %.1f°  AZ %03d°" % [日高, roundi(日方) % 360], 20, 灰, "等", HORIZONTAL_ALIGNMENT_CENTER)


func _太阳输入(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion or (ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT):
		var o := 表心(); var R := 118.0*s; var best := -1; var bd := 14.0*s
		for i in 天时.size():
			var d: float = (o + 方(时角(天时[i]))*R).distance_to(ev.position)
			if d < bd: bd = d; best = i
		if best != 悬停: 悬停 = best; 太阳.queue_redraw()
		if ev is InputEventMouseButton:
			if best >= 0: 设时(天时[best])
			太阳.accept_event()


# ———————————————————— 角标（左上）：身份一行 + 性能
func _画角标() -> void:
	pass                                                                  # 界面 5：去掉身份行（PERSEVERANCE · JEZERO）
	if 测 and 性能字 != "": 字串(角标, Vector2(0, 52*s), 性能字, 20, 灰, "等")
	if 测: 字串(角标, Vector2(0, 80*s), 环境.一行(), 18, 灰, "等")              # 版本（godot/环境.gd）


# ———————————————————— 小地图
func 半() -> float:
	return 档位[档]


func 地到屏(E: float, N: float, ppm: float) -> Vector2:
	return 图.size*0.5 + Vector2(E - 心.x, 心.y - N)*ppm


func 更地图() -> void:
	var half := 半(); var ppm := 图.size.x/(2.0*half)
	var 键 := Vector4(心.x, 心.y, half, 图.size.x)
	if 键 != 签图: 签图 = 键; 图.queue_redraw()
	轨迹层.transform = Transform2D(0.0, Vector2(ppm, ppm), 0.0, 图.size*0.5 + Vector2(-心.x, 心.y)*ppm)
	if 轨迹脏: 轨迹脏 = false; 轨迹层.queue_redraw()
	var a := Vector4(机E, 机N, 机航, 机视 + 机足.x*3.1 + 机足.y*0.7); var b := Vector4(车E, 车N, 车航, half + 心.x + 心.y*7.0)
	if a != 签标A or b != 签标B: 签标A = a; 签标B = b; 标层.queue_redraw()


func 整(x: float) -> float:
	"""≤ x 的 1、2、5 × 10ⁿ。"""
	var e := pow(10.0, floor(log(x)/log(10.0))); var m := x/e
	return (5.0 if m >= 5.0 else (2.0 if m >= 2.0 else 1.0))*e


func 数(v: float) -> String:
	"""整数不带小数点，否则一位小数。"""
	return str(roundi(v)) if is_equal_approx(v, roundf(v)) else "%.1f" % v


func 距(x: float) -> String:
	var 千 := x >= 1000.0; var v := x/1000.0 if 千 else x
	return 数(v) + (" km" if 千 else " m")


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
	if e1 > e0 and n1 > n0:                                              # u = E/(2·half) + 0.5，v = 0.5 − N/(2·half)
		var dst := Rect2((e0 - 心.x + half)*ppm, (心.y + half - n1)*ppm, (e1 - e0)*ppm, (n1 - n0)*ppm)
		var src := Rect2((e0/(2.0*th) + 0.5)*W, (0.5 - n1/(2.0*th))*H, (e1 - e0)/(2.0*th)*W, (n1 - n0)/(2.0*th)*H)
		图.draw_texture_rect_region(T, dst, src)
	var st := 整(half*0.5); var lw := maxf(1.0, s)                          # 方里网：和比例尺同一个间距
	var x := ceilf((心.x - half)/st)*st
	while x <= 心.x + half:
		var px := (x - 心.x + half)*ppm; 图.draw_line(Vector2(px, 0), Vector2(px, sz.y), Color(1, 1, 1, 0.12), lw); x += st
	var y := ceilf((心.y - half)/st)*st
	while y <= 心.y + half:
		var py := (心.y + half - y)*ppm; 图.draw_line(Vector2(0, py), Vector2(sz.x, py), Color(1, 1, 1, 0.12), lw); y += st
	if 远:                                                               # 远档：标出 HiRISE 高清范围
		var a := 地到屏(-高半, 高半, ppm); var b := 地到屏(高半, -高半, ppm)
		图.draw_rect(Rect2(a, b - a), Color(1, 1, 1, 0.5), false, lw)


func _画轨迹() -> void:
	if 轨迹.size() < 2: return
	var ppm := 图.size.x/(2.0*半())
	轨迹层.draw_polyline(轨迹, Color(0, 0, 0, 0.6), 5.5*s/ppm)               # 亮线 + 暗描边
	轨迹层.draw_polyline(轨迹, Color(白, 0.95), 2.2*s/ppm)
	轨迹层.draw_circle(轨迹[0], 3.0*s/ppm, 白)


func _画标记() -> void:
	var c := 标层; var sz := 图.size; var half := 半(); var ppm := sz.x/(2.0*half)
	# 相机：俯视时地面足迹框，否则视野扇形（只描边）
	var o := 地到屏(机E, 机N, ppm)
	if 机足.x > 0.0:
		var u := Vector2(sin(机航), cos(机航)); var r := Vector2(u.y, -u.x)    # (E, N)
		var k := 0
		for q: Vector2 in [Vector2(-1, 1), Vector2(1, 1), Vector2(1, -1), Vector2(-1, -1), Vector2(-1, 1)]:
			var w: Vector2 = r*q.x*机足.x + u*q.y*机足.y; 框[k] = 地到屏(机E + w.x, 机N + w.y, ppm); k += 1
		折(c, 框, Color(白, 0.7), 线宽*0.8)
	else:
		var L := sz.x*0.22; var a := 机视*0.5
		楔[0] = o
		for i in 7:
			var t := 机航 - a + 2.0*a*i/6.0; 楔[i + 1] = o + Vector2(sin(t), -cos(t))*L
		c.draw_colored_polygon(楔, Color(1, 1, 1, 0.07))
		折(c, 楔, Color(白, 0.6), 线宽*0.75); 线(c, 楔[7], o, Color(白, 0.6), 线宽*0.75)
	# 兴趣点（玩法模块）：没发现的画问号圈，发现了的画实心小圆，挑战画琥珀方框；只画落在图里的
	for m: Dictionary in 标记:
		var mp := 地到屏(float(m["E"]), float(m["N"]), ppm)
		if mp.x < 8*s or mp.y < 8*s or mp.x > sz.x - 8*s or mp.y > sz.y - 8*s: continue
		if m.get("挑战", false):
			c.draw_rect(Rect2(mp - Vector2(7, 7)*s, Vector2(14, 14)*s), Color(0, 0, 0, 0.6), false, 5.0*s)
			c.draw_rect(Rect2(mp - Vector2(7, 7)*s, Vector2(14, 14)*s), 琥珀, false, 2.0*s)
		elif m["已发现"]:
			c.draw_circle(mp, 6.0*s, Color(0, 0, 0, 0.6)); c.draw_circle(mp, 4.0*s, 白)
		else:
			c.draw_circle(mp, 10.0*s, Color(0, 0, 0, 0.55)); 弧(c, mp, 9.0*s, 0, TAU, 白, 线宽*0.7, 20)
			字串(c, mp + Vector2(0, 6.5*s), "?", 18, 白, "粗", HORIZONTAL_ALIGNMENT_CENTER)
	if not B态.is_empty(): 画B图(c, ppm)
	# 车：V 形
	if 有车:
		var p := 地到屏(车E, 车N, ppm); var d := Vector2(sin(车航), -cos(车航)); var n := Vector2(-d.y, d.x)
		折(c, PackedVector2Array([p - d*8*s + n*10*s, p + d*12*s, p - d*8*s - n*10*s]), 白, 线宽*1.4)
	# 暗框（P0 #4）、四角刻度、北向刻度、比例尺、档位
	c.draw_rect(Rect2(Vector2.ZERO, sz).grow(-2.5*s), Color(0, 0, 0, 0.6), false, 5.0*s)
	c.draw_rect(Rect2(Vector2.ZERO, sz).grow(-5.5*s), Color(白, 0.25), false, maxf(1.0, 1.2*s))
	var m := 1.0*s; var L2 := 22.0*s; var cl := Color(白, 0.9)
	for q: Vector2 in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]:
		var p0 := Vector2(m + q.x*(sz.x - 2*m), m + q.y*(sz.y - 2*m)); var sx := 1.0 - 2.0*q.x; var sy := 1.0 - 2.0*q.y
		折(c, PackedVector2Array([p0 + Vector2(sx*L2, 0), p0, p0 + Vector2(0, sy*L2)]), cl, 线宽)
	var nt := Vector2(sz.x*0.5, 0)
	线(c, nt, nt + Vector2(0, 14*s), cl, 线宽)
	字串(c, nt + Vector2(0, 38*s), "北", 20, 白, "粗", HORIZONTAL_ALIGNMENT_CENTER)
	var 长 := 整(half*0.5); var px := 长*ppm; var b0 := Vector2(18*s, sz.y - 18*s)
	折(c, PackedVector2Array([b0 + Vector2(0, -6*s), b0, b0 + Vector2(px, 0), b0 + Vector2(px, -6*s)]), 白, 线宽)
	字串(c, b0 + Vector2(px + 8*s, 2*s), 距(长), 20, 白, "等")
	字串(c, Vector2(18*s, 34*s), ("CTX" if half > 高半*0.95 else "HiRISE") + "  ±" + 距(half), 20, Color(白, 0.95), "等")


func _画图注() -> void:
	var c := 图注; var w := c.size.x
	var E := 车E if 有车 else 机E; var N := 车N if 有车 else 机N
	var y0 := 0.0
	if 有车 and P.rover_root: y0 = P.rover_root.global_position.y
	var lat := LAT0 + rad_to_deg(N/R_MARS); var lon := LON0 + rad_to_deg(E/(R_MARS*cos(deg_to_rad(lat))))
	var el := E0 + y0 + (E*E + N*N)/(2.0*R_MARS)
	字串(c, Vector2(w, 24*s), "%.6f°N  %.6f°E  %.1f m" % [lat, lon, el], 20, 灰, "等", HORIZONTAL_ALIGNMENT_RIGHT)
	字串(c, Vector2(w, 50*s), "E %+.1f  N %+.1f m" % [E, N], 20, 灰, "等", HORIZONTAL_ALIGNMENT_RIGHT)
	var 源 := "CTX NASA/JPL-Caltech/MSSS" if 半() > 高半*0.95 else "HiRISE NASA/JPL-Caltech/UArizona"
	字串(c, Vector2(w, 78*s), 源, 16, 淡, "正", HORIZONTAL_ALIGNMENT_RIGHT)       # 署名：小字（不算仪表标签）
	字串(c, Vector2(w, 100*s), "Data NASA/JPL-Caltech/ASU/MSSS/UArizona/USGS · not an official NASA product", 16, 淡, "正", HORIZONTAL_ALIGNMENT_RIGHT)


# ———————————————————— 玩法 B（sol 规划）
func B签() -> int:
	var 路: PackedVector2Array = B态["路"]
	return 7*路.size() + 131*int(B态["段"]) + 1009*(B态["禁"] as Array).size() + (5003 if B态["执行"] else 0) + (int(路[-1].x*10.0 + 路[-1].y*3.0) if not 路.is_empty() else 0)


func 算路局部() -> void:
	"""自驾时：接下来的计划路径（从车开始沿路径 6 m），换到车体坐标（x 左、z 前），给六轮示意画。"""
	路局部.clear()
	if not 自驾 or B态.is_empty(): return
	var 路: PackedVector2Array = B态["路"]
	if 路.size() < 2: return
	var f := Vector2(sin(车航), cos(车航)); var rt := Vector2(cos(车航), -sin(车航))   # (E, N)：车头、车右
	var c0 := Vector2(车E, 车N)
	var 剩 := 6.0; 路局部.append(Vector2.ZERO)
	for i in range(1, 路.size()):
		var a: Vector2 = 路[i - 1] if i > 1 else c0; var b: Vector2 = 路[i]
		var L := a.distance_to(b)
		if L < 1e-3: continue
		var n := ceili(minf(L, 剩)/0.25)
		for j in range(1, n + 1):
			var q := a + (b - a)*minf(j*0.25, 剩)/L
			var d := q - c0
			路局部.append(Vector2(-d.dot(rt), d.dot(f)))
		剩 -= L
		if 剩 <= 0.0: break


func 画能量(c: CanvasItem, top: Vector2, h: float) -> void:
	"""速度表旁的能量条（竖）：细框 + 当前电量；红刻度＝下限；预演过的话白刻度＝预计执行后的电量。只描边，不加暗底。"""
	var 容 := float(B态["容量"]); var v := clampf(float(B态["电量"])/容, 0.0, 1.0); var 下 := float(B态["下限"])/容
	var w := 12.0*s; var bot := top + Vector2(0, h)
	折(c, PackedVector2Array([top, top + Vector2(w, 0), bot + Vector2(w, 0), bot, top]), Color(白, 0.75), 线宽*0.7)
	var fy := bot.y - h*v
	c.draw_rect(Rect2(top.x + 3*s, fy, w - 6*s, bot.y - fy), Color(0, 0, 0, 影a*0.6))
	c.draw_rect(Rect2(top.x + 4*s, fy + 1*s, w - 8*s, maxf(0.0, bot.y - fy - 2*s)), 琥珀 if v < 下 + 0.05 else 白)
	var ly := bot.y - h*下
	线(c, Vector2(top.x - 6*s, ly), Vector2(top.x + w + 6*s, ly), 红, 线宽*0.9)
	var 预 := float(B态["预计电量"])
	if 预 >= 0.0:
		var py := bot.y - h*clampf(预/容, 0.0, 1.0)
		线(c, Vector2(top.x - 10*s, py), Vector2(top.x - 1*s, py), 白, 线宽)
	pass                                                                  # 电量条：去掉 PWR 标签
	字串(c, bot + Vector2(w*0.5, 30*s), "%d%%" % roundi(v*100.0), 22, 琥珀 if v < 下 + 0.05 else 白, "等中", HORIZONTAL_ALIGNMENT_CENTER)


func 画B图(c: CanvasItem, ppm: float) -> void:
	"""小地图：剩下的计划路径（AutoNav 段琥珀、其余白）、航点、禁行区。"""
	for z: Vector3 in B态["禁"]:
		var o := 地到屏(z.x, z.y, ppm)
		c.draw_arc(o, z.z*ppm, 0, TAU, 32, Color(0, 0, 0, 0.6), 4.0*s, true); c.draw_arc(o, z.z*ppm, 0, TAU, 32, 红, 1.8*s, true)
	var 路: PackedVector2Array = B态["路"]
	if 路.size() >= 2:
		var pts := PackedVector2Array()
		for e: Vector2 in 路: pts.append(地到屏(e.x, e.y, ppm))
		折(c, pts, Color(琥珀 if int(B态.get("方式", -1)) == 2 else 白, 0.9), 线宽*0.8)
	var 航: PackedVector2Array = B态["航点"]
	for i in range(1, 航.size()):
		var q := 地到屏(航[i].x, 航[i].y, ppm)
		c.draw_circle(q, 6.0*s, Color(0, 0, 0, 0.6)); c.draw_arc(q, 5.0*s, 0, TAU, 16, 白, 2.0*s, true)



# ———————————————————— 自测
func 自测(目录: String) -> void:
	if 目录 == "": 目录 = ProjectSettings.globalize_path("res://界面/截图")
	DirAccess.make_dir_recursive_absolute(目录)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)   # 量 GPU（性能读数默认关）
	print("[界面] 自测 %s，s = %.2f，控制模块 %s" % [str(尺寸), s, "有" if P.has_node("控制") else "无"])
	await 等(2.5)
	var c: Node = P.get_node_or_null("控制")
	print("[界面] 停车位航向 %.1f°（应≈ 252.2°：61 的 ROVER_YPR 偏航 −107.79°），倾角 %.1f°" % [fposmod(rad_to_deg(车航), 360.0), 倾])
	if c:
		c.set("rate_i", 5)                                                # 50×：几秒内走出看得见的轨迹
		c.call("set_mode", "跟车")
		c.set("自动", {"油": 1.0}); await 等(3.0); await 存(目录, "1_直行")
		c.set("自动", {"油": 1.0, "转": 1.0}); await 等(2.5); await 存(目录, "2_阿克曼左弧")
		c.set("自动", {"原地": -1.0}); await 等(3.0); await 存(目录, "3_原地右转")
		c.set("自动", {})
		var sp := 找坡()                                                   # 斜坡：停车位 40 m 内坡度最大处，车头斜对坡向
		if sp.z > 0.0:
			print("[界面] 斜坡 E %.1f N %.1f，坡度 %.1f°" % [sp.x, -sp.y, rad_to_deg(sp.z)])
			c.call("teleport", Vector3(sp.x, 0, sp.y), sp.w); c.set("自动", {"油": 0.4})
			await 等(1.2); c.set("自动", {}); await 等(1.0)
		await 存(目录, "4_斜坡倾角")
		c.call("set_mode", "桅杆"); c.set("自动", {"油": 1.0, "转": -1.0}); await 等(1.0); await 存(目录, "5_桅杆_右弧")
		c.set("自动", {})
		帮助(true); await 等(0.4); await 存(目录, "6_帮助"); 帮助(false)
		c.call("set_mode", "俯视"); 档 = 5; 轨迹脏 = true; 设时(10*60.0); await 等(1.2); await 存(目录, "7_俯视_远图_上午")
		档 = 1; 轨迹脏 = true; c.call("set_mode", "跟车")
	else:
		var f: Camera3D = P.fly; var p0 := f.global_position
		for i in 120:
			var t := i/119.0
			f.global_position = p0 + Vector3(-5.0*sin(t*PI*0.8), 0.0, 7.0*t); f.rotate_y(0.003)
			await get_tree().process_frame
		await 存(目录, "1_自由飞行")
		帮助(true); await 等(0.4); await 存(目录, "6_帮助"); 帮助(false)
	await 等(1.0)
	var r0 := [0.0, 0.0, 0.0, 0.0]; var r1 := [0.0, 0.0, 0.0, 0.0]          # 关 / 开交替 4 轮，各 1.5 s，抵消场景自己的漂移
	var 差s: Array[float] = []
	for k in 4:
		var a: Array = await 量(false); var b: Array = await 量(true)
		print("[界面]   第 %d 轮 GPU 关 %.3f / 开 %.3f ms" % [k + 1, a[1], b[1]])
		for i in 4: r0[i] += a[i]/4.0; r1[i] += b[i]/4.0
		差s.append(b[1] - a[1])
	差s.sort()
	print("[界面] GPU 差 各轮中位数 %+.3f ms（第一轮常有场景收敛的尖峰，看中位数）" % (0.5*(差s[1] + 差s[2])))
	print("[界面] 开销 界面关：帧 %.2f ms，GPU %.3f ms，CPU 渲染 %.3f ms" % r0.slice(0, 3))
	print("[界面] 开销 界面开：帧 %.2f ms，GPU %.3f ms，CPU 渲染 %.3f ms；界面脚本 %.4f ms/帧" % r1)
	print("[界面] 差：GPU %+.3f ms，CPU 渲染 %+.3f ms" % [r1[1] - r0[1], r1[2] - r0[2]])
	print("[界面] 自测完")
	get_tree().quit()


func 等(t: float) -> void:
	await get_tree().create_timer(t).timeout


func 找坡() -> Vector4:
	"""停车位 40 m 内 2 m 一格找坡度最大（≤ 24°）的地方 → (x, z, 坡度 rad, 车头 ψ)；ψ 按控制模块的约定 前 = (cos ψ, 0, sin ψ)。"""
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


func 量(on: bool) -> Array:
	根.visible = on
	await 等(0.4)
	var rid := get_viewport().get_viewport_rid()
	var n := 0; var fs := 0.0; var gs := 0.0; var cs := 0.0; var t0 := Time.get_ticks_usec(); var last := t0
	var 界0 := 界总; var 数0 := 帧总
	while Time.get_ticks_usec() - t0 < 1500000:
		await get_tree().process_frame
		var now := Time.get_ticks_usec(); fs += (now - last)/1000.0; last = now
		gs += RenderingServer.viewport_get_measured_render_time_gpu(rid); cs += RenderingServer.viewport_get_measured_render_time_cpu(rid); n += 1
	return [fs/n, gs/n, cs/n, (界总 - 界0)/maxf(1.0, float(帧总 - 数0))]


func 存(目录: String, 名: String) -> void:
	await RenderingServer.frame_post_draw
	var p := 目录.path_join(名 + ".png")
	get_viewport().get_texture().get_image().save_png(p)
	印区域(名)
	print("[界面] 截图 %s ｜ 模式 %s 航向 %.1f° 俯仰 %+.1f° 横滚 %+.1f° 倾角 %.1f° 速 %s 原地 %s 转向 %s 升降(cm) %s" % [
		名, 模式, 航显, 俯, 滚, 倾, str(速), str(原地), str(Array(轮转).map(func(x): return snappedf(rad_to_deg(x), 0.1))), str(Array(轮升).map(func(x): return snappedf(x*100.0, 0.1)))])


func 印区域(名: String) -> void:
	"""量对比度用（界面/对比度.py）：第一次调用时打印各仪表区域（像素矩形）。"""
	if not 名.begins_with("1"): return
	var R := {"航向带": 航向.get_global_rect(), "姿态仪": 姿态.get_global_rect(), "车轮速度": 车轮.get_global_rect(),
		"太阳表": 太阳.get_global_rect(), "小地图": 图.get_global_rect(), "图注": 图注.get_global_rect(), "角标": 角标.get_global_rect()}
	var o := {}
	for k in R: var r: Rect2 = R[k]; o[k] = [roundi(r.position.x), roundi(r.position.y), roundi(r.size.x), roundi(r.size.y)]
	print("[界面] 区域 ", JSON.stringify(o))
