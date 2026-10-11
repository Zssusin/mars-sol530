# 主菜单 a「活沙盘」（用户 2026-10-08 选定；样张 docs/界面/主菜单样张/样张_a_*.png，说明 说明.md「a」；体系 docs/界面/UI体系.md）。
#   游戏场景本身就是背景：相机在 16:30 的侧光里慢慢绕车（1 圈约 4 分钟）；车下是罗盘环（界面/地面.gd 的 Decal，半径 3.4 m）；
#   菜单项是立在环前半圈上的小标（件.小标 同一画法，按屏幕横坐标等距挑锚点）；选中项换「活」色、立杆加高，车和它之间铺地面人字箭头。
#   流程：载入（界面/载入.gd，2D 细环当进度）→ 落地（2D 环变形成地面环的投影、淡出，地面环淡入，小标逐个立起）→ 菜单
#     → 进游戏：相机从绕车机位推到跟车机位（不切黑），HUD 回来。游戏里 Esc 第二次 → 回到这里（世界暂停，代替老的暂停菜单）。
#   页：设置（画质预设、界面档、地面图形亮度、单位、语言占位、配色、字号、界面动效；存 user://设置.cfg）、关于（版本、数据、许可、署名）。
#   不加载的情况（令.要菜单() 为假）：自测（界面 / 玩法 / 控制测试）、测帧、渲染、视频、--菜单=0、没有控制模块。
#   开销：绕车相机 + 1 个环 Decal + 3 个箭头 Decal + 一层 2D；进游戏后整个藏起来（地面图形全藏，_process 只看状态）。
# 自测：--菜单测试[=目录]（界面/菜单测试.sh）：载入、落地、各选中项、设置、关于、进游戏、Esc 回来的截图 + 计时。
extends Node

const 件 := preload("res://界面/件.gd")
const 地线脚本 := preload("res://界面/地线.gd")
const 地面脚本 := preload("res://界面/地面.gd")
const 载入脚本 := preload("res://界面/载入.gd")
const 环R := 3.4
const 设机位 := {"pos": Vector3(-5.6777, 1.3516, -2.0727), "fwd": Vector3(0.989654, 0.064956, 0.12793), "up": Vector3(-0.06442, 0.997888, -0.008327), "hfov": 50.0}
#   设置页相机 = 样张 a_设置 的底图机位「a_仰视」（docs/界面/主菜单样张/生成/机位.json），世界坐标原样；hfov 50° = Camera3D.fov（KEEP_WIDTH 时 fov 就是水平视场）。
const 桅杆样张 := Vector3(-0.875698, 2.03704, 0.255576)           # 样张里引线锚的桅杆头（机位.json「桅杆」），和游戏里 控制.mast_local 变到世界是同一点
const 设距k := 0.8                                                # 样张设置页纵向间距 × 0.8：我们比样张多 5 个真实选项（配色、字号、动效、全屏、垂直同步），挤进同一屏
const 标题机位 := {"pos": Vector3(-6.2167, 2.3479, 12.7883), "fwd": Vector3(0.416768, -0.165816, -0.893762), "up": Vector3(0.070077, 0.986157, -0.15028), "hfov": 42.0}
#   标题页相机 = 样张 a_标题（docs/界面/主菜单样张/生成/机位.json），世界坐标原样；慢绕从这个机位出发（绕 = 方位角，起点 绕0；绕位 把样张机位绕车转 绕 − 绕0）
const 样张车心 := Vector3(-0.3, 0.8939, 0.1)
const 页fov := {"": 42.0, "设置": 50.0, "关于": 62.0}
const 菜单时 := 16.0*60.0 + 30.0                   # 16:30 侧光
const 绕速 := 0.025                                # rad/s（1 圈约 4 分钟）
const 项 := [
	{"键": "继续", "名": "继续", "说": "回到上次的模式", "图": "执行"},          # 说 = 悬停 0.35 s 才出的提示（不常驻）；图 = 各项自己的图标（界面 5）
	{"键": "A", "名": "自由漫游", "说": "开车、拍照、找兴趣点、复刻 NASA 照片", "图": "车轮"},
	{"键": "B", "名": "火星日规划", "说": "规划一个火星日的驾驶，上传，看它执行", "图": "地图"},
	{"键": "相册", "名": "相册", "说": "兴趣点、拍过的照片、复刻挑战", "图": "相册"},
	{"键": "设置", "名": "设置", "说": "画质、界面、单位、语言、配色", "图": "设置"},
	{"键": "关于", "名": "关于", "说": "版本、数据来源、许可", "图": "帮助"},
	{"键": "退出", "名": "退出", "说": "离开游戏", "图": "关闭"},
]
const 设项 := [                                                    # [键, 名, 选项（空 = 动态）, 类（选 / 滑 / 钮）, 组]
	["画质", "预设", [], "选", 0],                                     # 值 = 环境.预设列表()（低 / 中 / 性能 / 高）+ 手改后自动出现的「自定义」
	["缩放", "3D 分辨率", [], "滑", 0],                                 # 参数「缩放」50–100 %
	["AA", "抗锯齿", ["TAA", "FSR 2", "关"], "选", 0],                  # 参数「AA」：TAA / FSR2 / 无（MSAA 2× 不加：比 TAA 多 ~3.5 ms，高档预算放不下）
	["界面档", "界面档位", ["关", "精简", "完整"], "选", 1],
	["地亮", "地面图形亮度", [], "滑", 1],
	["配色", "配色", [], "选", 1],
	["字号", "字号", ["标准", "大", "特大"], "选", 1],
	["动效", "界面动效", ["正常", "减半", "关"], "选", 1],
	["全屏", "全屏", ["关", "开"], "选", 2],                            # [显示] 节，立刻生效
	["垂直同步", "垂直同步", ["开", "关"], "选", 2],
	["单位", "单位", ["公制", "英制"], "选", 2],
	["语言", "语言", ["简体中文", "English"], "选", 3],
	["重启", "生效", ["重启并应用"], "钮", 3],                          # 最后一项，画在页底；画质预设变了才出现（多数参数要重建场景）
]
const 设组 := [["画质", "拍照"], ["界面", "地图"], ["显示与单位", "里程"], ["语言", "帮助"]]   # [名, 图标]
const AA名 := ["TAA", "FSR2", "无"]                                  # 设项「AA」第 i 个选项对应的参数值（环境 / 实景.gd 认的名字）
const 缩放范围 := Vector2(50, 100)                                   # %
const 地亮范围 := Vector2(50, 130)                                   # %，步长 5
const 预设说 := {                                                    # 预设内容（环境.预设表）一行话；测帧实测见 预设测 
	"高": "TAA · 原生分辨率 · 全部效果开（画质基准）",
	"性能": "FSR 2 · 渲染 77 %，其余同「高」",
	"中": "FSR 2 · 渲染 77 % · SSAO 半分辨率 · 阴影 100 m · 石块、地面降采样",
	"低": "FSR 2 · 渲染 67 % · 无 SSAO · 阴影 80 m · 2 级联 · SDFGI 慢更新 · 石块、地面更粗"}
const 预设测 := {                                                    # 预设 → [地面, 绕车, 远足] 帧平均 ms（godot/测帧.sh 2560×1440，测试机；唯一的数表，重测只改这里）
	"高": [8.7, 10.2, 9.8], "性能": [6.9, 8.1, 7.7], "中": [6.0, 7.1, 6.6], "低": [4.2, 4.8, 4.8]}   # 协调者 2026-10-09 自编引擎 + C++ 重测（~/日志/预设测帧.log）；界面 4 自测同值

var P: Node
var 控: Node
var 玩: Node
var 界: Node
var 层: CanvasLayer
var 画: Control
var 机: Camera3D
var 地: Node3D
var 载: Node = null                                # 载入画面（落地时接手、淡掉）
var 态 := "等"                                     # 等 → 落地 → 菜单 → 出发 → 关；回来（游戏里 Esc）→ 菜单
var 报过抓 := false
var 页 := ""                                       # "" / 设置 / 关于
var 选 := 1
var 设行 := 0
var 设点: Array = []                                # 设置页每行的命中框 {i, 行, 项[], 滑}（画的时候填，鼠标用）
var 设悬 := Vector2i(-1, -1)                         # 鼠标指着的设置项（行, 选项号；选项号 −1 = 只在行上）
var 设按 := Vector2i(-1, -1)                         # 鼠标按下时按在哪（抬起时还在同一选项才触发）
var 设悬行 := -1                                    # 鼠标所在行（悬停提示用；−1 = 鼠标不在行上）
var 拖滑 := -1                                      # 正在拖的滑条行号
var 启动档 := "高"                                 # 这次启动用的画质预设（和设置里的不同 → 要重启）
var 需重启 := false
var 态t := 0.0
var 帧 := 0
var 绕 := 0.0
var 标出: Array[float] = []                        # 每个小标的出现进度
var 选t := 9.0                                     # 换选中项后多久（箭头重铺、立杆升高）
var 标位: Array = []                                # 每项 [落地点 Vector3, 屏幕落地点 Vector3, 屏幕图标点 Vector3, 命中框 Rect2]
var 从游戏 := false                                 # 游戏里 Esc 进来的（世界暂停着）
var 改了时 := false
var 起xf := Transform3D()
var 去机: Camera3D = null
var 动作 := ""
var 页a := 0.0
var 机目标 := Transform3D()
var 测 := ""                                        # 自测目录
var 计时 := {}
var 悬项 := -1                                      # 鼠标指着的菜单项（-1 = 没有）；悬停提示用
var 按项 := -1                                      # 鼠标按下时按在哪一项上（抬起时还在同一项才触发）
var 鼠标位 := Vector2.ZERO
var 停绕 := false                                   # 自测 / 样张对照：不转
var 绕0 := 0.0                                      # 样张机位的方位角
var 环线: Node3D = null                              # 屏宽线：罗盘环（主）、短刻线、选中项的人字箭头
var 刻线: Node3D = null
var 箭线: Node3D = null
var 环脏 := true
var 箭签 := ""
var 项k: Array[float] = []                         # 每项的选中度 0–1（图标 / 名字放大、变色的动画）
var 车盒: AABB = AABB()                             # 车在自身坐标里的包围盒（标 北东南西 时判断被不被车挡）
var 车盒好 := false
var 录鼠标开 := false                                # 录像时在画面上画一个鼠标指针（Movie Maker 录不到系统光标）
var 录按 := false


func _init(p: Node) -> void:
	P = p; name = "主菜单"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	载 = 令.载入层
	if not 令.要菜单() or P.get_node_or_null("控制") == null:
		if 载: 载.queue_free(); 令.载入层 = null
		queue_free(); return
	控 = P.get_node("控制"); 玩 = P.get_node_or_null("玩法"); 界 = P.get_node_or_null("界面")
	测 = String(P.args.get("菜单测试", "")) if P.args.has("菜单测试") else ""
	if P.args.has("菜单测试") and 测 == "": 测 = "user://菜单测试"
	层 = CanvasLayer.new(); 层.layer = 40; add_child(层)
	画 = Control.new(); 画.set_anchors_preset(Control.PRESET_FULL_RECT); 画.mouse_filter = Control.MOUSE_FILTER_IGNORE
	画.draw.connect(_画); 层.add_child(画)
	机 = Camera3D.new(); 机.name = "菜单相机"; 机.near = 0.05; 机.far = 200000.0
	机.keep_aspect = Camera3D.KEEP_WIDTH; 机.fov = 页fov[""]
	add_child(机)
	地 = 地面脚本.new(P, 环R); add_child(地)
	for i in 项.size(): 标出.append(0.0); 项k.append(0.0)
	环线 = 地线脚本.new(3.0, 3.2, 0); 刻线 = 地线脚本.new(2.0, 3.2, 0); 箭线 = 地线脚本.new(4.0, 3.2, 2)
	for n in [环线, 刻线, 箭线]: add_child(n); n.visible = false
	令.变了.connect(func(): 环脏 = true; if 画: 画.queue_redraw())
	应用设置()
	if 界: 界.visible = false
	控.set("自动", {"油": 0.0, "转": 0.0, "原地": 0.0})              # 菜单开着时车不收键（控制.gd 的自动输入口）
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE; P.set_meta("menu_mouse", true)
	P.set_time_f(菜单时); 改了时 = true
	绕0 = atan2(标题机位["pos"].x - 样张车心.x, -(标题机位["pos"].z - 样张车心.z)); 绕 = 绕0
	选 = 0 if 有存档() else 1
	机.global_transform = 绕位(绕); 机.current = true
	计时["菜单就绪_ms"] = Time.get_ticks_msec()
	if 载: 载.进度("天空", 0.88)
	if 令.菜单录() != "":
		var ua := " ".join(OS.get_cmdline_user_args())
		if ua.contains("--录鼠标"): 录鼠标.call_deferred()
		elif ua.contains("--录开车"): 录开车.call_deferred()
		elif ua.contains("--录相册"): 录相册.call_deferred()
		else: 录.call_deferred()
	elif 测 != "": 自测.call_deferred()


# ———————————————————— 设置（user://设置.cfg，令.设置）
func 应用设置() -> void:
	var S: Dictionary = 令.设置
	启动档 = String(环境.参数().get("画质预设", "高")); S["画质"] = 启动档 if not 令.测菜单() and 环境.设置读("画质预设", "") == "" else S["画质"]
	用画质(); 需重启 = String(S["画质"]) != 启动档
	if not 令.测菜单() and 环境.用设置(): 用显示()
	用地亮()
	地.亮 = 0.85


func 用地亮() -> void:
	if 界 and 界.get("地"): 界.地.亮 = float(令.设置["地亮"])/100.0


func 有效画质() -> Dictionary:
	"""预设内容 + 设置页手改的 缩放 / AA（令.设置 里空串 = 跟预设）。写进 [参数] 节的也是这两项，环境.参数() 合并时手改覆盖预设。"""
	var d: Dictionary = 环境.预设内容(String(令.设置["画质"]))
	if String(令.设置["缩放"]) != "": d["缩放"] = String(令.设置["缩放"])
	if String(令.设置["AA"]) != "": d["AA"] = String(令.设置["AA"])
	return d


