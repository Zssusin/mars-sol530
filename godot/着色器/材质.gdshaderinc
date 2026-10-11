// 地面材质（阶段 1 B 步，docs/地面材质/阶段1.md §6、§9）：控制图（每纹素前 3 种材质 + 积尘）→ 2×2 合并成 4 项小表 → 取前 k →
// 每种材质 Mikkelsen 2022 hex 平铺（每格随机变体、平移、旋转）→ 按高度混合。
// 中观位移.gdshaderinc 的顶点位移（地面、石块）和 地形.gdshader 片元（#define MAT_FRAG）共用。
// CPU 版：godot/材质.gd（mat_disp）、扩展/仿真核心 core/terrain_core.cpp（MatDisp）。位移那条路（mat_table、mat_topk、mat_tri、
// mat_cell、mat_h、mat_disp）改这里必须同样改那两边：同一个整数哈希、同一个选格、同一套混合，CPU 的 h_cpu 才和画出来的地面一致。
// 坐标：控制图、门用 Godot xz（x 东、z 南；图第 0 行在北 = z 最小，纹素 (i, j) 中心 = −half + (i + ½)·cs）；
// 样块 UV st = (E, N)/边长 = (x, −z)/边长（样块第 0 行在南）。

uniform sampler2D mat_ctrl_n : filter_nearest, repeat_disable;   // 近图 4 cm ±50 m：RGBA8 = 32 位字（R = 位 0–7）
uniform sampler2D mat_ctrl_f : filter_nearest, repeat_disable;   // 远图 1 m ±1 km
uniform sampler2D mat_gate : filter_linear, repeat_disable;      // 中观位移门（73 烘焙，同近图网格）；图外 = 1
uniform vec4 mat_grid = vec4(50.0, 0.04, 1000.0, 1.0);           // 近图 half、格距，远图 half、格距
uniform ivec4 mat_out_id = ivec4(0, 2, 3, -1);                   // 远图外（±1 km 外）固定配比：材质号、权重
uniform vec4 mat_out_w = vec4(0.6, 0.3, 0.1, 0.0);
uniform sampler2DArray mat_meso_h16 : filter_linear_mipmap, repeat_enable;
uniform vec4 mat_me[16];                                         // 每材质中观：起始层、变体数、边长 m、高度量程 m
uniform vec4 mat_mi[16];                                         // 每材质微观：起始层、变体数、边长 m、（未用）
uniform vec4 mat_bl[16];                                         // 混合对比、偏置、粗糙度 σ、hex 旋转（0 / 1）
uniform vec4 mat_lay[40];                                        // 中观每层混合高度的 lo、hi（米）：层 2i → xy、2i + 1 → zw（最多 80 层）
uniform int mat_fmt = 0;                                         // 控制图格式：0 = 旧（3 槽 × 5 位号、6 位权）；4 = 中景版（4 槽 × 4 位号、4 位权，材质 ≤ 16；变体选择换成无偏的范围映射）
uniform vec4 mat_hexp = vec4(0.45, 7.0, 0.6, 0.1);               // 中观 hex 格距 m、权重指数（Mikkelsen 7）、高度权（0.6）、材质混合锐度
uniform float mat_hexmi = 0.06;                                  // 微观 hex 格距 m
uniform int mat_k = 3;                                           // 每像素最多几种材质（档：低 2，其余 3）
uniform float mat_cpu_cell = 0.01;                               // CPU 位移按这个格距选（整数）mip

const float MAT_WMIN = 0.02;                                     // 权重低于它的材质不采（动态分支）
const float MAT_HMIN = 0.005;                                    // hex 格权重低于它不采

uint mat_hash(uint x) { x ^= x >> 16u; x *= 0x7feb352du; x ^= x >> 15u; x *= 0x5bd1e995u; x ^= x >> 16u; return x; }
float mat_u(uint h) { return float(h >> 8u)*(1.0/16777216.0); }
float mat_region(float e, float h, float f) { return clamp((h*0.97 - e)/(h*f), 0.0, 1.0); }

