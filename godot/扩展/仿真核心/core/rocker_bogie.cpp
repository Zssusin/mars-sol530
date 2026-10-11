#include "rocker_bogie.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace marsim {

namespace {

// 侧视平面内旋转（f, u），a > 0 = 前端抬起。
inline void rot(double p_f, double p_u, double p_a, double &r_f, double &r_u) {
	const double c = std::cos(p_a), s = std::sin(p_a);
	r_f = p_f * c - p_u * s;
	r_u = p_f * s + p_u * c;
}

// 6 个残差的最大绝对值；有非有限值时返回 NaN（std::max 会把 NaN 吞掉，所以单独判断）。
double max_abs6(const double *p_r) {
	double m = 0.0;
	for (int i = 0; i < 6; i++) {
		if (!std::isfinite(p_r[i])) {
			return std::numeric_limits<double>::quiet_NaN();
		}
		m = std::max(m, std::fabs(p_r[i]));
	}
	return m;
}

// 6×6 线性方程组，高斯消元 + 部分选主元。奇异时返回 false。
bool solve6(double p_a[6][6], double p_b[6], double r_x[6]) {
	for (int c = 0; c < 6; c++) {
		int piv = c;
		for (int r = c + 1; r < 6; r++) {
			if (std::fabs(p_a[r][c]) > std::fabs(p_a[piv][c])) {
				piv = r;
			}
		}
		if (std::fabs(p_a[piv][c]) < 1e-12) {
			return false;
		}
		if (piv != c) {
			for (int k = 0; k < 6; k++) {
				std::swap(p_a[c][k], p_a[piv][k]);
			}
			std::swap(p_b[c], p_b[piv]);
		}
		for (int r = c + 1; r < 6; r++) {
			const double f = p_a[r][c] / p_a[c][c];
			for (int k = c; k < 6; k++) {
				p_a[r][k] -= f * p_a[c][k];
			}
			p_b[r] -= f * p_b[c];
		}
	}
	for (int r = 5; r >= 0; r--) {
		double s = p_b[r];
		for (int k = r + 1; k < 6; k++) {
			s -= p_a[r][k] * r_x[k];
		}
		r_x[r] = s / p_a[r][r];
	}
	return true;
}

} // namespace

// 车体系三个轴的世界方向。航向 h = (sin ψ, 0, −cos ψ)，右 r0 = (cos ψ, 0, sin ψ)。
void RockerBogieSim::frame(double p_pitch, double p_roll, V3 &r_f, V3 &r_u, V3 &r_r) const {
	const double sy = std::sin(state.yaw), cy = std::cos(state.yaw);
	const V3 h(sy, 0, -cy), r0(cy, 0, sy), up(0, 1, 0);
	const V3 f = h * std::cos(p_pitch) + up * std::sin(p_pitch);
	const V3 u1 = h * (-std::sin(p_pitch)) + up * std::cos(p_pitch);
	r_f = f;
	r_r = r0 * std::cos(p_roll) - u1 * std::sin(p_roll);
	r_u = u1 * std::cos(p_roll) + r0 * std::sin(p_roll);
}

// q = [y, pitch, roll, rocker, bogie_l, bogie_r]
void RockerBogieSim::wheel_centers(const double *p_q, std::array<V3, W_COUNT> &r_c) const {
	const RoverGeometry &g = geom;
	V3 F, U, R;
	frame(p_q[1], p_q[2], F, U, R);
	const V3 origin(state.x, p_q[0], state.z);
	for (int side = 0; side < 2; side++) {
		const double lat = side == 0 ? -g.half_track : g.half_track; // 左 = −右
		const double rho = side == 0 ? p_q[3] : -p_q[3];
		const double beta = side == 0 ? p_q[4] : p_q[5];
		auto to_world = [&](double f, double u) { return origin + F * f + U * u + R * lat; };
		double ff, fu, bf, bu, mf, mu, rf, ru;
		rot(g.front_f - g.pivot_f, g.front_u - g.pivot_u, rho, ff, fu);
		rot(g.bogie_f - g.pivot_f, g.bogie_u - g.pivot_u, rho, bf, bu);
		rot(g.middle_f - g.bogie_f, g.middle_u - g.bogie_u, rho + beta, mf, mu);
		rot(g.rear_f - g.bogie_f, g.rear_u - g.bogie_u, rho + beta, rf, ru);
		const double Bf = g.pivot_f + bf, Bu = g.pivot_u + bu;
		r_c[side * 3 + 0] = to_world(g.pivot_f + ff, g.pivot_u + fu);
		r_c[side * 3 + 1] = to_world(Bf + mf, Bu + mu);
		r_c[side * 3 + 2] = to_world(Bf + rf, Bu + ru);
	}
}

