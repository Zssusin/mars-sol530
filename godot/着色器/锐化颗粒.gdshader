// 屏幕后处理：CAS 锐化 + 亮度相关胶片颗粒（docs/地面材质/颗粒感.md §1）。
// 挂在 CanvasLayer 的全屏 ColorRect 上读屏幕纹理：此时 3D 已色调映射，TAA / FSR2 也做完了（CompositorEffect 的回调都在它们之前，做不到）。
//
// CAS = AMD FidelityFX Contrast Adaptive Sharpening（MIT，Copyright (c) 2017-2019 Advanced Micro Devices；
// github.com/GPUOpen-Effects/FidelityFX-CAS ffx-cas/ffx_cas.h，十字核、不放大的那条路径）：
//   mn / mx = 十字 5 点每通道的最小 / 最大；amp = sqrt(sat(min(mn, 1 − mx) / mx))；w = −amp / lerp(8, 5, 锐度)；
//   输出 = sat((b + d + f + h)·w + e) / (1 + 4w)。对比越高 / 越接近 0 或 1 的地方 amp 越小：不在边缘和高光上过冲。
// 颗粒：像素哈希的三角分布噪声（零均值），幅度按显示亮度 L 加权 ∝ sqrt(L)(1 − L)（中间调最强，纯黑纯白为 0；接近传感器散粒噪声随信号的形状），
// 在 CAS 之后加（不被锐化放大）；每 1/颗粒帧率 秒换一次图案（默认 24 Hz，不是每帧：60 fps 下每帧换像电视雪花）。
shader_type canvas_item;
render_mode blend_disabled;

uniform sampler2D scr : hint_screen_texture, repeat_disable, filter_nearest;
uniform float sharp = 0.5;            // CAS 锐度 0..1（0 = 关）
uniform float grain = 0.012;          // 颗粒幅度（显示值，0..1；0 = 关）
uniform float grain_seed = 0.0;       // 图案编号（后处理.gd 按颗粒帧率递增）

float h12(vec2 p, float s) {
	vec3 q = fract(vec3(p, s)*vec3(0.1031, 0.1030, 0.0973));
	q += dot(q, q.yzx + 33.33);
	return fract((q.x + q.y)*q.z);
}

void fragment() {
	vec2 px = SCREEN_PIXEL_SIZE;
	vec3 e = textureLod(scr, SCREEN_UV, 0.0).rgb;
	vec3 c = e;
	if (sharp > 0.0) {
		vec3 b = textureLod(scr, SCREEN_UV + vec2(0.0, -px.y), 0.0).rgb;
		vec3 d = textureLod(scr, SCREEN_UV + vec2(-px.x, 0.0), 0.0).rgb;
		vec3 f = textureLod(scr, SCREEN_UV + vec2(px.x, 0.0), 0.0).rgb;
		vec3 h = textureLod(scr, SCREEN_UV + vec2(0.0, px.y), 0.0).rgb;
		vec3 mn = min(min(min(d, e), min(f, b)), h);
		vec3 mx = max(max(max(d, e), max(f, b)), h);
		vec3 amp = clamp(min(mn, 1.0 - mx)/max(mx, 1e-4), 0.0, 1.0);
		amp = sqrt(amp);
		vec3 w = amp*(-1.0/mix(8.0, 5.0, clamp(sharp, 0.0, 1.0)));
		c = clamp((b*w + d*w + f*w + h*w + e)/(1.0 + 4.0*w), 0.0, 1.0);
	}
	if (grain > 0.0) {
		float L = dot(c, vec3(0.2126, 0.7152, 0.0722));
		float wl = clamp(sqrt(L)*(1.0 - L)*2.6, 0.0, 1.0);
		vec2 p = FRAGCOORD.xy;
		float n = h12(p, grain_seed) + h12(p + 37.7, grain_seed + 1.7) - 1.0;   // 三角分布 −1..1
		c += n*grain*wl;
	}
	COLOR = vec4(c, 1.0);
}
