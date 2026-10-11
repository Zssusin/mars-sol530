// 火星车轮–土壤力学（刚性轮，Bekker 压力–沉陷 + Wong–Reece 应力分布 + Janosi–Hanamoto 剪切）。
// 纯 C++17，不依赖 Godot；GDExtension 绑定在 ../gdextension/。
//
// 公式（Wong & Reece 1967；实现方式同 RoverDevKit, arXiv 2606.21755 §3.2）：
//   θ 从竖直向下量起；入土角 θ1，出土角 θ2 = 0；沉陷 z0 = r(1 − cos θ1)
//   θm = (c1 + c2·|s|)·θ1，c1 = 0.4、c2 = 0.2
//   前区 θm ≤ θ ≤ θ1：σ = k·r^n·(cos θ − cos θ1)^n，k = kc/b + kφ
//   后区 0 ≤ θ < θm：σ 用 θ* = θ1 − (θ/θm)(θ1 − θm) 代入同一式
//   剪切位移 j = r[(θ1 − θ) − (1 − s)(sin θ1 − sin θ)]
//   τ = γg·(c + σ tan φ)(1 − e^(−|j|/K))·sgn(j)
//   Fz = r·b ∫(σ cos θ + τ sin θ)dθ；DP = r·b ∫(τ cos θ − σ sin θ)dθ；T = r²·b ∫τ dθ
// 给定轮载 Fz* 和滑转率 s，由 Fz(θ1) = Fz* 解出 θ1（沉陷是输出，不是输入）。
// 未建模：推土阻力、轮刺的几何效应（只有 γg 系数）、动态沉陷、土壤压实历史。
#pragma once

#include <limits>
#include <string>
#include <vector>

namespace marsim {

constexpr double MARS_G = 3.721; // m/s²

struct Soil {
	std::string name;
	double n = 1.0; // 沉陷指数
	double kc = 0.0; // 内聚模量，Pa/m^(n−1)（= kN/m^(n+1) × 1000）
	double kphi = 0.0; // 摩擦模量，Pa/m^n
	double c = 0.0; // 内聚力，Pa
	double phi_deg = 30.0; // 内摩擦角
	double K = 0.025; // 剪切变形模量，m
	double rho = 1500.0; // 体密度，kg/m³（只作记录）
	std::string source; // 出处
};

// 内置土壤（见 README 的出处表）。名字：
//   "M90"     风积沙/漂移物，NASA 评述中与火星风成沙最接近的模拟物之一（贝瓦仪实测，松散）
//   "GRC-3"   松散细砂（贝瓦仪实测），软沙的偏坏情形
//   "压实风化层" 估计值：c、φ 取 Viking 结壳–团块土（Moore & Jakosky 1989）的中值，k 取 M90 的 5 倍，n 取 1.0。没有实测，待替换
const std::vector<Soil> &soil_presets();
const Soil *find_soil(const std::string &p_name);

struct Wheel {
	double r = 0.263; // 半径，m（毅力号轮径 52.6 cm，NASA）
	double b = 0.40; // 宽，m（估计，待从模型量）
	double grouser = 1.0; // 轮刺剪切增益 γg（1 = 光轮；RoverDevKit 上限 1.6）
};

struct WheelState {
	double theta1 = 0.0; // 入土角，rad
	double theta_m = 0.0;
	double sinkage = 0.0; // z0，m
	double Fz = 0.0; // 竖直支承力，N
	double DP = 0.0; // 挂钩牵引力（净推力，正 = 推车前进），N
	double T = 0.0; // 驱动力矩，N·m
	bool ok = false; // 解出来了（载荷超过 θ1 = 80° 时的支承力 → false，轮子陷死）
};

struct ModelOptions {
	double c1 = 0.4;
	double c2 = 0.2;
	int steps = 160; // Simpson 积分段数（偶数）
};

// 参数检查：n、K、r、b > 0，kc/b + kφ > 0，0 ≤ φ < 90°，c ≥ 0，steps ≥ 2。不合法时 r_why 写原因。
bool soil_valid(const Soil &p_soil, std::string *r_why = nullptr);
bool wheel_valid(const Wheel &p_wheel, std::string *r_why = nullptr);

// 给定入土角和滑转率，积分出力（不解平衡）。三个积分一遍算完，每个积分点 σ、τ 只算一次。
WheelState wheel_forces(const Wheel &p_wheel, const Soil &p_soil, double p_theta1, double p_slip, const ModelOptions &p_opt = ModelOptions());

// 给定轮载（N）和滑转率，解沉陷（Fz(θ1) = 载荷），返回该状态下的牵引力、力矩。
// p_theta_hint > 0：上一次的入土角，用来热启动（结果与不给时相同，只是更快）。
WheelState wheel_at_load(const Wheel &p_wheel, const Soil &p_soil, double p_load, double p_slip, const ModelOptions &p_opt = ModelOptions(), double p_theta_hint = 0.0);

enum class SlipStatus {
	OK,
	STUCK, // s = s_max 时总牵引力仍不够：打滑陷车
	SKID, // s = s_min（最大制动）时总牵引力仍大于需要：刹不住，下坡溜车（准静态模型给不出加速度，只报告）
};

struct SlipSolve {
	double slip = 0.0;
	SlipStatus status = SlipStatus::OK;
	int evaluations = 0; // 总牵引力被算了几次（性能诊断）
	std::vector<WheelState> wheels; // 解出的滑转率下各轮的状态
};

// 多个轮子共用一个滑转率（同转速、同车速）时，解出让总牵引力 = p_required 的滑转率（Brent 法）。
// p_loads：各轮载荷。p_hint：上一步的解（NaN = 没有），p_theta_hints：各轮上一步的入土角（可空），只用来热启动。
SlipSolve solve_slip(const Wheel &p_wheel, const Soil &p_soil, const std::vector<double> &p_loads, double p_required, double p_s_min = -0.5, double p_s_max = 0.95, const ModelOptions &p_opt = ModelOptions(), double p_hint = std::numeric_limits<double>::quiet_NaN(), const std::vector<double> *p_theta_hints = nullptr);

// 旧接口：返回 s；陷车时 r_reached = false、s = s_max；刹不住时 r_reached = true、s = s_min。
double slip_for_drawbar(const Wheel &p_wheel, const Soil &p_soil, const std::vector<double> &p_loads, double p_required, bool &r_reached, double p_s_min = -0.5, double p_s_max = 0.95, const ModelOptions &p_opt = ModelOptions());

// 静沉陷的两个闭式解（无剪切、无后区、小角度 z ≈ z0 − x²/D，D = 2r），只用于单元测试对照：
//  精确积分：W = b·k·sqrt(D)/2 · B(n + 1, 1/2) · z0^(n + 1/2)
//  Bekker 经典式：W = b·k·(3 − n)/3 · z0^(n + 1/2) · sqrt(D)，把 B(n+1, 1/2)/2 近似成 (3 − n)/3（n = 1.3 时比精确值低 8.1%，即精确值高 8.8%）
double small_angle_static_load(const Wheel &p_wheel, const Soil &p_soil, double p_sinkage);
double bekker_static_load(const Wheel &p_wheel, const Soil &p_soil, double p_sinkage);

} // namespace marsim
