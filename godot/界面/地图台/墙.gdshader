shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
#include "高度.gdshaderinc"
uniform vec4 rect;
uniform vec3 c_main = vec3(1.0);
uniform float ubase = -100.0;
uniform float wall_a = 1.0;
uniform vec3 wl = vec3(0.0, 1.0, 0.0);
uniform float px = 1.0;
uniform float zdist = 10000.0;
varying vec3 v_uv;
varying float v_front;
varying float v_h;
const vec2 NRM[4] = vec2[4](vec2(0.0, -1.0), vec2(1.0, 0.0), vec2(0.0, 1.0), vec2(-1.0, 0.0));

void vertex() {
	int id = int(floor(COLOR.r * 3.0 + 0.5));
	float u = UV.x;
	vec2 en;
	if (id == 0) en = vec2(mix(rect.x, rect.y, u), rect.z);
	else if (id == 1) en = vec2(rect.y, mix(rect.z, rect.w, u));
	else if (id == 2) en = vec2(mix(rect.y, rect.x, u), rect.w);
	else en = vec2(rect.x, mix(rect.w, rect.z, u));
	float h = H(en);
	float top = h * VE * growp(en);
	float y = mix(top, ubase * VE * (anim_on > 0.5 ? clamp(anim.x * 3.0, 0.0, 1.0) : 1.0), UV.y);
	vec3 wp = vec3(en.x, y, -en.y);
	vec3 cam = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 nw = vec3(NRM[id].x, 0.0, -NRM[id].y);
	v_front = dot(nw, cam - wp) > 0.0 ? 1.0 : 0.0;
	wp += normalize(cam - wp) * zdist * 0.004;       // 沿视线挪近一点：不动屏幕位置，只避免和地形边缘打架
	v_uv = vec3(UV, u);
	v_h = y / VE;
	VERTEX = wp;
}

float cl(float h, float step, float w) {
	float x = h / step; float fw = max(fwidth(x), 1e-4);
	float d = abs(fract(x + 0.5) - 0.5) / fw;
	return (1.0 - smoothstep(w * 0.5 - 0.5, w * 0.5 + 0.5, d)) * smoothstep(3.0, 7.0, 1.0 / fw);
}
void fragment() {
	float vy = v_uv.y;
	float fwy = max(fwidth(vy), 1e-5);
	float top2 = 1.0 - smoothstep(px - 0.5, px + 0.5, vy / fwy);                 // 剖面线
	float bot = 1.0 - smoothstep(0.75 * px - 0.5, 0.75 * px + 0.5, (1.0 - vy) / fwy);
	float a;
	if (v_front > 0.5) {
		float st = max(cl(v_h, 5.0, px), max(cl(v_h, 25.0, px), cl(v_h, 250.0, px)));
		float strata = max(st * 0.0, max(cl(v_h, 5.0, px) * wl.x, max(cl(v_h, 25.0, px) * wl.y, cl(v_h, 250.0, px) * wl.z)));
		a = max(max(0.045, strata * 0.16), max(top2 * 0.85, bot * 0.45));
	} else {
		a = top2 * 0.6;
	}
	float fu = max(fwidth(v_uv.x), 1e-5);
	float edge = (1.0 - smoothstep(0.75 * px - 0.5, 0.75 * px + 0.5, min(v_uv.x, 1.0 - v_uv.x) / fu));
	a = max(a, edge * 0.5 * v_front);
	ALBEDO = s2l(c_main);
	ALPHA = clamp(a * wall_a, 0.0, 1.0);
}
