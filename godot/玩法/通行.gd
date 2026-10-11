# 可通行性（docs/玩法B.md §5）：CPU 上用游戏现有的高度（C++ h_cpu_grid，和地面、车轮同一个高）和石块（C++ scatter_rocks，
#   和画出来的同一套区块播种；+ 控制.gd 的固定石块）算每格的坡度、粗糙度、石块，合成风险（0–1）和「不可通行」，再按车体膨胀。
#   思路同 JPL GESTALT（坡度、粗糙度、台阶；Goldberg, Maimone, Matthies 2002）。不改地形着色器。
#   两张图：真值（执行、AutoNav）、已知（规划、预演：坡度全知；石块只知轨道上看得见的大石块 + 下行时 Navcam 环视范围内的全部）。
#   建() 很重（约几秒），在后台线程调；图的查询（风险 / 堵 / 石堵）很轻，可以在任何线程调。
extends RefCounted

const 半 := 400.0                               # 网格 ±400 m（以 sol 开始时的车位为中心）
const N := 800                                  # 1 m 一格
const 石门 := 0.40                              # 石顶离地 ≥ 40 cm 算撞石：真车能越过「knee-high rocks up to 40 cm」✔
const 石最小档 := 2                              # scatter_rocks 的档：b = 2 起，直径 ≥ 0.2 m
const 坡上限 := 25.0                             # °，同倾角上限（游戏设定）
const 已知石径 := 1.0                            # 轨道上看得见的石块直径（游戏设定，约 HiRISE 0.25 m/像素的 4 个像素）
const 已知半径 := 30.0                           # 下行时 Navcam 环视看清的范围 m（游戏设定）
const 坡区 := Vector2(12.0, 25.0)               # 风险：坡度 smoothstep（游戏设定）
const 粗区 := Vector2(0.10, 0.35)               # 粗糙度（4 m 弦中点偏差，m）smoothstep（游戏设定）
const 高区 := Vector2(0.20, 0.40)               # 格内最高石顶离地 smoothstep，到 40 cm 不可通行（游戏设定）
const 高石 := 0.15                               # 石顶离地 ≥ 15 cm 的才算进密度（游戏设定）
const 密满 := 1.0                                # 每 m² 1 块这样的石块：密度风险到顶（只到 0.5，即琥珀；游戏设定）


class 图:
	var x0 := 0.0
	var z0 := 0.0
	var n := 0
	var 险 := PackedFloat32Array()              # 膨胀后的风险
	var 堵格 := PackedByteArray()               # 膨胀后：石块 ≥ 石门 或 坡 ≥ 坡上限
	var 石格 := PackedByteArray()               # 膨胀后：只看石块

	func 下标(x: float, z: float) -> int:
		var i := floori(x - x0); var j := floori(z - z0)
		if i < 0 or j < 0 or i >= n or j >= n: return -1
		return j*n + i

	func 风险(x: float, z: float) -> float:
		var k := 下标(x, z)
		return 0.5 if k < 0 else 险[k]                                  # 网格外：未知，按中等风险

	func 堵(x: float, z: float) -> bool:
		var k := 下标(x, z)
		return k >= 0 and 堵格[k] != 0

	func 石堵(x: float, z: float) -> bool:
		var k := 下标(x, z)
		return k >= 0 and 石格[k] != 0

	func 在内(x: float, z: float) -> bool:
		return 下标(x, z) >= 0


var x0 := 0.0
var z0 := 0.0
var 高 := PackedFloat32Array()
var 坡 := PackedFloat32Array()                  # °
var 粗 := PackedFloat32Array()                  # m
var 真: 图
var 知: 图
var 知心 := Vector2()                            # (x, z)
var 石块数 := 0
var 大石数 := 0
var 用时 := {}
var 好了 := false


