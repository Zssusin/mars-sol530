# 全息地形台（全屏 3D 地形图）。设计：docs/界面/界面减字与交互规范.md §2–§5；样张 docs/界面/地图样张/样张_全息_D3_专业工具风.png（生成脚本 全息.py 模式 F、全息动画D.py）。
#   M 开 / 关。打开时世界暂停、主 3D 视图不再渲染（disable_3d），地图自己在一个 SubViewport 里画（地形网格 + 着色器等高线，路线、距离圈、已探索点云），
#   工具栏、右表、状态栏、标记、标签在主视口的 2D 层（画.gd）。机位 = 焦点（地面点）+ 半宽（缩放）+ 方位 + 俯仰；初始机位就是样张的机位（地图台机位.json）。
#   数据：数据/sol0530/地图台*.json|bin|png（scripts/Godot/90_地图台数据.py）。着色器：界面/地图台/*.gdshader。
#   自测：--地图台测试[=目录]（界面/地图台/测试.sh）。样张对照：--地图台样张=1（已发现集合、选中目标、状态栏光标按样张）。
extends Node

const 数据脚本 := preload("res://界面/地图台/数据.gd")
const 画脚本 := preload("res://界面/地图台/画.gd")
const 样张已发现 := ["hawksbill_gap", "three_forks", "butler_landing", "wildcat_ridge", "skinner_ridge", "hogwallow_flats", "sol535_tracks"]
const 半默认 := 2000.0
const 半最小 := 100.0                           # 缩放范围的唯一出处（半宽，m；对数刻度，后面往行星尺度放时只改这几个常量）
const 半最大 := 25000.0                         # 最宽：实际上限还要看 半上限()（相机离数据中心 / 离地高度都有界，见下），所以永远看不到数据的方形边
const 数据半宽 := 98000.0                       # 高度金字塔的覆盖半径
const 焦界比 := 0.40                            # 焦点离数据中心最远 = 比例 × 数据半宽（软界：拖过头有阻力，松手弹回）
const 机位界比 := 0.60                          # 相机的地面位置离数据中心最远
const 高界比 := 0.50                            # 相机离地高度上限
const 渐隐起 := 0.50; const 渐隐止 := 0.85      # 数据中心为圆心的渐隐圈（比例 × 数据半宽）：圈外什么都不画，所以方形边永远不出现
const 锚远 := 5.0                               # 光标在地平线上或指到太远的地方时，用「沿视线水平方向 半 × 锚远 处的地面点」当锚
const 环格 := 96                                # 每环每边的半格数
const 档 := {"1": 200.0, "2": 2000.0, "3": 25000.0}

var P: Node
var 玩: Node
var 数: RefCounted
var 开着 := false
var 态 := "关"                                    # 关 / 开中 / 开 / 关中
var 钟 := 0.0                                     # 样张时间线的秒（打开 0 → 3.6）
var 时标 := 0.55                                  # 样张秒 / 真实秒：3.6 s 的样张压到 ≈ 2 s
var 总长 := 3.7
var 层: CanvasLayer
var 视口: SubViewport
var 显: TextureRect
var 相机: Camera3D
var 叠: Control
var 地形环: Array = []; var 满网: ArrayMesh; var 环网: ArrayMesh; var 墙: MeshInstance3D; var 路线: MeshInstance3D; var 点云: MeshInstance3D
var 圈组: Array = []
var 圈半径 := [[25.0, 50.0, 100.0], [250.0, 500.0, 1000.0], [5000.0, 10000.0, 20000.0]]
var 材: Dictionary = {}
var 底画: ColorRect
var 尺 := Vector2(2560, 1440)
# 视角
var 焦 := Vector2.ZERO
var 焦高 := 0.0                                   # 相机绕着转的那个点的高度（世界 y）：平时慢慢跟着焦点处的地面，抓着 / 滚轮钉着地面点时冻住（不然相机一动，钉住的点就被带走）
var 半 := 半默认
var 半目标 := 半默认
var 方位 := 180.0; var 方位目标 := 180.0
var 俯仰 := 56.0; var 俯仰目标 := 56.0
var 净空时俯仰 := -1.0
var 拖屏 := Vector2.ZERO                          # 左键拖动时光标最近的位置（镜头高度变了要重钉）
var 实俯仰 := 56.0                               # 实际用的俯仰：平时 = 俯仰；相机要钻地时被抬高（净空俯仰()）
var 垂放 := 3.0; var 垂放目标 := 3.0
var 锚: Variant = null                            # 滚轮缩放 / 拖动时钉住的地面点（Vector3 E, U, N）
var 锚屏 := Vector2.ZERO
var 滚锚: Array = []                               # 滚轮缩放用的锚（[地面点, 屏位置]）；光标动了、或平移 / 转台 / 键盘动了镜头就清掉
var 滚锚屏 := Vector2.ZERO
var 软界外 := 0.0                                  # 自测读：焦点超出软界的量（m）
var 惯 := Vector2.ZERO                            # 平移惯性（焦点速度 m/s）
var 缓动: Dictionary = {}
var 台心偏 := Vector2.ZERO
var 距比 := 2.54
var 台半 := Vector2(2475.0, 1525.0)
var 机位 := Vector3.ZERO; var 前 := Vector3.FORWARD; var 右 := Vector3.RIGHT; var 上 := Vector3.UP
var 焦距k := 1000.0
var hfov := 38.0
# 鼠标
var 鼠 := Vector2(-1, -1)
var 左按 := false; var 右按 := false; var 左起 := Vector2(); var 拖了 := false; var 按下目标: Variant = null
var 上帧焦 := Vector2()
var 悬停地: Variant = null                        # 鼠标下的地面点 Vector3(E, U, N) 或 null
var 悬停淡 := 0.0
# 选中、图层、杂项
var 选中 := "butler_landing"
var 选中新 := 0.0                                 # 选中后的进度（引线、数字）0–1
var 层开 := {"路线": true, "兴趣点": true, "坡度": true, "地名": true, "已探索": true}
var 图层页 := false
var 帮助页 := false
var 样张 := false
var 车E := 0.0; var 车N := 0.0; var 车航 := 252.0
var 吐司 := ""; var 吐司时 := 0.0
var 测 := false
var 渲染时 := 0.0
var 上次尺 := Vector2()
const 默认俯仰 := 16.0                          # 默认低俯角：地平线在画面上部，坑缘和三角洲是天际线（俯仰下限 10°）


func 默认方位() -> float:
	"""默认朝坑缘的方向看（相机在相反一侧）。"""
	var rim := 取点("jezero_rim")
	if rim.is_empty(): return 180.0
	return fposmod(rad_to_deg(atan2(rim["E"], rim["N"])) + 180.0, 360.0)


