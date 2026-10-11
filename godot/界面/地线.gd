# 屏宽线（界面 5）：贴在地面上的线，线宽按「屏幕像素」算，不随透视变粗变细。
#   为什么：主菜单的罗盘环原来是 Decal（SVG 烤成贴图投到地面）——斜看时贴图被拉长、mipmap 糊掉、地形起伏处投影断开，线宽忽粗忽细。
#   做法：每条线段 = 一个四边形，着色器把两个端点投到屏幕上，沿屏幕上的法线方向各挪 宽/2 像素（两端再向外延 宽/2，接缝处不留缺口）。
#   仍是普通 3D 网格、走深度测试：车身和石块照常挡住它；加一点点深度偏移，免得和地形网格打架（z-fighting）。
#   每个 线集 = 两层（深色外扩 + 本体），用法：var 线 := 地线.new(宽px, 光边px); add_child(线); 线.设(段, 颜色, 透)；段 = [[a Vector3, b Vector3, 点透 0–1], …]。
extends Node3D

const 着色 := """
shader_type spatial;
render_mode unshaded, depth_draw_never, cull_disabled, blend_mix, fog_disabled;
uniform vec4 col : source_color = vec4(1.0);
uniform float hw = 1.5;
uniform float energy = 1.0;
uniform float bias = 0.004;
void vertex() {
	vec4 a = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(VERTEX, 1.0));
	vec4 b = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(CUSTOM0.xyz, 1.0));
	vec2 hv = VIEWPORT_SIZE * 0.5;
	vec2 sa = a.xy / a.w * hv;
	vec2 sb = b.xy / b.w * hv;
	vec2 d = sb - sa;
	float L = length(d);
	d = L > 1e-4 ? d / L : vec2(1.0, 0.0);
	vec2 n = vec2(-d.y, d.x);
	vec2 off = (n * UV.x * hw - d * hw) / hv;
	vec2 ndc = a.xy / a.w + off;
	POSITION = vec4(ndc * a.w, a.z * (1.0 + bias), a.w);      // 深度偏移按比例（≈ 离相机的 0.4 %，14 m 处约 6 cm）：绝对偏移在远处会大得把线推到车身前面
}
void fragment() {
	ALBEDO = col.rgb * energy;
	ALPHA = col.a * COLOR.a;
}
"""
static var _着色: Shader = null

var 本: MeshInstance3D
var 边: MeshInstance3D
var 本材: ShaderMaterial
var 边材: ShaderMaterial
var 宽 := 3.0                                      # 线宽（1440p 像素，乘 令.s）
var 光边 := 3.2                                    # 深色外扩（同 件.线 的「线外」）
var 能 := 1.0                                      # 发光倍数（压过曝光）


func _init(宽px := 3.0, 光边px := 3.2, 优先 := 0) -> void:
	宽 = 宽px; 光边 = 光边px
	if _着色 == null:
		_着色 = Shader.new(); _着色.code = 着色
	本材 = _新材(优先 + 1); 边材 = _新材(优先)
	本 = MeshInstance3D.new(); 边 = MeshInstance3D.new()
	本.material_override = 本材; 边.material_override = 边材
	for m: MeshInstance3D in [边, 本]:
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		m.custom_aabb = AABB(Vector3(-5000, -5000, -5000), Vector3(10000, 10000, 10000))
		m.layers = 1 << 0
		add_child(m)


func _新材(优先: int) -> ShaderMaterial:
	var m := ShaderMaterial.new(); m.shader = _着色; m.render_priority = 优先
	return m


func 设(段: Array, 色: Color, 透 := 1.0, 暗 := Color(-1, 0, 0)) -> void:
	"""段：[[a, b, 点透], …]；色 本体颜色；透 整体不透明度；暗 = 外扩颜色（默认令牌暗色，a 0.55）。"""
	if 暗.r < 0.0: 暗 = Color(令.色["暗"], 0.55)
	var V := PackedVector3Array(); var O := PackedFloat32Array(); var U := PackedVector2Array(); var C := PackedColorArray(); var I := PackedInt32Array()
	for q: Array in 段:
		var a: Vector3 = q[0]; var b: Vector3 = q[1]; var al: float = q[2]
		var k := V.size()
		for e: Array in [[a, b, -1.0], [a, b, 1.0], [b, a, 1.0], [b, a, -1.0]]:      # b 端的法线方向相反，边号也反过来，四边形不扭
			V.append(e[0]); O.append_array([e[1].x, e[1].y, e[1].z]); U.append(Vector2(e[2], 0.0)); C.append(Color(1, 1, 1, al))
		I.append_array([k, k + 1, k + 3, k, k + 3, k + 2])
	if V.is_empty(): 本.mesh = null; 边.mesh = null; return
	var arr := []; arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = V; arr[Mesh.ARRAY_TEX_UV] = U; arr[Mesh.ARRAY_COLOR] = C; arr[Mesh.ARRAY_INDEX] = I; arr[Mesh.ARRAY_CUSTOM0] = O
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr, [], {}, Mesh.ARRAY_CUSTOM_RGB_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	本.mesh = m; 边.mesh = m
	着色参(色, 透, 暗)


func 着色参(色: Color, 透: float, 暗: Color) -> void:
	var s: float = 令.s
	本材.set_shader_parameter("col", Color(色, 色.a*透)); 本材.set_shader_parameter("hw", 宽*s*0.5); 本材.set_shader_parameter("energy", 能)
	边材.set_shader_parameter("col", Color(暗, 暗.a*透)); 边材.set_shader_parameter("hw", (宽 + 光边)*s*0.5); 边材.set_shader_parameter("energy", 1.0)