func 自定义() -> bool:
	return String(令.设置["缩放"]) != "" or String(令.设置["AA"]) != ""


func 缩放值() -> float:
	return float(有效画质().get("缩放", "1.0"))


func AA值() -> String:
	return String(有效画质().get("AA", "TAA"))


func 渲染尺寸() -> Vector2i:
	return Vector2i((Vector2(get_window().size)*缩放值()).round())


func 用画质() -> void:
	"""画质的预览：只立刻换 抗锯齿 + 3D 缩放（背景马上看得到）；其余（SSAO、阴影、撒石……）要重建场景，走「重启并应用」。
	预设内容来自 环境.预设内容()（工程化方案 §6.0），手改叠在上面（有效画质）。规则同 实景.gd：AA=FSR2 用 FSR2 放大，TAA / 无 用双线性放大。"""
	var vp := get_viewport(); var aa := AA值(); var sc := 缩放值()
	if aa == "FSR2":
		vp.use_taa = false; vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
	else:
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR; vp.use_taa = aa == "TAA"
	vp.scaling_3d_scale = sc


func 用显示() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if 环境.设置读("全屏", "0", "显示") == "1" else DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if 环境.设置读("垂直同步", "1", "显示") == "1" else DisplayServer.VSYNC_DISABLED)


func 有存档() -> bool:
	return FileAccess.file_exists("user://玩法A.json") or FileAccess.file_exists("user://玩法B.json")


# ———————————————————— 相机
func 车心() -> Vector3:
	var rr: Node3D = P.rover_root
	return rr.global_position if rr and is_instance_valid(rr) else Vector3.ZERO


func 侧光角() -> float:
	"""太阳方位（从车看太阳，0 = 北、顺时针）+ 90°：侧光。"""
	var d: Vector3 = P.sun.global_transform.basis.z if P.sun else Vector3(1, 0, 0)
	return atan2(d.x, -d.z) + PI*0.5


func 绕位(a: float) -> Transform3D:
	"""标题页相机：样张 a_标题 的机位绕车（竖轴）转 a − 绕0；a = 绕0 时和样张逐像素对得上。"""
	var c := 车心(); var d := a - 绕0
	var rel: Vector3 = 标题机位["pos"] - Vector3(样张车心.x, 0, 样张车心.z)
	var 基 := Basis(Vector3.UP, -d)
	var p := Vector3(c.x, 0, c.z) + 基*Vector3(rel.x, 0, rel.z)
	p.y = 标题机位["pos"].y + (地高(c) - 地高(样张车心) if P.lod else 0.0)
	return Transform3D(基*Basis.looking_at(标题机位["fwd"], 标题机位["up"]), p)


func 页位() -> Transform3D:
	var o := 车心()
	if 页 == "设置":                                                 # 样张 a_设置 的机位（a_仰视）：低位仰看车头和桅杆，车在右半屏
		return Transform3D(Basis.looking_at(设机位["fwd"], 设机位["up"]), 设机位["pos"])
	if 页 == "关于":                                                 # 逆光看地平线（太阳在画里）
		var d: Vector3 = P.sun.global_transform.basis.z; var h := Vector3(d.x, 0, d.z).normalized()
		var p := o - h*7.5; p.y = 地高(p) + 1.7
		return Transform3D(Basis.looking_at(h*60.0 + Vector3(0, 3.5, 0), Vector3.UP), p)
	return 绕位(绕)


func 地高(p: Vector3) -> float:
	return P.lod.h_cpu(p.x, p.z, 0) if P.lod else p.y


# ———————————————————— 每帧
func _process(dt: float) -> void:
	if 态 in ["等", "落地", "菜单", "回来"] and not 相册开() and Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:   # 菜单开着鼠标必须能动：别的模块（玩法的 还鼠标()、控制的点一下抓回）会把它抓走，这里每帧放开
		if not 报过抓: 报过抓 = true; print("[主菜单] 鼠标被别的模块抓走了，已放开（态 %s，第 %d 帧）" % [态, Engine.get_process_frames()])
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if 态 == "关": return
	dt = minf(dt, 0.1)
	态t += dt; 帧 += 1; 选t += dt
	if get_tree().paused and 玩: 玩.世界更新(机)                         # 世界暂停时替 实景.gd 跑地面 LOD、天空（同 拍照模式）
	if get_viewport().get_camera_3d() != 机 and 态 != "出发": 机.current = true
	match 态:
		"等":                                                          # 3D 搭好了，等几帧和换天空（16:30）的后台活
			var 好 := 帧 > 6 and int(P.get("sky_task")) < 0 and String(P.get("sky_pending")) == ""
			if 载: 载.比 = minf(0.99, 0.88 + 态t*0.03); 载.画()
			if 好 or 态t > 4.0:
				计时["落地_ms"] = Time.get_ticks_msec(); 换态("落地")
		"落地":
			if 态t > 1.2: 换态("菜单")
		"出发":
			var k := 令.缓(clampf(态t/1.2, 0.0, 1.0), "入出")
			if 去机: 机.global_transform = 起xf.interpolate_with(去机.global_transform, k)
			if 态t >= 1.2: 收尾出发()
	if 态 in ["等", "落地", "菜单", "回来"]:
		if 页 == "" and not 停绕: 绕 += 绕速*dt
		var 目 := 页位()
		var k2 := 1.0 - exp(-dt*3.0)
		机.global_transform = 目 if (态 in ["等", "落地"]) else 机.global_transform.interpolate_with(目, k2)
		机.fov = 页fov[页] if (态 in ["等", "落地"]) else lerpf(机.fov, 页fov[页], k2)
	页a = move_toward(页a, 1.0 if 页 != "" else 0.0, dt/maxf(令.时长("慢"), 0.001) if 令.动倍 > 0.0 else 1.0)
	for i in 标出.size():
		var 要 := 态 in ["落地", "菜单", "回来"] and 页 == "" and not 相册开()
		var 迟 := (0.45 + i*令.时["错"]) if 态 == "落地" else 0.0
		if 要 and 态 == "落地" and 态t < 迟: continue
		标出[i] = 件.进({0: 标出[i]}, 0, 要, dt)
	更地面(dt)
	var 提键 := ""
	if 页 == "" and 态 == "菜单" and 悬项 >= 0: 提键 = "项%d" % 悬项
	elif 页 == "设置" and 设悬行 >= 0 and 拖滑 < 0: 提键 = "设%d" % 设悬行
	件.提示更(提键, dt)
	if 载 and 态 != "等": 载.queue_free(); 载 = null; 令.载入层 = null
	画.queue_redraw()


func 换态(s: String) -> void:
	态 = s; 态t = 0.0


func 相册开() -> bool:
	return 玩 != null and 玩.get("图鉴") != null and bool(玩.图鉴.开着)


func 更地面(dt: float) -> void:
	var o := 车心(); var rr: Node3D = P.rover_root
	var 航 := 0.0
	if rr: var f := rr.global_transform.basis.z; 航 = atan2(f.x, -f.z)
	var 环a := 0.0
	match 态:
		"落地": 环a = clampf((态t - 0.25)/0.4, 0.0, 1.0)
		"菜单", "回来": 环a = 1.0
		"出发": 环a = 1.0 - clampf(态t/0.5, 0.0, 1.0)
	if 页 != "" or 相册开(): 环a *= 0.0
	地.隐环 = true                                                   # 标题页的环、刻度、箭头改用屏宽线（地线.gd）：线宽不随透视变，不被地形投影弄断
	地.每帧(dt, Transform3D(Basis(), o), false, 航, true, 环a)
	地.摆箭([])
	for n: Node3D in [环线, 刻线]: n.visible = 环a > 0.01
	箭线.visible = 环a > 0.01
	if 环a <= 0.01: return
	if 环脏 or 环线.本.mesh == null: 建环线(o)
	环线.着色参(令.色["主"], 环a*0.95, Color(令.色["暗"], 0.55)); 刻线.着色参(令.色["主"], 环a*0.85, Color(令.色["暗"], 0.55))
	更箭线(o, 环a)


func 线高(x: float, z: float) -> float:
	return 地高(Vector3(x, 0, z)) + 0.03                              # 抬 3 cm（再加着色器里的深度偏移；抬高 10 cm 在这个机位会让线偏上 20 px，和样张对不上）


func 建环线(o: Vector3) -> void:
	"""罗盘环（样张 a2.py）：半径 环R、3 px 细线；每 10° 一道刻线，内伸 0.14 m，四个正方向 0.28 m（3 px）。"""
	环脏 = false
	var 环段: Array = []; var 短: Array = []
	for k in 360:
		var a0 := deg_to_rad(k); var a1 := deg_to_rad(k + 1)
		var p0 := Vector3(o.x + sin(a0)*环R, 0, o.z - cos(a0)*环R); var p1 := Vector3(o.x + sin(a1)*环R, 0, o.z - cos(a1)*环R)
		p0.y = 线高(p0.x, p0.z); p1.y = 线高(p1.x, p1.z); 环段.append([p0, p1, 1.0])
	for b in range(0, 360, 10):
		var a := deg_to_rad(b); var 北 := b % 90 == 0; var r1 := 环R - (0.28 if 北 else 0.14)
		var q0 := Vector3(o.x + sin(a)*环R, 0, o.z - cos(a)*环R); var q1 := Vector3(o.x + sin(a)*r1, 0, o.z - cos(a)*r1)
		q0.y = 线高(q0.x, q0.z); q1.y = 线高(q1.x, q1.z)
		(环段 if 北 else 短).append([q0, q1, 1.0])
	环线.设(环段, 令.色["主"], 0.95); 刻线.设(短, 令.色["主"], 0.85)


func 更箭线(o: Vector3, 环a: float) -> void:
	"""选中项朝外的三个人字箭头（样张：4 px 细折线，「活」色）；换选中项时一个个重新画出来（每个 0.2 s，错开 0.06 s）。"""
	if 选 >= 标位.size() or 标位[选].is_empty(): 箭线.本.mesh = null; 箭线.边.mesh = null; return
	var 签 := "%d|%.2f|%s" % [选, minf(选t, 1.0), 令.板]
	if 签 == 箭签: return
	箭签 = 签
	var 方: float = 标位[选][5]; var sx := sin(方); var cy := cos(方)             # (E, N) = (sin, cos)；世界 x = E，z = −N
	var 段: Array = []; var w := 0.26
	for k in 3:
		var r := 1.9 + 0.5*k
		var al := 1.0 if 令.动倍 <= 0.0 else clampf((选t - k*0.06)/(0.2*令.动倍), 0.0, 1.0)
		if al <= 0.0: continue
		var cE := o.x + r*sx; var cN := -o.z + r*cy
		var q := [Vector2(cE - sx*w - cy*w, cN - cy*w + sx*w), Vector2(cE, cN), Vector2(cE - sx*w + cy*w, cN - cy*w - sx*w)]
		var P3: Array = []
		for v: Vector2 in q: P3.append(Vector3(v.x, 线高(v.x, -v.y), -v.y))
		段.append([P3[0], P3[1], al]); 段.append([P3[1], P3[2], al])
	箭线.设(段, 令.色["活"], 0.95*环a)


# ———————————————————— 画
func _画() -> void:
	var c := 画; var vs := c.size; var s := 令.s
	if 机 == null: return
	var 主: Color = 令.色["主"]
	# 落地：2D 进度环变形成地面环的投影，同时淡出；黑底淡出
	if 态 in ["等", "落地"]:
		var 底a := 1.0 if 态 == "等" else 1.0 - 令.缓(clampf(态t/0.45, 0.0, 1.0))
		var 变 := 0.0 if 态 == "等" else 令.缓(clampf(态t/0.45, 0.0, 1.0), "入出")
		var 环a := 1.0 if 态 == "等" else 1.0 - clampf((态t - 0.3)/0.35, 0.0, 1.0)
		if 态 == "落地":
			c.draw_rect(Rect2(Vector2.ZERO, vs), Color(0, 0, 0, 底a))
			画落环(c, vs, 变, 环a)
	if 态 == "等": return
	var 文a := 1.0 - 页a
	if 文a > 0.01: 画主(c, vs, s, 文a)
	if 页a > 0.01:
		件.左渐变(c, vs, 令.色["页底"], 页a)
		if 页 == "设置": 画设置(c, vs, s, 页a)
		elif 页 == "关于": 画关于(c, vs, s, 页a)
	if 录鼠标开:
		var q := 鼠标位; var 白 := Color.WHITE
		if 录按: c.draw_arc(q, 20*s, 0, TAU, 24, Color(令.色["活亮"], 0.9), 3*s)
		var 箭 := PackedVector2Array([q, q + Vector2(0, 26)*s, q + Vector2(7, 20)*s, q + Vector2(13, 31)*s, q + Vector2(18, 28)*s, q + Vector2(12, 18)*s, q + Vector2(21, 18)*s])
		c.draw_colored_polygon(箭, 白); c.draw_polyline(箭 + PackedVector2Array([箭[0]]), Color(0, 0, 0, 0.9), 1.6*s)


func 画落环(c: CanvasItem, vs: Vector2, 变: float, a: float) -> void:
	"""载入的 2D 圆（载入.gd 的 环心 / 环半）→ 地面罗盘环在屏幕上的椭圆，按 变 插值。
	对应关系按屏幕角度：地面环上每个点对到「同一屏幕方向」的圆上点，插值不会拧成麻花。"""
	var o2 := Vector2(vs.x*载入脚本.环心.x, vs.y*载入脚本.环心.y); var r2 := vs.x*载入脚本.环半
	var o := 车心(); var pts := PackedVector2Array()
	if 机.is_position_behind(o): return
	var qc := 机.unproject_position(o)
	for i in 97:
		var tt := TAU*(i % 96)/96.0
		var w := o + Vector3(sin(tt), 0, -cos(tt))*环R; w.y = 地高(w) + 0.02
		if 机.is_position_behind(w): continue
		var q := 机.unproject_position(w)
		var phi := atan2(q.y - qc.y, q.x - qc.x)
		pts.append((o2 + Vector2(cos(phi), sin(phi))*r2).lerp(q, 变))
	if a > 0.01 and pts.size() > 2: 件.折(c, pts, Color(令.色["主"], 0.95*a), 2.0)


