// 地图台共用：15 层高度金字塔取高（同 docs/界面/地图样张/生成/全息.py 的 高()：每点取包含它的最细一层，外缘 15 % 和下一层交叉淡化），
// 加「按缩放选最细层」（kmin_f：连续值，整数两侧两层交叉淡化，换层不跳）和「打开动画」的鼓起比例。
uniform sampler2DArray hts : filter_linear, repeat_disable;
uniform float kmin_f = 8.0;
uniform float VE = 3.0;
uniform vec4 anim = vec4(99.0, 0.15, 1.0, 0.5);   // x 当前时刻（秒，样张时间线），y 脉冲起，z 脉冲长，w 鼓起用时
uniform float anim_on = 0.0;
uniform float dmax = 4000.0;
const float KMAX = 14.0;

float lvl(float k, vec2 en) {
	float hf = 6.0 * exp2(k);
	vec2 xz = vec2(en.x, -en.y);
	vec2 uv = ((xz + hf) / (2.0 * hf) * 600.0 + 0.5) / 601.0;
	return texture(hts, vec3(uv, k)).r;
}
float hk(vec2 en, float kmin) {
	float r = max(abs(en.x), abs(en.y));
	float k = clamp(ceil(log2(max(r, 1.0) / 5.97)), kmin, KMAX);
	float hf = 6.0 * exp2(k);
	float h = lvl(k, en);
	if (k < KMAX) {
		float t = clamp((r / hf - 0.82) / 0.15, 0.0, 1.0);
		t = t * t * (3.0 - 2.0 * t);
		if (t > 0.0) h = mix(h, lvl(k + 1.0, en), t);
	}
	return h;
}
float H(vec2 en) {
	float k0 = floor(kmin_f);
	float w = smoothstep(0.3, 0.7, kmin_f - k0);
	float a = hk(en, k0);
	return w > 0.001 ? mix(a, hk(en, k0 + 1.0), w) : a;
}
float growp(vec2 en) {
	if (anim_on < 0.5) return 1.0;
	float p = clamp((anim.x - (anim.y + anim.z * length(en) / dmax)) / anim.w, 0.0, 1.0);
	return 1.0 - pow(1.0 - p, 3.0);
}
float growraw(vec2 en) {   // 未缓动的进度 0–1（等高线前沿用）
	if (anim_on < 0.5) return 1.0;
	return clamp((anim.x - (anim.y + anim.z * length(en) / dmax)) / anim.w, 0.0, 1.0);
}
// 页底（样张 底()：压暗去饱和的照片 × 色板页底色 × 暗角），地形、画布背景共用
uniform sampler2D bg : filter_linear, repeat_disable;
uniform vec3 c_tint = vec3(0.03, 0.08, 0.09);
vec3 bgc(vec2 suv) {
	float g = texture(bg, suv).r;
	vec2 q = (suv - 0.5) * 2.0;
	float v = clamp(1.0 - 0.45 * dot(q, q), 0.35, 1.0);
	return vec3(g * 0.55 + c_tint * 0.45) * v;
}
vec3 s2l(vec3 c) { c = max(c, vec3(0.0)); return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c)); }
