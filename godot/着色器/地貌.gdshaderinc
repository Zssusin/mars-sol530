// 地貌印章（实景地形系统.md §14）：高程数据分辨不出的小撞击坑、风成沙纹，按数据分辨率自动出现（近处 Navcam 区没有，
// HiRISE 区补 0.5–4 m 的坑和米级沙纹，CTX 区补到 64 m 的坑）。地形.gdshader 顶点抬高 + 片元法线。
// 地貌.gd 里有逐位对应的 CPU 版（包围盒、车轮、撒石取高都用它）：改这里必须同样改那边。
// 输入 Godot 世界 xz（x 东、z 南）；返回 vec3(高 m, ∂h/∂x, ∂h/∂z)。fade：几何格距或像素足迹（m），比它小的特征渐隐防闪；CPU 传 0。
uniform float geo_on = 0.0;
uniform sampler2D geo_class : filter_linear, repeat_disable;     // HiRISE 地类 1 m、±1000 m（61 导出 geo_class.bin，CPU 同一份）
uniform float geo_half = 1000.0;
uniform vec4 geo_cr = vec4(0.003, 2.0, 0.2, 0.06);               // 撞击坑：N(>D) = C·D^−b（每 m²）、b、新鲜坑 d/D、老坑 d/D
uniform vec4 geo_cr2 = vec4(0.04, 0.5, 0.0, 0.0);                // 坑缘高 / D（新鲜）、老坑底积沙比例
uniform vec4 geo_cr_cls = vec4(1.0);                             // 各地类相对坑密度（沙、砾石、基岩、暗岩）
uniform vec4 geo_rp[3];                                          // 沙纹：λ、峰谷高、波脊法向（指向下风，Godot xz 单位向量）
uniform vec4 geo_rp2[3];                                         // 背风段占比、弯曲度（相位扭动，周期数）
uniform int geo_rp_n = 0;
// 实测沙纹场（docs/地面材质/沙纹.md，80_沙纹场.py 烘）：2 m 格 RGBA8 = 波矢方位、波长、相位、振幅权重；每格一列平面波，4 格相量相加取相位。
uniform float geo_rf_on = 0.0;
uniform sampler2D geo_rf : filter_nearest, repeat_disable;
uniform vec4 geo_rf_g = vec4(1000.0, 2.0, 1.0, 5.0);            // 半宽、格距、λ 下限、λ 上限
uniform vec4 geo_rf_p = vec4(0.0, 0.3, 0.15, 0.6);              // 峰谷高 H、背风占比、相干度渐隐 ρ0、ρ1
uniform int geo_rf_n = 1000;
uniform sampler2D geo_rf_st : filter_linear_mipmap_anisotropic, repeat_disable;   // 反照率条纹贴图（见 geo_rfield_alb）
uniform float geo_rf_alb = 0.0;                                // 反照率条纹幅度（±比例；HiRISE 里沙纹主要靠 ~3% 的亮度条纹可见），0 = 关
uniform sampler2D geo_rf_cov : filter_nearest, repeat_disable;   // 4×4 格一块：0 = 块里没有沙纹；否则 = 块内最大 G 字节 + 1（λ 上界，封顶 255），没沙纹 / 已渐隐光的区域一次取样就退出

const vec4 GEO_W0 = vec4(0.35, 0.35, 0.2, 0.1);                  // HiRISE 外（同 地形.gdshader 第 2 步）

float geo_s(float e, float h) { return smoothstep(0.92*h, h, e); }
// log2（高程数据分辨率 m）：近 2 cm、中 10 cm、HiRISE、CTX 20 m。HiRISE 区坑用 1 m（统计坑只补 < 4 m：≥ 4 m 的坑目录完整，
// 以后按真实位置印），沙纹用实测的 DTM 有效分辨率 8 m（资料/地貌参数/说明.md）。
float geo_dem_l(vec2 xz, float l_hirise) {
	float e = max(abs(xz.x), abs(xz.y));
	float l = -5.643856;
	l = mix(l, -3.321928, geo_s(e, 10.0));
	l = mix(l, l_hirise, geo_s(e, 50.0));
	l = mix(l, 4.321928, geo_s(e, 1000.0));
	return l;
}
vec4 geo_W(vec2 xz) {
	float e = max(abs(xz.x), abs(xz.y));
	vec4 k = textureLod(geo_class, xz/(2.0*geo_half) + 0.5, 0.0);   // 行 0 = 北沿 = z 最小 → v = 0.5 + z/(2·half)
	return mix(k, GEO_W0, geo_s(e, geo_half));
}
uint geo_hash(uint x) { x ^= x >> 16u; x *= 0x7feb352du; x ^= x >> 15u; x *= 0x5bd1e995u; x ^= x >> 16u; return x; }
float geo_u(uint h) { return float(h >> 8u)*(1.0/16777216.0); }

