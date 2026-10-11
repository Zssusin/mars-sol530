# 天气模块（实景.gd 实时模式自动加载：load().new() → add_child；父节点 = 实景根）。说明见同目录 说明.md。
#   尘埃光学厚度 τ 预设（天空整套换：61 --天气天空 生成的 sky_tau，多次散射按蒙特卡洛参照定标）、
#   尘卷风（GPU 粒子涡柱 + 地面暗痕 dd_tex）、近地扬尘（跃移沙流 + 尘絮，过起沙阈值才有）、按全天照度的自动曝光。
# 键：N / Shift+N 换 τ，U / Shift+U 风速，B 尘卷风开关，J 扬尘开关，K 眼前放一个尘卷风，G 自动曝光开关。
# 参数：--天气=τ --风速=m/s --风向=吹向°（0 = 北，顺时针） --尘卷风=0 --扬尘=0 --尘卷风倍率=1 --尘痕增益=0.02 --尘痕全=1
#       --天气曝光=0 --天气演示=N（开场在视野里放 N 个） --天气截图=路径.png [--天气截图帧=300]（存图后退出）
extends Node

# —— 文献数（出处见 说明.md）
const DD_RATE := 2.5            # 尘卷风 个 / km² / sol：Hueso 等 2023（2.0–3.0）、Toledo 等 2023（1.3–3.4）
const DD_PEAK_H := 12.5         # 峰值 12:00–13:00 LTST（Toledo 2023；Newman 2022）
const DD_SIGMA_H := 1.4         # 日变化宽度（h）：Newman 2022 每 sol > 4 个、峰值时段 > 1.15 个/h → 有效宽 3.5 h = σ√(2π)
const DD_D_MED := 25.0          # 直径中位 25 m、均值 29 m、5.6–132 m（Toledo 2023）；Hueso 2023 均值 20 m、5–135 m
const DD_D_SIG := 0.7           # 对数正态 σ：中位 25 → 均值 32、>100 m 占 2.4%（Hueso 2023：>100 m 的 0.1 个/km²/sol ≈ 4%）
const DD_H_MED := 230.0         # 高：Toledo 2023 最小高度均值 231 m、最大 872 m
const DD_LIFE := 360.0          # 寿命 6 min（Newman 2022 估算用的值）
const DD_TRACK_P := 0.14        # 留下轨道上可见暗痕的比例（Cantor 等 2006，经 Dundas 等 2021 引）
const DD_GAIN := 0.02           # 暗痕反照率降幅：Vicente-Retortillo 等 2023 —— 尘卷风引起的反照率变化比尘暴的 17% 小一个量级
const DD_TAU := 0.15            # 横穿涡柱底部的光学厚度（估计值，无文献；见 说明.md：尘载 1e-6–1e-4 kg/m³ 对应 0.01–1）
const W_UP := 5.0               # 涡柱上升速度（m/s，假设）：决定倾斜 = 风切变 / 上升速度
const SHEAR := 0.5              # 100 m 处风比 1.5 m 处大 ~50%（Newman 2022，MarsWRF）
const U_T := 15.0               # 起尘 / 起沙阈值（1.5 m 高 ~15 m/s：Newman 2022；Bickel 等 2025）
const U_REF := 22.0             # 扬尘强度 1：sol 313 尘暴峰值风 22 m/s、周围波纹西移（Lemmon 等 2022）
const GUST := 0.4               # 阵风幅度（假设）
const WIND_AZ := 276.0          # 风吹向：Newman 2022 首 216 sol 净输沙方向 276°（白天东南偏东风）
const TAUS: Array[String] = ["0.3", "0.67", "1.5", "3", "5"]
const WIND_OF_TAU := {"0.3": 4.0, "0.67": 4.0, "1.5": 8.0, "3": 12.0, "5": 15.0}   # 白天均值 ~4 m/s（Newman 2022）；尘暴前 4–8、尘暴 10 + 阵风 >20（Lemmon 2022）
const WINDS: Array[float] = [4.0, 8.0, 12.0, 15.0, 20.0, 25.0]
const MARS_HOUR := 3699.0       # 1 火星时（s）
const A_NORM := 0.07            # 尘团不透明度归一：横穿底部的视线上累积的 Σα ≈ τ_D（截图实测定标，见 说明.md）
const R_MIN := 100.0
const R_MAX := 3000.0
const MAX_DEVILS := 8
const DD_N := 1024              # 暗痕窗口：1024² × 1 m，跟着相机，离中心 > 256 m 重画
const DD_RES := 1.0
const HM_N := 17                # 扬尘用的地面高：17² × 4 m
const HM_CELL := 4.0
const DRIFT_N := 1600
const DRIFT_BOX := 60.0

