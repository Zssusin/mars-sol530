#include "horizon.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace horizon {

static constexpr double PI = 3.14159265358979323846;

double Grid::sample(double x, double z) const {
	const double fx = std::clamp((x + half) / cell, 0.0, N - 1.001);
	const double fz = std::clamp((z + half) / cell, 0.0, N - 1.001);
	const int i = (int)fx, j = (int)fz;
	const double tx = fx - i, tz = fz - j;
	const float *a = h.data() + (size_t)j * N + i;
	const double top = a[0] + (a[1] - a[0]) * tx;
	const double bot = a[N] + (a[N + 1] - a[N]) * tx;
	return top + (bot - top) * tz;
}

bool Grid::inside(double x, double z) const {
	const double e = 0.98 * half;
	return std::fabs(x) <= e && std::fabs(z) <= e;
}

int level_size(const Grid &p_grid, int p_stride) {
	return (p_grid.N - 1) / p_stride + 1;
}

// 从 (x, z)（高 h0，第 p_k 层）沿 (dx, dz) 步进，返回最大的 tan 仰角（扣曲率）。越远步长越大、取越粗的层。
static double march(const std::vector<Grid> &p_grids, int p_k, double x, double z, double h0, double dx, double dz, const Params &p_par) {
	const int L = (int)p_grids.size();
	const double inv2R = 0.5 / p_par.planet_radius;
	double best = std::tan(TH_MIN);
	double t = p_grids[p_k].cell;
	int lv = p_k;
	while (t < p_par.t_max) {
		const double step = std::max(p_grids[p_k].cell, p_par.growth * t);
		const double px = x + t * dx, pz = z + t * dz;
		while (lv + 1 < L && p_grids[lv].cell < 0.5 * step) {
			lv++; // 越远越粗（格距 ≈ 步长一半）
		}
		int s = lv;
		while (s < L && !p_grids[s].inside(px, pz)) {
			s++; // 本层装不下就去更粗的层
		}
		if (s >= L) {
			break; // 出了最外一层
		}
		const double tn = (p_grids[s].sample(px, pz) - h0 - t * t * inv2R) / t;
		best = std::max(best, tn);
		t += step;
	}
	return best;
}

template <typename T, typename F>
static std::vector<T> per_texel(const std::vector<Grid> &p_grids, int p_k, const Params &p_par, int p_per, T p_fill, F p_fn,
		const std::function<void(int64_t, const std::function<void(int64_t)> &)> &p_for) {
	const Grid &g = p_grids[p_k];
	const int n = level_size(g, p_par.stride);
	std::vector<T> out((size_t)n * n * p_per, p_fill);
	const double skip = p_k > 0 ? p_par.skip_inner * g.half : -1.0;
	auto row = [&](int64_t j) {
		const double z = -g.half + (double)j * p_par.stride * g.cell;
		for (int i = 0; i < n; i++) {
			const double x = -g.half + (double)i * p_par.stride * g.cell;
			if (std::max(std::fabs(x), std::fabs(z)) < skip) {
				continue;
			}
			p_fn(x, z, g.sample(x, z), out.data() + ((size_t)j * n + i) * p_per);
		}
	};
	if (p_for) {
		p_for(n, row);
	} else {
		for (int64_t j = 0; j < n; j++) {
			row(j);
		}
	}
	return out;
}

std::vector<uint8_t> compute_level(const std::vector<Grid> &p_grids, int p_k, const Params &p_par,
		const std::function<void(int64_t, const std::function<void(int64_t)> &)> &p_for) {
	const int D = p_par.dirs;
	std::vector<double> dx(D), dz(D);
	for (int d = 0; d < D; d++) {
		const double a = 2.0 * PI * d / D; // 自北顺时针
		dx[d] = std::sin(a);
		dz[d] = -std::cos(a);
	}
	return per_texel<uint8_t>(p_grids, p_k, p_par, D, encode(0.0), [&](double x, double z, double h0, uint8_t *o) {
		for (int d = 0; d < D; d++) {
			o[d] = encode(std::atan(march(p_grids, p_k, x, z, h0, dx[d], dz[d], p_par)));
		} }, p_for);
}

std::vector<float> sun_level(const std::vector<Grid> &p_grids, int p_k, const Params &p_par, double p_azimuth,
		const std::function<void(int64_t, const std::function<void(int64_t)> &)> &p_for) {
	const double dx = std::sin(p_azimuth), dz = -std::cos(p_azimuth);
	return per_texel<float>(p_grids, p_k, p_par, 1, 0.0f, [&](double x, double z, double h0, float *o) {
		o[0] = (float)std::atan(march(p_grids, p_k, x, z, h0, dx, dz, p_par)); }, p_for);
}

