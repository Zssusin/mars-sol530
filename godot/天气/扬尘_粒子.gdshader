// 近地扬尘（相机周围 box×box 的一块，世界坐标）：两类粒子 —— 跃移沙流（贴地 0–0.2 m 的细长条）和扬起的尘絮（0.2–1.6 m）。
// 局地风 = 平均风 ×（1 + G·阵风场），阵风场是随风平移的噪声（阵风锋扫过地面）。强度用 Kawamura 1951 的跃移通量形式
// q ∝ U³(1 − (Ut/U)²)(1 + Ut/U)（U ≤ Ut 时为 0），U = Uref 时为 1；U 用 1.5 m 高的风代替摩阻速度（只差一个比例）。
shader_type particles;
uniform vec3 center = vec3(0.0);
uniform float box = 60.0;
uniform vec3 wdir = vec3(-1.0, 0.0, 0.0);   // 风吹向（Godot 水平单位向量）
uniform float U = 4.0;                       // 平均风（m/s，1.5 m 高）
uniform float G = 0.4;                       // 阵风幅度
uniform float Ut = 15.0;                     // 起沙 / 起尘阈值（m/s，1.5 m 高）
uniform float Uref = 22.0;                   // 强度 1 时的风
uniform float a_salt = 0.05;
uniform float a_wisp = 0.03;
uniform sampler2D hm_tex : filter_linear, repeat_disable;
uniform vec4 hm_rect = vec4(-32.0, -32.0, 64.0, 0.0);   // x0, z0, 边长（Godot xz）

float h1(uint n) {
	n = (n << 13u) ^ n; n = n*(n*n*15731u + 789221u) + 1376312589u;
	return float(n & 0x7fffffffu)/2147483647.0;
}
float hash2(vec2 i) { return fract(sin(dot(i, vec2(127.1, 311.7)))*43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p); f = f*f*(3.0 - 2.0*f);
	return mix(mix(hash2(i), hash2(i + vec2(1.0, 0.0)), f.x), mix(hash2(i + vec2(0.0, 1.0)), hash2(i + vec2(1.0, 1.0)), f.x), f.y);
}
float flux(float u) {
	if (u <= Ut) return 0.0;
	float r = Ut/u, rr = Ut/Uref;
	return (u*u*u*(1.0 - r*r)*(1.0 + r))/(Uref*Uref*Uref*(1.0 - rr*rr)*(1.0 + rr));
}
float ground(vec2 xz) { return texture(hm_tex, (xz - hm_rect.xy)/hm_rect.z).r; }

void start() {
	uint s = RANDOM_SEED*5u + INDEX*7919u + NUMBER*104729u;
	CUSTOM = vec4(h1(s), h1(s + 1u), h1(s + 2u), (INDEX % 4u == 0u) ? 1.0 : 0.0);   // w：1 = 尘絮
	vec2 o = (vec2(h1(s + 3u), h1(s + 4u)) - 0.5)*box;
	TRANSFORM = mat4(1.0);
	TRANSFORM[3].xyz = vec3(center.x + o.x, ground(center.xz + o), center.z + o.y);
	VELOCITY = vec3(0.0);
}

void process() {
	vec3 p = TRANSFORM[3].xyz;
	bool wisp = CUSTOM.w > 0.5;
	vec2 adv = p.xz - wdir.xz*U*TIME;                                  // 阵风场：沿风平移的两层噪声（40 m、15 m）
	float g = vnoise(adv/40.0)*0.7 + vnoise(adv/15.0 + 7.3)*0.3;
	float u = U*(1.0 + G*(2.0*g - 1.0));
	float I = flux(u);
	float spd = wisp ? u : 0.5*u;                                      // 跃移颗粒比风慢
	p.xz += wdir.xz*spd*DELTA*(0.8 + 0.4*CUSTOM.x);
	vec2 rel = p.xz - center.xz;                                       // 出了框就绕回另一边
	vec2 wr = mod(rel + 0.5*box, box) - 0.5*box;
	p.xz = center.xz + wr;
	float hy = wisp ? mix(0.2, 1.6, CUSTOM.y*CUSTOM.y) : 0.03 + 0.15*CUSTOM.y*CUSTOM.y;
	p.y = ground(p.xz) + hy;
	float len = wisp ? mix(3.0, 8.0, CUSTOM.z) : mix(0.5, 2.0, CUSTOM.z);
	float hgt = wisp ? mix(0.4, 1.5, CUSTOM.x) : mix(0.05, 0.2, CUSTOM.x);
	TRANSFORM = mat4(vec4(len, 0.0, 0.0, 0.0), vec4(0.0, hgt, 0.0, 0.0), vec4(0.0, 0.0, 1.0, 0.0), vec4(p, 1.0));
	float edge = 1.0 - smoothstep(0.3*box, 0.5*box, length(wr));
	COLOR = vec4(1.0, 1.0, 1.0, clamp(I, 0.0, 2.0)*(wisp ? a_wisp : a_salt)*edge);
}