// part 0：高 + 全部坡度（CPU 同义）；1：顶点 —— 高（全部）+ 大特征的坡度（≥ 8 × split 格距）；2：片元 —— 只算小特征的坡度。
// 顶点、片元两份坡度相加 = 全部；大特征在顶点里算好插值过来，近处大多数像素不用再逐像素哈希。
float geo_part(float S, float split, int part) {
	if (part == 0) return 1.0;
	float kv = clamp(S/(8.0*split + 1e-9) - 1.0, 0.0, 1.0);
	return part == 1 ? kv : 1.0 - kv;
}
vec3 geo_craters(vec2 xz, float dl, vec4 W, float fade, float split, int part) {
	vec3 acc = vec3(0.0);
	float b = geo_cr.y, nb = 1.0 - exp2(-b);
	float cls = dot(W, geo_cr_cls)/max(W.x + W.y + W.z + W.w, 1e-4);
	for (int o = 0; o < 7; o++) {
		float Do = 0.5*exp2(float(o));                            // 本八度坑径 [Do, 2·Do)
		float k = clamp(dl + 2.0 - log2(Do), 0.0, 1.0)*clamp(Do/(4.0*fade + 1e-9) - 1.0, 0.0, 1.0);
		float kg = k*geo_part(Do, split, part);                   // 坡度权重
		if (k <= 0.0 || (part == 2 && kg <= 0.0)) continue;
		float Cs = 4.0*Do;                                        // 格边长 = 2 × 最大影响半径（2R ≤ 2·Do）→ 只看 2×2 格
		float p = geo_cr.x*pow(Do, -b)*nb*Cs*Cs*cls;              // 每格有坑的概率
		vec2 q = xz/Cs - 0.5; ivec2 c0 = ivec2(floor(q));
		for (int j = 0; j < 2; j++) {
			for (int i = 0; i < 2; i++) {
				ivec2 c = c0 + ivec2(i, j);
				uint h = geo_hash((uint(c.x)*0x27d4eb2du) ^ geo_hash(uint(c.y) + uint(o)*0x165667b1u));
				if (geo_u(h) >= p) continue;
				vec2 ctr = (vec2(c) + vec2(geo_u(geo_hash(h ^ 1u)), geo_u(geo_hash(h ^ 2u))))*Cs;
				float D = Do*pow(1.0 - geo_u(geo_hash(h ^ 3u))*nb, -1.0/b);
				float R = 0.5*D;
				vec2 dv = xz - ctr; float r = length(dv);
				if (r >= 2.0*R) continue;
				float deg = sqrt(geo_u(geo_hash(h ^ 4u)));           // 老化程度（偏老：小坑多处在侵蚀 / 填埋中）
				float dp = D*mix(geo_cr.z, geo_cr.w, deg);
				float hr = D*geo_cr2.x*(1.0 - deg);
				float x = r/R, hg, dh;                               // dh = ∂h/∂r
				if (x < 1.0) {                                       // 碗：抛物面，坑缘处 = hr
					hg = (dp + hr)*x*x - dp; dh = 2.0*(dp + hr)*x/R;
					float fl = -dp*(1.0 - geo_cr2.y*deg);            // 老坑底积沙：平底
					if (hg < fl) { hg = fl; dh = 0.0; }
				} else {                                             // 溅射：hr·x⁻³，1.4–2 R 渐隐到 0
					float s = clamp((x - 1.4)/0.6, 0.0, 1.0);
					float t = 1.0 - s*s*(3.0 - 2.0*s), dt = -6.0*s*(1.0 - s)/0.6;
					float x3 = 1.0/(x*x*x);
					hg = hr*x3*t; dh = hr*(-3.0*x3/x*t + x3*dt)/R;
				}
				acc += vec3(part == 2 ? 0.0 : k*hg, kg*dh*dv/max(r, 1e-6));
			}
		}
	}
	return acc;
}

