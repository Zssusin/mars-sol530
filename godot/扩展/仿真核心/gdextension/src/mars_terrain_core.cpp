#include "mars_terrain_core.h"

#include "horizon.h"
#include "rock_occlusion.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <thread>

using namespace godot;

void MarsTerrainCore::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure_heights", "lod"), &MarsTerrainCore::configure_heights);
	ClassDB::bind_method(D_METHOD("configure_geo", "geo"), &MarsTerrainCore::configure_geo);
	ClassDB::bind_method(D_METHOD("configure_scatter", "scat"), &MarsTerrainCore::configure_scatter);
	ClassDB::bind_method(D_METHOD("configure_mat", "mat"), &MarsTerrainCore::configure_mat);
	ClassDB::bind_method(D_METHOD("mat_disp", "x", "z"), &MarsTerrainCore::mat_disp);
	ClassDB::bind_method(D_METHOD("h_cpu", "x", "z", "kmin"), &MarsTerrainCore::h_cpu, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("h_data", "x", "z", "kmin"), &MarsTerrainCore::h_data, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("geo_h", "x", "z"), &MarsTerrainCore::geo_h);
	ClassDB::bind_method(D_METHOD("geo_w", "x", "z"), &MarsTerrainCore::geo_w);
	ClassDB::bind_method(D_METHOD("dem_l", "x", "z", "l_hirise"), &MarsTerrainCore::dem_l, DEFVAL(0.0));
	ClassDB::bind_method(D_METHOD("geo_margin", "e"), &MarsTerrainCore::geo_margin);
	ClassDB::bind_method(D_METHOD("h_cpu_grid", "x0", "z0", "cell", "nx", "nz"), &MarsTerrainCore::h_cpu_grid);
	ClassDB::bind_method(D_METHOD("select", "cam", "pixel_angle"), &MarsTerrainCore::select);
	ClassDB::bind_method(D_METHOD("get_range0"), &MarsTerrainCore::get_range0);
	ClassDB::bind_method(D_METHOD("clear_box_cache"), &MarsTerrainCore::clear_box_cache);
	ClassDB::bind_method(D_METHOD("rock_bucket", "cam", "pa", "budget_ms", "fixed"), &MarsTerrainCore::rock_bucket);
	ClassDB::bind_method(D_METHOD("get_scatter_stats"), &MarsTerrainCore::get_scatter_stats);
	ClassDB::bind_method(D_METHOD("clear_scatter_cache"), &MarsTerrainCore::clear_scatter_cache);
	ClassDB::bind_method(D_METHOD("horizon_maps", "stride", "dirs", "growth", "t_max"), &MarsTerrainCore::horizon_maps, DEFVAL(2), DEFVAL(16), DEFVAL(0.1), DEFVAL(40000.0));
	ClassDB::bind_method(D_METHOD("horizon_sun", "stride", "azimuth", "growth", "t_max"), &MarsTerrainCore::horizon_sun, DEFVAL(2), DEFVAL(0.0), DEFVAL(0.1), DEFVAL(40000.0));
	ClassDB::bind_method(D_METHOD("rock_occlusion", "res", "types", "x0", "z0", "cell", "n"), &MarsTerrainCore::rock_occlusion);
	ClassDB::bind_method(D_METHOD("scatter_rocks", "x0", "z0", "x1", "z1", "b_min"), &MarsTerrainCore::scatter_rocks, DEFVAL(1));
	ClassDB::bind_method(D_METHOD("horizon_irradiance", "maps", "table", "dirs", "nb", "half"), &MarsTerrainCore::horizon_irradiance, DEFVAL(16), DEFVAL(64), DEFVAL(false));
	ClassDB::bind_method(D_METHOD("horizon_sky_table", "rgb", "w", "h", "scale", "dirs", "nb"), &MarsTerrainCore::horizon_sky_table, DEFVAL(16), DEFVAL(64));
	ClassDB::bind_method(D_METHOD("set_threads", "threads"), &MarsTerrainCore::set_threads);
	ClassDB::bind_method(D_METHOD("get_threads"), &MarsTerrainCore::get_threads);
}

static int default_threads() {
	const int hw = int(std::thread::hardware_concurrency());
	return std::clamp(hw / 2, 1, 8);
}

std::shared_ptr<marsim::ThreadPool> MarsTerrainCore::pool() const {
	std::lock_guard<std::mutex> lock(pool_mutex_);
	if (!pool_) {
		pool_ = std::make_shared<marsim::ThreadPool>(threads_ > 0 ? threads_ : default_threads());
	}
	return pool_;
}

