// 中观细节位移（地形.gdshader 与 石块.gdshader 共用）：地面顶点抬中观高度；石块按 rock_lift 跟着地面走。
// 新材质（默认）：高度来自 材质.gdshaderinc 的控制图 + hex 平铺 + mat_meso_h16，门是 73 烘的 mat_gate（和片元第 3 步同一条 2r 公式，
//   修了旧版只有设计值 0.73 倍的问题），CPU 的 h_cpu 用同一套（材质.gd、terrain_core.cpp），所以车轮、撒石和画出来的地面一致。
// --材质=旧（#define MAT_OLD）：4 槽中观、按 r（不是 2r）判门、CPU 不算位移、石块整体抬，和 B 步之前逐像素相同。
// 依赖 公共.gdshaderinc 的 fbm_noise（只旧版）。所需 uniform 由 实景.gd 从地面材质抄到石块材质（lod_cam / lod_range0 每帧两边都设）。
uniform sampler2D albedo_mid : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D albedo_near : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform vec4 half_size = vec4(40000.0, 1000.0, 50.0, 10.0);     // CTX, HiRISE, 中, 近
uniform vec4 data_res = vec4(20.0, 0.25, 0.02, 0.01);
// 2 地类权重（RGBA＝沙、砾石风化层、基岩、暗色岩块）
uniform sampler2D class_mid : filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D class_hirise : filter_linear_mipmap_anisotropic, repeat_disable;
uniform vec2 class_half = vec2(50.0, 1000.0);
uniform sampler2D meso_h[4] : filter_linear_mipmap, repeat_enable;
uniform vec4 meso_size = vec4(2.0);                               // 每类各自的样块边长（米）：素材库样块像素不一
uniform vec3 lod_cam;                                             // 主相机位置（阴影 pass 也用它，几何才一致）
uniform float lod_c0 = 0.02;
uniform float lod_range0 = 6.0;
// 11 中观细节做成真几何（只在 CDLOD 下）：相机 disp_far 以内把中观高度加到顶点上，远处渐隐。
//    着色法线不变（数据法线 + 全部细节凹凸），位移只负责轮廓、遮挡、自阴影。mip 只看到相机的距离（不看块的级）→ 公共顶点无缝。
uniform float disp_far = 25.0;
uniform float disp_gain = 0.0;                                    // 0 = 关（实景.gd 给地面、石块都设）

float region(float e, float h, float feather) { return clamp((h*0.97 - e)/(h*feather), 0.0, 1.0); }
vec2 map_uv(vec3 p, float h) { return vec2(p.x, -p.y)/(2.0*h) + 0.5; }

// 随机平铺：原样一次、旋转 2.1 rad 加平移一次，用低频噪声混合（同 58 的 stoch）
vec2 rot_uv(vec3 p, float size) {
	vec2 q = p.xy/size + vec2(0.37, 0.71);
	float c = cos(2.1), s = sin(2.1);
	q = vec2(c*q.x - s*q.y, s*q.x + c*q.y);
	return vec2(q.x, -q.y);
}

#include "res://着色器/材质.gdshaderinc"

#ifdef MAT_OLD
float meso_disp(vec3 p, float dd) {                               // p：ENU；返回米
	float e = max(abs(p.x), abs(p.y));
	float res = data_res.x*4.0, w;                                // 同片元第 1 步，只算数据分辨率
	w = region(e, half_size.x, 0.08); res = mix(res, data_res.x, w);
	w = region(e, half_size.y, 0.08); res = mix(res, data_res.y, w);
	w = region(e, half_size.z, 0.08)*textureLod(albedo_mid, map_uv(p, half_size.z), 0.0).a; res = mix(res, data_res.z, w);
	w = region(e, half_size.w, 0.08)*textureLod(albedo_near, map_uv(p, half_size.w), 0.0).a; res = mix(res, data_res.w, w);
	float g_meso = clamp(log2(res/0.04)/log2(0.5/0.04), 0.0, 1.0);
	if (g_meso <= 0.0) return 0.0;
	vec4 km = textureLod(class_mid, map_uv(p, class_half.x), 0.0);
	vec4 kh = textureLod(class_hirise, map_uv(p, class_half.y), 0.0);
	float wm = region(e, class_half.x, 0.15)*clamp((km.r + km.g + km.b + km.a)*2.0, 0.0, 1.0);
	vec4 W = mix(mix(vec4(0.35, 0.35, 0.2, 0.1), kh, region(e, class_half.y, 0.08)), km, wm);
	float nmask = clamp((fbm_noise(p*1.3) - 0.5)*6.0 + 0.5, 0.0, 1.0);
	float cell = lod_c0*max(dd, 0.1)/lod_range0;                  // 这个距离上 CDLOD 的格距（连续）
	float hk[4]; float hmax = -1e9;
	for (int k = 0; k < 4; k++) {
		float mip = max(log2(cell*float(textureSize(meso_h[k], 0).x)/meso_size[k]), 0.0);
		vec2 ua = vec2(p.x, -p.y)/meso_size[k], ub = rot_uv(p, meso_size[k]);
		hk[k] = g_meso*mix(textureLod(meso_h[k], ua, mip).r, textureLod(meso_h[k], ub, mip).r, nmask);
		hmax = max(hmax, hk[k]);
	}
	float tot = 0.0, h = 0.0;
	for (int k = 0; k < 4; k++) { float b = (W[k] + 1e-4)*exp((hk[k] - hmax)/0.004); tot += b; h += b*hk[k]; }
	return h/tot;
}

float disp_at(vec3 g, float dd) {                                 // g：Godot 世界坐标；返回往上抬多少米
	if (disp_gain <= 0.0 || dd >= disp_far) return 0.0;
	return disp_gain*(1.0 - smoothstep(0.6*disp_far, disp_far, dd))*meso_disp(vec3(g.x, -g.z, g.y), dd);
}
float rock_lift(vec3 o, float dd) { return disp_at(o, dd); }    // 旧：石块整体随脚下地面抬（撒石取高不含位移）
#else
// g：Godot 世界坐标；返回往上抬多少米。cell = 这个距离上 CDLOD 的格距（选 mip，同旧版）；disp_far 外渐隐（顶点开销）
float disp_at(vec3 g, float dd) {
	if (disp_gain <= 0.0 || dd >= disp_far) return 0.0;
	float cell = lod_c0*max(dd, 0.1)/lod_range0;
	return disp_gain*(1.0 - smoothstep(0.6*disp_far, disp_far, dd))*mat_disp(g.xz, cell, false);
}
// 石块：撒石按 h_cpu（含完整位移）放好了，不再整体抬；只在地面位移渐隐处（0.6–1 × disp_far）跟着地面一起降，
// 1.6 × disp_far 外不管（≤ 1 像素）。o：石块原点（Godot 世界）
float rock_lift(vec3 o, float dd) {
	if (disp_gain <= 0.0 || dd <= 0.6*disp_far || dd >= 1.6*disp_far) return 0.0;
	return -disp_gain*smoothstep(0.6*disp_far, disp_far, dd)*mat_disp(o.xz, 0.0, true);
}
#endif