// —— 控制图 → 4 项小表（号 −1 = 空）。12 项依次放入：同号相加；新号顶掉最小的一项（比它大才顶）。
void mat_put(inout ivec4 id, inout vec4 w, int m, float x) {
	if (x <= 0.0) return;
	if (id.x == m) { w.x += x; return; }
	if (id.y == m) { w.y += x; return; }
	if (id.z == m) { w.z += x; return; }
	if (id.w == m) { w.w += x; return; }
	if (w.x <= w.y && w.x <= w.z && w.x <= w.w) { if (x > w.x) { id.x = m; w.x = x; } }
	else if (w.y <= w.z && w.y <= w.w) { if (x > w.y) { id.y = m; w.y = x; } }
	else if (w.z <= w.w) { if (x > w.z) { id.z = m; w.z = x; } }
	else if (x > w.w) { id.w = m; w.w = x; }
}
void mat_texel(sampler2D t, ivec2 ij, float bw, inout ivec4 id, inout vec4 w, inout float dust) {
	uvec4 b = uvec4(texelFetch(t, ij, 0)*255.0 + 0.5);
	uint u = b.r | (b.g << 8u) | (b.b << 16u) | (b.a << 24u);
#ifdef MAT_N16
	{                                                             // 4 槽：号位 0–15（各 4 位）、权 16–27（各 4 位，第 4 个 = 15 − 前 3）、积尘 28–31
		float q0 = float((u >> 16u) & 15u), q1 = float((u >> 20u) & 15u), q2 = float((u >> 24u) & 15u);
		float s4 = bw/15.0;
		mat_put(id, w, int(u & 15u), s4*q0);
		mat_put(id, w, int((u >> 4u) & 15u), s4*q1);
		mat_put(id, w, int((u >> 8u) & 15u), s4*q2);
		mat_put(id, w, int((u >> 12u) & 15u), s4*(15.0 - q0 - q1 - q2));
		dust += bw*float(u >> 28u)/15.0;
		return;
	}
#else
	float w0 = float((u >> 15u) & 63u), w1 = float((u >> 21u) & 63u);
	float s = bw/63.0;
	mat_put(id, w, int(u & 31u), s*w0);
	mat_put(id, w, int((u >> 5u) & 31u), s*w1);
	mat_put(id, w, int((u >> 10u) & 31u), s*(63.0 - w0 - w1));
	dust += bw*float(u >> 27u)/31.0;
#endif
}
void mat_bilin(sampler2D t, vec2 xz, float hf, float cs, float bw, inout ivec4 id, inout vec4 w, inout float dust) {
	int n = textureSize(t, 0).x;
	vec2 f = (xz + hf)/cs - 0.5; vec2 i0 = floor(f); vec2 a = f - i0;
	ivec2 p = clamp(ivec2(i0), ivec2(0), ivec2(n - 1)), q = clamp(ivec2(i0) + 1, ivec2(0), ivec2(n - 1));
	mat_texel(t, p, bw*(1.0 - a.x)*(1.0 - a.y), id, w, dust);
	mat_texel(t, ivec2(q.x, p.y), bw*a.x*(1.0 - a.y), id, w, dust);
	mat_texel(t, ivec2(p.x, q.y), bw*(1.0 - a.x)*a.y, id, w, dust);
	mat_texel(t, q, bw*a.x*a.y, id, w, dust);
}
// 近图（外缘 5% 渐变）→ 远图 → 图外固定配比
void mat_table(vec2 xz, out ivec4 id, out vec4 w, out float dust) {
	id = ivec4(-1); w = vec4(0.0); dust = 0.0;
	float e = max(abs(xz.x), abs(xz.y));
	float a = mat_region(e, mat_grid.x, 0.05), b = (1.0 - a)*mat_region(e, mat_grid.z, 0.05);
	if (a > 0.0) mat_bilin(mat_ctrl_n, xz, mat_grid.x, mat_grid.y, a, id, w, dust);
	if (b > 0.0) mat_bilin(mat_ctrl_f, xz, mat_grid.z, mat_grid.w, b, id, w, dust);
	float o = 1.0 - a - b;
	if (o > 0.0) {
		if (mat_out_id.x >= 0) mat_put(id, w, mat_out_id.x, o*mat_out_w.x);
		if (mat_out_id.y >= 0) mat_put(id, w, mat_out_id.y, o*mat_out_w.y);
		if (mat_out_id.z >= 0) mat_put(id, w, mat_out_id.z, o*mat_out_w.z);
		if (mat_out_id.w >= 0) mat_put(id, w, mat_out_id.w, o*mat_out_w.w);
		dust += o*0.15;
	}
}
// 只留前 k 项（去掉最小的非零项），再把 < MAT_WMIN 的去掉、归一
vec4 mat_topk(vec4 w) {
	for (int r = 0; r < 2; r++) {
		int nz = int(w.x > 0.0) + int(w.y > 0.0) + int(w.z > 0.0) + int(w.w > 0.0);
		if (nz <= mat_k) break;
		vec4 t = vec4(w.x > 0.0 ? w.x : 1e9, w.y > 0.0 ? w.y : 1e9, w.z > 0.0 ? w.z : 1e9, w.w > 0.0 ? w.w : 1e9);
		float mn = min(min(t.x, t.y), min(t.z, t.w));
		if (t.x == mn) w.x = 0.0; else if (t.y == mn) w.y = 0.0; else if (t.z == mn) w.z = 0.0; else w.w = 0.0;
	}
	w /= max(w.x + w.y + w.z + w.w, 1e-9);
	w = vec4(w.x >= MAT_WMIN ? w.x : 0.0, w.y >= MAT_WMIN ? w.y : 0.0, w.z >= MAT_WMIN ? w.z : 0.0, w.w >= MAT_WMIN ? w.w : 0.0);
	return w/max(w.x + w.y + w.z + w.w, 1e-9);
}

// —— hex 平铺（Mikkelsen 2022，JCGT 11(2)）：三角格在世界坐标里（格距 cell 米），三个格点各一个哈希，所有材质共用；
//    每格：平移（样块单位，2 × 10 位）、旋转角（8 位，材质可关）、变体（高 4 位 % 变体数）。每像素每层只算一次三角格和 3 个哈希。
void mat_tri(vec2 p, float cell, out vec3 W, out ivec2 v1, out ivec2 v2, out ivec2 v3) {
	vec2 st = p/cell;
	vec2 sk = vec2(st.x - 0.57735027*st.y, 1.15470054*st.y);
	vec2 b = floor(sk); vec2 f = sk - b;
	float z = 1.0 - f.x - f.y;
	int s = z <= 0.0 ? 1 : 0; float sf = float(s), s2 = 2.0*sf - 1.0;
	vec3 bw = clamp(vec3(-z*s2, sf - f.y*s2, sf - f.x*s2), 0.0, 1.0);
	ivec2 bi = ivec2(b);
	v1 = bi + ivec2(s, s); v2 = bi + ivec2(s, 1 - s); v3 = bi + ivec2(1 - s, s);
	W = pow(bw, vec3(mat_hexp.y)); W /= W.x + W.y + W.z;
}
// 格 v：q = (p − 格中心)（米）、角的 cos / sin；h = 哈希
void mat_cellq(vec2 p, float cell, ivec2 v, uint salt, out vec4 q, out uint h) {
	h = mat_hash((uint(v.x)*0x27d4eb2du) ^ mat_hash(uint(v.y) + salt*0x165667b1u));
	float a = float((h >> 20u) & 255u)*(6.2831853/256.0);
	q = vec4(p - vec2(float(v.x) + 0.5*float(v.y), 0.8660254*float(v.y))*cell, cos(a), sin(a));
}
vec2 mat_rot(vec2 p, vec2 cs) { return vec2(cs.x*p.x - cs.y*p.y, cs.y*p.x + cs.x*p.y); }
vec2 mat_rotT(vec2 g, vec2 cs) { return vec2(cs.x*g.x + cs.y*g.y, -cs.y*g.x + cs.x*g.y); }   // 导数转回世界：Rᵀ g
vec2 mat_off(uint h) { return vec2(float(h & 1023u), float((h >> 10u) & 1023u))*(1.0/1024.0); }
float mat_var(uint h, vec4 lv) {                                 // 变体号。旧：高 4 位 % n（n 不整除 16 时有的变体多一倍）；MAT_N16（中景版）：再哈希一次、高 16 位 × n >> 16（无偏，n ≤ 16）
	uint n = uint(max(lv.y, 1.0));
#ifdef MAT_N16
	return lv.x + float(((mat_hash(h ^ 0x68e31da4u) >> 16u)*n) >> 16u);
#else
	return lv.x + float((h >> 28u) % n);
#endif
}
// 只留前 3 项，压到 xyz（topk 之后至多 3 项非零）
void mat_pack3(ivec4 id, vec4 w, out ivec3 ik, out vec3 wk) {
	if (w.w > 0.0) {
		if (w.x <= 0.0) { id.x = id.w; w.x = w.w; } else if (w.y <= 0.0) { id.y = id.w; w.y = w.w; } else { id.z = id.w; w.z = w.w; }
	}
	ik = id.xyz; wk = w.xyz;
}

