// G4 石块遮地面（地形GI设计.md §3 G4）：每块石头近似成一个等体积球，解析算它挡掉的、朝上地面看到的天光（余弦加权），
// 写进一张跟着相机走的可见度图（n×n，1 = 不挡）。多块石头按 (1 − occ) 相乘，即 −log 相加，可以按行分带并行。纯 C++17。
// 球的遮挡：上 / 下地平线用 Quilez（iquilezles.org/articles/sphereao），跨地平线用 Lagarde & de Rousiers 2014 的精确式，
// 同 godot/着色器/地平线GI.gdshaderinc 的 _hz_sph_occ（车的遮挡球）。
#pragma once

#include <cstdint>
#include <functional>
#include <vector>

namespace rockocc {

struct Sphere {
	float x = 0, z = 0; // 球心水平位置（Godot x、z）
	float y = 0; // 球心比该处地面高多少（m，可为负：埋了一半以上）
	float r = 0;
};

// 法线朝上的点看半径 r、球心在 (dx, dy, dz)（相对该点）的球：挡掉的余弦加权比例 0..1
double sphere_occ(double dx, double dy, double dz, double r);

// 只算 occ ≥ 约 1/400 的范围：返回影响半径（水平，m）
double reach(const Sphere &s);

// 可见度图：纹素 (i, j) 中心在 (x0 + (i + 0.5)·cell, z0 + (j + 0.5)·cell)，行 = z。输出 n×n 个 0..255（255 = 不挡）。
std::vector<uint8_t> splat(const std::vector<Sphere> &p_s, double p_x0, double p_z0, double p_cell, int p_n,
		const std::function<void(int64_t, const std::function<void(int64_t)> &)> &p_for = nullptr);

} // namespace rockocc
