// 自动地形着色器：58_实景场景.py ground_material() 的 Godot 版，步骤与 实景地形系统.md §3 一一对应。
// 世界坐标 Godot (x 东, y 上, z 南) ↔ ENU：E = x, N = −z, U = y。贴图 UV：Blender v = N/(2·half) + 0.5（v = 0 在图下沿），
// Godot UV 的 v = 0 在图上沿，所以 v = 0.5 − N/(2·half)。
// 第 4–7 步默认走 材质.gdshaderinc（阶段 1 B 步：控制图 + 纹理数组 + hex 平铺 + 导数图法线）；--材质=旧 时 实景.gd 在代码前加
// #define MAT_OLD，回到 4 槽中观 / 微观 + dFdx 凹凸（和 B 步之前逐像素相同）。
shader_type spatial;
render_mode cull_back, specular_disabled, world_vertex_coords;

#define MAT_FRAG
#include "res://着色器/公共.gdshaderinc"
#include "res://着色器/中观位移.gdshaderinc"
#include "res://着色器/地貌.gdshaderinc"
#include "res://着色器/地平线GI.gdshaderinc"
#ifdef MAT_CACHE
#include "res://着色器/材质缓存.gdshaderinc"   // 材质缓存（原型，engine-vt；--材质缓存=1 时 实景.gd 加这个定义）
#endif

// 1 宏观反照率（RGB sRGB，A＝可信度）
uniform sampler2D albedo_ctx : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D albedo_hirise : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform vec3 base_color = vec3(0.239, 0.164, 0.124);              // 线性（Blender RGB 节点）
// 2 地类权重（RGBA＝沙、砾石风化层、基岩、暗色岩块）
// 3–5 细节（反照率均值 1、8 位里存 1/gain×，gain 每块各自（scene.json detail.*.gain，老图块 2）；高度为米，float 贴图）
uniform sampler2D meso_alb[4] : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D micro_alb[4] : filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 meso_gain = vec4(2.0);
uniform vec4 micro_gain = vec4(2.0);
uniform sampler2D micro_h[4] : filter_linear_mipmap, repeat_enable;
uniform vec4 micro_size = vec4(0.2304);
uniform float pixel_angle = 0.000545;                             // 相机水平视场 / 宽度像素，渲染时按相机改
// 8 车辙（66_车辆动画.py）：R 深度（m）、G 第一次压到的时刻（s）；只显示时刻 ≤ track_time 的格，车辙随车往前长
// 1b 细层（scripts/Godot/72_近景细化.py，全分辨率 Navcam XYZ/RAS 重建）：4 mm 反照率（A = 权重）、2 mm 工作区贴片、
//    每纹素数据分辨率（log 编码）、片元细坡度（相对 CDLOD 第 0/1 层法线的残差 ∂h/∂E、∂h/∂N）。fine_half = 0：没有细层（--近细=0）
uniform sampler2D fine_alb : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D fine_patch : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D fine_res : filter_linear, repeat_disable;
uniform sampler2D fine_slope : filter_linear_mipmap_anisotropic, repeat_disable;
uniform float fine_half = 0.0;
uniform vec4 fine_patch_rect = vec4(0.0);                         // E0, N0, E1, N1（ENU，m）
uniform float fine_patch_res = 0.003;
uniform vec2 fine_slope_fade = vec2(0.01, 0.03);                  // 像素足迹在这之间细坡度淡出（再远 CDLOD 换粗层，残差对不上）
uniform sampler2D track_tex : filter_linear, repeat_disable;
uniform vec4 track_rect = vec4(0.0);                              // E0, N0, E1, N1（ENU，m）；全 0 = 没有车辙
uniform float track_time = -1.0;
// 15 尘卷风痕迹（天气模块写）：R = 0..1 的变暗程度（表层亮尘被卷走，露出暗的底），范围 dd_rect（ENU：E0, N0, E1, N1）；全 0 = 没有
uniform sampler2D dd_tex : filter_linear, repeat_disable;
uniform vec4 dd_rect = vec4(0.0);
uniform float dd_gain = 0.1;                                      // R = 1 时反照率降多少（比例）

