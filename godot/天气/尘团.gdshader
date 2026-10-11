// 尘团（尘卷风粒子的画法）：面向相机的软圆片 + 噪声；unshaded，颜色 = 尘光.gdshaderinc 的源函数（被日光与天光照亮，不是自发光）。
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, fog_disabled, skip_vertex_transform, shadows_disabled;
#include "res://天气/尘光.gdshaderinc"
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform int dbg = 0;                                               // 测帧诊断：1 不读深度（无软粒子）、2 片元只出常色
varying float v_a;
varying float v_rnd;
varying float v_size;
varying vec3 v_w;
varying vec3 v_L;                                                   // 尘团的辐亮度（逐顶点算：一个尘团里方向几乎不变）

void vertex() {
	vec3 c = MODEL_MATRIX[3].xyz;
	float s = length(MODEL_MATRIX[0].xyz);
	// 相机钻进涡柱时：离相机不到一个尘团大小的尘团渐隐并退化成零面积（不产生片元，省掉满屏叠画）
	float kc = smoothstep(0.6*s, 1.6*s, distance(c, CAMERA_POSITION_WORLD));
	vec3 w = c + (INV_VIEW_MATRIX[0].xyz*VERTEX.x + INV_VIEW_MATRIX[1].xyz*VERTEX.y)*s*step(0.01, kc);
	v_w = w; v_size = s; v_a = COLOR.a*kc; v_rnd = INSTANCE_CUSTOM.w;
	vec3 dir = normalize(c - CAMERA_POSITION_WORLD);
	float T; vec3 La = dust_air(dir, length(c - CAMERA_POSITION_WORLD), T);
	v_L = dust_source(dir)*T + (1.0 - T)*La;
	VERTEX = (VIEW_MATRIX*vec4(w, 1.0)).xyz;
	NORMAL = vec3(0.0, 0.0, 1.0);
}

void fragment() {
	vec2 q = UV*2.0 - 1.0;
	float r2 = dot(q, q);
	if (r2 > 1.0 || v_a < 1e-4) discard;
	float n = texture(noise_tex, UV*0.6 + vec2(v_rnd*13.1, v_rnd*7.3)).r;
	float a = v_a*exp(-3.0*r2)*clamp(0.2 + 1.6*n*n, 0.0, 2.0);
	if (dbg == 2) {
		ALBEDO = vec3(50.0);
	} else {
		if (dbg != 1) a *= dust_soft(depth_tex, SCREEN_UV, INV_PROJECTION_MATRIX, VERTEX.z, 0.25*v_size);
		ALBEDO = v_L;
	}
	ALPHA = clamp(a, 0.0, 1.0);
}
