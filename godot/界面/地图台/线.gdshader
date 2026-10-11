shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, blend_mix;
#include "高度.gdshaderinc"
// 贴地的屏幕等宽线（路线、距离圈）：每段 4 个顶点，在裁剪空间里沿屏幕法线展开。被地形挡住的部分画成淡虚线（读深度图比较）。
uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;
uniform vec3 c_col = vec3(0.3, 0.8, 0.9);
uniform vec2 vp = vec2(2560.0, 1440.0);
uniform float width = 4.0;
uniform float lift = 6.0;
uniform float alpha = 1.0;
uniform float prog = 1.0;          // 路线画出的比例（沿弧长）
uniform float hid_a = 0.35;        // 被挡部分的不透明度；0 = 不画
uniform float dash = 0.0;          // > 0：虚线，周期（像素），占空 6/13
uniform float mppx = 3.0;          // 每像素米数，把弧长换成像素
uniform float zs = 1.0;
varying float v_side;
varying float v_arc;
varying float v_f;
varying vec2 v_en;

void vertex() {
	vec2 en = VERTEX.xz;
	float side = VERTEX.y;
	vec3 pw = vec3(en.x, H(en) * VE * growp(en) + lift, -en.y);
	vec3 pp = vec3(UV.x, H(UV) * VE * growp(UV) + lift, -UV.y);
	vec3 pn = vec3(CUSTOM0.x, H(CUSTOM0.xy) * VE * growp(CUSTOM0.xy) + lift, -CUSTOM0.y);
	vec4 c0 = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(pw, 1.0));
	vec4 c1 = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(pp, 1.0));
	vec4 c2 = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(pn, 1.0));
	vec2 s0 = c0.xy / max(c0.w, 1e-3) * vp * 0.5;
	vec2 s1 = c1.xy / max(c1.w, 1e-3) * vp * 0.5;
	vec2 s2 = c2.xy / max(c2.w, 1e-3) * vp * 0.5;
	vec2 d1 = s0 - s1; vec2 d2 = s2 - s0;
	d1 = length(d1) > 1e-4 ? normalize(d1) : vec2(0.0);
	d2 = length(d2) > 1e-4 ? normalize(d2) : vec2(0.0);
	vec2 dir = d1 + d2;
	dir = length(dir) > 1e-3 ? normalize(dir) : (length(d2) > 0.0 ? d2 : (length(d1) > 0.0 ? d1 : vec2(1.0, 0.0)));
	vec2 d2n = length(d2) > 0.0 ? d2 : dir;
	vec2 nrm = vec2(-dir.y, dir.x);
	float miter = 1.0 / max(dot(nrm, vec2(-d2n.y, d2n.x)), 0.45);       // 斜接：转弯处两条边外侧对齐，内侧不叠；太尖的拐角限 2.2 倍
	float w = width * 0.5 + 1.0;
	vec2 off = nrm * side * w * miter;
	POSITION = c0 + vec4(off / (vp * 0.5) * c0.w, 0.0, 0.0);
	v_side = side * w / (width * 0.5 + 1e-3);
	v_arc = UV2.x; v_f = UV2.y; v_en = en;
}
void fragment() {
	if (v_f > prog) discard;
	float d = texture(depth_tex, SCREEN_UV).x;
	vec4 v = INV_PROJECTION_MATRIX * vec4(vec3(SCREEN_UV * 2.0 - 1.0, d), 1.0);
	v.xyz /= v.w;
	float zscene = -v.z; float zme = -VERTEX.z;
	bool hid = zme > zscene * 1.004 + max(6.0 * zs, 2.5);
	float cov = clamp((1.0 - abs(v_side)) * (width * 0.5 + 1.0) + 0.0, 0.0, 1.0);
	float a = cov * alpha;
	if (hid) a *= step(fract(v_arc / mppx / 13.0), 6.0 / 13.0);
	else if (dash > 0.0) a *= step(fract(v_arc / mppx / dash), 6.0 / 13.0);
	if (hid) a *= hid_a;
	if (a < 0.003) discard;
	ALBEDO = s2l(c_col);
	ALPHA = a;
}
