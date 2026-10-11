// 扬尘的画法：沿风向拉长、绕风轴转向相机的软条（圆柱公告板），光照同 尘团.gdshader。
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, fog_disabled, skip_vertex_transform, shadows_disabled;
#include "res://天气/尘光.gdshaderinc"
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform vec3 wdir = vec3(-1.0, 0.0, 0.0);
varying float v_a;
varying float v_rnd;
varying float v_h;
varying vec3 v_w;
varying vec3 v_L;                                                   // 尘团的辐亮度（逐顶点算：一个尘团里方向几乎不变）

void vertex() {
	vec3 c = MODEL_MATRIX[3].xyz;
	float len = length(MODEL_MATRIX[0].xyz), hgt = length(MODEL_MATRIX[1].xyz);
	vec3 to_cam = normalize(CAMERA_POSITION_WORLD - c);
	vec3 ay = cross(wdir, to_cam);
	float side = length(ay);                                       // 顺着风看时条变短
	ay = side > 1e-3 ? ay/side : vec3(0.0, 1.0, 0.0);
	if (ay.y < 0.0) ay = -ay;
	vec3 w = c + wdir*VERTEX.x*len*max(side, 0.15) + ay*VERTEX.y*hgt;
	v_w = w; v_h = hgt; v_a = COLOR.a; v_rnd = INSTANCE_CUSTOM.z;
	vec3 dir = normalize(c - CAMERA_POSITION_WORLD);
	float T; vec3 La = dust_air(dir, length(c - CAMERA_POSITION_WORLD), T);
	v_L = dust_source(dir)*T + (1.0 - T)*La;
	VERTEX = (VIEW_MATRIX*vec4(w, 1.0)).xyz;
	NORMAL = vec3(0.0, 0.0, 1.0);
}

void fragment() {
	vec2 q = UV*2.0 - 1.0;
	float prof = (1.0 - q.x*q.x)*exp(-2.5*q.y*q.y);
	if (prof <= 0.0 || v_a < 1e-4) discard;
	float n = texture(noise_tex, vec2(UV.x*0.5 + v_rnd*9.7, UV.y*0.15 + v_rnd*3.1)).r;
	float a = v_a*prof*smoothstep(0.35, 0.8, n)*2.0;                  // 噪声切成一缕一缕
	a *= dust_soft(depth_tex, SCREEN_UV, INV_PROJECTION_MATRIX, VERTEX.z, max(0.5*v_h, 0.05));
	ALBEDO = v_L;
	ALPHA = clamp(a, 0.0, 1.0);
}