func 建(core: Object, rk_ab: Array, rk_fixed: Array, cx: float, cz: float, 知心_: Vector2) -> void:
	"""core：C++ MarsTerrainCore（h_cpu_grid、scatter_rocks）；rk_ab / rk_fixed：控制.gd 的石块网格包围盒、固定石块（每块 5 个数）。"""
	var t0 := Time.get_ticks_msec()
	x0 = floorf(cx - 半); z0 = floorf(cz - 半); 知心 = 知心_
	高 = core.h_cpu_grid(x0 + 0.5, z0 + 0.5, 1.0, N, N)
	var t1 := Time.get_ticks_msec()
	坡.resize(N*N); 粗.resize(N*N)
	for j in N:
		var jm := maxi(j - 1, 0)*N; var jp := mini(j + 1, N - 1)*N; var jr := j*N
		var dz := 2.0 if j > 0 and j < N - 1 else 1.0
		for i in N:
			var im := maxi(i - 1, 0); var ip := mini(i + 1, N - 1); var dx := 2.0 if i > 0 and i < N - 1 else 1.0
			var h := 高[jr + i]
			var a := 高[jr + im]; var b := 高[jr + ip]; var c := 高[jm + i]; var d := 高[jp + i]
			var gx := (b - a)/dx; var gz := (d - c)/dz
			坡[jr + i] = rad_to_deg(atan(sqrt(gx*gx + gz*gz)))
			var a2 := 高[jr + maxi(i - 2, 0)]; var b2 := 高[jr + mini(i + 2, N - 1)]; var c2 := 高[maxi(j - 2, 0)*N + i]; var d2 := 高[mini(j + 2, N - 1)*N + i]
			粗[jr + i] = 0.5*maxf(absf(a2 + b2 - 2.0*h), absf(c2 + d2 - 2.0*h))   # 4 m 弦中点偏差（车体尺度的起伏）
	var t2 := Time.get_ticks_msec()
	# 石块：每格最高石顶离地、直径 ≥ 0.2 m 的块数；大石块（轨道可见）另记
	var 石高 := PackedFloat32Array(); 石高.resize(N*N)
	var 石数 := PackedFloat32Array(); 石数.resize(N*N)
	var 大高 := PackedFloat32Array(); 大高.resize(N*N)
	var 大数 := PackedFloat32Array(); 大数.resize(N*N)
	var bufs: Array = core.scatter_rocks(x0, z0, x0 + N, z0 + N, 石最小档) if core.has_method("scatter_rocks") else []
	石块数 = 0; 大石数 = 0
	for ty in mini(bufs.size(), rk_ab.size()):
		var buf: PackedFloat32Array = bufs[ty]; var ab: AABB = rk_ab[ty]
		for q in range(0, buf.size() - 15, 16):
			var sx := Vector3(buf[q], buf[q + 4], buf[q + 8]).length(); var sy := Vector3(buf[q + 1], buf[q + 5], buf[q + 9]).length()
			var sz := Vector3(buf[q + 2], buf[q + 6], buf[q + 10]).length()
			var r := 0.25*(ab.size.x*sx + ab.size.z*sz)
			if 2.0*r < 0.2: continue
			var x := buf[q + 3]; var z := buf[q + 11]
			var k := 格号(x, z)
			if k < 0: continue
			var H := buf[q + 7] + ab.end.y*sy - 高[k]
			放石(x, z, r, H, 石高, 石数)
			if 2.0*r >= 已知石径: 放石(x, z, r, H, 大高, 大数); 大石数 += 1
	for q in range(0, rk_fixed.size() - 4, 5):                          # 固定石块（实测 + 固定表）：x、z、半径、底高、高
		var r: float = rk_fixed[q + 2]
		if 2.0*r < 0.2: continue
		放石(rk_fixed[q], rk_fixed[q + 1], r, rk_fixed[q + 4], 石高, 石数)
		if 2.0*r >= 已知石径: 放石(rk_fixed[q], rk_fixed[q + 1], r, rk_fixed[q + 4], 大高, 大数); 大石数 += 1
	var t3 := Time.get_ticks_msec()
	var 密 := 盒和(石数); var 大密 := 盒和(大数)
	真 = 合成(石高, 密, PackedFloat32Array(), PackedFloat32Array())
	知 = 合成(石高, 密, 大高, 大密)
	var t4 := Time.get_ticks_msec()
	用时 = {"高度_ms": t1 - t0, "坡度_ms": t2 - t1, "石块_ms": t3 - t2, "合成_ms": t4 - t3, "共_ms": t4 - t0}
	好了 = true