void MarsTerrainCore::set_threads(int p_threads) {
	ERR_FAIL_COND_MSG(p_threads < 0 || p_threads > 64, "set_threads: 0 (default) … 64");
	std::lock_guard<std::mutex> lock(scatter_mutex_); // 不在 rock_bucket 进行中换线程池
	std::lock_guard<std::mutex> plock(pool_mutex_);
	threads_ = p_threads;
	pool_.reset(); // 下次用时按新线程数重建
}

int MarsTerrainCore::get_threads() const {
	return pool()->threads();
}

bool MarsTerrainCore::configure_heights(Object *p_lod) {
	ERR_FAIL_NULL_V(p_lod, false);
	std::lock_guard<std::mutex> lock(scatter_mutex_); // 后台 rock_bucket 正在读高度层时不能重新分配
	terrain::HeightLayers &hl = t_.hl;
	hl.N = int(p_lod->get("hN"));
	hl.c0 = double(p_lod->get("hc0"));
	hl.half0 = double(p_lod->get("hh0"));
	hl.L = int(p_lod->get("hL"));
	const Array layers = p_lod->get("hl");
	ERR_FAIL_COND_V_MSG(layers.size() != hl.L, false, "hl.size() != hL");
	hl.layers.assign(hl.L, std::vector<float>());
	for (int k = 0; k < hl.L; k++) {
		const PackedFloat32Array a = layers[k];
		ERR_FAIL_COND_V_MSG(a.size() != int64_t(hl.N) * hl.N, false, "height layer size != hN*hN");
		hl.layers[k].assign(a.ptr(), a.ptr() + a.size());
	}
	t_.m = int(p_lod->get("m"));
	t_.c0 = double(p_lod->get("c0"));
	t_.tri_px = double(p_lod->get("tri_px"));
	t_.L = int(p_lod->get("L"));
	t_.W = double(p_lod->get("W"));
	t_.clear_box_cache();
	{
		std::lock_guard<std::mutex> hlock(hz_mutex_);
		hz_grids_.clear();
	}
	return true;
}

bool MarsTerrainCore::configure_geo(Object *p_geo) {
	std::lock_guard<std::mutex> lock(scatter_mutex_);
	if (!p_geo) {
		t_.has_geo = false;
		return true;
	}
	terrain::GeoStamps &g = t_.geo;
	g.on = double(p_geo->get("on"));
	const PackedByteArray cls = p_geo->get("cls");
	g.cls.assign(cls.ptr(), cls.ptr() + cls.size());
	g.cN = int(p_geo->get("cN"));
	g.c_half = double(p_geo->get("c_half"));
	g.c_cs = double(p_geo->get("c_cs"));
	ERR_FAIL_COND_V_MSG(int64_t(g.cls.size()) != int64_t(g.cN) * g.cN * 4, false, "cls size != cN*cN*4");
	g.C = double(p_geo->get("C"));
	g.b = double(p_geo->get("b"));
	g.dD_fresh = double(p_geo->get("dD_fresh"));
	g.dD_old = double(p_geo->get("dD_old"));
	g.rim = double(p_geo->get("rim"));
	g.fill = double(p_geo->get("fill"));
	const Array cr = p_geo->get("cr_cls");
	ERR_FAIL_COND_V_MSG(cr.size() < 4, false, "cr_cls.size() < 4");
	for (int i = 0; i < 4; i++) {
		g.cr_cls[i] = double(cr[i]);
	}
	g.rp.clear();
	const Array rp = p_geo->get("rp");
	for (int64_t i = 0; i < rp.size(); i++) {
		const Array e = rp[i];
		ERR_FAIL_COND_V_MSG(e.size() < 6, false, "rp entry size < 6");
		g.rp.push_back({ double(e[0]), double(e[1]), double(e[2]), double(e[3]), double(e[4]), double(e[5]) });
	}
	// 实测沙纹场（地貌.gd rf_*）；老版本 地貌.gd 没有这些成员 → get 返回 nil → 关
	g.rf_on = 0.0;
	g.rf.clear();
	if (p_geo->get("rf_on").get_type() != Variant::NIL && double(p_geo->get("rf_on")) > 0.0) {
		const PackedByteArray rf = p_geo->get("rf");
		g.rf_N = int(p_geo->get("rf_N"));
		ERR_FAIL_COND_V_MSG(int64_t(rf.size()) != int64_t(g.rf_N) * g.rf_N * 4, false, "rf size != rf_N*rf_N*4");
		g.rf.assign(rf.ptr(), rf.ptr() + rf.size());
		g.rf_half = double(p_geo->get("rf_half"));
		g.rf_cell = double(p_geo->get("rf_cell"));
		g.rf_H = double(p_geo->get("rf_H"));
		g.rf_lee = double(p_geo->get("rf_lee"));
		g.rf_rho0 = double(p_geo->get("rf_rho0"));
		g.rf_rho1 = double(p_geo->get("rf_rho1"));
		g.rf_lo = double(p_geo->get("rf_lo"));
		g.rf_hi = double(p_geo->get("rf_hi"));
		g.rf_on = double(p_geo->get("rf_on"));
	}
	t_.has_geo = true;
	t_.clear_box_cache();
	{
		std::lock_guard<std::mutex> hlock(hz_mutex_);
		hz_grids_.clear();
	}
	return true;
}

