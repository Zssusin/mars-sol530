# 地面材质（阶段 1 B 步，docs/地面材质/阶段1.md §9）：读 73 导出的 mat.json、控制图、位移门、纹理数组（DDS），设地形着色器的 uniform；
# 另存一份 CPU 数据给中观位移的 CPU 版（h_cpu）：控制图、门、每层一级 mip 的 R16 高度。
# disp() 是 着色器/材质.gdshaderinc mat_disp(…, cpu_mip = true) 的逐行移植（C++ 扩展有同样的 terrain::MatDisp，装了扩展走 C++）。
# 改着色器里位移那条路时必须同样改这里和 扩展/仿真核心/core/terrain_core.cpp。
# 路径：全部相对 D = 环境.数据目录() = 环境.外置("数据/sol0530/")（实景.gd 传进来）。DDS 在带 .gdignore 的 材质/ 里，导出器扫不到，
#   所以不能走 资源目录()；导出包里它们由 导出.sh 照原样复制到 data/数据/sol0530/材质/，load() 直接读绝对路径（引擎 DDS 加载器）。
extends RefCounted

const M32 := 0xFFFFFFFF
const MAXM := 16

var ok := false
var M: Dictionary                                  # mat.json
var nmat := 0
# —— CPU 位移（configure_mat 读这些属性）
var gain := 1.0                                    # = 着色器 disp_gain（--位移）；0 = 不算位移
var ctrl_n := PackedByteArray(); var nN := 0       # 控制图：int32 宽高 + RGBA8（文件原样，偏移 8 起）
var ctrl_f := PackedByteArray(); var nF := 0
var gate := PackedByteArray(); var nG := 0          # 位移门：int32 宽高 + R8
var grid := [50.0, 0.04, 1000.0, 1.0]
var out_id := [0, 2, 3, -1]; var out_w := [0.6, 0.3, 0.1, 0.0]
var h16 := PackedByteArray()                       # 每层一级 mip（小端 u16），按层接起来
var lay_off := PackedInt32Array(); var lay_n := PackedInt32Array()   # 每层在 h16 里的起点（u16 个数）、边长
var lay_lohi := PackedFloat32Array()                # 每层混合高度 lo、hi（米）
var me := PackedFloat32Array()                      # 每材质 4 个：起始层、变体数、边长、量程
var bl := PackedFloat32Array()                      # 每材质 4 个：对比、偏置、粗糙度、旋转
var hexp := [0.45, 7.0, 0.6, 0.1]                   # 中观 hex 格距 m、权重指数、高度权、混合锐度
var hexmi := 0.06
var k := 3
var fmt := 0                                        # 控制图格式：0 = 旧 3 槽，4 = 中景版 4 槽（mat_fmt）
var tab_file := "mat.json"
var cpu_cell := 0.01
var mip_of := PackedInt32Array()                    # 每材质 CPU 用哪级 mip