func 拉远() -> void:
	"""打开动画的头 0.8 s：相机从车旁低处拉远抬高到默认机位（和脉冲同时扫向地平线）。"""
	var p := 令.缓(clampf(钟*时标*maxf(令.动倍, 0.01)/0.8, 0.0, 1.0), "入出")
	半 = exp(lerpf(log(半默认*0.06), log(半默认), p)); 半目标 = 半
	俯仰 = lerpf(7.0, 默认俯仰, p); 俯仰目标 = 俯仰
	置焦(Vector2(车E, 车N))


func _ready() -> void:
	P = get_parent(); 玩 = P.get_node_or_null("玩法")
	process_mode = Node.PROCESS_MODE_ALWAYS
	样张 = P.args.get("地图台样张", "0") == "1"
	数 = 数据脚本.new()
	hfov = 75.0
	if P.args.has("地图台测试"):
		测 = true
		var t: Node = load("res://界面/地图台/自测.gd").new(); t.name = "自测"; add_child(t)


var 已搭 := false
var 搭坏 := false


func 搭起() -> bool:
	"""第一次按 M 才载数据、建视口和网格：地图没打开过时对驾驶一点开销都没有（常驻的子视口和 15 层高度纹理会拖慢重场景）。"""
	if 已搭: return true
	if 搭坏: return false
	if not 数.载(String(P.D)):
		push_warning("[地图台] 数据没找全（跑 scripts/Godot/90_地图台数据.py）"); 搭坏 = true; return false
	var 台: Array = 数.机位["台"]
	台半 = Vector2((台[1] - 台[0])*0.5, (台[3] - 台[2])*0.5)
	var 心 := Vector2((台[0] + 台[1])*0.5, (台[2] + 台[3])*0.5)
	var 目标: Array = 数.机位["目标"]
	var f0 := Vector2(目标[0], -目标[2])
	台心偏 = f0 - 心
	搭()
	get_viewport().size_changed.connect(func(): 搭尺寸())
	已搭 = true
	return true


# ———————————————————— 搭
func 搭() -> void:
	层 = CanvasLayer.new(); 层.layer = 46; 层.visible = false; 层.process_mode = Node.PROCESS_MODE_ALWAYS; add_child(层)
	视口 = SubViewport.new(); 视口.own_world_3d = true; 视口.msaa_3d = Viewport.MSAA_4X; 视口.render_target_update_mode = SubViewport.UPDATE_DISABLED
	视口.size = Vector2i(get_viewport().get_visible_rect().size); 视口.transparent_bg = false; 视口.handle_input_locally = false; 视口.gui_disable_input = true
	add_child(视口)
	var env := Environment.new(); env.background_mode = Environment.BG_CANVAS; env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new(); we.environment = env; 视口.add_child(we)
	var cl := CanvasLayer.new(); cl.layer = -1; 视口.add_child(cl)
	底画 = ColorRect.new(); 底画.set_anchors_preset(Control.PRESET_FULL_RECT); 底画.size = Vector2(视口.size)
	var sm := ShaderMaterial.new(); sm.shader = load("res://界面/地图台/底.gdshader"); sm.set_shader_parameter("bg", 数.底纹); 底画.material = sm; cl.add_child(底画); 材["底"] = sm
	相机 = Camera3D.new(); 相机.keep_aspect = Camera3D.KEEP_WIDTH; 相机.fov = hfov; 视口.add_child(相机)
	var sh := {}
	for k in ["地形", "线", "点"]: sh[k] = load("res://界面/地图台/%s.gdshader" % k)
	# 地形：嵌套的方环（每环格距翻倍，由近到远），顶点由着色器按「环中心 + 整数格 × 格距」摆、按高度金字塔取高；没有台边，一直铺到数据边缘
	满网 = _环网格(true); 环网 = _环网格(false)
	材["地形"] = _材(sh["地形"])
	for i in 14:
		var mi := MeshInstance3D.new(); mi.mesh = 满网 if i == 0 else 环网; mi.custom_aabb = AABB(Vector3(-1e7, -1e5, -1e7), Vector3(2e7, 2e5, 2e7)); mi.material_override = 材["地形"]
		视口.add_child(mi); 地形环.append(mi)
	# 路线
	var polys: Array = []
	for i in 数.段起.size():
		var a: int = 数.段起[i]; var b: int = 数.段起[i + 1] if i + 1 < 数.段起.size() else 数.路E.size()
		var pl := PackedVector2Array()
		for j in range(a, b): pl.append(Vector2(数.路E[j], 数.路N[j]))
		polys.append(pl)
	路线 = MeshInstance3D.new(); 路线.mesh = _带网格(polys, true, true); 路线.custom_aabb = AABB(Vector3(-1e7, -1e5, -1e7), Vector3(2e7, 2e5, 2e7)); 视口.add_child(路线)
	材["路线"] = _材(sh["线"]); 路线.material_override = 材["路线"]; (材["路线"] as ShaderMaterial).render_priority = 3
	for k in 3:
		var pl2: Array = []
		for R in 圈半径[k]:
			var c := PackedVector2Array()
			for d in 361: c.append(Vector2(sin(deg_to_rad(d))*R, cos(deg_to_rad(d))*R))
			pl2.append(c)
		var mi := MeshInstance3D.new(); mi.mesh = _带网格(pl2, false); mi.custom_aabb = AABB(Vector3(-1e7, -1e5, -1e7), Vector3(2e7, 2e5, 2e7)); 视口.add_child(mi)
		var m := _材(sh["线"]); mi.material_override = m; m.render_priority = 2; 圈组.append(m); m.set_shader_parameter("dash", 17.0); m.set_shader_parameter("hid_a", 0.0)
		m.set_shader_parameter("width", 1.6)
	# 已探索点云
	var arr: Array = []; arr.resize(Mesh.ARRAY_MAX)
	var n: int = 数.点.size(); var vs := PackedVector3Array(); vs.resize(n)
	for i in n: vs[i] = Vector3(数.点[i].x, float(i)/n, 数.点[i].y)
	arr[Mesh.ARRAY_VERTEX] = vs
	var pmesh := ArrayMesh.new(); pmesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arr); pmesh.custom_aabb = AABB(Vector3(-1e7, -1e5, -1e7), Vector3(2e7, 2e5, 2e7))
	点云 = MeshInstance3D.new(); 点云.mesh = pmesh; 点云.custom_aabb = AABB(Vector3(-1e7, -1e5, -1e7), Vector3(2e7, 2e5, 2e7)); 视口.add_child(点云)
	材["点"] = _材(sh["点"]); 点云.material_override = 材["点"]; (材["点"] as ShaderMaterial).render_priority = 1
	显 = TextureRect.new(); 显.texture = 视口.get_texture(); 显.set_anchors_preset(Control.PRESET_FULL_RECT); 显.mouse_filter = Control.MOUSE_FILTER_IGNORE; 显.stretch_mode = TextureRect.STRETCH_SCALE; 层.add_child(显)
	叠 = Control.new(); 叠.set_script(画脚本); 叠.set_anchors_preset(Control.PRESET_FULL_RECT); 叠.mouse_filter = Control.MOUSE_FILTER_IGNORE; 叠.M = self; 层.add_child(叠)
	令.变了.connect(func(): 推色())
	搭尺寸(); 推色()


