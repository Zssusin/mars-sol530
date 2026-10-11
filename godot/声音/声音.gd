# 声音：火星环境声 + 毅力号行驶声。实景.gd 实时模式下自动加载成子节点「声音」（--声音=0 不加载内容；--模块=0 整体不加载）。
#   素材全部来自 PDS（公有领域）：SuperCam 麦克风大气录音（风）、EDL 麦克风 sol 16 行驶录音（车）；热泵单频按录音实测频率合成。见 声音/来源.md。
#   声学：火星传播按 Maurice et al. 2022（Nature 605:653）实测衰减系数 α(f) 做距离相关的频响（EQ10 每段一个增益）+ 1/r 球面扩散。见 声音/说明.md。
#   听者＝当前相机（桅杆模式＝桅杆头上的 SuperCam 麦克风）；声源：车轮（行驶）、车体（热泵）；风是麦克风处的局部湍流，不定位。
# 键：K 静音 / 取消。参数：--声音=0 关、--声音增益=dB、--声音风速=m/s（固定风速，覆盖天气/时刻）、--声音录制=路径.wav（录下本模块总线输出，退出时保存）、
#     --声音测试（自动开车、换机位、录 40 s、写 wav + json 后退出；见 声音/自测.gd、声音/测试.sh）。
# 天气钩子（可选，有就跟）：天气节点的 状态() 字典或属性里的 风速_mps / 风速 / τ；天气也可以调 声音.尘卷风(强度)。
extends Node

const D := "res://声音/素材/"
const P_REF := 0.1                    # 输出 0 dBFS 对应的声压 Pa（74 dB SPL）：各层按 素材.json 的「满幅_Pa」还原物理相对响度
const V_REAL := 0.042                 # 真车直行 m/s（同 控制.gd）
const U_REF := 5.0                    # 「风_湍流」那段（sol 148 正午）当作的参考风速 m/s —— 假设，见 说明.md
const R0_DRIVE := 1.0                 # EDL 麦克风（左舷、离地 1 m）到车轮接地处的距离 m
const DRIVE_DB := 0.0                 # 行驶声在 R0 处的设计电平（EDL 未标定，相对响度是设计值）
const EQ_F := [31.0, 62.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0]

var P: Node
var C: Node = null                    # 控制
var meta := {}
var on := true
var gain_db := 0.0
var bus_all := -1; var bus_wind := -1; var bus_car := -1; var bus_pump := -1
var eq_car: AudioEffectEQ10; var eq_pump: AudioEffectEQ10
var pan_car: AudioEffectPanner; var pan_pump: AudioEffectPanner
var rec: AudioEffectRecord = null
var rec_path := ""
var calm: AudioStreamPlayer; var gust: AudioStreamPlayer; var devil: AudioStreamPlayer
var drive: AudioStreamPlayer; var pump: AudioStreamPlayer
var t := 0.0                          # 墙钟秒（从模块就绪起；录音也从那时开始，日志按它对齐）
var t_start := 0
var first := true
var t_off := randf()*600.0             # 慢变调制的随机相位
var drive_g := 0.0                    # 平滑后的行驶强度 0…1.5
var last_head := INF
var wx := {}                          # 天气读数
var wx_t := 0.0
var u_fixed := -1.0
var devil_cd := 120.0
var cpu_ms := 0.0
var dbg := {}                         # 给自测 / 录制记录用的当前量


func _ready() -> void:
	P = get_parent()
	if String(P.args.get("声音", "1")) == "0":
		print("[声音] --声音=0：不加载"); set_process(false); set_process_unhandled_input(false); return
	if not FileAccess.file_exists(D + "素材.json"):
		push_warning("[声音] 缺 素材.json，声音模块不工作"); set_process(false); return
	meta = JSON.parse_string(FileAccess.get_file_as_string(D + "素材.json"))
	gain_db = float(P.args.get("声音增益", "0"))
	u_fixed = float(P.args.get("声音风速", "-1"))
	C = P.get_node_or_null("控制")
	t_start = Time.get_ticks_usec()
	build_buses()
	calm = player("风_平静", bus_wind, true)
	gust = player("风_湍流", bus_wind, true)
	devil = player("尘卷风", bus_wind, false)
	drive = player("行驶", bus_car, true)
	pump = player("热泵", bus_pump, true)
	for p in [calm, gust, drive, pump]:
		p.volume_db = -80.0
		p.play(randf()*maxf(p.stream.get_length() - 1.0, 0.0))     # 各层从随机位置开始，免得每次一样
	if P.args.has("声音录制"):
		rec_path = String(P.args["声音录制"])
		rec = AudioEffectRecord.new(); rec.format = AudioStreamWAV.FORMAT_16_BITS
		AudioServer.add_bus_effect(bus_all, rec); rec.set_recording_active(true)
	if P.args.has("声音测试"):
		var tst: Node = load("res://声音/自测.gd").new(); tst.name = "自测"; add_child(tst)
	print("[声音] 好了：%d 层，键 K 静音；驱动 %s，混音 %d Hz%s" % [5, AudioServer.get_driver_name() if AudioServer.has_method("get_driver_name") else "?",
		int(AudioServer.get_mix_rate()), "，录制到 " + rec_path if rec else ""])