func setup(D: String, args: Dictionary, mat: ShaderMaterial) -> bool:
	# --中景=0：回到现行 8 类数据（mat.json）；默认 1：中景版 14 类（mat2.json，4 槽控制图、逐材质增益；没有数据时退回 mat.json）
	tab_file = "mat2.json" if args.get("中景", "1") != "0" and FileAccess.file_exists(D + "mat2.json") else "mat.json"
	if not FileAccess.file_exists(D + tab_file):
		push_warning("[材质] 没有 %s（跑 scripts/Godot/73_材质规则.py 全部），退回旧材质" % tab_file); return false
	var t0 := Time.get_ticks_msec()
	M = JSON.parse_string(FileAccess.get_file_as_string(D + tab_file))
	var R: Dictionary = M.get("运行时", {})
	var C: Dictionary = R.get("控制图", {})
	nmat = M["材质"].size()
	if nmat > MAXM: push_error("[材质] 材质 %d 种 > %d" % [nmat, MAXM]); return false
	var fn: String = C.get("近", {}).get("file", "mat_ctrl_4cm.bin"); var ff: String = C.get("远", {}).get("file", "mat_ctrl_1m.bin")
	var fg: String = C.get("门", "mat_gate_4cm.bin")
	for f in [fn, ff, fg]:
		if not FileAccess.file_exists(D + f): push_warning("[材质] 缺 %s，退回旧材质" % f); return false
	fmt = int(C.get("格式", 0))
	mat.set_shader_parameter("mat_fmt", fmt)
	if C.has("近"): grid = [float(C["近"]["half"]), float(C["近"]["cs"]), float(C["远"]["half"]), float(C["远"]["cs"])]
	ctrl_n = FileAccess.get_file_as_bytes(D + fn); nN = ctrl_n.decode_s32(0)
	ctrl_f = FileAccess.get_file_as_bytes(D + ff); nF = ctrl_f.decode_s32(0)
	gate = FileAccess.get_file_as_bytes(D + fg); nG = gate.decode_s32(0)
	mat.set_shader_parameter("mat_ctrl_n", ImageTexture.create_from_image(Image.create_from_data(nN, nN, false, Image.FORMAT_RGBA8, ctrl_n.slice(8))))
	mat.set_shader_parameter("mat_ctrl_f", ImageTexture.create_from_image(Image.create_from_data(nF, nF, false, Image.FORMAT_RGBA8, ctrl_f.slice(8))))
	mat.set_shader_parameter("mat_gate", ImageTexture.create_from_image(Image.create_from_data(nG, nG, false, Image.FORMAT_R8, gate.slice(8))))
	mat.set_shader_parameter("mat_grid", Vector4(grid[0], grid[1], grid[2], grid[3]))
	# 图外配比
	var ids := {}
	for i in nmat: ids[M["材质"][i]["id"]] = i
	var ow: Dictionary = C.get("图外", {"M1": 0.6, "M3": 0.3, "M4": 0.1})
	out_id = [-1, -1, -1, -1]; out_w = [0.0, 0.0, 0.0, 0.0]; var j := 0
	for key in ow:
		if ids.has(key) and j < 4: out_id[j] = ids[key]; out_w[j] = float(ow[key]); j += 1
	mat.set_shader_parameter("mat_out_id", Vector4i(out_id[0], out_id[1], out_id[2], out_id[3]))
	mat.set_shader_parameter("mat_out_w", Vector4(out_w[0], out_w[1], out_w[2], out_w[3]))
	# 纹理数组（DDS，引擎 DDS 加载器直接给 Texture2DArray）
	var A: Dictionary = M["数组"]
	for key in ["mat_meso_ah", "mat_meso_d", "mat_meso_h16", "mat_micro_ah", "mat_micro_d"]:
		var p: String = D + A[key]["file"]                             # D = 环境.外置("数据/sol0530/")：编辑器 res://…，导出包 data/…
		var tex = load(p)
		if not (tex is Texture2DArray): push_error("[材质] %s 读不成 Texture2DArray：%s" % [p, str(tex)]); return false
		mat.set_shader_parameter(key, tex)
	# 每材质参数
	var hb := PackedFloat32Array(); hb.resize(80*2)                 # 每层 lo、hi
	me.resize(nmat*4); bl.resize(nmat*4)
	var vme: Array[Vector4] = []; var vmi: Array[Vector4] = []; var vbl: Array[Vector4] = []
	var nl := 0
	for i in nmat:
		var e: Dictionary = M["材质"][i]; var a: Dictionary = e["中观"]; var b: Dictionary = e["微观"]
		vme.append(Vector4(a["起始层"], a["变体数"], a["尺寸"], a["量程"]))
		vmi.append(Vector4(b["起始层"], b["变体数"], b["尺寸"], b["量程"]))
		var rg: float = e.get("粗糙度", 0.8) if args.get("材质粗糙", "1") == "1" else 0.8   # --材质粗糙=0：全部 0.8（诊断）
		if args.has("粗糙幅"): rg = 0.8 + float(args["粗糙幅"])*(rg - float(args.get("粗糙心", "0.85")))   # 诊断：围绕 粗糙心 缩放后平移到 0.8
		vbl.append(Vector4(e.get("对比", 1.0), e.get("偏置", 0.0), rg, 1.0 if e.get("旋转", true) else 0.0))
		for q in 4: me[i*4 + q] = vme[i][q]; bl[i*4 + q] = vbl[i][q]
		var lh: Array = a.get("混合高度", [])
		for v in int(a["变体数"]):
			var L := int(a["起始层"]) + v; nl = maxi(nl, L + 1)
			var pr: Array = lh[v] if v < lh.size() else [-a["量程"], a["量程"]]
			hb[L*2] = pr[0]; hb[L*2 + 1] = pr[1]
	while vme.size() < MAXM: vme.append(Vector4(0, 1, 1, 0)); vmi.append(Vector4(0, 1, 1, 0)); vbl.append(Vector4(0, 0, 0.8, 0))
	mat.set_shader_parameter("mat_me", vme); mat.set_shader_parameter("mat_mi", vmi); mat.set_shader_parameter("mat_bl", vbl)
	var vl: Array[Vector4] = []
	for i in 40: vl.append(Vector4(hb[i*4], hb[i*4 + 1], hb[i*4 + 2], hb[i*4 + 3]))
	mat.set_shader_parameter("mat_lay", vl)
	var hr := PackedFloat32Array(); hr.resize(16)                    # 每种材质中观高差（交界起伏用）
	for i in nmat:
		var lh: Array = M["材质"][i]["中观"].get("混合高度", []); var sm := 0.0
		for pr in lh: sm += float(pr[1]) - float(pr[0])
		hr[i] = sm/maxf(lh.size(), 1)
	mat.set_shader_parameter("mat_hrng", hr)
	# 中景：逐材质反照率增益 + 低通图（--中景增益=κ，默认 1.0；0 关）
	var gv: Array[Vector4] = []
	for i in MAXM:
		var gg: Array = M["材质"][i].get("反照率增益", [1, 1, 1]) if i < nmat else [1, 1, 1]
		gv.append(Vector4(gg[0], gg[1], gg[2], 1.0))
	mat.set_shader_parameter("mat_gainv", gv)
	var GL: Dictionary = R.get("增益低通", {}); var gk := float(args.get("中景增益", "1.0")) if not GL.is_empty() else 0.0
	if gk > 0.0 and FileAccess.file_exists(D + String(GL["file"])):
		var gb := FileAccess.get_file_as_bytes(D + String(GL["file"])); var gn := gb.decode_s32(0)
		mat.set_shader_parameter("mat_glp", ImageTexture.create_from_image(Image.create_from_data(gn, gn, false, Image.FORMAT_RGBAH, gb.slice(8))))
		mat.set_shader_parameter("mat_gk", Vector4(gk, float(GL.get("half", 1000.0)), 0.0, 0.0))
	else:
		mat.set_shader_parameter("mat_gk", Vector4(0.0, 1000.0, 0.0, 0.0))
	mat.set_shader_parameter("mat_edge", float(args.get("材质边缘", str(R.get("边缘起伏", 0.0)))))   # --材质边缘=s：交界起伏强度（调参）
	mat.set_shader_parameter("mat_gs", pow(2.0, float(args.get("mip偏", "0"))))                      # --mip偏=b：纹理 mip 偏移（颗粒感 §4）
	mat.set_shader_parameter("mat_vp", float(args.get("材质保方差", "1")))                            # --材质保方差=s（0..1）：hex 混合保方差，补回加权平均压掉的细节对比（颗粒感 §4）
	lay_lohi = hb.slice(0, nl*2)
	# 混合、hex、档
	var hx: Dictionary = R.get("hex", {})
	hexp = [float(hx.get("中观格距", 0.45)), float(hx.get("指数", 7.0)), float(hx.get("高度权", 0.6)), float(R.get("锐度", 0.1))]
	hexmi = float(hx.get("微观格距", 0.06))
	if args.has("hex格距"): hexp[0] = float(args["hex格距"])                 # 诊断 / 调参
	mat.set_shader_parameter("mat_hexp", Vector4(hexp[0], hexp[1], hexp[2], hexp[3]))
	mat.set_shader_parameter("mat_hexmi", hexmi)
	var tier: Dictionary = R.get("档", {}).get(args.get("材质档", "高"), {"k": 3, "hex中观": true, "hex微观": true})
	k = int(args.get("材质k", str(tier.get("k", 3))))
	var hx_me: bool = tier.get("hex中观", true); var hx_mi: bool = tier.get("hex微观", true)
	if args.has("hex"): hx_me = args["hex"] == "1"; hx_mi = hx_me
	mat.set_shader_parameter("mat_k", k)
	mat.set_shader_parameter("mat_hex_meso", 1 if hx_me else 0); mat.set_shader_parameter("mat_hex_micro", 1 if hx_mi else 0)
	mat.set_shader_parameter("mat_gain", Vector4(float(M.get("中观_gain", 2.5)), float(M.get("微观_gain", 2.0)), float(M.get("梯度量程", 2.0)), 0.0))
	# 修饰：积尘、陡坡露岩、石旁积尘
	var dm: Dictionary = R.get("修饰", {}).get("M10", {})
	var dc: Array = dm.get("色", [1.04, 1.0, 0.94])
	var dk := float(args.get("积尘", "1"))                              # --积尘=0：不加 M10 修饰（诊断）
	mat.set_shader_parameter("mat_dust", Vector4(lerpf(1.0, dc[0], dk), lerpf(1.0, dc[1], dk), lerpf(1.0, dc[2], dk), float(dm.get("降对比", 0.5))*dk))
	mat.set_shader_parameter("mat_dust_rough", float(dm.get("粗糙度加", 0.08))*dk)
	var px: Dictionary = R.get("逐像素", {})
	var st: Dictionary = px.get("露岩坡度", {})
	var sid: int = ids.get(st.get("材质", "M8"), -1)
	mat.set_shader_parameter("mat_steep", Vector4(st.get("阈", 30.0), st.get("宽", 5.0), sid, st.get("强", 0.6) if args.get("露岩", "1") == "1" else 0.0))
	var lee: Dictionary = px.get("石旁积尘", {})
	var az := deg_to_rad(float(R.get("风", {}).get("来向", 63.0)))
	var off := float(lee.get("偏移", 0.15))
	mat.set_shader_parameter("mat_lee", Vector4(sin(az)*off, -cos(az)*off, float(lee.get("强", 0.8))*float(args.get("石旁尘", "1")), 0.0))   # 上风：ENU (sin, cos) → Godot (E, −N)
	var mac: Dictionary = R.get("宏观", {})                            # 宏观变化；--宏观=0 关、--宏观幅=s 整体缩放（诊断 / 调参）
	var ms := float(args.get("宏观幅", "1")) if args.get("宏观", "1") == "1" else 0.0
	var mgs: Array = mac.get("格距", [5.3, 21.7])
	mat.set_shader_parameter("mat_macro", Vector4(float(mac.get("对比幅", 0.35))*ms, float(mac.get("残差对比", 1.5))*ms, float(mac.get("偏置幅", 0.06))*ms, float(mac.get("亮度幅", 0.04))*ms))
	mat.set_shader_parameter("mat_macro_s", Vector4(float(mgs[0]), float(mgs[1]), float(mac.get("第一八度权", 0.6)), 0.0))
	var lv: Dictionary = R.get("分级", {})                             # 片元按像素足迹降级（阶段1.md §10）；--材质分级=0 关；--分级.<键>=值 覆盖单项（调参）
	for a in args:
		if String(a).begins_with("分级."): lv[String(a).substr(3)] = str_to_var(args[a]) if String(args[a]).begins_with("[") else float(args[a])
	var lo: Array = lv.get("hex门槛足迹", [0.004, 0.02]); var dz: Array = lv.get("导数图淡出足迹", [0.05, 0.1]); var ht: Array = lv.get("hex门槛", [0.02, 0.2])
	var mz: Array = lv.get("微观淡出足迹", [1.0, 2.0])
	mat.set_shader_parameter("mat_lod", Vector4(float(lo[0]), float(lo[1]), float(dz[0]), float(dz[1])))
	mat.set_shader_parameter("mat_lod2", Vector4(float(ht[0]), float(ht[1]), float(lv.get("k2足迹", 0.02)), float(args.get("各向异性", str(lv.get("各向异性上限", 4.0))))))
	mat.set_shader_parameter("mat_lod3", Vector4(float(lv.get("满k足迹", 0.004)), float(lv.get("微观hex门槛", 0.02)), float(mz[0]), float(mz[1])))
	if args.get("材质分级", "1") == "0": mat.set_shader_parameter("mat_lod", Vector4(1e9, 2e9, 1e9, 2e9)); mat.set_shader_parameter("mat_lod2", Vector4(0.005, 0.005, 1e9, 0.0)); mat.set_shader_parameter("mat_lod3", Vector4(1e9, 0.005, 1e9, 2e9))
	mat.set_shader_parameter("mat_dbg", int(args.get("地面材质诊断", "0")))
	mat.set_shader_parameter("mat_perf", int(args.get("材质性能", "0")))
	mat.set_shader_parameter("mat_cpu_cell", cpu_cell)
	# CPU：每层一级 mip 的 R16（按材质边长取格距最接近 cpu_cell 的那级，同着色器 round(log2(cell·n/边长))）
	gain = float(args.get("位移", "1"))
	if not _load_h16(D + A["mat_meso_h16"]["file"], nl): return false
	print("[材质] %d 种材质、%d 层中观、%d 层微观；控制图 %d² + %d²、门 %d²；k %d，hex %s/%s；%d ms" % [nmat, nl,
		int(A["mat_micro_ah"].get("层数", 0)), nN, nF, nG, k, "开" if hx_me else "关", "开" if hx_mi else "关", Time.get_ticks_msec() - t0])
	ok = true
	return true


