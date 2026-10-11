#include "rock_occlusion.h"

#include <algorithm>
#include <cmath>

namespace rockocc {

static constexpr double PI = 3.14159265358979323846;

double sphere_occ(double dx, double dy, double dz, double r) {
	const double l = std::sqrt(dx * dx + dy * dy + dz * dz);
	if (l < 1e-9) {
		return 1.0;
	}
	const double nl = dy / l;
	const double h = std::max(l / r, 1.0001);
	const double h2 = h * h;
	const double k2 = 1.0 - h2 * nl * nl;
	double res = std::max(0.0, nl) / h2;
	if (k2 > 0.001) {
		const double s = std::sqrt((h2 - 1.0) / std::max(1.0 - nl * nl, 1e-6));
		res = nl * std::acos(std::clamp(-nl * s, -1.0, 1.0)) - std::sqrt(k2 * (h2 - 1.0));
		res = res / h2 + std::atan(std::sqrt(k2 / (h2 - 1.0)));
		res /= PI;
	}
	return std::clamp(res, 0.0, 1.0);
}

double reach(const Sphere &s) {
	// 远处 occ ≈ r²·y/d³（球在地平线以上）或更小：d³ = r²·max(y, r)/ε，ε = 1/400
	const double y = std::max((double)s.y, (double)s.r);
	return std::max(1.5 * s.r, std::cbrt(400.0 * s.r * s.r * y));
}

std::vector<uint8_t> splat(const std::vector<Sphere> &p_s, double p_x0, double p_z0, double p_cell, int p_n,
		const std::function<void(int64_t, const std::function<void(int64_t)> &)> &p_for) {
	const int n = p_n;
	std::vector<uint8_t> out((size_t)n * n, 255);
	// 按行分带：每带只看压到它的球
	const int BAND = 32;
	const int nb = (n + BAND - 1) / BAND;
	std::vector<std::vector<int>> band(nb);
	std::vector<float> R(p_s.size());
	for (size_t k = 0; k < p_s.size(); k++) {
		const Sphere &s = p_s[k];
		if (!(s.r > 0.0f)) {
			continue;
		}
		R[k] = (float)reach(s);
		const double j0 = (s.z - R[k] - p_z0) / p_cell - 0.5, j1 = (s.z + R[k] - p_z0) / p_cell - 0.5;
		const double i0 = (s.x - R[k] - p_x0) / p_cell - 0.5, i1 = (s.x + R[k] - p_x0) / p_cell - 0.5;
		if (j1 < 0 || j0 > n - 1 || i1 < 0 || i0 > n - 1) {
			continue;
		}
		const int b0 = std::max(0, (int)std::floor(j0) / BAND), b1 = std::min(nb - 1, (int)std::ceil(j1) / BAND);
		for (int b = b0; b <= b1; b++) {
			band[b].push_back((int)k);
		}
	}
	auto do_band = [&](int64_t b) {
		const int jb0 = (int)b * BAND, jb1 = std::min(n, jb0 + BAND);
		std::vector<float> acc((size_t)(jb1 - jb0) * n, 0.0f); // Σ −log(1 − occ)
		for (int k : band[b]) {
			const Sphere &s = p_s[k];
			const double rr = R[k];
			const int j0 = std::max(jb0, (int)std::ceil((s.z - rr - p_z0) / p_cell - 0.5));
			const int j1 = std::min(jb1 - 1, (int)std::floor((s.z + rr - p_z0) / p_cell - 0.5));
			for (int j = j0; j <= j1; j++) {
				const double pz = p_z0 + (j + 0.5) * p_cell, dz = s.z - pz;
				const double w = std::sqrt(std::max(0.0, rr * rr - dz * dz));
				const int i0 = std::max(0, (int)std::ceil((s.x - w - p_x0) / p_cell - 0.5));
				const int i1 = std::min(n - 1, (int)std::floor((s.x + w - p_x0) / p_cell - 0.5));
				float *a = acc.data() + (size_t)(j - jb0) * n;
				for (int i = i0; i <= i1; i++) {
					const double px = p_x0 + (i + 0.5) * p_cell;
					const double o = sphere_occ(s.x - px, s.y, dz, s.r);
					a[i] += (float)-std::log(std::max(1.0 - o, 1e-4));
				}
			}
		}
		for (int j = jb0; j < jb1; j++) {
			const float *a = acc.data() + (size_t)(j - jb0) * n;
			uint8_t *o = out.data() + (size_t)j * n;
			for (int i = 0; i < n; i++) {
				o[i] = (uint8_t)std::lround(255.0 * std::exp(-(double)a[i]));
			}
		}
	};
	if (p_for) {
		p_for(nb, do_band);
	} else {
		for (int64_t b = 0; b < nb; b++) {
			do_band(b);
		}
	}
	return out;
}

} // namespace rockocc
