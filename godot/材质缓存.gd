# 地面材质缓存（原型，engine-vt 分支；docs/引擎/现代渲染优化调研.md §5）
# 把 材质.gdshaderinc 的 mat_frag（控制图 + 8 种材质 + hex + 宏观 + 中观 + 积尘）按「以相机为中心的 clipmap」烘进两张 Texture2DArray：
#   L 层，每层 N×N 纹素，第 i 层纹素 t0·2^i 米、覆盖 ±N·t/2；环形寻址（世界纹素编号 g 存在 g mod N，着色器用 repeat 采样，
#   不需要原点），相机挪动时只补新露出的条带（每帧有纹素预算，粗层优先）。
#   8 字节 / 纹素。A（RGBA8）：细节反照率 det/4（已乘积尘色，烘焙时加抖动）、粗糙度 σ；B（RGBA8）：中观坡度 0.5 + mg/2、权重最大的材质号、微观对比系数 k/2。
# 地形.gdshader 在 #define MAT_CACHE 时用 材质缓存.gdshaderinc 读缓存；像素足迹 < t0 的近处仍走实时 mat_frag（加实时微观）。
# 计算着色器不是手写的：把 地形.gdshader 连同 include 原样展开、去掉 vertex/fragment/light，非采样器 uniform 收进一个 std140 UBO、
# 采样器变成绑定，再接一个 main()（烘焙胶水，同 地形.gdshader 片元第 1–7 步）。所以材质代码改了，缓存自动跟着变；
# 唯一的文本补丁是在 mat_frag 里把权重最大的材质号抄出来（找不到锚点就报错）。uniform 的值每次烘焙时从地面材质读。
extends RefCounted

var ok := false
var rd: RenderingDevice
var mat: ShaderMaterial
var N := 2048
var L := 10
var t0 := 0.002
var budget := 1500000                     # 每帧最多烘多少纹素（相机跳变时不限）
var stress := 0                           # 诊断 --缓存压测=K：每帧额外重烘第 0 层 K 个纹素（内容不变），量烘焙开销
var snap := 16                            # 窗口按这么多纹素一跳（少碎条带）
var tex_a := RID(); var tex_b := RID()
# 微观自阴影（颗粒感 §2）：烘焙时顺手写每纹素高度（R16F，米），再用一遍计算着色器沿 8 个方位步进求地平线仰角，傅里叶展开到 3 阶（7 个系数）存两张 RGBA8
var LH := 5                               # 有地平线图的层数（第 0..LH−1 层，纹素 ≤ 2·2^(LH−1) mm = 32 mm）；0 = 关
const HR := 128                           # 地平线步进最远 128 纹素：地平线只在高度窗口往里缩 HR 纹素的范围里有效
var hsoft := 0.02                         # 太阳盘 + 编码误差的软边半宽（弧度）
var tex_h := RID(); var tex_c0 := RID(); var tex_c1 := RID()
var shader_h := RID(); var pipe_h := RID(); var set_h := RID(); var samp_h := RID()
var shader := RID(); var pipe := RID()
var ubo := RID(); var ubo_size := 0
var ufields: Array = []                   # [名, 基本类型, 分量数, 数组长（0 = 非数组）, 偏移, 默认值数组]
var samps: Array = []                     # [名, 类型 "2D"/"2DArray", 数组长, srgb, 采样器 RID, 绑定号]
var set0 := RID(); var set0_key := ""
var set1 := RID()
var dummy := {}                           # "2D"/"2DArray" → 白色 1×1 RD 纹理
var samplers := {}                        # 提示串 → 采样器 RID
var org: Array = []                       # 每层窗口最小角（世界纹素编号 Vector2i）；null = 还没烘
var frame := 0
# 统计（测帧时每个场景报一次）
var st_tex := 0; var st_frames := 0; var st_disp_frames := 0; var st_gpu_us := 0.0; var st_gpu_n := 0; var st_max_tex := 0
var st_full := 0; var st_htex := 0