func _load_h16(path: String, nl: int) -> bool:
	"""DX10 头的 DDS 数组（73 / 打包材质.gd 写的）：每层 mip 0..n−1 依次存。只取每层对应材质的那一级。"""
	var b := FileAccess.get_file_as_bytes(path)
	if b.size() < 148 or b.slice(0, 4).get_string_from_ascii() != "DDS " or b.slice(84, 88).get_string_from_ascii() != "DX10":
		push_error("[材质] %s 不是 DX10 DDS" % path); return false
	var hh := b.decode_u32(12); var ww := b.decode_u32(16); var nm := maxi(b.decode_u32(28), 1); var na := b.decode_u32(128 + 12)
	if hh != ww or na < nl: push_error("[材质] %s：%d×%d、%d 层" % [path, ww, hh, na]); return false
	var per := 0
	for m in nm: per += maxi(ww >> m, 1)*maxi(ww >> m, 1)*2
	mip_of.resize(nmat)
	var layer_mip := PackedInt32Array(); layer_mip.resize(nl)
	for i in nmat:
		var mp := clampi(roundi(log(cpu_cell*ww/me[i*4 + 2])/log(2.0)), 0, nm - 1)
		mip_of[i] = mp
		for v in int(me[i*4 + 1]): layer_mip[int(me[i*4]) + v] = mp
	h16 = PackedByteArray(); lay_off.resize(nl); lay_n.resize(nl)
	for L in nl:
		var o := 148 + L*per
		for m in layer_mip[L]: o += maxi(ww >> m, 1)*maxi(ww >> m, 1)*2
		var n := maxi(ww >> layer_mip[L], 1)
		lay_off[L] = h16.size()/2; lay_n[L] = n
		h16.append_array(b.slice(o, o + n*n*2))
	return true