// —— 位移（顶点、石块；CPU 同义）
float mat_gate_at(vec2 xz) {
	if (max(abs(xz.x), abs(xz.y)) >= mat_grid.x) return 1.0;
	return textureLod(mat_gate, (xz + mat_grid.x)/(2.0*mat_grid.x), 0.0).r;
}
void mat_htap(int m, vec4 me, bool rot, vec4 q, uint h, float W, float mip, inout vec3 acc) {   // acc：Σ w·h、Σ w·a、Σ w
	if (W < MAT_HMIN) return;
	float layer = mat_var(h, me);
	vec2 st = mat_rot(q.xy/me.z, rot ? q.zw : vec2(1.0, 0.0)) + mat_off(h);
	float hh = (textureLod(mat_meso_h16, vec3(st, layer), mip).r - 0.5)*2.0*me.w;
	int L = int(layer); vec4 lq = mat_lay[L >> 1]; vec2 lh = (L & 1) == 0 ? lq.xy : lq.zw;
	float a = clamp((hh - lh.x)/(lh.y - lh.x), 0.0, 1.0);
	float wi = W*mix(1.0, a, mat_hexp.z);
	acc += vec3(wi*hh, wi*a, wi);
}
// 一种材质：返回 (b·h, b)，b = 混合权重（没这种材质时 0）。手工展开（不用循环 + 动态下标：会被放进局部内存）
vec2 mat_hmat(int m, float wk, float g, float cell, bool cpu_mip, float n, vec3 W, vec4 q1, uint h1, vec4 q2, uint h2, vec4 q3, uint h3) {
	if (wk <= 0.0) return vec2(0.0);
	vec4 me = mat_me[m]; vec4 bl = mat_bl[m]; bool rot = bl.w > 0.5;
	float mip = max(cpu_mip ? round(log2(mat_cpu_cell*n/me.z)) : log2(cell*n/me.z), 0.0);
	vec3 acc = vec3(0.0);
	mat_htap(m, me, rot, q1, h1, W.x, mip, acc); mat_htap(m, me, rot, q2, h2, W.y, mip, acc); mat_htap(m, me, rot, q3, h3, W.z, mip, acc);
	float b = wk*exp((bl.x*g*(acc.y/acc.z - 0.5) + bl.y)/mat_hexp.w);
	return vec2(b*acc.x/acc.z, b);
}
// 中观位移（米）：cell = 这里的几何格距（选 mip）；cpu_mip = true 时按 mat_cpu_cell 取整数 mip（同 CPU）
float mat_disp(vec2 xz, float cell, bool cpu_mip) {
	float g = mat_gate_at(xz);
	if (g <= 0.0) return 0.0;
	ivec4 id; vec4 w; float dust; mat_table(xz, id, w, dust);
	ivec3 ik; vec3 wk; mat_pack3(id, mat_topk(w), ik, wk);
	vec2 p = vec2(xz.x, -xz.y);
	vec3 W; ivec2 v1, v2, v3; mat_tri(p, mat_hexp.x, W, v1, v2, v3);
	vec4 q1, q2, q3; uint h1, h2, h3;
	mat_cellq(p, mat_hexp.x, v1, 0u, q1, h1); mat_cellq(p, mat_hexp.x, v2, 0u, q2, h2); mat_cellq(p, mat_hexp.x, v3, 0u, q3, h3);
	float n = float(textureSize(mat_meso_h16, 0).x);
	vec2 r0 = mat_hmat(ik.x, wk.x, g, cell, cpu_mip, n, W, q1, h1, q2, h2, q3, h3);
	vec2 r1 = mat_hmat(ik.y, wk.y, g, cell, cpu_mip, n, W, q1, h1, q2, h2, q3, h3);
	vec2 r2 = mat_hmat(ik.z, wk.z, g, cell, cpu_mip, n, W, q1, h1, q2, h2, q3, h3);
	float tot = r0.y + r1.y + r2.y, hs = r0.x + r1.x + r2.x;
	return g*hs/tot;
}

#ifdef MAT_FRAG
// —— 片元（只在 地形.gdshader）
uniform sampler2DArray mat_meso_ah : filter_linear_mipmap_anisotropic, repeat_enable;   // RGB 反照率细节 ÷gain、A 混合高度
uniform sampler2DArray mat_meso_d : filter_linear_mipmap_anisotropic, repeat_enable;    // 导数图 0.5 + ∂h/∂(E,N)/(2·量程)
uniform sampler2DArray mat_micro_ah : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray mat_micro_d : filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 mat_gain = vec4(2.5, 2.0, 2.0, 0.0);                // 中观、微观反照率 gain，导数图量程
uniform vec4 mat_dust = vec4(1.04, 1.0, 0.94, 0.5);              // M10 积尘：色、降对比
uniform vec4 mat_gainv[16];                                      // 中景：每材质反照率增益（线性光 RGB，相对 M1 = 1；材质表 反照率增益）
uniform sampler2D mat_glp : filter_linear, repeat_disable;       // 中景：G = Σ 权重·增益 的 σ=4 m 低通（4 m 格、±mat_gk.y 米）
uniform vec4 mat_gk = vec4(0.0, 1000.0, 0.0, 0.0);               // 增益指数 κ（0 = 关；--中景增益）、低通图 half
uniform float mat_dust_rough = 0.08;                             // 积尘粗糙度加
uniform vec4 mat_steep = vec4(30.0, 5.0, -1.0, 0.6);             // 逐像素露岩：坡度阈°、宽°、材质号（−1 关）、强
uniform vec4 mat_lee = vec4(0.0);                                // 石旁积尘：上风偏移（Godot xz，米）、强、（未用）
uniform int mat_hex_meso = 1;                                    // 0：只取权重最大的格（1 次采样，档 低 / 中）
uniform int mat_hex_micro = 1;
uniform float mat_gs = 1.0;                                       // 纹理梯度缩放 = 2^mip偏（颗粒感 §4：负偏移 = 缩小梯度 = 取更细的 mip；hex 材质和缓存都乘；视口的 texture_mipmap_bias 对 textureGrad 无效，实测）
uniform float mat_vp = 0.0;                                      // 保方差混合（颗粒感 §4，Heitz & Neyret 2018 的方差保持）：hex 三格加权平均会把方差压成 Σŵ²，乘 (Σw/√Σw²)^vp 补回；0 = 关（旧）
// 保方差：加权平均的方差只剩 Σŵ²（ŵ = w/Σw），把偏离均值的部分乘 1/√Σŵ² = Σw/√Σw²（单格 = 1，三格等权 = 1.73）；vp 0..1 按幂调强度
float mat_vpf(vec3 wi) {
	float s2 = dot(wi, wi);
	return mat_vp > 0.0 && s2 > 1e-12 ? pow((wi.x + wi.y + wi.z)*inversesqrt(s2), mat_vp) : 1.0;
}
uniform int mat_perf = 0;                                        // 测帧诊断（位）：1 不取导数图
uniform int mat_dbg = 0;                                         // 诊断：1 = 材质权重上色（不打光）、2 = 积尘

