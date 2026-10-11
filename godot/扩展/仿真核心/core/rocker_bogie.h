// 摇臂–转向架（rocker-bogie）六轮车在高度场上的准静态仿真。
// 纯 C++17，不依赖 Godot。坐标同 Godot：x 东、y 上、z 南；航向 yaw = 0 朝北（−z），顺时针为正（同 地貌.gd 的方位角）。
//
// 每步：
//  1. 运动学：已知车体水平位置和航向，用牛顿法解 6 个未知数（车体高度、俯仰、侧倾、差速器转角 ρ、左右转向架转角）
//     使 6 个轮子都恰好落在地上（轮心高度 = 轮平面内地形剖面的最高接触点 + r − 沉陷）。左右摇臂经差速器反向：ρ_L = ρ, ρ_R = −ρ。
//  2. 静力：车重 → 左右摇臂枢轴（按侧向力矩）→ 前轮与转向架枢轴（按纵向力矩，差速器给两侧相等的力矩）→ 中轮与后轮。
//  3. 轮土：各轮载荷 + 共同滑转率 → 牵引力；解出让总牵引力 = 重力沿行进方向分量的滑转率；车速 = rω(1 − s)（沿坡面）。
//     倒车（ω < 0）按行进方向镜像：车头朝上坡倒车 = 下坡行驶。各轮入土角和滑转率用上一步的解热启动。
// 未建模：轮间牵引力对载荷分配的影响、加速度、转向时的侧滑、悬架关节极限外的离地（只报告残差）。
#pragma once

#include "mars_terramechanics.h"

#include <array>
#include <functional>

namespace marsim {

struct V3 {
	double x = 0, y = 0, z = 0;
	V3() = default;
	V3(double p_x, double p_y, double p_z) :
			x(p_x), y(p_y), z(p_z) {}
	V3 operator+(const V3 &o) const { return V3(x + o.x, y + o.y, z + o.z); }
	V3 operator-(const V3 &o) const { return V3(x - o.x, y - o.y, z - o.z); }
	V3 operator*(double s) const { return V3(x * s, y * s, z * s); }
	double dot(const V3 &o) const { return x * o.x + y * o.y + z * o.z; }
};

using HeightFn = std::function<double(double, double)>; // 地面高度 h(x, z)，m

// 侧视平面里的几何（车体系：f 向前、u 向上，单位 m），左右对称。默认值是按 MSL 级车的比例估的，待从 25042_Perseverance.glb 量。
struct RoverGeometry {
	double mass = 1025.0; // kg（毅力号，NASA）
	double half_track = 1.10; // 轮距的一半（车体中线到轮平面），m —— 估计
	// 名义姿态（ρ = β = 0）下的位置：
	double pivot_f = 0.15, pivot_u = 0.0; // 摇臂枢轴（在车体上）
	double front_f = 1.05, front_u = -0.45; // 前轮轮心
	double bogie_f = -0.45, bogie_u = -0.20; // 转向架枢轴
	double middle_f = 0.05, middle_u = -0.45; // 中轮轮心
	double rear_f = -0.95, rear_u = -0.45; // 后轮轮心
	double com_f = 0.0, com_u = 0.25, com_r = 0.0; // 质心（车体系，r 向右）
	double rocker_limit = 0.6, bogie_limit = 0.8; // 关节极限，rad
	Wheel wheel;
};

enum WheelId {
	W_LF = 0,
	W_LM,
	W_LR,
	W_RF,
	W_RM,
	W_RR,
	W_COUNT
};

struct WheelOut {
	V3 center; // 轮心（世界）
	double load = 0; // 法向载荷，N
	double sinkage = 0; // m
	double DP = 0; // N，沿车头方向（倒车时推车后退为负）
	double torque = 0; // N·m，与 ω 同号
	double gap = 0; // 运动学残差：轮心比应在高度高多少（> 1 cm ≈ 离地）
};

struct RoverState {
	// 输入/状态
	double x = 0, z = 0, yaw = 0;
	// 解出来的
	double y = 0, pitch = 0, roll = 0; // pitch > 0 抬头，roll > 0 右侧下沉
	double rocker = 0, bogie_l = 0, bogie_r = 0;
	double speed = 0; // m/s（沿航向）
	double slip = 0;
	double slope_deg = 0; // 沿航向（车头方向）的坡度（> 0 车头朝上坡）
	bool stuck = false; // 需要的牵引力超过滑转率 0.95 时的最大值：打滑陷车，车速 0
	bool skidding = false; // 滑转率 −0.5（最大制动）也刹不住：下坡溜车。准静态模型算不出加速度，车速按 s = −0.5 给，只作提示
	bool kinematics_ok = false;
	int slip_evaluations = 0; // 本步总牵引力求值次数（性能诊断）
	double power = 0; // 驱动功率 Σ T·ω，W
	std::array<WheelOut, W_COUNT> wheels;
};

class RockerBogieSim {
public:
	RoverGeometry geom;
	Soil soil;
	HeightFn height;
	ModelOptions model;

	RoverState state;

	void reset(double p_x, double p_z, double p_yaw);
	// 前进一步：轮子角速度（rad/s，六轮相同）、航向角速度（rad/s，原地转向近似：只改航向）。
	void step(double p_dt, double p_wheel_omega, double p_yaw_rate);
	// 只解姿态（不动位置），给定当前状态的 x、z、yaw；返回最大残差（m）。
	double solve_pose();

private:
	std::array<double, W_COUNT> sink_ = {};
	std::vector<double> theta_hint_ = std::vector<double>(W_COUNT, 0.0); // 各轮上一步的入土角
	double slip_hint_ = std::numeric_limits<double>::quiet_NaN(); // 上一步的滑转率
	bool has_pose_ = false; // 有上一步的姿态可以热启动
	void wheel_centers(const double *p_q, std::array<V3, W_COUNT> &r_c) const;
	double ground_contact(const V3 &p_center) const;
	void loads(std::array<double, W_COUNT> &r_load) const;
	void frame(double p_pitch, double p_roll, V3 &r_f, V3 &r_u, V3 &r_r) const;
};

} // namespace marsim
