// 地形 CPU 热点的 C++ 版，和 GDScript 原版逐位一致（见 godot_compat.h 的精度规则）：
//   HeightLayers  ← 地形LOD.gd 的 h_data / h_level（15 层嵌套高度图，和着色器同样选层、同样混合）
//   GeoStamps     ← 地貌.gd（撞击坑、沙纹、地类权重、数据分辨率；和 着色器/地貌.gdshaderinc 同一个整数哈希）
//   MatDisp       ← 材质.gd disp()（地面材质的中观位移：控制图 + hex 平铺 + R16 高度；和 着色器/材质.gdshaderinc mat_disp 同一个哈希、同一套混合）
//   Terrain       ← 地形LOD.gd 的 h_cpu、node_box、sel/update 的选块部分（RenderingServer 调用留在 GDScript）
// 改 GDScript 原版时必须同样改这里，并重跑 tests/parity（对拍）。
#pragma once

#include <array>
#include <cstdint>
#include <unordered_map>
#include <vector>

namespace terrain {

struct HeightLayers {
	int N = 601; // 每层格点数
	double c0 = 0.02; // 第 0 层格距
	double half0 = 6.0; // 第 0 层半宽
	int L = 15;
	std::vector<std::vector<float>> layers; // L 层，每层 N×N（行 = z）

	double h_level(double x, double z, int k) const;
	double h_data(double x, double z, int kmin) const;
};

struct Ripple {
	double lambda, amp, dir_x, dir_z, lee, sinuosity; // 同 地貌.gd rp 每组 [λ, 峰谷高, 法向 x, 法向 z, 背风占比, 弯曲度]
};

struct GeoStamps {
	double on = 1.0;
	std::vector<uint8_t> cls; // RGBA8，cN×cN
	int cN = 2000;
	double c_half = 1000.0, c_cs = 1.0;
	double C = 0.003, b = 2.0, dD_fresh = 0.2, dD_old = 0.06, rim = 0.04, fill = 0.5;
	std::array<double, 4> cr_cls = { 1.0, 1.0, 1.0, 1.0 };
	std::vector<Ripple> rp;
	// 实测沙纹场（地貌.gd rf_*；80_沙纹场.py 烘的 ripple_field.bin，RGBA8 行 0 = 北）
	double rf_on = 0.0;
	std::vector<uint8_t> rf;
	int rf_N = 1000;
	double rf_half = 1000.0, rf_cell = 2.0, rf_H = 0.0, rf_lee = 0.3, rf_rho0 = 0.15, rf_rho1 = 0.6, rf_lo = 1.0, rf_hi = 5.0;

	static uint32_t ih(uint32_t x);
	static double u(uint32_t h) { return (double)(h >> 8) / 16777216.0; }
	double dem_l(double x, double z, double l_hirise = 0.0) const;
	std::array<double, 4> W(double x, double z) const;
	double craters(double x, double z, double dl, const std::array<double, 4> &w) const;
	double ripples(double x, double z, double dl, const std::array<double, 4> &w) const;
	double rfield(double x, double z, double dl) const;
	double h(double x, double z) const;
	double margin(double e) const;
};

// 中观位移（docs/地面材质/阶段1.md §9.3）：着色器 mat_disp(xz, 0, cpu_mip = true) 的移植。数据全从 材质.gd 的成员读。
struct MatDisp {
	double gain = 0.0; // 着色器 disp_gain；0 = 不算
	std::vector<uint32_t> ctrl_n, ctrl_f; // 控制图 32 位字（行 0 在北）
	int nN = 0, nF = 0;
	std::vector<uint8_t> gate; // 位移门 R8，同近图网格
	int nG = 0;
	double grid[4] = { 50.0, 0.04, 1000.0, 1.0 }; // 近 half、格距，远 half、格距
	int out_id[4] = { 0, 2, 3, -1 };
	double out_w[4] = { 0.6, 0.3, 0.1, 0.0 };
	std::vector<uint16_t> h16; // 每层一级 mip，按层接起来
	std::vector<int> lay_off, lay_n; // 每层起点（u16 个数）、边长
	std::vector<float> lay_lohi; // 每层混合高度 lo、hi
	std::vector<float> me, bl; // 每材质 4 个：起始层、变体数、边长、量程 / 对比、偏置、粗糙度、旋转
	double hexp[4] = { 0.45, 7.0, 0.6, 0.1 }; // 中观 hex 格距 m、权重指数、高度权、混合锐度
	int k = 3;
	int fmt = 0; // 控制图格式（材质.gd fmt）：0 = 旧 3 槽、4 = 中景版 4 槽

	double gate_at(double x, double z) const;
	double disp(double x, double z) const; // 米，已乘 gain
};

// CDLOD 选出的一块：级、角点、高度范围、是否父块的 1/4（q = 1）
struct LodNode {
	int l;
	double x0, z0, hmin, hmax;
	int q;
};

class Terrain {
public:
	HeightLayers hl;
	GeoStamps geo;
	bool has_geo = false;
	MatDisp mat;
	bool has_mat = false;

	// CDLOD 参数（地形LOD.gd）
	int m = 64;
	double c0 = 0.01, tri_px = 8.0;
	int L = 18;
	double W = 98304.0;
	double range0 = 6.0;
	std::vector<double> R;

	// 中观位移只在 kmin = 0（车轮、撒石、相机、第 0 层地平线网格）时加：厘米级，粗层用不着
	double h_cpu(double x, double z, int kmin = 0) const {
		return hl.h_data(x, z, kmin) + (has_geo ? geo.h(x, z) : 0.0) + (has_mat && kmin == 0 ? mat.disp(x, z) : 0.0);
	}

	// 地形LOD.update 的选块：cam 是 Vector3（float 分量）。返回所选的块（顺序同 GDScript）。
	void select(float cam_x, float cam_y, float cam_z, double pixel_angle, std::vector<LodNode> &r_out);
	void clear_box_cache() { box_.clear(); }
	size_t box_cache_size() const { return box_.size(); }

private:
	struct Key {
		int64_t l, i, j;
		bool operator==(const Key &o) const { return l == o.l && i == o.i && j == o.j; }
	};
	struct KeyHash {
		size_t operator()(const Key &k) const { return (size_t)(k.l * 73856093) ^ (size_t)(k.i * 19349663) ^ (size_t)(k.j * 83492791); }
	};
	std::unordered_map<Key, std::array<double, 2>, KeyHash> box_;

	const std::array<double, 2> &node_box(int l, double x0, double z0, double s);
	bool hits(const float cam[3], double x0, double z0, double s, const std::array<double, 2> &b, double r) const;
	bool sel(const float cam[3], int l, double x0, double z0, std::vector<LodNode> &out);
};

} // namespace terrain