// 实测沙纹场（CPU 同义：地貌.gd rfield）。z = Σ 双线性权 · a_j · e^{iψ_j}，ψ_j = φ_j + k_j·(x − x_j)；相位 = arg z，
// 相干度 ρ = |z| / Σ w·a（分叉、断头处平面波互相抵消 → ρ 小 → 渐隐）；高 = H · Σw·a · g(ρ) · (不对称剖面(相位) − 0.5)。
vec3 geo_rfield(vec2 xz, float dl, float fade, float split, int part) {
	if (geo_rf_on <= 0.0) return vec3(0.0);
	float half_ = geo_rf_g.x, cell = geo_rf_g.y;
	// 早退：λ 在 [lam_lo, lam_hi]，渐隐系数的上界已经 ≤ 0 就不用取样（远处 fade 大、分辨率粗时占大多数像素）
	if (clamp(dl + 1.321928 - log2(geo_rf_g.z), 0.0, 1.0)*clamp(geo_rf_g.w/(4.0*fade + 1e-9) - 1.0, 0.0, 1.0) <= 0.0) return vec3(0.0);
	bool grad = !(part == 1 && geo_rf_g.w <= 8.0*split + 1e-9);   // 顶点段只要大特征（λ ≥ 8·split）的坡度；沙纹最长 lam_hi，够不到就不算梯度
	float lnlo = log(geo_rf_g.z), lnr = log(geo_rf_g.w/geo_rf_g.z);
	vec2 f2 = (xz + half_)/cell - 0.5; vec2 b0 = floor(f2); vec2 t2 = f2 - b0; ivec2 c0 = ivec2(b0);
	{                                                             // 覆盖块（4×4 格）：块里没有沙纹就退出（常见情况 1 次取样）；块里最长 λ 已经渐隐光了也退出
		ivec2 ca = clamp(c0, ivec2(0), ivec2(geo_rf_n - 1)), cb = clamp(c0 + 1, ivec2(0), ivec2(geo_rf_n - 1));
		ivec2 ba = ca >> 2, bb = cb >> 2;
		float cv = texelFetch(geo_rf_cov, ba, 0).r;
		if (bb.x != ba.x) cv = max(cv, texelFetch(geo_rf_cov, ivec2(bb.x, ba.y), 0).r);
		if (bb.y != ba.y) { cv = max(cv, texelFetch(geo_rf_cov, ivec2(ba.x, bb.y), 0).r); if (bb.x != ba.x) cv = max(cv, texelFetch(geo_rf_cov, bb, 0).r); }
		if (cv <= 0.0) return vec3(0.0);
		float lmx = exp(lnlo + round(cv*255.0)*(lnr/255.0))*1.0001;    // 覆盖值 = 块内最大 G 字节 + 1（上界）
		if (clamp(lmx/(4.0*fade + 1e-9) - 1.0, 0.0, 1.0) <= 0.0) return vec3(0.0);
	}
	float zr = 0.0, zi = 0.0, As = 0.0, Ls = 0.0;
	vec2 gzr = vec2(0.0), gzi = vec2(0.0), gAs = vec2(0.0);
	for (int dj = 0; dj < 2; dj++) {
		for (int di = 0; di < 2; di++) {
			ivec2 ij = clamp(c0 + ivec2(di, dj), ivec2(0), ivec2(geo_rf_n - 1));
			vec4 t = round(texelFetch(geo_rf, ij, 0)*255.0);
			float a = t.w/255.0;
			if (a <= 0.0) continue;
			float wx = di == 1 ? t2.x : 1.0 - t2.x, wz = dj == 1 ? t2.y : 1.0 - t2.y, w = wx*wz;
			vec2 gw = vec2((di == 1 ? 1.0 : -1.0)*wz, (dj == 1 ? 1.0 : -1.0)*wx)/cell;
			float az = t.x*(6.283185/256.0), ll = lnlo + t.y*(lnr/255.0), lam = exp(ll), ph = t.z*(6.283185/256.0);
			vec2 c = -half_ + (vec2(ij) + 0.5)*cell;
			vec2 kv = 6.283185/lam*vec2(sin(az), -cos(az));
			float psi = ph + dot(kv, xz - c);
			float cp = cos(psi), sp = sin(psi);
			zr += w*a*cp; zi += w*a*sp; As += w*a; Ls += w*a*ll;
			if (grad) { gzr += a*(gw*cp - w*sp*kv); gzi += a*(gw*sp + w*cp*kv); gAs += a*gw; }
		}
	}
	if (As <= 1e-6) return vec3(0.0);
	float lm = exp(Ls/As);
	float e = max(abs(xz.x), abs(xz.y));
	float k = clamp(dl + 1.321928 - log2(lm), 0.0, 1.0)*clamp(lm/(4.0*fade + 1e-9) - 1.0, 0.0, 1.0)*(1.0 - geo_s(e, half_));
	float kg = k*geo_part(lm, split, part);
	if (k <= 0.0 || (part == 2 && kg <= 0.0)) return vec3(0.0);
	float H = geo_rf_p.x, Lf = geo_rf_p.y;
	float m2 = max(zr*zr + zi*zi, 1e-12), m = sqrt(m2);
	float rho = m/As;
	float r0 = geo_rf_p.z, r1 = geo_rf_p.w;
	float gs = clamp((rho - r0)/(r1 - r0), 0.0, 1.0), g = gs*gs*(3.0 - 2.0*gs), dg = 6.0*gs*(1.0 - gs)/(r1 - r0);
	vec2 grho = ((zr*gzr + zi*gzi)/m - rho*gAs)/As;
	vec2 gph = (zr*gzi - zi*gzr)/m2;
	float t = fract(atan(zi, zr)/6.283185 + 1.0 - Lf), f, df;
	if (t < 1.0 - Lf) { float s = t/(1.0 - Lf); f = sin(1.570796*s); f *= f; df = 1.570796*sin(3.141593*s)/(1.0 - Lf); }
	else { float s = (t - 1.0 + Lf)/Lf; f = cos(1.570796*s); f *= f; df = -1.570796*sin(3.141593*s)/Lf; }
	float hh = H*As*g*(f - 0.5);
	vec2 gh = !grad ? vec2(0.0) : H*((gAs*g + As*dg*grho)*(f - 0.5) + As*g*df*gph/6.283185);
	return vec3(part == 2 ? 0.0 : k*hh, kg*gh);
}

