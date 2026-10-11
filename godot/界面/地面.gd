# 地面图形（界面 v3「丙」，实景地形系统.md §22）：罗盘环、车头三角、路径人字箭头，都是 Decal，从上往下投到地面上。
#   - 天然贴地、随地形起伏，被车身和前面的石块挡住（深度测试是现成的），不改地形着色器。
#   - 车放到第 20 层（同 车反射.gd 的 ROVER_LAYER），Decal 的 cull_mask 去掉这一层：不投到车身上。
#     rig_rover 会把网格拆成新件，所以每秒扫一遍车的件，有新件就挪层。
#   - 石块（实景.gd 的 MultiMesh「石块_*」）放到第 19 层，cull_mask 也去掉：石块不再被投上图形，而是挡住它（地面那段被石块切断）。
#     第 19 层别处没用：相机、灯、车反射探针的 cull_mask 都含这一层，石块照常画、投影、进反射。
#   - 贴图在 _ready 里用 SVG 字符串栅格化（Image.load_svg_from_string），不经导入，不占导出包。颜色从令牌（令）取、烤进贴图：
#     本体（环 = 主色，车头三角 = 活色，箭头 = 调用方给的颜色）同时进 albedo（压掉地面的颜色）和 emission（背阴处也亮）；
#     外扩（令.边：一般是暗色，只在 albedo 里起描边作用；NASA 色板的「活」深蓝配白边，白边也进 emission）。换色板时 重贴()。
#     emission 按色调映射曝光反向补偿：天气模块的自动曝光变了，地面图形的亮度不变。
#   - Decal 的 modulate 只乘 albedo 的 alpha，不乘 emission：淡出时 emission_energy 也跟着乘。
# 开销：环 1 个 + 三角 1 个 + 箭头池 56 个（不用的藏起来）；只在车走了 / 状态变了时挪，平时不动。
extends Node3D

const ROVER_LAYER := 1 << 19                       # 第 20 层：只放车（同 车反射.gd）
const ROCK_LAYER := 1 << 18                        # 第 19 层：只放石块（地面图形不投上去）
const 环R := 2.3                                   # 罗盘环半径（m，同样张；令.地.环R）
const 环尺 := 6.6                                  # 环贴图覆盖的边长（m）
const 箭数 := 56
const 箭距 := 1.0                                  # 人字箭头间距（m）

var P: Node
var R := 环R                                       # 这个实例的环半径（HUD 2.3、主菜单 3.4）
var 尺 := 环尺                                     # 环贴图覆盖的边长（m）
var 环: Decal
var 角: Decal
var 箭: Array[Decal] = []
var 箭纹 := {}                                     # 「颜色|虚」：[albedo, emission]（用到哪种颜色烤哪种）
var 亮: float = 令.地["亮"]                         # emission 基准（曝光 = 基准曝光时）
var 曝基 := 1.0
var 环出 := 0.0                                     # 罗盘环出现进度（每次从不显示变成显示重新长）
var 补 := 1.0                                      # 曝光补偿系数
var 层件 := 0
var 扫累 := 1.0
var 用线环 := false                                # 界面 6：驾驶界面的环 + 刻度改用屏宽线（地线.gd，界面.gd 画），这里只管车头三角和环的出现进度
var 隐环 := false                                  # 主菜单标题页：环和车头三角改用屏宽线（地线.gd），这里不显示
var 用箭 := 0                                      # 当前在用的箭头数


func _init(p: Node, r := 环R) -> void:
	P = p; name = "地面图形"; R = r; 尺 = 2.0*(r + 1.0)