const TS0 := "材质缓存烘焙"
const TS1 := "材质缓存烘焙完"


func setup(ground: ShaderMaterial, args: Dictionary) -> bool:
	mat = ground
	rd = RenderingServer.get_rendering_device()
	if rd == null: push_error("[材质缓存] 没有 RenderingDevice（要 Forward+ / Mobile）"); return false
	N = int(args.get("缓存N", "2048")); L = int(args.get("缓存层", "10")); t0 = float(args.get("缓存t0", "0.002"))   # 默认 = 调研文档 §6.5 建议档
	budget = int(args.get("缓存预算", "1500000")); stress = int(args.get("缓存压测", "0"))
	var t_start := Time.get_ticks_msec()
	var code := _translate("res://着色器/地形.gdshader")
	if code == "": return false
	if args.get("缓存存GLSL", "0") == "1":
		var f := FileAccess.open("user://材质缓存.comp.glsl", FileAccess.WRITE); f.store_string(code); f.close()
	var src := RDShaderSource.new(); src.language = RenderingDevice.SHADER_LANGUAGE_GLSL; src.source_compute = code
	var spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(src)
	if spirv.compile_error_compute != "":
		push_error("[材质缓存] 计算着色器编译失败：\n" + spirv.compile_error_compute.left(3000))
		var f2 := FileAccess.open("user://材质缓存.comp.glsl", FileAccess.WRITE); f2.store_string(code); f2.close()
		return false
	shader = rd.shader_create_from_spirv(spirv, "材质缓存")
	if not shader.is_valid(): push_error("[材质缓存] shader_create_from_spirv 失败"); return false
	pipe = rd.compute_pipeline_create(shader)
	# 缓存纹理
	var fa := RDTextureFormat.new()
	fa.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY; fa.width = N; fa.height = N; fa.depth = 1; fa.array_layers = L; fa.mipmaps = 1
	fa.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	fa.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	tex_a = rd.texture_create(fa, RDTextureView.new())
	var fb := RDTextureFormat.new()
	fb.texture_type = fa.texture_type; fb.width = N; fb.height = N; fb.depth = 1; fb.array_layers = L; fb.mipmaps = 1
	fb.usage_bits = fa.usage_bits; fb.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	tex_b = rd.texture_create(fb, RDTextureView.new())
	if not tex_a.is_valid() or not tex_b.is_valid(): push_error("[材质缓存] 建纹理失败"); return false
	# 微观自阴影：高度（R16F）、地平线系数（两张 RGBA8）；LH = 0 时仍建 1 层的占位（烘焙着色器要绑 mc_out_h）
	LH = clampi(int(args.get("缓存阴影层", "5")), 0, L) if args.get("缓存阴影", "0") == "1" else 0
	hsoft = float(args.get("缓存阴影软", "0.02"))
	var fh := RDTextureFormat.new()
	fh.texture_type = fa.texture_type; fh.width = N; fh.height = N; fh.depth = 1; fh.array_layers = maxi(LH, 1); fh.mipmaps = 1
	fh.usage_bits = fa.usage_bits; fh.format = RenderingDevice.DATA_FORMAT_R16_SFLOAT
	tex_h = rd.texture_create(fh, RDTextureView.new())
	var fc := RDTextureFormat.new()
	fc.texture_type = fa.texture_type; fc.width = N; fc.height = N; fc.depth = 1; fc.array_layers = maxi(LH, 1); fc.mipmaps = 1
	fc.usage_bits = fa.usage_bits; fc.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	tex_c0 = rd.texture_create(fc, RDTextureView.new()); tex_c1 = rd.texture_create(fc, RDTextureView.new())
	if not tex_h.is_valid() or not tex_c0.is_valid() or not tex_c1.is_valid(): push_error("[材质缓存] 建地平线纹理失败"); return false
	var u0 := RDUniform.new(); u0.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; u0.binding = 0; u0.add_id(tex_a)
	var u1 := RDUniform.new(); u1.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; u1.binding = 1; u1.add_id(tex_b)
	var u2 := RDUniform.new(); u2.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; u2.binding = 2; u2.add_id(tex_h)
	set1 = rd.uniform_set_create([u0, u1, u2], shader, 1)
	if LH > 0 and not _setup_horizon(): return false
	var pb := PackedByteArray(); pb.resize(ubo_size)
	ubo = rd.uniform_buffer_create(ubo_size, pb)
	var ta := Texture2DArrayRD.new(); ta.texture_rd_rid = tex_a
	var tb := Texture2DArrayRD.new(); tb.texture_rd_rid = tex_b
	mat.set_shader_parameter("mc_a", ta); mat.set_shader_parameter("mc_b", tb); mat.set_shader_parameter("mc_bn", tb)
	if LH > 0:                                                            # 关着时占位纹理只有 1 层，包成 Texture2DArrayRD 引擎会报错（array_layers <= 1）；着色器按 mc_ms.x = 0 不采样
		var tc0 := Texture2DArrayRD.new(); tc0.texture_rd_rid = tex_c0
		var tc1 := Texture2DArrayRD.new(); tc1.texture_rd_rid = tex_c1
		mat.set_shader_parameter("mc_c0", tc0); mat.set_shader_parameter("mc_c1", tc1)
	mat.set_shader_parameter("mc_ms", Vector4(LH, hsoft, 0.0, 0.0))
	mat.set_shader_parameter("mc_info", Vector4(t0, N, L, float(args.get("缓存各向异性", "8"))))
	mat.set_shader_parameter("mc_info2", Vector4(float(args.get("缓存近", "-1.0")), float(args.get("缓存近宽", "0.5")), 0.0, float(args.get("缓存诊断", "0"))))
	org.resize(L); org.fill(null)
	_set_windows()
	ok = true
	print("[材质缓存] N %d × %d 层，t0 %.1f mm（最粗 %.2f m，覆盖 ±%.0f m），%.0f MB（+ 微观自阴影 %d 层 %.0f MB）；UBO %d B，采样器 %d 个；建立 %d ms" % [N, L, t0*1000.0,
		t0*pow(2.0, L - 1), N*t0*pow(2.0, L - 1)/2.0, N*N*L*8.0/1048576.0, LH, N*N*LH*10.0/1048576.0, ubo_size, samps.size(), Time.get_ticks_msec() - t_start])
	return true


