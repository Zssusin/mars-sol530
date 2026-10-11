# 实时车辙：六个轮子每帧印进车周围一张 5 mm 格的车辙图，给地形着色器的 track_tex / track_rect / track_time（同 66_车辆动画.py 的离线车辙）。
#   车辙图是 GPU 上的 SubViewport（RGBA16F，不清屏，只在有新印子的帧画一次）：每个印子是一块 12 cm × 轮宽的四边形，
#   画布着色器按 66 的公式出深度（下陷 5 mm + 48 条略弯的抓地齿 4 mm，齿的相位＝该轮滚过的距离，和轮子转动对得上；轮边改成软肩）。
#   R＝深度 m，G＝0（实时：track_time 设成很大，全显示）。轮子压在石块上（接地高比地面高 3 cm 以上）不印。
#   车离窗口中心超过 半宽 − 3 m 时换窗口：两张图来回用，新窗口先把旧图按整格平移拷过来，窗口外的旧车辙丢掉。
# 参数：--车辙格=0.005（m）、--车辙像素=3072（窗口边长像素；默认 15.4 m 见方，两张共约 150 MB 显存）。
extends Node

const STAMP_SH := """
shader_type canvas_item;
render_mode blend_mix;
void fragment() {                       // UV.x：沿轮向的齿相位（周期数），UV.y：横向 −1…1
	float q = fract(UV.x + 0.25*UV.y*UV.y) - 0.5;
	float e = 1.0 - smoothstep(0.6, 1.0, abs(UV.y));             // 轮边 7 cm 的软肩（硬边在凹凸法线上会出一条亮线）
	COLOR = vec4(0.005 + 0.004*exp(-(q/0.12)*(q/0.12)), 0.0, 0.0, e);   // 按 e 和旧值混合：和旁边的车辙平滑接上
}
"""
const COPY_SH := """
shader_type canvas_item;
uniform sampler2D src : filter_nearest, repeat_disable;
void fragment() { COLOR = texture(src, UV); }
"""
const PATCH := 0.06                     # 印子沿轮向半长 m
const STEP := 0.03                      # 一帧走得多时按 3 cm 插值补印
const N_GROUSER := 48

var cs := 0.005
var N := 3072
var sv: Array[SubViewport] = []
var ink: Array[Node2D] = []             # 每张图一个：画印子
var cp: Array[Node2D] = []              # 每张图一个：换窗口时拷旧图
var act := 0
var ctr := Vector2i()                    # 窗口中心（格号，x 东、z 南）
var quads: Array = []                    # 本帧要画的印子 [PackedVector2Array 四角, PackedVector2Array UV]
var prev: Array = []                     # 各轮上一次印的 [接地点, 滚过距离, 轮向角]
var C: Node
var period := 0.0
var n_stamp := 0
var n_move := 0


func _ready() -> void:
	C = get_parent()
	cs = float(C.P.args.get("车辙格", "0.005")); N = int(C.P.args.get("车辙像素", "3072"))
	period = TAU*C.r/N_GROUSER
	var ssh := Shader.new(); ssh.code = STAMP_SH; var sm := ShaderMaterial.new(); sm.shader = ssh
	var csh := Shader.new(); csh.code = COPY_SH
	for k in 2:
		var v := SubViewport.new(); v.size = Vector2i(N, N); v.disable_3d = true; v.use_hdr_2d = true; v.transparent_bg = true
		v.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE; v.render_target_update_mode = SubViewport.UPDATE_ONCE
		v.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
		add_child(v); sv.append(v)
		var c := Node2D.new(); var cm := ShaderMaterial.new(); cm.shader = csh; c.material = cm; c.visible = false; v.add_child(c); cp.append(c)
		c.draw.connect(func():
			var o: Vector2 = c.get_meta("o", Vector2.ZERO)
			c.draw_polygon(PackedVector2Array([o, o + Vector2(N, 0), o + Vector2(N, N), o + Vector2(0, N)]), PackedColorArray([Color.WHITE]),
				PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])))
		var n := Node2D.new(); n.material = sm; v.add_child(n); ink.append(n)
		n.draw.connect(draw_quads.bind(n))
	var mat: ShaderMaterial = C.P.ground_mat
	mat.set_shader_parameter("track_time", 1.0e6)
	reset()


func reset() -> void:
	"""清空车辙、窗口放到车上（传送 / 复位时）。"""
	prev.clear()
	center_on(C.p, true)


