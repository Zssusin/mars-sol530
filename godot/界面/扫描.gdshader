// 扫描脉冲（界面 3 重做；docs/界面/UI体系.md §4.8、「扫描脉冲（界面 3）」一节）：全屏后处理，深度重建世界坐标，不碰地形 / 材质着色器。
// 世界基本不变：一道细而亮的环从车身向外扩（球面距离，所以会爬上石头），环后面一小段（约 0.5–1 s）
//   世界坐标的点阵在表面上依次亮起（地、石、崖都有；点在环到时「炸」大一下再缩回，每点有个小随机延迟）；
//   环刚过的石头 / 起伏边缘有一道很短的边缘高光；坡度到注意 / 警告线的表面，点换成琥珀 / 红（地形的反馈，同 令.色 的语义）。
// 车身（罗盘环以上、半径内）不参与。没有平涂、没有掠射边缘光。
// 输出 = blend_mix：ALBEDO 是颜色、ALPHA 是覆盖，没有覆盖的地方原样不动。亮度 = 色 × 强 × 曝光补偿（曝光变了亮度不变，同 界面/地面.gd）。
// 空闲时节点 visible = false → 这个着色器不跑，深度拷贝也不做。
shader_type spatial;
render_mode unshaded, blend_mix, depth_test_disabled, cull_disabled, skip_vertex_transform, shadows_disabled, fog_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;

