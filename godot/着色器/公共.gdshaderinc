// 地形、石块共用：噪声、凹凸、Oren–Nayar（EON）、空气透视。
uniform sampler2D sky_tex : filter_linear, repeat_enable;        // 火星大气 等距圆柱图（ENU，第 0 行＝天顶），E0 = 1
uniform float E_TOP = 694.4;                                      // 大气顶太阳照度 W/m²（sol 530：1361/1.40²）
uniform float beta_ap = 6.2037e-5;                               // 近地尘埃消光 τ/H（/m）

// —— 3D Perlin 梯度噪声，2 个八度（Blender 噪声纹理 Detail 1 的近似），返回约 0..1、均值 0.5
vec3 _h3(vec3 p) {
	p = vec3(dot(p, vec3(127.1, 311.7, 74.7)), dot(p, vec3(269.5, 183.3, 246.1)), dot(p, vec3(113.5, 271.9, 124.6)));
	return -1.0 + 2.0*fract(sin(p)*43758.5453123);
}
float _perlin(vec3 p) {
	vec3 i = floor(p), f = fract(p), u = f*f*f*(f*(f*6.0 - 15.0) + 10.0);
	float n000 = dot(_h3(i), f), n100 = dot(_h3(i + vec3(1, 0, 0)), f - vec3(1, 0, 0));
	float n010 = dot(_h3(i + vec3(0, 1, 0)), f - vec3(0, 1, 0)), n110 = dot(_h3(i + vec3(1, 1, 0)), f - vec3(1, 1, 0));
	float n001 = dot(_h3(i + vec3(0, 0, 1)), f - vec3(0, 0, 1)), n101 = dot(_h3(i + vec3(1, 0, 1)), f - vec3(1, 0, 1));
	float n011 = dot(_h3(i + vec3(0, 1, 1)), f - vec3(0, 1, 1)), n111 = dot(_h3(i + vec3(1, 1, 1)), f - vec3(1, 1, 1));
	return mix(mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y), mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y), u.z);
}
float fbm_noise(vec3 p) {
	p = mod(p, 1024.0);                                           // 远处也保住 float 精度（噪声只用于打破平铺）
	return 0.5 + 0.5*(_perlin(p) + 0.5*_perlin(p*2.0 + 17.0))/1.5*1.4;
}

// —— 凹凸：Mikkelsen 2010，同 Cycles Bump 节点（强度 1、距离 1）；p、n 在视空间
vec3 bump_normal(vec3 p, vec3 n, float h) {
	vec3 dpdx = dFdx(p), dpdy = dFdy(p);
	float dhdx = dFdx(h), dhdy = dFdy(h);
	vec3 r1 = cross(dpdy, n), r2 = cross(n, dpdx);
	float det = dot(dpdx, r1);
	vec3 grad = sign(det)*(dhdx*r1 + dhdy*r2);
	return normalize(abs(det)*n - grad);
}

// —— Oren–Nayar，能量守恒版 EON（Portsmouth 等 2024，Blender 4.3 起的 Diffuse BSDF）。
// 返回 f/ρ × cosθi（Godot 之后再乘 ALBEDO；LIGHT_COLOR 已含 π，所以灯的能量给 照度/π）。
const float C1_FON = 0.5 - 2.0/(3.0*PI);
const float C2_FON = 2.0/3.0 - 28.0/(15.0*PI);
float _E_FON(float mu, float r) {
	float m = 1.0 - mu;
	float GoverPi = m*(0.0571085289 + m*(0.491881867 + m*(-0.332181442 + m*0.0714429953)));
	return (1.0 + r*GoverPi)/(1.0 + C1_FON*r);
}
vec3 oren_nayar(vec3 n, vec3 l, vec3 v, vec3 rho, float r) {
	float mi = clamp(dot(n, l), 0.0, 1.0), mo = clamp(dot(n, v), 1e-4, 1.0);
	if (mi <= 0.0) return vec3(0.0);
	float s = dot(l, v) - mi*mo;
	float sot = s > 0.0 ? s/max(mi, mo) : s;
	float AF = 1.0/(1.0 + C1_FON*r);
	float f_ss = AF*(1.0 + r*sot)/PI;
	float avgEF = AF*(1.0 + C2_FON*r);
	vec3 rho_ms_over_rho = rho*avgEF/(vec3(1.0) - rho*(1.0 - avgEF));
	float k_ms = max(1e-7, 1.0 - _E_FON(mo, r))*max(1e-7, 1.0 - _E_FON(mi, r))/max(1e-7, 1.0 - avgEF)/PI;
	return (vec3(f_ss) + rho_ms_over_rho*k_ms)*mi;
}

