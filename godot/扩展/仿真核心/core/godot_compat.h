// 和 Godot 4.7.2 逐位一致的小工具：GDScript 内建函数（double）、RandomNumberGenerator（PCG32，float 版 randf/randfn）、
// Basis（float）的欧拉角与乘法。C++ 移植的 GDScript 代码要和原脚本算出一模一样的数，就只用这里的函数。
//
// 精度规则（GDScript）：float 变量是 double；Vector2/Vector3/Basis/Color 的分量是 float（real_t）；
// PackedFloat32Array 元素是 float。每个 GDScript 运算单独舍入 → 编译本目录必须 -ffp-contract=off（不许合成 FMA）。
// 出处：core/math/math_funcs.h、random_pcg.h、basis.h/.cpp、thirdparty/misc/pcg.cpp（4.7.2-stable）。
#pragma once

#include <cmath>
#include <cstdint>

namespace gdc {

// libm 函数一律经 volatile 函数指针调用：GDScript 在运行时调 libm，C++ 编译器却会把 pow(x, 2) 改成 x*x、
// 把 log(2.0) 在编译期算好、把 pow(2.0, x) 换成 exp2 —— 结果可能差 1 ulp（对拍里真实出现过：沙纹 pow(sin, 2)）。
inline double (*volatile pw)(double, double) = static_cast<double (*)(double, double)>(std::pow);
inline double (*volatile lg)(double) = static_cast<double (*)(double)>(std::log);
inline double (*volatile ex)(double) = static_cast<double (*)(double)>(std::exp);
inline double (*volatile sn)(double) = static_cast<double (*)(double)>(std::sin);
inline double (*volatile cs)(double) = static_cast<double (*)(double)>(std::cos);
inline double (*volatile at2)(double, double) = static_cast<double (*)(double, double)>(std::atan2);

constexpr double PI = 3.1415926535897932384626433833;
constexpr double TAU = 6.2831853071795864769252867666;
constexpr double CMP_EPSILON = 0.00001;

inline double maxf(double a, double b) { return a > b ? a : b; }
inline double minf(double a, double b) { return a < b ? a : b; }
inline double clampf(double v, double lo, double hi) { return v < lo ? lo : (v > hi ? hi : v); }
inline int64_t clampi(int64_t v, int64_t lo, int64_t hi) { return v < lo ? lo : (v > hi ? hi : v); }
inline double lerpf(double a, double b, double t) { return a + (b - a) * t; }
inline int64_t floori(double x) { return (int64_t)std::floor(x); }
inline int64_t ceili(double x) { return (int64_t)std::ceil(x); }
inline int64_t roundi(double x) { return (int64_t)std::round(x); }

inline double fposmod(double x, double y) {
	double v = std::fmod(x, y);
	if ((v < 0 && y > 0) || (v > 0 && y < 0)) {
		v += y;
	}
	v += 0.0;
	return v;
}

inline bool is_equal_approx(double a, double b) {
	if (a == b) {
		return true;
	}
	double tol = CMP_EPSILON * std::fabs(a);
	if (tol < CMP_EPSILON) {
		tol = CMP_EPSILON;
	}
	return std::fabs(a - b) < tol;
}

inline double smoothstep(double from, double to, double s) {
	if (is_equal_approx(from, to)) {
		if (from <= to) {
			return s <= from ? 0.0 : 1.0;
		}
		return s <= to ? 1.0 : 0.0;
	}
	const double t = clampf((s - from) / (to - from), 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}

inline double deg_to_rad(double d) { return d * (PI / 180.0); }

// RandomNumberGenerator：PCG32，inc = PCG_DEFAULT_INC_64。
class RNG {
	uint64_t state_ = 0, inc_ = 0;

public:
	uint32_t next() {
		const uint64_t old = state_;
		state_ = old * 6364136223846793005ULL + (inc_ | 1);
		const uint32_t xs = (uint32_t)(((old >> 18u) ^ old) >> 27u);
		const uint32_t rot = (uint32_t)(old >> 59u);
		return (xs >> rot) | (xs << ((-rot) & 31));
	}
	void seed(uint64_t s) {
		const uint64_t initseq = 1442695040888963407ULL;
		state_ = 0;
		inc_ = (initseq << 1u) | 1u;
		next();
		state_ += s;
		next();
	}
	uint32_t randi() { return next(); }
	float randf() {
		const uint32_t p = next();
		if (p == 0) {
			return 0;
		}
		return std::ldexp((float)(next() | 0x80000001u), -32 - __builtin_clz(p));
	}
	float randf_range(float from, float to) { return randf() * (to - from) + from; }
	float randfn(float mean, float dev) {
		float temp = randf();
		if (temp < CMP_EPSILON) {
			temp += CMP_EPSILON;
		}
		return mean + dev * (std::cos((float)TAU * randf()) * std::sqrt(-2.0 * std::log(temp)));
	}
};

// Basis（float，按行存）。
struct FBasis {
	float r[3][3];
	float tdot(int col, const float *v) const { return r[0][col] * v[0] + r[1][col] * v[1] + r[2][col] * v[2]; }
};

inline FBasis mul(const FBasis &a, const FBasis &m) {
	FBasis o;
	for (int i = 0; i < 3; i++) {
		o.r[i][0] = m.tdot(0, a.r[i]);
		o.r[i][1] = m.tdot(1, a.r[i]);
		o.r[i][2] = m.tdot(2, a.r[i]);
	}
	return o;
}

inline FBasis from_euler_xyz(float ex, float ey, float ez) {
	float c = std::cos(ex), s = std::sin(ex);
	const FBasis xm = { { { 1, 0, 0 }, { 0, c, -s }, { 0, s, c } } };
	c = std::cos(ey);
	s = std::sin(ey);
	const FBasis ym = { { { c, 0, s }, { 0, 1, 0 }, { -s, 0, c } } };
	c = std::cos(ez);
	s = std::sin(ez);
	const FBasis zm = { { { c, -s, 0 }, { s, c, 0 }, { 0, 0, 1 } } };
	return mul(xm, mul(ym, zm));
}

inline FBasis from_scale(float x, float y, float z) { return FBasis{ { { x, 0, 0 }, { 0, y, 0 }, { 0, 0, z } } }; }

// 实景.gd hash01 / enu_basis
inline double hash01(double x, double salt) { return fposmod(sn(x * 12.9898 + salt * 78.233) * 43758.5453, 1.0); }

inline FBasis enu_basis(double rx, double ry, double rz, double sx, double sy, double sz) {
	const FBasis M = mul(from_euler_xyz((float)rx, (float)ry, (float)rz), from_scale((float)sx, (float)sy, (float)sz));
	const FBasis G = { { { 1, 0, 0 }, { 0, 0, 1 }, { 0, -1, 0 } } }; // 列：E→x、N→−z、U→y
	const FBasis GT = { { { 1, 0, 0 }, { 0, 0, -1 }, { 0, 1, 0 } } };
	return mul(mul(G, M), GT);
}

// Vector2/Vector3（float）的长度与距离
inline float len2f(float x, float y) { return std::sqrt(x * x + y * y); }
inline float len3f(float x, float y, float z) { return std::sqrt(x * x + y * y + z * z); }

} // namespace gdc