bool MarsTerrainCore::configure_mat(Object *p_mat) {
	std::lock_guard<std::mutex> lock(scatter_mutex_);
	if (!p_mat) {
		t_.has_mat = false;
		return true;
	}
	terrain::MatDisp &d = t_.mat;
	d.gain = double(p_mat->get("gain"));
	auto words = [](const PackedByteArray &b, int &n, std::vector<uint32_t> &out) {
		ERR_FAIL_COND_V_MSG(b.size() < 8, false, "control map too small");
		n = int(b.decode_s32(0));
		ERR_FAIL_COND_V_MSG(b.size() != 8 + int64_t(n) * n * 4, false, "control map size != 8 + n*n*4");
		out.resize(size_t(n) * n);
		const uint8_t *p = b.ptr() + 8;
		for (size_t i = 0; i < out.size(); i++) {
			out[i] = uint32_t(p[i * 4]) | (uint32_t(p[i * 4 + 1]) << 8) | (uint32_t(p[i * 4 + 2]) << 16) | (uint32_t(p[i * 4 + 3]) << 24);
		}
		return true;
	};
	if (!words(p_mat->get("ctrl_n"), d.nN, d.ctrl_n) || !words(p_mat->get("ctrl_f"), d.nF, d.ctrl_f)) return false;
	const PackedByteArray g = p_mat->get("gate");
	ERR_FAIL_COND_V_MSG(g.size() < 8, false, "gate too small");
	d.nG = int(g.decode_s32(0));
	ERR_FAIL_COND_V_MSG(g.size() != 8 + int64_t(d.nG) * d.nG, false, "gate size != 8 + n*n");
	d.gate.assign(g.ptr() + 8, g.ptr() + g.size());
	const Array grid = p_mat->get("grid"), oid = p_mat->get("out_id"), ow = p_mat->get("out_w"), hexp = p_mat->get("hexp");
	ERR_FAIL_COND_V(grid.size() < 4 || oid.size() < 4 || ow.size() < 4 || hexp.size() < 4, false);
	for (int i = 0; i < 4; i++) {
		d.grid[i] = double(grid[i]);
		d.out_id[i] = int(oid[i]);
		d.out_w[i] = double(ow[i]);
		d.hexp[i] = double(hexp[i]);
	}
	const PackedByteArray h = p_mat->get("h16");
	d.h16.resize(size_t(h.size()) / 2);
	for (size_t i = 0; i < d.h16.size(); i++) d.h16[i] = uint16_t(h[i * 2]) | (uint16_t(h[i * 2 + 1]) << 8);
	const PackedInt32Array lo = p_mat->get("lay_off"), ln = p_mat->get("lay_n");
	d.lay_off.assign(lo.ptr(), lo.ptr() + lo.size());
	d.lay_n.assign(ln.ptr(), ln.ptr() + ln.size());
	const PackedFloat32Array lh = p_mat->get("lay_lohi"), me = p_mat->get("me"), bl = p_mat->get("bl");
	d.lay_lohi.assign(lh.ptr(), lh.ptr() + lh.size());
	d.me.assign(me.ptr(), me.ptr() + me.size());
	d.bl.assign(bl.ptr(), bl.ptr() + bl.size());
	d.k = int(p_mat->get("k"));
	d.fmt = int(p_mat->get("fmt"));
	ERR_FAIL_COND_V_MSG(d.lay_lohi.size() != d.lay_off.size() * 2 || d.me.size() != d.bl.size() || d.me.empty(), false, "material arrays inconsistent");
	for (size_t i = 0; i < d.lay_off.size(); i++) {
		ERR_FAIL_COND_V_MSG(size_t(d.lay_off[i]) + size_t(d.lay_n[i]) * d.lay_n[i] > d.h16.size(), false, "h16 layer out of range");
	}
	for (size_t m = 0; m < d.me.size() / 4; m++) {
		ERR_FAIL_COND_V_MSG(size_t(d.me[m * 4]) + size_t(std::max(1.0f, d.me[m * 4 + 1])) > d.lay_off.size(), false, "material layers out of range");
	}
	t_.has_mat = true;
	t_.clear_box_cache();
	{
		std::lock_guard<std::mutex> hlock(hz_mutex_);
		hz_grids_.clear();
	}
	return true;
}