// 环境光（天光、SDFGI）在 Godot 里按朗伯算；EON 在均匀照明下的方向反照率是
//   E(μo) = ρ·E_FON(μo) + ρ_ms·(1 − E_FON(μo))，比朗伯的 ρ 低约 10%（r = 0.8、ρ ≈ 0.3）。
// 返回 E/ρ，写进 AO（Godot 的 AO 只乘环境光）。
float eon_ambient(vec3 n, vec3 v, vec3 rho, float r) {
	float mo = clamp(dot(n, v), 1e-4, 1.0);
	float AF = 1.0/(1.0 + C1_FON*r);
	float avgEF = AF*(1.0 + C2_FON*r);
	float p = dot(rho, vec3(0.2126, 0.7152, 0.0722));
	float rms = p*avgEF/(1.0 - p*(1.0 - avgEF));
	float Eo = _E_FON(mo, r);
	return Eo + rms*(1.0 - Eo);
}

// 逐通道版（地形GI设计 §1 小修 2）：多次散射项按各通道的 ρ 算，不再先压成亮度。
// Godot 的 AO 只能是一个数，所以用法是：AO = 亮度加权值，再把各通道相对它的比值乘进 ALBEDO，light() 里除回去：
//   vec3 ea = eon_ambient3(...); AO = dot(ea, LUM_W); v_ambc = ea/AO; ALBEDO *= v_ambc;
//   light(): oren_nayar(…, ALBEDO/v_ambc, …)*LIGHT_COLOR*ATTENUATION/v_ambc
// 这样环境光 = 环境·ρ·E(ρ)/ρ 逐通道，直射不变。（ALBEDO 也喂给 SDFGI 体素，偏差 ≤ 约 3%。）
const vec3 LUM_W = vec3(0.2126, 0.7152, 0.0722);
vec3 eon_ambient3(vec3 n, vec3 v, vec3 rho, float r) {
	float mo = clamp(dot(n, v), 1e-4, 1.0);
	float AF = 1.0/(1.0 + C1_FON*r);
	float avgEF = AF*(1.0 + C2_FON*r);
	vec3 rms = rho*avgEF/(vec3(1.0) - rho*(1.0 - avgEF));
	float Eo = _E_FON(mo, r);
	return vec3(Eo) + rms*(1.0 - Eo);
}

// —— 空气透视（§3.9）：T = exp(−β d)，L = (1 − T)·E_TOP·L_sky(视线压到地平线上)
vec2 sky_uv(vec3 e) {                                            // ENU 单位方向 → 等距圆柱 UV
	return vec2(0.5 - atan(e.y, e.x)/(2.0*PI), 0.5 - asin(clamp(e.z, -1.0, 1.0))/PI);
}
void aerial(vec3 dir_godot, float d, out float T, out vec3 L) {
	vec3 e = normalize(vec3(dir_godot.x, -dir_godot.z, dir_godot.y));
	e = normalize(vec3(e.xy, max(e.z, 0.0) + 0.02));
	T = exp(-beta_ap*d);
	L = E_TOP*texture(sky_tex, sky_uv(e)).rgb;
}