func 搭尺寸() -> void:
	var vs := Vector2i(get_viewport().get_visible_rect().size)
	if vs.x < 64 or 视口 == null: return
	视口.size = vs; 尺 = Vector2(vs); 底画.size = 尺
	焦距k = (尺.x*0.5)/tan(deg_to_rad(hfov)*0.5)
	for k in ["线"]: pass
	(材["路线"] as ShaderMaterial).set_shader_parameter("vp", 尺)
	for m in 圈组: m.set_shader_parameter("vp", 尺)


func _材(sh: Shader) -> ShaderMaterial:
	var m := ShaderMaterial.new(); m.shader = sh
	m.set_shader_parameter("hts", 数.纹); m.set_shader_parameter("bg", 数.底纹)
	return m


func _环网格(满: bool) -> ArrayMesh:
	"""(2M+1)² 个整数格点；满 = 整块，否则挖掉中间的方洞（里面是更细的那一环）。
	洞比细环每边小一格（粗格）：各环的中心各自对齐自己的格距，细环相对洞最多错开一个细格，洞和细环一样大时错开的那一侧会露出一条没有地形的暗带，缩放时还会跳。"""
	var M_ := 环格; var n := 2*M_ + 1
	var vs := PackedVector3Array(); vs.resize(n*n)
	for j in n:
		for i in n: vs[j*n + i] = Vector3(i - M_, 0, j - M_)
	var idx := PackedInt32Array()
	for j in n - 1:
		for i in n - 1:
			var 洞 := (not 满) and (i >= M_ - M_/2 + 1 and i < M_ + M_/2 - 1 and j >= M_ - M_/2 + 1 and j < M_ + M_/2 - 1)
			if 洞: continue
			var a := j*n + i
			idx.append_array(PackedInt32Array([a, a + 1, a + n, a + 1, a + n + 1, a + n]))
	var arr: Array = []; arr.resize(Mesh.ARRAY_MAX); arr[Mesh.ARRAY_VERTEX] = vs; arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new(); m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr); return m


func _平滑(pl: PackedVector2Array, 半窗: int, 遍: int) -> PackedVector2Array:
	"""路线点是约 1 m 一个的轨迹，带 GPS / 里程计抖动：滑动平均（两端不动），近处放大才不锯齿。"""
	var q := pl
	if q.size() > 8:                                  # 先抽稀到约 4 m 一个点：方向不再被相邻 1 m 点的抖动带着乱跳
		var r := PackedVector2Array([q[0]]); var 累 := 0.0
		for i in range(1, q.size() - 1):
			累 += (q[i] - q[i - 1]).length()
			if 累 >= 4.0: r.append(q[i]); 累 = 0.0
		r.append(q[q.size() - 1])
		q = r
	for t in 遍:
		var o := q.duplicate()
		for i in range(1, q.size() - 1):
			var w := mini(半窗, mini(i, q.size() - 1 - i)); var sum := Vector2.ZERO
			for j in range(i - w, i + w + 1): sum += q[j]
			o[i] = sum/float(2*w + 1)
		q = o
	return q


func _带网格(polys: Array, 全局f: bool, 平滑 := false) -> ArrayMesh:
	"""贴地折线 = 一条三角带（每个折点 2 个顶点，在着色器里按屏幕上的前后两段取斜接方向展开，所以段与段之间不叠）。
	VERTEX = (E, 侧±1, N)，UV = 前一点 (E, N)，CUSTOM0.xy = 后一点 (E, N)，UV2 = (弧长 m, 全程比例)。"""
	var vs := PackedVector3Array(); var uv := PackedVector2Array(); var uv2 := PackedVector2Array(); var nx := PackedFloat32Array(); var idx := PackedInt32Array()
	var 总 := 0.0
	var 列: Array = []
	for pl in polys:
		var p: PackedVector2Array = pl
		if 平滑 and p.size() > 4: p = _平滑(p, 2, 2)
		列.append(p)
		for i in range(1, p.size()): 总 += (p[i] - p[i - 1]).length()
	总 = maxf(总, 1.0)
	var 累 := 0.0
	for p in 列:
		if p.size() < 2: continue
		var b := vs.size()
		var 弧 := 累
		for i in p.size():
			if i > 0: 弧 += (p[i] - p[i - 1]).length()
			var pv: Vector2 = p[maxi(i - 1, 0)]; var nt: Vector2 = p[mini(i + 1, p.size() - 1)]
			for sd in [-1.0, 1.0]:
				vs.append(Vector3(p[i].x, sd, p[i].y)); uv.append(pv); nx.append(nt.x); nx.append(nt.y); nx.append(0.0); nx.append(0.0)
				uv2.append(Vector2(弧, (弧/总) if 全局f else 0.0))
		累 = 弧
		for i in p.size() - 1:
			var a: int = b + i*2
			idx.append_array(PackedInt32Array([a, a + 1, a + 2, a + 1, a + 3, a + 2]))
	var arr: Array = []; arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = vs; arr[Mesh.ARRAY_TEX_UV] = uv; arr[Mesh.ARRAY_TEX_UV2] = uv2; arr[Mesh.ARRAY_CUSTOM0] = nx; arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr, [], {}, Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	return m