func 格号(x: float, z: float) -> int:
	var i := floori(x - x0); var j := floori(z - z0)
	if i < 0 or j < 0 or i >= N or j >= N: return -1
	return j*N + i


func 放石(x: float, z: float, r: float, H: float, 石高: PackedFloat32Array, 石数: PackedFloat32Array) -> void:
	"""石块盖住的格（包围方块）：最高石顶取大；块数只记在石心那格。"""
	石块数 += 1
	var k := 格号(x, z)
	if k >= 0 and H >= 高石: 石数[k] += 1.0
	var i0 := floori(x - r - x0); var i1 := floori(x + r - x0); var j0 := floori(z - r - z0); var j1 := floori(z + r - z0)
	for j in range(maxi(j0, 0), mini(j1, N - 1) + 1):
		for i in range(maxi(i0, 0), mini(i1, N - 1) + 1):
			if 石高[j*N + i] < H: 石高[j*N + i] = H


func 合成(石高: PackedFloat32Array, 石数: PackedFloat32Array, 大高: PackedFloat32Array, 大数: PackedFloat32Array) -> 图:
	"""大高为空：真值图（全部石块）；否则已知图：知心 已知半径 内用全部石块，外面只用大石块。"""
	var g := 图.new(); g.x0 = x0; g.z0 = z0; g.n = N
	var 险 := PackedFloat32Array(); 险.resize(N*N)
	var 堵 := PackedByteArray(); 堵.resize(N*N)
	var 石 := PackedByteArray(); 石.resize(N*N)
	var 已知 := not 大高.is_empty()
	var r2 := 已知半径*已知半径
	for j in N:
		var jr := j*N; var zc := z0 + j + 0.5; var dz2 := (zc - 知心.y)*(zc - 知心.y)
		for i in N:
			var k := jr + i
			var 全 := not 已知 or (x0 + i + 0.5 - 知心.x)*(x0 + i + 0.5 - 知心.x) + dz2 <= r2
			var H: float = 石高[k] if 全 else 大高[k]
			var 密: float = (石数[k] if 全 else 大数[k])/9.0                    # 3 × 3 m 内的块数 / 9 m²（石数、大数已是盒和）
			var s := 坡[k]
			险[k] = maxf(maxf(smoothstep(坡区.x, 坡区.y, s), smoothstep(粗区.x, 粗区.y, 粗[k])), maxf(smoothstep(高区.x, 高区.y, H), 0.5*minf(1.0, 密/密满)))
			var 石堵 := H >= 石门
			石[k] = 1 if 石堵 else 0
			堵[k] = 1 if (石堵 or s >= 坡上限) else 0
	g.险 = 膨胀f(险); g.堵格 = 膨胀b(堵); g.石格 = 膨胀b(石)
	return g


func 盒和(a: PackedFloat32Array) -> PackedFloat32Array:
	"""3 × 3 格求和（边上少几格，不补）。"""
	var t := PackedFloat32Array(); t.resize(N*N)
	for j in N:
		var o := j*N
		for i in N: t[o + i] = a[o + i] + (a[o + i - 1] if i > 0 else 0.0) + (a[o + i + 1] if i < N - 1 else 0.0)
	var out := PackedFloat32Array(); out.resize(N*N)
	for j in N:
		var o := j*N; var om := (j - 1)*N; var op := (j + 1)*N
		for i in N: out[o + i] = t[o + i] + (t[om + i] if j > 0 else 0.0) + (t[op + i] if j < N - 1 else 0.0)
	return out