func build_buses() -> void:
	"""总线：声音（限幅、静音、录制）← 声音_风（压缩）、声音_车 / 声音_泵（EQ10 = 火星传播频响、声像）。子总线只能送往排在它前面的总线。"""
	bus_all = new_bus("声音", "Master")
	var lim := AudioEffectHardLimiter.new(); lim.ceiling_db = -1.0
	AudioServer.add_bus_effect(bus_all, lim)
	bus_wind = new_bus("声音_风", "声音")
	var comp := AudioEffectCompressor.new(); comp.threshold = -20.0; comp.ratio = 4.0; comp.attack_us = 20000.0; comp.release_ms = 400.0
	AudioServer.add_bus_effect(bus_wind, comp)                         # 尘卷风比平静高 60 dB 以上：监听用压缩（设计，非物理）
	bus_car = new_bus("声音_车", "声音")
	eq_car = AudioEffectEQ10.new(); pan_car = AudioEffectPanner.new()
	AudioServer.add_bus_effect(bus_car, eq_car); AudioServer.add_bus_effect(bus_car, pan_car)
	bus_pump = new_bus("声音_泵", "声音")
	eq_pump = AudioEffectEQ10.new(); pan_pump = AudioEffectPanner.new()
	AudioServer.add_bus_effect(bus_pump, eq_pump); AudioServer.add_bus_effect(bus_pump, pan_pump)


func new_bus(name: String, send: String) -> int:
	var i := AudioServer.get_bus_index(name)
	if i < 0:
		i = AudioServer.bus_count; AudioServer.add_bus(i); AudioServer.set_bus_name(i, name)
	AudioServer.set_bus_send(i, send)
	return i


func player(name: String, bus: int, looping: bool) -> AudioStreamPlayer:
	var m: Dictionary = meta[name]
	var s: AudioStream = load(D + String(m["文件"]))
	if s is AudioStreamOggVorbis: (s as AudioStreamOggVorbis).loop = looping
	elif s is AudioStreamWAV:
		var w := s as AudioStreamWAV
		if looping:
			w.loop_mode = AudioStreamWAV.LOOP_FORWARD; w.loop_begin = 0; w.loop_end = int(round(float(m["时长_s"])*float(m["采样率"])))
	var p := AudioStreamPlayer.new(); p.name = name; p.stream = s; p.bus = AudioServer.get_bus_name(bus)
	add_child(p)
	return p


func cal_db(name: String) -> float:
	"""素材 1.0 满幅相对 P_REF 的 dB（有标定的层）。"""
	var fs = meta[name].get("满幅_Pa")
	return 20.0*log(float(fs)/P_REF)/log(10.0) if fs != null else 0.0


# ———————————————————— 火星传播
static func alpha(f: float) -> float:
	"""火星近地面声吸收系数（振幅，1/m）：3–6、6–11、11–15 kHz 三段用 Maurice et al. 2022 的原位实测 0.21 / 0.34 / 0.43 m⁻¹
	（取频段几何中心 4.2 / 8.1 / 12.8 kHz），段间按 ln f 线性插值；4.2 kHz 以下用 CO2 振动弛豫的单弛豫形式
	α = α_p·x²/(1+x²)，x = f/240 Hz（弛豫频率 240 Hz 同上文），平台 α_p 取 0.21（论文：<6 kHz 呈平台）。这一段没有原位实测，是近似。"""
	const FR := 240.0
	if f <= 4243.0:
		var x2 := (f/FR)*(f/FR)
		return 0.21*x2/(1.0 + x2)*(1.0 + 1.0/((4243.0/FR)*(4243.0/FR)))   # 在 4.2 kHz 处正好接上 0.21
	if f <= 8124.0: return lerpf(0.21, 0.34, log(f/4243.0)/log(8124.0/4243.0))
	return 0.34 + (0.43 - 0.34)*log(f/8124.0)/log(12845.0/8124.0)


func propagate(eq: AudioEffectEQ10, r: float, r0: float) -> float:
	"""声源距听者 r、素材录音距离 r0：EQ10 各段加 −8.686·α(f)·(r − r0) dB（r < r0 不补回，录音里已有的衰减不还原）；
	返回球面扩散的总增益 dB（−20 lg(r/r0)，r 不小于 0.3 m）。"""
	var dr := maxf(r - r0, 0.0)
	for i in 10: eq.set_band_gain_db(i, maxf(-8.686*alpha(EQ_F[i])*dr, -60.0))
	return -20.0*log(maxf(r, 0.3)/r0)/log(10.0)