bool MarsTerrainCore::configure_scatter(Object *p_scat) {
	ERR_FAIL_NULL_V(p_scat, false);
	std::lock_guard<std::mutex> lock(scatter_mutex_);
	const Array k = p_scat->get("k_cls");
	ERR_FAIL_COND_V(k.size() < 4, false);
	for (int i = 0; i < 4; i++) {
		sc_.k_cls[i] = double(k[i]);
	}
	sc_.nm = int(p_scat->get("nm"));
	const Color base = p_scat->get("base");
	sc_.base[0] = base.r;
	sc_.base[1] = base.g;
	sc_.base[2] = base.b;
	sc_.yr.clear();
	const Array yr = p_scat->get("yr");
	for (int64_t i = 0; i < yr.size(); i++) {
		const Array e = yr[i];
		ERR_FAIL_COND_V_MSG(e.size() < 2, false, "yr entry size < 2");
		sc_.yr.push_back({ double(e[0]), double(e[1]) });
	}
	ERR_FAIL_COND_V_MSG(int(sc_.yr.size()) != sc_.nm, false, "yr.size() != nm");
	sc_.px_min = double(p_scat->get("PX_MIN"));
	const Array px = p_scat->get("px");
	ERR_FAIL_COND_V_MSG(px.size() < 3, false, "px.size() < 3");
	for (int i = 0; i < 3; i++) {
		sc_.px[i] = double(px[i]);
	}
	sc_.setup();
	sc_.clear_cache();
	has_scatter_ = true;
	return true;
}

PackedFloat64Array MarsTerrainCore::geo_w(double p_x, double p_z) const {
	PackedFloat64Array out;
	out.resize(4);
	const std::array<double, 4> w = t_.geo.W(p_x, p_z);
	for (int i = 0; i < 4; i++) {
		out.set(i, w[i]);
	}
	return out;
}

PackedFloat32Array MarsTerrainCore::h_cpu_grid(double p_x0, double p_z0, double p_cell, int p_nx, int p_nz) const {
	PackedFloat32Array out;
	ERR_FAIL_COND_V(p_nx <= 0 || p_nz <= 0, out);
	ERR_FAIL_COND_V(!std::isfinite(p_x0) || !std::isfinite(p_z0) || !(p_cell > 0.0), out);
	out.resize(int64_t(p_nx) * p_nz);
	float *w = out.ptrw();
	// 按行并行（h_cpu 只读）。线程池正被 rock_bucket 占着时不等，在本线程串行算。
	const std::shared_ptr<marsim::ThreadPool> pl = pool();
	pl->try_parallel_for(p_nz, [&](int64_t j) {
		for (int i = 0; i < p_nx; i++) {
			w[j * p_nx + i] = (float)t_.h_cpu(p_x0 + i * p_cell, p_z0 + j * p_cell, 0);
		}
	});
	return out;
}

PackedFloat64Array MarsTerrainCore::select(const Vector3 &p_cam, double p_pixel_angle) {
	// 非有限相机：距离比较全为假，四叉树会一路细分到底（几十万块）
	ERR_FAIL_COND_V_MSG(!p_cam.is_finite() || !std::isfinite(p_pixel_angle) || !(p_pixel_angle > 0.0), PackedFloat64Array(), "select: non-finite camera or pixel_angle");
	std::vector<terrain::LodNode> nodes;
	t_.select(p_cam.x, p_cam.y, p_cam.z, p_pixel_angle, nodes);
	PackedFloat64Array out;
	out.resize(int64_t(nodes.size()) * 6);
	double *w = out.ptrw();
	for (size_t i = 0; i < nodes.size(); i++) {
		const terrain::LodNode &n = nodes[i];
		w[i * 6 + 0] = n.l;
		w[i * 6 + 1] = n.x0;
		w[i * 6 + 2] = n.z0;
		w[i * 6 + 3] = n.hmin;
		w[i * 6 + 4] = n.hmax;
		w[i * 6 + 5] = n.q;
	}
	return out;
}