func center_on(pos: Vector3, clear: bool) -> void:
	var nc := Vector2i(roundi(pos.x/cs), roundi(pos.z/cs))
	var mat: ShaderMaterial = C.P.ground_mat
	if clear:
		sv[act].render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE; sv[act].render_target_update_mode = SubViewport.UPDATE_ONCE
	else:                                                              # 换到另一张：先清空，再把旧图平移拷过来
		var nb := 1 - act
		var off := Vector2(ctr - nc)                                    # 旧图左上角在新图里的像素位置（列＝东，行＝南）
		cp[nb].set_meta("o", off); (cp[nb].material as ShaderMaterial).set_shader_parameter("src", sv[act].get_texture())
		cp[nb].visible = true; cp[nb].queue_redraw()
		if not RenderingServer.frame_post_draw.is_connected(hide_copy): RenderingServer.frame_post_draw.connect(hide_copy, CONNECT_ONE_SHOT)
		sv[nb].render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE; sv[nb].render_target_update_mode = SubViewport.UPDATE_ONCE
		act = nb; n_move += 1
	ctr = nc
	var h := N*cs*0.5; var cx := ctr.x*cs; var cz := ctr.y*cs
	mat.set_shader_parameter("track_tex", sv[act].get_texture())
	mat.set_shader_parameter("track_rect", Vector4(cx - h, -cz - h, cx + h, -cz + h))   # E0, N0, E1, N1


func hide_copy() -> void:
	"""拷贝画完（这一帧渲染后）就藏起来，之后只画印子。"""
	for k in 2: cp[k].visible = false


func stamp(c: Node) -> void:
	"""每帧由 控制.gd 调：六个轮子从上一次印的位置到现在，按 3 cm 一步补印。"""
	if c.last_c.size() != 6: return
	var h := N*cs*0.5 - 3.0
	if absf(c.p.x - ctr.x*cs) > h or absf(c.p.z - ctr.y*cs) > h: center_on(c.p, false)
	if prev.size() != 6:
		prev.clear()
		for i in 6: prev.append([c.last_c[i], c.spin[i]*c.r, c.psi - c.steer[i]])
		return
	for i in 6:
		var pt: Vector3 = c.last_c[i]; var s: float = c.spin[i]*c.r; var a: float = c.psi - c.steer[i]   # 轮向角（同 ψ 的约定）
		var q: Array = prev[i]
		var d: float = (pt - q[0]).length()
		if d < 0.002 and absf(s - q[1]) < 0.002: continue
		if c.hc[i] < c.ground(pt.x, pt.z) + 0.03:                       # 压在石块上不印
			var n := maxi(1, ceili(maxf(d, absf(s - q[1]))/STEP))
			for j in range(1, n + 1):
				var u := float(j)/n
				add_quad(q[0].lerp(pt, u), lerpf(q[1], s, u), lerp_angle(q[2], a, u))
		prev[i] = [pt, s, a]
	if quads.is_empty(): return
	ink[act].queue_redraw()
	sv[act].render_target_update_mode = SubViewport.UPDATE_ONCE


func add_quad(pt: Vector3, s: float, a: float) -> void:
	var hw := Vector2(cos(a), sin(a)); var lw := Vector2(sin(a), -cos(a))       # (x, z)：前、左
	var o := Vector2(pt.x/cs - ctr.x + N*0.5, pt.z/cs - ctr.y + N*0.5)
	var hw_p := hw*(PATCH/cs); var lw_p: Vector2 = lw*(C.HALF_W/cs)
	var ph := fposmod(s/period, 1.0); var du := PATCH/period
	quads.append([PackedVector2Array([o - hw_p - lw_p, o + hw_p - lw_p, o + hw_p + lw_p, o - hw_p + lw_p]),
		PackedVector2Array([Vector2(ph - du, -1), Vector2(ph + du, -1), Vector2(ph + du, 1), Vector2(ph - du, 1)])])
	n_stamp += 1


func draw_quads(n: Node2D) -> void:
	var white := PackedColorArray([Color.WHITE])
	for qd in quads: n.draw_polygon(qd[0], white, qd[1])
	quads.clear()


func info() -> String:
	"""自测用：读回当前车辙图，量深度范围（慢，只在自测里用）。"""
	var img := sv[act].get_texture().get_image()
	var used := img.get_used_rect()
	if used.size.x == 0: return "空（印 %d 块）" % n_stamp
	var sub := img.get_region(used)
	var sc := maxf(1.0, maxf(used.size.x, used.size.y)/400.0)
	sub.resize(int(used.size.x/sc), int(used.size.y/sc), Image.INTERPOLATE_NEAREST)
	var mx := 0.0; var mn := 1e9; var cnt := 0
	for y in sub.get_height():
		for x in sub.get_width():
			var r := sub.get_pixel(x, y).r
			if r > 1e-5: mx = maxf(mx, r); mn = minf(mn, r); cnt += 1
	return "窗口 %.1f m（%d²，%.0f mm），换窗口 %d 次，印 %d 块；格式 %d，压到范围 %s 像素，深度 %.4f–%.4f m（%d 个取样）" % [
		N*cs, N, cs*1000.0, n_move, n_stamp, img.get_format(), used.size, mn, mx, cnt]