func _ready() -> void:
	曝基 = P.env.tonemap_exposure if P.get("env") else 1.0
	环 = 新贴(纹对(环svg(false), 环svg(true), 环px()), Vector3(尺, 1.6, 尺))   # 盒子矮一点：屏幕上占的簇少（Decal 开销按覆盖的簇算）
	角 = 新贴(纹对(角svg(false), 角svg(true), 128), Vector3(0.8, 1.6, 0.8))
	var 实: Array = 箭纹对(令.色["主"], false)
	for i in 箭数:
		var d := 新贴(实, Vector3(0.8, 1.4, 0.5))
		d.visible = false; d.distance_fade_enabled = true; d.distance_fade_begin = 70.0; d.distance_fade_length = 20.0
		箭.append(d)


func 新贴(纹: Array, sz: Vector3) -> Decal:
	var d := Decal.new()
	d.size = sz
	d.set_texture(Decal.TEXTURE_ALBEDO, 纹[0])
	d.set_texture(Decal.TEXTURE_EMISSION, 纹[1])
	d.emission_energy = 亮
	d.cull_mask = 0xFFFFF & ~ROVER_LAYER & ~ROCK_LAYER
	d.upper_fade = 0.2; d.lower_fade = 0.2; d.normal_fade = 0.25
	add_child(d)
	return d


func 重贴() -> void:
	"""换色板：环、三角重烤，箭头贴图清掉（下次 摆箭 按新颜色烤）。"""
	if 环 == null: return
	for k in [[环, 纹对(环svg(false), 环svg(true), 环px())], [角, 纹对(角svg(false), 角svg(true), 128)]]:
		(k[0] as Decal).set_texture(Decal.TEXTURE_ALBEDO, k[1][0]); (k[0] as Decal).set_texture(Decal.TEXTURE_EMISSION, k[1][1])
	箭纹.clear()
	for d in 箭: d.set_texture(Decal.TEXTURE_ALBEDO, null)


# ———————————————————— 贴图（SVG → Image）
func 环px() -> int:
	return 768 if R <= 环R + 0.01 else 1024                          # 每米约 116 像素


func 色(c: Color) -> String:
	return "#" + c.to_html(false)


func 箭纹对(c: Color, 虚: bool) -> Array:
	var k := "%s|%d" % [c.to_html(false), int(虚)]
	if not 箭纹.has(k): 箭纹[k] = 纹对(箭svg(false, 虚, c), 箭svg(true, 虚, c), 128)
	return 箭纹[k]


func 边层(体: String, 色本: Color, 宽: float, 发光: bool) -> String:
	"""本体 体（stroke 或 fill 的 SVG 片段，颜色占位 {C}、线宽占位 {W}）配外扩：
	一般 = 暗色宽线（a 0.55，只进 albedo）；「活」且色板有活边 = 淡暗色更宽线 + 白边（白边也进 emission）。"""
	var 活 := 令.有活边 and 令.是活(色本)
	if 活: 宽 *= 1.4                                                  # 深蓝芯加粗（白边只占两侧各 0.025 m），远处也看得出是蓝的
	if 发光:
		return (体.replace("{C}", 色(令.色["活边"])).replace("{W}", "%.3f" % (宽 + 0.05)).replace("{A}", "1") if 活 else "") + 体.replace("{C}", 色(色本)).replace("{W}", "%.3f" % 宽).replace("{A}", "1")
	if 活:
		return 体.replace("{C}", 色(令.色["暗"])).replace("{W}", "%.3f" % (宽 + 0.12)).replace("{A}", "0.45") + 体.replace("{C}", 色(令.色["活边"])).replace("{W}", "%.3f" % (宽 + 0.05)).replace("{A}", "1") + 体.replace("{C}", 色(色本)).replace("{W}", "%.3f" % 宽).replace("{A}", "1")
	return 体.replace("{C}", 色(令.色["暗"])).replace("{W}", "%.3f" % (宽 + 0.075)).replace("{A}", "0.55") + 体.replace("{C}", 色(色本)).replace("{W}", "%.3f" % 宽).replace("{A}", "1")