// 轮子落在轮平面内地形剖面上的轮心高度：在轮前后 ±r 内取 9 点，取 h(x_k) + sqrt(r² − d_k²) 的最大值（能骑上石块边缘）。
double RockerBogieSim::ground_contact(const V3 &p_center) const {
	const double r = geom.wheel.r;
	const V3 h(std::sin(state.yaw), 0, -std::cos(state.yaw));
	double best = -1e30;
	for (int k = -4; k <= 4; k++) {
		const double d = r * k / 4.0;
		const V3 p = p_center + h * d;
		const double hk = height(p.x, p.z);
		if (!std::isfinite(hk)) {
			return std::numeric_limits<double>::quiet_NaN(); // std::max 会吞掉 NaN，这里显式往外传
		}
		best = std::max(best, hk + std::sqrt(std::max(0.0, r * r - d * d)));
	}
	return best;
}

double RockerBogieSim::solve_pose() {
	const double r = geom.wheel.r;
	double q[6] = { state.y, state.pitch, state.roll, state.rocker, state.bogie_l, state.bogie_r };
	bool cold = !has_pose_;
	for (double v : q) {
		cold = cold || !std::isfinite(v);
	}
	if (cold) { // 冷启动：按车中心下面的地面放。只在 reset 后或上一步解坏了（非有限值）时；解不满（关节到极限）时仍从上一步出发
		q[0] = height(state.x, state.z) + r - geom.front_u;
		for (int i = 1; i < 6; i++) {
			q[i] = 0.0;
		}
	}
	const double q_prev[6] = { q[0], q[1], q[2], q[3], q[4], q[5] };
	auto residual = [&](const double *p, double *res) {
		std::array<V3, W_COUNT> c;
		wheel_centers(p, c);
		for (int i = 0; i < W_COUNT; i++) {
			res[i] = c[i].y - (ground_contact(c[i]) - sink_[i]);
		}
	};
	const double lim[6] = { 1e9, 1.2, 1.2, geom.rocker_limit, geom.bogie_limit, geom.bogie_limit };
	double res[6];
	double err = 0.0;
	for (int it = 0; it < 40; it++) {
		residual(q, res);
		err = max_abs6(res);
		if (!std::isfinite(err) || err < 1e-5) {
			break;
		}
		double J[6][6];
		const double eps = 1e-5;
		for (int k = 0; k < 6; k++) {
			double qp[6];
			std::copy(q, q + 6, qp);
			qp[k] += eps;
			double rp[6];
			residual(qp, rp);
			for (int i = 0; i < 6; i++) {
				J[i][k] = (rp[i] - res[i]) / eps;
			}
		}
		double rhs[6], dq[6];
		for (int i = 0; i < 6; i++) {
			rhs[i] = -res[i];
		}
		if (!solve6(J, rhs, dq)) {
			break;
		}
		// 阻尼：单步高度 ≤ 0.2 m、角度 ≤ 0.2 rad
		double scale = 1.0;
		scale = std::min(scale, 0.2 / std::max(1e-12, std::fabs(dq[0])));
		for (int k = 1; k < 6; k++) {
			scale = std::min(scale, 0.2 / std::max(1e-12, std::fabs(dq[k])));
		}
		for (int k = 0; k < 6; k++) {
			q[k] = std::clamp(q[k] + dq[k] * scale, -lim[k], lim[k]);
		}
	}
	residual(q, res);
	err = max_abs6(res);
	if (!std::isfinite(err)) { // 地形给了 NaN 等：退回求解前的姿态，标记失败，下一步冷启动
		std::copy(q_prev, q_prev + 6, q);
		state.kinematics_ok = false;
		has_pose_ = false;
		return err;
	}
	has_pose_ = true;
	state.y = q[0];
	state.pitch = q[1];
	state.roll = q[2];
	state.rocker = q[3];
	state.bogie_l = q[4];
	state.bogie_r = q[5];
	state.kinematics_ok = err < 0.01;
	std::array<V3, W_COUNT> c;
	wheel_centers(q, c);
	for (int i = 0; i < W_COUNT; i++) {
		state.wheels[i].center = c[i];
		state.wheels[i].gap = res[i];
	}
	return err;
}

