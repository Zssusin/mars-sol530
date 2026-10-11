# 地貌印章的 CPU 版（实景地形系统.md §14）：和 着色器/地貌.gdshaderinc 逐位对应（同一个整数哈希、同一张 1 m 地类表），
# 地面包围盒、车轮接地、撒石取高都走 地形LOD.h_cpu → 这里，地面画出来的坑和沙纹与车、石块对得上。改一边必须同样改另一边。
# 参数：默认值是占位，资料/地貌参数/地貌参数.json（标定结果）存在就用它；命令行 --地貌=0 关。
# 米级沙纹（λ 1–5 m）默认用 HiRISE 实测沙纹场（80_沙纹场.py → ripple_field.bin，docs/地面材质/沙纹.md）：
# --沙纹=新（默认）实测场；--沙纹=旧 回到程序化 λ 2.7 m 一组；--沙纹=0 两者都关（TAR、冲击波纹照旧）。
extends RefCounted

const M32 := 0xFFFFFFFF
const W0 := [0.35, 0.35, 0.2, 0.1]

var on := 1.0
var cls := PackedByteArray(); var cN := 2000; var c_half := 1000.0; var c_cs := 1.0
var C := 0.003; var b := 2.0; var dD_fresh := 0.2; var dD_old := 0.06; var rim := 0.04; var fill := 0.5
var cr_cls := [1.0, 1.0, 1.0, 1.0]
var rp: Array = []                                              # 每组 [λ, 峰谷高, 法向 x, 法向 z, 背风占比, 弯曲度]
var tex: ImageTexture
var rmode := "新"                                               # 沙纹场：新 / 旧 / 0
var rf_on := 0.0; var rf := PackedByteArray(); var rf_N := 1000; var rf_half := 1000.0; var rf_cell := 2.0
var rf_H := 0.0; var rf_lee := 0.3; var rf_rho0 := 0.15; var rf_rho1 := 0.6; var rf_lo := 1.0; var rf_hi := 5.0
var rf_tex: ImageTexture
var rf_cov: ImageTexture
var rf_st: ImageTexture
var rf_alb := 0.16                                             # 反照率条纹幅度（±比例 × 振幅权重）；--沙纹条纹=0 关。默认值的依据见 沙纹.md §6