var P: Node3D
var sets := {}
var keys_of := {}
var taus: Array[String] = []
var tau_key := "0.67"
var exp_base := 1.0
var exp_auto := true
var exp_now := -1.0
var wind_over := -1.0
var wind_az := WIND_AZ
var devils_on := true
var drift_on := true
var rate_mul := 1.0
var dd_gain := DD_GAIN
var track_all := false
var devils: Array[Dictionary] = []
var quad: QuadMesh
var devil_draw: ShaderMaterial
var drift_draw: ShaderMaterial
var drift_proc: ShaderMaterial
var drift: GPUParticles3D
var dd_img: Image
var dd_tex: ImageTexture
var dd_c := Vector2(INF, INF)
var dd_stamps: Array[Vector4] = []
var dd_dirty := false
var dd_t := 0.0
var hm_img: Image
var hm_tex: ImageTexture
var hm_c := Vector2(INF, INF)
var sky_seen: Texture2D = null
var L_amb := Vector3.ZERO
var shot := ""
var shot_n := 300
var frame := 0
var toast: Label
var toast_t := 0.0
var rng := RandomNumberGenerator.new()
var spawned := 0
var dens_mul := 1.0


func _ready() -> void:
	P = get_parent()
	var a: Dictionary = P.args
	if a.get("天气模块", "1") == "0":                                   # 测帧对照：模块整个不要
		set_process(false); set_process_unhandled_input(false); queue_free(); return
	sets["0.67"] = {"sky": P.J["sky"], "beta": float(P.J["beta_ap"])}
	if P.J.has("sky_tau"):
		for k in P.J["sky_tau"]:
			sets[k] = {"sky": P.J["sky_tau"][k], "beta": float(P.J["beta_ap_tau"][k])}
	for k in TAUS:
		if sets.has(k): taus.append(k)
	for k in sets:
		var ks: Array = sets[k]["sky"].keys()
		ks.sort_custom(func(x, y): return P.minutes(x) < P.minutes(y))
		keys_of[k] = ks
	exp_base = P.expo_base                                            # 全日天空：不含自动曝光的那份（P.expo_mul 另乘）
	exp_auto = a.get("天气曝光", "1") == "1"
	devils_on = a.get("尘卷风", "1") == "1"
	drift_on = a.get("扬尘", "1") == "1"
	rate_mul = float(a.get("尘卷风倍率", "1"))
	dd_gain = float(a.get("尘痕增益", str(DD_GAIN)))
	track_all = a.get("尘痕全", "0") == "1"
	dens_mul = float(a.get("尘卷风浓度", "1"))
	if a.has("风速"): wind_over = float(a["风速"])
	if a.has("风向"): wind_az = float(a["风向"])
	shot = a.get("天气截图", ""); shot_n = int(a.get("天气截图帧", "300"))
	rng.seed = int(a.get("天气种子", "530"))
	build()
	if a.has("天气"): set_tau(nearest_tau(float(a["天气"])), false)
	print("[天气] τ 预设 %s，当前 %s；风 %.0f m/s 吹向 %.0f°" % [str(taus), tau_key, wind(), wind_az])


func nearest_tau(t: float) -> String:
	var best := tau_key; var bd := INF
	for k in taus:
		var d := absf(log(float(k)) - log(maxf(t, 1e-3)))
		if d < bd: bd = d; best = k
	return best


func wind() -> float:
	return wind_over if wind_over >= 0.0 else float(WIND_OF_TAU.get(tau_key, 4.0))


func wdir() -> Vector3:
	var az := deg_to_rad(wind_az)
	return Vector3(sin(az), 0.0, -cos(az))                            # ENU (sin, cos) → Godot (E, 0, −N)


