// GDExtension 绑定：地形取高、地貌印章、CDLOD 选块、撒石与石块分级的 C++ 版（core/terrain_core、scatter_core）。
// 参数一律从现有 GDScript 对象读（地形LOD.gd、地貌.gd、撒石.gd 的成员），保证和原版用的是同一份数；
// 对拍（tests/parity）证明两边逐位一致。没装扩展时 GDScript 照旧走原版。
#pragma once

#include "horizon.h"
#include "scatter_core.h"
#include "terrain_core.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>

#include <memory>
#include <mutex>

namespace godot {

class MarsTerrainCore : public RefCounted {
	GDCLASS(MarsTerrainCore, RefCounted)

	terrain::Terrain t_;
	scatter::Scatter sc_;
	bool has_scatter_ = false;
	scatter::Stats stats_;
	mutable std::mutex scatter_mutex_; // rock_bucket 在后台任务里跑；configure_*、get_scatter_stats 也拿这把锁
	// 线程池：第一次用时才建（ClassDB 会为取默认值实例化类，不能一构造就起线程）。默认 = 硬件线程数的一半（最多 8），给 Godot 自己的线程留余量。
	// shared_ptr：set_threads 换池时，正在用旧池的线程（如后台 h_cpu_grid）手里那份还有效，用完才销毁。
	mutable std::shared_ptr<marsim::ThreadPool> pool_;
	mutable std::mutex pool_mutex_;
	int threads_ = 0; // 0 = 默认
	std::shared_ptr<marsim::ThreadPool> pool() const;
	// 地平线用的高度网格（每层 h_cpu 建一次，horizon_maps / horizon_sun 共用；configure_* 时清掉）
	mutable std::vector<horizon::Grid> hz_grids_;
	mutable std::mutex hz_mutex_;
	const std::vector<horizon::Grid> &hz_grids() const; // 调用方持有 hz_mutex_

protected:
	static void _bind_methods();

public:
	// 配置：传入 GDScript 对象本身
	bool configure_heights(Object *p_lod); // 地形LOD.gd：hN hc0 hh0 hL hl m c0 tri_px L W
	bool configure_geo(Object *p_geo); // 地貌.gd：on cls cN c_half c_cs C b dD_fresh dD_old rim fill cr_cls rp
	bool configure_mat(Object *p_mat); // 材质.gd：中观位移的 CPU 数据（null = 不算位移，--材质=旧）
	double mat_disp(double p_x, double p_z) const { return t_.has_mat ? t_.mat.disp(p_x, p_z) : 0.0; }
	bool configure_scatter(Object *p_scat); // 撒石.gd：k_cls nm base yr PX_MIN px（N/Dt/Ct 在 C++ 里按同样公式重算）

	// 取高（只读，可在任意线程并发调用；但不要和 configure_* 同时调用——configure 只在 setup 时做）
	double h_cpu(double p_x, double p_z, int p_kmin) const { return t_.h_cpu(p_x, p_z, p_kmin); }
	double h_data(double p_x, double p_z, int p_kmin) const { return t_.hl.h_data(p_x, p_z, p_kmin); }
	double geo_h(double p_x, double p_z) const { return t_.has_geo ? t_.geo.h(p_x, p_z) : 0.0; }
	PackedFloat64Array geo_w(double p_x, double p_z) const;
	double dem_l(double p_x, double p_z, double p_l_hirise) const { return t_.geo.dem_l(p_x, p_z, p_l_hirise); }
	double geo_margin(double p_e) const { return t_.has_geo ? t_.geo.margin(p_e) : 0.0; }
	// 给 MarsRoverSim.set_height_grid。200×200 约 15 ms：放 WorkerThreadPool 里调，别在主线程（见 接入.md §3）
	PackedFloat32Array h_cpu_grid(double p_x0, double p_z0, double p_cell, int p_nx, int p_nz) const;

	// CDLOD 选块（只在主线程调：会写包围盒缓存）：返回每块 6 个数 [l, x0, z0, hmin, hmax, q]
	PackedFloat64Array select(const Vector3 &p_cam, double p_pixel_angle);
	double get_range0() const { return t_.range0; }
	void clear_box_cache() { t_.clear_box_cache(); }