static PackedFloat32Array to_packed(const std::vector<float> &v) {
	PackedFloat32Array p;
	p.resize(int64_t(v.size()));
	if (!v.empty()) {
		std::copy(v.begin(), v.end(), p.ptrw());
	}
	return p;
}

Array MarsTerrainCore::rock_bucket(const Vector3 &p_cam, double p_pa, double p_budget_ms, const Array &p_fixed) {
	ERR_FAIL_COND_V_MSG(!p_cam.is_finite() || !std::isfinite(p_pa) || !(p_pa > 0.0), Array(), "rock_bucket: non-finite camera or pa");
	std::lock_guard<std::mutex> lock(scatter_mutex_);
	const float cam[3] = { p_cam.x, p_cam.y, p_cam.z };
	const double rk_px[3] = { sc_.px[0], sc_.px[1], sc_.px[2] };
	const int ntypes = int(p_fixed.size());
	const int nout = std::max(ntypes, has_scatter_ ? sc_.nm : 0);
	if (has_scatter_ && sc_.nm > ntypes) {
		WARN_PRINT_ONCE("rock_bucket: scatter has more rock types (nm) than fixed types; extra types are returned at the end");
	}
	std::vector<std::array<std::vector<float>, 3>> out(nout);
	// 实景.gd rock_bucket 的顺序：先固定石块，再撒石区块
	std::vector<float> vp;
	for (int i = 0; i < ntypes; i++) {
		const Dictionary T = p_fixed[i];
		const PackedVector3Array pos = T["pos"];
		const PackedFloat32Array D = T["D"];
		const PackedFloat32Array buf = T["buf"];
		ERR_CONTINUE_MSG(pos.size() != D.size() || buf.size() < D.size() * scatter::FLOATS, "rock_bucket: fixed type has pos/D/buf size mismatch");
		const float *pp;
		if constexpr (sizeof(Vector3) == 3 * sizeof(float)) { // 单精度构建：Vector3 就是连续的 3 个 float，直接用
			pp = reinterpret_cast<const float *>(pos.ptr());
		} else { // precision=double：要转成 float（GDScript 端存进 PackedFloat32Array 时也是这样舍入）
			vp.resize(size_t(pos.size()) * 3);
			for (int64_t k = 0; k < pos.size(); k++) {
				const Vector3 &p = pos[k];
				vp[k * 3] = float(p.x);
				vp[k * 3 + 1] = float(p.y);
				vp[k * 3 + 2] = float(p.z);
			}
			pp = vp.data();
		}
		scatter::bucket_fixed(pp, D.ptr(), buf.ptr(), size_t(D.size()), cam, p_pa, rk_px, out[i]);
	}
	if (has_scatter_) {
		const std::shared_ptr<marsim::ThreadPool> pl = pool();
		sc_.collect(t_, cam, p_pa, p_budget_ms, out, stats_, pl.get());
	}
	Array res;
	for (int i = 0; i < nout; i++) {
		Array lv;
		for (int l = 0; l < 3; l++) {
			lv.push_back(to_packed(out[i][l]));
		}
		res.push_back(lv);
	}
	return res;
}

Dictionary MarsTerrainCore::get_scatter_stats() const {
	std::lock_guard<std::mutex> lock(scatter_mutex_);
	Dictionary d;
	d["tiles"] = stats_.tiles;
	d["rocks"] = stats_.rocks;
	d["generated"] = stats_.generated;
	d["pending"] = stats_.pending;
	Array band, level;
	for (int v : stats_.band) {
		band.push_back(v);
	}
	for (int v : stats_.level) {
		level.push_back(v);
	}
	d["band"] = band;
	d["level"] = level;
	d["cache"] = int64_t(sc_.cache_size());
	return d;
}

void MarsTerrainCore::clear_scatter_cache() {
	std::lock_guard<std::mutex> lock(scatter_mutex_);
	sc_.clear_cache();
}