func _setup_horizon() -> bool:
	var hs := RDShaderSource.new(); hs.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	hs.source_compute = FileAccess.get_file_as_string("res://着色器/材质缓存_地平线.glsl.txt")
	var sp: RDShaderSPIRV = rd.shader_compile_spirv_from_source(hs)
	if sp.compile_error_compute != "": push_error("[材质缓存] 地平线着色器编译失败：\n" + sp.compile_error_compute.left(3000)); return false
	shader_h = rd.shader_create_from_spirv(sp, "材质缓存地平线")
	if not shader_h.is_valid(): push_error("[材质缓存] 地平线 shader_create_from_spirv 失败"); return false
	pipe_h = rd.compute_pipeline_create(shader_h)
	var ss := RDSamplerState.new()
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR; ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR; ss.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT; ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT; ss.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	samp_h = rd.sampler_create(ss)
	var h0 := RDUniform.new(); h0.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE; h0.binding = 0; h0.add_id(samp_h); h0.add_id(tex_h)
	var h1 := RDUniform.new(); h1.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; h1.binding = 1; h1.add_id(tex_c0)
	var h2 := RDUniform.new(); h2.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; h2.binding = 2; h2.add_id(tex_c1)
	set_h = rd.uniform_set_create([h0, h1, h2], shader_h, 0)
	return set_h.is_valid()