func 推色() -> void:
	if not 数 or 材.is_empty(): return
	var c主: Color = 令.色["主"]; var c活: Color = 令.色["活"]; var c注: Color = 令.色["注意"]; var c底: Color = 令.色["页底"]
	if 令.有活边 and 令.是活(c活): c活 = 令.色["活亮"]                      # 3D 里的线压在深色底上：NASA 色板的深蓝读不出来，用同色系的亮蓝
	(材["地形"] as ShaderMaterial).set_shader_parameter("c_main", Vector3(c主.r, c主.g, c主.b))
	(材["地形"] as ShaderMaterial).set_shader_parameter("c_live", Vector3(c活.r, c活.g, c活.b))
	(材["地形"] as ShaderMaterial).set_shader_parameter("c_warn", Vector3(c注.r, c注.g, c注.b))
	(材["路线"] as ShaderMaterial).set_shader_parameter("c_col", Vector3(c活.r, c活.g, c活.b))
	(材["点"] as ShaderMaterial).set_shader_parameter("c_col", Vector3(c主.r, c主.g, c主.b))
	for m in 圈组: m.set_shader_parameter("c_col", Vector3(c主.r, c主.g, c主.b))
	for k in ["地形", "线", "点", "路线", "底"]:
		if 材.has(k): (材[k] as ShaderMaterial).set_shader_parameter("c_tint", Vector3(c底.r, c底.g, c底.b))
	(材["底"] as ShaderMaterial).set_shader_parameter("c_tint", Vector3(c底.r, c底.g, c底.b))


# ———————————————————— 机位
func 台矩形() -> Vector4:
	"""不再有「台」：这是焦点周围的取样范围（等高线数字、取点用）。"""
	var r := 半*3.0
	return Vector4(焦.x - r, 焦.x + r, 焦.y - r, 焦.y + r)


func 置焦(f: Vector2) -> void:
	焦 = f; 焦高 = 数.高(f.x, f.y)*垂放


func _机位于(t: Vector3, dist: float, az: float, 度: float) -> Vector3:
	var el := deg_to_rad(度)
	return t + dist*Vector3(sin(az)*cos(el), sin(el), -cos(az)*cos(el))


func _埋(t: Vector3, dist: float, az: float, 度: float) -> bool:
	"""这个俯仰下相机是不是钻到地面以下：查相机脚下和朝焦点方向前面四分之一段（近处的坡挡满画面也算）。"""
	var p := _机位于(t, dist, az, 度); var 余 := maxf(dist*0.05, 3.0)
	for s in [0.0, 0.05, 0.1, 0.17, 0.25]:
		var q: Vector3 = p.lerp(t, s)
		if q.y < 数.高(q.x, -q.z)*垂放 + 余*(1.0 - 2.0*s): return true
	return false


func 净空俯仰(t: Vector3, dist: float, az: float) -> float:
	"""相机不许进地面：按用户要的俯仰摆不下去时，取刚好高出地面的最小俯仰（二分，连续，不跳）。"""
	if not _埋(t, dist, az, 俯仰): return 俯仰
	var lo := 俯仰; var hi := 85.0
	if _埋(t, dist, az, hi): return hi
	for i in 12:
		var m := (lo + hi)*0.5
		if _埋(t, dist, az, m): lo = m
		else: hi = m
	return hi


func 净空步() -> bool:
	"""每帧一次：按当前焦点定实际俯仰（相机不进地面）。返回有没有变。"""
	var 要 := 净空俯仰(Vector3(焦.x, 焦高, -焦.y), 半*距比, deg_to_rad(方位))
	var 变 := absf(要 - 实俯仰) > 0.005
	实俯仰 = 要; 净空时俯仰 = 俯仰
	return 变


func 摆机() -> void:
	var az := deg_to_rad(方位)
	var t := Vector3(焦.x, 焦高, -焦.y)
	var dist := 半*距比
	if 俯仰 != 净空时俯仰: 净空步()                     # 俯仰被直接改了（右键转台、按键、自测）：先重定一次
	机位 = _机位于(t, dist, az, 实俯仰)                 # 实俯仰 每帧由 净空步() 定一次；一帧之内不变，钉点的计算才一步就准
	前 = (t - 机位).normalized(); 右 = 前.cross(Vector3.UP).normalized(); 上 = 右.cross(前)
	if 相机:
		相机.global_transform = Transform3D(Basis(右, 上, -前), 机位)
		相机.near = maxf(dist*0.02, 1.0); 相机.far = maxf(dist*14.0, 600000.0)


func 投(p: Vector3) -> Vector3:
	"""世界点（x = E，y = 高 × 垂直放大，z = −N）→ (屏 x, 屏 y, 深度)。"""
	var d := p - 机位; var z := d.dot(前)
	if z < 1e-3: return Vector3(-1e5, -1e5, z)
	return Vector3(尺.x*0.5 + d.dot(右)/z*焦距k, 尺.y*0.5 - d.dot(上)/z*焦距k, z)


func 地世(E: float, N: float, 抬 := 0.0) -> Vector3:
	return Vector3(E, 数.高(E, N)*垂放 + 抬, -N)


func 地屏(E: float, N: float, 抬 := 0.0) -> Vector3:
	return 投(地世(E, N, 抬))


func 每像素米() -> float:
	return 半*距比/焦距k


func 射线(屏p: Vector2) -> Array:
	var d := (前 + 右*((屏p.x - 尺.x*0.5)/焦距k) - 上*((屏p.y - 尺.y*0.5)/焦距k)).normalized()
	return [机位, d]


func 屏到地(屏p: Vector2) -> Variant:
	"""射线和地形（高 × 垂直放大）求交；没打到地面返回 null。返回 Vector3(E, U, N)。"""
	var r := 射线(屏p); var o: Vector3 = r[0]; var d: Vector3 = r[1]
	if d.y > -1e-4: return null
	var rc := 台矩形()
	var umin := 1e9; var umax := -1e9
	for i in 5:
		for j in 5:
			var h = 数.高(lerpf(rc.x, rc.y, i/4.0), lerpf(rc.z, rc.w, j/4.0)); umin = minf(umin, h); umax = maxf(umax, h)
	var ymax := (umax + 20.0 + (umax - umin)*0.3)*垂放; var ymin := (umin - 20.0 - (umax - umin)*0.3)*垂放
	var t0 := maxf(0.0, (ymax - o.y)/d.y); var t1 := minf((ymin - o.y)/d.y, t0 + 数据半宽*3.0)
	var N := 120; var 前t := t0; var 命中 := false; var tb := t1
	for i in range(1, N + 1):
		var t := lerpf(t0, t1, float(i)/N); var p := o + d*t
		if p.y <= 数.高(p.x, -p.z)*垂放: tb = t; 命中 = true; break
		前t = t
	if not 命中: return null
	var lo := 前t; var hi := tb
	for i in 14:
		var m := (lo + hi)*0.5; var p := o + d*m
		if p.y <= 数.高(p.x, -p.z)*垂放: hi = m
		else: lo = m
	var p := o + d*hi
	if absf(p.x) > 数据半宽*1.5 or absf(p.z) > 数据半宽*1.5: return null
	return Vector3(p.x, p.y/垂放, -p.z)