# ———————————————————— 搭建
func build() -> void:
	var nt := NoiseTexture2D.new(); var fn := FastNoiseLite.new()
	fn.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH; fn.frequency = 0.02; fn.fractal_octaves = 4
	nt.noise = fn; nt.width = 256; nt.height = 256; nt.seamless = true; nt.generate_mipmaps = true
	quad = QuadMesh.new(); quad.size = Vector2(2, 2)
	devil_draw = ShaderMaterial.new(); devil_draw.shader = load("res://天气/尘团.gdshader")
	devil_draw.set_shader_parameter("noise_tex", nt)
	devil_draw.set_shader_parameter("dbg", int(P.args.get("天气诊断", "0")))
	quad.material = devil_draw
	drift_draw = ShaderMaterial.new(); drift_draw.shader = load("res://天气/扬尘.gdshader")
	drift_draw.set_shader_parameter("noise_tex", nt)
	var q2 := QuadMesh.new(); q2.size = Vector2(2, 2); q2.material = drift_draw
	drift_proc = ShaderMaterial.new(); drift_proc.shader = load("res://天气/扬尘_粒子.gdshader")
	for kv in [["Ut", U_T], ["Uref", U_REF], ["G", GUST], ["box", DRIFT_BOX]]: drift_proc.set_shader_parameter(kv[0], kv[1])
	hm_img = Image.create(HM_N, HM_N, false, Image.FORMAT_RF); hm_tex = ImageTexture.create_from_image(hm_img)
	drift_proc.set_shader_parameter("hm_tex", hm_tex)
	drift = GPUParticles3D.new(); drift.name = "扬尘"
	drift.amount = DRIFT_N; drift.lifetime = 40.0; drift.randomness = 1.0; drift.local_coords = false
	drift.process_material = drift_proc; drift.draw_pass_1 = q2
	drift.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	drift.visibility_aabb = AABB(Vector3(-DRIFT_BOX, -60, -DRIFT_BOX), Vector3(2*DRIFT_BOX, 120, 2*DRIFT_BOX))
	drift.emitting = false; drift.visible = false
	add_child(drift)
	dd_img = Image.create(DD_N, DD_N, false, Image.FORMAT_R8); dd_tex = ImageTexture.create_from_image(dd_img)
	var cl := CanvasLayer.new(); cl.layer = 20; add_child(cl)
	toast = Label.new(); toast.position = Vector2(24, 24); toast.modulate.a = 0.0
	toast.add_theme_font_size_override("font_size", 22); toast.add_theme_color_override("font_outline_color", Color.BLACK)
	toast.add_theme_constant_override("outline_size", 6); cl.add_child(toast)


func say(s: String) -> void:
	print("[天气] ", s)
	if shot != "": return
	toast.text = s; toast_t = 3.0


func set_tau(k: String, show := true) -> void:
	if not sets.has(k): return
	tau_key = k
	var s: Dictionary = sets[k]
	P.set_sky_set(s["sky"], s["beta"])
	exp_now = -1.0
	if show: say("尘埃光学厚度 τ = %s（风 %.0f m/s）" % [k, wind()])


# ———————————————————— 每帧
func _process(dt: float) -> void:
	frame += 1
	var cam := get_viewport().get_camera_3d()
	if cam == null: return
	var cp := cam.global_position
	update_light()
	update_devils(dt, cp)
	update_drift(cp)
	dd_t += dt
	if dd_dirty and dd_t > 0.25: dd_tex.update(dd_img); dd_dirty = false; dd_t = 0.0
	if toast_t > 0.0: toast_t -= dt; toast.modulate.a = clampf(toast_t, 0.0, 1.0)
	if frame == 3: begin()
	if shot != "" and frame == shot_n:
		var img := get_viewport().get_texture().get_image()
		DirAccess.make_dir_recursive_absolute(shot.get_base_dir())
		img.save_png(shot); print("[天气] 截图 → ", shot)
		get_tree().quit()


func begin() -> void:
	"""第 3 帧（控制模块已设好相机）：截图藏 HUD、--天气机位、--天气演示。"""
	if shot != "" and P.has_node("界面"):                                          # 截图不要 HUD
		var ui: Node = P.get_node("界面")
		if ui is CanvasItem or ui is CanvasLayer: ui.visible = false
		for c in ui.find_children("*", "CanvasLayer", true, false): c.visible = false
		for c in ui.get_children(): if c is CanvasItem: c.visible = false
	if P.args.has("天气机位"):                                      # E,N,朝向°,俯仰°[,离地高 m]
		var q: PackedStringArray = String(P.args["天气机位"]).split(",")
		var E := float(q[0]); var Nn := float(q[1]); var az := deg_to_rad(float(q[2])); var pt := deg_to_rad(float(q[3]))
		var hh := float(q[4]) if q.size() > 4 else 1.6
		var pos := Vector3(E, ground_y(E, -Nn) + hh, -Nn)
		var f := Vector3(sin(az)*cos(pt), sin(pt), -cos(az)*cos(pt))
		P.fly.global_transform = Transform3D.IDENTITY.translated(pos).looking_at(pos + f, Vector3.UP)
		P.fly.current = true
	if P.args.has("天气演示"):
		for i in int(P.args["天气演示"]): spawn_demo(i)


