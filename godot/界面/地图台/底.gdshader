shader_type canvas_item;
uniform sampler2D bg : filter_linear;
uniform vec3 c_tint = vec3(0.03, 0.08, 0.09);
void fragment() {
	float g = texture(bg, UV).r;
	vec2 q = (UV - 0.5) * 2.0;
	float v = clamp(1.0 - 0.45 * dot(q, q), 0.35, 1.0);
	vec3 c = vec3(g * 0.55 + c_tint * 0.45) * v;
	COLOR = vec4(c, 1.0);
}