func 锚定(地: Vector3, 屏p: Vector2) -> bool:
	"""移焦点，让地面点 地(E,U,N) 落在屏幕 屏p：屏幕射线和过该点的水平面求交，差值就是要挪的量（相机随焦点平移，所以一步就准）。
	光标在地平线之上（射线下倾 < 0.6°）时不动，返回 false（拖动到天上就停在地平线，不会把焦点甩飞）。"""
	for i in 6:
		摆机()
		var r := 射线(屏p); var d: Vector3 = r[1]
		if d.y > -0.03: return false
		var py := 地.y*垂放
		var t := (py - 机位.y)/d.y
		var q := 机位 + d*t
		var 差 := Vector2(地.x - q.x, 地.z + q.z)
		if 差.length() > 半*8.0: return false
		if 差.length() < 0.01: break
		焦 += 差
	摆机()
	return true


func 取锚(屏p: Vector2) -> Array:
	"""滚轮缩放 / 拖动钉住的点：[地面点 Vector3(E,U,N), 它该在的屏幕位置]。
	光标下有近处的地面、而且视线下倾 ≥ 3.4°（再平，地面点高一点低一点就会让相机甩出几公里，钉不住）：就是光标下的地面点。
	否则（光标在地平线上 / 指到很远的地方 / 视线太平）：取「沿视线水平方向、半 × 锚远 处、焦点高度的水平面」上的点当锚，屏幕位置取该点自己的投影。"""
	var g: Variant = 屏到地(屏p)
	var d: Vector3 = 射线(屏p)[1]
	if g != null and d.y < -0.06 and 投(Vector3(g.x, g.y*垂放, -g.z)).z <= 半*距比*5.0: return [g, 屏p]
	var h := Vector2(d.x, d.z)
	if h.length() < 1e-5: return []
	h = h.normalized()*半*锚远
	var E := 机位.x + h.x; var N := -(机位.z + h.y)
	var q := 投(Vector3(E, 焦高, -N))
	if q.z <= 0.0 or q.y < 0.0 or q.y > 尺.y or q.x < -尺.x or q.x > 2.0*尺.x: return []
	return [Vector3(E, 焦高/垂放, N), Vector2(q.x, q.y)]


func 滚动锚定() -> void:
	"""滚轮缩放：相机在「锚点 → 光标射线」上沿线推近 / 拉远，距离和半宽成正比；再反推焦点和焦点高度。"""
	摆机()
	var g: Vector3 = 滚锚[0]
	var d: Vector3 = 射线(滚锚[1])[1]
	var c := Vector3(g.x, g.y*垂放, -g.z) - d*(float(滚锚[2])*半/float(滚锚[3]))
	var el := deg_to_rad(实俯仰); var az := deg_to_rad(方位)
	var 向 := Vector3(sin(az)*cos(el), sin(el), -cos(az)*cos(el))
	var t := c - 向*(半*距比)
	焦 = Vector2(t.x, -t.z); 焦高 = t.y
	摆机()


func 半上限() -> float:
	"""缩放的实际上限：相机的地面位置离数据中心 ≤ 机位界比 × 半宽，相机离地 ≤ 高界比 × 半宽。
	所以越靠近数据边缘、俯仰越高，能拉得越小——总是处在渐隐圈里面，方形边缘进不了画面。"""
	var el := deg_to_rad(俯仰目标)
	var 平 := 距比*cos(el); var 高 := 距比*sin(el)
	var 余 := maxf(0.0, 机位界比*数据半宽 - maxf(absf(焦.x), absf(焦.y)))
	return clampf(minf(余/maxf(平, 0.05), 高界比*数据半宽/maxf(高, 0.05)), 半最小, 半最大)


func 焦界() -> float:
	return 焦界比*数据半宽


func 权() -> Vector3:
	"""缩放类：x = 近（< 800 m），y = 中，z = 远（> 8 km）；连续淡变（对数）。"""
	var l := log(半)
	var far := smoothstep(log(6000.0), log(10000.0), l); var near := 1.0 - smoothstep(log(600.0), log(1000.0), l)
	return Vector3(near, maxf(0.0, 1.0 - far - near), far)


# ———————————————————— 开 / 关
func 能开() -> bool:
	if 玩 == null: return true
	if 玩.菜单 and 玩.菜单.开着: return false
	if 玩.B and 玩.B.页开着(): return false
	if 玩.图鉴 and 玩.图鉴.开着: return false
	if 玩.拍照 and 玩.拍照.开着: return false
	if 玩.复刻 and 玩.复刻.结果开着: return false
	return true


func 打开() -> void:
	if 开着 or 数 == null or not 搭起(): return
	var 车 := Vector3.ZERO
	if 玩: 车 = 玩.车位()
	车E = 车.x; 车N = -车.z
	var rr: Node3D = P.rover_root
	if rr and is_instance_valid(rr): 车航 = rad_to_deg(atan2(rr.global_transform.basis.z.x, -rr.global_transform.basis.z.z))
	if 样张: 车E = 0.0; 车N = 0.0; 车航 = 252.0
	开着 = true
	if 玩: 玩.暂停("地图台", true); 玩.放鼠标()
	else: Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	垂放 = 3.0; 垂放目标 = 3.0; 置焦(Vector2(车E, 车N)); 半 = 半默认; 半目标 = 半默认; 方位 = 默认方位(); 方位目标 = 方位; 俯仰 = 默认俯仰; 俯仰目标 = 俯仰; 垂放 = 3.0; 垂放目标 = 3.0
	锚 = null; 惯 = Vector2.ZERO; 缓动 = {}; 悬停地 = null; 图层页 = false; 帮助页 = false; 左按 = false; 右按 = false
	if not 样张 and 选中 == "": 选中 = ""
	选中新 = 0.0 if 令.动倍 > 0.0 else 1.0
	视口.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	get_tree().root.disable_3d = true
	层.visible = true
	态 = "开中" if 令.动倍 > 0.0 else "开"
	钟 = 0.0 if 令.动倍 > 0.0 else 总长
	摆机(); 推参(0.0); 叠.queue_redraw()


func 关闭() -> void:
	if not 开着 or 态 == "关中": return
	if 令.动倍 <= 0.0: 收尾(); return
	态 = "关中"


func 收尾() -> void:
	开着 = false; 态 = "关"; 层.visible = false
	视口.render_target_update_mode = SubViewport.UPDATE_DISABLED
	get_tree().root.disable_3d = false
	if 玩: 玩.暂停("地图台", false); 玩.还鼠标()
	else: Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	左按 = false; 右按 = false


func 跳过() -> void:
	if 态 == "开中": 钟 = 总长; 态 = "开"


func 段内(a: float, b: float) -> float:
	return 令.缓(clampf((钟 - a)/(b - a), 0.0, 1.0))


