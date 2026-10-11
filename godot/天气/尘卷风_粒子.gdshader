// 尘卷风：一根涡柱的粒子（本地坐标，发射器 = 涡柱底中心，由 天气.gd 按环境风平移）。解析运动：每颗尘团从底部升起、绕轴旋转；
// 高度 y = H·h^1.3（h = 年龄/寿命，尘多在下部）、半径随高度张开、整柱顺风倾斜（风随高度增大）、轴线慢慢摆动。
shader_type particles;
uniform float D = 25.0;            // 直径（m）
uniform float H = 230.0;           // 高（m）
uniform vec2 lean = vec2(0.0);     // 每米高度的水平偏移（本地 xz，顺风）
uniform float vt = 15.0;           // 切向风速（m/s）
uniform float psize = 10.0;        // 尘团大小（m）
uniform float a_peak = 0.05;       // 单个尘团中心的不透明度（底部）
uniform float fade = 1.0;          // 整根的生灭渐变
uniform float seedf = 0.0;

float h1(uint n) {
	n = (n << 13u) ^ n; n = n*(n*n*15731u + 789221u) + 1376312589u;
	return float(n & 0x7fffffffu)/2147483647.0;
}

void start() {
	uint s = RANDOM_SEED*3u + INDEX*7919u + NUMBER*104729u;
	CUSTOM = vec4(h1(s)*6.2832, 0.0, h1(s + 1u), h1(s + 2u));
	TRANSFORM = mat4(1.0);
	VELOCITY = vec3(0.0);
}

void process() {
	CUSTOM.y += DELTA;
	float h = clamp(CUSTOM.y/LIFETIME, 0.0, 1.0);
	float y = H*pow(h, 1.3);
	float yn = y/H;
	float r = 0.5*D*mix(0.3, 1.0, CUSTOM.z)*(1.0 + 1.5*yn);
	float th = CUSTOM.x + vt/max(r, 0.5)*CUSTOM.y;
	vec2 c = lean*y + vec2(sin(TIME*0.21 + yn*3.0 + seedf), cos(TIME*0.17 + yn*2.3 + seedf*1.7))*D*0.35*yn;
	vec3 p = vec3(c.x + r*cos(th), y + (CUSTOM.w - 0.5)*psize*0.3, c.y + r*sin(th));
	float sz = psize*(0.6 + 0.8*CUSTOM.w)*(1.0 + 1.2*yn);
	TRANSFORM = mat4(vec4(sz, 0.0, 0.0, 0.0), vec4(0.0, sz, 0.0, 0.0), vec4(0.0, 0.0, sz, 0.0), vec4(p, 1.0));
	float dens = exp(-yn/0.6);
	float life = smoothstep(0.0, 0.04, h)*(1.0 - smoothstep(0.8, 1.0, h));
	COLOR = vec4(1.0, 1.0, 1.0, a_peak*dens*life*fade);
}
