// 毅力号积尘（§15）：叠加层（material_overlay），只落在朝上的面上，边缘用噪声打散；尘色 = 地面底色提亮（空降尘比土壤亮、偏红）。
// 车的原材质不动；dust = 0 时整层透明。只在可见像素上多一次简单着色。
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_back, specular_disabled, diffuse_lambert;

#include "res://着色器/公共.gdshaderinc"

uniform float dust = 0.35;
uniform vec3 dust_col = vec3(0.30, 0.19, 0.125);                  // 线性；= 地面底色 ×(1.25, 1.15, 1.0)，实景.gd 按 scene.json 设

void fragment() {
	vec3 n = (INV_VIEW_MATRIX*vec4(NORMAL, 0.0)).xyz;
	vec3 wp = (INV_VIEW_MATRIX*vec4(VERTEX, 1.0)).xyz;
	float up = smoothstep(0.15, 0.85, n.y);
	float a = clamp(up*dust*1.6 + (fbm_noise(wp*7.0) - 0.5)*0.7*dust, 0.0, 1.0)*min(dust*2.5, 0.92);
	ALBEDO = dust_col; ALPHA = a;
	ROUGHNESS = 1.0;
}
