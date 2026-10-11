// 地平线 GI（地平线GI.gd、地形GI设计.md §3 G1）：E = Σ_k n·V_k(θ_k) + L_g·(π − Σ_k n·U_k(θ_k))；返回 E/π（写 IRRADIANCE）。
// 地平线图：第 k 层纹素间距 S = c0·2^k·stride，纹素 i 在 −half_k + i·S（Godot x、z）；4 张 RGBA8 数组各存 4 个方位（自北顺时针 0、22.5°…）。
// 编码 v ∈ [0, 1] 与天空表的仰角档正好对齐：表的 u = (v·(NB − 1) + 0.5)/NB。
uniform sampler2DArray hz_w0 : filter_linear, repeat_disable;  // (W_R.xyz, W_U.x)：天空变了由 C++ 重算（地平线GI.gd use_sky）
uniform sampler2DArray hz_w1 : filter_linear, repeat_disable;  // (W_G.xyz, W_U.y)
uniform sampler2DArray hz_w2 : filter_linear, repeat_disable;  // (W_B.xyz, W_U.z)
uniform vec4 hz_info = vec4(0.02, 6.0, 301.0, 15.0);            // c0、half0、每层纹素数、层数
uniform float hz_stride = 2.0;
uniform int hz_on = 0;
uniform vec3 hz_Lg = vec3(0.0);                                 // 平均地面辐亮度（引擎单位）

// G5 车的遮挡：一组球（世界坐标 xyz、半径 w）近似车身、RTG、桅杆头、臂、六个轮子；被挡的方向看到车腹（辐亮度 hz_belly）
uniform vec4 hz_sph[16];
uniform int hz_nsph = 0;
uniform vec4 hz_sph_bound = vec4(0.0, 0.0, 0.0, -1.0);           // 包围球：外面的像素直接跳过
uniform vec3 hz_belly = vec3(0.0);
// G2 远处地影：每个地平线纹素在太阳方位上的地平线仰角（弧度，float），太阳方位变了由 C++ 重算（地平线GI.gd set_sun）。
// 太阳仰角比它高就照得到，按太阳视半径做软边；和 CSM 取较暗者（近处 CSM 管石块和车，远处、CSM 范围外的地形全靠它）。
uniform sampler2DArray hz_sun : filter_linear, repeat_disable;
uniform int hz_sun_on = 0;
uniform float hz_sun_el = 0.0;                                    // 太阳仰角（弧度）
uniform float hz_sun_soft = 0.006;                                // 软边半宽（弧度）：太阳视半径 0.19° + 地平线插值的余量

uniform vec3 hz_open_E = vec3(1.0);                              // 开阔平地（各方位地平线 0°）朝上的天光 Σ V_k(0)·ŷ，算遮天比例用
uniform float hz_open_U = 3.14159265;

// 球对点 p（法线 n）的余弦加权遮挡比例（0..1）。上 / 下地平线：Quilez（iquilezles.org/articles/sphereao）；
// 跨地平线：Lagarde & de Rousiers 2014（Moving Frostbite to PBR，球面光源的 form factor）。
float _hz_sph_occ(vec3 p, vec3 n, vec4 sph) {
	vec3 di = sph.xyz - p;
	float l = length(di);
	float nl = dot(n, di/l);
	float h = max(l/sph.w, 1.0001);
	float h2 = h*h;
	float k2 = 1.0 - h2*nl*nl;
	float res = max(0.0, nl)/h2;
	if (k2 > 0.001) {
		res = nl*acos(clamp(-nl*sqrt((h2 - 1.0)/max(1.0 - nl*nl, 1e-6)), -1.0, 1.0)) - sqrt(k2*(h2 - 1.0));
		res = res/h2 + atan(sqrt(k2/(h2 - 1.0)));
		res /= PI;
	}
	return clamp(res, 0.0, 1.0);
}

float hz_rover_vis(vec3 p, vec3 n) {
	if (hz_nsph == 0 || distance(p, hz_sph_bound.xyz) > hz_sph_bound.w) return 1.0;
	float vis = 1.0;
	for (int i = 0; i < hz_nsph; i++) vis *= 1.0 - _hz_sph_occ(p, n, hz_sph[i]);
	return vis;
}

vec3 _hz_uv(vec2 xz, float k) {
	float half_k = hz_info.y*exp2(k), S = hz_info.x*exp2(k)*hz_stride;
	return vec3(((xz + half_k)/S + 0.5)/hz_info.z, k);
}

void _hz_level(vec2 xz, float k, out vec4 a, out vec4 b, out vec4 c) {
	vec3 uv = _hz_uv(xz, k);
	a = texture(hz_w0, uv); b = texture(hz_w1, uv); c = texture(hz_w2, uv);
}