// 10 CDLOD 地面（地形LOD.gd）：15 层嵌套高度图，第 k 层格距 c0·2^k、半宽 half0·2^k；块变换 = 缩放格距 + 平移到块角
uniform sampler2DArray hlv : filter_linear, repeat_disable;
uniform vec4 hlv_info = vec4(0.02, 6.0, 601.0, 15.0);            // c0, half0, N, 层数
uniform bool clip = false;                                        // false：老的 15 环网格（顶点自带高度和法线）
const float LOD_MORPH = 0.3;                                      // 每级可见半径的最后 30% 里渐变到粗一级
uniform int lod_dbg = 0;                                          // 诊断：1 不渐变；2 按级上色 + 块边框
uniform int geo_frag = 0;                                         // 1 = 小特征坡度逐像素算（贵）
uniform int geo_dbg = 0;                                          // 诊断：1 片元不算地貌坡度
uniform int perf_dbg = 0;                                         // 测帧诊断：1 跳过细节、2 跳过空气透视、3 跳过逐像素法线、4 常数反照率、5 只看反照率
uniform int prepass_cheap = 0;                                // --预通道简化=1：法线预通道里不取细节高度、不做凹凸（要自编引擎的 IN_NORMAL_PREPASS；官方版上无效）
varying float v_lod;
varying vec2 v_g;
varying vec3 v_geo;                                               // 14：x = 顶点格距（分工界线），yz = 大特征的坡度（顶点算好插值）

varying vec3 P;                                                   // ENU 世界坐标
varying vec3 v_ambc;                                              // 逐通道 EON 环境修正（fragment 写、light 读）
varying float v_sun;                                              // G2 远处地影：地形挡太阳后的可见度（fragment 写、light 读）
varying float v_ms;                                                 // 微观自阴影（材质缓存的地平线图）：直射光可见度，1 = 不遮；fragment 写、light 读
varying float v_rough;                                            // EON 粗糙度 σ：逐材质（fragment 写、light 读）；旧版常数 0.8

float hl_at(vec2 xz, float k) {
	float c = hlv_info.x*exp2(k), h = hlv_info.y*exp2(k);
	return textureLod(hlv, vec3(((xz + h)/c + 0.5)/hlv_info.z, k), 0.0).r;
}
// 用哪一层（可带小数：在两层之间线性混合）：包含该点的最细层，外缘 10% 里渐变到粗一层；不细于 kmin
float hl_level(vec2 xz, float kmin) {
	float e = max(abs(xz.x), abs(xz.y));
	float k0 = max(0.0, ceil(log2(max(e, 1e-6)/(hlv_info.y*0.98))));
	float hk = hlv_info.y*exp2(k0);
	float w = clamp((e - 0.9*hk)/(0.08*hk), 0.0, 1.0);
	return min(max(k0 + w, kmin), hlv_info.w - 1.0);
}
float hl_height(vec2 xz, float kf) {
	float k = floor(kf), t = kf - k;
	float a = hl_at(xz, k);
	if (t > 0.0) a = mix(a, hl_at(xz, k + 1.0), t);
	return a;
}
vec3 hl_normal(vec2 xz, float kf) {                               // 世界法线（Godot 坐标），中心差分，差分步长 = 该层格距
	float e = hlv_info.x*exp2(floor(kf));
	float hx = hl_height(xz + vec2(e, 0.0), kf) - hl_height(xz - vec2(e, 0.0), kf);
	float hz = hl_height(xz + vec2(0.0, e), kf) - hl_height(xz - vec2(0.0, e), kf);
	return normalize(vec3(-hx, 2.0*e, -hz));
}



