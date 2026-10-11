// 对拍（C++ 端）：生成合成输入写到目录，并用 C++ 移植版算出结果。GDScript 端（parity/对拍.gd）读同一份输入，
// 用未改动的原脚本（地貌.gd、撒石.gd、地形LOD.gd）算同样的东西；parity_compare.py 逐位比较。
// 用法：parity_dump <目录>
#include "godot_compat.h"
#include "scatter_core.h"
#include "terrain_core.h"

#include <chrono>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

using namespace terrain;

static FILE *open_w(const std::string &p) {
	FILE *f = std::fopen(p.c_str(), "wb");
	if (!f) {
		std::perror(p.c_str());
		std::exit(1);
	}
	return f;
}
static void wd(FILE *f, double v) { std::fwrite(&v, 8, 1, f); }

static void wi(FILE *f, int32_t v) { std::fwrite(&v, 4, 1, f); }

// 合成场景的参数（GDScript 端用同样的字面量）
static void build(Terrain &t, scatter::Scatter &sc) {
	HeightLayers &hl = t.hl;
	hl.N = 65;
	hl.c0 = 0.1875;
	hl.half0 = 6.0;
	hl.L = 15;
	hl.layers.assign(hl.L, std::vector<float>(hl.N * hl.N));
	for (int k = 0; k < hl.L; k++) {
		const double c = hl.c0 * std::pow(2.0, k), h = hl.half0 * std::pow(2.0, k);
		for (int j = 0; j < hl.N; j++) {
			for (int i = 0; i < hl.N; i++) {
				const double x = -h + i * c, z = -h + j * c;
				hl.layers[k][j * hl.N + i] = (float)(3.0 * std::sin(0.013 * x) + 2.0 * std::cos(0.021 * z) + 0.5 * std::sin(0.37 * x + 0.11 * z) + 0.002 * x);
			}
		}
	}
	t.W = hl.half0 * std::pow(2.0, hl.L - 1);
	GeoStamps &g = t.geo;
	g.cN = 200;
	g.c_half = 100.0;
	g.c_cs = 2.0 * g.c_half / g.cN;
	g.cls.resize((size_t)g.cN * g.cN * 4);
	for (int j = 0; j < g.cN; j++) {
		for (int i = 0; i < g.cN; i++) {
			const size_t o = ((size_t)j * g.cN + i) * 4;
			g.cls[o] = (uint8_t)((i * 7 + j * 13) % 256);
			g.cls[o + 1] = (uint8_t)((i * 3 + j * 29 + 50) % 256);
			g.cls[o + 2] = (uint8_t)((i * 11 + j * 5 + 100) % 256);
			g.cls[o + 3] = (uint8_t)((i * 17 + j * 2 + 200) % 256);
		}
	}
	g.C = 1.48e-3;
	g.b = 2.2;
	g.dD_fresh = 0.2;
	g.dD_old = 0.03;
	g.rim = 0.032;
	g.fill = 0.8;
	g.cr_cls = { 1.09, 0.65, 0.74, 0.98 };
	const double rp[3][5] = { { 20.0, 0.45, 0.3, 0.2, 286.0 }, { 2.7, 0.2, 0.2, 0.25, 10.0 }, { 0.2, 0.01, 0.3, 0.2, 286.0 } }; // λ, 高, 背风, 弯曲, 方位
	for (const auto &r : rp) {
		const double a = gdc::deg_to_rad(r[4]);
		g.rp.push_back({ r[0], r[1], gdc::sn(a), -gdc::cs(a), r[2], r[3] }); // 运行时 libm（同 GDScript）；std::sin 对常量会被 GCC 用 MPFR 编译期折叠，可能差 1 ulp
	}
	t.has_geo = true;

	sc.k_cls = { 0.03, 0.06, 0.09, 0.15 };
	sc.nm = 5;
	sc.yr = { { -0.4, 0.95 }, { -0.35, 1.0 }, { -0.5, 0.9 }, { -0.42, 0.97 }, { -0.3, 0.85 } };
	sc.setup();
}