func cur(k: String) -> Dictionary:
	"""该 τ 在当前时刻的 T、E_sun_h、E_sky（相邻两张天空线性插值，同 实景.set_time_f）。"""
	var S: Dictionary = sets[k]["sky"]; var ks: Array = keys_of[k]
	var m: float = P.time_m
	var i := 0
	while i < ks.size() - 2 and P.minutes(ks[i + 1]) <= m: i += 1
	var A: Dictionary = S[ks[i]]; var B: Dictionary = S[ks[mini(i + 1, ks.size() - 1)]]
	var den: float = P.minutes(ks[mini(i + 1, ks.size() - 1)]) - P.minutes(ks[i])
	var u := clampf((m - P.minutes(ks[i]))/den, 0.0, 1.0) if den > 0.0 else 0.0
	var T := Vector3(lerpf(A["T"][0], B["T"][0], u), lerpf(A["T"][1], B["T"][1], u), lerpf(A["T"][2], B["T"][2], u))
	return {"T": T, "E_sun_h": lerpf(A["E_sun_h"], B["E_sun_h"], u), "E_sky": lerpf(A["E_sky"], B["E_sky"], u)}


func update_light() -> void:
	var E_TOP: float = P.J["E_TOP"]
	var tex: Texture2D = P.sky_mat.get_shader_parameter("sky_tex")
	if tex != sky_seen and tex != null:
		sky_seen = tex; L_amb = sphere_mean(tex.get_image())*E_TOP
	var c := cur(tau_key)
	var Tv: Vector3 = c["T"]
	var sd: Vector3 = (P.sun.global_transform.basis.z as Vector3).normalized()
	for m in [devil_draw, drift_draw]:
		m.set_shader_parameter("sky_tex", sky_seen); m.set_shader_parameter("E_TOP", E_TOP)
		m.set_shader_parameter("beta_ap", sets[tau_key]["beta"]); m.set_shader_parameter("sun_dir", sd)
		m.set_shader_parameter("E_sun", Tv*E_TOP); m.set_shader_parameter("L_amb", L_amb)
	var e: float = exp_base*P.expo_mul
	if exp_auto and tau_key != "0.67":                                # 自动曝光：按全天水平照度（直射 + 天光）补到 τ 0.67 同一时刻的水平
		var b := cur("0.67")
		e = exp_base*P.expo_mul*(float(b["E_sun_h"]) + float(b["E_sky"]))/maxf(float(c["E_sun_h"]) + float(c["E_sky"]), 1e-3)
	if absf(e - exp_now) > 1e-4*e:
		exp_now = e; P.env.tonemap_exposure = e


func sphere_mean(img: Image) -> Vector3:
	"""等距圆柱天空图（第 0 行 = 天顶）在整个球面上的平均（按立体角），抽样 64×128。"""
	if img == null: return Vector3.ZERO
	var w := img.get_width(); var h := img.get_height()
	var s := Vector3.ZERO; var ws := 0.0
	for j in 64:
		var y := int((j + 0.5)*h/64.0); var lat := PI*(0.5 - (y + 0.5)/h); var cw := cos(lat)
		for i in 128:
			var c := img.get_pixel(int((i + 0.5)*w/128.0), y)
			s += Vector3(c.r, c.g, c.b)*cw; ws += cw
	return s/ws


# ———————————————————— 尘卷风
func ground_y(x: float, z: float) -> float:
	return P.lod.h_cpu(x, z, 0) if P.lod else 0.0


func randn() -> float:
	return rng.randfn(0.0, 1.0)