func setup(J: Dictionary, D: String, args: Dictionary, params_file: String) -> void:
	on = float(args.get("地貌", "1"))
	var G: Dictionary = J["geo"]
	cN = int(G["N"]); c_half = float(G["half"]); c_cs = 2.0*c_half/cN
	cls = FileAccess.get_file_as_bytes(D + G["file"])
	tex = ImageTexture.create_from_image(Image.create_from_data(cN, cN, false, Image.FORMAT_RGBA8, cls))
	rp = [[1.6, 0.10, 0.0, 0.0, 0.3, 0.25]]                         # 占位：等标定
	_dir(rp[0], 90.0)
	if FileAccess.file_exists(params_file):
		var P: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(params_file))
		var c: Dictionary = P["craters"]
		C = c["C"]; b = c["b"]; dD_fresh = c["dD_fresh"]; dD_old = c["dD_degraded"]; rim = c["rim_frac"]; fill = c["fill"]
		cr_cls = c.get("class_factor", cr_cls)
		rp = []
		for r in P["ripples"]:
			if r.get("class", "沙") != "沙" or float(r["lambda"]) <= 0.0: continue
			var e := [float(r["lambda"]), float(r["amp"]), 0.0, 0.0, float(r.get("lee_frac", 0.3)), float(r.get("sinuosity", 0.2))]
			_dir(e, float(r["az_deg"])); rp.append(e)
			if rp.size() == 3: break
		print("[地貌] 参数：%s" % params_file)
	rmode = String(args.get("沙纹", "新"))
	if rmode != "旧":                                              # 米级一组（λ 1–5 m）交给实测场（或关掉）
		rp = rp.filter(func(e): return not (e[0] > 1.0 and e[0] < 5.0))
	if rmode == "新" and FileAccess.file_exists(D + "ripple_field.json"):
		var R: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(D + "ripple_field.json"))
		var bb := FileAccess.get_file_as_bytes(D + String(R["file"]))
		rf_N = int(R["N"]); rf_half = float(R["half"]); rf_cell = float(R["cell"]); rf_H = float(R["H"]); rf_lee = float(R["lee"])
		if args.has("沙纹条纹"): rf_alb = float(args["沙纹条纹"])
		if args.has("沙纹高"): rf_H = float(args["沙纹高"])            # 诊断：覆盖实测波高（峰谷，m）
		rf_rho0 = float(R["rho"][0]); rf_rho1 = float(R["rho"][1]); rf_lo = float(R["lam_lo"]); rf_hi = float(R["lam_hi"])
		if bb.size() > 16 and bb.decode_u32(0) == 0x32465052:          # "RPF2"：头 16 字节 + zlib
			rf = bb.slice(16).decompress(rf_N*rf_N*4, FileAccess.COMPRESSION_DEFLATE)
		if rf.size() == rf_N*rf_N*4:
			rf_tex = ImageTexture.create_from_image(Image.create_from_data(rf_N, rf_N, false, Image.FORMAT_RGBA8, rf)); rf_on = 1.0
			var nb := rf_N/4; var cv := PackedByteArray(); cv.resize(nb*nb)          # 覆盖块（4×4 格）：0 = 没有沙纹，否则 = 块内最大 λ 字节 + 1；着色器据此早退，不影响结果
			for j in rf_N:
				var row := rf.slice(j*rf_N*4, (j + 1)*rf_N*4)
				for i in rf_N:
					if row[i*4 + 3] > 0:
						var bi := (j >> 2)*nb + (i >> 2)
						cv[bi] = maxi(cv[bi], mini(row[i*4 + 1] + 1, 255))      # 块内最大 λ 字节 + 1（着色器早退的 λ 上界）
			rf_cov = ImageTexture.create_from_image(Image.create_from_data(nb, nb, false, Image.FORMAT_R8, cv))
			var sp := D + "ripple_stripe.bin"                                               # 反照率条纹贴图（R8，mip）
			if FileAccess.file_exists(sp):
				var sb := FileAccess.get_file_as_bytes(sp); var sn := sb.decode_s32(4)
				var si := Image.create_from_data(sn, sn, false, Image.FORMAT_R8, sb.slice(16).decompress(sn*sn, FileAccess.COMPRESSION_DEFLATE))
				si.generate_mipmaps(); rf_st = ImageTexture.create_from_image(si)
			print("[地貌] 沙纹场：%s，%d² × %.1f m，H %.3f m，背风占比 %.2f" % [R["file"], rf_N, rf_cell, rf_H, rf_lee])
		else:
			push_error("ripple_field.bin 格式不对（%d 字节），不用沙纹场" % bb.size()); rf = PackedByteArray()
	print("[地貌] 撞击坑 N(>D)=%s·D^-%.2f，d/D %.2f–%.2f；沙纹 %d 组 %s" % [str(snappedf(C, 0.00001)), b, dD_fresh, dD_old, rp.size(), str(rp.map(func(e): return "λ%.2f/%.3f m" % [e[0], e[1]]))])


func _dir(e: Array, az_deg: float) -> void:
	var a := deg_to_rad(az_deg)                                    # 方位角自北顺时针 → ENU (sin, cos) → Godot (E, −N)
	e[2] = sin(a); e[3] = -cos(a)