func 纹对(svg_a: String, svg_e: String, px: int) -> Array:
	var out: Array = []
	for t: String in [svg_a, svg_e]:
		var img := Image.new()
		if img.load_svg_from_string(t, 1.0) != OK or img.get_width() != px:
			push_warning("[界面] 地面贴图栅格化失败"); img = Image.create(px, px, false, Image.FORMAT_RGBA8)
		img.generate_mipmaps()
		out.append(ImageTexture.create_from_image(img))
	return out


func 包(px: int, 半: float, 体: String, 发光: bool) -> String:
	"""viewBox 以 m 为单位、中心为原点（−z 朝上＝北）；发光版垫黑底（emission 只看 RGB）。"""
	var bg := '<rect x="%f" y="%f" width="%f" height="%f" fill="#000000"/>' % [-半, -半, 2*半, 2*半] if 发光 else ""
	return '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="%f %f %f %f">%s%s</svg>' % [px, px, -半, -半, 2*半, 2*半, bg, 体]


func 环svg(发光: bool) -> String:
	var 线s := ""
	for b in range(0, 360, 10):
		var a := deg_to_rad(b); var 主 := b % 90 == 0; var 中 := b % 30 == 0
		var r1 := R + (0.42 if 主 else (0.24 if 中 else 0.10))
		var w := 0.06 if 主 else (0.045 if 中 else 0.03)
		线s += '<line x1="%.4f" y1="%.4f" x2="%.4f" y2="%.4f" stroke-width="%.3f"/>' % [sin(a)*R, -cos(a)*R, sin(a)*r1, -cos(a)*r1, w]
	var 圈 := '<circle cx="0" cy="0" r="%.3f" stroke-width="0.045"/>' % R
	var 本 := '<g fill="none" stroke="%s" stroke-linecap="butt">%s%s</g>' % [色(令.色["主"]), 圈, 线s]
	if 发光: return 包(环px(), 尺*0.5, 本, true)
	var 晕 := '<g fill="none" stroke="%s" stroke-opacity="0.55" stroke-linecap="butt">%s%s</g>' % [色(令.色["暗"]), 圈.replace('stroke-width="0.045"', 'stroke-width="0.11"'), 加宽(线s, 0.065)]
	return 包(环px(), 尺*0.5, 晕 + 本, false)


func 加宽(s: String, d: float) -> String:
	"""把 stroke-width="x" 都加上 d（画深色外扩用）。"""
	var re := RegEx.create_from_string('stroke-width="([0-9.]+)"')
	var out := ""; var i := 0
	for m in re.search_all(s):
		out += s.substr(i, m.get_start() - i) + 'stroke-width="%.3f"' % (float(m.get_string(1)) + d); i = m.get_end()
	return out + s.substr(i)


func 角svg(发光: bool) -> String:
	var pts := "0,-0.30 0.30,0.24 -0.30,0.24"                       # 尖朝 −z（贴图上方）＝朝外
	var c: Color = 令.色["活"]                                       # 车标 = 活色
	var 体 := '<polygon points="%s" fill="{C}" fill-opacity="{A}" stroke="{C}" stroke-opacity="{A}" stroke-width="{W}" stroke-linejoin="miter"/>' % pts
	if 令.有活边: return 包(128, 0.4, 边层(体, c, 0.01, 发光), 发光)
	var 本 := '<polygon points="%s" fill="%s"/>' % [pts, 色(c)]
	if 发光: return 包(128, 0.4, 本, true)
	return 包(128, 0.4, '<polygon points="%s" fill="none" stroke="%s" stroke-opacity="0.6" stroke-width="0.07" stroke-linejoin="miter"/>' % [pts, 色(令.色["暗"])] + 本, false)


func 箭svg(发光: bool, 虚: bool, c: Color) -> String:
	"""人字箭头（尖朝 −z），颜色 c 烤进贴图；虚：盲开段（中间断开）。贴图是方的，Decal 的 x / z 尺寸把它拉成 0.8 × 0.5 m。"""
	var d := "M-0.30,0.13 L0,-0.15 L0.30,0.13"
	var da := ' stroke-dasharray="0.16 0.09"' if 虚 else ""
	var 体 := '<path d="%s" fill="none" stroke="{C}" stroke-opacity="{A}" stroke-width="{W}" stroke-linecap="butt" stroke-linejoin="miter"%s/>' % [d, da]
	return 包(128, 0.4, 边层(体, c, 0.075, 发光), 发光)