func update_devils(dt: float, cp: Vector3) -> void:
	if devils_on and devils.size() < MAX_DEVILS:
		var hr: float = P.time_m/60.0
		var prof := exp(-0.5*pow((hr - DD_PEAK_H)/DD_SIGMA_H, 2.0))/(DD_SIGMA_H*sqrt(TAU))   # 每火星时
		var area := PI*(R_MAX*R_MAX - R_MIN*R_MIN)/1e6
		var lam := DD_RATE*area*prof/MARS_HOUR*rate_mul
		if rng.randf() < lam*dt:
			var r := sqrt(rng.randf_range(R_MIN*R_MIN, R_MAX*R_MAX)); var a := rng.randf()*TAU
			spawn(Vector2(cp.x + r*cos(a), cp.z + r*sin(a)), -1.0, -1.0)
	var keep: Array[Dictionary] = []
	for d in devils:
		var n: GPUParticles3D = d["node"]
		d["age"] += dt
		var age: float = d["age"]; var life: float = d["life"]
		var f := smoothstep(0.0, 20.0, age)*(1.0 - smoothstep(life - 40.0, life, age))
		if not devils_on: f = 0.0
		var p: Vector3 = d["pos"]; var v: Vector3 = d["v"]
		# 路径弯曲：航向绕风向做 Ornstein–Uhlenbeck 随机游走（σ ≈ 20°，回复时间 60 s），轨迹成弧形而不是直线
		var dev: float = d["dev"]
		dev += -dev*dt/60.0 + deg_to_rad(20.0)*sqrt(2.0*dt/60.0)*randn(); d["dev"] = dev
		var ang := deg_to_rad(wind_az) + dev
		v = Vector3(sin(ang), 0.0, -cos(ang))*float(d["spd"]); d["v"] = v
		p += v*dt; p.y = ground_y(p.x, p.z); d["pos"] = p
		n.position = p
		var mat: ShaderMaterial = n.process_material
		mat.set_shader_parameter("fade", f)
		# 近处省叠画：相机离涡轴 < 6D 时少画尘团（amount_ratio），单个尘团加浓补回，总光学厚度不变
		var ratio := clampf(Vector2(p.x - cp.x, p.z - cp.z).length()/(6.0*float(d["D"])), 0.15, 1.0)
		if absf(ratio - n.amount_ratio) > 0.02:
			n.amount_ratio = ratio; mat.set_shader_parameter("a_peak", minf(float(d["a"])/ratio, 0.6))
		if d["track"] and f > 0.5: stamp_track(d, p)
		# 过境声：涡心离相机 < 1.5 D 时触发一次声音模块的尘卷风录音（sol 215），强度按最近距离
		var dc := Vector2(p.x - cp.x, p.z - cp.z).length()
		if f > 0.5 and dc < 1.5*float(d["D"]) and not d.get("heard", false) and P.has_node("声音") and P.get_node("声音").has_method("尘卷风"):
			d["heard"] = true; P.get_node("声音").尘卷风(clampf(float(d["D"])/maxf(dc, 1.0), 0.3, 1.5))
		if age > life or Vector2(p.x - cp.x, p.z - cp.z).length() > R_MAX*1.3:
			n.queue_free()
		else: keep.append(d)
	devils = keep
	if Vector2(cp.x, cp.z).distance_to(dd_c) > DD_N*DD_RES*0.25: recenter_dd(cp)


