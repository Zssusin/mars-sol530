// 毅力号材质（实景地形系统.md §17）：取代 glb 导入的 StandardMaterial3D（透明的玻璃件除外），一个着色器、每个材质一组参数。
// 底子照搬 StandardMaterial3D：基色贴图 × 颜色、法线贴图、金属度 / 粗糙度贴图、第二套 UV 上的车 AO（只压环境光）。
// 加三样：① 微起伏法线 + 粗糙度起伏（物体空间三向投影，平铺 detail_m 米；brush > 1 沿一个轴拉成机加工丝纹）；
//         ② 按物理位置落尘（第二轮）：朝上的面一层均匀薄膜 × 低对比大尺度起伏（物体空间值噪声，±dust_var，不平铺）
//            + 凹角/缝隙按车 AO 加厚 + 竖直面少量；尘是电介质，盖住的地方金属度→0、粗糙度→0.95；
//            dust_base = 只按凹处挂的尘（车轮：胎纹槽、内圈），不再整圈刷一层；
//         ③ 镜面遮蔽：车 AO 图换算成 Lagarde 2014 的 specular occlusion，压凹处的环境反射（Godot 自带的按环境光亮度估，在本项目的光照量级下基本不起作用）。
// 标识保护：guard = 1 的材质（铭牌、标识贴图）不落尘、不加起伏；有贴图的材质，贴图里高饱和的像素（红 JPL、蓝 NASA、国旗）按饱和度自动免尘。
// 第三轮（§17.1，PBR 细节）：
//   ④ 法线贴图自己算切线框架（Schüler 2013，屏幕导数）：glb 没有切线、运行时导入也不生成，Godot 只好按法线随便补一个切线，
//      原来的法线贴图凹凸方向是乱的（同一条缝一边亮一边暗的方向随面片转）；
//   ⑤ 各向异性高光（拉丝 / 车削金属）：TANGENT 设成垂直丝纹的方向，Godot 的各向异性 GGX 沿它拉长高光；
//   ⑥ 透明涂层（clearcoat）：阳极氧化膜、镀铝聚酰亚胺膜这类「电介质薄膜盖在金属上」的分层材质。
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

uniform vec4 albedo_col : source_color = vec4(1.0);
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, hint_default_white;
uniform float albedo_gain = 1.0;                                   // 线性增益（车身图集按参考提亮）
uniform float sat = 1.0;                                           // 贴图饱和度倍率（HGA 面：图集里是亮黄，照片是米金）
uniform float auto_guard = 1.0;                                    // 贴图高饱和像素自动免尘（0 = 关：HGA 黄面不是标识）
uniform float metallic = 0.0;
uniform float roughness = 0.5;
uniform float specular = 0.5;
uniform bool use_mr = false;                                       // glTF metallicRoughness：G = 粗糙度、B = 金属度（只有 RTG 冷却管有）
uniform sampler2D mr_tex : hint_default_white, filter_linear_mipmap;
uniform bool use_normal = false;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic;
uniform float normal_scale = 1.0;
uniform bool use_ao = false;
uniform sampler2D ao_tex : hint_default_white, filter_linear_mipmap;
uniform sampler2D detail_tex : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;   // rover_detail.png（68_车细节.py）
uniform float detail_m = 0.12;                                     // 细节纹理平铺一周的米数
uniform float micro_n = 0.0;                                       // 微法线强度（斜率）
uniform float brush = 1.0;                                         // 拉丝：沿物体 x 轴把纹理拉长的倍数
uniform float rough_var = 0.0;                                     // 粗糙度起伏幅度（±）
uniform float guard = 0.0;                                         // 1 = 标识，免尘、免起伏
uniform float dust_k = 1.0;                                        // 本材质挂尘倍率
uniform float dust_base = 0.0;                                     // 不看朝向的底尘（车轮：在地上滚，整圈都挂尘）
uniform float dust = 0.35;                                         // 全车尘量（--车尘）
uniform vec3 dust_col = vec3(0.38, 0.22, 0.09);                    // 线性；厚层空降尘，Kinch 2015 单次散射反照率 → Hapke 近似（参考.md §2.1）
uniform float so_on = 1.0;                                         // 镜面遮蔽开关（诊断）
uniform float wheel_r = 0.0;                                      // 车轮：胎齿顶半径（m，以轮心为原点、轮轴 = 物体 x）；> 0 时凹度按半径算（槽底、齿根、内圈），不用车 AO
uniform float wheel_in_ao = 1.0;                                   // 车轮内圈的几何 AO（轮内AO）
uniform float wheel_groove_ao = 0.0;                               // 胎齿间槽底的 AO 压低量（槽AO）
uniform int dbg = 0;                                               // 诊断（--材质调试）：1 = 车 AO，2 = 尘覆盖率，3 = 远近淡出 far_
uniform float dust_var = 0.18;                                     // 平面尘膜的大尺度起伏幅度（±，相对）
uniform float dust_film = 1.9;                                     // 水平面薄膜：覆盖率 = dust × dust_film（sol 530：0.35 × 1.9 ≈ 0.67）
uniform float dust_crev = 1.2;                                     // 凹角加厚：dust × dust_crev × 凹度
uniform float dust_side = 0.15;                                    // 竖直面：dust × dust_side
uniform float grain_k = 0.5;                                       // 砂粒深度
uniform bool cf_normal = true;                                     // 法线贴图用屏幕导数切线框架（false = 旧做法，交给 Godot 的 NORMAL_MAP + 默认切线；对比用）
uniform float aniso = 0.0;                                         // 各向异性强度（0–1）
uniform int aniso_mode = 0;                                        // 丝向：0 = 沿物体 x 直纹；1 = 绕物体 x 轴的车削圆纹（轮毂）；2 = 物体 yz 面内径向（轮辐）
uniform float clearcoat = 0.0;                                     // 透明涂层强度（F0 固定 0.04）
uniform float clearcoat_rough = 0.2;                               // 透明涂层粗糙度