const std::vector<horizon::Grid> &MarsTerrainCore::hz_grids() const {
	// 每层高度网格 = h_cpu(x, z, kmin = k)：本层（及更粗层）数据 + 地貌印章，和画出来的地面一致
	const terrain::HeightLayers &hl = t_.hl;
	if (int(hz_grids_.size()) == hl.L) {
		return hz_grids_;
	}
	const std::shared_ptr<marsim::ThreadPool> pl = pool();
	std::vector<horizon::Grid> grids(hl.L);
	for (int k = 0; k < hl.L; k++) {
		horizon::Grid &g = grids[k];
		g.N = hl.N;
		g.cell = hl.c0 * std::pow(2.0, k);
		g.half = hl.half0 * std::pow(2.0, k);
		g.h.resize(size_t(g.N) * g.N);
		pl->parallel_for(g.N, [&](int64_t j) {
			for (int i = 0; i < g.N; i++) {
				g.h[size_t(j) * g.N + i] = (float)t_.h_cpu(-g.half + i * g.cell, -g.half + j * g.cell, k);
			}
		});
	}
	hz_grids_ = std::move(grids);
	return hz_grids_;
}

Array MarsTerrainCore::horizon_sun(int p_stride, double p_azimuth, double p_growth, double p_t_max) const {
	Array out;
	const terrain::HeightLayers &hl = t_.hl;
	ERR_FAIL_COND_V_MSG(hl.layers.size() != size_t(hl.L) || hl.L <= 0, out, "horizon_sun：先 configure_heights");
	ERR_FAIL_COND_V(p_stride < 1 || !(p_growth > 0.0) || !(p_t_max > 0.0), out);
	const std::shared_ptr<marsim::ThreadPool> pl = pool();
	auto pf = [&](int64_t n, const std::function<void(int64_t)> &fn) { pl->parallel_for(n, fn); };
	std::lock_guard<std::mutex> hlock(hz_mutex_);
	const std::vector<horizon::Grid> &grids = hz_grids();
	horizon::Params par;
	par.stride = p_stride;
	par.growth = p_growth;
	par.t_max = p_t_max;
	for (int k = 0; k < hl.L; k++) {
		const std::vector<float> a = horizon::sun_level(grids, k, par, p_azimuth, pf);
		PackedFloat32Array b;
		b.resize(int64_t(a.size()));
		std::copy(a.begin(), a.end(), b.ptrw());
		out.push_back(b);
	}
	return out;
}

Array MarsTerrainCore::scatter_rocks(double p_x0, double p_z0, double p_x1, double p_z1, int p_b_min) const {
	Array out;
	std::lock_guard<std::mutex> lock(scatter_mutex_);
	if (!has_scatter_) {
		return out;
	}
	std::vector<std::vector<float>> per(sc_.nm);
	for (int b = std::max(0, p_b_min); b < scatter::NB; b++) {
		const double T = scatter::TILE * scatter::D0 * std::pow(2.0, b);
		const int64_t i0 = (int64_t)std::floor(p_x0 / T), i1 = (int64_t)std::floor(p_x1 / T);
		const int64_t j0 = (int64_t)std::floor(p_z0 / T), j1 = (int64_t)std::floor(p_z1 / T);
		for (int64_t j = j0; j <= j1; j++) {
			for (int64_t i = i0; i <= i1; i++) {
				const scatter::Tile tile = sc_.gen_tile(t_, b, i, j);
				for (const auto &pr : tile) {
					if (pr.first < 0 || pr.first >= sc_.nm) {
						continue;
					}
					const std::vector<float> &v = pr.second;
					for (size_t k = 0; k + scatter::FLOATS <= v.size(); k += scatter::FLOATS) {
						const float x = v[k + 3], z = v[k + 11];
						if (x >= p_x0 && x <= p_x1 && z >= p_z0 && z <= p_z1) {
							per[pr.first].insert(per[pr.first].end(), v.begin() + k, v.begin() + k + scatter::FLOATS);
						}
					}
				}
			}
		}
	}
	for (int ty = 0; ty < sc_.nm; ty++) {
		PackedFloat32Array a;
		a.resize(int64_t(per[ty].size()));
		std::copy(per[ty].begin(), per[ty].end(), a.ptrw());
		out.push_back(a);
	}
	return out;
}