func 时刻串() -> String:
	var m: float = float(P.get("time_m")) if P.get("time_m") != null and float(P.get("time_m")) >= 0.0 else 菜单时
	return "%02d:%02d" % [int(m)/60 % 24, int(m)%60]


func 画主(c: CanvasItem, vs: Vector2, s: float, a: float) -> void:
	"""开始页面（样张 docs/界面/主菜单样张/样张_a_标题_v2.png，生成 a2.py；位置、字号、线宽 1:1，2560×1440）：
	左上 游戏图标 + 「杰泽罗」+ 强色短线 + 一行等宽小字；7 项各有自己的图标，选中项 56 px 活色 + Enter 键帽；底部左两个键帽，右下版本。说明句不常驻（悬停 0.35 s 出）。"""
	var 主: Color = 令.色["主"]; var 活: Color = 令.色["活"]
	# 界面 6：不再压整屏渐暗（画面亮度以样张为准）；字和图标的对比度靠描边（件.字串 / 图标 的不透明描边，规范 §5）
	var 图: Texture2D = 令.图标贴图()
	if 图: c.draw_texture_rect(图, Rect2(Vector2(120, 100)*s, Vector2(128, 128)*s), false, Color(1, 1, 1, a))
	件.字距(c, Vector2(292, 190)*s, 令.片名, 96.0, Color(主, a), "片", 18.0)
	件.线(c, Vector2(296, 212)*s, Vector2(356, 212)*s, Color(令.色["强"], a), 3.0, false)
	件.字串(c, Vector2(296, 250)*s, "SOL 530 · %s" % 时刻串(), 24.0, Color(主, 0.95*a), "等")
	# 环上 北 东 南 西（环内 0.62 m；被车挡住的不画）
	if not 车盒好 and 态 == "菜单": 车盒算()
	var o := 车心()
	for b in range(0, 360, 90):
		var r := deg_to_rad(b); var w := o + Vector3(sin(r), 0, -cos(r))*(环R - 0.62); w.y = 地高(w)
		if 机.is_position_behind(w): continue
		var q := 机.unproject_position(w)
		if (w - 机.global_position).length() > (o - 机.global_position).length() and 车遮(q): continue
		件.字串(c, q + Vector2(0, 9*s), "北东南西"[b/90], 26.0, Color(主, 0.95*a), "粗", HORIZONTAL_ALIGNMENT_CENTER)
	算标位(vs)
	for i in 项.size():
		if 标位[i].is_empty() or 标出[i] <= 0.001: continue
		var k: float = 项k[i]; var ea: float = a*件.趋("菜单出%d" % i, 标出[i], 0.05)
		var 禁: bool = 项[i]["键"] == "继续" and not (有存档() or 从游戏)
		var col: Color = 主.lerp(活, k); col.a *= ea*(令.透["禁"] if 禁 else 1.0)
		var g0: Vector2 = 标位[i][4]; var g1 := Vector2(标位[i][1].x, 标位[i][1].y); var top := Vector2(标位[i][2].x, 标位[i][2].y)
		var 尺 := lerpf(40.0, 56.0, k); var 字号 := lerpf(30.0, 42.0, k)
		if i == 按项: c.draw_set_transform_matrix(Transform2D(0.0, Vector2.ONE*令.点击["按缩"], 0.0, top*(1.0 - 令.点击["按缩"])))
		件.线(c, g0, g1, col, lerpf(3.0, 4.0, k), false)                                   # 环上点 → 落地点（环外 0.42 m）
		件.线(c, g1, g1.lerp(top + Vector2(0, lerpf(22.0, 30.0, k))*s, 令.缓(标出[i])), col, lerpf(1.5, 3.0, k), false)
		件.点(c, g1, lerpf(3.0, 5.0, k), col)
		件.图标(c, 项[i]["图"], top, 尺, col)
		var nx := top.x + 尺*0.5*s + lerpf(10.0, 16.0, k)*s; var ny := top.y + lerpf(10.0, 15.0, k)*s
		var 名: String = 项[i]["名"]
		件.字串(c, Vector2(nx, ny), 名, 字号, col, "粗" if k > 0.5 else "中")
		if 禁: c.draw_line(Vector2(nx, ny - 字号*0.3*s), Vector2(nx + 件.宽度(名, 字号), ny - 字号*0.3*s), col, maxf(1.0, 2.0*s))
		if k > 0.02: 件.键帽(c, Vector2(nx + 件.宽度(名, 字号, "粗") + 22*s, top.y + 9*s), "Enter", Color(主, a*ea*k), 19.0)
		if i == 按项: c.draw_set_transform_matrix(Transform2D.IDENTITY)
	# 底部：左 两个键帽（不写字）、右 版本和声明
	var x := 120.0*s
	for 键 in ["← →", "Esc"]:
		x += 件.键帽(c, Vector2(x, 1346*s), 键, Color(主, a), 18.0) + 18*s
	件.字串(c, Vector2(vs.x - 120*s, 1352*s), "%s · 非 NASA 官方产品" % String(环境.信息.get("游戏", "?")), 18.0, Color(主, 0.9*a), "中", HORIZONTAL_ALIGNMENT_RIGHT, -1.0, true)
	if 悬项 >= 0 and 悬项 < 项.size() and 页 == "":
		var 说: String = 项[悬项]["说"]
		if 项[悬项]["键"] == "继续" and 从游戏: 说 = "回到游戏"
		件.提示画(c, 说, 鼠标位, vs)


func 算标位(vs: Vector2) -> void:
	"""每项一个锚点（样张 a2.py）：目标屏幕 x = 0.25W … 0.766W 等距，在环外 0.42 m 的圈上、近半圈里挑投影 x 最接近的方位；
	[0] 落地点（世界）[1] 落地点（屏幕）[2] 图标点（屏幕）[3] 命中框 [4] 环上点（屏幕）[5] 方位（rad）。图标 / 名字随选中度 40 → 56 px、30 → 42 px。"""
	标位.clear()
	var o := 车心(); var cp := 机.global_position; var s := 令.s
	var 候: Array = []
	for k in 360:
		var a := deg_to_rad(k); var w := o + Vector3(sin(a), 0, -cos(a))*(环R + 0.42); w.y = 地高(w)
		if (w - cp).length() > (o - cp).length() + 0.3 or 机.is_position_behind(w): continue
		候.append([机.unproject_position(w).x, a, w])
	for i in 项.size():
		var X := vs.x*(0.25 + 0.516*i/float(项.size() - 1))
		var best: Array = []; var bd := INF
		for q: Array in 候:
			var d := absf(float(q[0]) - X)
			if d < bd: bd = d; best = q
		if best.is_empty(): 标位.append([]); continue
		项k[i] = 件.趋("菜单项%d" % i, 1.0 if i == 选 else 0.0, 令.时["滑"])
		var k := 项k[i]
		var g: Vector3 = best[2]; var a: float = best[1]
		var g0 := o + Vector3(sin(a), 0, -cos(a))*环R; g0.y = 地高(g0)
		var 高 := 0.55 + 0.2*k
		var pg := 机.unproject_position(g); var pq := 机.unproject_position(g + Vector3(0, 高, 0))
		var 尺 := lerpf(40.0, 56.0, k); var 字号 := lerpf(30.0, 42.0, k)
		var 字w := 件.宽度(项[i]["名"], 字号, "粗" if k > 0.5 else "中") + (40*s + 件.宽度("Enter", 19)) * k
		var 低 := 机.unproject_position(g + Vector3(0, 0.55, 0)); var 顶 := 机.unproject_position(g + Vector3(0, 0.75, 0))   # 选中时图标会升高 0.2 m：命中框盖住升降两个位置，鼠标停着不动也不会因为图标升起而脱靶
		var 框高 := maxf(44.0, 尺 + 8.0)*s
		var 框 := Rect2(pq.x - 尺*0.5*s - 12*s, 顶.y - 框高*0.5, 尺*s + 字w + 34*s, (低.y - 顶.y) + 框高)
		标位.append([g, Vector3(pg.x, pg.y, 1), Vector3(pq.x, pq.y, 1), 框, 机.unproject_position(g0), a])


func 点中项(p: Vector2) -> int:
	"""选中项的名字很长（会盖到邻项的图标上）：框里有几个时取图标中心离鼠标最近的；一个都不在框里再用 8 px 容差（件.命中）。"""
	var 框: Array = []; var 最 := -1; var bd := INF
	for i in 标位.size():
		var q: Array = 标位[i]
		框.append(q[3] if not q.is_empty() else Rect2())
		if q.is_empty() or not (q[3] as Rect2).has_point(p): continue
		var d := Vector2(q[2].x, q[2].y).distance_to(p)
		if d < bd: bd = d; 最 = i
	return 最 if 最 >= 0 else 件.命中(框, p)


func 车盒算() -> void:
	"""车在自身坐标里的包围盒（一次）：标 北东南西 时判断「被不被车挡」。"""
	var rr: Node3D = P.rover_root
	if rr == null or not is_instance_valid(rr): return
	var inv := rr.global_transform.affine_inverse(); var 有 := false
	for g in rr.find_children("*", "VisualInstance3D", true, false):
		var v := g as VisualInstance3D
		var b: AABB = (inv*v.global_transform) * v.get_aabb()
		车盒 = b if not 有 else 车盒.merge(b); 有 = true
	车盒好 = 有


func 车遮(p: Vector2) -> bool:
	if not 车盒好: return false
	var rr: Node3D = P.rover_root; var pts := PackedVector2Array()
	for i in 8:
		var w: Vector3 = rr.global_transform*车盒.get_endpoint(i)
		if 机.is_position_behind(w): return false
		pts.append(机.unproject_position(w))
	return Geometry2D.is_point_in_polygon(p, Geometry2D.convex_hull(pts))


func 画设置(c: CanvasItem, vs: Vector2, s: float, a: float) -> void:
	"""样张 样张_a_设置.png 的版式，位置 / 字号 / 线宽取自 docs/界面/主菜单样张/生成/a.py（设置页 / 设置内容 / 页头 / 选项行 / 滑条 / 节），按 s 缩放；
	纵向间距 × 设距k（我们比样张多 5 个真实选项）。选项全部内联：选中 = 白色最亮 + 活亮下划线，其余暗灰；一行说明：预设下面是内容 + 实测帧时间，其余在底部。"""
	var 主: Color = 令.色["主"]; var 次: Color = 令.色["次"]
	var x0 := 200.0*s; var xv := 500.0*s; var 线宽 := 1000.0*s; var 滑宽 := 420.0*s
	件.页题(c, Vector2(230*s, 160*s), "设置", "", a)
	设点.clear()
	var m := 300.0; var 组 := -1; var n := 0                              # m：样张纵坐标（1440p），屏幕 y = (300 + k·(m − 300))·s
	var 总 := 设项.size() + 设组.size()
	var 选y := -1.0
	var 末: Array = []                                                    # 每组最后一行的下标
	for i in 设项.size():
		if 设项[i][0] == "重启": continue
		if i + 1 >= 设项.size() or 设项[i + 1][0] == "重启" or 设项[i + 1][4] != 设项[i][4]: 末.append(i)
	for i in 设项.size():
		var 键: String = 设项[i][0]; var 名: String = 设项[i][1]; var 类: String = 设项[i][3]
		if 键 == "重启": continue
		var 选中 := i == 设行
		if int(设项[i][4]) != 组:
			组 = int(设项[i][4])
			var ag := a*clampf(页a*(总 + 2.0) - n, 0.0, 1.0); n += 1
			件.组头(c, Vector2(x0, (300.0 + 设距k*(m - 300.0))*s), 线宽, 设组[组][0], 设组[组][1], ag)
			m += 76.0
		var y := (300.0 + 设距k*(m - 300.0))*s
		var ai := a*clampf(页a*(总 + 2.0) - n, 0.0, 1.0); n += 1             # 动效：设置行逐行出现（总共 ≤ 0.4 s）
		var 禁 := false                                                    # （语言已启用；禁用项的划线画法留着）
		件.行标(c, Vector2(x0, y), 名, 选中, false, ai, false)
		if 选中: 选y = y
		var 槽 := {"i": i, "行": Rect2(x0 - 40*s, y - 36*s, 线宽 + 40*s, 52*s), "项": [], "滑": Rect2()}
		match 类:
			"选": 槽["项"] = 件.选项(c, Vector2(xv, y), 选项表(i), 选项当前(i), ai, [1] if 禁 else [], 26.0, 设悬.y if 设悬.x == i else -1, 设按.y if 设按.x == i else -1, "设|" + 键)
			"滑":
				var 范 := 滑范围(键); var 值 := 滑值(键)
				var 滑 := Rect2(xv, y - 22*s, 滑宽, 26*s)
				var 悬滑 := 设悬行 == i or 拖滑 == i
				件.滑条(c, 滑, (值 - 范.x)/(范.y - 范.x), 选中, ai, 悬滑, 拖滑 == i, "%d %%" % roundi(值), "设|" + 键)
				件.字串(c, Vector2(xv + 滑宽 + 24*s, y), "%d %%" % roundi(件.趋("设值|" + 键, 值, 令.时["数"])), 22.0, Color(主, ai), "等")                      # 数字数到新值（0.3 s）
				槽["滑"] = 滑
		设点.append(槽)
		if 键 == "画质":                                                   # 预设下面两行（界面 5：图标 + 数字，句子进悬停提示）：渲染比例 + 抗锯齿 / 实测帧时间
			var 名p := String(令.设置["画质"]); var 测: Array = 预设测.get(名p, [])
			件.图标(c, "拍照", Vector2(xv + 11*s, y + 34*s), 22.0, Color(次, ai))
			件.字串(c, Vector2(xv + 30*s, y + 40*s), "%d %%  %s" % [roundi(缩放值()*100.0), ["TAA", "FSR 2", "关"][maxi(0, AA名.find(AA值()))]], 19.0, Color(次, ai), "等", HORIZONTAL_ALIGNMENT_LEFT, -1.0, true)
			件.图标(c, "速度", Vector2(xv + 11*s, y + 62*s), 22.0, Color(次, ai))
			件.字串(c, Vector2(xv + 30*s, y + 68*s), (" · ".join(测.map(func(v): return "%.1f" % v)) + " ms") if not 测.is_empty() else "—", 19.0, Color(次, ai), "等", HORIZONTAL_ALIGNMENT_LEFT, -1.0, true)
			m += 134.0
		elif i in 末: m += 96.0
		else: m += 66.0
	if 选y >= 0.0: 件.滑竖(c, "设置竖", Vector2(x0 - 28*s, 选y - 30*s), Vector2(x0 - 28*s, 选y + 12*s), Color(令.色["活亮"], a), 4.0)
	# 页底：按键（样张 y = 1330）、选中项的一行说明、需要时的「重启并应用」
	var kx := x0                                                           # 页底只剩三个键帽（不写字）
	for kk in ["↑ ↓", "← →", "Esc"]: kx += 件.键帽(c, Vector2(kx, 1330*s), kk, Color(主, 0.9*a), 18.0) + 16*s
	if 需重启:
		var ri := 设项.size() - 1; var y2 := 1396.0*s
		件.行标(c, Vector2(x0, y2), "生效", 设行 == ri, false, a, 设行 != ri)
		if 设行 == ri: 件.滑竖(c, "设置竖", Vector2(x0 - 28*s, y2 - 30*s), Vector2(x0 - 28*s, y2 + 12*s), Color(令.色["活亮"], a), 4.0)
		设点.append({"i": ri, "行": Rect2(x0 - 40*s, y2 - 34*s, 线宽 + 40*s, 50*s), "项": 件.选项(c, Vector2(xv, y2), 设项[ri][2], 0 if 设行 == ri else -1, a, [], 26.0, 设悬.y if 设悬.x == ri else -1, 设按.y if 设按.x == ri else -1, "设|重启"), "滑": Rect2()})
	# 右：实时预览标注 + 引线（样张：锚 = 桅杆头，折点 = 锚 + (−230, −120)，横线向左 330，字在横线上方 16）
	var 名s := "自定义" if 自定义() else String(令.设置["画质"])
	var 车p := 桅杆样张
	var rr: Node3D = P.rover_root
	if rr and 控 and 控.get("mast_local") != null: 车p = rr.global_transform*(控.get("mast_local") as Vector3)
	if not 机.is_position_behind(车p):
		var 锚 := 机.unproject_position(车p); var 折 := 锚 + Vector2(-230, -120)*s; var 字左 := Vector2(折.x - 330*s, 折.y)
		件.字串(c, 字左 + Vector2(0, -16*s), 名s, 24.0, Color(主, a), "粗")
		件.引线(c, 锚, 折, 字左, Color(令.色["活亮"], a), clampf(页a*2.0 - 0.8, 0.0, 1.0))
	if 设悬行 >= 0 and 拖滑 < 0:
		var 键h: String = 设项[设悬行][0]
		var 文: String = 设说(键h) + ("\n" + 预设说.get(String(令.设置["画质"]), "") + "\n" + 预设测字(String(令.设置["画质"]))) if 键h == "画质" else 设说(键h)
		件.提示画(c, 文, 鼠标位, vs)