# ———————————————————— 地形.gdshader → GLSL 计算着色器
func _expand(path: String, seen: Dictionary) -> String:
	var src := FileAccess.get_file_as_string(path)
	if src == "": push_error("[材质缓存] 读不到 " + path)
	var out := PackedStringArray()
	for line in src.split("\n"):
		var s := line.strip_edges()
		if s.begins_with("#include"):
			var p := s.get_slice("\"", 1)
			if p.contains("材质缓存"): continue                         # 读缓存的那份不进烘焙（否则会把缓存自己当采样器绑上）
			if not seen.has(p): seen[p] = true; out.append(_expand(p, seen))
			continue
		out.append(line)
	return "\n".join(out)


func _strip_comments(s: String) -> String:
	var r := RegEx.create_from_string("/\\*[\\s\\S]*?\\*/"); s = r.sub(s, "", true)
	r = RegEx.create_from_string("//[^\\n]*"); return r.sub(s, "", true)


func _remove_func(s: String, fname: String) -> String:
	var r := RegEx.create_from_string("void\\s+" + fname + "\\s*\\(\\s*\\)\\s*\\{")
	var m := r.search(s)
	if m == null: return s
	var i := m.get_end(); var depth := 1
	while i < s.length() and depth > 0:
		var c := s[i]
		if c == "{": depth += 1
		elif c == "}": depth -= 1
		i += 1
	return s.substr(0, m.get_start()) + s.substr(i)


const BASE := {"float": ["f", 1], "int": ["i", 1], "uint": ["u", 1], "bool": ["b", 1], "vec2": ["f", 2], "vec3": ["f", 3], "vec4": ["f", 4],
	"ivec2": ["i", 2], "ivec3": ["i", 3], "ivec4": ["i", 4], "uvec2": ["u", 2], "uvec3": ["u", 3], "uvec4": ["u", 4], "bvec2": ["b", 2], "bvec3": ["b", 3], "bvec4": ["b", 4],
	"mat4": ["f", 16]}


