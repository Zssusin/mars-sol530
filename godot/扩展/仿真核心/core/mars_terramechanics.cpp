#include "mars_terramechanics.h"

#include <algorithm>
#include <cmath>

namespace marsim {

namespace {

constexpr double PI = 3.14159265358979323846;
constexpr double DEG = PI / 180.0;

// 单位换算：表里 kc 是 kPa/m^(n−1)、kφ 是 kPa/m^n、c 是 kPa、K 是 mm。
Soil make_soil(const char *p_name, double p_n, double p_kc_kpa, double p_kphi_kpa, double p_c_kpa, double p_phi_deg, double p_K_mm, double p_rho, const char *p_source) {
	Soil s;
	s.name = p_name;
	s.n = p_n;
	s.kc = p_kc_kpa * 1000.0;
	s.kphi = p_kphi_kpa * 1000.0;
	s.c = p_c_kpa * 1000.0;
	s.phi_deg = p_phi_deg;
	s.K = p_K_mm / 1000.0;
	s.rho = p_rho;
	s.source = p_source;
	return s;
}

// Brent 法求单调增函数 f 的根（Brent 1973；写法同 Numerical Recipes zbrent）。[a, b] 须已夹住根：f(a) ≤ 0 ≤ f(b)。
template <typename F>
double brent(F &p_f, double p_a, double p_b, double p_fa, double p_fb, double p_xtol, int &r_evals) {
	constexpr double EPS = 2.220446049250313e-16;
	double a = p_a, b = p_b, fa = p_fa, fb = p_fb;
	double c = b, fc = fb, d = b - a, e = d;
	for (int it = 0; it < 100; it++) {
		if ((fb > 0.0 && fc > 0.0) || (fb < 0.0 && fc < 0.0)) {
			c = a;
			fc = fa;
			e = d = b - a;
		}
		if (std::fabs(fc) < std::fabs(fb)) {
			a = b;
			b = c;
			c = a;
			fa = fb;
			fb = fc;
			fc = fa;
		}
		const double tol1 = 2.0 * EPS * std::fabs(b) + 0.5 * p_xtol;
		const double xm = 0.5 * (c - b);
		if (std::fabs(xm) <= tol1 || fb == 0.0) {
			return b;
		}
		if (std::fabs(e) >= tol1 && std::fabs(fa) > std::fabs(fb)) {
			const double s = fb / fa;
			double p, q;
			if (a == c) {
				p = 2.0 * xm * s;
				q = 1.0 - s;
			} else {
				const double qq = fa / fc, r = fb / fc;
				p = s * (2.0 * xm * qq * (qq - r) - (b - a) * (r - 1.0));
				q = (qq - 1.0) * (r - 1.0) * (s - 1.0);
			}
			if (p > 0.0) {
				q = -q;
			}
			p = std::fabs(p);
			const double min1 = 3.0 * xm * q - std::fabs(tol1 * q), min2 = std::fabs(e * q);
			if (2.0 * p < std::min(min1, min2)) {
				e = d;
				d = p / q;
			} else {
				d = xm;
				e = d;
			}
		} else {
			d = xm;
			e = d;
		}
		a = b;
		fa = fb;
		b += std::fabs(d) > tol1 ? d : (xm >= 0.0 ? tol1 : -tol1);
		fb = p_f(b);
		r_evals++;
	}
	return b;
}

enum class Bracket {
	FOUND,
	BELOW, // f(hi) < 0：整个区间都在根下面
	ABOVE, // f(lo) > 0：整个区间都在根上面
};

// 在 [lo, hi] 上给单调增函数 f 找一个夹住根的区间。有热启动值时从它出发、按 p_step 加倍往外扩；
// 没有时直接算两端。返回 FOUND 时 [r_a, r_b] 夹住根（r_fa ≤ 0 ≤ r_fb）。
template <typename F>
Bracket bracket(F &p_f, double p_lo, double p_hi, double p_hint, double p_step, double &r_a, double &r_b, double &r_fa, double &r_fb, int &r_evals) {
	if (std::isfinite(p_hint) && p_hint > p_lo && p_hint < p_hi) {
		double x = p_hint, fx = p_f(x);
		r_evals++;
		double step = p_step;
		if (fx <= 0.0) { // 往上找
			for (;;) {
				const double y = std::min(p_hi, x + step);
				const double fy = p_f(y);
				r_evals++;
				if (fy >= 0.0) {
					r_a = x;
					r_fa = fx;
					r_b = y;
					r_fb = fy;
					return Bracket::FOUND;
				}
				if (y >= p_hi) {
					r_a = r_b = p_hi;
					r_fa = r_fb = fy;
					return Bracket::BELOW;
				}
				x = y;
				fx = fy;
				step *= 2.0;
			}
		} else { // 往下找
			for (;;) {
				const double y = std::max(p_lo, x - step);
				const double fy = p_f(y);
				r_evals++;
				if (fy <= 0.0) {
					r_a = y;
					r_fa = fy;
					r_b = x;
					r_fb = fx;
					return Bracket::FOUND;
				}
				if (y <= p_lo) {
					r_a = r_b = p_lo;
					r_fa = r_fb = fy;
					return Bracket::ABOVE;
				}
				x = y;
				fx = fy;
				step *= 2.0;
			}
		}
	}
	const double fhi = p_f(p_hi);
	r_evals++;
	if (fhi < 0.0) {
		r_a = r_b = p_hi;
		r_fa = r_fb = fhi;
		return Bracket::BELOW;
	}
	const double flo = p_f(p_lo);
	r_evals++;
	if (flo > 0.0) {
		r_a = r_b = p_lo;
		r_fa = r_fb = flo;
		return Bracket::ABOVE;
	}
	r_a = p_lo;
	r_fa = flo;
	r_b = p_hi;
	r_fb = fhi;
	return Bracket::FOUND;
}

} // namespace

const std::vector<Soil> &soil_presets() {
	static const std::vector<Soil> presets = {
		make_soil("M90", 1.3, 572.1, 4915.3, 0.27, 32.0, 25.4, 1420.0,
				"NASA NTRS 20200003046 (2020) Table 3, M90 loose, bevameter; density = mid of Table 2 range"),
		make_soil("GRC-3", 1.0, 23.2, 606.7, 0.13, 36.7, 23.5, 1730.0,
				"NASA NTRS 20200003046 (2020) Table 3, GRC-3 loose, bevameter; density = mid of Table 2 range"),
		make_soil("压实风化层", 1.0, 2860.0, 24577.0, 1.5, 34.5, 15.0, 1400.0,
				"ESTIMATE: c, phi = mid of Viking crusty-to-cloddy (Moore & Jakosky 1989 via NTRS 20200003046 Table 1); k = 5 x M90; n = 1; K guessed"),
	};
	return presets;
}

const Soil *find_soil(const std::string &p_name) {
	for (const Soil &s : soil_presets()) {
		if (s.name == p_name) {
			return &s;
		}
	}
	return nullptr;
}

bool soil_valid(const Soil &p_soil, std::string *r_why) {
	const char *why = nullptr;
	if (!(p_soil.n > 0.0 && p_soil.n < 5.0)) {
		why = "n must be in (0, 5)";
	} else if (!(p_soil.K > 0.0)) {
		why = "K must be > 0";
	} else if (!(p_soil.c >= 0.0)) {
		why = "c must be >= 0";
	} else if (!(p_soil.phi_deg >= 0.0 && p_soil.phi_deg < 90.0)) {
		why = "phi_deg must be in [0, 90)";
	} else if (!std::isfinite(p_soil.kc) || !std::isfinite(p_soil.kphi)) {
		why = "kc, kphi must be finite";
	}
	if (why && r_why) {
		*r_why = why;
	}
	return why == nullptr;
}

bool wheel_valid(const Wheel &p_wheel, std::string *r_why) {
	const char *why = nullptr;
	if (!(p_wheel.r > 0.0 && p_wheel.r < 10.0)) {
		why = "wheel radius must be in (0, 10) m";
	} else if (!(p_wheel.b > 0.0 && p_wheel.b < 10.0)) {
		why = "wheel width must be in (0, 10) m";
	} else if (!(p_wheel.grouser > 0.0 && p_wheel.grouser < 10.0)) {
		why = "grouser gain must be in (0, 10)";
	}
	if (why && r_why) {
		*r_why = why;
	}
	return why == nullptr;
}

WheelState wheel_forces(const Wheel &p_wheel, const Soil &p_soil, double p_theta1, double p_slip, const ModelOptions &p_opt) {
	WheelState w;
	const double r = p_wheel.r, b = p_wheel.b;
	const double th1 = p_theta1;
	const double thm = std::min(th1, (p_opt.c1 + p_opt.c2 * std::fabs(p_slip)) * th1);
	const double k = p_soil.kc / b + p_soil.kphi;
	const double krn = k * std::pow(r, p_soil.n);
	const double cos1 = std::cos(th1), sin1 = std::sin(th1);
	const double tanphi = std::tan(p_soil.phi_deg * DEG);
	const bool linear = p_soil.n == 1.0;
	const double inv_K = 1.0 / p_soil.K;
	w.theta1 = th1;
	w.theta_m = thm;
	w.sinkage = r * (1.0 - cos1);
	w.ok = true;
	if (!(th1 > 0.0)) {
		return w;
	}
	// Simpson，n 段（偶数）；三个积分共用积分点，每点 σ、τ 只算一次。
	int n = std::max(2, p_opt.steps);
	if (n % 2) {
		n++;
	}
	const double h = th1 / n;
	double sFz = 0.0, sDP = 0.0, sT = 0.0;
	for (int i = 0; i <= n; i++) {
		const double th = i == n ? th1 : i * h;
		const double wgt = (i == 0 || i == n) ? 1.0 : ((i % 2) ? 4.0 : 2.0);
		const double cth = std::cos(th), sth = std::sin(th);
		// σ：后区（θ < θm）把 θ 线性映射回前区的形状
		double cos_t = cth;
		if (th < thm) { // th < thm 蕴含 thm > 0
			cos_t = std::cos(th1 - (th / thm) * (th1 - thm));
		}
		const double d = cos_t - cos1;
		const double sigma = d > 0.0 ? (linear ? krn * d : krn * std::pow(d, p_soil.n)) : 0.0;
		// τ：Janosi–Hanamoto
		const double j = r * ((th1 - th) - (1.0 - p_slip) * (sin1 - sth));
		const double mag = p_wheel.grouser * (p_soil.c + sigma * tanphi) * (1.0 - std::exp(-std::fabs(j) * inv_K));
		const double tau = j >= 0.0 ? mag : -mag;
		sFz += wgt * (sigma * cth + tau * sth);
		sDP += wgt * (tau * cth - sigma * sth);
		sT += wgt * tau;
	}
	w.Fz = r * b * sFz * h / 3.0;
	w.DP = r * b * sDP * h / 3.0;
	w.T = r * r * b * sT * h / 3.0;
	return w;
}

WheelState wheel_at_load(const Wheel &p_wheel, const Soil &p_soil, double p_load, double p_slip, const ModelOptions &p_opt, double p_theta_hint) {
	if (!(p_load > 0.0)) {
		WheelState w;
		w.ok = true; // 离地：没有力（NaN 载荷也按离地，不往下算）
		return w;
	}
	// Fz(θ1) 在 (0, 80°] 上单调增。热启动：从上次的 θ1 出发找夹住根的区间，再用 Brent 法（通常 4–8 次积分；原来二分要 32 次）。
	const double lo = 1e-6, hi = 80.0 * DEG;
	auto f = [&](double th) { return wheel_forces(p_wheel, p_soil, th, p_slip, p_opt).Fz - p_load; };
	int evals = 0;
	double a, b, fa, fb;
	const Bracket br = bracket(f, lo, hi, p_theta_hint, 0.05 * p_theta_hint + 1e-4, a, b, fa, fb, evals);
	if (br == Bracket::BELOW) {
		WheelState top = wheel_forces(p_wheel, p_soil, hi, p_slip, p_opt);
		top.ok = false; // 陷到轮轴附近也撑不住
		return top;
	}
	if (br == Bracket::ABOVE) {
		return wheel_forces(p_wheel, p_soil, lo, p_slip, p_opt);
	}
	const double th = brent(f, a, b, fa, fb, 1e-10, evals);
	return wheel_forces(p_wheel, p_soil, th, p_slip, p_opt);
}

SlipSolve solve_slip(const Wheel &p_wheel, const Soil &p_soil, const std::vector<double> &p_loads, double p_required, double p_s_min, double p_s_max, const ModelOptions &p_opt, double p_hint, const std::vector<double> *p_theta_hints) {
	SlipSolve out;
	const size_t nw = p_loads.size();
	std::vector<double> th(nw, 0.0);
	if (p_theta_hints && p_theta_hints->size() == nw) {
		th = *p_theta_hints;
	}
	// 总牵引力随滑转率单调增（Janosi 剪切随 j 增，j 随 s 增）。每次求值把各轮的 θ1 记下来，给下一次求值热启动。
	auto total = [&](double s) {
		double sum = 0.0;
		for (size_t i = 0; i < nw; i++) {
			const WheelState ws = wheel_at_load(p_wheel, p_soil, p_loads[i], s, p_opt, th[i]);
			if (ws.ok && ws.theta1 > 0.0) {
				th[i] = ws.theta1;
			}
			sum += ws.DP;
		}
		return sum - p_required;
	};
	double a, b, fa, fb;
	const Bracket br = bracket(total, p_s_min, p_s_max, p_hint, 0.02, a, b, fa, fb, out.evaluations);
	if (br == Bracket::BELOW) {
		out.slip = p_s_max;
		out.status = SlipStatus::STUCK;
	} else if (br == Bracket::ABOVE) {
		out.slip = p_s_min;
		out.status = SlipStatus::SKID;
	} else {
		out.slip = brent(total, a, b, fa, fb, 1e-9, out.evaluations);
	}
	out.wheels.resize(nw);
	for (size_t i = 0; i < nw; i++) {
		out.wheels[i] = wheel_at_load(p_wheel, p_soil, p_loads[i], out.slip, p_opt, th[i]);
	}
	return out;
}

double slip_for_drawbar(const Wheel &p_wheel, const Soil &p_soil, const std::vector<double> &p_loads, double p_required, bool &r_reached, double p_s_min, double p_s_max, const ModelOptions &p_opt) {
	const SlipSolve r = solve_slip(p_wheel, p_soil, p_loads, p_required, p_s_min, p_s_max, p_opt);
	r_reached = r.status != SlipStatus::STUCK;
	return r.slip;
}

double small_angle_static_load(const Wheel &p_wheel, const Soil &p_soil, double p_sinkage) {
	const double k = p_soil.kc / p_wheel.b + p_soil.kphi;
	const double n = p_soil.n;
	const double beta = std::tgamma(n + 1.0) * std::tgamma(0.5) / std::tgamma(n + 1.5);
	return p_wheel.b * k * std::sqrt(2.0 * p_wheel.r) / 2.0 * beta * std::pow(p_sinkage, n + 0.5);
}

double bekker_static_load(const Wheel &p_wheel, const Soil &p_soil, double p_sinkage) {
	const double k = p_soil.kc / p_wheel.b + p_soil.kphi;
	const double n = p_soil.n;
	return p_wheel.b * k * (3.0 - n) / 3.0 * std::pow(p_sinkage, (2.0 * n + 1.0) / 2.0) * std::sqrt(2.0 * p_wheel.r);
}

} // namespace marsim
