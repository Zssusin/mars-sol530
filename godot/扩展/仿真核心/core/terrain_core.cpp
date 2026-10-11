#include "terrain_core.h"

#include "godot_compat.h"

#include <algorithm>
#include <cmath>
#include <limits>

using namespace gdc;

namespace terrain {

// ———— 材质.gd disp()（= 着色器/材质.gdshaderinc mat_disp(xz, 0, true)）
namespace {
inline uint32_t mh(uint32_t x) {
	x ^= x >> 16;
	x *= 0x7feb352du;
	x ^= x >> 15;
	x *= 0x5bd1e995u;
	x ^= x >> 16;
	return x;
}
inline double mu(uint32_t h) { return (double)(h >> 8) / 16777216.0; }
inline double region_(double e, double h, double f) { return std::min(std::max((h * 0.97 - e) / (h * f), 0.0), 1.0); }

struct Tab {
	int fmt = 0; // 控制图格式：0 = 旧 3 槽，4 = 中景版 4 槽（4 位号、4 位权）
	int id[4] = { -1, -1, -1, -1 };
	double w[4] = { 0.0, 0.0, 0.0, 0.0 };
	void put(int m, double x) {
		if (x <= 0.0) return;
		for (int i = 0; i < 4; i++) {
			if (id[i] == m) {
				w[i] += x;
				return;
			}
		}
		if (w[0] <= w[1] && w[0] <= w[2] && w[0] <= w[3]) {
			if (x > w[0]) { id[0] = m; w[0] = x; }
		} else if (w[1] <= w[2] && w[1] <= w[3]) {
			if (x > w[1]) { id[1] = m; w[1] = x; }
		} else if (w[2] <= w[3]) {
			if (x > w[2]) { id[2] = m; w[2] = x; }
		} else if (x > w[3]) {
			id[3] = m;
			w[3] = x;
		}
	}
	void texel(uint32_t u, double bw) {
		if (fmt == 4) {
			const double q0 = (double)((u >> 16) & 15u), q1 = (double)((u >> 20) & 15u), q2 = (double)((u >> 24) & 15u), s4 = bw / 15.0;
			put((int)(u & 15u), s4 * q0);
			put((int)((u >> 4) & 15u), s4 * q1);
			put((int)((u >> 8) & 15u), s4 * q2);
			put((int)((u >> 12) & 15u), s4 * (15.0 - q0 - q1 - q2));
			return;
		}
		const double w0 = (double)((u >> 15) & 63u), w1 = (double)((u >> 21) & 63u), s = bw / 63.0;
		put((int)(u & 31u), s * w0);
		put((int)((u >> 5) & 31u), s * w1);
		put((int)((u >> 10) & 31u), s * (63.0 - w0 - w1));
	}
	void bilin(const std::vector<uint32_t> &c, int n, double x, double z, double hf, double cs, double bw) {
		const double fx = (x + hf) / cs - 0.5, fz = (z + hf) / cs - 0.5;
		const double ix = std::floor(fx), iz = std::floor(fz), ax = fx - ix, az = fz - iz;
		auto cl = [n](int64_t v) { return (int)std::min<int64_t>(std::max<int64_t>(v, 0), n - 1); };
		const int px = cl((int64_t)ix), pz = cl((int64_t)iz), qx = cl((int64_t)ix + 1), qz = cl((int64_t)iz + 1);
		texel(c[size_t(pz) * n + px], bw * (1.0 - ax) * (1.0 - az));
		texel(c[size_t(pz) * n + qx], bw * ax * (1.0 - az));
		texel(c[size_t(qz) * n + px], bw * (1.0 - ax) * az);
		texel(c[size_t(qz) * n + qx], bw * ax * az);
	}
};
} // namespace

double MatDisp::gate_at(double x, double z) const {
	if (std::max(std::fabs(x), std::fabs(z)) >= grid[0]) return 1.0;
	const double cs = 2.0 * grid[0] / nG;
	const double fx = (x + grid[0]) / cs - 0.5, fz = (z + grid[0]) / cs - 0.5;
	const double ix = std::floor(fx), iz = std::floor(fz), ax = fx - ix, az = fz - iz;
	auto cl = [this](int64_t v) { return (int)std::min<int64_t>(std::max<int64_t>(v, 0), nG - 1); };
	const int px = cl((int64_t)ix), pz = cl((int64_t)iz), qx = cl((int64_t)ix + 1), qz = cl((int64_t)iz + 1);
	auto g = [this](int i, int j) { return gate[size_t(j) * nG + i] / 255.0; };
	return lerpf(lerpf(g(px, pz), g(qx, pz), ax), lerpf(g(px, qz), g(qx, qz), ax), az);
}

double MatDisp::disp(double x, double z) const {
	if (gain <= 0.0 || !std::isfinite(x) || !std::isfinite(z)) return 0.0;
	const double g = gate_at(x, z);
	if (g <= 0.0) return 0.0;
	Tab T;
	T.fmt = fmt;
	const double e = std::max(std::fabs(x), std::fabs(z));
	const double a = region_(e, grid[0], 0.05), b = (1.0 - a) * region_(e, grid[2], 0.05);
	if (a > 0.0) T.bilin(ctrl_n, nN, x, z, grid[0], grid[1], a);
	if (b > 0.0) T.bilin(ctrl_f, nF, x, z, grid[2], grid[3], b);
	const double o = 1.0 - a - b;
	if (o > 0.0) {
		for (int i = 0; i < 4; i++) {
			if (out_id[i] >= 0) T.put(out_id[i], o * out_w[i]);
		}
	}
	// 前 k
	for (int r = 0; r < 2; r++) {
		int nz = 0;
		for (int i = 0; i < 4; i++) nz += T.w[i] > 0.0;
		if (nz <= k) break;
		double t[4], mn = 1e300;
		for (int i = 0; i < 4; i++) {
			t[i] = T.w[i] > 0.0 ? T.w[i] : 1e9;
			mn = std::min(mn, t[i]);
		}
		for (int i = 0; i < 4; i++) {
			if (t[i] == mn) {
				T.w[i] = 0.0;
				break;
			}
		}
	}
	double s = std::max(T.w[0] + T.w[1] + T.w[2] + T.w[3], 1e-9);
	for (int i = 0; i < 4; i++) T.w[i] = T.w[i] / s >= 0.02 ? T.w[i] / s : 0.0;
	s = std::max(T.w[0] + T.w[1] + T.w[2] + T.w[3], 1e-9);
	for (int i = 0; i < 4; i++) T.w[i] /= s;

	// 压到前 3 项（同 mat_pack3）
	if (T.w[3] > 0.0) {
		const int z3 = T.w[0] <= 0.0 ? 0 : (T.w[1] <= 0.0 ? 1 : 2);
		T.id[z3] = T.id[3];
		T.w[z3] = T.w[3];
	}
	// 三角格（世界坐标，格距 hexp[0]）
	const double px = x, py = -z, cell = hexp[0];
	const double su = px / cell, sv = py / cell;
	const double kx = su - 0.57735027 * sv, ky = 1.15470054 * sv;
	const double bx = std::floor(kx), by = std::floor(ky), fx = kx - bx, fy = ky - by;
	const double zz = 1.0 - fx - fy;
	const int sI = zz <= 0.0 ? 1 : 0;
	const double sf = sI, s2 = 2.0 * sf - 1.0;
	double W[3] = { std::pow(clampf(-zz * s2, 0.0, 1.0), hexp[1]), std::pow(clampf(sf - fy * s2, 0.0, 1.0), hexp[1]), std::pow(clampf(sf - fx * s2, 0.0, 1.0), hexp[1]) };
	const double ws = W[0] + W[1] + W[2];
	const int ib = (int)bx, jb = (int)by;
	const int vx[3] = { ib + sI, ib + sI, ib + 1 - sI }, vy[3] = { jb + sI, jb + 1 - sI, jb + sI };
	double qx[3], qy[3], qc[3], qs[3];
	uint32_t qh[3];
	for (int i = 0; i < 3; i++) {
		qh[i] = mh(((uint32_t)vx[i] * 0x27d4eb2du) ^ mh((uint32_t)vy[i]));
		const double ang = (double)((qh[i] >> 20) & 255u) * (6.2831853 / 256.0);
		qc[i] = std::cos(ang);
		qs[i] = std::sin(ang);
		qx[i] = px - (vx[i] + 0.5 * vy[i]) * cell;
		qy[i] = py - 0.8660254 * vy[i] * cell;
	}
	double tot = 0.0, hs = 0.0;
	for (int j = 0; j < 3; j++) {
		if (T.w[j] <= 0.0) continue;
		const int m = T.id[j];
		const float *M = &me[size_t(m) * 4], *B = &bl[size_t(m) * 4];
		const bool rot = B[3] > 0.5f;
		double acc[3] = { 0.0, 0.0, 0.0 };
		for (int i = 0; i < 3; i++) {
			const double Wi = W[i] / ws;
			if (Wi < 0.005) continue;
			const uint32_t h = qh[i];
			const double c = rot ? qc[i] : 1.0, sn = rot ? qs[i] : 0.0;
			const uint32_t nv = (uint32_t)std::max((int)M[1], 1);
			const int L = (int)M[0] + (fmt == 4 ? (int)(((mh(h ^ 0x68e31da4u) >> 16) * nv) >> 16) : (int)((h >> 28) % nv));
			const double u = (c * qx[i] - sn * qy[i]) / M[2] + (double)(h & 1023u) / 1024.0;
			const double v = (sn * qx[i] + c * qy[i]) / M[2] + (double)((h >> 10) & 1023u) / 1024.0;
			// R16 双线性，重复寻址（同 GPU：像素中心 (i + ½)/n）
			const int n = lay_n[L];
			const uint16_t *H = &h16[size_t(lay_off[L])];
			const double fxx = u * n - 0.5, fyy = v * n - 0.5;
			const double ixx = std::floor(fxx), iyy = std::floor(fyy), tx = fxx - ixx, ty = fyy - iyy;
			auto wr = [n](int64_t q) { int64_t r = q % n; return (int)(r < 0 ? r + n : r); };
			const int x0 = wr((int64_t)ixx), x1 = wr((int64_t)ixx + 1), y0 = wr((int64_t)iyy), y1 = wr((int64_t)iyy + 1);
			const double t = lerpf(lerpf(H[size_t(y0) * n + x0], H[size_t(y0) * n + x1], tx), lerpf(H[size_t(y1) * n + x0], H[size_t(y1) * n + x1], tx), ty) / 65535.0;
			const double hh = (t - 0.5) * 2.0 * M[3];
			const double lo = lay_lohi[size_t(L) * 2], hi = lay_lohi[size_t(L) * 2 + 1];
			const double al = clampf((hh - lo) / (hi - lo), 0.0, 1.0);
			const double wi = Wi * lerpf(1.0, al, hexp[2]);
			acc[0] += wi * hh;
			acc[1] += wi * al;
			acc[2] += wi;
		}
		const double bb = T.w[j] * std::exp((B[0] * g * (acc[1] / acc[2] - 0.5) + B[1]) / hexp[3]);
		tot += bb;
		hs += bb * acc[0] / acc[2];
	}
	return gain * g * hs / tot;
}

// ———— 地形LOD.gd h_level / h_data
double HeightLayers::h_level(double x, double z, int k) const {
	if (!std::isfinite(x) || !std::isfinite(z)) { // (int64_t)NaN 在 x86-64 上是 INT64_MIN → 越界读；有限输入不受影响，对拍不变
		return std::numeric_limits<double>::quiet_NaN();
	}
	const double c = c0 * pw(2.0, k);
	const double h = half0 * pw(2.0, k);
	const double fx = clampf((x + h) / c, 0.0, N - 1.001);
	const double fz = clampf((z + h) / c, 0.0, N - 1.001);
	const int64_t i = (int64_t)fx, j = (int64_t)fz;
	const double tx = fx - i, tz = fz - j;
	const std::vector<float> &a = layers[k];
	const int64_t o = j * N + i;
	return lerpf(lerpf(a[o], a[o + 1], tx), lerpf(a[o + N], a[o + N + 1], tx), tz);
}

double HeightLayers::h_data(double x, double z, int kmin) const {
	const double e = maxf(std::fabs(x), std::fabs(z));
	const double k0 = maxf(0.0, std::ceil(lg(maxf(e, 1e-6) / (half0 * 0.98)) / lg(2.0)));
	const double hk = half0 * pw(2.0, k0);
	const double kf = minf(maxf(k0 + clampf((e - 0.9 * hk) / (0.08 * hk), 0.0, 1.0), (double)kmin), L - 1.0);
	const int k = (int)kf;
	const double t = kf - k;
	double a = h_level(x, z, k);
	if (t > 0.0) {
		a = lerpf(a, h_level(x, z, k + 1), t);
	}
	return a;
}

// ———— 地貌.gd
static const double W0[4] = { 0.35, 0.35, 0.2, 0.1 };

static inline double s_(double e, double h) { return smoothstep(0.92 * h, h, e); }

uint32_t GeoStamps::ih(uint32_t x) {
	x ^= x >> 16;
	x *= 0x7feb352du;
	x ^= x >> 15;
	x *= 0x5bd1e995u;
	x ^= x >> 16;
	return x;
}

double GeoStamps::dem_l(double x, double z, double l_hirise) const {
	const double e = maxf(std::fabs(x), std::fabs(z));
	double l = -5.643856;
	l = lerpf(l, -3.321928, s_(e, 10.0));
	l = lerpf(l, l_hirise, s_(e, 50.0));
	l = lerpf(l, 4.321928, s_(e, 1000.0));
	return l;
}

std::array<double, 4> GeoStamps::W(double x, double z) const {
	if (!std::isfinite(x) || !std::isfinite(z)) {
		const double nan = std::numeric_limits<double>::quiet_NaN();
		return { nan, nan, nan, nan };
	}
	const double fx = clampf((x + c_half) / c_cs - 0.5, 0.0, cN - 1.001);
	const double fz = clampf((z + c_half) / c_cs - 0.5, 0.0, cN - 1.001);
	const int64_t i = (int64_t)fx, j = (int64_t)fz;
	const double tx = fx - i, tz = fz - j;
	const int64_t o = (j * cN + i) * 4;
	std::array<double, 4> r = { 0.0, 0.0, 0.0, 0.0 };
	const double t = s_(maxf(std::fabs(x), std::fabs(z)), c_half);
	const int64_t row = (int64_t)cN * 4;
	for (int ch = 0; ch < 4; ch++) {
		const double v = lerpf(lerpf(cls[o + ch], cls[o + 4 + ch], tx), lerpf(cls[o + row + ch], cls[o + row + 4 + ch], tx), tz) / 255.0;
		r[ch] = lerpf(v, W0[ch], t);
	}
	return r;
}

double GeoStamps::craters(double x, double z, double dl, const std::array<double, 4> &w) const {
	double acc = 0.0;
	const double nb = 1.0 - pw(2.0, -b);
	const double cf = (w[0] * cr_cls[0] + w[1] * cr_cls[1] + w[2] * cr_cls[2] + w[3] * cr_cls[3]) / maxf(w[0] + w[1] + w[2] + w[3], 1e-4);
	for (int o = 0; o < 7; o++) {
		const double Do = 0.5 * pw(2.0, o);
		const double k = clampf(dl + 2.0 - lg(Do) / lg(2.0), 0.0, 1.0);
		if (k <= 0.0) {
			continue;
		}
		const double Cs = 4.0 * Do;
		const double p = C * pw(Do, -b) * nb * Cs * Cs * cf;
		const int64_t i0 = floori(x / Cs - 0.5), j0 = floori(z / Cs - 0.5);
		for (int j = 0; j < 2; j++) {
			for (int i = 0; i < 2; i++) {
				const int64_t ci = i0 + i, cj = j0 + j;
				const uint32_t h = ih(((uint32_t)ci * 0x27d4eb2du) ^ ih((uint32_t)cj + (uint32_t)o * 0x165667b1u));
				if (u(h) >= p) {
					continue;
				}
				const double cx = (ci + u(ih(h ^ 1))) * Cs, cz = (cj + u(ih(h ^ 2))) * Cs;
				const double Dm = Do * pw(1.0 - u(ih(h ^ 3)) * nb, -1.0 / b);
				const double R = 0.5 * Dm;
				const double r = len2f((float)(x - cx), (float)(z - cz)); // Vector2(…).length()：float
				if (r >= 2.0 * R) {
					continue;
				}
				const double deg = std::sqrt(u(ih(h ^ 4)));
				const double dp = Dm * lerpf(dD_fresh, dD_old, deg), hr = Dm * rim * (1.0 - deg);
				const double xr = r / R;
				double hg;
				if (xr < 1.0) {
					hg = maxf((dp + hr) * xr * xr - dp, -dp * (1.0 - fill * deg));
				} else {
					const double s = clampf((xr - 1.4) / 0.6, 0.0, 1.0);
					hg = hr / (xr * xr * xr) * (1.0 - s * s * (3.0 - 2.0 * s));
				}
				acc += k * hg;
			}
		}
	}
	return acc;
}

double GeoStamps::ripples(double x, double z, double dl, const std::array<double, 4> &w) const {
	const double ws = smoothstep(0.3, 0.7, w[0]);
	if (ws <= 0.0) {
		return 0.0;
	}
	double acc = 0.0;
	for (const Ripple &e : rp) {
		const double lam = e.lambda;
		const double k = ws * clampf(dl + 1.321928 - lg(lam) / lg(2.0), 0.0, 1.0);
		if (k <= 0.0) {
			continue;
		}
		const double dx = e.dir_x, dz = e.dir_z;
		const double px = -dz, pz = dx, qx = px * 0.8 + dx * 0.6, qz = pz * 0.8 + dz * 0.6;
		const double s1 = TAU * fposmod((x * px + z * pz) / (5.3 * lam), 1.0), s2 = TAU * fposmod((x * qx + z * qz) / (11.7 * lam), 1.0);
		const double s3 = TAU * fposmod((x * px + z * pz) / (7.1 * lam), 1.0);
		const double ph = (x * dx + z * dz) / lam + e.sinuosity * (sn(s1) + 0.5 * sn(s2));
		const double am = e.amp * (0.75 + 0.25 * sn(s3));
		const double t = fposmod(ph, 1.0), Lf = e.lee;
		double f;
		if (t < 1.0 - Lf) {
			f = pw(sn(PI / 2 * t / (1.0 - Lf)), 2);
		} else {
			f = pw(cs(PI / 2 * (t - 1.0 + Lf) / Lf), 2);
		}
		acc += k * am * (f - 0.5);
	}
	return acc;
}

// 地貌.gd rfield：实测沙纹场（4 格平面波相量相加取相位，套不对称剖面；相干度低处渐隐）
double GeoStamps::rfield(double x, double z, double dl) const {
	if (rf_on <= 0.0) {
		return 0.0;
	}
	if (!std::isfinite(x) || !std::isfinite(z)) {
		return std::numeric_limits<double>::quiet_NaN();
	}
	const double fx = (x + rf_half) / rf_cell - 0.5, fz = (z + rf_half) / rf_cell - 0.5;
	const int64_t i0 = floori(fx), j0 = floori(fz);
	const double tx = fx - i0, tz = fz - j0;
	double zr = 0.0, zi = 0.0, As = 0.0, Ls = 0.0;
	for (int dj = 0; dj < 2; dj++) {
		for (int di = 0; di < 2; di++) {
			const int64_t i = clampi(i0 + di, 0, rf_N - 1), j = clampi(j0 + dj, 0, rf_N - 1);
			const int64_t o = (j * rf_N + i) * 4;
			const double a = rf[o + 3] / 255.0;
			if (a <= 0.0) {
				continue;
			}
			const double w = (di == 1 ? tx : 1.0 - tx) * (dj == 1 ? tz : 1.0 - tz);
			const double az = rf[o] * (TAU / 256.0);
			const double lam = rf_lo * pw(rf_hi / rf_lo, rf[o + 1] / 255.0);
			const double ph = rf[o + 2] * (TAU / 256.0);
			const double cx = -rf_half + (i + 0.5) * rf_cell, cz = -rf_half + (j + 0.5) * rf_cell;
			const double psi = ph + TAU / lam * (sn(az) * (x - cx) - cs(az) * (z - cz));
			zr += w * a * cs(psi);
			zi += w * a * sn(psi);
			As += w * a;
			Ls += w * a * lg(lam);
		}
	}
	if (As <= 1e-6) {
		return 0.0;
	}
	const double lm = ex(Ls / As);
	const double k = clampf(dl + 1.321928 - lg(lm) / lg(2.0), 0.0, 1.0) * (1.0 - s_(maxf(std::fabs(x), std::fabs(z)), rf_half));
	if (k <= 0.0) {
		return 0.0;
	}
	const double rho = std::sqrt(zr * zr + zi * zi) / As;
	const double g = smoothstep(rf_rho0, rf_rho1, rho);
	const double t = fposmod(at2(zi, zr) / TAU + 1.0 - rf_lee, 1.0);
	double f;
	if (t < 1.0 - rf_lee) {
		f = pw(sn(PI / 2 * t / (1.0 - rf_lee)), 2);
	} else {
		f = pw(cs(PI / 2 * (t - 1.0 + rf_lee) / rf_lee), 2);
	}
	return k * rf_H * As * g * (f - 0.5);
}

double GeoStamps::h(double x, double z) const {
	if (on <= 0.0) {
		return 0.0;
	}
	const double dl = dem_l(x, z);
	if (dl <= -3.0) {
		return 0.0;
	}
	const std::array<double, 4> w = W(x, z);
	const double dl3 = dem_l(x, z, 3.0);
	return on * (craters(x, z, dl, w) + ripples(x, z, dl3, w) + rfield(x, z, dl3));
}

double GeoStamps::margin(double e) const {
	if (on <= 0.0) {
		return 0.0;
	}
	const double dl = dem_l(e, 0.0);
	if (dl <= -3.0) {
		return 0.0;
	}
	const double dmax = minf(pw(2.0, dl + 2.0), 32.0) * 2.0;
	double a = 0.0;
	for (const Ripple &r : rp) {
		a += r.amp * 0.5;
	}
	a += rf_H * 0.5 * rf_on;
	return on * (dD_fresh * dmax + a);
}

// ———— 地形LOD.gd node_box / hits / sel / update（选块部分）
const std::array<double, 2> &Terrain::node_box(int l, double x0, double z0, double s) {
	const Key key{ l, roundi(x0 / s), roundi(z0 / s) };
	auto it = box_.find(key);
	if (it != box_.end()) {
		return it->second;
	}
	const int kmin = (int)clampi(l + roundi(lg(c0 / hl.c0) / lg(2.0)), 0, hl.L - 1);
	double lo = INFINITY, hi = -INFINITY;
	for (int j = 0; j < 9; j++) {
		for (int i = 0; i < 9; i++) {
			const double h = hl.h_data(x0 + s * i / 8.0, z0 + s * j / 8.0, kmin);
			lo = minf(lo, h);
			hi = maxf(hi, h);
		}
	}
	double mg = 0.05 * s + 0.3;
	if (has_geo) {
		mg += geo.margin(maxf(maxf(std::fabs(x0), std::fabs(x0 + s)), maxf(std::fabs(z0), std::fabs(z0 + s))));
	}
	return box_[key] = { lo - mg, hi + mg };
}

bool Terrain::hits(const float cam[3], double x0, double z0, double s, const std::array<double, 2> &b, double r) const {
	// Vector3(clampf(...)) → float；distance_squared_to 在 float 里算
	const float qx = (float)clampf(cam[0], x0, x0 + s), qy = (float)clampf(cam[1], b[0], b[1]), qz = (float)clampf(cam[2], z0, z0 + s);
	const float dx = cam[0] - qx, dy = cam[1] - qy, dz = cam[2] - qz;
	const float d2 = dx * dx + dy * dy + dz * dz;
	return d2 <= r * r;
}

bool Terrain::sel(const float cam[3], int l, double x0, double z0, std::vector<LodNode> &out) {
	const double s = m * c0 * pw(2.0, l);
	if (x0 >= W || z0 >= W || x0 + s <= -W || z0 + s <= -W) {
		return true;
	}
	const std::array<double, 2> b = node_box(l, x0, z0, s);
	if (!hits(cam, x0, z0, s, b, R[l])) {
		return false;
	}
	if (l == 0 || !hits(cam, x0, z0, s, b, R[l - 1])) {
		out.push_back({ l, x0, z0, b[0], b[1], 0 });
		return true;
	}
	const double hs = s * 0.5;
	const double hf = (float)hs; // Vector2(hs, …)：float
	const double cx[4] = { 0.0, hf, 0.0, hf }, cz[4] = { 0.0, 0.0, hf, hf };
	for (int c = 0; c < 4; c++) {
		if (!sel(cam, l - 1, x0 + cx[c], z0 + cz[c], out)) {
			const std::array<double, 2> bq = node_box(l - 1, x0 + cx[c], z0 + cz[c], hs);
			out.push_back({ l, x0 + cx[c], z0 + cz[c], bq[0], bq[1], 1 });
		}
	}
	return true;
}

void Terrain::select(float cam_x, float cam_y, float cam_z, double pixel_angle, std::vector<LodNode> &r_out) {
	range0 = maxf(c0 / (tri_px * pixel_angle), 3.0 * m * c0);
	R.clear();
	for (int l = 0; l < L; l++) {
		R.push_back(range0 * pw(2.0, l));
	}
	const float cam[3] = { cam_x, cam_y, cam_z };
	r_out.clear();
	const double s = m * c0 * pw(2.0, L - 1);
	const int64_t nr = ceili(W / s);
	for (int64_t j = -nr; j < nr; j++) {
		for (int64_t i = -nr; i < nr; i++) {
			sel(cam, L - 1, i * s, j * s, r_out);
		}
	}
}

} // namespace terrain