func 预设测字(名: String) -> String:
	if not 预设测.has(名): return "测帧：未测"
	var m: Array = 预设测[名]
	return "实测 2560×1440：地面 %.1f · 绕车 %.1f · 远足 %.1f ms" % [m[0], m[1], m[2]]


func 设说(键: String) -> String:
	var d := {
		"画质": "预设 = 抗锯齿、3D 分辨率、SSAO、阴影、石块密度等一整套；改了 3D 分辨率或抗锯齿会自动变成「自定义」。",
		"缩放": "3D 渲染分辨率占窗口的比例（现在渲染 %d×%d）；低于 100 %% 的画面按「抗锯齿」放大。" % [渲染尺寸().x, 渲染尺寸().y],
		"AA": "TAA：原生分辨率 · 时间累积；FSR 2：低分辨率渲染再放大（省帧时间）；关：最快，边缘有锯齿。",
		"重启": "预设里的 SSAO、阴影、石块等要重建场景：按 Enter 重启，带着原来的命令行。",
		"界面档": "关：不显示读数；精简：读数牌只在开车和换倍率时出现；完整：常驻。",
		"地亮": "地面图形（罗盘环、航点、箭头）的亮度，50–130 %。",
		"配色": "整套界面颜色：NASA 标准是默认；其他色板用来对照。",
		"字号": "界面文字大小（标准 / 大 ×1.15 / 特大 ×1.3）。",
		"动效": "界面出现、消失的动画；「关」直接到终态。",
		"全屏": "立刻生效。", "垂直同步": "立刻生效；关掉后帧率不受显示器限制，可能撕裂。",
		"单位": "距离、速度的显示：公制 m、km / 英制 ft、mi。",
		"语言": "界面文字的语言；立刻生效。"}
	return String(d.get(键, ""))


func 邻行(d: int) -> int:
	var j := posmod(设行 + d, 设项.size())
	if 设项[j][0] == "重启" and not 需重启: j = posmod(j + d, 设项.size())
	return j


func 选项表(i: int) -> Array:
	match String(设项[i][0]):
		"画质": return 环境.预设列表() + ["自定义"]
		"配色": return 令.色板序.map(func(k): return String(令.色板[k]["名"]))
		_: return 设项[i][2]


func 选项当前(i: int) -> int:
	var 键: String = 设项[i][0]
	match 键:
		"画质":
			var L: Array = 环境.预设列表()
			return L.size() if 自定义() else maxi(0, L.find(String(令.设置["画质"])))
		"AA": return maxi(0, AA名.find(AA值()))
		"配色": return maxi(0, 令.色板序.find(令.板))
		"全屏": return 1 if 环境.设置读("全屏", "0", "显示") == "1" else 0
		"垂直同步": return 0 if 环境.设置读("垂直同步", "1", "显示") == "1" else 1
	return clampi(int(令.设置[键]), 0, (设项[i][2] as Array).size() - 1)


func 滑范围(键: String) -> Vector2:
	return 缩放范围 if 键 == "缩放" else 地亮范围


func 滑值(键: String) -> float:
	return roundf(缩放值()*100.0) if 键 == "缩放" else float(令.设置["地亮"])


func 画关于(c: CanvasItem, vs: Vector2, s: float, a: float) -> void:
	var 主: Color = 令.色["主"]; var 次 := Color(令.色["次"], a)
	件.题(c, Vector2(120, 210)*s, "帮助", "关于", 56, Color(主, a))
	var y := 320.0*s; var x := 150.0*s; var w := vs.x*0.5
	件.字串(c, Vector2(x, y), 令.片名 + " · " + 令.片名中, 32, Color(主, a), "粗"); y += 50*s
	for kv in [["版本", 环境.一行()], ["场景", "毅力号 sol 530 停车点（site 26 / drive 1222），杰泽罗陨石坑三角洲前缘，NASA 公开数据重建"],
			["声明", "非 NASA / JPL 官方产品，不代表 NASA 背书。界面不使用任何 NASA 标志；车模型贴图上的标志保真保留（THIRD_PARTY §5）"],
			["数据", "HiRISE 高程与正射：NASA/JPL/University of Arizona · CTX：NASA/JPL-Caltech/MSSS · MOLA：NASA/JPL/GSFC · HRSC：ESA/DLR/FU Berlin · Navcam、全景、毅力号模型：NASA/JPL-Caltech · 地面样块：NASA/JPL-Caltech/ASU/MSSS/LANL · 处理：USGS Astrogeology"],
			["字体", "Inter、IBM Plex Mono、Noto Sans SC（SIL Open Font License 1.1）"],
			["引擎", "Godot Engine（MIT）+ 本项目补丁；godot-cpp（MIT）"],
			["许可", "代码 MIT（见 LICENSE），文档 CC BY 4.0。第三方清单见 THIRD_PARTY.md"]]:
		件.字串(c, Vector2(x, y + 34*s), kv[0], 22, 次, "中")
		y = 件.段落描边(c, Vector2(x + 110*s, y), kv[1], 22, Color(主, a), w - 110*s, "中") + 16*s
	件.键提示(c, Vector2(vs.x*0.31, vs.y - 84*s), [["Esc", "返回"]], 22, 20, 36)


# ———————————————————— 输入（菜单开着时吃掉所有键，不让 控制 / 界面 / 玩法 收到；相册开着时让给 玩法）
func _input(ev: InputEvent) -> void:
	if 态 in ["关", "出发", "等"] or 相册开(): return
	if 页 == "设置" and (ev is InputEventMouseMotion or ev is InputEventMouseButton):
		设鼠标(ev); return
	if ev is InputEventMouseMotion and 页 == "":
		鼠标位 = ev.position; 悬项 = 点中项(ev.position)
		if 悬项 >= 0 and 悬项 != 选: 换选(悬项)
		return
	if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT and 页 == "":
		鼠标位 = ev.position
		if ev.pressed: 按项 = 点中项(ev.position)                       # 按下只记录 + 按下态；抬起时还在同一项才触发
		else:
			var j := 点中项(ev.position)
			if 按项 >= 0 and j == 按项: 换选(j); 按项 = -1; 执行()
			else: 按项 = -1
		get_viewport().set_input_as_handled(); return
	if not (ev is InputEventKey and ev.pressed): return
	get_viewport().set_input_as_handled()
	if 态 == "落地": 换态("菜单")                                      # 任意键跳过落地
	var k: Key = ev.keycode
	if 页 == "设置":
		match k:
			KEY_UP, KEY_W: 设行 = 邻行(-1)
			KEY_DOWN, KEY_S: 设行 = 邻行(1)
			KEY_LEFT, KEY_A: 改设(-1)
			KEY_RIGHT, KEY_D: 改设(1)
			KEY_ENTER, KEY_KP_ENTER, KEY_SPACE: 改设(1, true)
			KEY_ESCAPE, KEY_BACKSPACE: 页 = ""; 令.存设置()
		return
	if 页 == "关于":
		if k in [KEY_ESCAPE, KEY_BACKSPACE, KEY_ENTER, KEY_KP_ENTER]: 页 = ""
		return
	match k:
		KEY_LEFT, KEY_UP, KEY_A, KEY_W: 换选(posmod(选 - 1, 项.size()))
		KEY_RIGHT, KEY_DOWN, KEY_D, KEY_S: 换选(posmod(选 + 1, 项.size()))
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE: 执行()
		KEY_ESCAPE:
			if 从游戏: 选 = 0; 执行()
			else: 换选(项.size() - 1)


func 换选(i: int) -> void:
	if i == 选: return
	选 = i; 选t = 0.0


func 设点中(p: Vector2) -> Vector2i:
	"""设置页鼠标指着什么：x = 设置项下标（行），y = 选项号（−1 = 在行上但没指着选项；滑条 = −2）；x = −1 没指着行。选项用 件.命中（相邻无死缝 + 8 px 容差）。"""
	var s := 令.s
	for h: Dictionary in 设点:
		var i: int = h["i"]; var 滑: Rect2 = h["滑"]
		if 滑.size.x > 0.0 and 滑.grow_individual(16*s, 20*s, 16*s, 20*s).has_point(p): return Vector2i(i, -2)
		var j := 件.命中(h["项"], p)
		if j >= 0: return Vector2i(i, j)
	for h: Dictionary in 设点:
		if (h["行"] as Rect2).grow(4*s).has_point(p): return Vector2i(h["i"], -1)
	return Vector2i(-1, -1)