void vertex() {
	if (clip) {                                                   // VERTEX 已是世界坐标（world_vertex_coords）
		float cell = MODEL_MATRIX[0][0];
		// 全局格点编号：相邻块在公共边上算出逐位相同的位置（用"块角 + 局部编号×格距"会差一个 ulp，光栅化漏出裂缝）
		vec2 g = round(VERTEX.xz/cell);
		float lod = round(log2(cell/lod_c0));
		float kmin = max(lod + log2(lod_c0/hlv_info.x), 0.0);   // 不取比本级格距更细的数据（否则远处闪）
		vec2 w = g*cell;
		float d = distance(vec3(w.x, hl_height(w, hl_level(w, kmin)), w.y), lod_cam);
		float r1 = lod_range0*exp2(lod);
		float mk = lod_dbg == 1 ? 0.0 : clamp((d - r1*(1.0 - LOD_MORPH))/(r1*LOD_MORPH), 0.0, 1.0);
		v_lod = lod; v_g = g - round(MODEL_MATRIX[3].xz/cell);
		g -= fract(g*0.5)*2.0*mk;                                 // 奇数格点并到偶数格点（负数也朝 −∞ 那个偶数）
		w = g*cell;
		float kf = hl_level(w, kmin);
		float y = hl_height(w, kf);
		float dd = distance(vec3(w.x, y, w.y), lod_cam);
		float gcell = lod_c0*max(dd, 0.1)/lod_range0;             // 这个距离上的 CDLOD 格距（连续，公共顶点一致）
		vec3 gv = geo_at2(w, gcell, gcell, geo_frag == 1 ? 1 : 0);  // 14 地貌印章：高 + 坡度（默认全在顶点算，片元只插值）
		y += gv.x;
		y += disp_at(vec3(w.x, y, w.y), dd);
		VERTEX = vec3(w.x, y, w.y);
		vec3 n0 = hl_normal(w, kf);
		v_geo = vec3(gcell, gv.y, gv.z);
		NORMAL = normalize(n0/n0.y - vec3(gv.y, 0.0, gv.z));
	}
	P = vec3(VERTEX.x, -VERTEX.z, VERTEX.y);
}