// 宏观变化（防「从高处看是一堆复制的贴图」，阶段1B_交接.md §7）：两个八度的值噪声（每个格点一个哈希拆成 4 个独立通道）
// 调 细节对比、亮度、每种材质的混合偏置；HiRISE 反照率的低频残差（宏观亮处 = 积尘多）再降细节对比。都只乘 g_meso（数据分辨不出处）。
uniform vec4 mat_macro = vec4(0.35, 1.5, 0.06, 0.04);           // 对比噪声幅、残差→对比系数、混合偏置噪声幅（同 偏置 的单位）、亮度噪声幅
uniform vec4 mat_macro_s = vec4(5.3, 21.7, 0.6, 0.0);           // 两个八度的格距（米）、第一八度的权重

const vec3 MAT_PAL[16] = vec3[16](vec3(0.36, 0.22, 0.15), vec3(0.95, 0.92, 0.82), vec3(0.95, 0.72, 0.20), vec3(0.85, 0.45, 0.30),
	vec3(0.45, 0.55, 0.75), vec3(0.40, 0.75, 0.40), vec3(0.75, 0.35, 0.75), vec3(0.30, 0.70, 0.75),
	vec3(1.00, 1.00, 0.30), vec3(0.15, 0.15, 0.25), vec3(0.60, 0.20, 0.20), vec3(0.20, 0.45, 0.20),
	vec3(0.95, 0.55, 0.85), vec3(0.10, 0.80, 0.95), vec3(0.55, 0.45, 0.10), vec3(0.50, 0.50, 0.50));

vec4 mat_h4(ivec2 c, uint salt) {
	uint h = mat_hash((uint(c.x)*0x27d4eb2du) ^ mat_hash(uint(c.y) + salt*0x165667b1u));
	return vec4(float(h & 255u), float((h >> 8u) & 255u), float((h >> 16u) & 255u), float(h >> 24u))*(2.0/255.0) - 1.0;
}
vec4 mat_vn4(vec2 p, uint salt) {                                // 值噪声 4 通道，各 −1..1
	vec2 i = floor(p), f = p - i; f = f*f*(3.0 - 2.0*f); ivec2 c = ivec2(i);
	return mix(mix(mat_h4(c, salt), mat_h4(c + ivec2(1, 0), salt), f.x), mix(mat_h4(c + ivec2(0, 1), salt), mat_h4(c + ivec2(1, 1), salt), f.x), f.y);
}
vec4 mat_macro_n(vec2 p) {                                       // 两个八度（第二个转 37°，免得格线对齐）
	vec2 q = vec2(0.7986*p.x - 0.6018*p.y, 0.6018*p.x + 0.7986*p.y);
	return mat_macro_s.z*mat_vn4(p/mat_macro_s.x, 7u) + (1.0 - mat_macro_s.z)*mat_vn4(q/mat_macro_s.y, 8u);
}
float mat_nsel(vec4 N, int m) { float v = N[m & 3]; return (m & 4) != 0 ? -v : v; }   // 按材质号取一路噪声（m 与 m + 4 反号）

// —— 片元的性能分级（阶段 1 B 步测帧，阶段1.md §10）：按像素足迹 fp（米，横向）降级
//    · hex：格权减去门槛 t 再归一（连续，无跳变），t 从近处 mat_lod2.x 抬到远处 mat_lod2.y → 远处大多只采 1 格；
//    · k：足迹 > mat_lod2.z 时最多 2 种材质；
//    · 导数图：足迹在 mat_lod.z–w 之间淡出（远处一个像素里已平均掉，滤波后的坡度趋于 0），淡完不采；
//    · 先只采中观 ah、按高度混合定好每种材质的权重 bw，导数图和微观只给 bw > mat_bwmin 的材质采；
//    · 各向异性上限 mat_lod2.w（把短轴导数放大到 长轴/上限，探针少、横向略糊；0 = 不限）。
uniform vec4 mat_lod = vec4(0.004, 0.02, 0.012, 0.025);
uniform vec4 mat_lod2 = vec4(0.02, 0.2, 0.02, 4.0);
uniform float mat_bwmin = 0.04;
uniform float mat_hrng[16];                                      // 每种材质中观的高差（米，各变体 hi − lo 的平均）：混合高度 a → 米（交界起伏用）
uniform float mat_edge = 0.0;                                    // 交界起伏强度（材质表 混合.边缘起伏；--材质边缘=s）                                 // （v1 用；v2 导数图、微观只给混合后权重最大的一种）
uniform vec4 mat_lod3 = vec4(0.004, 0.02, 1.0, 2.0);             // 足迹 < x 时用满 k 种；微观 hex 格权门槛；微观在足迹 z–w 之间淡出（新材质另加的，旧的 g_micro 不变）