// 沙纹反照率条纹：与高度同一个相位 / 相干度，脊暗槽亮（巨波纹冠部是深灰粗砂，Bell 2022；docs/地面材质/沙纹.md §4、§6），乘到地面反照率上。
// 条纹烘成 0.25 m 的 R8 贴图（80_沙纹场.py 条纹：v = 127.5 + 127.5·s，s = 2·As·g·(f − 0.5)，Navcam 区 / ±1 km 边外 = 中性），
// 运行时只取一次样，贴图 mip 让远处自然渐隐；逐像素算相量会让这个已经很满的片元着色器多占寄存器（全场景 +0.15 ms）。fp 留着不用（挂钩签名不变）。
float geo_rfield_alb(vec2 xz, float fp) {
	if (geo_rf_on <= 0.0 || geo_rf_alb <= 0.0) return 1.0;
	return 1.0 - geo_rf_alb*(texture(geo_rf_st, xz/(2.0*geo_rf_g.x) + 0.5).r*2.0 - 1.0);
}

vec3 geo_ripples(vec2 xz, float dl, vec4 W, float fade, float split, int part) {
	vec3 acc = vec3(0.0);
	float ws = smoothstep(0.3, 0.7, W.x);                         // 只在沙类上
	if (ws <= 0.0) return acc;
	for (int i = 0; i < geo_rp_n; i++) {
		vec4 a = geo_rp[i], a2 = geo_rp2[i];
		float lam = a.x;
		float k = ws*clamp(dl + 1.321928 - log2(lam), 0.0, 1.0)*clamp(lam/(4.0*fade + 1e-9) - 1.0, 0.0, 1.0);   // λ > 2.5 × 分辨率：数据自带
		float kg = k*geo_part(lam, split, part);
		if (k <= 0.0 || (part == 2 && kg <= 0.0)) continue;
		vec2 dir = a.zw, per = vec2(-dir.y, dir.x), d2 = per*0.8 + dir*0.6;
		// 波脊弯曲：沿脊方向两个正弦扭相位（先取周期小数，远处 float 也准）
		float L1 = 5.3*lam, L2 = 11.7*lam, L3 = 7.1*lam;
		float s1 = 6.283185*fract(dot(xz, per)/L1), s2 = 6.283185*fract(dot(xz, d2)/L2);
		float s3 = 6.283185*fract(dot(xz, per)/L3);
		float ph = dot(xz, dir)/lam + a2.y*(sin(s1) + 0.5*sin(s2));
		vec2 gph = dir/lam + a2.y*(cos(s1)*6.283185/L1*per + 0.5*cos(s2)*6.283185/L2*d2);
		float am = a.y*(0.75 + 0.25*sin(s3)); vec2 gam = a.y*0.25*cos(s3)*6.283185/L3*per;   // 沿脊高低起伏
		float t = fract(ph), Lf = a2.x, f, df;                     // 迎风坡长而缓（1 − Lf），背风坡短而陡（Lf）
		if (t < 1.0 - Lf) { float s = t/(1.0 - Lf); f = sin(1.570796*s); f *= f; df = 1.570796*sin(3.141593*s)/(1.0 - Lf); }
		else { float s = (t - 1.0 + Lf)/Lf; f = cos(1.570796*s); f *= f; df = -1.570796*sin(3.141593*s)/Lf; }
		acc += vec3(part == 2 ? 0.0 : k*am*(f - 0.5), kg*(am*df*gph + (f - 0.5)*gam));
	}
	return acc + geo_rfield(xz, dl, fade, split, part);
}

vec3 geo_at2(vec2 xz, float fade, float split, int part) {
	if (geo_on <= 0.0) return vec3(0.0);
	float dl = geo_dem_l(xz, 0.0);
	if (dl <= -3.0) return vec3(0.0);                            // Navcam 区：数据自带
	vec4 W = geo_W(xz);
	return geo_on*(geo_craters(xz, dl, W, fade, split, part) + geo_ripples(xz, geo_dem_l(xz, 3.0), W, fade, split, part));
}
vec3 geo_at(vec2 xz, float fade) { return geo_at2(xz, fade, 0.0, 0); }
