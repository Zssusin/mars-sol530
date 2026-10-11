// 地平线 GI（地形GI设计.md §3 G1）：多尺度地平线图 + 天空向量辐照度表。纯 C++17，不依赖 Godot。
//
// 地平线图：每层嵌套高度网格（第 k 层格距 c_k、半宽 half_k，原点居中，行 = z）上每隔 stride 个格点取一个纹素，
// 往 dirs 个方位步进（方位 a_i = i·2π/dirs，自北顺时针；Godot 方向 (sin a, 0, −cos a)），
// 步长按 t 的几何级数增长，越远取越粗的层（格距 ≈ 步长的一半，相当于预滤波），扣掉行星曲率 t²/2R，
// 记录最大仰角 θ = atan(max (h(t) − h0 − t²/2R) / t)，编码成 8 位：(θ − TH_MIN)/(TH_MAX − TH_MIN)。
// 参考：Max 1988；Timonen & Westerholm 2010（可扩展高度场自阴影）。
//
// 天空表：V_k(θ) = ∫_{扇区 k，仰角 > θ} L(ω)·ω dΩ（每通道一个向量，Godot 坐标），U_k(θ) = ∫ ω dΩ（只和几何有关）。
// 着色：E = Σ_k n·V_k(θ_k) + L_g·(π − Σ_k n·U_k(θ_k))，即看得见的天空 + 被挡方向看到的平均地面。
#pragma once

#include <cstdint>
#include <functional>
#include <vector>

namespace horizon {

constexpr double TH_MIN = -64.0 / 191.0 * 1.5707963267948966; // ≈ −30.16°：第 64 档正好是 0°（每档 90°/191 ≈ 0.47°）
constexpr double TH_MAX = 1.5707963267948966; // 90°

inline uint8_t encode(double th) {
	const double v = (th - TH_MIN) / (TH_MAX - TH_MIN) * 255.0 + 0.5;
	return (uint8_t)(v < 0.0 ? 0.0 : (v > 255.0 ? 255.0 : v));
}
inline double decode(uint8_t b) { return TH_MIN + (TH_MAX - TH_MIN) * b / 255.0; }

struct Grid {
	int N = 0; // 每边格点数，格点在 −half + i·cell
	double cell = 0.0, half = 0.0;
	std::vector<float> h; // N×N，行 = z
	double sample(double x, double z) const; // 双线性，越界夹到边
	bool inside(double x, double z) const;
};

struct Params {
	int dirs = 16;
	int stride = 2; // 地平线纹素 = 每 stride 个高度格点
	double growth = 0.1; // 步长 = max(格距, growth·t)
	double t_max = 40000.0; // 最远看多远（m）
	double planet_radius = 3389500.0; // 火星平均半径（m）
	double skip_inner = 0.40; // 第 k > 0 层 max(|x|,|z|) < skip_inner·half_k 的纹素由更细的层负责，不算（填 0）
};

// 第 k 层地平线图：返回 n×n×dirs 字节（纹素主序：((j·n + i)·dirs + d)），n = (N − 1)/stride + 1。
// p_for(rows, fn)：按行并行的执行器（传线程池的 parallel_for；空则串行）。
std::vector<uint8_t> compute_level(const std::vector<Grid> &p_grids, int p_k, const Params &p_par,
		const std::function<void(int64_t, const std::function<void(int64_t)> &)> &p_for = nullptr);
int level_size(const Grid &p_grid, int p_stride);

// G2 远处地影：第 k 层在方位 p_azimuth（弧度，自北顺时针）上的地平线仰角（弧度，float，不量化），n×n。
// 太阳仰角 > 它就照得到；着色器按太阳视半径做软边。太阳方位变了才要重算（仰角在着色器里比）。
std::vector<float> sun_level(const std::vector<Grid> &p_grids, int p_k, const Params &p_par, double p_azimuth,
		const std::function<void(int64_t, const std::function<void(int64_t)> &)> &p_for = nullptr);

// 天空表。p_rgb：等距圆柱（ENU，第 0 行 = 天顶，u = 0.5 − atan2(北, 东)/2π），w×h×3 个 float，乘 p_scale。
// 返回 nb × (dirs·4) 个 RGBA float（行主序，行 = k·4 + c，c = 0..2 为 R/G/B 的 V，3 为 U；列 = 仰角档 b，θ_b = TH_MIN + b/(nb−1)·(TH_MAX − TH_MIN)）。
std::vector<float> sky_table(const float *p_rgb, int p_w, int p_h, double p_scale, int p_dirs, int p_nb);

// 天空变了就重算：每个地平线纹素的 W = Σ_k V_k(θ_k)（每通道一个向量）和 Σ_k U_k(θ_k)，着色器里 E = n·W 只要 3 次采样。
// p_q[q]：第 q 组 4 个方位的 n×n RGBA8（compute_level 的输出按 4 个一组拆开，即 horizon_maps 的格式）。
// 输出 3 张 n×n RGBA float：a = (W_R.xyz, W_U.x)，b = (W_G.xyz, W_U.y)，c = (W_B.xyz, W_U.z)。
void irradiance_level(const std::vector<const uint8_t *> &p_q, int p_n, int p_dirs, const float *p_table, int p_nb,
		float *r_a, float *r_b, float *r_c,
		const std::function<void(int64_t, const std::function<void(int64_t)> &)> &p_for = nullptr);

// float → IEEE 半精度（就近舍入、溢出成 ∞、次正规数照算），给 Godot 的 FORMAT_RGBAH 用
uint16_t to_half(float p_f);

} // namespace horizon