	// 实景.gd rock_bucket：p_fixed[i] = {pos: PackedVector3Array, D: PackedFloat32Array, buf: PackedFloat32Array}（实测 + 固定表石块）。
	// 返回 Array[类型] = [PackedFloat32Array 0 级, 1 级, 2 级]，可以直接给 rock_apply。类型数 = max(固定类型数, 撒石类型数 nm)。
	Array rock_bucket(const Vector3 &p_cam, double p_pa, double p_budget_ms, const Array &p_fixed);
	Dictionary get_scatter_stats() const;
	// 碰撞用（控制.gd）：矩形 [x0, x1]×[z0, z1] 里第 b_min..5 档的撒石石块（和画出来的逐位相同：同一套区块播种），
	// 返回 Array[类型] 个 PackedFloat32Array（每块 16 个数，同 rock_bucket）。不进缓存、不管屏幕大小。
	Array scatter_rocks(double p_x0, double p_z0, double p_x1, double p_z1, int p_b_min) const; // {tiles, rocks, generated, band, level, pending, cache}
	void clear_scatter_cache();

	// 地平线 GI（core/horizon.h）。horizon_maps：每层先用 h_cpu（数据 + 地貌印章）建高度网格，再算地平线图；
	// 返回 Array[dirs/4]，每项是 Array[L] 个 PackedByteArray（n×n RGBA8，4 个方位一组），可直接建 Texture2DArray。
	// 15 层 601²、stride 2、16 方位在 fedora 16 线程上约几秒：加载时调一次，结果缓存到盘。
	Array horizon_maps(int p_stride, int p_dirs, double p_growth, double p_t_max) const;
	// 天空表：p_rgb = 天空图（等距圆柱 FORMAT_RGBF 的 float），返回 nb × (dirs·4) 个 RGBA float（见 horizon::sky_table）。
	PackedFloat32Array horizon_sky_table(const PackedFloat32Array &p_rgb, int p_w, int p_h, double p_scale, int p_dirs, int p_nb) const;
	// 天空变了就调：p_maps = horizon_maps 的返回值（或读回的缓存），p_table = horizon_sky_table 的返回值。
	// 返回 Array[3]，每项 Array[L] 个 PackedByteArray（n×n RGBA float32），着色器 E = n·W 三次采样。
	// p_half = true：输出半精度（RGBA 各 16 位，给 FORMAT_RGBAH），显存和上传量减半。
	Array horizon_irradiance(const Array &p_maps, const PackedFloat32Array &p_table, int p_dirs, int p_nb, bool p_half = false) const;
	// G2 远处地影：方位 p_azimuth（弧度，自北顺时针）上的地平线仰角（弧度）。返回 Array[L] 个 PackedFloat32Array（n×n），
	// 可直接建 FORMAT_RF 的 Texture2DArray。太阳方位变了才调；可在后台线程调（不和 configure_* 同时）。
	Array horizon_sun(int p_stride, double p_azimuth, double p_growth, double p_t_max) const;
	// G4 石块遮地面（core/rock_occlusion.h）：p_res = rock_bucket 的返回值（Array[类型] = [0 级, 1 级, 2 级] 缓冲，每块 16 个数），
	// p_types = 每种单位石块网格的包围盒（中心 xyz、半尺寸 xyz，6 个数一种）。每块石头 → 等体积球（球心高度相对 h_cpu 地面），
	// 写进以 (p_x0, p_z0) 为角、格距 p_cell、n×n 的可见度图（L8，255 = 不挡）。可在后台线程调。
	PackedByteArray rock_occlusion(const Array &p_res, const PackedFloat32Array &p_types, double p_x0, double p_z0, double p_cell, int p_n) const;

	// 线程数（含调用线程）：1 = 单线程；0 = 默认。多线程和单线程的输出逐位相同。
	void set_threads(int p_threads);
	int get_threads() const;
};

} // namespace godot