#ifdef MAT_N16
// 片元控制图：16 种材质累加进四个 vec4 再挑前 3（无分支）。和 mat_table 的 4 项小表在一处出现 > 4 种时略有不同，片元不必和 CPU 位移逐位一致
void mat_acc8(inout vec4 a0, inout vec4 a1, inout vec4 a2, inout vec4 a3, int m, float x) {
	ivec4 mm = ivec4(m);
	a0 += x*vec4(equal(mm, ivec4(0, 1, 2, 3))); a1 += x*vec4(equal(mm, ivec4(4, 5, 6, 7)));
	a2 += x*vec4(equal(mm, ivec4(8, 9, 10, 11))); a3 += x*vec4(equal(mm, ivec4(12, 13, 14, 15)));
}
void mat_texel8(sampler2D t, ivec2 ij, float bw, inout vec4 a0, inout vec4 a1, inout vec4 a2, inout vec4 a3, inout float dust) {
	uvec4 b = uvec4(texelFetch(t, ij, 0)*255.0 + 0.5);
	uint u = b.r | (b.g << 8u) | (b.b << 16u) | (b.a << 24u);
	if (mat_fmt == 4) {
		float q0 = float((u >> 16u) & 15u), q1 = float((u >> 20u) & 15u), q2 = float((u >> 24u) & 15u);
		float s4 = bw/15.0;
		mat_acc8(a0, a1, a2, a3, int(u & 15u), s4*q0);
		mat_acc8(a0, a1, a2, a3, int((u >> 4u) & 15u), s4*q1);
		mat_acc8(a0, a1, a2, a3, int((u >> 8u) & 15u), s4*q2);
#ifndef MAT_S3
		mat_acc8(a0, a1, a2, a3, int((u >> 12u) & 15u), s4*(15.0 - q0 - q1 - q2));
#endif
		dust += bw*float(u >> 28u)/15.0;
		return;
	}
	float w0 = float((u >> 15u) & 63u), w1 = float((u >> 21u) & 63u);
	float s = bw/63.0;
	mat_acc8(a0, a1, a2, a3, int(u & 31u), s*w0);
	mat_acc8(a0, a1, a2, a3, int((u >> 5u) & 31u), s*w1);
	mat_acc8(a0, a1, a2, a3, int((u >> 10u) & 31u), s*(63.0 - w0 - w1));
	dust += bw*float(u >> 27u)/31.0;
}
void mat_bilin8(sampler2D t, vec2 xz, float hf, float cs, float bw, inout vec4 a0, inout vec4 a1, inout vec4 a2, inout vec4 a3, inout float dust) {
	int n = textureSize(t, 0).x;
	vec2 f = (xz + hf)/cs - 0.5; vec2 i0 = floor(f); vec2 a = f - i0;
	ivec2 p = clamp(ivec2(i0), ivec2(0), ivec2(n - 1)), q = clamp(ivec2(i0) + 1, ivec2(0), ivec2(n - 1));
	mat_texel8(t, p, bw*(1.0 - a.x)*(1.0 - a.y), a0, a1, a2, a3, dust);
	mat_texel8(t, ivec2(q.x, p.y), bw*a.x*(1.0 - a.y), a0, a1, a2, a3, dust);
	mat_texel8(t, ivec2(p.x, q.y), bw*(1.0 - a.x)*a.y, a0, a1, a2, a3, dust);
	mat_texel8(t, q, bw*a.x*a.y, a0, a1, a2, a3, dust);
}
// 取最大的一项、清零；返回号（全 0 时 −1）
int mat_pop8(inout vec4 a0, inout vec4 a1, inout vec4 a2, inout vec4 a3, out float w) {
	vec4 m4 = max(max(a0, a1), max(a2, a3)); w = max(max(m4.x, m4.y), max(m4.z, m4.w));
	if (w <= 0.0) return -1;
	int i = w == a0.x ? 0 : (w == a0.y ? 1 : (w == a0.z ? 2 : (w == a0.w ? 3 : (w == a1.x ? 4 : (w == a1.y ? 5 : (w == a1.z ? 6 : (w == a1.w ? 7 : (w == a2.x ? 8 : (w == a2.y ? 9 : (w == a2.z ? 10 : (w == a2.w ? 11 : (w == a3.x ? 12 : (w == a3.y ? 13 : (w == a3.z ? 14 : 15))))))))))))));
	ivec4 ii = ivec4(i);
	a0 *= vec4(notEqual(ii, ivec4(0, 1, 2, 3))); a1 *= vec4(notEqual(ii, ivec4(4, 5, 6, 7)));
	a2 *= vec4(notEqual(ii, ivec4(8, 9, 10, 11))); a3 *= vec4(notEqual(ii, ivec4(12, 13, 14, 15)));
	return i;
}

#else
// 片元控制图：8 种材质累加进两个 vec4 再挑前 3（无分支）。和 mat_table 的 4 项小表在一处出现 > 4 种时略有不同，片元不必和 CPU 位移逐位一致
void mat_acc8(inout vec4 a0, inout vec4 a1, inout vec4 a2, inout vec4 a3, int m, float x) {
	ivec4 mm = ivec4(m);
	a0 += x*vec4(equal(mm, ivec4(0, 1, 2, 3))); a1 += x*vec4(equal(mm, ivec4(4, 5, 6, 7)));
}
void mat_texel8(sampler2D t, ivec2 ij, float bw, inout vec4 a0, inout vec4 a1, inout vec4 a2, inout vec4 a3, inout float dust) {
	uvec4 b = uvec4(texelFetch(t, ij, 0)*255.0 + 0.5);
	uint u = b.r | (b.g << 8u) | (b.b << 16u) | (b.a << 24u);
	float w0 = float((u >> 15u) & 63u), w1 = float((u >> 21u) & 63u);
	float s = bw/63.0;
	mat_acc8(a0, a1, a2, a3, int(u & 31u), s*w0);
	mat_acc8(a0, a1, a2, a3, int((u >> 5u) & 31u), s*w1);
	mat_acc8(a0, a1, a2, a3, int((u >> 10u) & 31u), s*(63.0 - w0 - w1));
	dust += bw*float(u >> 27u)/31.0;
}
void mat_bilin8(sampler2D t, vec2 xz, float hf, float cs, float bw, inout vec4 a0, inout vec4 a1, inout vec4 a2, inout vec4 a3, inout float dust) {
	int n = textureSize(t, 0).x;
	vec2 f = (xz + hf)/cs - 0.5; vec2 i0 = floor(f); vec2 a = f - i0;
	ivec2 p = clamp(ivec2(i0), ivec2(0), ivec2(n - 1)), q = clamp(ivec2(i0) + 1, ivec2(0), ivec2(n - 1));
	mat_texel8(t, p, bw*(1.0 - a.x)*(1.0 - a.y), a0, a1, a2, a3, dust);
	mat_texel8(t, ivec2(q.x, p.y), bw*a.x*(1.0 - a.y), a0, a1, a2, a3, dust);
	mat_texel8(t, ivec2(p.x, q.y), bw*(1.0 - a.x)*a.y, a0, a1, a2, a3, dust);
	mat_texel8(t, q, bw*a.x*a.y, a0, a1, a2, a3, dust);
}
// 取最大的一项、清零；返回号（全 0 时 −1）
int mat_pop8(inout vec4 a0, inout vec4 a1, inout vec4 a2, inout vec4 a3, out float w) {
	vec4 m4 = max(a0, a1); w = max(max(m4.x, m4.y), max(m4.z, m4.w));
	if (w <= 0.0) return -1;
	int i = w == a0.x ? 0 : (w == a0.y ? 1 : (w == a0.z ? 2 : (w == a0.w ? 3 : (w == a1.x ? 4 : (w == a1.y ? 5 : (w == a1.z ? 6 : 7))))));
	a0 *= vec4(notEqual(ivec4(i), ivec4(0, 1, 2, 3))); a1 *= vec4(notEqual(ivec4(i), ivec4(4, 5, 6, 7)));
	return i;
}

#endif