// 选层同 地形LOD.gd h_data：能装下的最细层，外缘 8% 渐变到粗一层（返回带小数的层号）
float _hz_kf(vec2 xz) {
	float e = max(abs(xz.x), abs(xz.y));
	float k0 = max(0.0, ceil(log2(max(e, 1e-6)/(hz_info.y*0.98))));
	float hk = hz_info.y*exp2(k0);
	return min(k0 + clamp((e - 0.9*hk)/(0.08*hk), 0.0, 1.0), hz_info.w - 1.0);
}

// W = Σ_k V_k(θ_k)（每通道）和 Σ_k U_k(θ_k)：E 对法线是线性的，E = n·W
void hz_vectors(vec2 xz, out vec3 wr, out vec3 wg, out vec3 wb, out vec3 wu) {
	float kf = _hz_kf(xz);
	float k = floor(kf), t = kf - k;
	vec4 a, b, c;
	_hz_level(xz, k, a, b, c);
	if (t > 0.0) {
		vec4 a2, b2, c2;
		_hz_level(xz, k + 1.0, a2, b2, c2);
		a = mix(a, a2, t); b = mix(b, b2, t); c = mix(c, c2, t);
	}
	wr = a.xyz; wg = b.xyz; wb = c.xyz; wu = vec3(a.w, b.w, c.w);
}

// 片元里：E/π（写 IRRADIANCE），再乘车的遮挡
vec3 hz_irradiance(vec3 pw, vec3 n) {
	vec3 wr, wg, wb, wu;
	hz_vectors(pw.xz, wr, wg, wb, wu);
	vec3 hz_E = vec3(dot(n, wr), dot(n, wg), dot(n, wb));
	vec3 irr = max(hz_E + hz_Lg*max(PI - dot(n, wu), 0.0), vec3(0.0))/PI;
	float vis = hz_rover_vis(pw, n);
	return irr*vis + hz_belly*(1.0 - vis);
}

// 石块（任意朝向）：向量式只对法线半球装得下可见天空时成立，石块侧面、底面会把背后的天空当负值扣掉。
// 所以石块照旧用天空环境光（下半球是地面，任意朝向都对），只把 AO 乘上"这里朝上的天光 / 开阔平地朝上的天光"（含车的遮挡）。
float hz_sky_ratio(vec3 pw) {
	vec3 up = vec3(0.0, 1.0, 0.0);
	vec3 here = hz_irradiance(pw, up);
	vec3 open = max(hz_open_E + hz_Lg*(PI - hz_open_U), vec3(1e-6))/PI;
	return clamp(dot(here, LUM_W)/dot(open, LUM_W), 0.0, 1.0);
}

// G2：太阳可见度 0..1（地形挡太阳）。xz = Godot 世界 (x, z)
float hz_sun_vis(vec2 xz) {
	if (hz_sun_on == 0) return 1.0;
	float kf = _hz_kf(xz);
	float k = floor(kf), t = kf - k;
	float hor = texture(hz_sun, _hz_uv(xz, k)).r;
	if (t > 0.0) hor = mix(hor, texture(hz_sun, _hz_uv(xz, k + 1.0)).r, t);
	return smoothstep(-hz_sun_soft, hz_sun_soft, hz_sun_el - hor);
}

// G4 石块遮地面（地平线GI.gd rock_occ_*）：两级跟着相机走的可见度图（1 = 不挡），C++ 把每块石头当等体积球解析算。
// 被挡的方向看到石块侧面，辐亮度取 hz_rk_L × 平均地面辐亮度。只给地形用（石块自己不查，否则会被自己的球挡住）。
uniform sampler2D hz_rk0 : filter_linear, repeat_disable;        // 1 cm，±10 m
uniform sampler2D hz_rk1 : filter_linear, repeat_disable;        // 4 cm，±41 m
uniform vec3 hz_rk_rect0 = vec3(0.0, 0.0, -1.0);                 // 左上角 x、z，边长（m）
uniform vec3 hz_rk_rect1 = vec3(0.0, 0.0, -1.0);
uniform int hz_rk_on = 0;
uniform float hz_rk_L = 0.6;

float _hz_rk_at(sampler2D t, vec3 rect, vec2 xz, out float w) {
	vec2 uv = (xz - rect.xy)/rect.z;
	vec2 e = min(uv, 1.0 - uv);
	w = clamp(min(e.x, e.y)/0.05, 0.0, 1.0);                     // 图边 5% 里渐变到下一级
	return texture(t, uv).r;
}

float hz_rock_vis(vec2 xz) {
	if (hz_rk_on == 0) return 1.0;
	float w0, w1;
	float v0 = _hz_rk_at(hz_rk0, hz_rk_rect0, xz, w0);
	float v1 = _hz_rk_at(hz_rk1, hz_rk_rect1, xz, w1);
	return mix(mix(1.0, v1, w1), v0, w0);
}