# ———————————————————— CPU 版（和 材质.gdshaderinc mat_disp(xz, 0, true) 逐行对应）
static func mh(x: int) -> int:
	x &= M32
	x ^= x >> 16; x = (x*0x7feb352d) & M32
	x ^= x >> 15; x = (x*0x5bd1e995) & M32
	x ^= x >> 16
	return x


static func mu(h: int) -> float:
	return float(h >> 8)/16777216.0


func _put(T: Array, m: int, x: float) -> void:                 # T = [id0..3, w0..3]
	if x <= 0.0: return
	for i in 4:
		if T[i] == m:
			T[4 + i] += x
			return
	var w0: float = T[4]; var w1: float = T[5]; var w2: float = T[6]; var w3: float = T[7]
	var j := 3
	if w0 <= w1 and w0 <= w2 and w0 <= w3: j = 0
	elif w1 <= w2 and w1 <= w3: j = 1
	elif w2 <= w3: j = 2
	if x > T[4 + j]:
		T[j] = m; T[4 + j] = x


func _texel(c: PackedByteArray, n: int, i: int, j: int, bw: float, T: Array) -> void:
	var u: int = c.decode_u32(8 + (j*n + i)*4)
	if fmt == 4:
		var q0 := float((u >> 16) & 15); var q1 := float((u >> 20) & 15); var q2 := float((u >> 24) & 15); var s4 := bw/15.0
		_put(T, u & 15, s4*q0); _put(T, (u >> 4) & 15, s4*q1); _put(T, (u >> 8) & 15, s4*q2); _put(T, (u >> 12) & 15, s4*(15.0 - q0 - q1 - q2))
		return
	var w0 := float((u >> 15) & 63); var w1 := float((u >> 21) & 63); var s := bw/63.0
	_put(T, u & 31, s*w0); _put(T, (u >> 5) & 31, s*w1); _put(T, (u >> 10) & 31, s*(63.0 - w0 - w1))


