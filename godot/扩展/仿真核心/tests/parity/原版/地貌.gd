# 地貌印章的 CPU 版（实景地形系统.md §14）：和 着色器/地貌.gdshaderinc 逐位对应（同一个整数哈希、同一张 1 m 地类表），
# 地面包围盒、车轮接地、撒石取高都走 地形LOD.h_cpu → 这里，地面画出来的坑和沙纹与车、石块对得上。改一边必须同样改另一边。
# 参数：默认值是占位，资料/地貌参数/地貌参数.json（标定结果）存在就用它；命令行 --地貌=0 关。
extends RefCounted

const M32 := 0xFFFFFFFF
const W0 := [0.35, 0.35, 0.2, 0.1]

var on := 1.0
var cls := PackedByteArray(); var cN := 2000; var c_half := 1000.0; var c_cs := 1.0
var C := 0.003; var b := 2.0; var dD_fresh := 0.2; var dD_old := 0.06; var rim := 0.04; var fill := 0.5
var cr_cls := [1.0, 1.0, 1.0, 1.0]
var rp: Array = []                                              # 每组 [λ, 峰谷高, 法向 x, 法向 z, 背风占比, 弯曲度]
var tex: ImageTexture


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
	print("[地貌] 撞击坑 N(>D)=%s·D^-%.2f，d/D %.2f–%.2f；沙纹 %d 组 %s" % [str(snappedf(C, 0.00001)), b, dD_fresh, dD_old, rp.size(), str(rp.map(func(e): return "λ%.2f/%.2f m" % [e[0], e[1]]))])


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


func h(x: float, z: float) -> float:
	if on <= 0.0: return 0.0
	var dl := dem_l(x, z)
	if dl <= -3.0: return 0.0
	var w := W(x, z)
	return on*(craters(x, z, dl, w) + ripples(x, z, dem_l(x, z, 3.0), w))


func margin(e: float) -> float:
	"""包围盒余量：该处会出现的最大坑深 + 沙纹半高（9×9 采样之间可能漏掉）。"""
	if on <= 0.0: return 0.0
	var dl := dem_l(e, 0.0)
	if dl <= -3.0: return 0.0
	var dmax := minf(pow(2.0, dl + 2.0), 32.0)*2.0
	var a := 0.0
	for r in rp: a += r[1]*0.5
	return on*(dD_fresh*dmax + a)