# ———————————————————— 每帧
func _process(dt: float) -> void:
	var t0 := Time.get_ticks_usec()
	t = (Time.get_ticks_usec() - t_start)/1e6                       # 墙钟（加载后的第一帧 dt 不含加载耗时，按 dt 累加会和录音错开 ~1.5 s）
	var k0 := 1e-3 if first else 1.0; first = false               # 第一帧环境层直接到位，不从 −80 淡入
	var cam := get_viewport().get_camera_3d()
	var st: Dictionary = C.状态() if C and C.has_method("状态") else {}
	var M: float = float(st.get("倍率", 1.0))
	# — 风：风速 U（天气 > --声音风速 > 按当地时刻的默认），慢变调制，阵风层 ∝ U²
	wx_t -= dt
	if wx_t <= 0.0: wx_t = 0.5; wx = read_weather()
	var u := wind_u()
	var ts := t + t_off
	var slow := 0.5*sin(TAU*ts/97.0) + 0.3*sin(TAU*ts/41.0 + 1.0) + 0.2*sin(TAU*ts/223.0 + 2.0)
	var ue := u*exp(0.35*slow)                                        # 风速 ×0.70…1.42（阵风层 ±6 dB），周期 41–223 s 的慢起伏
	var gust_db := 40.0*log(maxf(ue, 0.05)/U_REF)/log(10.0)           # p' ∝ U²（幂律指数 2 是我们的假设）
	gust_db = minf(gust_db, 12.0)
	set_vol(gust, cal_db("风_湍流") + gust_db + gain_db, dt, 1.5*k0)
	set_vol(calm, cal_db("风_平静") + gain_db, dt, 1.5*k0)
	devil_cd -= dt
	var h := hour()
	if wx.is_empty() and devil_cd <= 0.0 and h > 10.5 and h < 15.0 and u > 3.0 and randf() < dt/300.0:
		尘卷风(1.0)
	# — 车：真车等效轮速（直行 速度_mps；原地转用航向角速度 × 0.9 m），0…1.5
	var spd := absf(float(st.get("速度_mps", 0.0)))
	var head := float(st.get("航向_deg", 0.0))
	if last_head < INF and dt > 0.0:
		var w := deg_to_rad(absf(wrapf(head - last_head, -180.0, 180.0)))/dt/maxf(M, 1.0)
		if absf(float(st.get("转向_deg", 0.0))) < 5.0 and spd < 0.004: spd = maxf(spd, w*0.9)   # 原地转
	last_head = head
	var s := clampf(spd/V_REAL, 0.0, 1.5)
	drive_g = move_toward(drive_g, s, dt*(4.0 if s > drive_g else 2.5))   # 起步 0.25 s、停 0.4 s
	var ld := absf(float(st.get("油门", 0.0)))*0.3 + absf(float(st.get("转向_deg", 0.0)))/39.0*0.4
	ld += maxf(float(st.get("俯仰_deg", 0.0))*signf(float(st.get("速度_mps", 0.0))), 0.0)/15.0
	drive.pitch_scale = clampf((0.9 + 0.1*drive_g)*(1.0 + 0.06*ld)*(1.0 + 0.05*log(maxf(M, 1.0))/log(10.0)), 0.8, 1.25)
	# — 定位：声源（轮子接地、车体热泵）到相机
	var body := Transform3D()
	if C: body = C.body
	elif P.get("rover_root"): body = (P.rover_root as Node3D).global_transform
	var src_car := body*Vector3(0, 0.26, 0)
	var src_pump := body*Vector3(0, 0.8, 0)
	var mast: Vector3 = src_pump + Vector3.UP*1.4
	if C: mast = body*(C.mast_local as Vector3)
	var r0_pump := maxf(mast.distance_to(src_pump), 0.5)                # 热泵电平是在 SuperCam 麦克风（桅杆头）处测的
	var lp := cam.global_position if cam else mast
	var r_car := lp.distance_to(src_car); var r_pump := lp.distance_to(src_pump)
	var g_car := propagate(eq_car, r_car, R0_DRIVE)
	var g_pump := propagate(eq_pump, r_pump, r0_pump)
	pan_car.pan = pan_of(cam, src_car); pan_pump.pan = pan_of(cam, src_pump)
	var dlin := drive_g*(1.0 + 0.4*ld)
	set_vol(drive, DRIVE_DB + g_car + 20.0*log(maxf(dlin, 1e-4))/log(10.0) + gain_db, dt, 0.08)
	set_vol(pump, cal_db("热泵") + g_pump + gain_db, dt, 0.08*k0)
	dbg = {"t": t, "模式": String(st.get("模式", "")), "速度": spd, "s": drive_g, "负载": ld, "r车": r_car, "r泵": r_pump, "风速": u, "阵风dB": gust_db,
		"车dB": drive.volume_db, "风dB": gust.volume_db, "音高": drive.pitch_scale, "声像": pan_car.pan, "倍率": M}
	cpu_ms = (Time.get_ticks_usec() - t0)/1000.0


