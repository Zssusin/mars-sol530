# 声音自测（--声音测试，配 --声音录制=路径.wav）：自动开一段车、换机位，录下本模块输出，同时每帧记下状态（json，与 wav 同名），然后退出。
# 时间表（秒）：0 桅杆停 → 4 桅杆直行 → 11 停 → 14 跟车直行 → 21 停 → 24 自由相机离车 25 m 直行 → 30 停 → 31 桅杆原地转 → 36 停、尘卷风 → 42 完。
# 离线分析：资料/声音/工具/析录音.py。由 声音/测试.sh 在 kwin 虚拟显示器里跑。
extends Node

var S: Node
var C: Node
var log_rows: Array = []
var t0 := 0


func _ready() -> void:
	S = get_parent(); C = S.C
	run.call_deferred()


func _process(_dt: float) -> void:
	if t0 == 0: return
	var d: Dictionary = S.dbg.duplicate()
	d["墙钟"] = (Time.get_ticks_msec() - t0)/1000.0; d["cpu_ms"] = S.cpu_ms
	log_rows.append(d)


func wait(t: float) -> void:
	await get_tree().create_timer(t).timeout


func mark(s: String) -> void:
	print("[声音自测] %.2f s %s" % [(Time.get_ticks_msec() - t0)/1000.0, s])
	log_rows.append({"标记": s, "墙钟": (Time.get_ticks_msec() - t0)/1000.0, "t": S.t})


func run() -> void:
	if C == null:
		push_warning("[声音自测] 没有 控制 模块，只录 10 s 环境声"); t0 = Time.get_ticks_msec(); await wait(10.0); finish(); return
	await wait(2.0)                                                      # 场景稳定
	t0 = Time.get_ticks_msec()
	C.set_mode("桅杆"); mark("桅杆 停")
	await wait(4.0)
	mark("桅杆 直行"); C.自动 = {"油": 1.0}
	await wait(7.0)
	mark("停"); C.自动 = {}
	await wait(3.0)
	C.set_mode("跟车"); mark("跟车 直行"); C.自动 = {"油": 1.0}
	await wait(7.0)
	mark("停"); C.自动 = {}
	await wait(3.0)
	C.set_mode("自由")
	var b: Basis = C.body.basis; var o: Vector3 = C.body.origin
	var pos: Vector3 = o - b.x*25.0; pos.y = C.ground(pos.x, pos.z) + 1.7
	C.P.fly.global_transform = Transform3D(Basis.IDENTITY, pos).looking_at(o + Vector3.UP*0.5, Vector3.UP)
	mark("自由 25 m 直行"); C.自动 = {"油": 1.0}
	await wait(6.0)
	mark("停"); C.自动 = {}
	await wait(1.0)
	C.set_mode("桅杆"); mark("桅杆 原地转"); C.自动 = {"原地": 1.0}
	await wait(5.0)
	mark("停 尘卷风"); C.自动 = {}; S.尘卷风(1.0)
	await wait(6.0)
	finish()


func finish() -> void:
	mark("完")
	var path: String = S.save_recording()
	var n := 0; var cs := 0.0; var mx := 0.0
	for r in log_rows:
		if r.has("cpu_ms"): n += 1; cs += r["cpu_ms"]; mx = maxf(mx, r["cpu_ms"])
	print("[声音自测] 本模块 _process 平均 %.3f ms，最差 %.3f ms（%d 帧）" % [cs/maxf(n, 1), mx, n])
	if path != "":
		var f := FileAccess.open(path.get_basename() + ".json", FileAccess.WRITE)
		f.store_string(JSON.stringify(log_rows)); f.close()
		print("[声音自测] 日志 ", path.get_basename() + ".json")
	print("[声音自测] 完")
	S.stop_all()
	await wait(0.3)
	get_tree().quit()
