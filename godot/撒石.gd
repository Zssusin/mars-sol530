# 实时统计撒石（实景地形系统.md §14）：取代 57 导出的固定撒石表（只到 1 km、最小尺寸按离站点距离定）。
#   尺寸分档：第 b 档 D ∈ [0.05·2^b, 0.1·2^b)，b = 0..5；每档按 512·D_b 边长分区块，区块按 (档, 格号) 播种 → 同一处每次一样。
#   数目：Golombek & Rapp 1997，F(D) = k·e^(−qD)（同 57 golombek_n），各地类 k 来自 57 的近景定标；地类权重取 1 m 地类表（地貌.gd）。
#   只补数据分辨不出的：D < 2.5 × 该处高程分辨率（地貌.gd dem_l），所以 Navcam 近区不撒（那里的石块是实测网格）。
#   远近：区块按最近点的屏幕直径定级（同 实景.gd RK_PX），小于 1.5 像素的档整块不要；生成在后台线程，近的先做，每次有时间预算。
#   石块高度：地形LOD.h_cpu（数据层 + 地貌印章），埋入四分之一（同 61）。
extends RefCounted

const D0 := 0.05
const NB := 6
const TILE := 512.0                                            # 区块边长 = TILE·D_b
var PX_MIN := 3.0                                              # --撒石像素=
const CACHE_MAX := 6000

var lod: Node3D; var geo: RefCounted; var host: Node3D          # host：实景.gd（enu_basis、hash01）
var px: Array = [48.0, 12.0, 1.0]                              # 同 实景.gd RK_PX
var k_cls: Array = []; var nm := 1; var base := Color(0.24, 0.17, 0.13)
var yr: Array = []                                            # 每种单位石块网格的 [y 最低, y 最高]（原点不在底面：中位 −0.4 … 0.95）
var N := []                                                    # N[b][c]：每 m² 个数
var Dt := []; var Ct := []                                     # Dt[b][c]、Ct[b][c]：按数目分布的 D 抽样表（D、累计比例）
var Nmax := []
var cache := {}                                                # Vector3i(b, i, j) → {类型: PackedFloat32Array（每块 16 个数）}
# 注意：PackedArray 是值类型，放在 Array / Dictionary 里时 a[i].append(…) 改的是副本 → 先用 Array 攒，最后一次性转
var pending := false                                           # 上次没做完（时间预算到了）
var n_gen := 0; var n_tiles := 0; var n_rocks := 0; var n_band := []; var n_lv := []


func setup(host_: Node3D, lod_: Node3D, geo_: RefCounted, J: Dictionary, nm_: int, base_: Color, yr_: Array) -> void:
	host = host_; lod = lod_; geo = geo_; nm = nm_; base = base_; yr = yr_
	k_cls = J["geo"]["k_cls"]
	PX_MIN = float(host.args.get("撒石像素", "3"))
	for b in NB:
		var d1 := D0*pow(2.0, b); var d2 := 2.0*d1
		var nb := []; var db := []; var cb := []; var mx := 0.0
		for c in 4:
			var t := golombek_n(k_cls[c], d1, d2)
			nb.append(t[0]); db.append(t[1]); cb.append(t[2]); mx = maxf(mx, t[0])
		N.append(nb); Dt.append(db); Ct.append(cb); Nmax.append(mx)
	print("[撒石] 实时：%d 档 %.2f–%.2f m，每 m² 最多 %s 块" % [NB, D0, D0*pow(2.0, NB), str(Nmax.map(func(x): return snappedf(x, 0.0001)))])


static func golombek_n(k: float, d1: float, d2: float, nD := 40) -> Array:
	var q := 1.79 + 0.152/maxf(k, 1e-4)
	var D := PackedFloat32Array(); var nd := PackedFloat32Array()
	for i in nD:
		var d := d1*pow(d2/d1, float(i)/(nD - 1)); D.append(d)
		nd.append(k*q*exp(-q*d)/(PI*d*d/4.0))
	var cdf := PackedFloat32Array([0.0])
	for i in range(1, nD): cdf.append(cdf[i - 1] + 0.5*(nd[i] + nd[i - 1])*(D[i] - D[i - 1]))
	var tot := cdf[nD - 1]
	for i in nD: cdf[i] /= maxf(tot, 1e-12)
	return [tot, D, cdf]


