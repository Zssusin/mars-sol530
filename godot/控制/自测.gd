# 控制自测（--控制测试）：自动开一段（直行 → 左弧 → 原地右转 → 压石块 → 倒车），轮换相机、截图，
# 打印本模块每帧 CPU 用时、车身抖动（俯仰 / 横滚的二阶差分）、上下补偿是否顶到 ±12 cm，然后退出。
# 截图存 --控制出=<目录>（默认 产出/Godot/控制测试）。由 控制/测试.sh 在 kwin 虚拟显示器里跑。
extends Node

var C: Node
var out := ""
var rec := false
var cpu: Array[float] = []
var frm: Array[float] = []
var pr: Array[Vector2] = []
var jit := Vector2(); var jit_t := ""; var jit_sum := Vector2()
var dy_max := 0.0; var n_clamp := 0; var n_rock := 0; var seg := ""
var 无头 := DisplayServer.get_name() == "headless"


func _ready() -> void:
	C = get_parent()
	out = String(C.P.args.get("控制出", ProjectSettings.globalize_path("res://").path_join("../产出/Godot/控制测试"))).simplify_path()
	DirAccess.make_dir_recursive_absolute(out)
	run.call_deferred()


func _process(dt: float) -> void:
	if not rec: return
	cpu.append(C.cpu_ms); frm.append(dt*1000.0)
	var s: Dictionary = C.状态()
	pr.append(Vector2(s["俯仰_deg"], s["横滚_deg"]))
	var n := pr.size()
	var m := frm.size()
	if n >= 3 and m >= 3 and maxf(frm[m - 1], maxf(frm[m - 2], frm[m - 3])) < 20.0:   # 截图那几帧（帧长不匀）不算
		var j: Vector2 = (pr[n - 1] - 2.0*pr[n - 2] + pr[n - 3]).abs()
		jit_sum += j
		if j.length() > jit.length(): jit = j; jit_t = seg
	for i in 6:
		dy_max = maxf(dy_max, absf(C.dy[i] + 0.01))
		if absf(C.dy[i] + 0.01) >= 0.1199: n_clamp += 1
	for i in 6:
		var c: Vector3 = C.last_c[i]
		if C.hc[i] > C.ground(c.x, c.z) + 0.03: n_rock += 1; break


func shot(name: String, settle := 8) -> void:
	for k in settle: await 帧()
	var path := out.path_join(name + ".png")
	if not 无头: get_viewport().get_texture().get_image().save_png(path)   # 无头（scripts/检查.sh 快档）不画，不截图
	var s: Dictionary = C.状态()
	print("[自测] 截图 %s ｜ %s 航向 %.1f° 俯仰 %.1f° 横滚 %.1f° 转向 %.1f° 真速 %.3f m/s 里程 %.2f m" % [
		path.get_file(), s["模式"], s["航向_deg"], s["俯仰_deg"], s["横滚_deg"], s["转向_deg"], s["速度_mps"], s["里程_m"]])


func 帧() -> void:                                                   # 等一帧画完；无头时没有 frame_post_draw，等 process_frame
	await (get_tree().process_frame if 无头 else RenderingServer.frame_post_draw)


func wait(t: float) -> void:
	await get_tree().create_timer(t).timeout


func side_cam(target: Vector3, side: float, dist: float, hgt: float) -> void:
	"""自由相机放在车左（side=1）/ 右侧，贴地看 target。"""
	var fly: Camera3D = C.P.fly
	var b: Basis = C.body.basis
	var pos: Vector3 = target + b.x*side*dist + b.z*0.6
	pos.y = maxf(C.ground(pos.x, pos.z), C.ground(target.x, target.z)) + hgt          # 车在坡上：按高的一边定机位，免得被坡挡住
	fly.global_transform = Transform3D(Basis.IDENTITY, pos).looking_at(target, Vector3.UP); fly.fov = 45.0