# ———————————————————— 输入
func _unhandled_input(ev: InputEvent) -> void:
	if 开着 or not (ev is InputEventKey and ev.pressed and not ev.echo): return
	if ev.keycode == KEY_M and not ev.shift_pressed and not ev.ctrl_pressed and 能开():
		打开(); get_viewport().set_input_as_handled()


func _input(ev: InputEvent) -> void:
	if not 开着: return
	if ev is InputEventKey:
		if ev.pressed and not ev.echo: 键(ev)
	elif ev is InputEventMouseButton:
		鼠 = ev.position; 鼠键(ev)
	elif ev is InputEventMouseMotion:
		鼠 = ev.position; 鼠动(ev)
	get_viewport().set_input_as_handled()


func 键(ev: InputEventKey) -> void:
	if 态 == "开中" and ev.keycode != KEY_ESCAPE: 跳过(); return
	match ev.keycode:
		KEY_ESCAPE, KEY_M:
			if 图层页 or 帮助页: 图层页 = false; 帮助页 = false
			else: 关闭()
		KEY_1, KEY_2, KEY_3, KEY_KP_1, KEY_KP_2, KEY_KP_3:
			var k := str(ev.keycode - (KEY_KP_0 if ev.keycode >= KEY_KP_0 and ev.keycode <= KEY_KP_9 else KEY_0))
			跳档(float(档[k]))
		KEY_EQUAL, KEY_KP_ADD, KEY_PLUS: 缩放步(1, Vector2(尺.x*0.5, 尺.y*0.5))
		KEY_MINUS, KEY_KP_SUBTRACT: 缩放步(-1, Vector2(尺.x*0.5, 尺.y*0.5))
		KEY_N: 指北视角()
		KEY_V: 垂放目标 = 1.0 if 垂放目标 > 2.0 else 3.0
		KEY_TAB: 图层页 = not 图层页
		KEY_F1: 帮助页 = not 帮助页
		KEY_ENTER, KEY_KP_ENTER: 设航点()
		KEY_F: if 选中 != "": 飞向(选中)
		KEY_P: 吐司 = "剖面工具下一版做"; 吐司时 = 2.0


func 鼠键(ev: InputEventMouseButton) -> void:
	if 态 == "开中": 跳过(); return
	match ev.button_index:
		MOUSE_BUTTON_WHEEL_UP: if ev.pressed: 缩放步(1, ev.position)
		MOUSE_BUTTON_WHEEL_DOWN: if ev.pressed: 缩放步(-1, ev.position)
		MOUSE_BUTTON_LEFT:
			if ev.pressed:
				左按 = true; 拖了 = false; 左起 = ev.position; 按下目标 = 叠.命中(ev.position); 惯 = Vector2.ZERO; 缓动 = {}
				if ev.double_click and 按下目标 == null:
					var g: Variant = 屏到地(ev.position)
					if g == null:
						var a := 取锚(ev.position)
						if not a.is_empty(): g = a[0]
					if g != null: 双击缩放(g)
					左按 = false
				elif 按下目标 == null:
					var a := 取锚(ev.position); 滚锚 = []
					if not a.is_empty(): 锚 = a[0]; 锚屏 = a[1]
					else: 锚 = null
					上帧焦 = 焦
			else:
				if not 左按: return
				左按 = false
				if not 拖了:
					var 抬 = 叠.命中(ev.position)
					if 抬 != null and 按下目标 != null and str(抬) == str(按下目标): 点击(抬)
				elif 惯.length() > 1.0 and 令.动倍 > 0.0: pass
				else: 惯 = Vector2.ZERO
				锚 = null
		MOUSE_BUTTON_RIGHT:
			右按 = ev.pressed; 滚锚 = []
			if not ev.pressed and absf(wrapf(方位 - 180.0, -180.0, 180.0)) < 5.0: 方位目标 = 180.0


func _软界阻力() -> void:
	"""拖过软界：焦点只跟 40 %（橡皮筋）；松手后 _process 里 τ = 0.07 s 弹回（≈ 0.2 s）。"""
	var L := 焦界()
	var 外 := Vector2(焦.x - clampf(焦.x, -L, L), 焦.y - clampf(焦.y, -L, L))
	if 外 != Vector2.ZERO: 焦 -= 外*0.6
	摆机()


func 鼠动(ev: InputEventMouseMotion) -> void:
	if 滚锚.size() > 0 and (ev.position - 滚锚屏).length() > 3.0: 滚锚 = []
	if 右按:
		方位 += ev.relative.x*0.25; 方位目标 = 方位
		俯仰 = clampf(俯仰 - ev.relative.y*0.2, 10.0, 85.0); 俯仰目标 = 俯仰
		半目标 = minf(半目标, 半上限())
	elif 左按 and 按下目标 == null:
		if not 拖了 and (ev.position - 左起).length() > 6.0*令.s: 拖了 = true
		if 拖了 and 锚 != null:
			拖屏 = ev.position
			锚定(锚, ev.position)
			_软界阻力()


func 缩放步(d: int, 屏p: Vector2) -> void:
	半目标 = clampf(半目标/pow(1.25, d), 半最小, 半上限())
	# 光标没动就一直钉同一个地面点：层间细节变了、地面高度差一点，也不会把点挪走
	if 滚锚.is_empty() or (屏p - 滚锚屏).length() > 3.0:
		摆机()
		var a := 取锚(屏p)
		if a.is_empty(): 滚锚 = []
		else:
			var g: Vector3 = a[0]
			var s0 := (Vector3(g.x, g.y*垂放, -g.z) - 机位).dot(射线(a[1])[1])      # 相机到锚点的距离：之后跟着半宽等比例缩，相机沿视线推近（锚点永远在光标下，不管地面比相机高还是低）
			滚锚 = [g, a[1], s0, 半]
		滚锚屏 = 屏p
	锚 = null
	缓动 = {}
	惯 = Vector2.ZERO


func 指北视角() -> void:
	滚锚 = []
	"""N / 指北 / 立体：在「朝坑缘低俯角」和「正北朝上高俯角（样张 D3 那种）」之间切。"""
	if absf(wrapf(方位目标 - 180.0, -180.0, 180.0)) < 1.0 and 俯仰目标 > 40.0:
		方位目标 = 默认方位(); 俯仰目标 = 默认俯仰
	else: 方位目标 = 180.0; 俯仰目标 = 56.0


func 跳档(h: float) -> void:
	var 目标焦 := 焦
	目标焦 = Vector2(车E, 车N)
	缓到(目标焦, h)


