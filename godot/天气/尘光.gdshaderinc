// 天气模块：悬浮尘的光照（尘卷风、扬尘共用）。单位同 实景：W/m²/sr，曝光由 Environment 统一乘。
// 光学薄的尘团：像素 = 背景·(1 − α) + α·J，J = 源函数 = ω₀·[E_sun·p(Θ) + 4π 平均天光]
// （单次散射；环境光按各向同性近似 ∫p·L dω ≈ L 的 4π 平均）。
// 相函数、单次散射反照率与 火星大气.py 今天() 相同（双 HG：前向 g 0.72 占 90%，后向 −0.25；ω₀ 0.975 / 0.94 / 0.85）。
// 远处再叠空气透视（同 公共.gdshaderinc 的 aerial：T = exp(−β d)，L_air = 视线方向压到地平线上的天空辐亮度）。
uniform sampler2D sky_tex : filter_linear, repeat_enable;
uniform float E_TOP = 694.4;
uniform float beta_ap = 6.2037e-5;
uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0);      // 指向太阳（Godot 坐标）
uniform vec3 E_sun = vec3(0.0);                    // 法向直射照度（W/m²，已乘透过率）
uniform vec3 L_amb = vec3(0.0);                    // 天空图（含地平线下的地面）全 4π 的平均辐亮度
uniform vec3 ssa = vec3(0.975, 0.94, 0.85);

float dust_hg(float c, float g) { return (1.0 - g*g)/(4.0*PI*pow(1.0 + g*g - 2.0*g*c, 1.5)); }

vec3 dust_source(vec3 view_dir) {                   // view_dir：相机 → 尘（单位向量）
	float c = dot(view_dir, sun_dir);               // 同 火星大气.integrate：cosΘ = 视线 · 太阳方向（朝太阳看 = 前向散射）
	float p = 0.9*dust_hg(c, 0.72) + 0.1*dust_hg(c, -0.25);
	return ssa*(E_sun*p + L_amb);
}

vec3 dust_air(vec3 view_dir, float d, out float T) {
	vec3 e = normalize(vec3(view_dir.x, -view_dir.z, view_dir.y));
	e = normalize(vec3(e.xy, max(e.z, 0.0) + 0.02));
	T = exp(-beta_ap*d);
	vec2 uv = vec2(0.5 - atan(e.y, e.x)/(2.0*PI), 0.5 - asin(clamp(e.z, -1.0, 1.0))/PI);
	return E_TOP*texture(sky_tex, uv).rgb;
}

// 软粒子：与不透明场景的深度差在 fade 米内渐隐（Godot 4.3+ 反向 Z，NDC z = 深度缓冲值）
float dust_soft(sampler2D dtex, vec2 suv, mat4 inv_proj, float vz, float fade) {
	float z = texture(dtex, suv).r;
	vec4 v = inv_proj*vec4(suv*2.0 - 1.0, z, 1.0);
	return clamp((vz - v.z/v.w)/fade, 0.0, 1.0);
}
