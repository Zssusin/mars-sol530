// 材质缓存（原型，engine-vt 分支）：读 材质缓存.gd 烘的相机中心 clipmap，代替 mat_frag 的控制图 + 多材质 hex 采样。
// 依赖 材质.gdshaderinc（MAT_FRAG）的 mat_tri / mat_cellq / mat_fA / mat_fD（运行时微观）。
// 选层：像素在地面上的足迹椭圆，短轴 mn、长轴 mj；有效宽度 f = max(mn, mj/各向异性上限)（硬件各向异性负责长轴），
//       lf = log2(f/t0)；f 落在 [t_i, 2t_i) 用第 i 层，后半段（a > ½）再和 i + 1 层线性混合，免得换层处有线；
//       长轴足迹要整个落在该层的有效窗口里，否则往粗层退。lf 低于 mc_info2.x 走实时 mat_frag，[x, x + 宽) 里按屏幕噪声抖动过渡。
uniform sampler2DArray mc_a : filter_linear_mipmap_anisotropic, repeat_enable;   // det/4（含积尘色，rgb，烘焙时加抖动）、σ
uniform sampler2DArray mc_b : filter_linear_mipmap_anisotropic, repeat_enable;   // 0.5 + mg/2、材质号/16、k/2
uniform sampler2DArray mc_bn : filter_nearest, repeat_enable;                    // 同一张 B，最近邻取材质号
uniform vec4 mc_win[16];                                         // 每层有效窗口：世界 x0, z0, x1, z1（米）；x1 < x0 = 还没烘
uniform vec4 mc_info = vec4(0.004, 2048.0, 0.0, 8.0);            // t0（米）、N、层数（0 = 关）、各向异性上限
uniform vec4 mc_info2 = vec4(-1.0, 0.5, 0.0, 0.0);               // 实时→缓存过渡起点、宽（lf）、帧号（抖动）、诊断（1 = 按层上色）

float mc_ign(vec2 p) { return fract(52.9829189*fract(dot(p, vec2(0.06711056, 0.00583715)))); }   // Jimenez 2014 交错梯度噪声

bool mc_in(int i, vec2 xz, float m) {
	vec4 w = mc_win[i]; float mm = m + 2.0*mc_info.x*exp2(float(i));
	return xz.x - mm > w.x && xz.x + mm < w.z && xz.y - mm > w.y && xz.y + mm < w.w;
}
void mc_tap(int i, vec2 xz, vec2 gx, vec2 gy, out vec4 A, out vec4 B) {
	float s = 1.0/(mc_info.y*mc_info.x*exp2(float(i)));
	vec3 uv = vec3(xz*s, float(i)); vec2 dx = gx*s, dy = gy*s;
	float lx = length(dx), ly = length(dy), c = mc_info.w;      // 各向异性上限（同 mat_uvg：放大短轴导数）
	if (lx > c*ly) dy *= lx/(c*max(ly, 1e-12)); else if (ly > c*lx) dx *= ly/(c*max(lx, 1e-12));
	A = textureGrad(mc_a, uv, dx, dy); B = textureGrad(mc_b, uv, dx, dy);
}

// 用了缓存返回 true。det：细节反照率（已含积尘色，调用方别再乘）；mg：中观 + 微观坡度；rough：σ
bool mc_frag(vec3 P, vec2 dPx, vec2 dPy, float fp, float g_micro, vec2 fc, out vec3 det, out vec2 mg, out float rough) {
	det = vec3(1.0); mg = vec2(0.0); rough = 0.8;
	int nl = int(mc_info.z);
	if (nl <= 0) return false;
	vec2 xz = vec2(P.x, -P.y);
	vec2 gx = vec2(dPx.x, -dPx.y), gy = vec2(dPy.x, -dPy.y);
	gx *= mat_gs; gy *= mat_gs;                                  // --mip偏：缓存按像素足迹选层，偏移要在选层前乘（缓存纹理没有 mip，层间混合才是滤波）
	float lx = length(gx), ly = length(gy);
	float mj = max(lx, ly), mn = min(lx, ly);
	float lf = log2(max(max(mn, mj/mc_info.w), 1e-7)/mc_info.x);
	if (lf < mc_info2.x + mc_info2.y*mc_ign(fc + 5.588238*mc_info2.z)) return false;
	lf = max(lf, 0.0);
	int i = int(floor(lf)); float a = smoothstep(0.5, 1.0, lf - float(i));
	float m = 0.5*mj;
	while (i < nl && !mc_in(i, xz, m)) { i++; a = 0.0; }
	if (i >= nl) return false;
	vec4 A, B; mc_tap(i, xz, gx, gy, A, B);
	if (a > 0.0 && i + 1 < nl && mc_in(i + 1, xz, m)) {
		vec4 A2, B2; mc_tap(i + 1, xz, gx, gy, A2, B2);
		A = mix(A, A2, a); B = mix(B, B2, a);
	}
	det = A.rgb*4.0; rough = A.a; mg = (B.xy - 0.5)*2.0;
#if !defined(MAT_NOLAYERS) && !defined(MAT_NOMICRO)
	float gm = g_micro*(1.0 - smoothstep(mat_lod3.z, mat_lod3.w, fp));
	if (gm > 0.0 && (mat_perf & 24) == 0) {                     // 运行时微观：只给缓存里权重最大的那种材质（同 mat_frag）
		float s = 1.0/(mc_info.y*mc_info.x*exp2(float(i)));
		int mjm = clamp(int(textureLod(mc_bn, vec3(xz*s, float(i)), 0.0).z*16.0), 0, 15);
		bool rj = mat_bl[mjm].w > 0.5;
		vec3 W; ivec2 v1, v2, v3; mat_tri(P.xy, mat_hexmi, W, v1, v2, v3);
		W = mat_wcut(W, mat_lod3.y, mat_hex_micro == 1);
		vec4 q1, q2, q3; uint h1, h2, h3;
		mat_cellq(P.xy, mat_hexmi, v1, 1u, q1, h1); mat_cellq(P.xy, mat_hexmi, v2, 1u, q2, h2); mat_cellq(P.xy, mat_hexmi, v3, 1u, q3, h3);
		vec4 Bm; vec3 wi;
		mat_fA(mat_micro_ah, mat_mi[mjm], rj, dPx, dPy, W, q1, h1, q2, h2, q3, h3, Bm, wi);
		vec3 Dm = mix(vec3(1.0), 1.0 + (mat_gain.y*Bm.rgb - 1.0)*mat_vpf(wi), gm);
		mg += gm*mat_fD(mat_micro_d, mat_mi[mjm], rj, dPx, dPy, wi, q1, h1, q2, h2, q3, h3);
		det *= 1.0 + 2.0*B.w*(Dm - 1.0);
	}
#endif
	if (mc_info2.w > 0.5 && mc_info2.w < 1.5) det = 0.5 + 0.5*cos(6.2832*((float(i) + a)*0.17 + vec3(0.0, 0.33, 0.67)));   // 诊断：按层上色
	return true;
}