func run() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var park: Transform3D = C.park
	print("[自测] 停车位：模型位姿 俯仰 %.2f° 横滚 %.2f° ｜ 本模块拟合 俯仰 %.2f° 横滚 %.2f°，原点高差 %.3f m" % [
		rad_to_deg(asin(park.basis.z.y)), rad_to_deg(asin(park.basis.x.y)),
		rad_to_deg(asin(C.body.basis.z.y)), rad_to_deg(asin(C.body.basis.x.y)), C.body.origin.y - park.origin.y])
	var s0: Dictionary = C.状态()
	print("[自测] 状态键：", s0.keys(), " 轮序 ", s0["轮序"], " 倾角 %.2f°" % s0["倾角_deg"])
	await wait(4.0)
	await shot("01_跟车_停车位")
	rec = true
	seg = "直行"; C.自动 = {"油": 1.0}
	await wait(4.0); await shot("02_跟车_直行", 2)
	C.set_mode("桅杆"); await wait(1.0); await shot("03_桅杆_直行", 2)
	seg = "左弧"; C.自动 = {"油": 1.0, "转": 1.0}
	C.set_mode("跟车"); await wait(4.0); await shot("04_跟车_左弧", 2)
	C.set_mode("自由"); side_cam(C.body.origin + Vector3.UP*0.3, -1.0, 3.2, 0.5); await wait(0.5); await shot("05_自由_左弧车轮", 2)
	C.自动 = {}; await wait(1.0)
	if C.track:                                                          # 车辙：车后 5 m、3 m 高往车后 1.5 m 看
		var b: Basis = C.body.basis; var fly: Camera3D = C.P.fly
		var tgt: Vector3 = C.body.origin - b.z*1.8; var pos: Vector3 = C.body.origin - b.z*4.5 - b.x*1.2
		pos.y = C.ground(pos.x, pos.z) + 2.2
		fly.global_transform = Transform3D(Basis.IDENTITY, pos).looking_at(tgt, Vector3.UP); fly.fov = 60.0
		await shot("05b_自由_车辙", 4)
		print("[自测] 车辙：", C.track.info())
		C.track.center_on(C.p + Vector3(0.83, 0, -0.41), false)          # 强行换一次窗口，读回看拷贝有没有变值
		for k in 3: await 帧()
		print("[自测] 车辙换窗口后：", C.track.info())
		await shot("05c_自由_车辙换窗口后", 2)
	seg = "原地右转"; C.自动 = {"原地": -1.0}
	C.set_mode("俯视"); await wait(5.0); await shot("06_俯视_原地转", 2)
	C.set_mode("自由"); side_cam(C.body.origin + Vector3.UP*0.3, 1.0, 3.2, 0.5); await wait(0.3); await shot("07_自由_原地转车轮", 2)
	# 压石块：找停车位 20 m 内一块直径 30–60 cm、高 12–30 cm 的石块，让左前轮从 1.2 m 外直着压过去
	seg = "压石块"; C.自动 = {}
	await wait(1.5)
	var best := -1; var bd := 20.0
	for n in C.rk.size()/5:
		var o: int = n*5
		var a: float = C.rk[o + 2]; var H: float = C.rk[o + 4]
		var d := Vector2(C.rk[o] - park.origin.x, C.rk[o + 1] - park.origin.z).length()
		if a >= 0.15 and a <= 0.3 and H >= 0.12 and H <= 0.3 and d < bd: bd = d; best = n
	if best >= 0:
		var o: int = best*5
		var rp := Vector3(C.rk[o], C.rk[o + 3], C.rk[o + 1]); var psi: float = C.psi
		var f := Vector3(cos(psi), 0, sin(psi)); var l := Vector3(sin(psi), 0, -cos(psi))
		print("[自测] 石块：直径 %.2f m、高 %.2f m，离停车位 %.1f m" % [2.0*C.rk[o + 2], C.rk[o + 4], bd])
		C.teleport(rp - f*(C.W[0].z + 1.2) - l*C.W[0].x, psi); pr.clear()
		C.set_mode("自由"); side_cam(rp + Vector3.UP*0.2, 1.0, 3.5, 0.6)
		await wait(1.0)
		C.自动 = {"油": 1.0}
		for wi in [0, 1, 2]:                                              # 左前、左中、左后轮依次压上去时各截一张
			var t0 := Time.get_ticks_msec()
			while Time.get_ticks_msec() - t0 < 12000:
				await get_tree().process_frame
				var c: Vector3 = C.last_c[wi]
				if (rp - c).dot(Vector3(cos(C.psi), 0, sin(C.psi))) < 0.0: break
			C.自动 = {}
			await wait(0.8)
			side_cam(rp + Vector3.UP*0.2, 1.0, 3.5, 0.6)
			await shot("08_自由_压石块_%s" % ["左前", "左中", "左后"][wi], 4)
			var lc: Vector3 = C.last_c[wi]
			print("[自测]   该轮接地比地面高 %.1f cm ｜ 各轮 dy（cm）：%s" % [(C.hc[wi] - C.ground(lc.x, lc.z))*100.0, str(Array(C.dy).map(func(x): return snappedf(x*100.0, 0.1)))])
			C.自动 = {"油": 1.0}
		C.自动 = {}
		C.set_mode("跟车"); await wait(1.0); await shot("09_跟车_压过石块", 2)
	seg = "倒车"; C.自动 = {"油": -1.0}
	await wait(2.5); C.自动 = {}; await wait(1.0)
	await shot("10_跟车_倒车后", 2)
	rec = false
	var cs := cpu.duplicate(); cs.sort(); var fs := frm.duplicate(); fs.sort(); var n := cs.size()
	print("[自测] 本模块 _process：平均 %.3f ms，95%% %.3f，最差 %.3f（%d 帧）｜ 整帧 平均 %.1f ms，95%% %.1f" % [
		cs.reduce(func(a, b): return a + b)/n, cs[int(n*0.95)], cs[-1], n, fs.reduce(func(a, b): return a + b)/n, fs[int(n*0.95)]])
	print("[自测] 车身抖动（逐帧二阶差分）平均 %.4f° / %.4f°，最大 俯仰 %.3f° 横滚 %.3f°（%s）｜ 上下补偿最大 %.1f cm，顶到 ±12 cm %d 轮帧，压在石块上 %d 帧" % [
		jit_sum.x/maxf(pr.size(), 1), jit_sum.y/maxf(pr.size(), 1), jit.x, jit.y, jit_t, dy_max*100.0, n_clamp, n_rock])
	if C.track: print("[自测] 车辙：", C.track.info())
	print("[自测] 完")
	get_tree().quit()
