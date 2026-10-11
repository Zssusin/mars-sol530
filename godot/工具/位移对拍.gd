# 中观位移对拍：CPU（C++ MarsTerrainCore.mat_disp、GDScript 材质.gd disp）和 GPU（材质.gdshaderinc mat_disp）逐点比。
#   无头（只比 C++ / GDScript）：godot --headless --path godot --script res://工具/位移对拍.gd
#   GPU（kwin 虚拟合成器里）：  godot --display-driver wayland --path godot --script res://工具/位移对拍.gd -- --gpu [--格=0.01]
# 区域：车旁 ±8 m（Navcam 区，门多半 0）、中层 12–45 m、HiRISE 区 60–300 m、1 km 外。每区 128×128 点、点距 3.1 cm。
extends SceneTree

const AREAS := [["车旁", -4.0, -4.0], ["中层", 20.0, -30.0], ["HiRISE", 140.0, 90.0], ["1km外", 1300.0, -800.0]]
const N := 128
const DX := 0.031


func _initialize() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1); args[kv[0]] = kv[1] if kv.size() > 1 else ""
	var D := "res://数据/sol0530/"                                 # --script 模式没有 autoload（环境）
	var mat := ShaderMaterial.new()
	var M = load("res://材质.gd").new()
	if not M.setup(D, args, mat): push_error("材质 setup 失败"); quit(1); return
	var core = ClassDB.instantiate("MarsTerrainCore") if ClassDB.class_exists("MarsTerrainCore") else null
	if core: core.configure_mat(M)
	var gpu := args.has("gpu")
	var cellv := float(args.get("格", "0"))
	var vp: SubViewport; var rect: ColorRect
	if gpu:
		vp = SubViewport.new(); vp.size = Vector2i(N, N); vp.use_hdr_2d = true; vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		vp.transparent_bg = true; root.add_child(vp)
		rect = ColorRect.new(); rect.size = Vector2(N, N); vp.add_child(rect)
		var sm := ShaderMaterial.new(); sm.shader = load("res://工具/位移对拍.gdshader")
		if M.fmt == 4: var sh2 := Shader.new(); sh2.code = "#define MAT_N16\n" + sm.shader.code; sm.shader = sh2   # 中景版 4 槽格式（同 实景.gd shader_of）
		rect.material = sm
		for k in ["mat_ctrl_n", "mat_ctrl_f", "mat_gate", "mat_grid", "mat_out_id", "mat_out_w", "mat_meso_h16", "mat_me", "mat_bl", "mat_lay", "mat_hexp", "mat_k", "mat_cpu_cell", "mat_fmt"]:
			sm.set_shader_parameter(k, mat.get_shader_parameter(k))
		sm.set_shader_parameter("cell", cellv)
	var all_c := PackedFloat64Array(); var all_g := PackedFloat64Array()
	for A in AREAS:
		var x0: float = A[1]; var z0: float = A[2]
		var t0 := Time.get_ticks_usec()
		var cv := PackedFloat64Array(); cv.resize(N*N)
		for j in N:
			for i in N:
				cv[j*N + i] = core.mat_disp(x0 + i*DX, z0 + j*DX) if core else M.disp(x0 + i*DX, z0 + j*DX)
		var tc := (Time.get_ticks_usec() - t0)/float(N*N)
		var line := "[对拍] %-7s C++ %.2f µs/点，|d| 均 %.2f mm、最大 %.1f mm" % [A[0], tc, _mean_abs(cv)*1e3, _max_abs(cv)*1e3]
		if core:                                                     # GDScript 版抽 400 点
			var dm := 0.0; var t1 := Time.get_ticks_usec()
			for k in 400:
				var i := (k*37) % N; var j := (k*61) % N
				dm = maxf(dm, absf(M.disp(x0 + i*DX, z0 + j*DX) - cv[j*N + i]))
			line += "；GDScript 差最大 %.4f µm（%.0f µs/点）" % [dm*1e6, (Time.get_ticks_usec() - t1)/400.0]
		if gpu:
			(rect.material as ShaderMaterial).set_shader_parameter("rect", Vector4(x0, z0, DX, DX))
			for f in 4: await RenderingServer.frame_post_draw
			var img := vp.get_texture().get_image()
			var diffs := PackedFloat64Array()
			for j in N:
				for i in N:
					var gv := img.get_pixel(i, j).r/10.0
					diffs.append(gv - cv[j*N + i]); all_g.append(gv); all_c.append(cv[j*N + i])
			diffs.sort()
			line += "；GPU−CPU：|差| 中位 %.3f mm、99%% %.3f mm、最大 %.3f mm" % [_q(diffs, 0.5)*1e3, _q(diffs, 0.99)*1e3, maxf(absf(diffs[0]), absf(diffs[-1]))*1e3]
		print(line)
	print("[对拍] 完")
	quit(0)


func _mean_abs(a: PackedFloat64Array) -> float:
	var s := 0.0
	for v in a: s += absf(v)
	return s/maxf(a.size(), 1)


func _max_abs(a: PackedFloat64Array) -> float:
	var m := 0.0
	for v in a: m = maxf(m, absf(v))
	return m


func _q(sorted_d: PackedFloat64Array, q: float) -> float:
	var ab := PackedFloat64Array()
	for v in sorted_d: ab.append(absf(v))
	ab.sort()
	return ab[int(q*(ab.size() - 1))]