func _bilin(c: PackedByteArray, n: int, x: float, z: float, hf: float, cs: float, bw: float, T: Array) -> void:
	var fx: float = (x + hf)/cs - 0.5; var fz := (z + hf)/cs - 0.5
	var ix := floorf(fx); var iz := floorf(fz); var ax := fx - ix; var az := fz - iz
	var px: float = clampi(int(ix), 0, n - 1); var pz := clampi(int(iz), 0, n - 1); var qx := clampi(int(ix) + 1, 0, n - 1); var qz := clampi(int(iz) + 1, 0, n - 1)
	_texel(c, n, px, pz, bw*(1.0 - ax)*(1.0 - az), T); _texel(c, n, qx, pz, bw*ax*(1.0 - az), T)
	_texel(c, n, px, qz, bw*(1.0 - ax)*az, T); _texel(c, n, qx, qz, bw*ax*az, T)


static func _region(e: float, h: float, f: float) -> float:
	return clampf((h*0.97 - e)/(h*f), 0.0, 1.0)


func gate_at(x: float, z: float) -> float:
	if maxf(absf(x), absf(z)) >= grid[0]: return 1.0
	var cs: float = 2.0*grid[0]/nG
	var fx: float = (x + grid[0])/cs - 0.5; var fz: float = (z + grid[0])/cs - 0.5
	var ix := floorf(fx); var iz := floorf(fz); var ax := fx - ix; var az := fz - iz
	var px: float = clampi(int(ix), 0, nG - 1); var pz := clampi(int(iz), 0, nG - 1); var qx := clampi(int(ix) + 1, 0, nG - 1); var qz := clampi(int(iz) + 1, 0, nG - 1)
	var g := func(i: int, j: int) -> float: return gate[8 + j*nG + i]/255.0
	return lerpf(lerpf(g.call(px, pz), g.call(qx, pz), ax), lerpf(g.call(px, qz), g.call(qx, qz), ax), az)