std::vector<float> sky_table(const float *p_rgb, int p_w, int p_h, double p_scale, int p_dirs, int p_nb) {
	// 每行先按扇区累加 4 个向量（R、G、B 的 L·ω dΩ 和几何的 ω dΩ），再按仰角从高到低做后缀和。
	const int D = p_dirs;
	std::vector<double> rowacc((size_t)p_h * D * 12, 0.0);
	std::vector<double> el(p_h);
	const double dphi = 2.0 * PI / p_w, dth = PI / p_h;
	for (int j = 0; j < p_h; j++) {
		el[j] = (0.5 - (j + 0.5) / p_h) * PI;
		const double ce = std::cos(el[j]), se = std::sin(el[j]);
		const double dO = dphi * dth * ce;
		double *ra = rowacc.data() + (size_t)j * D * 12;
		for (int i = 0; i < p_w; i++) {
			const double phi = (0.5 - (i + 0.5) / p_w) * 2.0 * PI; // atan2(北, 东)
			const double east = ce * std::cos(phi), north = ce * std::sin(phi);
			const double w[3] = { east, se, -north }; // Godot (x, y, z)
			double az = std::atan2(east, north); // 自北顺时针
			if (az < 0.0) {
				az += 2.0 * PI;
			}
			const int k = (int)std::lround(az / (2.0 * PI / D)) % D;
			const float *L = p_rgb + ((size_t)j * p_w + i) * 3;
			double *r = ra + (size_t)k * 12;
			for (int c = 0; c < 3; c++) {
				const double l = L[c] * p_scale * dO;
				r[c * 3 + 0] += l * w[0];
				r[c * 3 + 1] += l * w[1];
				r[c * 3 + 2] += l * w[2];
			}
			r[9] += dO * w[0];
			r[10] += dO * w[1];
			r[11] += dO * w[2];
		}
	}
	std::vector<float> out((size_t)p_nb * D * 4 * 4, 0.0f);
	for (int k = 0; k < D; k++) {
		for (int b = 0; b < p_nb; b++) {
			const double th = TH_MIN + (TH_MAX - TH_MIN) * b / (p_nb - 1);
			double acc[12] = {};
			for (int j = 0; j < p_h && el[j] > th; j++) { // 第 0 行是天顶，仰角递减
				const double *r = rowacc.data() + ((size_t)j * D + k) * 12;
				for (int q = 0; q < 12; q++) {
					acc[q] += r[q];
				}
			}
			for (int c = 0; c < 4; c++) {
				float *o = out.data() + (((size_t)(k * 4 + c)) * p_nb + b) * 4;
				o[0] = (float)acc[c * 3 + 0];
				o[1] = (float)acc[c * 3 + 1];
				o[2] = (float)acc[c * 3 + 2];
				o[3] = 0.0f;
			}
		}
	}
	return out;
}

void irradiance_level(const std::vector<const uint8_t *> &p_q, int p_n, int p_dirs, const float *p_table, int p_nb,
		float *r_a, float *r_b, float *r_c,
		const std::function<void(int64_t, const std::function<void(int64_t)> &)> &p_for) {
	auto row = [&](int64_t j) {
		for (int i = 0; i < p_n; i++) {
			const size_t t = (size_t)j * p_n + i;
			double w[4][3] = {};
			for (int k = 0; k < p_dirs; k++) {
				const double b = p_q[k / 4][t * 4 + (k % 4)] / 255.0 * (p_nb - 1); // 编码和表的档对齐
				const int b0 = std::min((int)b, p_nb - 2);
				const double f = b - b0;
				for (int c = 0; c < 4; c++) {
					const float *e = p_table + (((size_t)(k * 4 + c)) * p_nb + b0) * 4;
					for (int x = 0; x < 3; x++) {
						w[c][x] += e[x] + (e[4 + x] - e[x]) * f;
					}
				}
			}
			float *outs[3] = { r_a + t * 4, r_b + t * 4, r_c + t * 4 };
			for (int c = 0; c < 3; c++) {
				outs[c][0] = (float)w[c][0];
				outs[c][1] = (float)w[c][1];
				outs[c][2] = (float)w[c][2];
				outs[c][3] = (float)w[3][c];
			}
		}
	};
	if (p_for) {
		p_for(p_n, row);
	} else {
		for (int64_t j = 0; j < p_n; j++) {
			row(j);
		}
	}
}

uint16_t to_half(float p_f) {
	uint32_t x;
	std::memcpy(&x, &p_f, 4);
	const uint16_t sign = (uint16_t)((x >> 16) & 0x8000u);
	const uint32_t ax = x & 0x7fffffffu;
	if (ax >= 0x7f800000u) { // inf / nan
		return sign | 0x7c00u | (ax > 0x7f800000u ? 0x200u : 0u);
	}
	if (ax >= 0x477ff000u) { // ≥ 65520 → 舍入后溢出
		return sign | 0x7c00u;
	}
	if (ax < 0x38800000u) { // 次正规数（< 2^−14）
		if (ax < 0x33000000u) {
			return sign; // < 2^−25：舍成 0
		}
		const uint32_t m = (ax & 0x7fffffu) | 0x800000u;
		const int sh = 126 - (int)(ax >> 23); // 14..24
		uint32_t h = m >> (sh);
		const uint32_t rem = m & ((1u << sh) - 1u), half = 1u << (sh - 1);
		if (rem > half || (rem == half && (h & 1u))) {
			h++;
		}
		return sign | (uint16_t)h;
	}
	uint32_t h = ((ax - 0x38000000u) >> 13); // 重设指数偏置
	const uint32_t rem = ax & 0x1fffu;
	if (rem > 0x1000u || (rem == 0x1000u && (h & 1u))) {
		h++; // 进位可能进到指数，正好对
	}
	return sign | (uint16_t)h;
}

} // namespace horizon
