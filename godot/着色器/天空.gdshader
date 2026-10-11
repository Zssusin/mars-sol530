// 天空：火星大气.py 的等距圆柱图（ENU）× 大气顶照度，单位 W/m²/sr，同 58 的世界节点。
// 太阳盘 58（Cycles 太阳灯）在相机里看不见；漫游时可开 sun_disc。
shader_type sky;

uniform sampler2D sky_tex : filter_linear, repeat_enable;
uniform float E_TOP = 694.4;
uniform bool sun_disc = false;
uniform vec3 sun_radiance = vec3(0.0);                            // 太阳盘辐亮度（W/m²/sr，已含直射透过率）
uniform float sun_radius = 0.0033;                                // 视半径（rad），0.38°/2
uniform vec3 ground_radiance = vec3(-1.0);                        // 地平线以下（只在环境图里）：地面辐亮度 ρ_g·E_g/π，W/m²/sr；负 = 关

void sky() {
	vec3 e = vec3(EYEDIR.x, -EYEDIR.z, EYEDIR.y);
	vec2 uv = vec2(0.5 - atan(e.y, e.x)/(2.0*PI), 0.5 - asin(clamp(e.z, -1.0, 1.0))/PI);
	COLOR = E_TOP*texture(sky_tex, uv).rgb;
	// 环境光和反射都取自这张环境图。Cycles 里下半球被地面挡住，看到的是红色地面；这里照此把地平线以下换成地面辐亮度
	// （UE SkyAtmosphere 的"地面反照率"做法）。地平线下 2° 内从地平线天空渐变过去。背景（相机直接看到的天空）不改。
	if (AT_CUBEMAP_PASS && ground_radiance.r >= 0.0 && e.z < 0.0) {
		vec3 hz = E_TOP*texture(sky_tex, vec2(uv.x, 0.5)).rgb;
		COLOR = mix(hz, ground_radiance, smoothstep(0.0, 0.035, -e.z));
	}
	if (sun_disc && AT_CUBEMAP_PASS == false) {
		float a = acos(clamp(dot(EYEDIR, LIGHT0_DIRECTION), -1.0, 1.0));
		if (a < sun_radius) { float x = a/sun_radius; COLOR += sun_radiance*(1.0 - 0.6*(1.0 - sqrt(1.0 - x*x))); }
	}
}
