// 撒石.gd 和 实景.gd rock_bucket 的 C++ 版，和原版逐位一致（区块内容）；区块排序用稳定排序（GDScript sort_custom 不稳定，
// 距离相等的区块顺序可能不同 → 只影响 MultiMesh 里的实例顺序，不影响画面）。
#pragma once

#include "terrain_core.h"
#include "thread_pool.h"

#include <array>
#include <cstdint>
#include <unordered_map>
#include <utility>
#include <vector>

namespace scatter {

constexpr double D0 = 0.05;
constexpr int NB = 6;
constexpr double TILE = 512.0;
constexpr int CACHE_MAX = 6000;
constexpr int FLOATS = 16; // 每块：3×4 变换（按行）+ RGBA

// 一个区块：按类型首次出现的顺序，(类型, 缓冲)
using Tile = std::vector<std::pair<int, std::vector<float>>>;

struct Stats {
	int tiles = 0, rocks = 0, generated = 0;
	std::array<int, NB> band = {};
	std::array<int, 3> level = {};
	bool pending = false;
};

class Scatter {
public:
	// 配置（撒石.gd setup）
	std::array<double, 4> k_cls = { 0, 0, 0, 0 };
	int nm = 1;
	float base[3] = { 0.24f, 0.17f, 0.13f }; // Color：float
	std::vector<std::array<double, 2>> yr; // 每种网格 [y 最低, y 最高]
	double px_min = 3.0;
	double px[3] = { 48.0, 12.0, 1.0 };

	void setup(); // 由 k_cls 算 N、Dt、Ct、Nmax（同 golombek_n）
	Tile gen_tile(const terrain::Terrain &t, int b, int64_t ti, int64_t tj) const;

	// 撒石.gd collect：把看得见的区块按级拼进 r_out[类型][级]（直接追加 float）。budget_ms ≤ 0 = 不限时。
	// p_pool 非空时多线程：区块生成、逐块分级、写入都并行，输出的内容和顺序与单线程逐位相同（单测 + 对拍检查）。
	// 限时的含义不变：开始生成一个新区块前看是否超时，超时的区块留到下次（pending）；多线程时哪些区块赶上了会略有不同。
	void collect(const terrain::Terrain &t, const float cam[3], double pa, double budget_ms, std::vector<std::array<std::vector<float>, 3>> &r_out, Stats &r_stats, marsim::ThreadPool *p_pool = nullptr);

	const std::array<double, NB> &nmax() const { return Nmax_; }
	double n_density(int b, int c) const { return N_[b][c]; }
	size_t cache_size() const { return cache_.size(); }
	void clear_cache() { cache_.clear(); }

private:
	std::array<std::array<double, 4>, NB> N_ = {};
	std::array<std::array<std::vector<float>, 4>, NB> Dt_, Ct_;
	std::array<double, NB> Nmax_ = {};

	struct Key {
		int64_t b, i, j;
		bool operator==(const Key &o) const { return b == o.b && i == o.i && j == o.j; }
	};
	struct KeyHash {
		size_t operator()(const Key &k) const { return (size_t)(k.b * 73856093) ^ (size_t)(k.i * 19349663) ^ (size_t)(k.j * 83492791); }
	};
	std::unordered_map<Key, Tile, KeyHash> cache_;

	int lv(double s) const { return s > px[0] ? 0 : (s > px[1] ? 1 : 2); }
};

// golombek_n：返回 [总数, D 表, 累计比例表]（D、cdf 存成 float，同 PackedFloat32Array）
double golombek_n(double k, double d1, double d2, std::vector<float> &r_D, std::vector<float> &r_cdf, int nD = 40);
double inv_cdf(const std::vector<float> &D, const std::vector<float> &cdf, double u);

// 实景.gd rock_bucket 的固定石块部分：pos（float×3）、D（float）、buf（每块 16 float）按屏幕直径分 3 级追加到 r_out。
// pos：n×3（x, y, z），D：n，buf：n×FLOATS。指针版给 GDExtension 直接用 Packed 数组的内存，不拷贝。
void bucket_fixed(const float *pos, const float *D, const float *buf, size_t n, const float cam[3], double pa, const double rk_px[3], std::array<std::vector<float>, 3> &r_out);
void bucket_fixed(const std::vector<float> &pos, const std::vector<float> &D, const std::vector<float> &buf, const float cam[3], double pa, const double rk_px[3], std::array<std::vector<float>, 3> &r_out);

} // namespace scatter