func 缓到(f: Vector2, h: float) -> void:
	锚 = null; 惯 = Vector2.ZERO; 滚锚 = []
	var L := 焦界(); f = Vector2(clampf(f.x, -L, L), clampf(f.y, -L, L))
	缓动 = {"t": 0.0, "f0": 焦, "f1": f, "h0": 半, "h1": clampf(h, 半最小, 半上限()), "y0": 焦高, "y1": 数.高(f.x, f.y)*垂放}
	半目标 = 缓动["h1"]


func 双击缩放(g: Vector3) -> void:
	缓到(Vector2(g.x, g.z), 半目标/1.25*0.8)


func 点击(目标: Variant) -> void:
	var s := str(目标)
	if s.begins_with("点:"): 选(s.substr(2))
	elif s.begins_with("行:"): 选(s.substr(2))
	elif s.begins_with("档:"): 跳档(float(档[s.substr(2)]))
	elif s.begins_with("簇:"):
		var 部 := s.substr(2).split(",")
		缓到(Vector2(float(部[0]), float(部[1])), maxf(半*0.35, 半最小))
	else:
		match s:
			"关": 关闭()
			"工具:放大": 缩放步(1, Vector2(尺.x*0.5, 尺.y*0.5))
			"工具:缩小": 缩放步(-1, Vector2(尺.x*0.5, 尺.y*0.5))
			"工具:指北": 指北视角()
			"工具:立体": 垂放目标 = 1.0 if 垂放目标 > 2.0 else 3.0
			"工具:图层": 图层页 = not 图层页
			"工具:航点": 设航点()
			"工具:帮助": 帮助页 = not 帮助页
			"工具:剖面": 吐司 = "剖面工具下一版做"; 吐司时 = 2.0
			"按钮:航点": 设航点()
			"按钮:飞": if 选中 != "": 飞向(选中)
		if s.begins_with("层:"): 层开[s.substr(2)] = not 层开[s.substr(2)]


func 点表() -> Array:
	return 玩.数据["兴趣点"] if 玩 else []


func 取点(id: String) -> Dictionary:
	for p in 点表(): if p["id"] == id: return p
	return {}


func 已发现(p: Dictionary) -> bool:
	if 样张: return p["id"] in 样张已发现 or p["类"] == "远"
	return (玩 != null and 玩.进度["已发现"].has(p["id"])) or p["类"] == "远"


func 选(id: String) -> void:
	if id == 选中: return
	选中 = id; 选中新 = 0.0 if 令.动倍 > 0.0 else 1.0
	飞向(id)


func 飞向(id: String) -> void:
	var p := 取点(id)
	if p.is_empty(): return
	var 中 := (Vector2(车E, 车N) + Vector2(p["E"], p["N"]))*0.5
	var d := (Vector2(车E, 车N) - Vector2(p["E"], p["N"])).length()
	缓到(中, clampf(maxf(d*0.45, 150.0), 半最小, 半上限()))


func 设航点() -> void:
	"""Enter：选中的目标交给玩法 B 的规划，接在计划末尾（没有 B 或计划还没起，只发信号）。"""
	var p := 取点(选中)
	if p.is_empty(): return
	var ok := false
	if 玩 and 玩.B and 玩.B.计划 != null:
		var 计: RefCounted = 玩.B.计划
		计.航点.append(Vector2(p["E"], p["N"]))
		计.方式.append(int(计.方式[-1]) if not 计.方式.is_empty() else 1)
		玩.B.改计划(); ok = true
	航点设了.emit(选中, Vector2(p["E"], p["N"]))
	吐司 = "已加入航点" if ok else "航点：规划还没开"; 吐司时 = 2.0

signal 航点设了(id, 位置)


# ———————————————————— 每帧
func _process(dt: float) -> void:
	if not 开着: return
	if 态 == "开中": 拉远()
	var t0 := Time.get_ticks_usec()
	var 动 := 令.动倍
	if 态 == "开中":
		钟 += dt/时标*(1.0/maxf(动, 0.01)) if 动 > 0.0 else 总长
		if 钟 >= 总长: 钟 = 总长; 态 = "开"
	elif 态 == "关中":
		钟 -= dt/时标*3.0/maxf(动, 0.01)
		if 钟 <= 0.0: 钟 = 0.0; 收尾(); return
	if 吐司时 > 0.0: 吐司时 -= dt
	var 可动 := 态 == "开"
	# 键盘平移
	if 可动:
		var v := Vector2()
		if Input.is_key_pressed(KEY_LEFT): v.x -= 1
		if Input.is_key_pressed(KEY_RIGHT): v.x += 1
		if Input.is_key_pressed(KEY_UP): v.y += 1
		if Input.is_key_pressed(KEY_DOWN): v.y -= 1
		if v != Vector2.ZERO:
			var rg := Vector2(右.x, -右.z).normalized(); var fg := Vector2(前.x, -前.z).normalized()
			焦 += (rg*v.x + fg*v.y)*半*0.9*dt; 缓动 = {}; 锚 = null; 滚锚 = []
	# 缩放平滑（对数域，τ = 0.09 s）
	var k := 1.0 - exp(-dt/0.09)
	if 缓动.is_empty():
		半 = exp(lerpf(log(半), log(半目标), k)) if 动 > 0.0 else 半目标
	else:
		缓动["t"] += dt/0.3
		var e := 令.缓(缓动["t"], "入出")
		焦 = (缓动["f0"] as Vector2).lerp(缓动["f1"], e); 半 = exp(lerpf(log(缓动["h0"]), log(缓动["h1"]), e)); 焦高 = lerpf(缓动["y0"], 缓动["y1"], e)
		if 缓动["t"] >= 1.0: 缓动 = {}
	if not 右按 and 态 != "开中": 方位 += wrapf(方位目标 - 方位, -180.0, 180.0)*(1.0 - exp(-dt/0.08))
	if not 右按 and 态 != "开中": 俯仰 = lerpf(俯仰, 俯仰目标, 1.0 - exp(-dt/0.08))
	垂放 = lerpf(垂放, 垂放目标, 1.0 - exp(-dt/0.12))
	if 缓动.is_empty() and not 左按 and 锚 == null and 滚锚.is_empty() and 态 != "开中":
		焦高 = lerpf(焦高, 数.高(焦.x, 焦.y)*垂放, 1.0 - exp(-dt/0.4))
	var 半变 := absf(log(半/上帧半)) > 1e-7
	for _i in 4:                                       # 定镜头高度 → 钉点；钉点会挪焦点，高度要求跟着变一点，所以来回几次到不动为止
		var 俯变 := 净空步()
		摆机()
		if 锚 != null and not 左按: 锚定(锚, 锚屏)
		elif 锚 != null and 左按 and 拖了 and 俯变: 锚定(锚, 拖屏)
		elif not 左按 and 滚锚.size() > 0 and (半变 or 俯变): 滚动锚定()
		if not 俯变 and _i > 0: break
	上帧半 = 半
	if 锚 != null and not 左按 and absf(log(半/半目标)) < 0.002: 锚 = null
	# 惯性
	if 左按 and 拖了:
		var dv := (焦 - 上上焦)/maxf(dt, 1e-4); 惯 = 惯.lerp(dv, 0.5)
	elif 惯.length() > 0.5 and not 左按:
		焦 += 惯*dt; 惯 *= exp(-dt/0.25)
	上上焦 = 焦
	# 软边界
	var lim := 焦界()
	var 外 := Vector2(焦.x - clampf(焦.x, -lim, lim), 焦.y - clampf(焦.y, -lim, lim))
	软界外 = 外.length()
	if 外 != Vector2.ZERO and not 左按: 焦 -= 外*(1.0 - exp(-dt/0.07))
	半目标 = minf(半目标, 半上限())
	# 悬停读数
	if 可动 and 鼠.x >= 0 and (鼠 != 上次鼠 or 半 != 上半):
		悬停地 = 屏到地(鼠) if 叠.在地图上(鼠) else null
	上次鼠 = 鼠; 上半 = 半
	悬停淡 = move_toward(悬停淡, 1.0 if 悬停地 != null else 0.0, dt/0.15)
	if 选中新 < 1.0: 选中新 = minf(1.0, 选中新 + dt/(0.5*maxf(动, 0.01)))
	数.kminf = clampf(log(半/8.0)/log(2.0), 3.0, 13.0)
	推参(dt)
	叠.queue_redraw()
	渲染时 = lerpf(渲染时, (Time.get_ticks_usec() - t0)/1000.0, 0.1)