varying vec3 op;                                                   // 物体空间位置（按模型矩阵的缩放换成米）
varying vec3 on;                                                   // 物体空间法线

void vertex() {
	vec3 sc = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	op = VERTEX*sc; on = NORMAL;
}

// 值噪声（物体空间，不平铺）：大尺度尘膜起伏
float h21(vec2 p) { p = fract(p*vec2(0.1031, 0.1030)); p += dot(p, p.yx + 33.33); return fract((p.x + p.y)*p.x); }
float vnoise(vec2 p) {
	vec2 i = floor(p), f = fract(p); f = f*f*(3.0 - 2.0*f);
	return mix(mix(h21(i), h21(i + vec2(1.0, 0.0)), f.x), mix(h21(i + vec2(0.0, 1.0)), h21(i + vec2(1.0, 1.0)), f.x), f.y);
}

// 三向投影的切线空间法线混合：Golus 2017「whiteout」做法（Normal Mapping for a Triplanar Shader）
vec3 tri_normal(vec3 p, vec3 n, float s, out float rv, out float grain) {
	vec3 w = pow(abs(n), vec3(4.0)); w /= (w.x + w.y + w.z);
	vec2 bx = vec2(1.0/brush, 1.0);                                  // 拉丝：物体 x 方向拉长（yz 面无 x，那一面不拉）
	vec4 tx = texture(detail_tex, p.zy/s);
	vec4 ty = texture(detail_tex, p.xz*bx/s);
	vec4 tz = texture(detail_tex, p.xy*bx/s);
	rv = tx.b*w.x + ty.b*w.y + tz.b*w.z;
	grain = tx.a*w.x + ty.a*w.y + tz.a*w.z;
	vec2 nx = tx.rg*2.0 - 1.0, ny = ty.rg*2.0 - 1.0, nz = tz.rg*2.0 - 1.0;
	vec3 sg = sign(n);
	vec3 ax = vec3(n.x, nx.y + n.y, nx.x + n.z);                   // whiteout：切线空间 xy 加到对应的世界轴上
	vec3 ay = vec3(ny.x + n.x, n.y, ny.y + n.z);
	vec3 az = vec3(nz.x + n.x, nz.y + n.y, n.z);
	return normalize(ax*w.x + ay*w.y + az*w.z);
}