void fragment() {
	v_ms = 1.0;
	float dbg_al = 0.0;
	float e = max(abs(P.x), abs(P.y));
	// 1 宏观反照率 M 与数据分辨率 r：由粗到细
	vec3 cur = base_color; float res = data_res.x*4.0;
	float w;
	w = region(e, half_size.x, 0.08); cur = mix(cur, texture(albedo_ctx, map_uv(P, half_size.x)).rgb, w); res = mix(res, data_res.x, w);
	w = region(e, half_size.y, 0.08); cur = mix(cur, texture(albedo_hirise, map_uv(P, half_size.y)).rgb, w); res = mix(res, data_res.y, w);
	vec4 tm = texture(albedo_mid, map_uv(P, half_size.z));
	w = region(e, half_size.z, 0.08)*tm.a; cur = mix(cur, tm.rgb, w); res = mix(res, data_res.z, w);
	vec4 tn = texture(albedo_near, map_uv(P, half_size.w));
	w = region(e, half_size.w, 0.08)*tn.a; cur = mix(cur, tn.rgb, w); res = mix(res, data_res.w, w);
	// 1b 细层：数据分辨率逐纹素。UV 与导数在分支外算（分支里的隐式导数未定义），分支里 textureGrad。
	//    细坡度也在这里取（只留 2 个分量活到第 10 步）：UV 和导数一直活到法线那步时寄存器多占，全场景 +0.3–0.45 ms
	float wf = 0.0; vec2 fs = vec2(0.0);
	{
		vec4 pr = fine_patch_rect;
		vec2 fuv = map_uv(P, max(fine_half, 1.0)), fdx = dFdx(fuv), fdy = dFdy(fuv);
		vec2 puv = vec2((P.x - pr.x)/max(pr.z - pr.x, 1e-3), (pr.w - P.y)/max(pr.w - pr.y, 1e-3)), pdx = dFdx(puv), pdy = dFdy(puv);
		if (fine_half > 0.0 && e < fine_half) {
			vec4 tf = textureGrad(fine_alb, fuv, fdx, fdy);
			wf = tf.a;
			cur = mix(cur, tf.rgb, wf); res = mix(res, 0.001*exp2(textureGrad(fine_res, fuv, fdx, fdy).r*(255.0/32.0)), wf);
			fs = textureGrad(fine_slope, fuv, fdx, fdy).rg*wf;                 // 片元细坡度（按足迹淡出在第 10 步乘）
			if (P.x > pr.x && P.x < pr.z && P.y > pr.y && P.y < pr.w) {
				vec4 tp = textureGrad(fine_patch, puv, pdx, pdy);
				cur = mix(cur, tp.rgb, tp.a); res = mix(res, fine_patch_res, tp.a); wf = max(wf, tp.a);
			}
		}
	}
#ifdef MAT_OLD
	// 2 地类权重：中景图四通道全 0（没数据）处用 HiRISE 的
	vec4 km = texture(class_mid, map_uv(P, class_half.x));
	vec4 kh = texture(class_hirise, map_uv(P, class_half.y));
	float wm = region(e, class_half.x, 0.15)*clamp((km.r + km.g + km.b + km.a)*2.0, 0.0, 1.0);
	vec4 W = mix(mix(vec4(0.35, 0.35, 0.2, 0.1), kh, region(e, class_half.y, 0.08)), km, wm);
#endif
	// 3 频段门控
	float d = length(VERTEX);
	float fp = d*pixel_angle;
	float g_meso = clamp(log2(2.0*res/0.04)/log2(0.5/0.04), 0.0, 1.0);   // 数据只分辨 ≥ 2r（奈奎斯特）：HiRISE r=0.25 → 1，近层 r≤0.02 → 0
	float g_micro = clamp(1.0 - log2(max(fp/0.001, 1.0))/3.0, 0.0, 1.0);
	g_micro *= mix(1.0, clamp(log2(res/0.001)/log2(10.0), 0.0, 1.0), wf);   // 细层：数据已有 ≥ 2r 的起伏，微观图块（0.6 mm–4 cm）按 r 减幅（r = 1 cm 不减、2 mm 剩 0.3）
	// 法线预通道（只给 SSAO / SDFGI 等用）：跳过细节高度和凹凸，只留宏观法线。颜色 pass 里 IN_NORMAL_PREPASS 是编译期 false
	bool cheap = false;
#ifdef HAS_IN_DEPTH_PREPASS
	cheap = IN_NORMAL_PREPASS && prepass_cheap == 1;
#endif
#ifdef MAT_OLD
	float nmask = clamp((fbm_noise(P*1.3) - 0.5)*6.0 + 0.5, 0.0, 1.0);
	// 4–6 每类细节，按高度混合
	vec3 alb[4]; float hk[4];
	for (int k = 0; k < 4; k++) {
		vec3 a_k = vec3(1.0); float h_k = 0.0;
		vec2 ua_me = vec2(P.x, -P.y)/meso_size[k], ub_me = rot_uv(P, meso_size[k]);
		vec2 ua_mi = vec2(P.x, -P.y)/micro_size[k], ub_mi = rot_uv(P, micro_size[k]);
		if (!cheap && g_meso > 0.0 && perf_dbg != 1) {
			vec3 Ad = meso_gain[k]*mix(texture(meso_alb[k], ua_me).rgb, texture(meso_alb[k], ub_me).rgb, nmask);
			a_k = mix(a_k, Ad, g_meso);
			h_k += g_meso*mix(texture(meso_h[k], ua_me).r, texture(meso_h[k], ub_me).r, nmask);
		}
		if (!cheap && g_micro > 0.0 && perf_dbg != 1) {
			vec3 Ad = micro_gain[k]*mix(texture(micro_alb[k], ua_mi).rgb, texture(micro_alb[k], ub_mi).rgb, nmask);
			a_k = mix(a_k, a_k*Ad, g_micro);
			h_k += g_micro*mix(texture(micro_h[k], ua_mi).r, texture(micro_h[k], ub_mi).r, nmask);
		}
		alb[k] = a_k; hk[k] = h_k;
	}
	float hb[4]; float tot = 0.0;
	float hmax = max(max(hk[0], hk[1]), max(hk[2], hk[3]));      // 减最大值防溢出（比例不变）
	for (int k = 0; k < 4; k++) { hb[k] = (W[k] + 1e-4)*exp((hk[k] - hmax)/0.004); tot += hb[k]; }
	vec3 det = vec3(0.0); float hsum = 0.0;
	for (int k = 0; k < 4; k++) { float wk = hb[k]/tot; det += wk*alb[k]; hsum += wk*hk[k]; }
	vec3 albedo = cur*det;
	const float rough = 0.8;
#else
	// 4–7 材质（材质.gdshaderinc）：控制图前 k 种 × hex 平铺 × 按高度混合 → 细节反照率、导数图法线坡度 mg、粗糙度、积尘
	vec3 albedo = cur; vec2 mg = vec2(0.0); float hsum = 0.0; float rough = 0.8; vec3 mdbg = vec3(0.0); float mdust = 0.0;
	{
		vec2 dPx = dFdx(P.xy), dPy = dFdy(P.xy);                  // 分支外求导
		if (!cheap && perf_dbg != 1) {
			vec2 xz = vec2(P.x, -P.y);
			vec3 det; bool mcd = false;
#ifdef MAT_CACHE
			mcd = mc_frag(P, dPx, dPy, fp, g_micro, FRAGCOORD.xy, det, mg, rough);   // 远处读缓存（积尘色已烘进 det，mdust 保持 0）；近处 false → 实时
#endif
			if (!mcd) {
				float ny = normalize((INV_VIEW_MATRIX*vec4(NORMAL, 0.0)).xyz).y;
				float lee = mat_lee.z > 0.0 ? mat_lee.z*(1.0 - hz_rock_vis(xz + mat_lee.xy)) : 0.0;   // 石块背风积尘：石遮图往上风偏
				float mr = 0.0;                                       // 宏观残差：HiRISE 反照率 ~8 m 低频（lod 5）对当前宏观反照率
				float wh = region(e, half_size.y, 0.08);
				if (wh > 0.0) mr = wh*clamp(log(max(dot(cur, LUM_W), 1e-3)/max(dot(textureLod(albedo_hirise, map_uv(P, half_size.y), 5.0).rgb, LUM_W), 1e-3)), -0.5, 0.5);
				mat_frag(P, dPx, dPy, fp, g_meso, g_micro, ny, lee, mr, det, mg, rough, mdust, mdbg);
			}
			albedo = cur*det*mix(vec3(1.0), mat_dust.rgb, mdust*g_meso);   // 积尘色只在数据分辨不出处加（Navcam 区照片里已有）
		}
	}
#endif
	if (!cheap) albedo *= geo_rfield_alb(vec2(P.x, -P.y), fp);   // 沙纹反照率条纹（地貌.gdshaderinc；幅度 geo_rf_alb，0 = 关）
	v_rough = rough;
	// 8 车辙：压下去的深度并进凹凸高度，压实的细土略暗
	if (!cheap && track_time >= 0.0 && P.x > track_rect.x && P.x < track_rect.z && P.y > track_rect.y && P.y < track_rect.w) {
		vec2 tuv = vec2((P.x - track_rect.x)/(track_rect.z - track_rect.x), (track_rect.w - P.y)/(track_rect.w - track_rect.y));
		vec2 tr = texture(track_tex, tuv).rg;
		float on = step(tr.g, track_time)*step(1e-5, tr.r);
		hsum -= on*tr.r;
		albedo *= mix(1.0, 0.9, on*clamp(tr.r/0.006, 0.0, 1.0));
	}
	// 15 尘卷风痕迹
	if (dd_rect.z > dd_rect.x && P.x > dd_rect.x && P.x < dd_rect.z && P.y > dd_rect.y && P.y < dd_rect.w) {
		vec2 duv = vec2((P.x - dd_rect.x)/(dd_rect.z - dd_rect.x), (dd_rect.w - P.y)/(dd_rect.w - dd_rect.y));
		albedo *= 1.0 - dd_gain*texture(dd_tex, duv).r;
	}
	// 10 CDLOD：逐像素从高度层取法线（数据层级按像素足迹选，不细于一个像素，远处不闪）
	if (clip && perf_dbg != 3) {
		vec2 xz = vec2(P.x, -P.y);
		float kfp = max(log2(max(fp, 1e-6)/hlv_info.x), 0.0);
		vec3 n0 = hl_normal(xz, hl_level(xz, kfp));
#ifdef MAT_CACHE
		v_ms = mc_hzv(xz, vec2(dFdx(P.x), -dFdx(P.y)), vec2(dFdy(P.x), -dFdy(P.y)), normalize(n0/n0.y - vec3(v_geo.y, 0.0, v_geo.z)), dbg_al);   // 微观自阴影（颗粒感 §2）：宏观平面 = 高度层 + 印章
#endif
		if (geo_dbg != 1) {
			vec3 gv = geo_frag == 1 ? geo_at2(xz, 2.0*fp, v_geo.x, 2) : vec3(0.0);   // 14 --地貌片元=1：小特征逐像素（+0.9 ms：着色器变重、整体并发掉）
			fs *= 1.0 - smoothstep(fine_slope_fade.x, fine_slope_fade.y, fp);   // 1b 细层的片元细坡度（Godot z = −N → ∂h/∂z = −∂h/∂N）
#ifdef MAT_OLD
			n0 = normalize(n0/n0.y - vec3(gv.y + v_geo.y + fs.x, 0.0, gv.z + v_geo.z - fs.y));
#else
			n0 = normalize(n0/n0.y - vec3(gv.y + v_geo.y + fs.x + mg.x, 0.0, gv.z + v_geo.z - fs.y - mg.y));   // 材质导数图坡度（surface gradient）
#endif
		}
		NORMAL = normalize((VIEW_MATRIX*vec4(n0, 0.0)).xyz);
	}
#ifdef MAT_OLD
	// 7 凹凸（Blender Bump 节点：强度 1、距离 1，高度单位米）
	if (!cheap) NORMAL = bump_normal(VERTEX, normalize(NORMAL), hsum);
#else
	if (!cheap && !(clip && perf_dbg != 3 && geo_dbg != 1)) {     // 老环网格 / 诊断：材质坡度直接加到几何法线上
		vec3 nw = normalize((INV_VIEW_MATRIX*vec4(NORMAL, 0.0)).xyz);
		nw = normalize(nw/max(nw.y, 0.05) - vec3(mg.x, 0.0, -mg.y));
		NORMAL = normalize((VIEW_MATRIX*vec4(nw, 0.0)).xyz);
	}
	if (!cheap && track_time >= 0.0) NORMAL = bump_normal(VERTEX, normalize(NORMAL), hsum);   // 7 凹凸：只剩车辙
#endif
	// 9 空气透视
	vec3 wpos = (INV_VIEW_MATRIX*vec4(VERTEX, 1.0)).xyz;
	vec3 dir = wpos - CAMERA_POSITION_WORLD;
	float T = 1.0; vec3 Lap = vec3(0.0);
	if (perf_dbg != 2) aerial(dir, d, T, Lap);
	if (perf_dbg == 4) albedo = vec3(0.3);                        // 诊断：常数反照率，只看光照
	ALBEDO = albedo*T;
	if (perf_dbg == 5) { ALBEDO = vec3(0.0); EMISSION = albedo*40.0; }   // 诊断：只看反照率（不打光）
	if (geo_dbg >= 2) {                                           // 诊断：2 印章高度（灰 0.5 = 0，±10 cm 满）、3 地类权重 RGB、4 dem 分辨率
		vec2 xz = vec2(P.x, -P.y);
		if (geo_dbg == 2) ALBEDO = vec3(clamp(0.5 + 5.0*geo_at(xz, 0.0).x, 0.0, 1.0));
		if (geo_dbg == 3) ALBEDO = geo_W(xz).rgb;
		if (geo_dbg == 4) ALBEDO = vec3((geo_dem_l(xz, 0.0) + 6.0)/11.0);
		EMISSION = vec3(0.0);
	}
	if (lod_dbg == 2 && clip) {
		vec3 lc = 0.5 + 0.5*cos(6.2832*(v_lod*0.17 + vec3(0.0, 0.33, 0.67)));
		vec2 gw = fwidth(v_g); vec2 eg = min(fract(v_g/64.0)*64.0, 64.0 - fract(v_g/64.0)*64.0)/max(gw, 1e-4);
		ALBEDO = mix(lc*0.3, vec3(0.0), step(min(eg.x, eg.y), 1.5)); EMISSION = vec3(0.0);
	}
	EMISSION = (1.0 - T)*Lap;
	if (perf_dbg == 5) { ALBEDO = vec3(0.0); EMISSION = albedo*2.0; }                    // 诊断 5（修）：只看反照率（不打光；上面那条被这一行之前的 EMISSION 覆盖了）
	if (geo_dbg == 2) { EMISSION = vec3(clamp(0.5 + 5.0*geo_at(vec2(P.x, -P.y), 0.0).x, 0.0, 1.0))*40.0; ALBEDO = vec3(0.0); }   // 不打光，直接看高度
#ifndef MAT_OLD
	if (mat_dbg == 1) { ALBEDO = vec3(0.0); EMISSION = mdbg*40.0; }   // 诊断 --地面材质诊断=1：材质权重上色、2：积尘（不打光）
	if (mat_dbg == 2) { ALBEDO = vec3(0.0); EMISSION = vec3(mdust)*40.0; }
#endif
#ifdef MAT_CACHE
	if (mc_info2.w > 1.5 && mc_info2.w < 2.5) { ALBEDO = vec3(0.0); EMISSION = vec3(v_ms)*40.0; }          // 诊断 --缓存诊断=2：微观自阴影可见度（不打光）
	if (mc_info2.w > 2.5 && mc_info2.w < 3.5) { ALBEDO = vec3(0.0); EMISSION = vec3(dbg_al*6.0)*40.0; }   // 3：地平线仰角（1/6 rad 满）
#endif
	ROUGHNESS = 1.0; METALLIC = 0.0; SPECULAR = 0.0;
	vec3 ea = eon_ambient3(NORMAL, VIEW, albedo, rough);
	AO = dot(ea, LUM_W); v_ambc = ea/AO; ALBEDO *= v_ambc;
	v_sun = hz_sun_vis(vec2(P.x, -P.y));
	if (perf_dbg == 5) { ALBEDO = vec3(0.0); EMISSION = albedo*2.0; }                    // 诊断 5（修，同 grain）：只看反照率（不打光；前面的 EMISSION 被后面覆盖）
	if (hz_sun_on == 2) { ALBEDO = vec3(0.0); EMISSION = vec3(v_sun*0.5); }   // 诊断 --远影=诊断：白 = 照得到、黑 = 在地影里（不打光）
	float rv = hz_rock_vis(vec2(P.x, -P.y));                       // G4 石块遮地面
	if (hz_on == 1) {                                             // 地平线 GI 替代天空环境光；石块挡掉的那份换成石块侧面的辐亮度
		vec3 irr = hz_irradiance(vec3(P.x, P.z, -P.y), normalize((INV_VIEW_MATRIX*vec4(NORMAL, 0.0)).xyz));
		IRRADIANCE = vec4(irr*rv + hz_Lg*hz_rk_L*(1.0 - rv), 1.0);
	} else AO *= rv;
}

void light() {
	float att = LIGHT_IS_DIRECTIONAL ? min(min(ATTENUATION, v_sun), v_ms) : ATTENUATION;   // G2：CSM 和地形地平线取较暗者（两者都含地形自身的影，不叠乘）
#ifdef MAT_OLD
	DIFFUSE_LIGHT += oren_nayar(NORMAL, LIGHT, VIEW, ALBEDO/v_ambc, 0.8)*LIGHT_COLOR*att/v_ambc;   // 去掉 fragment 里乘进 ALBEDO 的逐通道环境修正
#else
	DIFFUSE_LIGHT += oren_nayar(NORMAL, LIGHT, VIEW, ALBEDO/v_ambc, v_rough)*LIGHT_COLOR*att/v_ambc;   // 逐材质粗糙度（v_rough）
#endif
}