func _translate(path: String) -> String:
	var s := _strip_comments(_expand(path, {}))
	for f in ["vertex", "fragment", "light"]: s = _remove_func(s, f)
	var body := PackedStringArray(); var ublock := PackedStringArray(); var sbind := PackedStringArray()
	var ru := RegEx.create_from_string("^\\s*uniform\\s+(\\w+)\\s+(\\w+)\\s*(?:\\[\\s*(\\d+)\\s*\\])?\\s*(?::\\s*([^=;]*))?(?:=\\s*([^;]*))?;\\s*$")
	var off := 0; var binding := 1
	ufields.clear(); samps.clear()
	for line in s.split("\n"):
		var t := line.strip_edges()
		if t.begins_with("shader_type") or t.begins_with("render_mode") or t.begins_with("varying"): continue
		if t.begins_with("uniform"):
			var m := ru.search(t)
			if m == null: push_error("[材质缓存] 看不懂这条 uniform：" + t); return ""
			var ty := m.get_string(1); var nm := m.get_string(2); var cnt := int(m.get_string(3)) if m.get_string(3) != "" else 0
			var hint := m.get_string(4).strip_edges(); var dflt := m.get_string(5).strip_edges()
			if ty.begins_with("sampler"):
				var kind := "2D" if ty == "sampler2D" else ("2DArray" if ty == "sampler2DArray" else "")
				if kind == "": push_error("[材质缓存] 不支持的采样器类型 " + ty); return ""
				samps.append([nm, kind, cnt, hint.contains("source_color"), _sampler(hint), binding])
				sbind.append("layout(set = 0, binding = %d) uniform %s %s%s;" % [binding, ty, nm, ("[%d]" % cnt) if cnt > 0 else ""])
				binding += 1
			else:
				if not BASE.has(ty): push_error("[材质缓存] 不支持的 uniform 类型 " + ty); return ""
				var nc: int = BASE[ty][1]
				var al := 4 if nc == 1 else (8 if nc == 2 else 16)
				var sz := 4*nc if nc != 3 else 12
				if ty == "mat4": al = 16; sz = 64
				if cnt > 0: al = 16; sz = (16 if nc <= 4 else 64)*cnt
				off = (off + al - 1)/al*al
				ufields.append([nm, BASE[ty][0], nc, cnt, off, _parse_default(dflt, nc)])
				ublock.append("\t%s %s%s;" % [ty, nm, ("[%d]" % cnt) if cnt > 0 else ""])
				off += sz
			continue
		body.append(line)
	off = (off + 15)/16*16
	ublock.append("\tvec4 mc_pad_;"); off += 16
	ubo_size = off
	var b := "\n".join(body)
	# 唯一的文本补丁：mat_frag 里把权重最大的材质号抄到全局 mc_mj
	var anchor := RegEx.create_from_string("(int\\s+mj\\s*=[^;]*;)")
	if anchor.search(b) == null: push_error("[材质缓存] mat_frag 里找不到「int mj = …;」锚点（材质.gdshaderinc 改了？）"); return ""
	b = anchor.sub(b, "$1 mc_mj = mj;", false)
	var n16 := "#define MAT_N16\n" if int(mat.get_shader_parameter("mat_fmt")) == 4 else ""
	var head := """#version 450
#define MAT_BAKE
%s#define PI 3.14159265358979323846
#define TAU 6.28318530717958647692
#define texture(s, c) textureLod(s, c, 0.0)
#define dFdx(x) ((x)*0.0)
#define dFdy(x) ((x)*0.0)
#define fwidth(x) ((x)*0.0)
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0, std140) uniform MatU {
%s
};
%s
layout(set = 1, binding = 0, rgba16f) uniform restrict writeonly image2DArray mc_out_a;
layout(set = 1, binding = 1, rgba8) uniform restrict writeonly image2DArray mc_out_b;
layout(set = 1, binding = 2, r16f) uniform restrict writeonly image2DArray mc_out_h;
layout(push_constant, std430) uniform MCPush { ivec4 rect; vec4 lv; } pc;
int mc_mj = 0;
""" % [n16, "\n".join(ublock), "\n".join(sbind)]
	return head + b + "\n" + FileAccess.get_file_as_string("res://着色器/材质缓存_烘焙.glsl.txt")


func _parse_default(d: String, nc: int) -> Array:
	if d == "": return []
	if d == "true": return [1]
	if d == "false": return [0]
	var r := RegEx.create_from_string("-?\\d+\\.?\\d*(?:[eE][-+]?\\d+)?")
	var v := []
	for m in r.search_all(d): v.append(float(m.get_string()))
	if v.size() == 1 and nc > 1:
		var x = v[0]; v = []
		for i in nc: v.append(x)
	return v


func _sampler(hint: String) -> RID:
	var key := hint
	if samplers.has(key): return samplers[key]
	var ss := RDSamplerState.new()
	var lin := not hint.contains("filter_nearest")
	var mip := hint.contains("mipmap") or not hint.contains("filter_")   # 没写 filter_ = 项目默认（线性 + mip）
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR if lin else RenderingDevice.SAMPLER_FILTER_NEAREST
	ss.min_filter = ss.mag_filter
	ss.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR if (mip and lin) else RenderingDevice.SAMPLER_FILTER_NEAREST
	if not mip: ss.max_lod = 0.0
	if hint.contains("anisotropic"): ss.use_anisotropy = true; ss.anisotropy_max = 16.0
	var rep := RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE if hint.contains("repeat_disable") else RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	ss.repeat_u = rep; ss.repeat_v = rep; ss.repeat_w = rep
	samplers[key] = rd.sampler_create(ss)
	return samplers[key]