func table(x: float, z: float) -> Array:
	var T := [-1, -1, -1, -1, 0.0, 0.0, 0.0, 0.0]
	var e := maxf(absf(x), absf(z))
	var a := _region(e, grid[0], 0.05); var b := (1.0 - a)*_region(e, grid[2], 0.05)
	if a > 0.0: _bilin(ctrl_n, nN, x, z, grid[0], grid[1], a, T)
	if b > 0.0: _bilin(ctrl_f, nF, x, z, grid[2], grid[3], b, T)
	var o := 1.0 - a - b
	if o > 0.0:
		for i in 4:
			if out_id[i] >= 0: _put(T, out_id[i], o*out_w[i])
	return T


func topk(T: Array) -> void:
	for r in 2:
		var nz := 0
		for i in 4: nz += 1 if T[4 + i] > 0.0 else 0
		if nz <= k: break
		var t := []
		for i in 4: t.append(T[4 + i] if T[4 + i] > 0.0 else 1e9)
		var mn: float = minf(minf(t[0], t[1]), minf(t[2], t[3]))
		for i in 4:
			if t[i] == mn:
				T[4 + i] = 0.0
				break
	var s: float = maxf(T[4] + T[5] + T[6] + T[7], 1e-9)
	for i in 4: T[4 + i] = T[4 + i]/s if T[4 + i]/s >= 0.02 else 0.0
	s = maxf(T[4] + T[5] + T[6] + T[7], 1e-9)
	for i in 4: T[4 + i] /= s


func _h16(L: int, u: float, v: float) -> float:
	var n := lay_n[L]; var o := lay_off[L]*2
	var fx: float = u*n - 0.5; var fy: float = v*n - 0.5
	var ix := floori(fx); var iy := floori(fy); var tx := fx - ix; var ty := fy - iy
	var x0 := posmod(ix, n); var x1 := posmod(ix + 1, n); var y0 := posmod(iy, n); var y1 := posmod(iy + 1, n)
	var a := lerpf(h16.decode_u16(o + (y0*n + x0)*2), h16.decode_u16(o + (y0*n + x1)*2), tx)
	var c := lerpf(h16.decode_u16(o + (y1*n + x0)*2), h16.decode_u16(o + (y1*n + x1)*2), tx)
	return lerpf(a, c, ty)/65535.0