static func inv_cdf(D: PackedFloat32Array, cdf: PackedFloat32Array, u: float) -> float:
	var i := cdf.bsearch(u)
	if i <= 0: return D[0]
	if i >= cdf.size(): return D[D.size() - 1]
	var t := (u - cdf[i - 1])/maxf(cdf[i] - cdf[i - 1], 1e-12)
	return lerpf(D[i - 1], D[i], t)


static func poisson(rng: RandomNumberGenerator, lam: float) -> int:
	if lam > 40.0: return maxi(0, roundi(rng.randfn(lam, sqrt(lam))))
	var L := exp(-lam); var k := 0; var p := 1.0
	while true:
		p *= rng.randf()
		if p <= L: return k
		k += 1
	return k


func gen_tile(b: int, ti: int, tj: int) -> Dictionary:
	var T := TILE*D0*pow(2.0, b)
	var rng := RandomNumberGenerator.new()
	rng.seed = geo.ih(geo.ih(b*0x3c6ef372 + 7) ^ geo.ih(((ti & geo.M32)*0x27d4eb2d) & geo.M32) ^ ((tj & geo.M32)*0x165667b1 & geo.M32))
	var out := {}
	var cnt := poisson(rng, Nmax[b]*T*T)
	for _n in cnt:
		var x := (ti + rng.randf())*T; var z := (tj + rng.randf())*T
		var u1 := rng.randf(); var u2 := rng.randf(); var u3 := rng.randf(); var u4 := rng.randf()
		var dl: float = geo.dem_l(x, z)
		if dl <= -4.5: continue                                    # 近区：一定不撒，省掉地类查表
		var w: Array = geo.W(x, z)
		var nc := [w[0]*N[b][0], w[1]*N[b][1], w[2]*N[b][2], w[3]*N[b][3]]
		var ns: float = nc[0] + nc[1] + nc[2] + nc[3]
		if u1*Nmax[b] >= ns: continue                              # 稀疏化：该处的密度 / 本档最大密度
		var c := 0; var acc: float = nc[0]; var pick := u2*ns
		while c < 3 and pick > acc: c += 1; acc += nc[c]
		var D := inv_cdf(Dt[b][c], Ct[b][c], u3)
		if u4 >= clampf(dl + 1.321928 - log(D)/log(2.0), 0.0, 1.0): continue   # D < 2.5·分辨率才补
		var sd := float(rng.randi() & 0x3FFFFFFF)
		var asp := rng.randf_range(0.35, 0.7)
		var ty := int(fposmod(sd, nm))
		var sz: float = D*asp/maxf(yr[ty][1] - yr[ty][0], 0.05)          # 整块高 = D·高宽比，埋入四分之一（按网格实际上下沿）
		var y: float = lod.h_cpu(x, z, 0) - yr[ty][0]*sz - 0.25*D*asp
		var B: Basis = host.enu_basis((host.hash01(sd, 1.0) - 0.5)*0.7, (host.hash01(sd, 2.0) - 0.5)*0.7, rng.randf()*TAU, D, D, sz)
		var r: float = host.hash01(sd, 3.1)
		var col := Color(base.r*lerpf(0.75, 1.2, r), base.g*lerpf(0.75, 1.15, r), base.b*lerpf(0.75, 1.1, r), lerpf(0.4, 1.0, host.hash01(sd, 5.3)))   # alpha：积尘程度
		if not out.has(ty): out[ty] = []
		out[ty].append_array([B.x.x, B.y.x, B.z.x, x, B.x.y, B.y.y, B.z.y, y, B.x.z, B.y.z, B.z.z, z, col.r, col.g, col.b, col.a])
	var packed := {}
	for ty in out: packed[ty] = PackedFloat32Array(out[ty])
	return packed


func lv(s: float) -> int:
	return 0 if s > px[0] else (1 if s > px[1] else 2)