func _dummy(kind: String) -> RID:
	if dummy.has(kind): return dummy[kind]
	var f := RDTextureFormat.new(); f.width = 1; f.height = 1; f.depth = 1; f.mipmaps = 1
	f.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	f.texture_type = RenderingDevice.TEXTURE_TYPE_2D if kind == "2D" else RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	f.array_layers = 1
	dummy[kind] = rd.texture_create(f, RDTextureView.new(), [PackedByteArray([255, 255, 255, 255])])
	return dummy[kind]


func _rd_tex(v, kind: String, srgb: bool) -> RID:
	if v is Texture:
		var r := RenderingServer.texture_get_rd_texture((v as Texture).get_rid(), srgb)
		if r.is_valid(): return r
	return _dummy(kind)


# ———————————————————— uniform 值（每次烘焙从地面材质读）
func _comps(v) -> Array:
	match typeof(v):
		TYPE_FLOAT, TYPE_INT, TYPE_BOOL: return [v]
		TYPE_VECTOR2, TYPE_VECTOR2I: return [v.x, v.y]
		TYPE_VECTOR3, TYPE_VECTOR3I: return [v.x, v.y, v.z]
		TYPE_VECTOR4, TYPE_VECTOR4I, TYPE_QUATERNION: return [v.x, v.y, v.z, v.w]
		TYPE_COLOR: return [v.r, v.g, v.b, v.a]
	return []


func _put(pb: PackedByteArray, o: int, kind: String, x) -> void:
	if kind == "f": pb.encode_float(o, float(x))
	elif kind == "u": pb.encode_u32(o, int(x))
	elif kind == "b": pb.encode_u32(o, 1 if bool(x) else 0)
	else: pb.encode_s32(o, int(x))


func _ubo_bytes() -> PackedByteArray:
	var pb := PackedByteArray(); pb.resize(ubo_size)
	for f in ufields:
		var v = mat.get_shader_parameter(f[0])
		var kind: String = f[1]; var nc: int = f[2]; var cnt: int = f[3]; var o: int = f[4]
		if cnt > 0:
			if v == null: continue
			var n: int = mini(cnt, v.size())
			for e in n:
				var c := _comps(v[e])
				for j in mini(c.size(), nc): _put(pb, o + 16*e + 4*j, kind, c[j])
		else:
			var c: Array = _comps(v) if v != null else f[5]
			for j in mini(c.size(), nc): _put(pb, o + 4*j, kind, c[j])
	return pb


func _set0() -> RID:
	var rids := []; var key := ""
	for s in samps:
		var v = mat.get_shader_parameter(s[0]); var lst := []
		if s[2] > 0:
			for e in s[2]: lst.append(_rd_tex(v[e] if (v is Array and e < v.size()) else null, s[1], s[3]))
		else: lst.append(_rd_tex(v, s[1], s[3]))
		rids.append(lst)
		for r in lst: key += str(r.get_id()) + ","
	if key == set0_key and set0.is_valid() and rd.uniform_set_is_valid(set0): return set0
	var us: Array[RDUniform] = []
	var u := RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER; u.binding = 0; u.add_id(ubo); us.append(u)
	for i in samps.size():
		var s: Array = samps[i]
		var w := RDUniform.new(); w.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE; w.binding = s[5]
		for r in rids[i]: w.add_id(s[4]); w.add_id(r)
		us.append(w)
	if set0.is_valid() and rd.uniform_set_is_valid(set0): rd.free_rid(set0)
	set0 = rd.uniform_set_create(us, shader, 0); set0_key = key
	return set0


# ———————————————————— 每帧更新
func _rects(cur, want: Vector2i, n: int = N) -> Array:
	if cur == null: return [Rect2i(want, Vector2i(n, n))]
	var c: Vector2i = cur; var d := want - c
	if absi(d.x) >= n or absi(d.y) >= n: return [Rect2i(want, Vector2i(n, n))]
	var out := []
	if d.x > 0: out.append(Rect2i(Vector2i(c.x + n, want.y), Vector2i(d.x, n)))
	elif d.x < 0: out.append(Rect2i(Vector2i(want.x, want.y), Vector2i(-d.x, n)))
	var x0 := maxi(c.x, want.x); var x1 := mini(c.x, want.x) + n
	if d.y > 0: out.append(Rect2i(Vector2i(x0, c.y + n), Vector2i(x1 - x0, d.y)))
	elif d.y < 0: out.append(Rect2i(Vector2i(x0, want.y), Vector2i(x1 - x0, -d.y)))
	return out