PackedByteArray MarsTerrainCore::rock_occlusion(const Array &p_res, const PackedFloat32Array &p_types, double p_x0, double p_z0, double p_cell, int p_n) const {
	PackedByteArray out;
	ERR_FAIL_COND_V(p_n <= 0 || p_n > 8192 || !(p_cell > 0.0), out);
	ERR_FAIL_COND_V_MSG(p_types.size() < p_res.size() * 6, out, "rock_occlusion：types 要每种 6 个数");
	const double ext = p_n * p_cell;
	// 1 收集压到图上的石块（粗筛：中心离图 ≤ 3 m；细的影响半径在 splat 里算）
	struct Cand {
		float x, y, z, r;
	};
	std::vector<Cand> cand;
	const float *ty = p_types.ptr();
	for (int64_t i = 0; i < p_res.size(); i++) {
		const Array lv = p_res[i];
		const float *t = ty + i * 6;
		for (int64_t l = 0; l < lv.size(); l++) {
			const PackedFloat32Array b = lv[l];
			const float *f = b.ptr();
			for (int64_t k = 0; k + 16 <= b.size(); k += 16) {
				const float *m = f + k; // 行主序 3×4：[b00 b01 b02 ox, b10 b11 b12 oy, b20 b21 b22 oz]
				const float cx = m[0] * t[0] + m[1] * t[1] + m[2] * t[2] + m[3];
				const float cz = m[8] * t[0] + m[9] * t[1] + m[10] * t[2] + m[11];
				if (cx < p_x0 - 3.0 || cx > p_x0 + ext + 3.0 || cz < p_z0 - 3.0 || cz > p_z0 + ext + 3.0) {
					continue;
				}
				const float cy = m[4] * t[0] + m[5] * t[1] + m[6] * t[2] + m[7];
				double rr = 1.0;
				for (int c = 0; c < 3; c++) { // 第 c 根轴 = 第 c 列，乘半尺寸
					rr *= std::sqrt(double(m[c]) * m[c] + double(m[4 + c]) * m[4 + c] + double(m[8 + c]) * m[8 + c]) * t[3 + c];
				}
				cand.push_back({ cx, cy, cz, (float)std::cbrt(rr) }); // 等体积球
			}
		}
	}
	// 2 球心相对地面的高度（h_cpu 只读，可并发）
	std::vector<rockocc::Sphere> sp(cand.size());
	const std::shared_ptr<marsim::ThreadPool> pl = pool();
	const int64_t CH = 1024;
	pl->parallel_for((int64_t(cand.size()) + CH - 1) / CH, [&](int64_t c) {
		for (int64_t k = c * CH; k < std::min<int64_t>(int64_t(cand.size()), (c + 1) * CH); k++) {
			const Cand &q = cand[k];
			sp[k] = { q.x, q.z, (float)(q.y - t_.h_cpu(q.x, q.z, 0)), q.r };
		}
	});
	// 3 写图
	const std::vector<uint8_t> v = rockocc::splat(sp, p_x0, p_z0, p_cell, p_n,
			[&](int64_t n, const std::function<void(int64_t)> &fn) { pl->parallel_for(n, fn); });
	out.resize(int64_t(v.size()));
	std::copy(v.begin(), v.end(), out.ptrw());
	return out;
}

Array MarsTerrainCore::horizon_maps(int p_stride, int p_dirs, double p_growth, double p_t_max) const {
	Array out;
	const terrain::HeightLayers &hl = t_.hl;
	ERR_FAIL_COND_V_MSG(hl.layers.size() != size_t(hl.L) || hl.L <= 0, out, "horizon_maps：先 configure_heights");
	ERR_FAIL_COND_V(p_stride < 1 || p_dirs < 4 || p_dirs % 4 != 0 || !(p_growth > 0.0) || !(p_t_max > 0.0), out);
	const std::shared_ptr<marsim::ThreadPool> pl = pool();
	auto pf = [&](int64_t n, const std::function<void(int64_t)> &fn) { pl->parallel_for(n, fn); };
	std::lock_guard<std::mutex> hlock(hz_mutex_);
	const std::vector<horizon::Grid> &grids = hz_grids();
	// 地平线图，4 个方位一组打包成 RGBA8
	horizon::Params par;
	par.dirs = p_dirs;
	par.stride = p_stride;
	par.growth = p_growth;
	par.t_max = p_t_max;
	const int Q = p_dirs / 4;
	std::vector<Array> qs(Q);
	for (int k = 0; k < hl.L; k++) {
		const std::vector<uint8_t> h = horizon::compute_level(grids, k, par, pf);
		const int n = horizon::level_size(grids[k], p_stride);
		for (int q = 0; q < Q; q++) {
			PackedByteArray b;
			b.resize(int64_t(n) * n * 4);
			uint8_t *w = b.ptrw();
			for (int64_t t = 0; t < int64_t(n) * n; t++) {
				for (int c = 0; c < 4; c++) {
					w[t * 4 + c] = h[size_t(t) * p_dirs + q * 4 + c];
				}
			}
			qs[q].push_back(b);
		}
	}
	for (int q = 0; q < Q; q++) {
		out.push_back(qs[q]);
	}
	return out;
}