func 膨胀f(a: PackedFloat32Array) -> PackedFloat32Array:
	"""3 × 3 最大值（车体 3 m × 2.7 m ✔，车心落在膨胀后的格上就算车体碰到）。可分离：先横后竖。"""
	var t := PackedFloat32Array(); t.resize(N*N)
	for j in N:
		var o := j*N
		for i in N:
			var m := a[o + i]
			if i > 0: m = maxf(m, a[o + i - 1])
			if i < N - 1: m = maxf(m, a[o + i + 1])
			t[o + i] = m
	var out := PackedFloat32Array(); out.resize(N*N)
	for j in N:
		var o := j*N; var om := maxi(j - 1, 0)*N; var op := mini(j + 1, N - 1)*N
		for i in N: out[o + i] = maxf(t[o + i], maxf(t[om + i], t[op + i]))
	return out


func 膨胀b(a: PackedByteArray) -> PackedByteArray:
	var t := PackedByteArray(); t.resize(N*N)
	for j in N:
		var o := j*N
		for i in N:
			t[o + i] = a[o + i] | (a[o + i - 1] if i > 0 else 0) | (a[o + i + 1] if i < N - 1 else 0)
	var out := PackedByteArray(); out.resize(N*N)
	for j in N:
		var o := j*N; var om := maxi(j - 1, 0)*N; var op := mini(j + 1, N - 1)*N
		for i in N: out[o + i] = t[o + i] | t[om + i] | t[op + i]
	return out


func 叠图(g: 图, 色: Dictionary) -> Image:
	"""规划图的可通行性层（N × N RGBA8，北在上：图像第 0 行 = 最北，即 z 最小）：风险 ≤ 0.3 透明，往上由 中 → 高 渐变、渐不透明，不可通行实色。
	色：{中, 高, 堵, 透明}（玩法/风格.gd 的 险中、险高、险堵、险透明）。"""
	var data := PackedByteArray(); data.resize(N*N*4)
	var 门 := float(色.get("门", 0.3))
	for j in N:                                                         # z0 + j：j = 0 最北
		for i in N:
			var k := j*N + i; var o := k*4
			var r := g.险[k]
			var c := Color(0, 0, 0, 0)
			if g.堵格[k] != 0: c = 色["堵"]
			elif r > 门: c = (色["中"] as Color).lerp(色["高"], smoothstep(0.5, 0.8, r)); c.a = float(色["透明"])*smoothstep(门, 0.8, r)
			data[o] = c.r8; data[o + 1] = c.g8; data[o + 2] = c.b8; data[o + 3] = c.a8
	return Image.create_from_data(N, N, false, Image.FORMAT_RGBA8, data)


func 标记图(g: 图) -> Image:
	"""稀疏标记（规划图、下行卡）：R = 不可通行格、G = 高风险格（风险 ≥ 0.66，不含不可通行），N × N RG8，行列同 叠图()。
	生成 mipmap（每档 2×2 平均）后，第 L 档一个像素 = 2^L m 见方的块里两类格各占多少。"""
	var data := PackedByteArray(); data.resize(N*N*2)
	for k in N*N:
		if g.堵格[k] != 0: data[k*2] = 255
		elif g.险[k] >= 0.66: data[k*2 + 1] = 255
	var im := Image.create_from_data(N, N, false, Image.FORMAT_RG8, data)
	im.generate_mipmaps()
	return im


func 统计(g: 图) -> Dictionary:
	var n险 := [0, 0, 0]; var n堵 := 0
	for k in N*N:
		if g.堵格[k] != 0: n堵 += 1
		elif g.险[k] >= 0.66: n险[2] += 1
		elif g.险[k] >= 0.33: n险[1] += 1
		else: n险[0] += 1
	var f := 1.0/float(N*N)
	var 分 := func(a: PackedFloat32Array) -> String:
		var b := a.duplicate(); b.sort()
		return "%.3f/%.3f/%.3f" % [b[b.size()/2], b[int(b.size()*0.9)], b[int(b.size()*0.99)]]
	return {"低": snappedf(n险[0]*f, 0.001), "中": snappedf(n险[1]*f, 0.001), "高": snappedf(n险[2]*f, 0.001), "不可通行": snappedf(n堵*f, 0.001),
		"坡度p50/90/99": 分.call(坡), "粗糙p50/90/99": 分.call(粗)}