func collect(cam: Vector3, pa: float, lists: Array, budget_ms: float) -> void:
	"""把看得见的区块按级放进 lists[类型][级]（Array，元素是区块的 PackedFloat32Array，调用方再拼）。
	没生成的区块近的先做，超出预算的留到下次（pending）。"""
	var t0 := Time.get_ticks_usec()
	var agl := maxf(cam.y - lod.h_cpu(cam.x, cam.z, 0), 0.0)        # 相机离地高：远处区块的距离按它算
	pending = false; var nt := 0; var nr := 0; var nb := [0, 0, 0, 0, 0, 0]; var nl := [0, 0, 0]
	var todo := []
	for b in NB:
		var Dm := 1.4142*D0*pow(2.0, b)
		var T := TILE*D0*pow(2.0, b)
		var r := Dm/(PX_MIN*pa)
		if r <= agl: continue
		var rh := sqrt(r*r - agl*agl)
		for tj in range(floori((cam.z - rh)/T), floori((cam.z + rh)/T) + 1):
			for ti in range(floori((cam.x - rh)/T), floori((cam.x + rh)/T) + 1):
				var dx := maxf(maxf(ti*T - cam.x, cam.x - (ti + 1)*T), 0.0); var dz := maxf(maxf(tj*T - cam.z, cam.z - (tj + 1)*T), 0.0)
				var dn := sqrt(dx*dx + dz*dz + agl*agl)
				if dn > r: continue
				var fx := maxf(absf(ti*T - cam.x), absf(cam.x - (ti + 1)*T)); var fz := maxf(absf(tj*T - cam.z), absf(cam.z - (tj + 1)*T))
				var df := sqrt(fx*fx + fz*fz + agl*agl)
				var l := lv(Dm/(maxf(dn, 0.01)*pa))
				if lv(Dm/(df*pa)) != l or (l == 2 and Dm/(df*pa) < PX_MIN): l = -1   # 区块跨级（或跨可见边界）：逐块定级
				todo.append([dn, Vector3i(b, ti, tj), l])
	todo.sort_custom(func(a, c): return a[0] < c[0])
	for t in todo:
		var key: Vector3i = t[1]
		if not cache.has(key):
			if budget_ms > 0.0 and (Time.get_ticks_usec() - t0) > budget_ms*1000.0: pending = true; continue
			cache[key] = gen_tile(key.x, key.y, key.z); n_gen += 1
		var tile: Dictionary = cache[key]; var l: int = t[2]
		if l >= 0:
			for ty in tile:
				lists[ty][l].append(tile[ty]); nr += tile[ty].size()/16; nb[key.x] += tile[ty].size()/16; nl[l] += tile[ty].size()/16
		else:
			for ty in tile:
				var buf: PackedFloat32Array = tile[ty]
				var o := [PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array()]
				for q in range(0, buf.size(), 16):
					var Dk := Vector3(buf[q], buf[q + 4], buf[q + 8]).length()
					var sk := Dk/(maxf(cam.distance_to(Vector3(buf[q + 3], buf[q + 7], buf[q + 11])), 0.01)*pa)
					if sk < PX_MIN: continue
					var a: PackedFloat32Array = o[lv(sk)]; o[lv(sk)] = PackedFloat32Array()   # 先拿走引用，原地追加
					a.append_array(buf.slice(q, q + 16)); o[lv(sk)] = a; nr += 1; nb[key.x] += 1; nl[lv(sk)] += 1
				for k in 3:
					if o[k].size(): lists[ty][k].append(o[k])
		nt += 1
	n_tiles = nt; n_rocks = nr; n_band = nb; n_lv = nl
	if cache.size() > CACHE_MAX:                                     # 丢掉最远的一半
		var keep := {}
		for t in todo: if cache.has(t[1]): keep[t[1]] = cache[t[1]]
		cache = keep


func stats(x0: float, z0: float, rad: float) -> String:
	"""诊断（--撒石统计=E,N）：以 (x0, z0) 为心、rad 米内每档实际撒了多少块，和地类算的期望比。"""
	var out := ""
	var w: Array = geo.W(x0, z0)
	for b in NB:
		var T := TILE*D0*pow(2.0, b); var n := 0
		for tj in range(floori((z0 - rad)/T), floori((z0 + rad)/T) + 1):
			for ti in range(floori((x0 - rad)/T), floori((x0 + rad)/T) + 1):
				var tile := gen_tile(b, ti, tj)
				for ty in tile:
					var buf: PackedFloat32Array = tile[ty]
					for q in range(0, buf.size(), 16):
						if Vector2(buf[q + 3] - x0, buf[q + 11] - z0).length() < rad: n += 1
		var exp_n: float = (w[0]*N[b][0] + w[1]*N[b][1] + w[2]*N[b][2] + w[3]*N[b][3])*PI*rad*rad
		out += " 档%d %d/期望%.0f" % [b, n, exp_n]
	return "W=%s%s" % [str(w.map(func(v): return snappedf(v, 0.01))), out]