func _pack3(T: Array) -> void:                                  # 同 mat_pack3：第 4 项挪进 xyz 里的空位
	if T[7] > 0.0:
		if T[4] <= 0.0: T[0] = T[3]; T[4] = T[7]
		elif T[5] <= 0.0: T[1] = T[3]; T[5] = T[7]
		else: T[2] = T[3]; T[6] = T[7]


func disp(x: float, z: float) -> float:
	"""中观位移（米，已乘 gain）：= GPU disp_at 在 disp_far × 0.6 以内、按 cpu_cell 选 mip 时的值（着色器 mat_disp(xz, 0, true)）。"""
	if not ok or gain <= 0.0: return 0.0
	var g := gate_at(x, z)
	if g <= 0.0: return 0.0
	var T := table(x, z); topk(T); _pack3(T)
	var px: float = x; var py: float = -z; var cell: float = hexp[0]
	# 三角格（世界坐标，格距 cell）
	var su: float = px/cell; var sv: float = py/cell
	var kx: float = su - 0.57735027*sv; var ky: float = 1.15470054*sv
	var bx: float = floorf(kx); var by: float = floorf(ky); var fx: float = kx - bx; var fy: float = ky - by
	var zz: float = 1.0 - fx - fy
	var s := 1 if zz <= 0.0 else 0; var s2 := 2.0*s - 1.0
	var W := [pow(clampf(-zz*s2, 0.0, 1.0), hexp[1]), pow(clampf(s - fy*s2, 0.0, 1.0), hexp[1]), pow(clampf(s - fx*s2, 0.0, 1.0), hexp[1])]
	var ws: float = W[0] + W[1] + W[2]
	var ib := int(bx); var jb := int(by)
	var V := [[ib + s, jb + s], [ib + s, jb + 1 - s], [ib + 1 - s, jb + s]]
	var Q := []                                                   # 每格：[qx, qy, cos, sin, 哈希]
	for v in V:
		var h := mh(((int(v[0]) & M32)*0x27d4eb2d & M32) ^ mh(int(v[1]) & M32))
		var a := float((h >> 20) & 255)*(6.2831853/256.0)
		Q.append([px - (v[0] + 0.5*v[1])*cell, py - 0.8660254*v[1]*cell, cos(a), sin(a), h])
	var tot := 0.0; var hs := 0.0
	for j in 3:
		if T[4 + j] <= 0.0: continue
		var m: int = T[j]; var S: float = me[m*4 + 2]; var rot: bool = bl[m*4 + 3] > 0.5
		var acc := [0.0, 0.0, 0.0]
		for i in 3:
			var Wi: float = W[i]/ws
			if Wi < 0.005: continue
			var q: Array = Q[i]; var h: int = q[4]
			var c: float = q[2] if rot else 1.0; var sn: float = q[3] if rot else 0.0
			var nv := maxi(int(me[m*4 + 1]), 1)
			var L := int(me[m*4]) + ((h >> 28) % nv if fmt != 4 else (((mh((h ^ 0x68e31da4) & M32) >> 16)*nv) >> 16))
			var u: float = (c*q[0] - sn*q[1])/S + float(h & 1023)/1024.0
			var v: float = (sn*q[0] + c*q[1])/S + float((h >> 10) & 1023)/1024.0
			var hh := (_h16(L, u, v) - 0.5)*2.0*me[m*4 + 3]
			var lo := lay_lohi[L*2]; var hi := lay_lohi[L*2 + 1]
			var a := clampf((hh - lo)/(hi - lo), 0.0, 1.0)
			var wi: float = Wi*lerpf(1.0, a, hexp[2])
			acc[0] += wi*hh; acc[1] += wi*a; acc[2] += wi
		var b: float = T[4 + j]*exp((bl[m*4]*g*(acc[1]/acc[2] - 0.5) + bl[m*4 + 1])/hexp[3])
		tot += b; hs += b*acc[0]/acc[2]
	return gain*g*hs/tot
