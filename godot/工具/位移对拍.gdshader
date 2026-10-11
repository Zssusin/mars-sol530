// 位移对拍（工具/位移对拍.gd）：把 材质.gdshaderinc 的 mat_disp 逐点画到 RGBA16F 里读回，和 CPU（C++ / GDScript）比。
shader_type canvas_item;
#include "res://着色器/公共.gdshaderinc"
#include "res://着色器/中观位移.gdshaderinc"
uniform vec4 rect = vec4(0.0, 0.0, 0.01, 0.01);                  // 第 0 个点的 Godot x、z，点距 dx、dz
uniform float cell = 0.0;                                         // 0：同 CPU（整数 mip）；> 0：同顶点（按格距选 mip）
void fragment() {
	vec2 xz = rect.xy + floor(FRAGCOORD.xy)*rect.zw;
	COLOR = vec4(mat_disp(xz, cell, cell <= 0.0)*10.0, mat_gate_at(xz), 0.0, 1.0);
}