# ———————————————————— 每帧（界面.gd 调）
func 挪层() -> void:
	"""车的件放到第 20 层（rig_rover 拆出来的新件也要挪；每秒扫一遍）；石块放到第 19 层。"""
	for g in P.get_children():
		if g is MultiMeshInstance3D and String(g.name).begins_with("石块_") and (g as VisualInstance3D).layers != ROCK_LAYER:
			(g as VisualInstance3D).layers = ROCK_LAYER
	var rr: Node3D = P.rover_root
	if rr == null or not is_instance_valid(rr): return
	var n := 0
	for g in rr.find_children("*", "VisualInstance3D", true, false):
		var v := g as VisualInstance3D
		if v.layers != ROVER_LAYER: v.layers = ROVER_LAYER; n += 1
	层件 += n


func 每帧(dt: float, 车: Transform3D, 有车: bool, 航: float, 显环: bool, 环a := 1.0) -> void:
	扫累 += dt
	if 扫累 >= 1.0:
		扫累 = 0.0; 挪层()
		var e: float = P.env.tonemap_exposure if P.get("env") else 1.0
		var k := 曝基/maxf(e, 1e-6)
		if absf(k - 补) > 0.01: 补 = k
	var 显 := 显环 and 有车 and not 隐环
	环.visible = 显 and not 用线环; 角.visible = 显
	if not 显: 环出 = 0.0; return
	var 出时 := 令.时长("环出")                                          # 动效：环从车身往外长（半径 0.35 → 1，淡入），0.6 s；动效关 = 直接到位
	环出 = 1.0 if 出时 <= 0.0 else minf(1.0, 环出 + dt/出时)
	var ek := 令.缓(环出); var 环k := lerpf(0.35, 1.0, ek)
	环.size = Vector3(尺*环k, 环.size.y, 尺*环k)
	环a *= ek
	环.modulate = Color(1, 1, 1, 环a); 环.emission_energy = 亮*补*环a; 角.emission_energy = 亮*补*maxf(环a, 0.7*ek)*(1.6 if 令.有活边 else 1.0)
	var o := 车.origin
	环.global_position = o                                              # 北向固定，不转
	var f := Vector3(sin(航), 0.0, -cos(航))                            # 航：0 = 北、顺时针（rad）
	角.global_transform = Transform3D(Basis(Vector3.UP, -航), o + f*(R + 0.30))


func 摆箭(点: Array) -> void:
	"""点：[[位置 Vector3, 切向 Vector3（水平）, 颜色 Color, 虚 bool, 淡 0–1], …]；多的箭头藏起来。"""
	var n := mini(点.size(), 箭数)
	for i in 箭数:
		var d := 箭[i]
		if i >= n:
			if d.visible: d.visible = false
			continue
		var q: Array = 点[i]
		var t: Vector3 = q[1]
		d.global_transform = Transform3D(Basis(Vector3.UP, atan2(-t.x, -t.z)), q[0])
		var col: Color = q[2]; var 淡: float = q[4]
		d.modulate = Color(1, 1, 1, 淡)                                  # 颜色烤在贴图里（箭纹对）
		d.emission_energy = 亮*补*淡
		var 纹: Array = 箭纹对(col, q[3])
		if d.get_texture(Decal.TEXTURE_ALBEDO) != 纹[0]:
			d.set_texture(Decal.TEXTURE_ALBEDO, 纹[0]); d.set_texture(Decal.TEXTURE_EMISSION, 纹[1])
		d.visible = true
	用箭 = n


func 全藏() -> void:
	环.visible = false; 角.visible = false
	for d in 箭: d.visible = false
	用箭 = 0