func set_vol(p: AudioStreamPlayer, db: float, dt: float, tau: float) -> void:
	"""dB 一阶平滑（时间常数 tau 秒），下限 −80。"""
	db = maxf(db, -80.0)
	p.volume_db = lerpf(p.volume_db, db, 1.0 - exp(-dt/tau))


func pan_of(cam: Camera3D, src: Vector3) -> float:
	if cam == null: return 0.0
	var rel: Vector3 = cam.global_transform.affine_inverse()*src
	return clampf(rel.x/maxf(rel.length(), 0.5), -1.0, 1.0)*0.7


func hour() -> float:
	var m = P.get("time_m")
	if m == null or float(m) < 0.0: m = P.minutes(P.ltst) if P.has_method("minutes") else 13.0*60.0
	return float(m)/60.0


func read_weather() -> Dictionary:
	var W := P.get_node_or_null("天气")
	if W == null: return {}
	var d := {}
	if W.has_method("状态"):
		var s = W.call("状态")
		if s is Dictionary: d = s
	for k in ["风速_mps", "风速", "τ", "tau"]:
		if not d.has(k):
			var v = W.get(k)
			if v != null: d[k] = v
	return d


func wind_u() -> float:
	"""风速 m/s：--声音风速 > 天气（风速_mps / 风速）> 默认按当地真太阳时：白天对流湍流在 11–14 时最强、黄昏消失（Maurice 2022 Fig.3 的讨论），
	取 1 + 4·exp(−((h−12.75)/2.2)²)。天气只给 τ 时：τ > 1 视为起沙天气，风速 ×(1 + 0.3(τ−1))（设计）。"""
	if u_fixed >= 0.0: return u_fixed
	for k in ["风速_mps", "风速"]:
		if wx.has(k) and wx[k] != null: return float(wx[k])
	var h := hour()
	var u := 1.0 + 4.0*exp(-pow((h - 12.75)/2.2, 2.0))
	var tau = wx.get("τ", wx.get("tau", null))
	if tau != null and float(tau) > 1.0: u *= 1.0 + 0.3*(float(tau) - 1.0)
	return u


func 尘卷风(强度: float = 1.0) -> void:
	"""放一次尘卷风过境（sol 215 录音，Murdoch et al. 2022）。强度 1 ＝ 录音原样（从车上方经过）。"""
	if devil == null: return
	devil.volume_db = cal_db("尘卷风") + 20.0*log(maxf(强度, 1e-3))/log(10.0) + gain_db
	devil.play(); devil_cd = 180.0
	print("[声音] 尘卷风过境（强度 %.2f）" % 强度)


func 按键() -> Array:
	return [["K", "声音 开 / 关"]]


func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not ev.echo and ev.keycode == KEY_K:
		on = not on
		if bus_all >= 0: AudioServer.set_bus_mute(bus_all, not on)
		print("[声音] ", "开" if on else "静音")


func save_recording() -> String:
	"""把录制到的声音写成 wav；没录到（例如音频驱动不混音）返回空串。"""
	if rec == null or rec_path == "": return ""
	rec.set_recording_active(false)
	var w := rec.get_recording()
	if w == null: push_warning("[声音] 没有录到声音（音频驱动没在混音？）"); return ""
	var path := rec_path
	if not path.is_absolute_path() and not path.begins_with("user://") and not path.begins_with("res://"):
		path = ProjectSettings.globalize_path("res://").path_join(path)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	w.save_to_wav(path); rec_path = ""
	print("[声音] 录音存到 %s（%.1f s）" % [path, w.get_length()])
	return path


func stop_all() -> void:
	"""停掉所有层（退出前调用并等一两帧，混音线程才会放掉播放实例，否则退出时报资源未释放）。"""
	for p in [calm, gust, devil, drive, pump]:
		if p and is_instance_valid(p): p.stop(); p.stream = null          # 只 stop 在 Dummy 驱动下放不掉播放实例


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST: stop_all()


func _exit_tree() -> void:
	if rec_path != "": save_recording()
	stop_all()
	for nm in ["声音_泵", "声音_车", "声音_风", "声音"]:                  # 去掉自己加的总线（连同效果器），退出时不留引用
		var i := AudioServer.get_bus_index(nm)
		if i > 0: AudioServer.remove_bus(i)
