// 石块：底色（实例颜色：实测石块＝对象色、统计石块＝全局石色，都已乘每块随机明暗）× 基岩微观细节（三平面投影）＋ 凹凸。
// 同 58 rock_material()；三平面投影用世界坐标（米），Blender 的统计石块用归一化的对象坐标，尺度略有不同。
shader_type spatial;
render_mode cull_back, specular_disabled, skip_vertex_transform;   // 自己变换：MultiMesh 非等比缩放时 Godot 不用逆转置，法线会歪

#include "res://着色器/公共.gdshaderinc"
#include "res://着色器/中观位移.gdshaderinc"
#include "res://着色器/地平线GI.gdshaderinc"

uniform sampler2D detail_alb : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D detail_h : filter_linear_mipmap_anisotropic, repeat_enable;
uniform float detail_size = 0.2304;
uniform float detail_gain = 2.0;                                  // 反照率细节的解码倍率（scene.json detail.micro_2.gain）
// 积尘（§15）：实例色是从上方 / 斜上方照片取的，等于"积了尘的顶面"。侧面、底面尘少，露出暗而偏灰的岩石本色。
// 干净岩石 / 积尘反照率比按 MER Pancam 光谱估（Bell et al. 2004：亮尘 750 nm 约 0.30、430 nm 约 0.07；
// 刷净的玄武岩约 0.13 / 0.06）→ 红 0.45、绿约 0.6、蓝 0.85。实例 alpha = 这块石头的积尘程度（统计石块随机，实测石块 1）。
uniform vec3 clean_ratio = vec3(1.0);                           // 默认不分两色：真照片检验里分两色让石块像素误差变大（§15），--石净=0.45,0.6,0.85 打开
uniform float rock_dust = 1.0;                                    // 全局积尘倍率（0 = 全是干净岩面，诊断 / 风暴后）
uniform int dbg = 0;                                              // 诊断：1＝只用实例色，2＝不要凹凸，3＝染红

varying vec3 Pw;
varying vec3 Nw;
varying vec3 v_ambc;                                              // 逐通道 EON 环境修正（fragment 写、light 读）
varying float v_sun;                                              // G2 远处地影（见 地形.gdshader）

void vertex() {
	Pw = (MODEL_MATRIX*vec4(VERTEX, 1.0)).xyz;
	vec3 o = MODEL_MATRIX[3].xyz;                                  // 中观位移：撒石已按 h_cpu（含位移）放好，只补地面渐隐（中观位移.gdshaderinc rock_lift）
	Pw.y += rock_lift(o, distance(o, lod_cam));
	mat3 M = mat3(MODEL_MATRIX);                                   // 余子式矩阵＝det·逆转置；扁平石块（高 0）时也不出 NaN
	Nw = normalize(mat3(cross(M[1], M[2]), cross(M[2], M[0]), cross(M[0], M[1]))*NORMAL);
	VERTEX = (VIEW_MATRIX*vec4(Pw, 1.0)).xyz;
	NORMAL = normalize(mat3(VIEW_MATRIX)*Nw);
}

vec4 tri(sampler2D t, vec3 p, vec3 n) {
	vec3 w = pow(abs(n), vec3(4.0)); w /= (w.x + w.y + w.z);       // 近似 Blender BOX 投影 blend 0.3
	return w.x*texture(t, p.zy/detail_size) + w.y*texture(t, p.xz/detail_size) + w.z*texture(t, p.xy/detail_size);
}

void fragment() {
	vec3 col = COLOR.rgb*detail_gain*tri(detail_alb, Pw, Nw).rgb;
	float cov = clamp(smoothstep(0.0, 0.65, Nw.y)*COLOR.a*rock_dust + (fbm_noise(Pw*9.0) - 0.5)*0.6, 0.0, 1.0);   // 朝上才积尘，边缘用噪声打散
	col = mix(col*clean_ratio, col, cov);
	if (dbg == 1) col = COLOR.rgb;
	float h = tri(detail_h, Pw, Nw).r;
	if (dbg != 1 && dbg != 2) NORMAL = bump_normal(VERTEX, normalize(NORMAL), h);
	float d = length(VERTEX); float T; vec3 Lap;
	aerial(Pw - CAMERA_POSITION_WORLD, d, T, Lap);
	ALBEDO = col*T; EMISSION = (1.0 - T)*Lap;
	if (dbg == 3) { ALBEDO = vec3(0.0); EMISSION = vec3(30.0, 0.0, 0.0); }   // 诊断：石块染红（看撒了多少、埋了多少）
	ROUGHNESS = 1.0; METALLIC = 0.0; SPECULAR = 0.0;
	vec3 ea = eon_ambient3(NORMAL, VIEW, col, 0.6);
	AO = dot(ea, LUM_W); v_ambc = ea/AO; ALBEDO *= v_ambc;
	if (hz_on == 1) AO *= hz_sky_ratio(Pw);                     // 地平线 GI：地形和车挡掉的天光（见 地平线GI.gdshaderinc hz_sky_ratio）
	v_sun = hz_sun_vis(Pw.xz);                                    // G2 远处地影
}

void light() {
	float att = LIGHT_IS_DIRECTIONAL ? min(ATTENUATION, v_sun) : ATTENUATION;
	DIFFUSE_LIGHT += oren_nayar(NORMAL, LIGHT, VIEW, ALBEDO/v_ambc, 0.6)*LIGHT_COLOR*att/v_ambc;   // 去掉 fragment 里乘进 ALBEDO 的逐通道环境修正
}