// 准静态载荷：重力竖直向下，力臂用世界水平面内沿航向（纵向）和垂直航向（侧向）的投影。
void RockerBogieSim::loads(std::array<double, W_COUNT> &r_load) const {
	const RoverGeometry &g = geom;
	const double W = g.mass * MARS_G;
	V3 F, U, R;
	frame(state.pitch, state.roll, F, U, R);
	const V3 origin(state.x, state.y, state.z);
	const V3 h(std::sin(state.yaw), 0, -std::cos(state.yaw)), side(std::cos(state.yaw), 0, std::sin(state.yaw));
	const V3 com = origin + F * g.com_f + U * g.com_u + R * g.com_r;
	auto lon = [&](const V3 &p) { return p.dot(h); };
	auto lat = [&](const V3 &p) { return p.dot(side); };

	V3 piv[2];
	for (int s = 0; s < 2; s++) {
		const double l = s == 0 ? -g.half_track : g.half_track;
		piv[s] = origin + F * g.pivot_f + U * g.pivot_u + R * l;
	}
	// 左右分配：绕质心的侧向力矩平衡
	const double lL = lat(piv[0]), lR = lat(piv[1]), lc = lat(com);
	const double FL = W * (lR - lc) / (lR - lL);
	const double Fside[2] = { FL, W - FL };
	// 差速器：车体给两侧摇臂相等的力矩 τ，抵消重力对枢轴轴线的俯仰力矩
	const double xp = 0.5 * (lon(piv[0]) + lon(piv[1]));
	const double tau = -(lon(com) - xp) * W * 0.5;

	for (int s = 0; s < 2; s++) {
		const V3 &cf = state.wheels[s * 3 + 0].center, &cm = state.wheels[s * 3 + 1].center, &cr = state.wheels[s * 3 + 2].center;
		// 转向架枢轴（世界）：摇臂上的点
		const double rho = s == 0 ? state.rocker : -state.rocker;
		double bf, bu;
		rot(g.bogie_f - g.pivot_f, g.bogie_u - g.pivot_u, rho, bf, bu);
		const double l = s == 0 ? -g.half_track : g.half_track;
		const V3 B = origin + F * (g.pivot_f + bf) + U * (g.pivot_u + bu) + R * l;
		const double xP = lon(piv[s]), xF = lon(cf), xB = lon(B), xM = lon(cm), xR = lon(cr);
		// 摇臂：N_F + N_B = F_side；N_F(xF − xP) + N_B(xB − xP) + τ = 0
		const double NF = (-tau - Fside[s] * (xB - xP)) / ((xF - xP) - (xB - xP));
		const double NB = Fside[s] - NF;
		// 转向架：N_M + N_R = N_B；N_M(xM − xB) + N_R(xR − xB) = 0
		const double NM = NB * (xR - xB) / ((xR - xB) - (xM - xB));
		const double NR = NB - NM;
		r_load[s * 3 + 0] = NF;
		r_load[s * 3 + 1] = NM;
		r_load[s * 3 + 2] = NR;
	}
}