func spawn(xz: Vector2, D: float, H: float, track := -1, pre := 0.0) -> void:
	if D <= 0.0: D = clampf(DD_D_MED*exp(DD_D_SIG*randn()), 5.0, 135.0)
	if H <= 0.0: H = clampf(DD_H_MED*exp(0.45*randn())*pow(D/DD_D_MED, 0.3), 60.0, 900.0)
	var U := wind()
	var ang := deg_to_rad(wind_az + rng.randf_range(-20.0, 20.0))
	var v := Vector3(sin(ang), 0.0, -cos(ang))*U*rng.randf_range(0.8, 1.2)          # 尘卷风随环境风走（Toledo 2023：移动方向与风一致）
	var lean := wdir()*minf(SHEAR*U/W_UP, 0.8)
	var n := GPUParticles3D.new(); n.name = "尘卷风_%d" % spawned; spawned += 1
	var m := ShaderMaterial.new(); m.shader = load("res://天气/尘卷风_粒子.gdshader")
	var amount := 260
	var ps := maxf(0.5*D, 3.0)
	var frac := pow(minf(2.0*ps/H, 1.0), 1.0/1.3)                                   # 横穿底部的视线会碰到的尘团（底部 2 个尘团高度里的）比例
	var tau_d := minf(DD_TAU*sqrt(D/DD_D_MED), 0.4)*dens_mul
	var a_peak := clampf(tau_d/maxf(1.0, amount*frac*A_NORM), 0.002, 0.5)
	for kv in [["D", D], ["H", H], ["lean", Vector2(lean.x, lean.z)], ["vt", 15.0], ["psize", ps],
			["a_peak", a_peak], ["fade", 0.0], ["seedf", rng.randf()*100.0]]:
		m.set_shader_parameter(kv[0], kv[1])
	n.process_material = m; n.draw_pass_1 = quad
	n.amount = amount; n.lifetime = H/W_UP; n.local_coords = true; n.randomness = 0.0
	n.preprocess = pre; n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var R := D*2.5 + absf(lean.length())*H + D*0.35
	n.visibility_aabb = AABB(Vector3(-R, -10.0, -R), Vector3(2*R, H + 2*ps + 20.0, 2*R))
	var p := Vector3(xz.x, ground_y(xz.x, xz.y), xz.y)
	n.position = p; add_child(n)
	var tr := (rng.randf() < DD_TRACK_P or track_all) if track < 0 else track == 1
	devils.append({"node": n, "pos": p, "v": v, "age": 0.0, "life": clampf(DD_LIFE*exp(0.5*randn()), 90.0, 1200.0),
		"D": D, "H": H, "track": tr, "last": Vector2(INF, INF), "s": rng.randf_range(0.6, 1.0),
		"dev": ang - deg_to_rad(wind_az), "spd": v.length(), "dist": 0.0, "a": a_peak})
	print("[天气] 尘卷风 #%d：E %.0f N %.0f，D %.0f m，H %.0f m，风 %.1f m/s，暗痕 %s" % [spawned, p.x, -p.z, D, H, v.length(), str(tr)])


func spawn_demo(i: int) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null: return
	var f := -cam.global_transform.basis.z; f.y = 0.0; f = f.normalized()
	var r := f.cross(Vector3.UP)
	var dist: float = [180.0, 450.0, 900.0, 1500.0][i % 4]*float(P.args.get("天气演示距", "1"))
	var off: float = [0.0, -0.35, 0.3, -0.15][i % 4]
	var c := cam.global_position + (f + r*off).normalized()*dist
	var H: float = [320.0, 250.0, 600.0, 200.0][i % 4]
	spawn(Vector2(c.x, c.z), [45.0, 30.0, 80.0, 25.0][i % 4], H, 1, H/W_UP)              # 预跑一整个上升周期：马上是完整的柱
	devils[-1]["age"] = 25.0                                            # 跳过渐显


# ———————————————————— 暗痕（ground_mat 的 dd_tex / dd_rect / dd_gain）
func stamp_track(d: Dictionary, p: Vector3) -> void:
	var w := maxf(0.25*float(d["D"]), 1.0)                              # 痕宽取直径的一半（无文献比例；轨道上看到的痕宽几米到几十米）
	var q := Vector2(p.x, p.z)
	var step := q.distance_to(d["last"])
	if step < 0.5*w: return
	d["last"] = q
	if step < 4.0*w: d["dist"] += step
	var L: float = d["dist"]
	var s := Vector4(p.x, p.z, w*(0.85 + 0.15*sin(L/23.0)), float(d["s"])*(0.75 + 0.25*sin(L/41.0 + float(d["D"]))))   # 抬尘强弱沿途起伏
	dd_stamps.append(s)
	if dd_stamps.size() > 40000: dd_stamps = dd_stamps.slice(10000)
	if dd_c.x != INF: raster(s); dd_dirty = true


func raster(s: Vector4) -> void:
	var half := DD_N*DD_RES*0.5
	var cx := (s.x - (dd_c.x - half))/DD_RES; var cy := (s.y - (dd_c.y - half))/DD_RES    # v = (N1 − N)/(N1 − N0) = (z − z0)/size
	var r := s.z/DD_RES
	var x0 := maxi(int(cx - r), 0); var x1 := mini(int(cx + r) + 1, DD_N - 1)
	var y0 := maxi(int(cy - r), 0); var y1 := mini(int(cy + r) + 1, DD_N - 1)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var t := Vector2(x + 0.5 - cx, y + 0.5 - cy).length()/r
			if t >= 1.0: continue
			var val := s.w*(1.0 - smoothstep(0.5, 1.0, t))
			if val > dd_img.get_pixel(x, y).r: dd_img.set_pixel(x, y, Color(val, 0, 0))