// 一格的 UV（样块单位，含旋转、平移、变体层）和导数（含各向异性上限）
void mat_uvg(vec4 lv, bool rot, vec2 sx, vec2 sy, vec4 q, uint h, out vec3 uv, out vec2 gx, out vec2 gy, out vec2 cs) {
	cs = rot ? q.zw : vec2(1.0, 0.0);
	float r = 1.0/lv.z;
	uv = vec3(mat_rot(q.xy*r, cs) + mat_off(h), mat_var(h, lv)); gx = mat_rot(sx*r, cs); gy = mat_rot(sy*r, cs);
#ifndef MAT_BAKE
	gx *= mat_gs; gy *= mat_gs;                                       // 烘焙时不偏（纹素足迹本来就是目标滤波宽度）
#endif
	if ((mat_perf & 128) != 0) { gx *= 1e5; gy *= 1e5; }             // 诊断 128：全取最顶层 mip（指令照旧，不走显存）
	if (mat_lod2.w > 0.0) {
		float lx = length(gx), ly = length(gy), c = mat_lod2.w;
		if (lx > c*ly) gy *= lx/(c*max(ly, 1e-12)); else if (ly > c*lx) gx *= ly/(c*max(lx, 1e-12));
	}
}
// 一种材质的 ah（hex 三格加权）：A = Σ wi·ah / Σ wi，wi = W·mix(1, a, 高度权)（留给导数图用）
void mat_fA(sampler2DArray tah, vec4 lv, bool rot, vec2 sx, vec2 sy, vec3 W, vec4 q1, uint h1, vec4 q2, uint h2, vec4 q3, uint h3,
		out vec4 A, out vec3 wi) {
	vec4 Aa = vec4(0.0); wi = vec3(0.0); vec3 uv; vec2 gx, gy, cs; vec4 ah;
	if (W.x > 0.0) { mat_uvg(lv, rot, sx, sy, q1, h1, uv, gx, gy, cs); ah = textureGrad(tah, uv, gx, gy); wi.x = W.x*mix(1.0, ah.a, mat_hexp.z); Aa += wi.x*ah; }
	if (W.y > 0.0) { mat_uvg(lv, rot, sx, sy, q2, h2, uv, gx, gy, cs); ah = textureGrad(tah, uv, gx, gy); wi.y = W.y*mix(1.0, ah.a, mat_hexp.z); Aa += wi.y*ah; }
	if (W.z > 0.0) { mat_uvg(lv, rot, sx, sy, q3, h3, uv, gx, gy, cs); ah = textureGrad(tah, uv, gx, gy); wi.z = W.z*mix(1.0, ah.a, mat_hexp.z); Aa += wi.z*ah; }
	A = Aa/(wi.x + wi.y + wi.z);
}
// 同一组格、同样的 wi：导数图 → 世界坡度（∂h/∂E、∂h/∂N）
vec2 mat_fD(sampler2DArray td, vec4 lv, bool rot, vec2 sx, vec2 sy, vec3 wi, vec4 q1, uint h1, vec4 q2, uint h2, vec4 q3, uint h3) {
	vec2 g = vec2(0.0); vec3 uv; vec2 gx, gy, cs;
	if (wi.x > 0.0) { mat_uvg(lv, rot, sx, sy, q1, h1, uv, gx, gy, cs); g += wi.x*mat_rotT(textureGrad(td, uv, gx, gy).rg - 0.5, cs); }
	if (wi.y > 0.0) { mat_uvg(lv, rot, sx, sy, q2, h2, uv, gx, gy, cs); g += wi.y*mat_rotT(textureGrad(td, uv, gx, gy).rg - 0.5, cs); }
	if (wi.z > 0.0) { mat_uvg(lv, rot, sx, sy, q3, h3, uv, gx, gy, cs); g += wi.z*mat_rotT(textureGrad(td, uv, gx, gy).rg - 0.5, cs); }
	return g*(2.0*mat_gain.z)*mat_vpf(wi)/(wi.x + wi.y + wi.z);
}
// 三角格权：减门槛 t 再归一（!hex 时只留最大的一格）
vec3 mat_wcut(vec3 W, float t, bool hex) {
	if (!hex) return W.x >= W.y && W.x >= W.z ? vec3(1.0, 0.0, 0.0) : (W.y >= W.z ? vec3(0.0, 1.0, 0.0) : vec3(0.0, 0.0, 1.0));
	W = max(W - t, 0.0); return W/(W.x + W.y + W.z);
}

