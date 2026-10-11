# 对拍（GDScript 端）：读 parity_dump 写的合成输入，用未改动的原脚本（原版/地貌.gd、撒石.gd、地形LOD.gd）算同样的量，写 gd_*.bin。
# 运行：Godot --headless --path <项目目录> --script res://对拍.gd -- <目录>
extends SceneTree


func _init() -> void:
	var dir: String = OS.get_cmdline_user_args()[0]
	# —— 地形LOD（不进场景树，只用取高和选块）
	var lod = load("res://地形LOD.gd").new()
	lod.hN = 65; lod.hc0 = 0.1875; lod.hh0 = 6.0; lod.hL = 15
	lod.W = lod.hh0*pow(2.0, lod.hL - 1)
	var hb := FileAccess.get_file_as_bytes(dir + "/heights.bin")
	for k in lod.hL: lod.hl.append(hb.slice(k*65*65*4, (k + 1)*65*65*4).to_float32_array())
	# —— 地貌（同 parity_dump.cpp build() 的字面量）
	var geo = load("res://地貌.gd").new()
	geo.cN = 200; geo.c_half = 100.0; geo.c_cs = 2.0*geo.c_half/geo.cN
	geo.cls = FileAccess.get_file_as_bytes(dir + "/geo_class.bin")
	geo.C = 1.48e-3; geo.b = 2.2; geo.dD_fresh = 0.2; geo.dD_old = 0.03; geo.rim = 0.032; geo.fill = 0.8
	geo.cr_cls = [1.09, 0.65, 0.74, 0.98]
	geo.rp = []
	for r in [[20.0, 0.45, 0.3, 0.2, 286.0], [2.7, 0.2, 0.2, 0.25, 10.0], [0.2, 0.01, 0.3, 0.2, 286.0]]:
		var e := [r[0], r[1], 0.0, 0.0, r[2], r[3]]
		geo._dir(e, r[4]); geo.rp.append(e)
	lod.geo = geo
	# —— 撒石
	var host = load("res://宿主桩.gd").new()
	var scat = load("res://撒石.gd").new()
	scat.setup(host, lod, geo, {"geo": {"k_cls": [0.03, 0.06, 0.09, 0.15]}}, 5, Color(0.24, 0.17, 0.13),
		[[-0.4, 0.95], [-0.35, 1.0], [-0.5, 0.9], [-0.42, 0.97], [-0.3, 0.85]])
	var timing := ""

	# 1 逐点
	var fin := FileAccess.open(dir + "/points.bin", FileAccess.READ)
	var n := fin.get_32(); var P := []
	for i in n: P.append(Vector2(0, 0)); P[i] = [fin.get_double(), fin.get_double()]
	var f := FileAccess.open(dir + "/gd_points.bin", FileAccess.WRITE)
	var t0 := Time.get_ticks_usec()
	for p in P:
		var x: float = p[0]; var z: float = p[1]
		f.store_double(lod.h_data(x, z, 0)); f.store_double(lod.h_data(x, z, 3)); f.store_double(geo.dem_l(x, z))
		for v in geo.W(x, z): f.store_double(v)
		f.store_double(geo.h(x, z)); f.store_double(geo.margin(absf(x))); f.store_double(lod.h_cpu(x, z, 0))
	f.close()
	timing += "points %.3f ms (%d 点)\n" % [(Time.get_ticks_usec() - t0)/1000.0, n]

	# 2 区块
	fin = FileAccess.open(dir + "/tiles.bin", FileAccess.READ)
	var nt := fin.get_32(); var T := []
	for i in nt: T.append([fin.get_32(), _s32(fin.get_32()), _s32(fin.get_32())])
	f = FileAccess.open(dir + "/gd_tiles.bin", FileAccess.WRITE)
	t0 = Time.get_ticks_usec(); var rocks := 0
	for tl in T:
		var tile: Dictionary = scat.gen_tile(tl[0], tl[1], tl[2])
		f.store_32(tile.size())
		for ty in tile:
			var buf: PackedFloat32Array = tile[ty]
			f.store_32(ty); f.store_32(buf.size())
			for v in buf: f.store_float(v)
			rocks += buf.size()/16
	f.close()
	timing += "tiles %.3f ms (%d 区块, %d 块)\n" % [(Time.get_ticks_usec() - t0)/1000.0, nt, rocks]

	# 3 选块（地形LOD.update 的选块部分，逐字）
	var cams := [Vector3(3.0, 1.8, -4.0), Vector3(140.0, 2.5, 60.0), Vector3(-30.0, 45.0, 10.0)]
	var pa := 0.0005
	f = FileAccess.open(dir + "/gd_select.bin", FileAccess.WRITE)
	t0 = Time.get_ticks_usec()
	for cam in cams:
		lod.range0 = maxf(lod.c0/(lod.tri_px*pa), 3.0*lod.m*lod.c0)
		lod.R.clear()
		for l in lod.L: lod.R.append(lod.range0*pow(2.0, l))
		var out := []
		var s: float = lod.m*lod.c0*pow(2.0, lod.L - 1); var nr := ceili(lod.W/s)
		for j in range(-nr, nr):
			for i in range(-nr, nr): lod.sel(cam, lod.L - 1, i*s, j*s, out)
		f.store_32(out.size())
		for nd in out:
			f.store_32(nd[0]); f.store_double(nd[1]); f.store_double(nd[2]); f.store_double(nd[3][0]); f.store_double(nd[3][1]); f.store_32(nd[4])
	f.close()
	timing += "select %.3f ms (3 机位)\n" % [(Time.get_ticks_usec() - t0)/1000.0]

	# 4 收集（冷缓存，不限时）
	f = FileAccess.open(dir + "/gd_collect.bin", FileAccess.WRITE)
	t0 = Time.get_ticks_usec(); var collected := 0
	for cam in cams:
		scat.cache = {}
		var lists := []
		for i in 5: lists.append([[], [], []])
		scat.collect(cam, pa, lists, 0.0)
		collected += scat.n_rocks
		f.store_32(scat.n_tiles); f.store_32(scat.n_rocks)
		for ty in 5:
			for l in 3:
				var cat := PackedFloat32Array()
				for a in lists[ty][l]: cat.append_array(a)
				f.store_32(cat.size())
				for v in cat: f.store_float(v)
	f.close()
	timing += "collect %.3f ms (3 机位冷缓存, %d 块)\n" % [(Time.get_ticks_usec() - t0)/1000.0, collected]

	var ft := FileAccess.open(dir + "/gd_timing.txt", FileAccess.WRITE); ft.store_string(timing); ft.close()
	print("GDScript：\n" + timing)
	host.free(); lod.free()
	quit()


func _s32(v: int) -> int:
	return v - 0x100000000 if v >= 0x80000000 else v
