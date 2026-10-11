# 沙纹场对拍：地貌印章 CPU 两版（GDScript 地貌.gd h、C++ MarsTerrainCore.geo_h）逐点逐位比，重点是实测沙纹场 rfield（docs/地面材质/沙纹.md）。
#   godot --headless --path godot --script res://工具/沙纹对拍.gd [-- --沙纹=新|旧|0]
# 区域：HiRISE 区四块有沙纹的 64 m 方块（每块 160×160 点、点距 0.4 m）+ 1 km 边界渐隐带 + Navcam 区（应全 0）。
extends SceneTree

const AREAS := [["南TAR场", 40.0, 80.0], ["西南", -110.0, 60.0], ["B2", -20.0, 560.0], ["东南", 100.0, 180.0], ["1km边", 940.0, -30.0], ["Navcam", -20.0, -20.0]]
const N := 160
const DX := 0.4


func _initialize() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1); args[kv[0]] = kv[1] if kv.size() > 1 else ""
	var D := "res://数据/sol0530/"
	var J: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(D + "scene.json"))
	var geo = load("res://地貌.gd").new()
	geo.setup(J, D, args, ProjectSettings.globalize_path("res://") + "../资料/地貌参数/地貌参数.json")
	if not ClassDB.class_exists("MarsTerrainCore"): push_error("扩展没加载"); quit(1); return
	var core = ClassDB.instantiate("MarsTerrainCore")
	core.configure_geo(geo)
	var bad := 0; var tot := 0; var nz := 0; var tg := 0; var tc := 0; var hmax := 0.0
	for A in AREAS:
		var x0: float = A[1]; var z0: float = A[2]
		var d_max := 0.0; var n_nz := 0; var n_bad := 0; var rf_max := 0.0
		for j in N:
			for i in N:
				var x := x0 + i*DX + 0.013*j; var z := z0 + j*DX + 0.007*i   # 错开格点，避免总落在格中心
				var t0 := Time.get_ticks_usec()
				var hg: float = geo.h(x, z)
				var t1 := Time.get_ticks_usec()
				var hc: float = core.geo_h(x, z)
				tc += Time.get_ticks_usec() - t1; tg += t1 - t0
				var r: float = geo.rfield(x, z, geo.dem_l(x, z, 3.0))
				if r != 0.0: n_nz += 1
				rf_max = maxf(rf_max, absf(r))
				if hg != hc: n_bad += 1; d_max = maxf(d_max, absf(hg - hc))
		print("[对拍] %s 点 %d：GDScript ≠ C++ %d 点（最大差 %.6f mm）；沙纹场非 0 %d 点，|rfield| 最大 %.3f m" % [A[0], N*N, n_bad, d_max*1000.0, n_nz, rf_max])
		bad += n_bad; tot += N*N; nz += n_nz; hmax = maxf(hmax, rf_max)
	print("[对拍] 合计 %d 点，不一致 %d；沙纹场非 0 %d 点；GDScript %.1f µs/点，C++ %.2f µs/点" % [tot, bad, nz, tg/float(tot), tc/float(tot)])
	print("[对拍] %s" % ("逐位一致" if bad == 0 else "不一致！"))
	quit(0 if bad == 0 else 1)
