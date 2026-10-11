// 仿真核心单元测试：c++ -std=c++17 -O2 -pthread -I../core ../core/*.cpp test_core.cpp && ./a.out
// 每条检查都对着解析解或物理约束，不只是"能跑"。最后打印坡度–滑转率表（不断言，给人看）。
#include "mars_terramechanics.h"
#include "rocker_bogie.h"
#include "thread_pool.h"
#include "horizon.h"
#include "rock_occlusion.h"

#include <chrono>
#include <cmath>
#include <cstdio>

using namespace marsim;

static int g_fail = 0;
#define CHECK(cond, ...)                         \
	do {                                         \
		if (!(cond)) {                           \
			g_fail++;                            \
			std::printf("  ✗ " __VA_ARGS__);     \
			std::printf("   (%s)\n", #cond);     \
		} else {                                 \
			std::printf("  ✓ " __VA_ARGS__);     \
			std::printf("\n");                   \
		}                                        \
	} while (0)

static const double PI = 3.14159265358979323846;

int main() {
	const Soil *m90 = find_soil("M90");
	const Soil *grc = find_soil("GRC-3");
	Wheel wheel;

	std::printf("1. 积分精度：n = 1、无剪切、无后区时 Fz 有精确解\n");
	{
		Soil s = *grc;
		s.c = 0;
		s.phi_deg = 0;
		ModelOptions o;
		o.c1 = 0;
		o.c2 = 0;
		const double th1 = 0.4;
		const double k = s.kc / wheel.b + s.kphi;
		const double exact = wheel.b * k * wheel.r * wheel.r * ((th1 / 2 + std::sin(2 * th1) / 4) - std::cos(th1) * std::sin(th1));
		const double num = wheel_forces(wheel, s, th1, 0.0, o).Fz;
		CHECK(std::fabs(num / exact - 1) < 1e-6, "Fz 数值 %.3f N，精确 %.3f N", num, exact);
	}

	std::printf("2. 小沉陷极限：数值解收敛到小角度精确解（c1 = c2 = 0、无剪切）；Bekker 经典式只作对照\n");
	{
		Soil s = *m90;
		s.c = 0;
		s.phi_deg = 0;
		ModelOptions o;
		o.c1 = 0;
		o.c2 = 0;
		for (double z : { 0.001, 0.005 }) {
			const double th1 = std::acos(1 - z / wheel.r);
			const double num = wheel_forces(wheel, s, th1, 0.0, o).Fz;
			const double ex = small_angle_static_load(wheel, s, z);
			const double bek = bekker_static_load(wheel, s, z);
			CHECK(std::fabs(num / ex - 1) < 0.01, "z = %.1f mm：数值 %.2f N，小角度精确 %.2f N，差 %.3f%%（Bekker 经典式 %.2f N，低 %.1f%%）", z * 1000, num, ex, 100 * (num / ex - 1), bek, 100 * (1 - bek / ex));
		}
	}

	const double W = 1025.0 * MARS_G;
	const double per_wheel = W / 6;
	std::printf("3. 毅力号单轮（载荷 %.0f N = 1025 kg × 3.721 / 6）\n", per_wheel);
	for (const Soil *s : { m90, grc, find_soil("压实风化层") }) {
		const WheelState a = wheel_at_load(wheel, *s, per_wheel, 0.0);
		CHECK(a.ok && std::fabs(a.Fz / per_wheel - 1) < 1e-4, "%-6s 力平衡：Fz = %.2f N", s->name.c_str(), a.Fz);
		CHECK(a.sinkage > 0.0005 && a.sinkage < 0.10, "%-6s 静沉陷 %.1f mm 在 0.5–100 mm 之间", s->name.c_str(), a.sinkage * 1000);
	}
	{
		const double z_m90 = wheel_at_load(wheel, *m90, per_wheel, 0).sinkage;
		const double z_grc = wheel_at_load(wheel, *grc, per_wheel, 0).sinkage;
		const double z_hard = wheel_at_load(wheel, *find_soil("压实风化层"), per_wheel, 0).sinkage;
		CHECK(z_grc > z_m90 && z_m90 > z_hard, "软的陷得深：GRC-3 %.1f > M90 %.1f > 压实 %.1f mm", z_grc * 1000, z_m90 * 1000, z_hard * 1000);
		const double z_heavy = wheel_at_load(wheel, *m90, 2 * per_wheel, 0).sinkage;
		CHECK(z_heavy > z_m90, "载荷翻倍沉陷增加：%.1f → %.1f mm", z_m90 * 1000, z_heavy * 1000);
	}

	std::printf("4. 牵引力随滑转率单调增，自由滚动时为负（滚动阻力）\n");
	{
		double prev = -1e30;
		bool mono = true;
		for (double s = 0; s <= 0.9 + 1e-9; s += 0.1) {
			const double dp = wheel_at_load(wheel, *m90, per_wheel, s).DP;
			mono = mono && dp >= prev - 1e-6;
			prev = dp;
		}
		CHECK(mono, "M90：DP(s) 在 s = 0…0.9 单调");
		const double dp0 = wheel_at_load(wheel, *m90, per_wheel, 0).DP;
		CHECK(dp0 < 0, "s = 0 时 DP = %.1f N < 0（要靠滑转才能克服压实阻力）", dp0);
		bool reached;
		const std::vector<double> loads(6, per_wheel);
		const double s0 = slip_for_drawbar(wheel, *m90, loads, 0.0, reached);
		CHECK(reached && s0 > 0 && s0 < 0.2, "平地自推进滑转率 %.3f", s0);
		const double dp_s0 = wheel_at_load(wheel, *m90, per_wheel, s0).DP;
		CHECK(std::fabs(dp_s0) < 0.5, "该滑转率下单轮 DP = %.3f N ≈ 0", dp_s0);
	}

	std::printf("5. 摇臂–转向架运动学\n");
	RockerBogieSim sim;
	sim.soil = *m90;
	{
		sim.height = [](double, double) { return 0.0; };
		sim.reset(0, 0, 0);
		const RoverState &st = sim.state;
		CHECK(sim.solve_pose() < 1e-4, "平地残差 %.2e m", sim.solve_pose());
		CHECK(std::fabs(st.pitch) < 1e-4 && std::fabs(st.roll) < 1e-4 && std::fabs(st.rocker) < 1e-4, "平地姿态：俯仰 %.4f、侧倾 %.4f、差速 %.4f rad", st.pitch, st.roll, st.rocker);
		std::array<double, W_COUNT> ld{};
		sim.step(0.1, 0.0, 0.0); // ω = 0：只解静力
		double sum = 0;
		for (const WheelOut &w : st.wheels) {
			sum += w.load;
		}
		CHECK(std::fabs(sum / W - 1) < 1e-6, "载荷合计 = 车重：%.2f / %.2f N", sum, W);
		// 力矩平衡：Σ N_i·x_i = W·x_com（x 沿航向）
		double m = 0;
		for (const WheelOut &w : st.wheels) {
			m += w.load * (-w.center.z); // 航向北 = −z
		}
		const double xcom = -(st.y * 0 + 0) + sim.geom.com_f; // 平地无俯仰：质心纵向坐标 = com_f（车体原点在 x = z = 0）
		CHECK(std::fabs(m - W * xcom) < 1e-3 * W, "纵向力矩平衡：Σ N·x = %.3f，W·x_com = %.3f N·m", m, W * xcom);
		(void)ld;
	}
	{
		const double a = 15.0 * PI / 180.0;
		sim.height = [a](double, double z) { return -z * std::tan(a); }; // 朝北（−z）上坡 15°
		sim.reset(0, 0, 0);
		const RoverState &st = sim.state;
		CHECK(std::fabs(st.pitch - a) < 0.01 && std::fabs(st.rocker) < 0.01, "15° 纵坡：俯仰 %.2f°（应 15°），差速 %.3f rad", st.pitch * 180 / PI, st.rocker);
	}
	{
		const double a = 10.0 * PI / 180.0;
		sim.height = [a](double x, double) { return -x * std::tan(a); }; // 向东（右）下坡 10°
		sim.reset(0, 0, 0);
		const RoverState &st = sim.state;
		CHECK(std::fabs(st.roll - a) < 0.01, "10° 横坡（右低）：侧倾 %.2f°（应 +10°）", st.roll * 180 / PI);
	}
	{
		// 左前轮下面一块 20 cm 高的台阶（只在左侧、车前方）
		sim.height = [](double x, double z) { return (x < 0 && z < -0.8 && z > -1.4) ? 0.20 : 0.0; };
		sim.reset(0, 0, 0);
		const RoverState &st = sim.state;
		const double err = sim.solve_pose();
		CHECK(err < 1e-3, "左前轮上 20 cm 台阶：残差 %.2e m", err);
		CHECK(st.rocker > 0.02, "左摇臂抬起、右摇臂下压（差速器）：ρ = %.3f rad", st.rocker);
		CHECK(std::fabs(st.wheels[W_LF].center.y - st.wheels[W_RF].center.y - 0.20) < 0.01, "左前轮比右前轮高 %.3f m（应 0.20）", st.wheels[W_LF].center.y - st.wheels[W_RF].center.y);
		CHECK(std::fabs(st.pitch) < 0.2 * 0.2 / 2.0 + 0.05, "车体俯仰只吃掉一小部分台阶：%.2f°", st.pitch * 180 / PI);
	}

	std::printf("6. 爬坡：滑转率随坡度上升，超过极限陷车（M90 / GRC-3，毅力号，ω = 1 rad/s）\n");
	std::printf("   坡度   M90 滑转  M90 沉陷(mm)  M90 车速(cm/s)   GRC-3 滑转  GRC-3 沉陷  GRC-3 车速\n");
	double prev_slip = -1;
	bool slip_mono = true;
	for (int deg = 0; deg <= 30; deg += 5) {
		const double a = deg * PI / 180.0;
		double out[2][3];
		bool stuck[2];
		int idx = 0;
		for (const Soil *s : { m90, grc }) {
			RockerBogieSim r;
			r.soil = *s;
			r.height = [a](double, double z) { return -z * std::tan(a); };
			r.reset(0, 0, 0);
			for (int k = 0; k < 3; k++) {
				r.step(0.1, 1.0, 0.0); // 三步：让沉陷反馈进运动学
			}
			out[idx][0] = r.state.slip;
			out[idx][1] = r.state.wheels[W_LM].sinkage * 1000;
			out[idx][2] = r.state.speed * 100;
			stuck[idx] = r.state.stuck;
			idx++;
		}
		if (!stuck[0]) {
			slip_mono = slip_mono && out[0][0] >= prev_slip - 1e-6;
			prev_slip = out[0][0];
		}
		std::printf("   %2d°    %5.2f%s     %6.1f        %5.1f          %5.2f%s    %6.1f      %5.1f\n", deg,
				out[0][0], stuck[0] ? "陷" : "  ", out[0][1], out[0][2], out[1][0], stuck[1] ? "陷" : "  ", out[1][1], out[1][2]);
	}
	CHECK(slip_mono, "M90 上滑转率随坡度单调上升");

	std::printf("7. 求解器：热启动不改变结果，只减少求值次数\n");
	{
		const std::vector<double> loads = { 700, 650, 560, 690, 640, 570 };
		const SlipSolve cold = solve_slip(wheel, *m90, loads, 600.0);
		std::vector<double> th;
		for (const WheelState &w : cold.wheels) {
			th.push_back(w.theta1 * 1.03); // 故意偏一点
		}
		const SlipSolve warm = solve_slip(wheel, *m90, loads, 600.0, -0.5, 0.95, ModelOptions(), cold.slip + 0.01, &th);
		CHECK(std::fabs(cold.slip - warm.slip) < 1e-8, "冷启动 s = %.9f，热启动 s = %.9f", cold.slip, warm.slip);
		CHECK(warm.evaluations < cold.evaluations, "总牵引力求值：冷 %d 次，热 %d 次", cold.evaluations, warm.evaluations);
		double dp = 0;
		for (const WheelState &w : warm.wheels) {
			dp += w.DP;
		}
		CHECK(std::fabs(dp - 600.0) < 0.01, "解出的总牵引力 %.4f N = 需要的 600 N", dp);
		const WheelState a = wheel_at_load(wheel, *m90, 650.0, 0.3);
		const WheelState b = wheel_at_load(wheel, *m90, 650.0, 0.3, ModelOptions(), a.theta1 * 0.9);
		CHECK(std::fabs(a.theta1 - b.theta1) < 1e-9 && std::fabs(a.Fz / 650.0 - 1) < 1e-6, "单轮 θ1 冷 %.10f / 热 %.10f，Fz %.6f N", a.theta1, b.theta1, a.Fz);
	}

	std::printf("8. 倒车、溜车、水平位移、性能\n");
	auto run = [&](const Soil *s, double deg, double yaw, double omega, int n = 4) {
		RockerBogieSim r;
		r.soil = *s;
		const double a = deg * PI / 180.0;
		r.height = [a](double, double z) { return -z * std::tan(a); }; // 朝北（−z）上坡
		r.reset(0, 0, yaw);
		for (int k = 0; k < n; k++) {
			r.step(0.1, omega, 0.0);
		}
		return r;
	};
	{
		const RockerBogieSim flat = run(m90, 0, 0, 1);
		const RockerBogieSim rev = run(m90, 10, 0, -1); // 车头朝上坡，倒车 = 下坡行驶
		const RockerBogieSim down = run(m90, 10, PI, 1); // 车头朝下坡，前进
		CHECK(rev.state.speed < 0 && rev.state.slip < flat.state.slip, "车头朝上坡倒车：v = %.3f m/s（向后），s = %.3f < 平地 %.3f", rev.state.speed, rev.state.slip, flat.state.slip);
		CHECK(std::fabs(rev.state.slip - down.state.slip) < 0.05, "倒车下坡 s = %.3f ≈ 前进下坡 s = %.3f（车前后不对称，载荷不同）", rev.state.slip, down.state.slip);
		CHECK(rev.state.wheels[W_LM].torque < 0 && rev.state.power > 0, "倒车力矩与 ω 同号（%.1f N·m），功率为正（%.1f W）", rev.state.wheels[W_LM].torque, rev.state.power);
		const RockerBogieSim steep = run(m90, 35, PI, 1);
		CHECK(steep.state.skidding && !steep.state.stuck, "35° 下坡：最大制动也刹不住 → 溜车标志（s = %.2f）", steep.state.slip);
		const RockerBogieSim up = run(grc, 15, 0, 1, 1);
		RockerBogieSim up2 = up;
		const double z0 = up2.state.z;
		up2.step(0.1, 1.0, 0.0);
		const double a = up2.state.slope_deg * PI / 180.0;
		CHECK(std::fabs((z0 - up2.state.z) - up2.state.speed * std::cos(a) * 0.1) < 1e-9, "15° 坡上水平位移 = v·cos α·dt（%.5f m）", z0 - up2.state.z);
	}
	{
		RockerBogieSim r;
		r.soil = *m90;
		r.height = [](double x, double z) { return 0.05 * std::sin(2 * x) * std::cos(3 * z); };
		r.reset(0, 0, 0);
		r.step(0.02, 1.0, 0.0);
		const auto t0 = std::chrono::steady_clock::now();
		const int N = 50;
		for (int k = 0; k < N; k++) {
			r.step(0.02, 1.0, 0.02);
		}
		const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count() / N;
		CHECK(ms < 2.0, "起伏地面每步 %.3f ms（原二分实现约 75 ms）；本步总牵引力求值 %d 次", ms, r.state.slip_evaluations);
	}

	std::printf("9. 健壮性：参数校验、NaN 地形\n");
	{
		Soil bad = *m90;
		bad.K = 0;
		std::string why;
		CHECK(!soil_valid(bad, &why) && soil_valid(*m90), "K = 0 被拒绝（%s）", why.c_str());
		Wheel wb;
		wb.b = 0;
		CHECK(!wheel_valid(wb) && wheel_valid(wheel), "轮宽 0 被拒绝");
		RockerBogieSim r;
		r.soil = *m90;
		bool nan_on = false;
		r.height = [&nan_on](double, double) { return nan_on ? std::nan("") : 0.0; };
		r.reset(0, 0, 0);
		const double y0 = r.state.y;
		nan_on = true;
		r.step(0.1, 1.0, 0.0);
		CHECK(!r.state.kinematics_ok && std::isfinite(r.state.y) && std::fabs(r.state.y - y0) < 1e-12, "地形返回 NaN：姿态保持上一步（y = %.3f），kinematics_ok = false", r.state.y);
		nan_on = false;
		r.step(0.1, 1.0, 0.0);
		CHECK(r.state.kinematics_ok && std::isfinite(r.state.speed), "地形恢复后下一步重新解出（v = %.3f m/s）", r.state.speed);
	}

	std::printf("10. 线程池\n");
	{
		for (int nt : { 1, 2, 5, 16 }) {
			ThreadPool pool(nt);
			std::vector<int> hit(100000, 0);
			for (int round = 0; round < 20; round++) {
				pool.parallel_for((int64_t)hit.size(), [&](int64_t i) { hit[i]++; });
			}
			bool ok = true;
			for (int v : hit) {
				ok = ok && v == 20;
			}
			CHECK(ok && pool.threads() == nt, "%d 线程：20 轮 × 10 万个任务，每个恰好做一次", nt);
		}
		ThreadPool pool(4);
		std::vector<int> outer(8, 0), inner(8 * 50, 0);
		pool.parallel_for(8, [&](int64_t i) {
			outer[i] = 1;
			pool.try_parallel_for(50, [&](int64_t j) { inner[i * 50 + j]++; }); // 池正忙：在本线程串行做，不死锁
		});
		bool ok = true;
		for (int v : inner) {
			ok = ok && v == 1;
		}
		CHECK(ok, "任务里再调 try_parallel_for：串行完成、不死锁");
		pool.set_threads(3);
		std::vector<int> h2(1000, 0);
		pool.parallel_for(1000, [&](int64_t i) { h2[i] = (int)i; });
		CHECK(pool.threads() == 3 && h2[999] == 999, "换线程数后照常工作（%d 线程）", pool.threads());
	}

	std::printf("11. 地平线图与天空表（地平线 GI）\n");
	{
		auto grids = [](auto hfun) {
			std::vector<horizon::Grid> g(3);
			for (int k = 0; k < 3; k++) {
				g[k].N = 41;
				g[k].cell = std::pow(2.0, k);
				g[k].half = 20.0 * std::pow(2.0, k);
				g[k].h.resize(41 * 41);
				for (int j = 0; j < 41; j++) {
					for (int i = 0; i < 41; i++) {
						g[k].h[j * 41 + i] = (float)hfun(-g[k].half + i * g[k].cell, -g[k].half + j * g[k].cell);
					}
				}
			}
			return g;
		};
		horizon::Params par;
		par.dirs = 8;
		par.stride = 1;
		par.t_max = 1000.0;
		const auto flat = grids([](double, double) { return 0.0; });
		const std::vector<uint8_t> hf = horizon::compute_level(flat, 0, par);
		double worst = 0.0;
		for (int j = 5; j < 36; j++) {
			for (int i = 5; i < 36; i++) {
				for (int d = 0; d < 8; d++) {
					worst = std::max(worst, std::fabs(horizon::decode(hf[(j * 41 + i) * 8 + d])));
				}
			}
		}
		CHECK(worst < 0.5 * PI / 180, "平地：地平线仰角最大偏差 %.2f°（8 位量化 0.47°）", worst * 180 / PI);
		const auto wall = grids([](double x, double) { return x >= 5.0 ? 10.0 : 0.0; });
		const std::vector<uint8_t> hw = horizon::compute_level(wall, 0, par);
		const int c = (20 * 41 + 20) * 8; // 原点
		const double east = horizon::decode(hw[c + 2]), west = horizon::decode(hw[c + 6]);
		CHECK(std::fabs(east - std::atan(2.0)) < 0.6 * PI / 180, "东边 5 m 外 10 m 高墙：仰角 %.2f°（应 %.2f°）", east * 180 / PI, std::atan(2.0) * 180 / PI);
		CHECK(std::fabs(west) < 0.5 * PI / 180, "背对墙：仰角 %.2f°（应 0）", west * 180 / PI);
		{
			// G2 sun_level：正东方位和 compute_level 的第 2 个方位一致（后者 8 位量化）；斜 60° 看墙，步进误差 ≤ 1.5°
			const std::vector<float> se = horizon::sun_level(wall, 0, par, 0.5 * PI);
			CHECK(std::fabs(se[20 * 41 + 20] - east) < 0.5 * PI / 180, "太阳方位正东：地平线 %.2f°（地平线图 %.2f°）", se[20 * 41 + 20] * 180 / PI, east * 180 / PI);
			const std::vector<float> s60 = horizon::sun_level(wall, 0, par, PI / 3);
			const double want = std::atan(10.0 / (5.0 / std::sin(PI / 3)));
			CHECK(std::fabs(s60[20 * 41 + 20] - want) < 1.5 * PI / 180, "太阳方位 60°：地平线 %.2f°（应 %.2f°）", s60[20 * 41 + 20] * 180 / PI, want * 180 / PI);
			const std::vector<float> sw = horizon::sun_level(wall, 0, par, 1.5 * PI);
			CHECK(std::fabs(sw[20 * 41 + 20]) < 0.1 * PI / 180, "背对墙：%.2f°（应 0）", sw[20 * 41 + 20] * 180 / PI);
		}
		par.planet_radius = 40.0; // 很小的星球：曲率让平地的地平线压到 0 以下（第一步 t = 1 m 处 −t/2R = −0.72°）
		const std::vector<uint8_t> hc = horizon::compute_level(flat, 0, par);
		CHECK(horizon::decode(hc[c + 2]) < -0.4 * PI / 180 && horizon::decode(hc[c + 2]) > -1.2 * PI / 180, "曲率：R = 40 m 时平地地平线 %.2f°（应约 −0.72°）", horizon::decode(hc[c + 2]) * 180 / PI);

		const int w = 256, h = 128, nb = 64, D = 16;
		std::vector<float> ones((size_t)w * h * 3, 1.0f);
		const std::vector<float> T = horizon::sky_table(ones.data(), w, h, 1.0, D, nb);
		auto Vy = [&](int c4, int b) {
			double s = 0;
			for (int k = 0; k < D; k++) {
				s += T[(((size_t)(k * 4 + c4)) * nb + b) * 4 + 1];
			}
			return s;
		};
		CHECK(std::fabs(Vy(0, 0) / (0.75 * PI) - 1) < 0.01, "均匀天空 L = 1：仰角 > −30° 的向上通量 %.4f（应 0.75π = %.4f）", Vy(0, 0), 0.75 * PI);
		const int b0 = (int)std::lround(-horizon::TH_MIN / (horizon::TH_MAX - horizon::TH_MIN) * (nb - 1)); // θ ≈ 0 那一档
		const double th0 = horizon::TH_MIN + (horizon::TH_MAX - horizon::TH_MIN) * b0 / (nb - 1);
		CHECK(std::fabs(Vy(0, b0) / (PI * std::pow(std::cos(th0), 2)) - 1) < 0.01, "θ = %.2f° 以上的向上通量 %.4f（应 π·cos²θ = %.4f）", th0 * 180 / PI, Vy(0, b0), PI * std::pow(std::cos(th0), 2));
		CHECK(std::fabs(Vy(3, b0) - Vy(2, b0)) < 1e-4 && Vy(0, nb - 1) < 1e-3, "L = 1 时几何行 U = V；θ = 90° 时为 0");
		{
			// irradiance_level：平地（全是 θ = 0 的那一档）时 W_U = Σ_k U_k(0)，向上分量 = π
			const int n = 3;
			std::vector<std::vector<uint8_t>> qb(D / 4, std::vector<uint8_t>(n * n * 4, horizon::encode(0.0)));
			std::vector<const uint8_t *> qp;
			for (auto &v : qb) {
				qp.push_back(v.data());
			}
			std::vector<float> a(n * n * 4), b(n * n * 4), cc(n * n * 4);
			horizon::irradiance_level(qp, n, D, T.data(), nb, a.data(), b.data(), cc.data());
			const double up = b[4 * 4 + 3]; // 中心纹素 W_U.y 在 b 的 w 分量
			CHECK(std::fabs(up / PI - 1) < 0.01 && std::fabs(a[4 * 4 + 1] - up) < 1e-3, "平地：Σ U 的向上分量 %.4f ≈ π，均匀天空 W_R.y = %.4f 相同", up, a[4 * 4 + 1]);
		}
		// 性能：601² 一层、stride 2、16 方位
		std::vector<horizon::Grid> big(15);
		for (int k = 0; k < 15; k++) {
			big[k].N = 601;
			big[k].cell = 0.02 * std::pow(2.0, k);
			big[k].half = 6.0 * std::pow(2.0, k);
			big[k].h.resize(601 * 601);
			for (int j = 0; j < 601; j++) {
				for (int i = 0; i < 601; i++) {
					const double x = -big[k].half + i * big[k].cell, z = -big[k].half + j * big[k].cell;
					big[k].h[j * 601 + i] = (float)(3.0 * std::sin(x / 37.0) * std::cos(z / 53.0));
				}
			}
		}
		horizon::Params pp;
		ThreadPool tp(0);
		auto pf = [&](int64_t n, const std::function<void(int64_t)> &fn) { tp.parallel_for(n, fn); };
		const auto t0 = std::chrono::steady_clock::now();
		for (int k : { 0, 7, 14 }) {
			horizon::compute_level(big, k, pp, pf);
		}
		const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
		std::printf("  · 3 层（0、7、14）601² stride 2、16 方位：%.0f ms（%d 线程）\n", ms, tp.threads());
		const auto t1 = std::chrono::steady_clock::now();
		for (int k = 0; k < 15; k++) {
			horizon::sun_level(big, k, pp, 1.0, pf);
		}
		std::printf("  · 太阳方位一次（15 层）：%.0f ms\n", std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t1).count());
	}

	{
		// 半精度：和逐位参考值对拍（1、−2、65504、溢出、次正规、舍入到偶）
		const struct { float f; uint16_t h; } hv[] = { { 1.0f, 0x3c00 }, { -2.0f, 0xc000 }, { 65504.0f, 0x7bff }, { 70000.0f, 0x7c00 },
			{ 5.960464477539063e-08f, 0x0001 }, { 6.103515625e-05f, 0x0400 }, { 1.0009765625f, 0x3c01 }, { 1.00048828125f, 0x3c00 }, { 1.00146484375f, 0x3c02 },
			{ 0.0f, 0x0000 }, { 0.333333343f, 0x3555 } };
		int bad = 0;
		for (const auto &e : hv) {
			bad += horizon::to_half(e.f) != e.h;
		}
		CHECK(bad == 0, "float → 半精度：11 个参考值 %d 个不对", bad);
	}
	std::printf("12. 石块遮地面（G4）\n");
	{
		// 数值积分：朝上半球余弦加权，数射线打中球的比例（经纬网格 2000×500）
		auto numeric = [](double dx, double dy, double dz, double r) {
			const int NA = 2000, NE = 500;
			double hit = 0, tot = 0;
			for (int e = 0; e < NE; e++) {
				const double th = (e + 0.5) / NE * PI / 2; // 天顶角
				const double w = std::cos(th) * std::sin(th);
				for (int a = 0; a < NA; a++) {
					const double ph = (a + 0.5) / NA * 2 * PI;
					const double ux = std::sin(th) * std::cos(ph), uy = std::cos(th), uz = std::sin(th) * std::sin(ph);
					const double b = ux * dx + uy * dy + uz * dz, c = dx * dx + dy * dy + dz * dz - r * r;
					tot += w;
					if (b > 0 && b * b - c >= 0) {
						hit += w;
					}
				}
			}
			return hit / tot;
		};
		double worst = 0;
		const double cases[][4] = { { 0, 3, 0, 1 }, { 2, 0.5, 0, 1 }, { 1.5, 0.2, 0.3, 1 }, { 3, -0.5, 0, 1 }, { 0.6, 0.05, 0, 0.5 }, { 5, 1, 2, 0.7 } };
		for (const auto &c : cases) {
			const double a = rockocc::sphere_occ(c[0], c[1], c[2], c[3]), b = numeric(c[0], c[1], c[2], c[3]);
			worst = std::max(worst, std::fabs(a - b));
		}
		CHECK(worst < 0.004, "球遮挡解析式 vs 数值积分（6 种位置，含跨地平线、球心低于地面）：最大差 %.4f", worst);
		rockocc::Sphere sp;
		sp.x = 0.0f; sp.z = 0.0f; sp.y = 0.05f; sp.r = 0.1f;
		const int n = 101;
		const double cell = 0.01, x0 = -0.505; // 纹素 50 的中心在 0
		const std::vector<uint8_t> v = rockocc::splat({ sp }, x0, x0, cell, n);
		const double want = 1.0 - rockocc::sphere_occ(0.3, 0.05, 0.0, 0.1); // 纹素 (80, 50) 中心 x = 0.3
		CHECK(std::abs(v[50 * n + 80] - want * 255) <= 1.0 && v[50 * n + 50] < 10 && v[0] == 255,
				"单球：30 cm 外可见度 %d（应 %.1f），球下 %d，角上 %d", v[50 * n + 80], want * 255, v[50 * n + 50], v[0]);
		const std::vector<uint8_t> v2 = rockocc::splat({ sp, sp }, x0, x0, cell, n);
		CHECK(std::abs(v2[50 * n + 80] - want * want * 255) <= 1.0, "两块叠在一起：可见度相乘 %d（应 %.1f）", v2[50 * n + 80], want * want * 255);
		// 性能：±10 m、1 cm（2048²），2 万块 r 1–5 cm
		std::vector<rockocc::Sphere> many(20000);
		uint32_t sd = 12345;
		auto rnd = [&]() { sd = sd * 1664525u + 1013904223u; return (sd >> 8) / 16777216.0; };
		for (auto &m : many) {
			m.x = (float)(rnd() * 20 - 10); m.z = (float)(rnd() * 20 - 10); m.r = (float)(0.01 + 0.04 * rnd()); m.y = (float)(m.r * (rnd() - 0.3));
		}
		ThreadPool tp(0);
		auto pf = [&](int64_t k, const std::function<void(int64_t)> &fn) { tp.parallel_for(k, fn); };
		const auto t0 = std::chrono::steady_clock::now();
		rockocc::splat(many, -10.24, -10.24, 0.01, 2048, pf);
		std::printf("  · 2048²、2 万块：%.0f ms（%d 线程）\n", std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count(), tp.threads());
	}

	std::printf("\n%s：%d 项失败\n", g_fail ? "有失败" : "全部通过", g_fail);
	return g_fail ? 1 : 0;
}