// —— 微观自阴影（颗粒感 §2）：读 材质缓存.gd 烘的地平线图（8 方位傅里叶 3 阶，层 0..LH−1），按太阳方位重建地平线仰角，
//    和太阳相对宏观平面的仰角比较（太阳盘 + 编码误差 → 软边），返回直射光可见度；light() 里和 CSM、远处地影取最小。
//    地平线是相对水平面算的；坡面上用宏观法线 nm 把太阳仰角换成相对坡面的（微起伏叠在坡上）。
uniform sampler2DArray mc_c0 : filter_linear, repeat_enable;
uniform sampler2DArray mc_c1 : filter_linear, repeat_enable;
uniform vec4 mc_hwin[8];                                         // 每层地平线有效窗口（比高度窗口往里缩 128 纹素）；x1 < x0 = 无
uniform vec4 mc_ms = vec4(0.0, 0.02, 0.0, 0.0);                  // 有地平线图的层数（0 = 关）、软边半宽（弧度）
uniform vec3 mc_sun = vec3(0.0, 1.0, 0.0);                       // 太阳方向（Godot 世界，指向太阳），实景.gd set_sun 设
uniform vec4 mc_sunt = vec4(1.0, 0.0, 1.0, 0.0);                 // cos φ, sin φ, cos 2φ, sin 2φ（φ = atan2(sun.z, sun.x)）
uniform vec2 mc_sunt3 = vec2(1.0, 0.0);                          // cos 3φ, sin 3φ

vec2 mc_hz_tap(int i, vec2 xz, float e) {                          // (可见度, 地平线仰角)
	float s = 1.0/(mc_info.y*mc_info.x*exp2(float(i)));
	vec3 uv = vec3(xz*s, float(i));
	vec4 a = textureLod(mc_c0, uv, 0.0), b = textureLod(mc_c1, uv, 0.0);
	float al = a.r*0.8 + 0.8*((a.g - 0.5)*mc_sunt.x + (a.b - 0.5)*mc_sunt.y + (a.a - 0.5)*mc_sunt.z + (b.r - 0.5)*mc_sunt.w + (b.g - 0.5)*mc_sunt3.x + (b.b - 0.5)*mc_sunt3.y);
	return vec2(clamp(0.5 + (e - max(al, 0.0))/(2.0*mc_ms.y), 0.0, 1.0), max(al, 0.0));
}
// xz：世界 (x, z)；gx、gy：d(x, z)/d 屏幕；nm：宏观平面法线（世界）
float mc_hzv(vec2 xz, vec2 gx, vec2 gy, vec3 nm, out float al_dbg) {
	al_dbg = 0.0;
	int lh = int(mc_ms.x);
	if (lh <= 0) return 1.0;
	float e = asin(clamp(dot(nm, mc_sun), 0.0, 1.0));
	if (e <= 0.0) return 1.0;                                     // 太阳在宏观平面下：直射本来就是 0
	float lx = length(gx), ly = length(gy);
	float lf = max(log2(max(max(min(lx, ly), max(lx, ly)/mc_info.w), 1e-7)/mc_info.x), 0.0);
	int i = int(floor(lf)); float a = smoothstep(0.5, 1.0, lf - float(i));
	float m = 0.5*max(lx, ly);
	while (i < lh) {
		vec4 w = mc_hwin[i]; float mm = m + 2.0*mc_info.x*exp2(float(i));
		if (xz.x - mm > w.x && xz.x + mm < w.z && xz.y - mm > w.y && xz.y + mm < w.w) break;
		i++; a = 0.0;
	}
	if (i >= lh) return 1.0;
	vec2 vt = mc_hz_tap(i, xz, e);
	float v = vt.x; al_dbg = vt.y;
	if (a > 0.0 && i + 1 < lh) {
		vec4 w = mc_hwin[i + 1]; float mm = m + 2.0*mc_info.x*exp2(float(i + 1));
		if (xz.x - mm > w.x && xz.x + mm < w.z && xz.y - mm > w.y && xz.y + mm < w.w) v = mix(v, mc_hz_tap(i + 1, xz, e).x, a);
	}
	return v;
}