PackedFloat32Array MarsTerrainCore::horizon_sky_table(const PackedFloat32Array &p_rgb, int p_w, int p_h, double p_scale, int p_dirs, int p_nb) const {
	PackedFloat32Array out;
	ERR_FAIL_COND_V(p_w <= 0 || p_h <= 0 || p_dirs <= 0 || p_nb < 2, out);
	ERR_FAIL_COND_V_MSG(p_rgb.size() != int64_t(p_w) * p_h * 3, out, "horizon_sky_table：rgb 长度应为 w×h×3");
	const std::vector<float> t = horizon::sky_table(p_rgb.ptr(), p_w, p_h, p_scale, p_dirs, p_nb);
	out.resize(int64_t(t.size()));
	std::copy(t.begin(), t.end(), out.ptrw());
	return out;
}

Array MarsTerrainCore::horizon_irradiance(const Array &p_maps, const PackedFloat32Array &p_table, int p_dirs, int p_nb, bool p_half) const {
	Array out;
	ERR_FAIL_COND_V(p_dirs < 4 || p_dirs % 4 != 0 || p_nb < 2 || p_maps.size() != p_dirs / 4, out);
	ERR_FAIL_COND_V_MSG(p_table.size() != int64_t(p_nb) * p_dirs * 4 * 4, out, "horizon_irradiance：表大小不对");
	const Array q0 = p_maps[0];
	const int L = q0.size();
	const std::shared_ptr<marsim::ThreadPool> pl = pool();
	auto pf = [&](int64_t n, const std::function<void(int64_t)> &fn) { pl->parallel_for(n, fn); };
	Array A, B, C;
	for (int k = 0; k < L; k++) {
		std::vector<PackedByteArray> keep(p_dirs / 4);
		std::vector<const uint8_t *> q(p_dirs / 4);
		int64_t sz = -1;
		for (int g = 0; g < p_dirs / 4; g++) {
			const Array lv = p_maps[g];
			ERR_FAIL_COND_V(lv.size() != L, Array());
			keep[g] = lv[k];
			ERR_FAIL_COND_V(sz >= 0 && keep[g].size() != sz, Array());
			sz = keep[g].size();
			q[g] = keep[g].ptr();
		}
		const int n = (int)std::lround(std::sqrt(double(sz / 4)));
		ERR_FAIL_COND_V(int64_t(n) * n * 4 != sz, Array());
		PackedByteArray a, b, c;
		const int64_t nf = int64_t(n) * n * 4;
		if (!p_half) {
			a.resize(nf * 4);
			b.resize(nf * 4);
			c.resize(nf * 4);
			horizon::irradiance_level(q, n, p_dirs, p_table.ptr(), p_nb, (float *)a.ptrw(), (float *)b.ptrw(), (float *)c.ptrw(), pf);
		} else {
			std::vector<float> fa(nf), fb(nf), fc(nf);
			horizon::irradiance_level(q, n, p_dirs, p_table.ptr(), p_nb, fa.data(), fb.data(), fc.data(), pf);
			const std::vector<float> *src[3] = { &fa, &fb, &fc };
			PackedByteArray *dst[3] = { &a, &b, &c };
			for (int s = 0; s < 3; s++) {
				dst[s]->resize(nf * 2);
				uint16_t *o = (uint16_t *)dst[s]->ptrw();
				const float *f = src[s]->data();
				pf((nf + 65535) / 65536, [&](int64_t blk) {
					for (int64_t i = blk * 65536; i < std::min(nf, (blk + 1) * 65536); i++) {
						o[i] = horizon::to_half(f[i]);
					}
				});
			}
		}
		A.push_back(a);
		B.push_back(b);
		C.push_back(c);
	}
	out.push_back(A);
	out.push_back(B);
	out.push_back(C);
	return out;
}