func recenter_dd(cp: Vector3) -> void:
	dd_c = Vector2(snappedf(cp.x, 16.0), snappedf(cp.z, 16.0))
	dd_img.fill(Color(0, 0, 0))
	var half := DD_N*DD_RES*0.5
	for s in dd_stamps:
		if absf(s.x - dd_c.x) < half + s.z and absf(s.y - dd_c.y) < half + s.z: raster(s)
	dd_tex.update(dd_img); dd_dirty = false
	var gm: ShaderMaterial = P.ground_mat
	gm.set_shader_parameter("dd_tex", dd_tex)
	gm.set_shader_parameter("dd_gain", dd_gain)
	# ENU：E = x，N = −z
	gm.set_shader_parameter("dd_rect", Vector4(dd_c.x - half, -dd_c.y - half, dd_c.x + half, -dd_c.y + half))


# ———————————————————— 近地扬尘
func update_drift(cp: Vector3) -> void:
	var U := wind()
	var on := drift_on and U*(1.0 + GUST) > U_T                          # 最强阵风都过不了阈值：整个关掉（不花 GPU）
	if on != drift.emitting: drift.emitting = on; drift.visible = on
	if not on: return
	if Vector2(cp.x, cp.z).distance_to(hm_c) > 8.0:
		hm_c = Vector2(snappedf(cp.x, 4.0), snappedf(cp.z, 4.0))
		var x0 := hm_c.x - (HM_N - 1)*0.5*HM_CELL; var z0 := hm_c.y - (HM_N - 1)*0.5*HM_CELL
		for j in HM_N:
			for i in HM_N: hm_img.set_pixel(i, j, Color(ground_y(x0 + i*HM_CELL, z0 + j*HM_CELL), 0, 0))
		hm_tex.update(hm_img)
		drift_proc.set_shader_parameter("hm_rect", Vector4(x0 - 0.5*HM_CELL, z0 - 0.5*HM_CELL, HM_N*HM_CELL, 0.0))
	var gy := ground_y(cp.x, cp.z)
	drift.position = Vector3(cp.x, gy, cp.z)
	drift_proc.set_shader_parameter("center", Vector3(cp.x, gy, cp.z))
	drift_proc.set_shader_parameter("wdir", wdir()); drift_proc.set_shader_parameter("U", U)
	drift_draw.set_shader_parameter("wdir", wdir())


# ———————————————————— 键
func _unhandled_input(ev: InputEvent) -> void:
	if not (ev is InputEventKey and ev.pressed and not ev.echo): return
	match ev.keycode:
		KEY_N:
			var i := taus.find(tau_key)
			set_tau(taus[posmod(i + (-1 if ev.shift_pressed else 1), taus.size())])
		KEY_U:
			if ev.shift_pressed: wind_over = -1.0
			else:
				var i := WINDS.find(wind_over)
				wind_over = WINDS[(i + 1) % WINDS.size()]
			say("风 %.0f m/s 吹向 %.0f°%s" % [wind(), wind_az, "（随 τ 预设）" if wind_over < 0.0 else ""])
		KEY_B:
			devils_on = not devils_on; say("尘卷风 " + ("开" if devils_on else "关"))
		KEY_J:
			drift_on = not drift_on; say("扬尘 " + ("开" if drift_on else "关") + ("" if wind()*(1.0 + GUST) > U_T else "（风 < 起沙阈值，看不到）"))
		KEY_Y:                                                          # K 归声音模块（静音）
			spawn_demo(0); say("眼前放了一个尘卷风")
		KEY_G:
			exp_auto = not exp_auto; exp_now = -1.0; say("自动曝光 " + ("开" if exp_auto else "关（物理固定曝光）"))
		_: return
	get_viewport().set_input_as_handled()


func _exit_tree() -> void:
	for d in devils: (d["node"] as Node).free()
	devils.clear(); dd_stamps.clear()


func 状态() -> Dictionary:
	return {"τ": float(tau_key), "风速_mps": wind(), "风向_deg": wind_az, "尘卷风": devils.size(), "尘卷风开": devils_on,
		"扬尘开": drift_on, "曝光": exp_now, "暗痕": dd_stamps.size()}
