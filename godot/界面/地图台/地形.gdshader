shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;
#include "高度.gdshaderinc"
instance uniform vec3 ring = vec3(0.0, 0.0, 1.0);   // 环的中心 E N 和格距 m；网格坐标是整数（VERTEX.xz）
uniform float haze = 1.0e9;                           // 雾化距离（视线方向）：线随远处淡出
uniform vec3 c_main = vec3(1.0);
uniform vec3 c_live = vec3(0.3, 0.8, 0.9);
uniform vec3 c_warn = vec3(1.0, 0.69, 0.0);
uniform vec3 wl = vec3(0.0, 1.0, 0.0);      // 三套等高线的权重：x = 1 m（粗 5 m），y = 5 m（粗 25 m），z = 50 m（粗 250 m）
uniform float px = 1.0;                      // 屏高 / 1440
uniform float mpp = 3.0;                     // 焦点处每像素多少米
uniform float dots_a = 1.0;
uniform float cell_n = 8.0;
uniform float fade_a = 1.0;
uniform vec2 edge = vec2(49000.0, 83000.0);  // 数据中心为圆心的渐隐圈：内圈起淡，外圈全无并且不画面（方形数据边永远不出现）
uniform float fpx = 1668.0;                  // 焦距（像素）：按每个像素自己的深度算「一个像素多少米」
varying vec2 v_en;
varying float v_slope;
varying vec2 v_grad;                         // 地面梯度（dh/d东, dh/d北），已乘鼓起比例
uniform float fill = 1.0;                    // 地表填色的强度（0 = 只有线，和原来一样）

void vertex() {
	vec2 en = ring.xy + VERTEX.xz * ring.z;
	float g = growp(en);
	float h = H(en);
	float d = max(max(10.0 * mpp / 2.8, 0.4), ring.z);
	float hx = H(en + vec2(d, 0.0)) - H(en - vec2(d, 0.0));
	float hy = H(en + vec2(0.0, d)) - H(en - vec2(0.0, d));
	v_slope = degrees(atan(length(vec2(hx, hy)) / (2.0 * d)));
	v_en = en;
	v_grad = vec2(hx, hy) / (2.0 * d) * g;
	VERTEX = vec3(en.x, h * VE * g, -en.y);
}

float cline(float h, float step, float w) {
	float x = h / step;
	float fw = max(fwidth(x), 1e-4);
	float d = abs(fract(x + 0.5) - 0.5) / fw;
	float a = 1.0 - smoothstep(w * 0.5 - 0.5, w * 0.5 + 0.5, d);
	return a * smoothstep(8.0, 24.0, 1.0 / fw);          // 线在屏幕上挤到 24 px 以内开始淡、8 px 以内不画：远处不再是一片白条纹，缩放时也不闪
}
float dots(vec2 en, float cs, float r, float lm) {
	vec2 c = (floor(en / cs) + 0.5) * cs;
	float dpx = length(en - c) / max(lm, 1e-4);
	return 1.0 - smoothstep(r - 0.6, r + 0.6, dpx);
}

void fragment() {
	vec3 col = bgc(SCREEN_UV);
	float gr = growraw(v_en);
	float h = H(v_en);
	float a = 0.0;
	float k = px;
	float l1 = max(cline(h, 1.0, 1.3 * k) * 0.55, cline(h, 5.0, 2.2 * k) * 1.0) * wl.x;
	float l5 = max(cline(h, 5.0, 1.3 * k) * 0.50, cline(h, 25.0, 2.2 * k) * 1.0) * wl.y;
	float l50 = max(cline(h, 50.0, 1.3 * k) * 0.50, cline(h, 250.0, 2.2 * k) * 1.0) * wl.z;
	float zv = -VERTEX.z;
	float hz = 1.0 / (1.0 + pow(zv / haze, 2.0));
	float rc = length(v_en);
	if (rc > edge.y) discard;
	float ef = 1.0 - smoothstep(edge.x, edge.y, rc);
	a = max(l1, max(l5, l50)) * fade_a * hz * ef;
	a *= step(0.001, gr);
	// 地表填色：按坡向明暗（光从西北上方来），让起伏读得出来；只有线时地形看不清。比线淡得慢，远处仍是一个面，地平线看得见。
	// 梯度逐像素从高度图取，步长跟这个像素盖住的地面大小走：不跟网格走，所以缩放时嵌套环换格距、挪位置都不会在明暗上留下一条条会动的带子
	float dg = clamp(length(fwidth(v_en)) * 1.5, 0.5, 4000.0);
	vec2 gf = vec2(H(v_en + vec2(dg, 0.0)) - H(v_en - vec2(dg, 0.0)), H(v_en + vec2(0.0, dg)) - H(v_en - vec2(0.0, dg))) / (2.0 * dg) * growp(v_en);
	vec3 nrm = normalize(vec3(-gf.x * VE, 1.0, -gf.y * VE));                  // (东, 上, 北)
	float sh = clamp(dot(nrm, normalize(vec3(-0.55, 0.62, 0.55))), 0.0, 1.0);
	float hzf = 1.0 / (1.0 + pow(zv / (haze * 2.5), 2.0));
	float fv = mix(0.035, 0.26, sh * sh) * fill * fade_a * hzf * ef * smoothstep(0.0, 1.0, gr);
	col = mix(col, c_main, fv);
	float front = (gr > 0.0 && gr < 0.3) ? 1.0 : 0.0;
	vec3 lc = mix(c_main, c_live, front * 0.9);
	col = mix(col, lc, clamp(a + front * a * 0.5, 0.0, 1.0));
	// 坡度 > 20°：琥珀半调网点（两套格子交叉淡化，屏幕上间距基本不变）
	if (v_slope > 20.0 && dots_a > 0.01) {
		float lm = max(zv, 1.0) / fpx;                      // 这个像素处一个像素多少米
		float lg = log2(10.7 * lm);
		float cs = exp2(floor(lg));
		float r = (1.0 + 1.8 * min((v_slope - 20.0) / 15.0, 1.0)) * k;   // 半径以像素计，最多 2.8 px × 屏高比，不随贴近变大
		float d0 = dots(v_en, cs, r, lm);
		float d1 = dots(v_en, cs * 2.0, r, lm);
		float dd = mix(d0, d1, lg - floor(lg));
		col = mix(col, c_warn, dd * 0.85 * dots_a * smoothstep(0.55, 1.0, gr) * hz * ef);
	}
	ALBEDO = s2l(col);
}
