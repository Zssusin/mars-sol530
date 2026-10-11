#include "scatter_core.h"

#include "godot_compat.h"

#include <algorithm>
#include <chrono>
#include <functional>
#include <cmath>

using namespace gdc;

namespace scatter {

double golombek_n(double k, double d1, double d2, std::vector<float> &r_D, std::vector<float> &r_cdf, int nD) {
	const double q = 1.79 + 0.152 / maxf(k, 1e-4);
	r_D.clear();
	std::vector<float> nd;
	for (int i = 0; i < nD; i++) {
		const double d = d1 * pw(d2 / d1, (double)i / (nD - 1));
		r_D.push_back((float)d);
		nd.push_back((float)(k * q * ex(-q * d) / (PI * d * d / 4.0)));
	}
	r_cdf.assign(1, 0.0f);
	for (int i = 1; i < nD; i++) {
		r_cdf.push_back((float)((double)r_cdf[i - 1] + 0.5 * ((double)nd[i] + (double)nd[i - 1]) * ((double)r_D[i] - (double)r_D[i - 1])));
	}
	const double tot = r_cdf[nD - 1];
	for (int i = 0; i < nD; i++) {
		r_cdf[i] = (float)((double)r_cdf[i] / maxf(tot, 1e-12));
	}
	return tot;
}

// PackedFloat32Array.bsearch(u)（before = true）：第一个 ≥ u 的位置，比较在 float 里做。
double inv_cdf(const std::vector<float> &D, const std::vector<float> &cdf, double u) {
	const float uf = (float)u;
	const int64_t i = std::lower_bound(cdf.begin(), cdf.end(), uf) - cdf.begin();
	if (i <= 0) {
		return D[0];
	}
	if (i >= (int64_t)cdf.size()) {
		return D[D.size() - 1];
	}
	const double t = (u - (double)cdf[i - 1]) / maxf((double)cdf[i] - (double)cdf[i - 1], 1e-12);
	return lerpf(D[i - 1], D[i], t);
}

static int64_t poisson(RNG &rng, double lam) {
	if (lam > 40.0) {
		const int64_t v = roundi(rng.randfn((float)lam, (float)std::sqrt(lam)));
		return v > 0 ? v : 0;
	}
	const double L = ex(-lam);
	int64_t k = 0;
	double p = 1.0;
	while (true) {
		p *= rng.randf();
		if (p <= L) {
			return k;
		}
		k++;
	}
}

void Scatter::setup() {
	for (int b = 0; b < NB; b++) {
		const double d1 = D0 * pw(2.0, b), d2 = 2.0 * d1;
		double mx = 0.0;
		for (int c = 0; c < 4; c++) {
			N_[b][c] = golombek_n(k_cls[c], d1, d2, Dt_[b][c], Ct_[b][c]);
			mx = maxf(mx, N_[b][c]);
		}
		Nmax_[b] = mx;
	}
}

Tile Scatter::gen_tile(const terrain::Terrain &t, int b, int64_t ti, int64_t tj) const {
	using terrain::GeoStamps;
	const GeoStamps &geo = t.geo;
	const double T = TILE * D0 * pw(2.0, b);
	RNG rng;
	rng.seed(GeoStamps::ih(GeoStamps::ih((uint32_t)b * 0x3c6ef372u + 7u) ^ GeoStamps::ih((uint32_t)ti * 0x27d4eb2du) ^ ((uint32_t)tj * 0x165667b1u)));
	Tile out;
	const int64_t cnt = poisson(rng, Nmax_[b] * T * T);
	for (int64_t n = 0; n < cnt; n++) {
		const double x = (ti + (double)rng.randf()) * T;
		const double z = (tj + (double)rng.randf()) * T;
		const double u1 = rng.randf(), u2 = rng.randf(), u3 = rng.randf(), u4 = rng.randf();
		const double dl = geo.dem_l(x, z);
		if (dl <= -4.5) {
			continue;
		}
		const std::array<double, 4> w = geo.W(x, z);
		const double nc[4] = { w[0] * N_[b][0], w[1] * N_[b][1], w[2] * N_[b][2], w[3] * N_[b][3] };
		const double ns = nc[0] + nc[1] + nc[2] + nc[3];
		if (u1 * Nmax_[b] >= ns) {
			continue;
		}
		int c = 0;
		double acc = nc[0];
		const double pick = u2 * ns;
		while (c < 3 && pick > acc) {
			c++;
			acc += nc[c];
		}
		const double D = inv_cdf(Dt_[b][c], Ct_[b][c], u3);
		if (u4 >= clampf(dl + 1.321928 - lg(D) / lg(2.0), 0.0, 1.0)) {
			continue;
		}
		const double sd = (double)(rng.randi() & 0x3FFFFFFFu);
		const double asp = rng.randf_range(0.35f, 0.7f);
		const int ty = (int)fposmod(sd, nm);
		const double sz = D * asp / maxf(yr[ty][1] - yr[ty][0], 0.05);
		const double y = t.h_cpu(x, z, 0) - yr[ty][0] * sz - 0.25 * D * asp;
		const double rx = (hash01(sd, 1.0) - 0.5) * 0.7, ry = (hash01(sd, 2.0) - 0.5) * 0.7;
		const double rz = rng.randf() * TAU;
		const FBasis B = enu_basis(rx, ry, rz, D, D, sz);
		const double r = hash01(sd, 3.1);
		const float col[4] = { (float)(base[0] * lerpf(0.75, 1.2, r)), (float)(base[1] * lerpf(0.75, 1.15, r)), (float)(base[2] * lerpf(0.75, 1.1, r)), (float)lerpf(0.4, 1.0, hash01(sd, 5.3)) };
		std::vector<float> *dst = nullptr;
		for (auto &e : out) {
			if (e.first == ty) {
				dst = &e.second;
				break;
			}
		}
		if (!dst) {
			out.emplace_back(ty, std::vector<float>());
			dst = &out.back().second;
		}
		const float row[FLOATS] = { B.r[0][0], B.r[0][1], B.r[0][2], (float)x, B.r[1][0], B.r[1][1], B.r[1][2], (float)y, B.r[2][0], B.r[2][1], B.r[2][2], (float)z, col[0], col[1], col[2], col[3] };
		dst->insert(dst->end(), row, row + FLOATS);
	}
	return out;
}

void Scatter::collect(const terrain::Terrain &t, const float cam[3], double pa, double budget_ms, std::vector<std::array<std::vector<float>, 3>> &r_out, Stats &st, marsim::ThreadPool *p_pool) {
	const auto t0 = std::chrono::steady_clock::now();
	auto pfor = [p_pool](int64_t n, const std::function<void(int64_t)> &fn) {
		if (p_pool) {
			p_pool->parallel_for(n, fn);
		} else {
			for (int64_t i = 0; i < n; i++) {
				fn(i);
			}
		}
	};
	const double cx = cam[0], cy = cam[1], cz = cam[2];
	const double agl = maxf(cy - t.h_cpu(cx, cz, 0), 0.0);
	st = Stats();
	struct Todo {
		double dn;
		Key key;
		int l;
	};
	std::vector<Todo> todo;
	for (int b = 0; b < NB; b++) {
		const double Dm = 1.4142 * D0 * pw(2.0, b);
		const double T = TILE * D0 * pw(2.0, b);
		const double r = Dm / (px_min * pa);
		if (r <= agl) {
			continue;
		}
		const double rh = std::sqrt(r * r - agl * agl);
		for (int64_t tj = floori((cz - rh) / T); tj < floori((cz + rh) / T) + 1; tj++) {
			for (int64_t ti = floori((cx - rh) / T); ti < floori((cx + rh) / T) + 1; ti++) {
				const double dx = maxf(maxf(ti * T - cx, cx - (ti + 1) * T), 0.0), dz = maxf(maxf(tj * T - cz, cz - (tj + 1) * T), 0.0);
				const double dn = std::sqrt(dx * dx + dz * dz + agl * agl);
				if (dn > r) {
					continue;
				}
				const double fx = maxf(std::fabs(ti * T - cx), std::fabs(cx - (ti + 1) * T)), fz = maxf(std::fabs(tj * T - cz), std::fabs(cz - (tj + 1) * T));
				const double df = std::sqrt(fx * fx + fz * fz + agl * agl);
				int l = lv(Dm / (maxf(dn, 0.01) * pa));
				if (lv(Dm / (df * pa)) != l || (l == 2 && Dm / (df * pa) < px_min)) {
					l = -1; // 区块跨级（或跨可见边界）：逐块定级
				}
				todo.push_back({ dn, { b, ti, tj }, l });
			}
		}
	}
	std::stable_sort(todo.begin(), todo.end(), [](const Todo &a, const Todo &c) { return a.dn < c.dn; });
	const int64_t nt = (int64_t)todo.size();

	// 1. 生成缺的区块（并行，近的先领）。gen_tile 是 const、只读地形，各区块互不相干。
	std::vector<int64_t> miss;
	for (int64_t i = 0; i < nt; i++) {
		if (cache_.find(todo[i].key) == cache_.end()) {
			miss.push_back(i);
		}
	}
	std::vector<Tile> fresh(miss.size());
	std::vector<char> made(miss.size(), 0);
	pfor((int64_t)miss.size(), [&](int64_t m) {
		if (budget_ms > 0.0 && std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count() > budget_ms) {
			return; // 超时：留到下次
		}
		const Key &k = todo[miss[m]].key;
		fresh[m] = gen_tile(t, (int)k.b, k.i, k.j);
		made[m] = 1;
	});
	for (size_t m = 0; m < miss.size(); m++) {
		if (made[m]) {
			cache_.emplace(todo[miss[m]].key, std::move(fresh[m]));
			st.generated++;
		} else {
			st.pending = true;
		}
	}

	// 2. 逐区块分级（并行）：每块石头定级，记各区块每类每级的块数。
	if ((int)r_out.size() < nm) {
		r_out.resize(nm);
	}
	const int ntypes = (int)r_out.size();
	std::vector<const Tile *> tp(nt, nullptr);
	for (int64_t i = 0; i < nt; i++) {
		auto it = cache_.find(todo[i].key);
		if (it != cache_.end()) {
			tp[i] = &it->second;
		}
	}
	std::vector<std::vector<int8_t>> lev(nt); // 逐块定级的区块：每块石头的级（−1 = 太小不画），按区块内顺序
	std::vector<int> cnt((size_t)nt * ntypes * 3, 0); // [区块][类型][级] 块数
	pfor(nt, [&](int64_t i) {
		const Tile *tile = tp[i];
		if (!tile) {
			return;
		}
		int *c = &cnt[(size_t)i * ntypes * 3];
		const int l0 = todo[i].l;
		for (const auto &e : *tile) {
			const std::vector<float> &buf = e.second;
			const int n = (int)(buf.size() / FLOATS);
			if (l0 >= 0) {
				c[e.first * 3 + l0] += n;
				continue;
			}
			for (int q = 0; q < n * FLOATS; q += FLOATS) {
				const float Dk = len3f(buf[q], buf[q + 4], buf[q + 8]);
				const float ddx = buf[q + 3] - cam[0], ddy = buf[q + 7] - cam[1], ddz = buf[q + 11] - cam[2];
				const double sk = Dk / (maxf(len3f(ddx, ddy, ddz), 0.01) * pa);
				const int8_t l = sk < px_min ? -1 : (int8_t)lv(sk);
				lev[i].push_back(l);
				if (l >= 0) {
					c[e.first * 3 + l]++;
				}
			}
		}
	});

	// 3. 串行：按区块顺序排出每个区块在输出里的起点（= 单线程逐个追加时的位置），统计。
	std::vector<size_t> off((size_t)nt * ntypes * 3, 0);
	std::vector<size_t> end(ntypes * 3);
	for (int k = 0; k < ntypes * 3; k++) {
		end[k] = r_out[k / 3][k % 3].size() / FLOATS; // r_out 里可能已经有固定石块
	}
	for (int64_t i = 0; i < nt; i++) {
		if (!tp[i]) {
			continue;
		}
		st.tiles++;
		for (int k = 0; k < ntypes * 3; k++) {
			const int n = cnt[(size_t)i * ntypes * 3 + k];
			off[(size_t)i * ntypes * 3 + k] = end[k];
			end[k] += n;
			st.rocks += n;
			st.band[todo[i].key.b] += n;
			st.level[k % 3] += n;
		}
	}
	for (int k = 0; k < ntypes * 3; k++) {
		r_out[k / 3][k % 3].resize(end[k] * FLOATS);
	}

	// 4. 写入（并行，各区块写各自的区间）。
	pfor(nt, [&](int64_t i) {
		const Tile *tile = tp[i];
		if (!tile) {
			return;
		}
		size_t *o = &off[(size_t)i * ntypes * 3];
		const int l0 = todo[i].l;
		size_t r = 0; // lev[i] 的下标
		for (const auto &e : *tile) {
			const std::vector<float> &buf = e.second;
			const int n = (int)(buf.size() / FLOATS);
			if (l0 >= 0) {
				float *dst = r_out[e.first][l0].data() + o[e.first * 3 + l0] * FLOATS;
				std::copy(buf.begin(), buf.end(), dst);
				o[e.first * 3 + l0] += n;
				continue;
			}
			for (int q = 0; q < n; q++, r++) {
				const int l = lev[i][r];
				if (l < 0) {
					continue;
				}
				float *dst = r_out[e.first][l].data() + o[e.first * 3 + l] * FLOATS;
				std::copy(buf.begin() + q * FLOATS, buf.begin() + (q + 1) * FLOATS, dst);
				o[e.first * 3 + l]++;
			}
		}
	});

	if ((int)cache_.size() > CACHE_MAX) { // 丢掉不在这次可见列表里的
		std::unordered_map<Key, Tile, KeyHash> keep;
		for (const Todo &td : todo) {
			auto it = cache_.find(td.key);
			if (it != cache_.end()) {
				keep.emplace(td.key, std::move(it->second));
			}
		}
		cache_.swap(keep);
	}
}

void bucket_fixed(const float *pos, const float *D, const float *buf, size_t n, const float cam[3], double pa, const double rk_px[3], std::array<std::vector<float>, 3> &r_out) {
	for (size_t k = 0; k < n; k++) {
		const float dx = cam[0] - pos[k * 3], dy = cam[1] - pos[k * 3 + 1], dz = cam[2] - pos[k * 3 + 2];
		const double s = D[k] / (maxf(len3f(dx, dy, dz), 0.01) * pa);
		const int l = s > rk_px[0] ? 0 : (s > rk_px[1] ? 1 : (s > rk_px[2] ? 2 : -1));
		if (l >= 0) {
			r_out[l].insert(r_out[l].end(), buf + k * FLOATS, buf + (k + 1) * FLOATS);
		}
	}
}

void bucket_fixed(const std::vector<float> &pos, const std::vector<float> &D, const std::vector<float> &buf, const float cam[3], double pa, const double rk_px[3], std::array<std::vector<float>, 3> &r_out) {
	const size_t n = std::min({ D.size(), pos.size() / 3, buf.size() / FLOATS });
	bucket_fixed(pos.data(), D.data(), buf.data(), n, cam, pa, rk_px, r_out);
}

} // namespace scatter