void RockerBogieSim::reset(double p_x, double p_z, double p_yaw) {
	state = RoverState();
	state.x = p_x;
	state.z = p_z;
	state.yaw = p_yaw;
	sink_.fill(0.0);
	theta_hint_.assign(W_COUNT, 0.0);
	slip_hint_ = std::numeric_limits<double>::quiet_NaN();
	has_pose_ = false;
	solve_pose();
}

void RockerBogieSim::step(double p_dt, double p_wheel_omega, double p_yaw_rate) {
	if (!std::isfinite(p_dt) || !std::isfinite(p_wheel_omega) || !std::isfinite(p_yaw_rate)) {
		return;
	}
	state.yaw += p_yaw_rate * p_dt;
	if (!std::isfinite(solve_pose())) { // 地形给了非有限值：这一步不动
		state.speed = 0.0;
		return;
	}

	const double W = geom.mass * MARS_G;
	const V3 h(std::sin(state.yaw), 0, -std::cos(state.yaw));
	// 沿航向的坡度：前后轮平均高度差 / 水平距离（比车体俯仰更接近"地面"坡度）
	const V3 front = (state.wheels[W_LF].center + state.wheels[W_RF].center) * 0.5;
	const V3 rear = (state.wheels[W_LR].center + state.wheels[W_RR].center) * 0.5;
	const double run = (front - rear).dot(h);
	const double alpha = std::atan2(front.y - rear.y, std::max(1e-6, run));
	state.slope_deg = alpha * 180.0 / 3.14159265358979323846;
	// 行进方向：倒车时轮土力学按镜像算（刚性轮前后对称），需要的牵引力 = 重力沿行进方向的分量
	const double dir = p_wheel_omega < 0.0 ? -1.0 : 1.0;
	const double omega = std::fabs(p_wheel_omega);
	const double required = W * std::sin(alpha * dir);

	std::array<double, W_COUNT> load;
	loads(load); // 竖直分量，合计 = W
	std::vector<double> lv(W_COUNT);
	for (int i = 0; i < W_COUNT; i++) {
		load[i] = std::max(0.0, load[i]) * std::cos(alpha); // 法向载荷；负载荷 = 该轮要离地（准静态模型的边界），按 0
		lv[i] = load[i];
	}

	SlipSolve sol;
	if (omega > 1e-9) {
		sol = solve_slip(geom.wheel, soil, lv, required, -0.5, 0.95, model, slip_hint_, &theta_hint_);
	} else { // 不转：只解静沉陷
		sol.wheels.resize(W_COUNT);
		for (int i = 0; i < W_COUNT; i++) {
			sol.wheels[i] = wheel_at_load(geom.wheel, soil, load[i], 0.0, model, theta_hint_[i]);
		}
	}
	const double s = sol.slip;
	state.slip = s;
	state.stuck = sol.status == SlipStatus::STUCK;
	state.skidding = sol.status == SlipStatus::SKID;
	state.slip_evaluations = sol.evaluations;
	if (omega > 1e-9) {
		slip_hint_ = s;
	}
	const double v = state.stuck ? 0.0 : dir * geom.wheel.r * omega * (1.0 - s); // 沿坡面
	state.speed = v;

	double power = 0.0;
	for (int i = 0; i < W_COUNT; i++) {
		const WheelState &ws = sol.wheels[i];
		WheelOut &wo = state.wheels[i];
		wo.load = load[i];
		wo.sinkage = ws.ok ? ws.sinkage : geom.wheel.r;
		wo.DP = dir * ws.DP;
		wo.torque = dir * ws.T;
		power += ws.T * omega;
		sink_[i] = wo.sinkage;
		if (ws.ok && ws.theta1 > 0.0) {
			theta_hint_[i] = ws.theta1;
		}
	}
	state.power = power;

	// 位移取水平分量（v 沿坡面）
	const double vh = v * std::cos(alpha);
	state.x += h.x * vh * p_dt;
	state.z += h.z * vh * p_dt;
}

} // namespace marsim
