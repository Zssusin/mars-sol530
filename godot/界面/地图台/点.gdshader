shader_type spatial;
render_mode unshaded, depth_test_disabled, depth_draw_never, blend_mix, cull_disabled;
#include "高度.gdshaderinc"
// 已探索区点云：车走过的路两侧 ~35 m 的 4 m 抖动点，亮度 = 坡向明暗（光从西北来），点大小随距离；密度随缩放减
uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;
uniform vec3 c_col = vec3(1.0);
uniform float density = 1.0;
uniform float px = 1.0;
uniform float psize = 2.0;     // 焦点处点的像素直径
uniform float zs = 1.0;
uniform float alpha = 1.0;
uniform float zfocus = 10000.0;
uniform float dd = 4.0;
varying float v_b;
varying float v_hid;

void vertex() {
	vec2 en = vec2(VERTEX.x, VERTEX.z);
	float rnd = VERTEX.y;
	float h = H(en);
	float g = growp(en);
	float hx = H(en + vec2(dd, 0.0)) - H(en - vec2(dd, 0.0));
	float hy = H(en + vec2(0.0, dd)) - H(en - vec2(0.0, dd));
	vec3 n = normalize(vec3(-hx * VE / (2.0 * dd), -hy * VE / (2.0 * dd), 1.0));      // (E, N, U)
	vec3 sun = vec3(sin(radians(315.0)) * cos(radians(40.0)), cos(radians(315.0)) * cos(radians(40.0)), sin(radians(40.0)));
	float b = clamp(dot(n, sun), 0.0, 1.0);
	v_b = 0.12 + 0.43 * pow(b, 1.2);
	vec3 wp = vec3(en.x, h * VE * g + 0.6 * zs, -en.y);
	vec4 vv = VIEW_MATRIX * vec4(wp, 1.0);
	float z = -vv.z;
	POINT_SIZE = clamp(psize * zfocus / max(z, 1.0), 1.5, 5.0 * px) * (rnd < density ? 1.0 : 0.0);
	v_hid = z;
	POSITION = PROJECTION_MATRIX * vv;
	if (rnd >= density || g < 0.001) POSITION = vec4(2.0, 2.0, 2.0, 1.0);
}
void fragment() {
	vec2 pc = POINT_COORD - 0.5;
	float rr = length(pc) * 2.0;
	float d = texture(depth_tex, SCREEN_UV).x;
	vec4 v = INV_PROJECTION_MATRIX * vec4(vec3(SCREEN_UV * 2.0 - 1.0, d), 1.0);
	v.xyz /= v.w;
	if (v_hid > -v.z * 1.004 + 6.0 * zs) discard;
	float a = (1.0 - smoothstep(0.7, 1.0, rr)) * v_b * alpha;
	if (a < 0.004) discard;
	ALBEDO = s2l(c_col);
	ALPHA = a;
}