var 上上焦 := Vector2()
var 上次鼠 := Vector2(-9, -9)
var 上半 := 0.0
var 上帧半 := 0.0


func _摆环(mpp: float) -> void:
	"""嵌套环：最细一环的格距跟缩放（≈ 半宽 / 400），往外每环翻倍，铺到数据边缘（+ 焦点偏离原点的量）。环中心对齐各自的格距，平移时网格不游。"""
	var c0 := clampf(半*0.0025, 0.1, 400.0)
	var need := 数据半宽*渐隐止 + maxf(absf(焦.x), absf(焦.y)) + 半*距比*2.0
	for i in 地形环.size():
		var mi: MeshInstance3D = 地形环[i]
		var c := c0*pow(2.0, i); var R := c*环格
		var 用 := i == 0 or c0*环格*pow(2.0, i - 1) < need
		mi.visible = 用
		if 用: mi.set_instance_shader_parameter("ring", Vector3(round(焦.x/c)*c, round(焦.y/c)*c, c))


func 推参(dt: float) -> void:
	var rc := 台矩形(); var zs := 半/半默认; var w := 权()
	var 动 := 态 == "开中" or 态 == "关中"
	var tt := 钟
	var mpp := 每像素米()
	var 动参 := Vector4(tt, 0.15, 1.0, 0.5)
	var dmax := 数据半宽
	var kf := clampf(log(半/8.0)/log(2.0), 3.0, 13.0)
	var pxs := 尺.y/1440.0
	var 坡进 := 段内(1.4, 1.8) if 动 else 1.0
	var 圈进 := 段内(0.6, 1.2) if 动 else 1.0
	var 路进 := (clampf((钟 - 1.4)/1.1, 0.0, 1.0)) if 动 else 1.0
	var 点进 := 1.0
	for mn in ["地形", "路线", "点"]:
		var m: ShaderMaterial = 材[mn]
		m.set_shader_parameter("kmin_f", kf); m.set_shader_parameter("VE", 垂放)
		m.set_shader_parameter("anim", 动参); m.set_shader_parameter("anim_on", 1.0 if 动 else 0.0); m.set_shader_parameter("dmax", dmax)
	for m in 圈组:
		m.set_shader_parameter("kmin_f", kf); m.set_shader_parameter("VE", 垂放)
		m.set_shader_parameter("anim", 动参); m.set_shader_parameter("anim_on", 1.0 if 动 else 0.0); m.set_shader_parameter("dmax", dmax)
	_摆环(mpp)
	var mt: ShaderMaterial = 材["地形"]
	mt.set_shader_parameter("haze", 半*距比*6.0); mt.set_shader_parameter("edge", Vector2(数据半宽*渐隐起, 数据半宽*渐隐止)); mt.set_shader_parameter("fpx", 焦距k)
	mt.set_shader_parameter("wl", w); mt.set_shader_parameter("px", pxs); mt.set_shader_parameter("mpp", mpp)
	var 近淡 := lerpf(0.3, 1.0, smoothstep(log(250.0), log(1500.0), log(半)))       # 贴近时网点淡到 30 %（网点大小已按每个像素自己的距离算，不会再变成大圆斑）
	mt.set_shader_parameter("dots_a", (w.x + w.y)*(1.0 if 层开["坡度"] else 0.0)*坡进*近淡)
	var ml: ShaderMaterial = 材["路线"]
	ml.set_shader_parameter("lift", maxf(6.0*zs, 1.2)); ml.set_shader_parameter("zs", zs); ml.set_shader_parameter("mppx", mpp); ml.set_shader_parameter("prog", 路进); ml.set_shader_parameter("width", 4.0*pxs)
	ml.set_shader_parameter("alpha", 1.0 if 层开["路线"] else 0.0); ml.set_shader_parameter("vp", 尺)
	var cw := [w.x, w.y, w.z]
	for i in 3:
		var m: ShaderMaterial = 圈组[i]
		m.set_shader_parameter("alpha", 0.6*cw[i]*圈进); m.set_shader_parameter("lift", maxf(4.0*zs, 1.0)); m.set_shader_parameter("zs", zs); m.set_shader_parameter("mppx", mpp)
		m.set_shader_parameter("width", 1.6*pxs); m.set_shader_parameter("vp", 尺)
	var mp: ShaderMaterial = 材["点"]
	var dens := clampf(pow(4.0/(mpp*1.3), 2.0), 0.04, 1.0)
	mp.set_shader_parameter("density", dens); mp.set_shader_parameter("px", pxs); mp.set_shader_parameter("psize", 2.2*pxs); mp.set_shader_parameter("zs", zs)
	mp.set_shader_parameter("alpha", (1.0 if 层开["已探索"] else 0.0)*minf(1.0, 1.0/sqrt(maxf(dens, 0.04))*0.6 + 0.4)*0.18); mp.set_shader_parameter("zfocus", 半*距比)
	mp.set_shader_parameter("dd", maxf(4.0, mpp*2.0))