int main(int argc, char **argv) {
	if (argc < 2) {
		std::fprintf(stderr, "用法：parity_dump <目录>\n");
		return 1;
	}
	const std::string dir = argv[1];
	Terrain t;
	scatter::Scatter sc;
	build(t, sc);

	// —— 输入
	FILE *f = open_w(dir + "/heights.bin");
	for (const auto &layer : t.hl.layers) {
		std::fwrite(layer.data(), 4, layer.size(), f);
	}
	std::fclose(f);
	f = open_w(dir + "/geo_class.bin");
	std::fwrite(t.geo.cls.data(), 1, t.geo.cls.size(), f);
	std::fclose(f);
	std::vector<double> px, pz;
	gdc::RNG r;
	r.seed(12345);
	for (int i = 0; i < 4000; i++) {
		const double s = (i % 4 == 0) ? 1500.0 : (i % 4 == 1 ? 120.0 : (i % 4 == 2 ? 60.0 : 15.0)); // 覆盖各分辨率区和地类表边缘
		px.push_back((r.randf() * 2.0 - 1.0) * s);
		pz.push_back((r.randf() * 2.0 - 1.0) * s);
	}
	f = open_w(dir + "/points.bin");
	wi(f, (int32_t)px.size());
	for (size_t i = 0; i < px.size(); i++) {
		wd(f, px[i]);
		wd(f, pz[i]);
	}
	std::fclose(f);
	std::vector<std::array<int, 3>> tiles;
	for (int b = 0; b < scatter::NB; b++) {
		for (int ti = -2; ti <= 1; ti++) {
			for (int tj = -2; tj <= 1; tj++) {
				tiles.push_back({ b, ti, tj });
			}
		}
		tiles.push_back({ b, 37, -55 }); // 远处
	}
	f = open_w(dir + "/tiles.bin");
	wi(f, (int32_t)tiles.size());
	for (const auto &tl : tiles) {
		wi(f, tl[0]);
		wi(f, tl[1]);
		wi(f, tl[2]);
	}
	std::fclose(f);
	const float cams[3][3] = { { 3.0f, 1.8f, -4.0f }, { 140.0f, 2.5f, 60.0f }, { -30.0f, 45.0f, 10.0f } };
	const double pa = 0.0005; // 每像素角（≈ 70°/2560）

	// —— C++ 结果
	using clk = std::chrono::steady_clock;
	auto ms = [](clk::time_point a) { return std::chrono::duration<double, std::milli>(clk::now() - a).count(); };
	f = open_w(dir + "/cpp_points.bin");
	auto t0 = clk::now();
	for (size_t i = 0; i < px.size(); i++) {
		const double x = px[i], z = pz[i];
		wd(f, t.hl.h_data(x, z, 0));
		wd(f, t.hl.h_data(x, z, 3));
		wd(f, t.geo.dem_l(x, z));
		const auto w = t.geo.W(x, z);
		for (double v : w) {
			wd(f, v);
		}
		wd(f, t.geo.h(x, z));
		wd(f, t.geo.margin(std::fabs(x)));
		wd(f, t.h_cpu(x, z, 0));
	}
	std::fclose(f);
	const double t_points = ms(t0);

	f = open_w(dir + "/cpp_tiles.bin");
	t0 = clk::now();
	int rocks = 0;
	for (const auto &tl : tiles) {
		const scatter::Tile tile = sc.gen_tile(t, tl[0], tl[1], tl[2]);
		wi(f, (int32_t)tile.size());
		for (const auto &e : tile) {
			wi(f, e.first);
			wi(f, (int32_t)e.second.size());
			std::fwrite(e.second.data(), 4, e.second.size(), f);
			rocks += (int)e.second.size() / 16;
		}
	}
	std::fclose(f);
	const double t_tiles = ms(t0);

	f = open_w(dir + "/cpp_select.bin");
	t0 = clk::now();
	for (const auto &c : cams) {
		std::vector<LodNode> out;
		t.select(c[0], c[1], c[2], pa, out);
		wi(f, (int32_t)out.size());
		for (const LodNode &n : out) {
			wi(f, n.l);
			wd(f, n.x0);
			wd(f, n.z0);
			wd(f, n.hmin);
			wd(f, n.hmax);
			wi(f, n.q);
		}
	}
	std::fclose(f);
	const double t_select = ms(t0);

	// 撒石收集：单线程和多线程各跑一遍（冷缓存），两者必须逐位相同；写出的是多线程的结果，交给 GDScript 对拍。
	using Out = std::vector<std::array<std::vector<float>, 3>>;
	auto run_collect = [&](marsim::ThreadPool *pool, std::vector<Out> &r_outs, std::vector<scatter::Stats> &r_st) {
		for (const auto &c : cams) {
			sc.clear_cache();
			Out out;
			scatter::Stats st;
			sc.collect(t, c, pa, 0.0, out, st, pool);
			r_outs.push_back(std::move(out));
			r_st.push_back(st);
		}
	};
	std::vector<Out> serial, parallel;
	std::vector<scatter::Stats> st_s, st_p;
	t0 = clk::now();
	run_collect(nullptr, serial, st_s);
	const double t_collect_serial = ms(t0);
	marsim::ThreadPool pool(argc > 2 ? std::atoi(argv[2]) : 0);
	t0 = clk::now();
	run_collect(&pool, parallel, st_p);
	const double t_collect = ms(t0);
	bool same = true;
	for (size_t k = 0; k < std::size(cams); k++) {
		same = same && st_s[k].tiles == st_p[k].tiles && st_s[k].rocks == st_p[k].rocks && st_s[k].band == st_p[k].band && st_s[k].level == st_p[k].level;
		same = same && serial[k].size() == parallel[k].size();
		for (size_t ty = 0; same && ty < serial[k].size(); ty++) {
			for (int l = 0; l < 3; l++) {
				const std::vector<float> &x = serial[k][ty][l], &y = parallel[k][ty][l];
				same = same && x.size() == y.size() && (x.empty() || std::memcmp(x.data(), y.data(), x.size() * 4) == 0);
			}
		}
	}
	std::printf("撒石收集：单线程 %.1f ms，%d 线程 %.1f ms；输出（内容和顺序）%s\n", t_collect_serial, pool.threads(), t_collect, same ? "逐位相同" : "不一致！");
	if (!same) {
		return 2;
	}
	{ // 热缓存（每帧的常见情况）：区块都在缓存里，只做分级和拼接
		double ws = 0, wp = 0;
		for (const auto &c : cams) {
			sc.clear_cache();
			Out o0;
			scatter::Stats s0;
			sc.collect(t, c, pa, 0.0, o0, s0, &pool);
			for (int r = 0; r < 5; r++) {
				Out o1, o2;
				scatter::Stats s1, s2;
				auto a = clk::now();
				sc.collect(t, c, pa, 0.0, o1, s1, nullptr);
				ws += ms(a);
				a = clk::now();
				sc.collect(t, c, pa, 0.0, o2, s2, &pool);
				wp += ms(a);
			}
		}
		std::printf("撒石收集（热缓存，每机位每次）：单线程 %.2f ms，%d 线程 %.2f ms\n", ws / (5 * std::size(cams)), pool.threads(), wp / (5 * std::size(cams)));
	}
	f = open_w(dir + "/cpp_collect.bin");
	int collected = 0;
	for (size_t k = 0; k < std::size(cams); k++) {
		const scatter::Stats &st = st_p[k];
		const Out &out = parallel[k];
		collected += st.rocks;
		wi(f, st.tiles);
		wi(f, st.rocks);
		for (int ty = 0; ty < sc.nm; ty++) {
			for (int l = 0; l < 3; l++) {
				const std::vector<float> &v = ty < (int)out.size() ? out[ty][l] : std::vector<float>();
				wi(f, (int32_t)v.size());
				std::fwrite(v.data(), 4, v.size(), f);
			}
		}
	}
	std::fclose(f);

	f = open_w(dir + "/cpp_timing.txt");
	std::fprintf(f, "points %.3f ms (%zu 点)\ntiles %.3f ms (%zu 区块, %d 块)\nselect %.3f ms (3 机位)\ncollect %.3f ms (3 机位冷缓存, %d 块, %d 线程；单线程 %.3f ms)\n", t_points, px.size(), t_tiles, tiles.size(), rocks, t_select, t_collect, collected, pool.threads(), t_collect_serial);
	std::fclose(f);
	std::printf("C++：points %.2f ms，tiles %.2f ms（%d 块），select %.2f ms，collect %.2f ms（%d 块）\n", t_points, t_tiles, rocks, t_select, t_collect, collected);
	return 0;
}