// P：ENU；dPx、dPy：d(E, N)/d 屏幕 x、y（分支外算好）；fp：像素足迹（米）；ny：几何法线的世界 y；lee：石旁积尘（地平线GI 的石遮图，调用方算）；
// macro_r：宏观反照率相对其 ~8 m 低频的对数残差（调用方算，没有 HiRISE 处 0）。
// 出：det 细节反照率（均值 1）、mg 法线坡度（∂h/∂E、∂h/∂N）、rough 粗糙度 σ、dust 积尘 0..1、dbg 诊断色
#ifdef MAT_BAKE
vec3 mc_bw = vec3(0.0); vec3 mc_hk = vec3(0.0); float mc_sk = 0.0;   // 材质缓存烘焙：交界起伏不能用屏幕导数，把混合权重、各材质高度、材质组合记号交给烘焙胶水做有限差分
#endif
void mat_frag(vec3 P, vec2 dPx, vec2 dPy, float fp, float g_meso, float g_micro, float ny, float lee, float macro_r,
		out vec3 det, out vec2 mg, out float rough, out float dust, out vec3 dbg) {
	if ((mat_perf & 64) != 0) fp = 0.0;                          // 诊断 64：不按足迹降级
	// 内容分级（材质数 kk、hex 格权门槛 t）用 fpc：运行时 = 像素足迹（省采样）；烘焙时 = 0（缓存的内容只能是世界坐标的函数：
	// 烘焙里按层的纹素边长 t 降级，同一块地从上往下看（细层）和斜着往远看（粗层）就是两种内容——次要材质逐层消失，见 docs/地面材质/贴图随视角变化_交接.md）。
	// 烘焙是增量的，多出的采样不在每帧每像素上；导数图 / 微观淡出仍按 fp（那是滤波：足迹大了坡度和微观平均掉）。
#ifdef MAT_BAKE
	float fpc = 0.0;
#else
	float fpc = fp;
#endif
	vec2 xz = vec2(P.x, -P.y);
	// 控制图（近图 → 远图 → 图外）
#if defined(MAT_N16) && !defined(MAT_DENSE)
	ivec3 ik; vec3 wk;
	{                                                             // 稀疏 4 项小表（和位移同一个 mat_table）→ 前 3 → 降序
		ivec4 tid; vec4 tw; mat_table(xz, tid, tw, dust);
		if (mat_steep.z >= 0.0 && g_meso > 0.0) {
			float sl = degrees(acos(clamp(ny, -1.0, 1.0)));
			float ws = g_meso*mat_steep.w/(1.0 + exp(-(sl - mat_steep.x)/mat_steep.y));
			if (ws > 0.01) mat_put(tid, tw, int(mat_steep.z), ws*(tw.x + tw.y + tw.z + tw.w));
		}
		// 4 项降序（5 次比较交换）
#define MAT_SW(a, b) if (tw.a < tw.b) { float tf = tw.a; tw.a = tw.b; tw.b = tf; int ti = tid.a; tid.a = tid.b; tid.b = ti; }
		MAT_SW(x, y) MAT_SW(z, w) MAT_SW(x, z) MAT_SW(y, w) MAT_SW(y, z)
		ik = tid.xyz; wk = tw.xyz;
	}
#else
	vec4 a0 = vec4(0.0), a1 = vec4(0.0), a2 = vec4(0.0), a3 = vec4(0.0); dust = 0.0;
	{
		float e = max(abs(xz.x), abs(xz.y));
		float a = mat_region(e, mat_grid.x, 0.05), b = (1.0 - a)*mat_region(e, mat_grid.z, 0.05);
		if (a > 0.0) mat_bilin8(mat_ctrl_n, xz, mat_grid.x, mat_grid.y, a, a0, a1, a2, a3, dust);
		if (b > 0.0) mat_bilin8(mat_ctrl_f, xz, mat_grid.z, mat_grid.w, b, a0, a1, a2, a3, dust);
		float o = 1.0 - a - b;
		if (o > 0.0) {
			mat_acc8(a0, a1, a2, a3, mat_out_id.x, o*mat_out_w.x); mat_acc8(a0, a1, a2, a3, mat_out_id.y, o*mat_out_w.y);
			mat_acc8(a0, a1, a2, a3, mat_out_id.z, o*mat_out_w.z); mat_acc8(a0, a1, a2, a3, mat_out_id.w, o*mat_out_w.w);
			dust += o*0.15;
		}
	}
	if (mat_steep.z >= 0.0 && g_meso > 0.0) {                    // 像素坡度过休止角 → 陡面岩（Navcam 区控制图本身已按 0.1 m 坡度分好，不再加）
		float sl = degrees(acos(clamp(ny, -1.0, 1.0)));
		float ws = g_meso*mat_steep.w/(1.0 + exp(-(sl - mat_steep.x)/mat_steep.y));
		if (ws > 0.01) mat_acc8(a0, a1, a2, a3, int(mat_steep.z), ws*(dot(a0, vec4(1.0)) + dot(a1, vec4(1.0)) + dot(a2, vec4(1.0)) + dot(a3, vec4(1.0))));
	}
	ivec3 ik; vec3 wk;
	ik.x = mat_pop8(a0, a1, a2, a3, wk.x); ik.y = mat_pop8(a0, a1, a2, a3, wk.y); ik.z = mat_pop8(a0, a1, a2, a3, wk.z);
#endif
	int kk = fpc > mat_lod2.z ? 1 : (fpc > mat_lod3.x ? min(mat_k, 2) : mat_k);   // 足迹：< lod3.x 前 k 种，到 lod2.z 前 2 种，再远只 1 种
	if (kk < 3) wk.z = 0.0;
	if (kk < 2) wk.y = 0.0;
	wk /= max(wk.x + wk.y + wk.z, 1e-9);
	wk = vec3(wk.x >= MAT_WMIN ? wk.x : 0.0, wk.y >= MAT_WMIN ? wk.y : 0.0, wk.z >= MAT_WMIN ? wk.z : 0.0);
	wk /= max(wk.x + wk.y + wk.z, 1e-9);
	ik = max(ik, ivec3(0));
	dust = clamp(max(dust, lee), 0.0, 1.0);
	vec4 b0 = mat_bl[ik.x], b1 = mat_bl[ik.y], b2 = mat_bl[ik.z];
	bool r0 = b0.w > 0.5, r1 = b1.w > 0.5, r2 = b2.w > 0.5;
	vec4 MN = mat_macro_n(P.xy);
	vec3 nb = g_meso*mat_macro.z*vec3(mat_nsel(MN, ik.x), mat_nsel(MN, ik.y), mat_nsel(MN, ik.z));   // 宏观：每种材质的混合偏置随地漂

	// 中观：先只取 ah，按高度混合定权重
	vec4 A0 = vec4(1.0, 1.0, 1.0, 0.5), A1 = A0, A2 = A0;
	float t = mix(mat_lod2.x, mat_lod2.y, smoothstep(mat_lod.x, mat_lod.y, fpc));
	vec3 W; vec4 q1, q2, q3; uint h1, h2, h3; vec3 wi0 = vec3(0.0), wi1 = wi0, wi2 = wi0;
	bool meso = g_meso > 0.0 && (mat_perf & 40) == 0;            // 诊断 8：不采任何层；32：不采中观
#ifdef MAT_NOLAYERS
	meso = false;                                                // 诊断（编译期，--着色器定义=MAT_NOLAYERS）：层的代码整个编没，比 位 8 看寄存器的影响
#endif
	if (meso) {
		ivec2 v1, v2, v3; mat_tri(P.xy, mat_hexp.x, W, v1, v2, v3);
		W = mat_wcut(W, t, mat_hex_meso == 1);
		mat_cellq(P.xy, mat_hexp.x, v1, 0u, q1, h1); mat_cellq(P.xy, mat_hexp.x, v2, 0u, q2, h2); mat_cellq(P.xy, mat_hexp.x, v3, 0u, q3, h3);
		vec4 B;
		if (wk.x > 0.0) { mat_fA(mat_meso_ah, mat_me[ik.x], r0, dPx, dPy, W, q1, h1, q2, h2, q3, h3, B, wi0); float f = mat_vpf(wi0); A0 = vec4(mix(vec3(1.0), 1.0 + (mat_gain.x*B.rgb - 1.0)*f, g_meso), 0.5 + g_meso*(B.a - 0.5)*f); }
		if (wk.y > 0.0) { mat_fA(mat_meso_ah, mat_me[ik.y], r1, dPx, dPy, W, q1, h1, q2, h2, q3, h3, B, wi1); float f = mat_vpf(wi1); A1 = vec4(mix(vec3(1.0), 1.0 + (mat_gain.x*B.rgb - 1.0)*f, g_meso), 0.5 + g_meso*(B.a - 0.5)*f); }
		if (wk.z > 0.0) { mat_fA(mat_meso_ah, mat_me[ik.z], r2, dPx, dPy, W, q1, h1, q2, h2, q3, h3, B, wi2); float f = mat_vpf(wi2); A2 = vec4(mix(vec3(1.0), 1.0 + (mat_gain.x*B.rgb - 1.0)*f, g_meso), 0.5 + g_meso*(B.a - 0.5)*f); }
	}
	// 按高度混合：w_k ∝ W_k·exp((对比·(a_k − ½) + 偏置 + 宏观偏置)/锐度)
	vec3 bw = wk*exp((vec3(b0.x, b1.x, b2.x)*(vec3(A0.a, A1.a, A2.a) - 0.5) + vec3(b0.y, b1.y, b2.y) + nb)/mat_hexp.w);
	bw /= bw.x + bw.y + bw.z;
	// 导数图、微观只给混合后权重最大的那种材质（锐度 0.1 下过渡带很窄；省 2/3 的这部分采样，也少占寄存器）
	int jm = bw.x >= bw.y && bw.x >= bw.z ? 0 : (bw.y >= bw.z ? 1 : 2);
	int mj = jm == 0 ? ik.x : (jm == 1 ? ik.y : ik.z); bool rj = jm == 0 ? r0 : (jm == 1 ? r1 : r2);
	vec3 wij = jm == 0 ? wi0 : (jm == 1 ? wi1 : wi2);
	vec2 Gm = vec2(0.0); vec3 Dm = vec3(1.0);
	float dg = (mat_perf & 1) != 0 ? 0.0 : 1.0 - smoothstep(mat_lod.z, mat_lod.w, fp);
	if (meso && dg > 0.0) Gm = dg*g_meso*mat_fD(mat_meso_d, mat_me[mj], rj, dPx, dPy, wij, q1, h1, q2, h2, q3, h3);
	// 交界起伏：混合高度的梯度 = Σ w_k ∇h_k + Σ h_k ∇w_k。导数图只给了权重最大那种的 ∇h，第二项（沙里冒出的碎片、板缘这类材质交界的坎）没有，
	// 旧 4 槽版按绝对高度混合再 dFdx 凹凸是有的。这里用屏幕导数求 ∇w（mat_edge 是 uniform，统一控制流），h_k 由 a 和每种材质的高差换成米；
	// 和导数图一起按足迹淡出，坡度限 45°。
	if (mat_edge > 0.0) {
		vec3 hk = (vec3(A0.a, A1.a, A2.a) - 0.5)*vec3(mat_hrng[ik.x], mat_hrng[ik.y], mat_hrng[ik.z]);
		float sk = float(kk) + 4.0*float(ik.x) + 64.0*float(ik.y) + 1024.0*float(ik.z) + 16384.0*dot(vec3(greaterThan(wk, vec3(0.0))), vec3(1.0, 2.0, 4.0));
#ifdef MAT_BAKE
		mc_bw = bw; mc_hk = hk; mc_sk = sk;
#endif
		float ex = dot(hk, dFdx(bw)), ey = dot(hk, dFdy(bw));
		float dj = dPx.x*dPy.y - dPx.y*dPy.x;
		vec2 ge = abs(dj) > 1e-14 ? vec2(ex*dPy.y - ey*dPx.y, ey*dPx.x - ex*dPy.x)/dj : vec2(0.0);
		float gl = length(ge);
		if (gl > 1.0) ge /= gl;
		// 2×2 像素块里参与的材质（号、k 档、过权重下限的）不同时 ∇w 是跳变不是交界（足迹档的分界会画出一条虚线），这种块不加
		Gm += fwidth(sk) == 0.0 ? mat_edge*dg*ge : vec2(0.0);
	}
#if !defined(MAT_NOLAYERS) && !defined(MAT_NOMICRO)
	g_micro *= 1.0 - smoothstep(mat_lod3.z, mat_lod3.w, fp);
	if (g_micro > 0.0 && (mat_perf & 24) == 0) {                 // 诊断 16：不采微观
		ivec2 v1, v2, v3; mat_tri(P.xy, mat_hexmi, W, v1, v2, v3);
		W = mat_wcut(W, mat_lod3.y, mat_hex_micro == 1);
		mat_cellq(P.xy, mat_hexmi, v1, 1u, q1, h1); mat_cellq(P.xy, mat_hexmi, v2, 1u, q2, h2); mat_cellq(P.xy, mat_hexmi, v3, 1u, q3, h3);
		vec4 B; vec3 wi;
#ifdef MAT_MICRO0
		mat_fA(mat_micro_ah, vec4(0.0, 1.0, 0.11, 0.0), rj, dPx, dPy, W, q1, h1, q2, h2, q3, h3, B, wi);
#else
		mat_fA(mat_micro_ah, mat_mi[mj], rj, dPx, dPy, W, q1, h1, q2, h2, q3, h3, B, wi);
#endif
		Dm = mix(vec3(1.0), 1.0 + (mat_gain.y*B.rgb - 1.0)*mat_vpf(wi), g_micro); Gm += g_micro*mat_fD(mat_micro_d, mat_mi[mj], rj, dPx, dPy, wi, q1, h1, q2, h2, q3, h3);
	}
#endif
	det = (bw.x*A0.rgb + bw.y*A1.rgb + bw.z*A2.rgb)*Dm;
#if defined(MAT_N16) && !defined(MAT_NOGAIN)
	if (mat_gk.x > 0.0 && g_meso > 0.0) {                         // 中景增益：各材质自己的平均亮度 / 颜色（样块入库时都归一成 1，只有 HiRISE 的 ±3% 起伏）。只加 4 m 以下的差别：除以局部 G 的 4 m 低通，大尺度仍是 HiRISE
		vec3 Gp = bw.x*mat_gainv[ik.x].rgb + bw.y*mat_gainv[ik.y].rgb + bw.z*mat_gainv[ik.z].rgb;
		vec3 Gl = textureLod(mat_glp, (xz + mat_gk.y)/(2.0*mat_gk.y), 0.0).rgb;
		det *= pow(Gp/max(Gl, vec3(0.05)), vec3(mat_gk.x*g_meso));
	}
#endif
	mg = Gm;
	rough = dot(bw, mix(vec3(0.8), vec3(b0.z, b1.z, b2.z), g_meso));   // σ：数据区（反照率来自照片）保持全场统一的 0.8，见 阶段1.md §9.4
	dbg = vec3(0.0);
	if (mat_dbg == 1) dbg = wk.x*MAT_PAL[ik.x & 15] + wk.y*MAT_PAL[ik.y & 15] + wk.z*MAT_PAL[ik.z & 15];   // 只在诊断时（常量数组动态下标）
	float mc = clamp(1.0 + g_meso*(1.6*mat_macro.x*MN.x - mat_macro.y*macro_r), 0.35, 1.8);   // 宏观：细节对比随地变、宏观亮处（多尘）降对比
	det = (1.0 + (det - 1.0)*mc)*(1.0 + g_meso*mat_macro.w*MN.y);                          // 宏观：亮度起伏
	det = mix(det, vec3(1.0), mat_dust.w*dust*g_meso);         // 积尘降对比、加粗糙：只在数据分辨不出处（Navcam 区照片里已有尘）
	rough += mat_dust_rough*dust*g_meso;
}
#endif