uniform vec3 u_origin = vec3(0.0);
uniform vec4 u_rover = vec4(0.0, 0.0, 0.0, 2.0);   // xyz = 车下地面点，w = 排除半径（米）
uniform float u_speed = 40.0;       // 环此刻的速度 m/s（CPU 算；age ≈ 环后距离 / 速度，省掉每像素一个 pow）
uniform float u_t = 0.0;             // 脉冲开始后的秒数
uniform float u_radius = 60.0;       // m
uniform float u_ring_t = 1.5;        // 环扫完半径用的时间
uniform float u_total = 2.5;         // 世界效果总时间
uniform float u_pitch = 0.5;         // 点阵间距 m
uniform float u_dot_r = 0.035;       // 点半径 m
uniform float u_life = 0.30;         // 点亮度衰减时间常数 s
uniform float u_trail = 1.6;         // 环后拖光长度 m（近处；远处按像素放大）
uniform vec3 u_col_core = vec3(1.0); // 环芯（已乘 强 和 曝光补偿）
uniform vec3 u_col_glow = vec3(0.5, 0.6, 1.0);
uniform vec3 u_col_out = vec3(0.04, 0.24, 0.57);   // 环的细描边（NASA 蓝，不乘强：深色边把亮芯和任何底色分开）
uniform vec3 u_col_dot = vec3(1.0);
uniform vec3 u_col_edge = vec3(1.0);
uniform vec3 u_col_warn = vec3(1.0, 0.7, 0.0);
uniform vec3 u_col_red = vec3(1.0, 0.2, 0.1);
uniform vec2 u_slope_cos = vec2(0.94, 0.866);   // 注意 / 警告坡度的 cos（20° / 30°）
uniform float k_ring = 1.0;
uniform float k_dot = 0.9;
uniform float k_edge = 0.8;
uniform float th_depth = 0.06;       // 深度二阶差分（相对）超过这个才算边
uniform int dbg = 0;                 // 调试：1 环 2 点阵 3 边线（--扫描调试=N）

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	float d0 = texture(depth_tex, SCREEN_UV).x;
	vec4 v4 = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, d0, 1.0);
	vec3 vpos = v4.xyz / v4.w;
	vec3 w = (INV_VIEW_MATRIX * vec4(vpos, 1.0)).xyz;
	vec3 wn = normalize(cross(dFdx(w), dFdy(w)));                        // 屏幕导数法线（放在所有分支之前，导数才可靠）
	if (d0 <= 0.0 || dbg == 9) discard;                                  // 天空（反向 Z）；dbg 9 = 只量固定开销
	float dist = length(w - u_origin);
	float x = clamp(u_t / u_ring_t, 0.0, 1.0);
	float R = u_radius * (1.0 - pow(1.0 - x, 1.5));                      // 环半径（ease-out，末速不到 0，环不会停在半径上）
	if (dist > R + 1.0) discard;                                         // 环还没到
	float age = clamp(-(dist - R) / max(u_speed, 4.0), -1.0, u_t);         // 这个点被环扫过多久了（环后距离 / 环速，近似）
	float fade_end = 1.0 - smoothstep(u_total - 0.4, u_total, u_t);
	float fade_far = 1.0 - smoothstep(0.75, 1.0, dist / u_radius);       // 靠近最大半径时变淡
	// 车身不参与：车下地面点的水平半径内、地面以上 0.15 m 起（地面和车下的地还照常）
	float hd = length(w.xz - u_rover.xz);
	float on_rover = (1.0 - smoothstep(u_rover.w, u_rover.w + 0.3, hd)) * smoothstep(u_rover.y + 0.12, u_rover.y + 0.3, w.y);
	float live = (1.0 - on_rover) * fade_end * fade_far;
	if (live < 0.003) discard;
	float dd0 = dist - R;
	if (age > 1.15 && dd0 < -u_trail * 8.0) discard;                      // 环过去很久、点也灭了：什么都不画

	float px_world = max(abs(vpos.z), 0.1) * 2.0 / (abs(PROJECTION_MATRIX[1][1]) * VIEWPORT_SIZE.y);   // 这个深度处一个像素 = 多少米
	vec3 col = vec3(0.0);
	float a = 0.0;

	// 环：芯 = 约 2.5 像素的亮线（近处 0.03 m 下限）；后面一小段拖光（向车的方向，约 1.6 m 或 40 像素）
	float dd = dist - R;
	float pw = max(0.04, px_world * 2.2);
	float core = 1.0 - smoothstep(pw * 0.6, pw * 1.6, abs(dd));
	float tl = max(u_trail, px_world * 11.0);
	float trail = (dd < 0.0 ? exp(dd / tl) : exp(-dd / (pw * 3.0))) * 0.32;
	if (dbg == 0 || dbg == 1) {
		float ra = clamp(core * k_ring, 0.0, 1.0);
		float ga = clamp(trail * k_ring, 0.0, 1.0) * (1.0 - ra);
		float oa = (1.0 - smoothstep(pw * 2.0, pw * 3.0, abs(dd))) * 0.9 * k_ring * (1.0 - ra) * (1.0 - ga * 0.5);
		col += u_col_core * ra + u_col_glow * ga + u_col_out * oa;
		a += ra + ga + oa;
	}

	if (age > 0.0 && age < 1.2) {
		// 点阵：世界坐标，按法线主轴选面；一格不到 ~7 个像素就淡掉（防摩尔纹）
		float aa = px_world * 1.2 / u_pitch;
		if (aa < 0.14) {
			vec3 an = abs(wn);
			vec2 q = (an.y >= an.x && an.y >= an.z) ? w.xz : ((an.x >= an.z) ? w.yz : w.xy);
			vec2 cell = floor(q / u_pitch);
			vec2 g = fract(q / u_pitch) - 0.5;
			float delay = hash13(vec3(cell, an.y >= an.x ? 1.0 : 2.0)) * 0.14;
			float ad = age - delay;
			if (ad > 0.0) {
				float env = exp(-ad / u_life) * smoothstep(0.0, 0.03, ad);
				float pop = 1.0 + 0.9 * exp(-ad / 0.07);                 // 到的一瞬间点炸大，再缩回
				float r_dot = max(u_dot_r * pop, px_world * 2.3) / u_pitch;
				float dv = clamp((r_dot + aa * 0.5 - length(g)) / (aa), 0.0, 1.0);
				float vis = 1.0 - smoothstep(0.08, 0.14, aa);
				float slope = abs(wn.y);                                   // = cos(坡度)
				vec3 dc = slope <= u_slope_cos.y ? u_col_red : (slope <= u_slope_cos.x ? u_col_warn : u_col_dot);
				float da = clamp(dv * vis * env * k_dot, 0.0, 1.0);
				if (dbg == 0 || dbg == 2) { col += dc * da * (1.0 - a); a += da * (1.0 - a); }
			}
		}
		// 边缘高光：深度二阶差分（石头边、起伏边；平地上为 0），只在环刚过的 ~0.45 s
		if (age < 0.7) {
			vec2 px = 1.0 / VIEWPORT_SIZE;
			float dr = texture(depth_tex, SCREEN_UV + vec2(px.x, 0.0)).x;
			float dl = texture(depth_tex, SCREEN_UV - vec2(px.x, 0.0)).x;
			float du = texture(depth_tex, SCREEN_UV + vec2(0.0, px.y)).x;
			float db = texture(depth_tex, SCREEN_UV - vec2(0.0, px.y)).x;
			float lap = abs(dr + dl - 2.0 * d0) + abs(du + db - 2.0 * d0);
			float edge = smoothstep(th_depth, th_depth * 2.5, lap / max(d0, 1e-5));
			float ea = edge * exp(-age / 0.16) * smoothstep(0.0, 0.02, age) * k_edge;
			if (dbg == 0 || dbg == 3) { ea = clamp(ea, 0.0, 1.0); col += u_col_edge * ea * (1.0 - a); a += ea * (1.0 - a); }
		}
	}
	a *= live;
	if (a < 0.004) discard;
	ALBEDO = col / max(a / live, 0.004);                                // col 是按未乘 live 的覆盖加权的，除回去
	ALPHA = clamp(a, 0.0, 1.0);
}