void fragment() {
	vec4 at = texture(albedo_tex, UV);
	vec3 alb = albedo_col.rgb*at.rgb*albedo_gain;
	alb = mix(vec3(dot(alb, vec3(0.2126, 0.7152, 0.0722))), alb, sat);
	float met = metallic, rgh = roughness;
	if (use_mr) { vec4 mr = texture(mr_tex, UV); rgh *= mr.g; met *= mr.b; }
	float ao = use_ao ? texture(ao_tex, UV2).r : 1.0;
	// 标识保护：贴图高饱和像素（JPL 红、NASA 蓝）
	float mx = max(at.r, max(at.g, at.b)), mn = min(at.r, min(at.g, at.b));
	float g = max(guard, auto_guard*smoothstep(0.35, 0.6, (mx - mn)/max(mx, 1e-3))*step(0.15, mx));
	// 微起伏
	float rv = 0.5, grain = 0.0;
	vec3 n_obj = normalize(on);
	vec3 nd = tri_normal(op, n_obj, detail_m, rv, grain);
	// 落尘：水平面一层均匀薄膜（低对比大尺度起伏）+ 凹角加厚 + 竖直面一点；车轮之类只按凹处挂（dust_base）
	vec3 wn = normalize((INV_VIEW_MATRIX*vec4(NORMAL, 0.0)).xyz);
	float flat_ = smoothstep(0.35, 0.85, wn.y);                       // 水平面（甲板、顶板）
	float cav = smoothstep(0.08, 0.5, 1.0 - ao);                      // 凹度（车 AO）
	if (wheel_r > 0.0) {                                              // 车轮的 AO 图集坏（胎面一半的面采到图集空白处），凹度按几何算
		float r = length(op.yz); float nr = dot(n_obj, vec3(0.0, op.y, op.z)/max(r, 1e-4));
		float ang = atan(op.z, op.y);
		float patch_ = smoothstep(0.55, 0.85, vnoise(vec2(ang*9.0, op.x*16.0) + 5.3));               // 一槽一槽地塞（照片：有的槽满、有的空）
		float groove = smoothstep(wheel_r - 0.0115, wheel_r - 0.0165, r)*smoothstep(-0.2, 0.3, nr)*(0.05 + 0.95*patch_);   // 外皮 r≈0.245–0.25 + 齿根；齿面、齿顶干净
		float inner = smoothstep(0.0, -0.5, nr)*smoothstep(wheel_r - 0.02, wheel_r - 0.035, r);      // 内圈（r≈0.231，朝里）
		cav = max(groove, 0.5*inner);
		// 几何 AO（§17.1）：轮圈内面朝着轮轴，看到的大半是轮子自己、车身和地面，原来按 AO = 1 收满天光，阴影里的轮内比照片亮一截；
		// 胎齿之间的槽也压一点。只压环境光和环境反射（AO_LIGHT_AFFECT = 0），太阳直射不变
		float g_groove = smoothstep(wheel_r - 0.0115, wheel_r - 0.0165, r)*smoothstep(-0.2, 0.3, nr);
		ao = min(ao, mix(1.0, wheel_in_ao, inner))*(1.0 - wheel_groove_ao*g_groove);
	}
	vec2 q = op.xz + vec2(0.31*op.y, -0.27*op.y);                     // 各层高度错开，免得上下两层的花样对齐
	float lf = 0.55*vnoise(q/1.7 + 11.3) + 0.3*vnoise(q/0.55 + 4.1) + 0.15*vnoise(q/0.19 + 7.9);
	float vary = 1.0 + dust_var*(lf - 0.5)*3.0;
	float cov = dust*dust_k*(dust_film*flat_*vary + dust_crev*cav*smoothstep(-0.3, 0.4, wn.y) + dust_side*(1.0 - flat_)) + dust_base*cav*min(dust/0.35, 1.5);   // 底尘跟着全车尘量走（--车尘=0 全干净）
	cov = clamp(cov, 0.0, 0.92)*(1.0 - g);
	// 砂粒：水平积尘面上的零星深色颗粒（照片：甲板上满是车轮带上来的砂粒）；远处淡出，防闪烁
	float fw = length(fwidth(op))/detail_m*512.0;                     // 每像素跨几个细节纹素
	float far_ = smoothstep(8.0, 40.0, fw);                           // 微起伏主波长约 85 纹素：fw 过 8 开始淡、过 40（< 2 像素一个起伏）全淡
	float gr = grain*flat_*smoothstep(6.0, 1.5, fw)*min(dust*2.0, 1.0)*(1.0 - g)*grain_k;   // 砂粒 1–2 纹素大，fw > 6 就会闪
	// 合成
	float mn_k = micro_n*(1.0 - g)*(1.0 - cov)*(1.0 - far_);           // 远处细节小于像素：法线起伏淡出，折进粗糙度（Toksvig 式）
	vec3 n2 = normalize(mix(n_obj, nd, mn_k));
	rgh = sqrt(rgh*rgh + 0.5*micro_n*micro_n*far_*(1.0 - g));
	float fs = FRONT_FACING ? 1.0 : -1.0;
	mat3 o2v = mat3(VIEW_MATRIX)*mat3(MODEL_MATRIX);
	vec3 N0 = normalize(o2v*n_obj)*fs;                                // 几何法线（视空间）
	vec3 Nv = normalize(o2v*n2)*fs;                                    // + 微起伏
	if (use_normal && cf_normal) {
		// 切线框架（Schüler 2013, "Followup: Normal Mapping Without Precomputed Tangents"）：T = ∂P/∂u、B = ∂P/∂v。
		// glTF / Godot 的法线贴图是 OpenGL 约定（绿 = 图上方 = v 减小），所以副切线取 −B（同 Godot SurfaceTool 的 MikkTSpace）
		vec3 dp1 = dFdx(VERTEX), dp2 = dFdy(VERTEX); vec2 du1 = dFdx(UV), du2 = dFdy(UV);
		vec3 dp2p = cross(dp2, N0), dp1p = cross(N0, dp1);
		vec3 T = dp2p*du1.x + dp1p*du2.x, B = dp2p*du1.y + dp1p*du2.y;
		float im = inversesqrt(max(max(dot(T, T), dot(B, B)), 1e-30));
		vec2 nxy = texture(normal_tex, UV).rg*2.0 - 1.0;
		vec3 nt = vec3(nxy, sqrt(max(1.0 - dot(nxy, nxy), 0.0)));
		vec3 Nm = normalize(mix(N0, normalize(T*im*nt.x - B*im*nt.y + N0*nt.z), normal_scale));   // 同 Godot：按深度在几何法线和贴图法线之间插
		Nv = normalize(Nm + (Nv - N0));                               // 微起伏叠在贴图法线上
	}
	NORMAL = Nv;
	if (use_normal && !cf_normal) { NORMAL_MAP = texture(normal_tex, UV).rgb; NORMAL_MAP_DEPTH = normal_scale; }
	// 各向异性：丝纹方向 d（物体空间）→ 视空间、投到切平面；TANGENT = 垂直丝纹（高光沿它拉长：拉丝面的亮带横跨丝纹）
	float an = aniso*(1.0 - g);
	if (an > 0.0) {
		vec3 d = aniso_mode == 1 ? cross(vec3(1.0, 0.0, 0.0), op) : (aniso_mode == 2 ? vec3(0.0, op.y, op.z) : vec3(1.0, 0.0, 0.0));
		vec3 dv = o2v*d; dv -= Nv*dot(dv, Nv);
		float dl = length(dv);
		if (dl > 1e-5) { dv /= dl; BINORMAL = dv; TANGENT = normalize(cross(Nv, dv)); } else { an = 0.0; }
	}
	rgh = clamp(rgh + (rv - 0.5)*2.0*rough_var*(1.0 - g), 0.04, 1.0);
	alb = mix(alb, dust_col, cov)*(1.0 - 0.6*gr);
	met = mix(met, 0.0, cov);
	rgh = mix(rgh, 0.95, cov);
	// 镜面遮蔽（Lagarde & de Rousiers 2014，Moving Frostbite to PBR，式 (59)）
	float nv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float so = clamp(pow(nv + ao, exp2(-16.0*rgh - 1.0)) - 1.0 + ao, 0.0, 1.0);
	so = mix(1.0, so, so_on);
	ALBEDO = alb*mix(1.0, so, met);                                 // 金属：F0 就是基色，乘遮蔽压环境反射（直射在凹处本来多在阴影里）
	METALLIC = met; ROUGHNESS = rgh;
	SPECULAR = specular*so;
	ANISOTROPY = an*(1.0 - cov);
	CLEARCOAT = clearcoat*(1.0 - cov)*(1.0 - g)*so; CLEARCOAT_ROUGHNESS = clearcoat_rough;
	AO = ao; AO_LIGHT_AFFECT = 0.0;
	if (dbg > 0) { ALBEDO = vec3(dbg == 1 ? ao : (dbg == 2 ? cov : (dbg == 3 ? far_ : fract(length(op.yz)*20.0)))); METALLIC = 0.0; ROUGHNESS = 1.0; SPECULAR = 0.0; ANISOTROPY = 0.0; CLEARCOAT = 0.0; }
	if (dbg == 5) { ALBEDO = Nv*0.5 + 0.5; }                         // 视空间法线（核对法线贴图方向）
	if (dbg == 6) { ALBEDO = vec3(1.0); METALLIC = 1.0; ROUGHNESS = 0.05; SPECULAR = 0.5; }   // 镜面球：看反射里是什么（天空 / 探针 / SSR）
}