func 设鼠标(ev: InputEvent) -> void:
	"""设置页的鼠标（规范 §3）：悬停选行（下一帧高亮）；点选项 / 按钮 = 抬起才触发（按下有按下态，移出再抬起取消）；滑条：点轨道直接跳到那里并可接着拖，
	滚轮每格 ±5 %，拖动时拇指上方显示数值；键盘随时可接管（键盘 ←→ 走同一套 设选 / 设滑）。"""
	var s := 令.s
	if ev is InputEventMouseMotion:
		鼠标位 = ev.position
		if 拖滑 >= 0 and (ev.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0: 滑到(拖滑, ev.position.x); return
		拖滑 = -1
		var q := 设点中(ev.position)
		设悬 = q if q.y >= 0 else Vector2i(-1, -1); 设悬行 = q.x
		if q.x >= 0: 设行 = q.x
		return
	if not (ev is InputEventMouseButton): return
	鼠标位 = ev.position
	if ev.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		if not ev.pressed: return
		var q := 设点中(ev.position)
		if q.x >= 0 and 设项[q.x][3] == "滑":
			设行 = q.x; 设滑(String(设项[q.x][0]), 滑值(String(设项[q.x][0])) + (1.0 if ev.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0)*令.点击["滚轮"])
		return
	if ev.button_index != MOUSE_BUTTON_LEFT: return
	var q := 设点中(ev.position)
	if ev.pressed:
		if q.x < 0: return
		设行 = q.x
		if q.y == -2: 拖滑 = q.x; 滑到(q.x, ev.position.x)                 # 滑条：按下就定值，接着拖
		elif q.y >= 0: 设按 = q
	else:
		拖滑 = -1
		if 设按.x >= 0 and q == 设按:
			设行 = q.x
			if 设项[q.x][3] == "钮": 改设(1)
			else: 设选(q.x, q.y)
		设按 = Vector2i(-1, -1)


func 滑到(i: int, x: float) -> void:
	var 键: String = 设项[i][0]
	for h: Dictionary in 设点:
		if h["i"] != i: continue
		var r: Rect2 = h["滑"]; var v := clampf((x - r.position.x)/r.size.x, 0.0, 1.0); var 范 := 滑范围(键)
		设滑(键, roundf(lerpf(范.x, 范.y, v)))


func 设滑(键: String, 值: float) -> void:
	"""滑条定值（%）。缩放：和预设自带的一样就回到「跟预设」（空串），否则记成手改 → 自定义。"""
	var 范 := 滑范围(键); 值 = clampf(值, 范.x, 范.y)
	if 键 == "缩放":
		var 预: float = roundf(float(环境.预设内容(String(令.设置["画质"])).get("缩放", "1.0"))*100.0)
		令.设置["缩放"] = "" if 值 == 预 else "%.2f" % (值/100.0)
		用画质()
	else:
		令.设置["地亮"] = int(roundf(值/5.0)*5.0); 用地亮()


func 设选(i: int, j: int) -> void:
	"""内联选项第 j 项被选中（键盘 ←→ 和鼠标共用）。"""
	var 键: String = 设项[i][0]
	match 键:
		"画质":
			var L: Array = 环境.预设列表()
			if j >= L.size(): return                                     # 「自定义」只会自动出现，不能直接选
			令.设置["画质"] = L[j]; 令.设置["缩放"] = ""; 令.设置["AA"] = ""; 用画质(); 需重启 = L[j] != 启动档
		"AA":
			var 预: String = String(环境.预设内容(String(令.设置["画质"])).get("AA", "TAA"))
			令.设置["AA"] = "" if AA名[j] == 预 else AA名[j]; 用画质()
		"配色":
			令.设置["配色"] = 令.色板序[j]; 令.设色板(令.色板序[j])
		"语言":
			令.设置["语言"] = j; 令.设语言(令.语言码[j])                    # 立刻生效（--语言= 给了就不动）
		"全屏", "垂直同步":
			环境.设置写(键, "1" if (j == 1) == (键 == "全屏") else "0", "显示")
			if not 令.测菜单(): 用显示()
		_:
			令.设置[键] = j
			match 键:
				"单位": 令.单位 = j
				"字号": 令.设字倍([1.0, 1.15, 1.3][j])
				"动效": 令.动倍 = [1.0, 0.5, 0.0][j]


func 改设(d: int, 环 := false) -> void:
	var 键: String = 设项[设行][0]; var 类: String = 设项[设行][3]
	if 键 == "重启":
		if d > 0 and 需重启: 令.存设置(); 环境.重启()
		return
	if 类 == "滑":
		设滑(键, 滑值(键) + (5.0 if d > 0 else -5.0)); return
	var 表 := 选项表(设行); var L: Array = 环境.预设列表()
	var j := 选项当前(设行)
	if 键 == "画质": j = L.find(String(令.设置["画质"]))                    # 「自定义」里按 ←→：回到手改所基于的预设的邻档
	var wrap := 环 or 键 == "画质" or 键 == "配色"
	var n: int = L.size() if 键 == "画质" else 表.size()
	j = posmod(j + d, n) if wrap else clampi(j + d, 0, n - 1)
	设选(设行, j)


# ———————————————————— 动作
func 执行() -> void:
	var 键: String = 项[选]["键"]
	match 键:
		"继续":
			if not (有存档() or 从游戏): return
			出发("B" if (not 从游戏 and String(令.设置.get("上次", "")) == "B") else "")
		"A": 出发("A")
		"B": 出发("B")
		"相册": if 玩 and 玩.图鉴: 玩.图鉴.打开()
		"设置": 页 = "设置"; 设行 = 0
		"关于": 页 = "关于"
		"退出": 令.存设置(); P.quit_clean()


func 出发(a: String) -> void:
	"""进游戏：相机从现在的位置推到跟车相机（1.2 s，不切黑），菜单小标收回、地面环淡出。"""
	动作 = a
	if a != "": 令.设置["上次"] = a
	令.存设置()
	if 改了时: P.set_time_f(P.minutes(String(P.args.get("时刻", "13:07")))); 改了时 = false
	去机 = 控.get("cam") as Camera3D
	if 从游戏 and 玩: 玩.暂停("主菜单", false)
	控.set("自动", {})
	起xf = 机.global_transform
	if 去机 == null: 收尾出发(); return
	换态("出发")


func 收尾出发() -> void:
	态 = "关"; 页 = ""
	地.全藏(); 画.queue_redraw(); 层.visible = false
	if 去机: 去机.current = true
	if 界: 界.设档(int(令.设置["界面档"]))
	if 界 and 界.get("扫"): 界.扫.放.call_deferred()                          # 进游戏放一次脉冲（点题：活沙盘 → 实景）
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	计时["进游戏_ms"] = Time.get_ticks_msec()
	match 动作:
		"B": if 玩 and 玩.B: 玩.B.进入()
	从游戏 = false


func 回来() -> void:
	"""游戏里 Esc 第二次（玩法/菜单.gd 打开() 转到这里）：世界暂停，相机飞回绕车机位，HUD 藏起来。"""
	if 态 != "关": return
	从游戏 = true; 选 = 0; 选t = 9.0; 页 = ""
	if 玩: 玩.暂停("主菜单", true); 玩.放鼠标()
	if 界: 界.visible = false
	绕 = atan2((get_viewport().get_camera_3d().global_position - 车心()).x, -(get_viewport().get_camera_3d().global_position - 车心()).z) if get_viewport().get_camera_3d() else 侧光角()
	机.global_transform = get_viewport().get_camera_3d().global_transform if get_viewport().get_camera_3d() else 绕位(绕)
	机.current = true; 层.visible = true
	for i in 标出.size(): 标出[i] = 0.0
	换态("回来")


func 开着() -> bool:
	return 态 != "关"


# ———————————————————— 录短片（--菜单录=<目录>，界面/菜单录.sh：Movie Maker 30 fps）：落地 → 逐项 → 设置 → 关于 → 进游戏 → Esc 回来
func 录() -> void:
	while 态 != "菜单": await get_tree().process_frame
	await 等(2.0)
	for i in 3: await 键(KEY_RIGHT); await 等(0.9)
	while 项[选]["键"] != "设置": await 键(KEY_RIGHT); await 等(0.5)
	await 等(0.6); await 键(KEY_ENTER); await 等(2.2)
	await 键(KEY_DOWN); await 键(KEY_RIGHT); await 等(1.0); await 键(KEY_LEFT); await 等(0.6)
	await 键(KEY_ESCAPE); await 等(1.6)
	while 项[选]["键"] != "关于": await 键(KEY_RIGHT); await 等(0.4)
	await 键(KEY_ENTER); await 等(2.2); await 键(KEY_ESCAPE); await 等(1.4)
	while 项[选]["键"] != "A": await 键(KEY_LEFT); await 等(0.4)
	await 等(0.8); await 键(KEY_ENTER)
	while 态 != "关": await get_tree().process_frame
	await 等(2.5)
	P.quit_clean()


func 鼠标走(到: Vector2, 帧n := 18) -> void:
	"""录像：鼠标从现在的位置缓入缓出地走到 到（每帧一个移动事件）。"""
	var 起 := 鼠标位
	for i in 帧n: await 鼠标移(起.lerp(到, 令.缓(float(i + 1)/帧n, "入出")))


func 拖走(到: Vector2, 帧n := 24) -> void:
	var 起 := 鼠标位
	for i in 帧n:
		var p := 起.lerp(到, 令.缓(float(i + 1)/帧n, "入出"))
		var e := InputEventMouseMotion.new(); e.position = p; e.global_position = p; e.button_mask = MOUSE_BUTTON_MASK_LEFT
		Input.parse_input_event(e); await get_tree().process_frame


func 点按(p: Vector2, 停 := 0.25) -> void:
	录按 = true; await 鼠标键(p, true); await 等(停); await 鼠标键(p, false); 录按 = false


func 录鼠标() -> void:
	"""--录鼠标：标题页划过几项（提示、选中动画）→ 点「设置」（抬起才触发）→ 设置页：悬停选行、点选项（下划线滑动）、点轨道、拖滑条（数值）、滚轮 → Esc。"""
	录鼠标开 = true; var vs := 画.size
	while 态 != "菜单": await get_tree().process_frame
	await 等(1.5); 鼠标位 = Vector2(vs.x*0.5, vs.y*0.85)
	for i in [0, 1, 2, 3]:
		await 鼠标走((标位[i][3] as Rect2).get_center()); await 等(0.9 if i == 1 else 0.3)
	await 鼠标走((标位[4][3] as Rect2).get_center()); await 等(0.4); await 点按((标位[4][3] as Rect2).get_center()); await 等(2.2)
	for 键名 in ["配色", "字号", "动效"]:
		var h := 设点行(键名); var 框: Array = h["项"]
		await 鼠标走((框[0] as Rect2).get_center()); await 等(0.3)
		await 鼠标走((框[1] as Rect2).get_center()); await 等(0.2); await 点按((框[1] as Rect2).get_center()); await 等(0.6)
		h = 设点行(键名); 框 = h["项"]
		await 鼠标走((框[0] as Rect2).get_center()); await 等(0.2); await 点按((框[0] as Rect2).get_center()); await 等(0.6)
	var hs := 设点行("地亮"); var 滑: Rect2 = hs["滑"]
	await 鼠标走(Vector2(滑.position.x + 滑.size.x*0.3, 滑.get_center().y)); await 等(0.4)
	录按 = true; await 鼠标键(鼠标位, true); await 等(0.3)
	await 拖走(Vector2(滑.position.x + 滑.size.x*0.9, 滑.get_center().y), 36); await 等(0.4)
	await 拖走(Vector2(滑.position.x + 滑.size.x*0.55, 滑.get_center().y), 24); await 等(0.4)
	await 鼠标键(鼠标位, false); 录按 = false; await 等(0.4)
	for k in 3: await 鼠标键(鼠标位, true, MOUSE_BUTTON_WHEEL_DOWN); await 等(0.35)
	await 鼠标走(Vector2(滑.position.x + 滑.size.x*0.8, 滑.get_center().y + 3)); await 等(0.4); await 点按(鼠标位); await 等(0.6)
	var hy := 设点行("画质"); await 鼠标走(((hy["行"] as Rect2).position + Vector2(100, 20)*令.s)); await 等(1.0)
	await 键(KEY_ESCAPE); await 等(1.5)
	P.quit_clean()


func 光标层建() -> void:
	"""录像：在所有页面之上画一个鼠标指针（Movie Maker 录不到系统光标；拍照、图鉴、暂停菜单是别的 CanvasLayer，盖在主菜单上面）。"""
	var L := CanvasLayer.new(); L.layer = 200; L.process_mode = Node.PROCESS_MODE_ALWAYS; get_tree().root.add_child(L)
	var C := Control.new(); C.mouse_filter = Control.MOUSE_FILTER_IGNORE; C.set_anchors_preset(Control.PRESET_FULL_RECT); L.add_child(C)
	C.draw.connect(func():
		var q := 鼠标位; var s := 令.s
		if 录按: C.draw_arc(q, 20*s, 0, TAU, 24, Color(令.色["活亮"], 0.9), 3*s)
		var 箭 := PackedVector2Array([q, q + Vector2(0, 26)*s, q + Vector2(7, 20)*s, q + Vector2(13, 31)*s, q + Vector2(18, 28)*s, q + Vector2(12, 18)*s, q + Vector2(21, 18)*s])
		C.draw_colored_polygon(箭, Color.WHITE); C.draw_polyline(箭 + PackedVector2Array([箭[0]]), Color(0, 0, 0, 0.9), 1.6*s))
	get_tree().process_frame.connect(C.queue_redraw)


func 框心(框: Array, id: int) -> Vector2:
	for q in 框:
		if int(q[0]) == id: return (q[1] as Rect2).get_center()
	return Vector2(100, 100)


func 录相册() -> void:
	"""--录相册：进游戏 → 拍照模式（悬停行、点值的左 / 右半、滚轮调曝光、悬停快门出提示、点关闭）→ 图鉴（悬停卡片、点进全屏、滚轮、点「挑战」页签、点关闭键）→ 暂停菜单（悬停、点继续）。"""
	光标层建(); var vs := 画.size
	while 态 != "菜单": await get_tree().process_frame
	await 等(1.0); 鼠标位 = Vector2(vs.x*0.5, vs.y*0.9)
	while 项[选]["键"] != "A": await 键(KEY_RIGHT)
	await 键(KEY_ENTER)
	while 态 != "关": await get_tree().process_frame
	await 等(1.0)
	控.set("rate_i", 5); 控.call("set_mode", "跟车"); await 等(1.0)
	var 玩节: Node = P.get_node("玩法"); var 拍: Node = 玩节.拍照; var 鉴: Node = 玩节.图鉴; var 菜: Node = 玩节.菜单
	拍.进入(); await 等(1.5)
	for id in [0, 2, 4, 5]: await 鼠标走(框心(拍.框, id)); await 等(0.35)
	await 鼠标走(框心(拍.框, 1)); await 等(0.9)
	var 行: Rect2 = Rect2(); for q in 拍.框: if int(q[0]) == 1: 行 = q[1]
	var 右 := Vector2(拍.面板x中 + 70*令.s, 行.get_center().y); var 左 := Vector2(拍.面板x中 - 120*令.s + 60*令.s, 行.get_center().y)
	await 鼠标走(右); await 等(0.3); await 点按(右); await 等(0.3); await 点按(右); await 等(0.3); await 鼠标走(左); await 等(0.2); await 点按(左); await 等(0.6)
	await 鼠标走(框心(拍.框, 4)); await 等(0.3)
	for k in 3: await 鼠标键(鼠标位, true, MOUSE_BUTTON_WHEEL_UP); await 等(0.35)
	await 鼠标走(框心(拍.框, 100)); await 等(1.0)
	await 鼠标走(框心(拍.框, 111)); await 等(0.9)
	await 鼠标走(框心(拍.框, 101)); await 等(0.4); await 点按(框心(拍.框, 101)); await 等(0.8)
	鉴.打开(); await 等(0.9)
	for i in [0, 1, 2, 6]: await 鼠标走(框心(鉴.框, i)); await 等(0.4)
	await 等(0.5)
	await 鼠标走(框心(鉴.框, 1)); await 等(0.3); await 点按(框心(鉴.框, 1)); await 等(1.4)
	await 点按(Vector2(vs.x*0.5, vs.y*0.4)); await 等(0.6)
	for k in 3: await 鼠标键(鼠标位, true, MOUSE_BUTTON_WHEEL_DOWN); await 等(0.4)
	await 鼠标走(框心(鉴.框, -11)); await 等(0.8); await 点按(框心(鉴.框, -11)); await 等(1.2)
	await 鼠标走(框心(鉴.框, -10)); await 等(0.3); await 点按(框心(鉴.框, -10)); await 等(1.0)
	await 鼠标走(框心(鉴.框, -23)); await 等(0.4); await 点按(框心(鉴.框, -23)); await 等(0.8)
	菜.搭(); 菜.开着 = true; 菜.层.visible = true; await 等(0.8)
	for i in [1, 3, 4, 0]: await 鼠标走((菜.框[i] as Rect2).get_center()); await 等(0.35)
	await 点按((菜.框[0] as Rect2).get_center()); await 等(1.0)
	P.quit_clean()


func 录开车() -> void:
	"""--录开车：进自由漫游，开车直行、左弧、原地转、停（录驾驶界面前后对比）。"""
	while 态 != "菜单": await get_tree().process_frame
	await 等(1.0)
	while 项[选]["键"] != "A": await 键(KEY_RIGHT)
	await 键(KEY_ENTER)
	while 态 != "关": await get_tree().process_frame
	await 等(1.0)
	控.set("rate_i", 5); 控.call("set_mode", "跟车")
	控.set("自动", {"油": 1.0}); await 等(4.0)
	控.set("自动", {"油": 1.0, "转": 1.0}); await 等(4.0)
	控.set("自动", {"原地": -1.0}); await 等(3.0)
	控.set("自动", {}); await 等(2.0)
	P.quit_clean()


# ———————————————————— 自测（--菜单测试[=目录]，界面/菜单测试.sh）
func 等(t: float) -> void:
	await get_tree().create_timer(t, true, false, true).timeout


func 存(名: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(测)
	img.save_png(测.path_join(名 + ".png")); print("[菜单] 截图 %s ｜ 态 %s 页 %s 选 %s" % [名, 态, 页, 项[选]["名"]])


func 键(k: Key) -> void:
	var e := InputEventKey.new(); e.keycode = k; e.pressed = true
	Input.parse_input_event(e); await get_tree().process_frame
	var e2 := InputEventKey.new(); e2.keycode = k; e2.pressed = false
	Input.parse_input_event(e2); await get_tree().process_frame


class 错记 extends Logger:
	"""自测用：收集引擎报的 ERROR / SCRIPT ERROR / SHADER ERROR（警告不收）。_log_error 可能在别的线程，加锁。"""
	var 条: Array = []
	var 锁 := Mutex.new()
	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _bt: Array) -> void:
		if error_type == 1: return
		锁.lock(); 条.append("%s:%d %s ｜ %s" % [file, line, code, rationale]); 锁.unlock()
	func 取() -> Array:
		锁.lock(); var r := 条.duplicate(); 锁.unlock(); return r


func 去行(k: String) -> void:
	var n := 0
	while 设项[设行][0] != k and n < 30: await 键(KEY_DOWN); n += 1


func 字框(文: String) -> Array:
	"""自测：从 件.字框记 里找画出的那串字的记录（先按文字找，找不到按包含找）。"""
	文 = 令.译(文)
	for q: Array in 件.字框记:
		if String(q[0]) == 文: return q
	for q: Array in 件.字框记:
		if String(q[0]).contains(文): return q
	return []


func 描测(记: Callable, 名: String, 图: Image, q: Array, 阈: float) -> Dictionary:
	"""自测（规范 §5 新量法，协程）：字对紧贴它外面 1–3 px 的一圈（它自己的描边）的 p95 亮度；同时打出旧量法数字作对照。阈 = 0：只打印，不判。"""
	if q.is_empty(): print("[对比度] %s：没有找到这串字" % 名); return {}
	var 膜: Image = await 件.字膜(q[0], q[3], q[5])
	var d := 件.描边测(图, 膜, 件.膜原点(q), q[2], q[1])
	if d.is_empty(): print("[对比度] %s：量不出" % 名); return {}
	print("[对比度] %s ｜ 新法 %.1f:1（带 p95 亮度 %.3f，描边宽 %.0f px）｜ 旧法 %.1f:1" % [名, d["对比"], d["带95"], d["宽"], d["旧"]])
	if 阈 > 0.0: 记.call("对比度 " + 名, d["对比"] >= 阈, "新法 %.1f:1（旧法 %.1f:1）描边宽 %.0f px" % [d["对比"], d["旧"], d["宽"]])
	return d


func 图标测(记: Callable, 名: String, 图: Image, 图名: String, 心: Vector2, px: float, 前: Color, 阈: float) -> Dictionary:
	"""自测：图标对自己的外扩（1–3 px）的对比度（图标贴图的 alpha 做膜）。"""
	var n := roundi(px); var 纹: Texture2D = 件.标().纹(图名, n, false)
	if 纹 == null: return {}
	var 膜 := 纹.get_image(); var 原 := Vector2i((心 - Vector2(n, n)*0.5).round())
	var d := 件.描边测(图, 膜, 原, 前, Rect2(Vector2(原), Vector2(n, n)))
	if d.is_empty(): return {}
	print("[对比度] %s ｜ 新法 %.1f:1（描边宽 %.0f px）｜ 旧法 %.1f:1" % [名, d["对比"], d["宽"], d["旧"]])
	if 阈 > 0.0: 记.call("对比度 " + 名, d["对比"] >= 阈, "新法 %.1f:1（旧法 %.1f:1）描边宽 %.0f px" % [d["对比"], d["旧"], d["宽"]])
	return d


func 对比测(记: Callable, 名: String, 图: Image, 缩: float, r: Rect2, 前: Color, 阈: float) -> float:
	"""自测：文字 / 图标所在矩形 r 周围一圈背景（外扩 14 px、去掉内扩 3 px）的 p95 亮度对 前 色的 WCAG 对比度（工具/界面对比度.py 的方法：取背景 p95 亮度）。"""
	var 值: Array = []; var s := 令.s
	var 外 := r.grow(14*s); var 内 := r.grow(3*s)
	for y in range(maxi(0, int(外.position.y*缩)), mini(图.get_height(), int(外.end.y*缩)), 2):
		for x in range(maxi(0, int(外.position.x*缩)), mini(图.get_width(), int(外.end.x*缩)), 2):
			if 内.has_point(Vector2(x, y)/缩): continue
			值.append(亮度(图.get_pixel(x, y)))
	if 值.is_empty(): return 0.0
	值.sort(); var L: float = 值[int(值.size()*0.95)]
	var cr := 对比Y(亮度(前), L)
	print("[对比度] %s ｜ 前景 #%s 对背景 p95 亮度 %.3f ＝ %.1f:1（要求 ≥ %.1f）" % [名, 前.to_html(false), L, cr, 阈])
	记.call("对比度 " + 名, cr >= 阈, "%.1f:1" % cr)
	return cr


func 对比Y(a: float, b: float) -> float:
	return (maxf(a, b) + 0.05)/(minf(a, b) + 0.05)


func 鼠标移(p: Vector2) -> void:
	"""自测：鼠标移到 p（不按键）。"""
	var e := InputEventMouseMotion.new(); e.position = p; e.global_position = p
	Input.parse_input_event(e); await get_tree().process_frame


func 鼠标键(p: Vector2, 按: bool, 键 := MOUSE_BUTTON_LEFT) -> void:
	var e := InputEventMouseButton.new(); e.button_index = 键; e.pressed = 按; e.position = p; e.global_position = p
	Input.parse_input_event(e); await get_tree().process_frame


func 点(p: Vector2) -> void:
	"""自测：在 p 点一下鼠标左键。"""
	for 按 in [true, false]:
		var e := InputEventMouseButton.new(); e.button_index = MOUSE_BUTTON_LEFT; e.pressed = 按
		e.position = p; e.global_position = p
		Input.parse_input_event(e); await get_tree().process_frame


func 亮度(c: Color) -> float:
	var f := func(v: float) -> float: return v/12.92 if v <= 0.03928 else pow((v + 0.055)/1.055, 2.4)
	return 0.2126*f.call(c.r) + 0.7152*f.call(c.g) + 0.0722*f.call(c.b)


func 对比(a: Color, b: Color) -> float:
	var x := 亮度(a); var y := 亮度(b)
	return (maxf(x, y) + 0.05)/(minf(x, y) + 0.05)


func 区亮(图: Image, r: Rect2, 缩: float) -> float:
	"""自测：屏幕矩形 r 里 p99 亮度（luma 0–255），样张对照用。"""
	var 值: Array = []
	var x0 := maxi(0, int(r.position.x*缩)); var x1 := mini(图.get_width(), int(r.end.x*缩)); var y0 := maxi(0, int(r.position.y*缩)); var y1 := mini(图.get_height(), int(r.end.y*缩))
	for y in range(y0, y1):
		for x in range(x0, x1):
			var c := 图.get_pixel(x, y); 值.append((0.2126*c.r + 0.7152*c.g + 0.0722*c.b)*255.0)
	if 值.is_empty(): return 0.0
	值.sort()
	return 值[int(值.size()*0.99)]


func 设点行(键: String) -> Dictionary:
	for h: Dictionary in 设点:
		if 设项[h["i"]][0] == 键: return h
	return {}


func 环线宽测(图: Image, 缩: float, vs: Vector2) -> Array:
	"""自测：沿罗盘环前半圈取一圈采样点，在屏幕法线方向上量线的半高宽（px）。线宽该恒定（屏幕空间线），变化 < 1 px。"""
	var o := 车心(); var 宽s: Array = []
	for j in 24:
		var k := 3 + 15*j; var a := deg_to_rad(k)
		var w := o + Vector3(sin(a), 0, -cos(a))*环R; w.y = 线高(w.x, w.z)
		var w2 := o + Vector3(sin(a + 0.05), 0, -cos(a + 0.05))*环R; w2.y = 线高(w2.x, w2.z)
		if 机.is_position_behind(w) or (w - 机.global_position).length() > (o - 机.global_position).length(): continue
		var p := 机.unproject_position(w); var q := 机.unproject_position(w2)
		if p.x < 30 or p.y < 30 or p.x > vs.x - 30 or p.y > vs.y - 30: continue
		var 近 := false
		for e: Array in 标位:
			if not e.is_empty() and (e[4] as Vector2).distance_to(p) < 40*令.s: 近 = true
		if 近: continue
		var d := (q - p).normalized(); var n := Vector2(-d.y, d.x)
		var 面: Array = []
		for ti in range(-36, 37):
			var u := (p + n*(ti*0.25))*缩; var x0 := int(floor(u.x)); var y0 := int(floor(u.y)); var fx := u.x - x0; var fy := u.y - y0
			var L := func(x: int, y: int) -> float:
				var cc := 图.get_pixel(clampi(x, 0, 图.get_width() - 1), clampi(y, 0, 图.get_height() - 1)); return 0.2126*cc.r + 0.7152*cc.g + 0.0722*cc.b
			面.append(lerpf(lerpf(L.call(x0, y0), L.call(x0 + 1, y0), fx), lerpf(L.call(x0, y0 + 1), L.call(x0 + 1, y0 + 1), fx), fy))
		var pk := 0.0; var pi := 0
		for i in range(20, 53):
			if 面[i] > pk: pk = 面[i]; pi = i
		var 基 := minf((面.slice(0, 12).reduce(func(a, b): return a + b)/12.0), (面.slice(61).reduce(func(a, b): return a + b)/12.0))
		if pk - 基 < 0.15: continue                                      # 这一点上看不到线（被石块 / 影子遮了）
		var th := 基 + 0.5*(pk - 基); var l := pi; var r := pi
		while l > 0 and 面[l - 1] >= th: l -= 1
		while r < 面.size() - 1 and 面[r + 1] >= th: r += 1
		宽s.append((r - l + 1)*0.25)
	return 宽s


func 标题自测(记: Callable) -> void:
	var vs := 画.size; var s := 令.s
	var 图集: Array = []
	for q in 项: 图集.append(q["图"])
	var 唯: Dictionary = {}
	for g in 图集: 唯[g] = true
	记.call("标题页：7 项的图标各不相同且都存在", 唯.size() == 项.size() and 图集.all(func(g): return 件.标().有(g)), str(图集))
	var 英 := RegEx.create_from_string("[A-Za-z]")
	var 有英: Array = []
	for q in 项: if 英.search(q["名"]) != null: 有英.append(q["名"])
	if 英.search(令.片名) != null: 有英.append(令.片名)
	记.call("标题页：标题和 7 项名字里没有英文", 有英.is_empty(), str(有英))
	记.call("标题页：相机 = 样张 a_标题（hfov 42°）", absf(机.fov - 42.0) < 0.01 and 页fov[""] == 42.0)
	件.记字 = true; 件.字框记.clear(); await 等(0.3); await RenderingServer.frame_post_draw; 件.记字 = false
	var 图 := get_viewport().get_texture().get_image(); var 缩 := float(图.get_width())/vs.x
	var 主c: Color = 令.色["主"]; var 次c: Color = 令.色["次"]
	var q0: Array = 标位[3]                                              # 未选中的「相册」
	var tp := Vector2(q0[2].x, q0[2].y)
	var 比: Array = []; var 旧比: Array = []; var 宽比: Array = []
	for i in 项.size():
		if i == 选 or 标位[i].is_empty(): continue
		var d := await 描测(记, "标题页 名字「%s」" % 项[i]["名"], 图, 字框(项[i]["名"]), 0.0)
		if not d.is_empty(): 比.append(d["对比"]); 旧比.append(d["旧"]); 宽比.append(d["宽"])
	比.sort(); 旧比.sort(); var 中位: float = 比[比.size()/2]
	if 令.英(): print("[菜单测试]   （英文：标题页名字的描边法对比度按中文字框量，英文标签更宽、会量进旁边的杆线，不判；改看截图）")
	else: 记.call("对比度 标题页 正文（未选中项名字，6 个取中位数；描边法，目标 ≥ 7:1）", 中位 >= 7.0 and 比[0] >= 7.0, "新法中位 %.1f、最低 %.1f；旧法（背景 p95）中位 %.1f、最低 %.1f" % [中位, 比[0], 旧比[旧比.size()/2], 旧比[0]])
	宽比.sort()
	记.call("标题页：名字的描边宽 ≥ max(2 px, 字高 × 8 %)", 宽比.size() > 0 and 宽比[0] >= maxf(2.0, 0.08*30.0)*令.s - 0.01, "最窄 %.1f px（要求 %.1f）" % [宽比[0] if 宽比.size() > 0 else 0.0, maxf(2.0, 0.08*30.0)*令.s])
	await 图标测(记, "标题页 图标（未选中项）", 图, 项[3]["图"], tp, 40.0*s, 主c, 3.0)
	await 描测(记, "标题页 次要文字（版本 · 非 NASA 官方产品）", 图, 字框("非 NASA 官方产品"), 4.5)
	var 宽s := 环线宽测(图, 缩, vs)
	var lo := 99.0; var hi := 0.0
	for w: float in 宽s: lo = minf(lo, w); hi = maxf(hi, w)
	记.call("标题页：罗盘环线宽恒定（%d 个采样点，最大 − 最小 < 1 px）" % 宽s.size(), 宽s.size() >= 6 and hi - lo < 1.0, "%.2f–%.2f px" % [lo, hi])
	# 鼠标：悬停选中；按下不触发、抬起才触发；按下后移开再抬起取消
	var 框: Rect2 = 标位[3][3]
	await 鼠标移(框.get_center()); await 等(0.2)
	记.call("悬停第 4 项（相册）→ 选中它", 选 == 3 and 悬项 == 3)
	await 等(0.5)
	记.call("悬停 0.35 s 后出提示", 件.提示可见())
	await 鼠标移(Vector2(vs.x*0.5, vs.y*0.1)); await 等(0.1)
	记.call("鼠标移开 → 提示立刻消失", not 件.提示可见())
	框 = 标位[4][3]
	await 鼠标移(框.get_center()); await 等(0.4)
	await 鼠标键(框.get_center(), true); await 等(0.1)
	记.call("按下设置项：还没触发（页仍是主页）", 页 == "" and 按项 == 4, "页 %s 按项 %d 选 %d 悬 %d 点 %s 框 %s" % [页, 按项, 选, 悬项, str(框.get_center()), str(标位[4][3])])
	await 鼠标键(框.get_center(), false); await 等(0.3)
	记.call("抬起：触发（进设置页）", 页 == "设置", "页 %s 按项 %d" % [页, 按项])
	页 = ""; 按项 = -1; await 等(0.3)
	框 = 标位[5][3]
	await 鼠标移(框.get_center()); await 等(0.2); await 鼠标键(框.get_center(), true); await 等(0.1)
	await 鼠标移(Vector2(vs.x*0.5, vs.y*0.1)); await 鼠标键(Vector2(vs.x*0.5, vs.y*0.1), false); await 等(0.2)
	记.call("按下后移出再抬起：取消，不触发", 页 == "" and 按项 == -1)
	var 小 := 标位.filter(func(q): return not q.is_empty() and (q[3] as Rect2).size.y >= 44.0*s - 0.5)
	记.call("标题页：7 项命中框高 ≥ 44 px", 小.size() == 项.size(), "%d / 7" % 小.size())
	悬项 = -1; 选 = 1


func 设置自测(记: Callable) -> void:
	var vp := get_viewport(); var vs := 画.size
	await 等(0.5)
	await RenderingServer.frame_post_draw
	var 图 := get_viewport().get_texture().get_image(); var 缩 := float(图.get_width())/vs.x
	var 主c: Color = 令.色["主"]; var 次c: Color = 令.色["次"]; var s0 := 令.s
	var hz := 设点行("字号"); var 框z: Array = hz["项"]
	对比测(记, "设置页 正文（设置项名「字号」）", 图, 缩, Rect2((hz["行"] as Rect2).position.x + 40*s0, (hz["行"] as Rect2).position.y + 4*s0, 70*s0, 34*s0), 主c, 7.0)
	if not 令.英(): 对比测(记, "设置页 次要文字（未选中的选项「大」）", 图, 缩, Rect2((框z[1] as Rect2).position.x + 22*s0, (框z[1] as Rect2).position.y + 10*s0, 26*s0, 30*s0), 次c, 4.5)
	对比测(记, "设置页 图标（分组图标）", 图, 缩, Rect2(200*s0, 276*s0, 28*s0, 28*s0), 主c, 3.0)
	for h: Dictionary in 设点: print("[菜单测试]   行 %s y=%.0f x=%.0f" % [设项[h["i"]][0], (h["行"] as Rect2).position.y + 34*令.s, (h["行"] as Rect2).position.x])
	var 焦 := 设点行(String(设项[设行][0])); var 框: Array = 焦["项"]; var 当 := 选项当前(设行); var 当亮 := 0.0; var 他亮 := 0.0
	for j in 框.size():
		var q := 区亮(图, (框[j] as Rect2), 缩)
		if j == 当: 当亮 = q
		else: 他亮 = maxf(他亮, q)
	记.call("设置页：焦点行的选中项亮度最高", 当亮 > 他亮, "选中 %.0f，其余最高 %.0f（p99 luma）" % [当亮, 他亮])
	记.call("设置页：每行有命中框、4 个分组", 设点.size() == 设项.size() - 1 and 设组.size() == 4, "%d 行" % 设点.size())
	记.call("设置页：2 个滑条（3D 分辨率、地面图形亮度）", 设点.filter(func(h): return (h["滑"] as Rect2).size.x > 0.0).size() == 2)
	var 对 := 对比(令.色["活亮"], 令.色["页底"])
	记.call("设置页：强调字（活亮）对页底对比度 ≥ 4.5", 对 >= 4.5, "活亮 %.1f:1（原「活」%.1f:1）" % [对, 对比(令.色["活"], 令.色["页底"])])
	var 车x := 机.unproject_position(车心() + Vector3(0, 1.0, 0)).x
	var 右缘 := 0.0
	for h: Dictionary in 设点:
		for r: Rect2 in h["项"]: 右缘 = maxf(右缘, r.end.x)
		if (h["滑"] as Rect2).size.x > 0.0: 右缘 = maxf(右缘, (h["滑"] as Rect2).end.x + 180*令.s)
	记.call("设置页：车在右半屏，值列不压车", 车x > vs.x*0.6 and 右缘 < 车x - 0.1*vs.x, "车 x %.2f W，值列右缘 %.2f W" % [车x/vs.x, 右缘/vs.x])
	记.call("预设「高」起点：不是自定义、渲染 100 %", not 自定义() and 令.设置["画质"] == "高" and is_equal_approx(vp.scaling_3d_scale, 1.0))
	# 手改 3D 分辨率 → 自动「自定义」
	await 去行("缩放"); await 键(KEY_LEFT); await 键(KEY_LEFT); await 等(0.3)
	记.call("手改 3D 分辨率 → 自动「自定义」", 自定义() and 选项当前(0) == 4 and absf(缩放值() - 0.9) < 0.001 and absf(vp.scaling_3d_scale - 0.9) < 0.001, "%.0f %%" % (缩放值()*100.0))
	await 存("5b_设置_自定义")
	await 键(KEY_RIGHT); await 键(KEY_RIGHT); await 等(0.2)
	记.call("改回预设的值 → 「自定义」消失", not 自定义() and 选项当前(0) == 3)
	# 抗锯齿
	await 去行("AA"); await 键(KEY_RIGHT); await 等(0.2)
	记.call("抗锯齿 TAA → FSR 2：自定义 + 视口用 FSR2", 自定义() and AA值() == "FSR2" and vp.scaling_3d_mode == Viewport.SCALING_3D_MODE_FSR2 and not vp.use_taa)
	await 键(KEY_RIGHT); await 等(0.2)
	记.call("抗锯齿 → 关：TAA 关、双线性", AA值() == "无" and not vp.use_taa and vp.scaling_3d_mode == Viewport.SCALING_3D_MODE_BILINEAR)
	await 键(KEY_LEFT); await 键(KEY_LEFT); await 等(0.2)
	记.call("抗锯齿改回 TAA → 「自定义」消失、TAA 开", not 自定义() and vp.use_taa and vp.scaling_3d_mode == Viewport.SCALING_3D_MODE_BILINEAR)
	# 预设切换（带出「重启并应用」行）
	await 去行("画质"); await 键(KEY_LEFT); await 等(0.4)
	记.call("预设 高 → 性能：缩放 77 %、需要重启、出现重启行", 令.设置["画质"] == "性能" and absf(vp.scaling_3d_scale - 0.77) < 0.001 and 需重启 and not 设点行("重启").is_empty())
	await 存("5c_设置_性能")
	await 键(KEY_RIGHT); await 等(0.4)
	记.call("预设 性能 → 高：回到 100 %、不用重启、重启行消失", 令.设置["画质"] == "高" and is_equal_approx(vp.scaling_3d_scale, 1.0) and not 需重启 and 设点行("重启").is_empty())
	# 地面图形亮度滑条
	await 去行("地亮"); await 键(KEY_LEFT); await 等(0.2)
	记.call("地面图形亮度滑条 −5 %", int(令.设置["地亮"]) == 80)
	await 键(KEY_RIGHT); await 等(0.2)
	# 鼠标：点选项、点滑条
	await 等(0.2)
	var h := 设点行("单位"); await 点((h["项"][1] as Rect2).get_center()); await 等(0.2)
	记.call("鼠标点「英制」：单位改了、选中该行", int(令.设置["单位"]) == 1 and 设项[设行][0] == "单位")
	h = 设点行("单位"); await 点((h["项"][0] as Rect2).get_center()); await 等(0.2)
	记.call("鼠标点「公制」改回", int(令.设置["单位"]) == 0)
	h = 设点行("缩放"); var 滑: Rect2 = h["滑"]
	await 点(Vector2(滑.position.x + 滑.size.x*0.5, 滑.get_center().y)); await 等(0.3)
	记.call("鼠标点滑条中点 → 3D 分辨率 75 % + 自定义", 自定义() and absf(缩放值() - 0.75) < 0.001, "%.0f %%" % (缩放值()*100.0))
	await 点(Vector2(滑.end.x + 8, 滑.get_center().y)); await 等(0.3)
	记.call("鼠标点滑条右端 → 100 %，自定义消失", not 自定义() and is_equal_approx(vp.scaling_3d_scale, 1.0))
	await 设置鼠标测(记)
	# 语言：→ English 立刻生效（设置值、当前语言、字串都换了），← 切回
	await 去行("语言"); await 键(KEY_RIGHT); await 等(0.2)
	var 底语: String = 令.语言覆盖 if 令.语言覆盖 != "" else "zh"                      # --语言= 给了的话，设置页改不动当前语言
	var 切英: bool = int(令.设置["语言"]) == 1 and (令.语言覆盖 != "" or 令.语言 == "en") and 令.译("设置") == ("设置" if 底语 == "zh" and 令.语言覆盖 != "" else "Settings")
	await 键(KEY_LEFT); await 等(0.2)
	记.call("语言：→ English 立刻生效，← 切回简体中文", 切英 and int(令.设置["语言"]) == 0 and 令.语言 == 底语)
	记.call("设置读写往返（写 settings.cfg → 读回 → 自定义恢复）", 持久化测())


func 设置鼠标测(记: Callable) -> void:
	"""界面 5 的鼠标手感和动画自测：命中框、悬停选行、抬起才触发、滑条点击 / 滚轮 / 拖动、下划线滑动、提示延迟、动效开关、英文标签和字数。"""
	var s := 令.s; var vs := 画.size
	var 英: Array = []
	for q in 设项:
		英.append_array(件.英文标签(q[1]))
		for o in q[2]: 英.append_array(件.英文标签(String(o)))
	for g in 设组: 英.append_array(件.英文标签(g[0]))
	记.call("设置页：名字、选项里没有英文标签（白名单外）", 英.is_empty(), str(英))
	件.记字 = true; 件.字记.clear(); await 等(0.3); 件.记字 = false
	var 画出: Dictionary = {}
	for q in 件.字记: 画出[q] = true
	var 英2: Array = []
	for q in 画出: 英2.append_array(件.英文标签(q))
	记.call("设置页：画出的每一串字里没有英文标签", 英2.is_empty(), str(英2))
	var 高ok := true
	for h: Dictionary in 设点:
		if (h["行"] as Rect2).size.y < 44.0*s - 0.5: 高ok = false
		for r: Rect2 in h["项"]: if r.size.y < 44.0*s - 0.5: 高ok = false
	记.call("设置页：行和选项的命中框高 ≥ 44 px", 高ok)
	var 全唯 := true
	for h: Dictionary in 设点:
		var 框: Array = h["项"]
		for j in 框.size() - 1: if absf((框[j] as Rect2).end.x - (框[j + 1] as Rect2).position.x) > 1.0: 全唯 = false
	记.call("设置页：相邻选项命中框之间没有死缝", 全唯)
	# 动效开关：关 = 直接到终态，开 = 要滑
	var 旧动: float = 令.动倍
	令.动倍 = 1.0; 件.趋("测|a", 0.0); var v1: float = 件.趋("测|a", 1.0, 0.12)
	令.动倍 = 0.0; 件.趋("测|b", 0.0); var v2: float = 件.趋("测|b", 1.0, 0.12)
	令.动倍 = 旧动
	记.call("界面动效：开 = 逐步趋近，关 = 直接到位", v1 < 0.9 and is_equal_approx(v2, 1.0), "%.2f / %.2f" % [v1, v2])
	# 悬停选行（下一帧）和提示
	var h := 设点行("字号"); var r: Rect2 = h["行"]
	await 鼠标移(Vector2(r.position.x + 50*s, r.get_center().y)); await 等(0.05)
	记.call("鼠标停在「字号」行 → 选中该行（下一帧）", 设项[设行][0] == "字号" and 设悬行 == 设行)
	记.call("提示：0.35 s 之前不出", not 件.提示可见())
	await 等(0.45)
	记.call("提示：悬停 0.35 s 后出", 件.提示可见())
	await 鼠标移(Vector2(vs.x*0.9, vs.y*0.9)); await 等(0.05)
	记.call("提示：移开立即消失", not 件.提示可见())
	# 抬起才触发
	h = 设点行("单位"); var 框: Array = h["项"]
	var p1: Vector2 = (框[1] as Rect2).get_center(); var x0: float = (框[0] as Rect2).position.x + 22*s
	await 鼠标移(p1); await 等(0.1)
	await 鼠标键(p1, true); await 等(0.1)
	记.call("按下「英制」：还没改（要抬起才触发）", int(令.设置["单位"]) == 0 and 设按.y == 1)
	await 鼠标移(Vector2(vs.x*0.9, vs.y*0.9)); await 鼠标键(Vector2(vs.x*0.9, vs.y*0.9), false); await 等(0.1)
	记.call("按下后移出再抬起：取消", int(令.设置["单位"]) == 0 and 设按.x == -1)
	await 鼠标移(p1); await 鼠标键(p1, true); await 等(0.05)
	await 鼠标键(p1, false); await 等(0.03)
	记.call("抬起：触发（单位 = 英制）", int(令.设置["单位"]) == 1)
	var 下划: Array = 件._动.get("设|单位|ux", [x0])
	var 中 := float(下划[0])
	var h2 := 设点行("单位"); var x1: float = ((h2["项"] as Array)[1] as Rect2).position.x + 22*s
	记.call("选项下划线：切换后在途中（从旧选项滑向新选项）", 中 > x0 + 0.5 and 中 < x1 - 0.5 or 令.动倍 <= 0.0, "旧 %.0f → 新 %.0f，当前 %.0f" % [x0, x1, 中])
	await 等(0.5)
	var 终 := float(件._动["设|单位|ux"][0])
	记.call("选项下划线：到位", absf(终 - x1) < 1.5, "%.1f / %.1f" % [终, x1])
	h = 设点行("单位"); await 点(((h["项"] as Array)[0] as Rect2).get_center()); await 等(0.2)
	# 滑条：滚轮 ±5、点轨道、拖动显示数值
	h = 设点行("地亮"); var 滑: Rect2 = h["滑"]; var c0 := 滑.get_center()
	var v0 := int(令.设置["地亮"])
	await 鼠标移(c0); await 鼠标键(c0, true, MOUSE_BUTTON_WHEEL_UP); await 等(0.05)
	记.call("滑条：滚轮向上一格 +5 %", int(令.设置["地亮"]) == v0 + 5, "%d → %d" % [v0, int(令.设置["地亮"])])
	await 鼠标键(c0, true, MOUSE_BUTTON_WHEEL_DOWN); await 鼠标键(c0, true, MOUSE_BUTTON_WHEEL_DOWN); await 等(0.05)
	记.call("滑条：滚轮向下两格 −10 %", int(令.设置["地亮"]) == v0 - 5)
	var pa := Vector2(滑.position.x + 滑.size.x*0.25, c0.y); var pb := Vector2(滑.position.x + 滑.size.x*0.75, c0.y)
	await 鼠标键(pa, true); await 等(0.1)
	记.call("滑条：按在轨道上直接跳到那里（25 %）并开始拖", 拖滑 >= 0 and int(令.设置["地亮"]) == int(roundf((50.0 + 0.25*80.0)/5.0)*5.0), "%d %%" % int(令.设置["地亮"]))
	var e := InputEventMouseMotion.new(); e.position = pb; e.global_position = pb; e.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(e); await get_tree().process_frame; await 等(0.1)
	记.call("滑条：拖到 75 % 跟着走，拖动中", 拖滑 >= 0 and int(令.设置["地亮"]) == int(roundf((50.0 + 0.75*80.0)/5.0)*5.0), "%d %%" % int(令.设置["地亮"]))
	await 存("5d_设置_拖滑条")
	await 鼠标键(pb, false); await 等(0.1)
	记.call("滑条：抬起后拖动结束", 拖滑 == -1)
	设滑("地亮", 85.0); await 鼠标移(Vector2(vs.x*0.9, vs.y*0.9)); await 等(0.1)


func 持久化测() -> bool:
	"""真写 user://settings.cfg（经 环境.设置写 / 设置存）再读回；测完把文件和内存都还原（测的可能是玩家在用的机器）。"""
	var 文: String = 环境.设置文件
	var 有 := FileAccess.file_exists(文); var 原 := FileAccess.get_file_as_string(文) if 有 else ""
	var 键们: Array = []
	for k in 令.设置默认.keys(): 键们.append(令._键(k))
	var 原值 := {}
	for k in 键们: 原值[k] = 环境.设置读(k, "")
	var 旧设: Dictionary = 令.设置.duplicate(); var 旧板: String = 令.板
	令.设置["画质"] = "性能"; 令.设置["缩放"] = "0.83"; 令.设置["AA"] = "无"; 令.设置["地亮"] = 100; 令.设置["单位"] = 1
	令.存设置(true)
	var cf := ConfigFile.new(); var ok := cf.load(文) == OK
	var v: Dictionary = cf.get_value("args", "v", {}) if ok else {}
	var 写对: bool = ok and v.get("画质预设") == "性能" and v.get("缩放") == "0.83" and v.get("AA") == "无" and v.get("地亮") == "100" and v.get("单位") == "1"
	令.设置 = 令.设置默认.duplicate(); 令.读设置(true)
	var 读对: bool = 令.设置["画质"] == "性能" and 令.设置["缩放"] == "0.83" and 令.设置["AA"] == "无" and int(令.设置["地亮"]) == 100 and int(令.设置["单位"]) == 1 and 自定义()
	print("[菜单测试]   往返：文件 %s ｜ 读回 %s ｜ %s" % [str(v), str(读对), str(令.设置)])
	for k in 键们: 环境.设置写(k, 原值[k] if 原值[k] != "" else null)
	if 有:
		var f := FileAccess.open(文, FileAccess.WRITE); f.store_string(原); f.close()
	else: DirAccess.remove_absolute(ProjectSettings.globalize_path(文))
	令.设置 = 旧设; 令.单位 = int(旧设["单位"]); 令.设色板(旧板, false)
	用画质(); 用地亮()
	return 写对 and 读对


func 自测() -> void:
	var 错 := 错记.new(); OS.add_logger(错)
	var 计 := [0, 0]                                                   # 闭包按值捕获局部变量，计数放数组里
	var 记 := func(名: String, ok: bool, 注 := ""):
		计[0 if ok else 1] += 1
		print("[菜单测试] %s %s %s" % ["✓" if ok else "✗", 名, 注])
	while 态 == "等": await get_tree().process_frame
	await 等(0.25); await 存("1_落地中")
	while 态 != "菜单": await get_tree().process_frame
	await 等(0.5); await 存("2_菜单_" + 项[选]["名"])
	停绕 = true; 绕 = 绕0; 选 = 1; 选t = 9.0; await 等(0.8); await 存("2a_标题_样张对照")
	await 标题自测(记); await 等(0.4); 停绕 = false
	记.call("落地后进菜单", 态 == "菜单")
	记.call("HUD 藏着", 界 == null or not 界.visible)
	记.call("菜单相机是当前相机", get_viewport().get_camera_3d() == 机)
	记.call("车不收键（自动输入）", not (控.get("自动") as Dictionary).is_empty())
	await 键(KEY_RIGHT); await 等(0.6); await 存("3_选中_" + 项[选]["名"])
	await 键(KEY_RIGHT); await 等(0.6); await 存("4_选中_" + 项[选]["名"])
	while 项[选]["键"] != "设置": await 键(KEY_RIGHT)
	await 键(KEY_ENTER); await 等(2.2); await 存("5_设置")             # 等入场动画（≤ 0.4 s）和相机过渡走完再截
	记.call("设置页", 页 == "设置")
	await 设置自测(记)
	var 板0 := 令.板
	while 设项[设行][0] != "配色": await 键(KEY_DOWN)
	await 键(KEY_RIGHT); await 等(0.4); await 存("6_设置_配色_" + 令.板)
	记.call("配色切换", 令.板 != 板0, 令.板)
	await 键(KEY_LEFT); await 等(0.2)
	记.call("配色切回", 令.板 == 板0)
	await 键(KEY_ESCAPE); await 等(0.3)
	while 项[选]["键"] != "关于": await 键(KEY_RIGHT)
	await 键(KEY_ENTER); await 等(1.2); await 存("7_关于")
	记.call("关于页", 页 == "关于")
	await 键(KEY_ESCAPE); await 等(1.0)
	while 项[选]["键"] != "A": await 键(KEY_LEFT)
	await 等(0.5); await 存("8_选中_自由漫游")
	var t0 := Time.get_ticks_msec()
	await 键(KEY_ENTER); await 等(0.55); await 存("9_出发中")
	while 态 != "关": await get_tree().process_frame
	记.call("进游戏", 态 == "关" and get_viewport().get_camera_3d() == 控.get("cam"), "%d ms" % (Time.get_ticks_msec() - t0))
	记.call("HUD 回来", 界 == null or 界.visible)
	记.call("车收键", (控.get("自动") as Dictionary).is_empty())
	await 等(0.8); await 存("10_游戏")
	# Esc 两次：第一次放开鼠标（控制），第二次回主菜单
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	await 键(KEY_ESCAPE); await 等(0.2); await 键(KEY_ESCAPE); await 等(1.0)
	await 存("11_回到菜单")
	记.call("Esc 回到主菜单（世界暂停）", 态 == "回来" and get_tree().paused)
	await 键(KEY_ENTER); while 态 != "关": await get_tree().process_frame
	记.call("继续回到游戏", not get_tree().paused and get_viewport().get_camera_3d() == 控.get("cam"))
	# 按键触发扫描（Space）：脉冲在放、屏幕上有变化；再等它放完
	if 界 and 界.get("扫"):
		while 界.扫.冷 > 0.0 or 界.扫.扫中: await get_tree().process_frame
		await 键(令.扫["键"]); await 等(0.3)
		记.call("Space 触发扫描", 界.扫.扫中, "")
		await 存("12_扫描中"); await 等(令.扫["时长"] + 0.5)
	# 重入：游戏 → 菜单 → 火星日规划 → Esc → 菜单 → 自由漫游 → 菜单 → 火星日规划（界面重建时旧节点的 draw 信号曾画到新节点上）
	var 窗 := get_window(); var 原窗 := 窗.size; var 缩过 := false
	for 模 in ["B", "A", "B"]:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		await 键(KEY_ESCAPE); await 等(0.2); await 键(KEY_ESCAPE); await 等(0.8)
		记.call("重入：回到菜单（" + 模 + "）", 态 == "回来")
		while 项[选]["键"] != 模: await 键(KEY_RIGHT)
		if 模 == "A": 缩过 = true; 窗.size = Vector2i(int(原窗.x*0.8), int(原窗.y*0.8)); await 等(0.5)   # 界面关着时窗口尺寸变了：下次打开规划图要整页重建
		await 键(KEY_ENTER); while 态 != "关": await get_tree().process_frame
		if 模 == "B" and 玩 and 玩.B:
			var B: Node = 玩.B
			记.call("重入：规划图打开", B.图页.开着, "阶段 " + str(B.阶段))
			if B.阶段 == "下行": await 键(KEY_ENTER); await 等(0.5)                    # 下行卡 → 规划图
			var t1 := Time.get_ticks_msec()
			while not B.通好了() and Time.get_ticks_msec() - t1 < 60000: await get_tree().process_frame
			B.图页.刷新(); await 等(0.8); await 存("13_重入_规划图")
			记.call("重入：险标已画（可通行性算好）", B.通好了() and not B.险标.is_empty())
			if 缩过: 记.call("重入：窗口尺寸变了、整页重建", 窗.size != 原窗 and B.图页.尺寸 == Vector2i(B.图页.层.get_viewport().get_visible_rect().size), str(窗.size))
			await 键(KEY_ESCAPE); await 等(0.6)                                   # 规划图 Esc → 回游戏
			记.call("重入：规划图 Esc 回游戏", not B.页开着())
		else:
			await 等(0.6)
	窗.size = 原窗
	var 报 := 错.取()
	var 画错 := 报.filter(func(x): return "Drawing is only allowed" in x)
	for x in 报.slice(0, 12): print("[菜单测试]   ERROR ", x)
	记.call("日志无 Drawing is only allowed", 画错.is_empty(), "%d 条" % 画错.size())
	记.call("日志无 ERROR（整轮自测）", 报.is_empty(), "%d 条" % 报.size())
	if 令.英(): 记.call("英文：画出的字里没有残留中文（令.译缺）", 令.译缺.is_empty(), str(令.译缺.keys()))
	print("[菜单测试] 计时 %s；载入 %s" % [str(计时), str(令.载入记)])
	print("[菜单测试] 通过：%d 项，%d 项失败" % [计[0], 计[1]])
	await 等(0.3)
	P.quit_clean()