func apply(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter("geo_on", on)
	mat.set_shader_parameter("geo_class", tex); mat.set_shader_parameter("geo_half", c_half)
	mat.set_shader_parameter("geo_cr", Vector4(C, b, dD_fresh, dD_old)); mat.set_shader_parameter("geo_cr2", Vector4(rim, fill, 0, 0))
	mat.set_shader_parameter("geo_cr_cls", Vector4(cr_cls[0], cr_cls[1], cr_cls[2], cr_cls[3]))
	var a: Array[Vector4] = []; var a2: Array[Vector4] = []
	for e in rp: a.append(Vector4(e[0], e[1], e[2], e[3])); a2.append(Vector4(e[4], e[5], 0, 0))
	while a.size() < 3: a.append(Vector4(1, 0, 1, 0)); a2.append(Vector4(0.3, 0, 0, 0))
	mat.set_shader_parameter("geo_rp", a); mat.set_shader_parameter("geo_rp2", a2); mat.set_shader_parameter("geo_rp_n", rp.size())
	mat.set_shader_parameter("geo_rf_on", rf_on)
	if rf_on > 0.0:
		mat.set_shader_parameter("geo_rf", rf_tex); mat.set_shader_parameter("geo_rf_cov", rf_cov); if rf_st != null: mat.set_shader_parameter("geo_rf_st", rf_st)
		mat.set_shader_parameter("geo_rf_alb", rf_alb if rf_st != null else 0.0); mat.set_shader_parameter("geo_rf_n", rf_N)
		mat.set_shader_parameter("geo_rf_g", Vector4(rf_half, rf_cell, rf_lo, rf_hi)); mat.set_shader_parameter("geo_rf_p", Vector4(rf_H, rf_lee, rf_rho0, rf_rho1))


# ———— 和着色器一一对应
static func s_(e: float, h: float) -> float:
	return smoothstep(0.92*h, h, e)


func dem_l(x: float, z: float, l_hirise := 0.0) -> float:
	var e := maxf(absf(x), absf(z))
	var l := -5.643856
	l = lerpf(l, -3.321928, s_(e, 10.0)); l = lerpf(l, l_hirise, s_(e, 50.0)); l = lerpf(l, 4.321928, s_(e, 1000.0))
	return l


func W(x: float, z: float) -> Array:
	"""地类权重（沙、砾石、基岩、暗岩），1 m 表双线性，同 GPU 采样（像素中心在 (i + 0.5)·格）。"""
	var fx := clampf((x + c_half)/c_cs - 0.5, 0.0, cN - 1.001); var fz := clampf((z + c_half)/c_cs - 0.5, 0.0, cN - 1.001)
	var i := int(fx); var j := int(fz); var tx := fx - i; var tz := fz - j
	var o := (j*cN + i)*4; var r := [0.0, 0.0, 0.0, 0.0]
	var t := s_(maxf(absf(x), absf(z)), c_half)
	for ch in 4:
		var v := lerpf(lerpf(cls[o + ch], cls[o + 4 + ch], tx), lerpf(cls[o + cN*4 + ch], cls[o + cN*4 + 4 + ch], tx), tz)/255.0
		r[ch] = lerpf(v, W0[ch], t)
	return r


static func ih(x: int) -> int:
	x &= M32
	x ^= x >> 16; x = (x*0x7feb352d) & M32
	x ^= x >> 15; x = (x*0x5bd1e995) & M32
	x ^= x >> 16
	return x


static func u(h: int) -> float:
	return float(h >> 8)/16777216.0


func craters(x: float, z: float, dl: float, w: Array) -> float:
	var acc := 0.0; var nb := 1.0 - pow(2.0, -b)
	var cf: float = (w[0]*cr_cls[0] + w[1]*cr_cls[1] + w[2]*cr_cls[2] + w[3]*cr_cls[3])/maxf(w[0] + w[1] + w[2] + w[3], 1e-4)
	for o in 7:
		var Do := 0.5*pow(2.0, o)
		var k := clampf(dl + 2.0 - log(Do)/log(2.0), 0.0, 1.0)
		if k <= 0.0: continue
		var Cs := 4.0*Do
		var p: float = C*pow(Do, -b)*nb*Cs*Cs*cf
		var i0 := floori(x/Cs - 0.5); var j0 := floori(z/Cs - 0.5)
		for j in 2:
			for i in 2:
				var ci := i0 + i; var cj := j0 + j
				var h := ih((((ci & M32)*0x27d4eb2d) & M32) ^ ih(((cj & M32) + o*0x165667b1) & M32))
				if u(h) >= p: continue
				var cx := (ci + u(ih(h ^ 1)))*Cs; var cz := (cj + u(ih(h ^ 2)))*Cs
				var Dm := Do*pow(1.0 - u(ih(h ^ 3))*nb, -1.0/b)
				var R := 0.5*Dm
				var r := Vector2(x - cx, z - cz).length()
				if r >= 2.0*R: continue
				var deg := sqrt(u(ih(h ^ 4)))
				var dp := Dm*lerpf(dD_fresh, dD_old, deg); var hr := Dm*rim*(1.0 - deg)
				var xr := r/R; var hg: float
				if xr < 1.0:
					hg = maxf((dp + hr)*xr*xr - dp, -dp*(1.0 - fill*deg))
				else:
					var s := clampf((xr - 1.4)/0.6, 0.0, 1.0)
					hg = hr/(xr*xr*xr)*(1.0 - s*s*(3.0 - 2.0*s))
				acc += k*hg
	return acc


func ripples(x: float, z: float, dl: float, w: Array) -> float:
	var ws := smoothstep(0.3, 0.7, w[0])
	if ws <= 0.0: return 0.0
	var acc := 0.0
	for e in rp:
		var lam: float = e[0]
		var k := ws*clampf(dl + 1.321928 - log(lam)/log(2.0), 0.0, 1.0)
		if k <= 0.0: continue
		var dx: float = e[2]; var dz: float = e[3]
		var px := -dz; var pz := dx; var qx := px*0.8 + dx*0.6; var qz := pz*0.8 + dz*0.6
		var s1 := TAU*fposmod((x*px + z*pz)/(5.3*lam), 1.0); var s2 := TAU*fposmod((x*qx + z*qz)/(11.7*lam), 1.0)
		var s3 := TAU*fposmod((x*px + z*pz)/(7.1*lam), 1.0)
		var ph: float = (x*dx + z*dz)/lam + e[5]*(sin(s1) + 0.5*sin(s2))
		var am: float = e[1]*(0.75 + 0.25*sin(s3))
		var t := fposmod(ph, 1.0); var Lf: float = e[4]; var f: float
		if t < 1.0 - Lf: f = pow(sin(PI/2*t/(1.0 - Lf)), 2)
		else: f = pow(cos(PI/2*(t - 1.0 + Lf)/Lf), 2)
		acc += k*am*(f - 0.5)
	return acc


func rfield(x: float, z: float, dl: float) -> float:
	"""实测沙纹场（着色器 geo_rfield 的高度部分）：4 格平面波相量相加，取相位套不对称剖面，相干度低处（分叉、断头）渐隐。"""
	if rf_on <= 0.0: return 0.0
	var fx := (x + rf_half)/rf_cell - 0.5; var fz := (z + rf_half)/rf_cell - 0.5
	var i0 := floori(fx); var j0 := floori(fz); var tx := fx - i0; var tz := fz - j0
	var zr := 0.0; var zi := 0.0; var As := 0.0; var Ls := 0.0
	for dj in 2:
		for di in 2:
			var i := clampi(i0 + di, 0, rf_N - 1); var j := clampi(j0 + dj, 0, rf_N - 1)
			var o := (j*rf_N + i)*4
			var a: float = rf[o + 3]/255.0
			if a <= 0.0: continue
			var w: float = (tx if di == 1 else 1.0 - tx)*(tz if dj == 1 else 1.0 - tz)
			var az: float = rf[o]*(TAU/256.0); var lam: float = rf_lo*pow(rf_hi/rf_lo, rf[o + 1]/255.0); var ph: float = rf[o + 2]*(TAU/256.0)
			var cx := -rf_half + (i + 0.5)*rf_cell; var cz := -rf_half + (j + 0.5)*rf_cell
			var psi := ph + TAU/lam*(sin(az)*(x - cx) - cos(az)*(z - cz))
			zr += w*a*cos(psi); zi += w*a*sin(psi); As += w*a; Ls += w*a*log(lam)
	if As <= 1e-6: return 0.0
	var lm := exp(Ls/As)
	var k := clampf(dl + 1.321928 - log(lm)/log(2.0), 0.0, 1.0)*(1.0 - s_(maxf(absf(x), absf(z)), rf_half))
	if k <= 0.0: return 0.0
	var rho := sqrt(zr*zr + zi*zi)/As
	var g := smoothstep(rf_rho0, rf_rho1, rho)
	var t := fposmod(atan2(zi, zr)/TAU + 1.0 - rf_lee, 1.0); var f: float
	if t < 1.0 - rf_lee: f = pow(sin(PI/2*t/(1.0 - rf_lee)), 2)
	else: f = pow(cos(PI/2*(t - 1.0 + rf_lee)/rf_lee), 2)
	return k*rf_H*As*g*(f - 0.5)


func h(x: float, z: float) -> float:
	if on <= 0.0: return 0.0
	var dl := dem_l(x, z)
	if dl <= -3.0: return 0.0
	var w := W(x, z)
	var dl3 := dem_l(x, z, 3.0)
	return on*(craters(x, z, dl, w) + ripples(x, z, dl3, w) + rfield(x, z, dl3))


func margin(e: float) -> float:
	"""包围盒余量：该处会出现的最大坑深 + 沙纹半高（9×9 采样之间可能漏掉）。"""
	if on <= 0.0: return 0.0
	var dl := dem_l(e, 0.0)
	if dl <= -3.0: return 0.0
	var dmax := minf(pow(2.0, dl + 2.0), 32.0)*2.0
	var a := 0.0
	for r in rp: a += r[1]*0.5
	a += rf_H*0.5*rf_on
	return on*(dD_fresh*dmax + a)