func update(cam: Vector3, force := false) -> void:
	if not ok: return
	frame += 1; st_frames += 1
	_read_timestamps()
	var jobs := []; var hjobs := []; var left := budget
	# 先估总量：跳变（> 3 倍预算）时一次烘完（不让窗口滞后到拿不准）
	var wants := []; var total := 0
	for i in L:
		var t := t0*pow(2.0, i)
		var w := Vector2i(int(floor(cam.x/t/snap))*snap - N/2, int(floor(cam.z/t/snap))*snap - N/2)
		wants.append(w)
		for r in _rects(org[i], w): total += r.size.x*r.size.y
	if total > 3*budget: force = true
	for i in range(L - 1, -1, -1):                                        # 粗层先：细层跟不上时着色器自动退到粗层
		var w: Vector2i = wants[i]
		if org[i] != null and org[i] == w: continue
		var rs := _rects(org[i], w); var cost := 0
		for r in rs: cost += r.size.x*r.size.y
		if not force and cost > left:
			if org[i] == null: continue
			var c: Vector2i = org[i]; var fr := float(left)/cost        # 只挪一部分（按预算），下帧接着挪
			w = c + Vector2i(int((w.x - c.x)*fr)/snap*snap, int((w.y - c.y)*fr)/snap*snap)
			if w == c: continue
			rs = _rects(c, w); cost = 0
			for r in rs: cost += r.size.x*r.size.y
		left -= cost
		for r in rs: jobs.append([i, r])
		var old = org[i]
		org[i] = w
		if i < LH:                                                          # 地平线：窗口往里缩 HR 纹素，只补新露出的条带（高度在同一次调度里先写好）
			var oh = null if old == null else (old as Vector2i) + Vector2i(HR, HR)
			for r in _rects(oh, w + Vector2i(HR, HR), N - 2*HR): hjobs.append([i, r])
	if force: st_full += 1
	if stress > 0 and org[0] != null:
		var rows := clampi(stress/N, 1, N); var o0: Vector2i = org[0]
		jobs.append([0, Rect2i(Vector2i(o0.x, o0.y + (frame*rows) % (N - rows + 1)), Vector2i(N, rows))])
	if jobs.size() or hjobs.size(): RenderingServer.call_on_render_thread(_dispatch.bind(jobs, hjobs))
	_set_windows()


func _set_windows() -> void:
	var W: Array[Vector4] = []
	for i in 16:
		if i < L and org[i] != null:
			var t := t0*pow(2.0, i); var o: Vector2i = org[i]
			W.append(Vector4(o.x*t, o.y*t, (o.x + N)*t, (o.y + N)*t))
		else: W.append(Vector4(1.0, 1.0, -1.0, -1.0))
	mat.set_shader_parameter("mc_win", W)
	var HW: Array[Vector4] = []
	for i in 8:
		if i < LH and org[i] != null:
			var t := t0*pow(2.0, i); var o: Vector2i = org[i]
			HW.append(Vector4((o.x + HR)*t, (o.y + HR)*t, (o.x + N - HR)*t, (o.y + N - HR)*t))
		else: HW.append(Vector4(1.0, 1.0, -1.0, -1.0))
	mat.set_shader_parameter("mc_hwin", HW)
	var i2: Vector4 = mat.get_shader_parameter("mc_info2")
	i2.z = float(frame % 64); mat.set_shader_parameter("mc_info2", i2)


func _dispatch(jobs: Array, hjobs: Array) -> void:
	var s0 := _set0()
	rd.buffer_update(ubo, 0, ubo_size, _ubo_bytes())
	rd.capture_timestamp(TS0)
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipe)
	rd.compute_list_bind_uniform_set(cl, s0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	var n := 0
	for j in jobs:
		var i: int = j[0]; var r: Rect2i = j[1]
		var pb := PackedByteArray(); pb.resize(32)
		pb.encode_s32(0, r.position.x); pb.encode_s32(4, r.position.y); pb.encode_s32(8, r.size.x); pb.encode_s32(12, r.size.y)
		pb.encode_float(16, float(i)); pb.encode_float(20, t0*pow(2.0, i)); pb.encode_float(24, float(N)); pb.encode_float(28, float(LH))
		rd.compute_list_set_push_constant(cl, pb, 32)
		rd.compute_list_dispatch(cl, (r.size.x + 7)/8, (r.size.y + 7)/8, 1)
		n += r.size.x*r.size.y
	if hjobs.size():                                                       # 高度写完 → 屏障 → 地平线
		rd.compute_list_add_barrier(cl)
		rd.compute_list_bind_compute_pipeline(cl, pipe_h)
		rd.compute_list_bind_uniform_set(cl, set_h, 0)
		for j in hjobs:
			var i: int = j[0]; var r: Rect2i = j[1]
			var pb := PackedByteArray(); pb.resize(32)
			pb.encode_s32(0, r.position.x); pb.encode_s32(4, r.position.y); pb.encode_s32(8, r.size.x); pb.encode_s32(12, r.size.y)
			pb.encode_float(16, float(i)); pb.encode_float(20, t0*pow(2.0, i)); pb.encode_float(24, float(N)); pb.encode_float(28, 0.0)
			rd.compute_list_set_push_constant(cl, pb, 32)
			rd.compute_list_dispatch(cl, (r.size.x + 7)/8, (r.size.y + 7)/8, 1)
			st_htex += r.size.x*r.size.y
	rd.compute_list_end()
	rd.capture_timestamp(TS1)
	st_tex += n; st_disp_frames += 1; st_max_tex = maxi(st_max_tex, n)


func _read_timestamps() -> void:
	var fr := rd.get_captured_timestamps_frame()                         # 同一帧的结果可能被读到好几次：按帧号去重
	if fr == _last_ts_frame: return
	_last_ts_frame = fr
	var a := -1.0
	for k in rd.get_captured_timestamps_count():
		var nm := rd.get_captured_timestamp_name(k)
		if nm == TS0: a = rd.get_captured_timestamp_gpu_time(k)
		elif nm == TS1 and a >= 0.0:
			st_gpu_us += rd.get_captured_timestamp_gpu_time(k) - a; st_gpu_n += 1; a = -1.0

var _last_ts_frame := -1


func report() -> String:
	# 注：GPU 时间别用这里的时间戳（draw graph 重排后读数不对，见调研文档 §6.4）；用 --gpu-profile 的「材质缓存烘焙」段，或帧时间
	var s := "[材质缓存] %d 帧里 %d 帧烘焙，共 %.2f M 纹素（每帧平均 %.0f k、最多 %.0f k），跳变全烘 %d 次；地平线 %.2f M 纹素" % [st_frames, st_disp_frames,
		st_tex/1e6, st_tex/1000.0/maxf(st_frames, 1), st_max_tex/1000.0, st_full, st_htex/1e6]
	st_htex = 0
	st_tex = 0; st_frames = 0; st_disp_frames = 0; st_gpu_us = 0.0; st_gpu_n = 0; st_max_tex = 0; st_full = 0
	return s


func free_all() -> void:
	for r in [set0, set1, set_h, ubo, pipe, shader, pipe_h, shader_h, samp_h, tex_a, tex_b, tex_h, tex_c0, tex_c1]:
		if r.is_valid(): rd.free_rid(r)
	for k in samplers: rd.free_rid(samplers[k])
	for k in dummy: rd.free_rid(dummy[k])
