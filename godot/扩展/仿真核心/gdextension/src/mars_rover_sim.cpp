#include "mars_rover_sim.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <limits>
#include <string>

using namespace godot;

MarsRoverSim::MarsRoverSim() {
	sim_.soil = *marsim::find_soil("M90");
	sim_.height = [](double, double) { return 0.0; };
}

void MarsRoverSim::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_height_callable", "callable"), &MarsRoverSim::set_height_callable);
	ClassDB::bind_method(D_METHOD("set_height_grid", "heights", "nx", "nz", "x0", "z0", "cell"), &MarsRoverSim::set_height_grid);
	ClassDB::bind_method(D_METHOD("set_soil", "name"), &MarsRoverSim::set_soil);
	ClassDB::bind_method(D_METHOD("set_soil_params", "params"), &MarsRoverSim::set_soil_params);
	ClassDB::bind_method(D_METHOD("set_geometry", "geometry"), &MarsRoverSim::set_geometry);
	ClassDB::bind_method(D_METHOD("get_soil_names"), &MarsRoverSim::get_soil_names);
	ClassDB::bind_method(D_METHOD("reset", "position", "yaw"), &MarsRoverSim::reset);
	ClassDB::bind_method(D_METHOD("step", "dt", "wheel_omega", "yaw_rate"), &MarsRoverSim::step);
	ClassDB::bind_method(D_METHOD("get_state"), &MarsRoverSim::get_state);
	ClassDB::bind_method(D_METHOD("wheel_query", "load", "slip"), &MarsRoverSim::wheel_query);
}

double MarsRoverSim::sample_grid(double p_x, double p_z) const {
	double fx = (p_x - grid_x0_) / grid_cell_;
	double fz = (p_z - grid_z0_) / grid_cell_;
	if (!std::isfinite(fx) || !std::isfinite(fz)) { // 先挡住 NaN：(int)NaN 在 x86-64 上是 INT_MIN，会越界读
		off_grid_ = true;
		return std::numeric_limits<double>::quiet_NaN(); // 交给 core：这一步不动
	}
	const double mx = grid_nx_ - 1.001, mz = grid_nz_ - 1.001;
	if (fx < 0.0 || fz < 0.0 || fx > mx || fz > mz) {
		off_grid_ = true; // 网格外按边缘值钳位，结果是假的：报告给 GDScript
		fx = std::clamp(fx, 0.0, mx);
		fz = std::clamp(fz, 0.0, mz);
	}
	const int i = int(fx), j = int(fz);
	const double tx = fx - i, tz = fz - j;
	const float *h = grid_.ptr();
	const int64_t o = int64_t(j) * grid_nx_ + i;
	const double a = h[o] + (h[o + 1] - h[o]) * tx;
	const double b = h[o + grid_nx_] + (h[o + grid_nx_ + 1] - h[o + grid_nx_]) * tx;
	return a + (b - a) * tz;
}

void MarsRoverSim::update_height_fn() {
	if (use_grid_) {
		sim_.height = [this](double x, double z) { return sample_grid(x, z); };
	} else if (height_callable_.is_valid()) {
		sim_.height = [this](double x, double z) { return double(height_callable_.call(x, z)); };
	} else {
		sim_.height = [](double, double) { return 0.0; };
	}
}

void MarsRoverSim::set_height_callable(const Callable &p_callable) {
	height_callable_ = p_callable;
	use_grid_ = false;
	update_height_fn();
}

void MarsRoverSim::set_height_grid(const PackedFloat32Array &p_heights, int p_nx, int p_nz, double p_x0, double p_z0, double p_cell) {
	ERR_FAIL_COND_MSG(p_nx < 2 || p_nz < 2 || p_heights.size() != int64_t(p_nx) * p_nz || p_cell <= 0.0, "set_height_grid: heights.size() must be nx*nz, nx, nz >= 2, cell > 0");
	grid_ = p_heights;
	grid_nx_ = p_nx;
	grid_nz_ = p_nz;
	grid_x0_ = p_x0;
	grid_z0_ = p_z0;
	grid_cell_ = p_cell;
	use_grid_ = true;
	update_height_fn();
}

bool MarsRoverSim::set_soil(const String &p_name) {
	const marsim::Soil *s = marsim::find_soil(p_name.utf8().get_data());
	ERR_FAIL_NULL_V_MSG(s, false, "Unknown soil: " + p_name);
	sim_.soil = *s;
	return true;
}

bool MarsRoverSim::set_soil_params(const Dictionary &p_params) {
	marsim::Soil s = sim_.soil;
	s.name = "custom";
	s.n = double(p_params.get("n", s.n));
	s.kc = double(p_params.get("kc", s.kc));
	s.kphi = double(p_params.get("kphi", s.kphi));
	s.c = double(p_params.get("c", s.c));
	s.phi_deg = double(p_params.get("phi_deg", s.phi_deg));
	s.K = double(p_params.get("K", s.K));
	std::string why;
	ERR_FAIL_COND_V_MSG(!marsim::soil_valid(s, &why), false, String("set_soil_params: ") + why.c_str());
	sim_.soil = s;
	return true;
}

bool MarsRoverSim::set_geometry(const Dictionary &p_geometry) {
	marsim::RoverGeometry g = sim_.geom;
#define GEO(m_name) g.m_name = double(p_geometry.get(#m_name, g.m_name))
	GEO(mass);
	GEO(half_track);
	GEO(pivot_f);
	GEO(pivot_u);
	GEO(front_f);
	GEO(front_u);
	GEO(bogie_f);
	GEO(bogie_u);
	GEO(middle_f);
	GEO(middle_u);
	GEO(rear_f);
	GEO(rear_u);
	GEO(com_f);
	GEO(com_u);
	GEO(com_r);
	GEO(rocker_limit);
	GEO(bogie_limit);
#undef GEO
	g.wheel.r = double(p_geometry.get("wheel_radius", g.wheel.r));
	g.wheel.b = double(p_geometry.get("wheel_width", g.wheel.b));
	g.wheel.grouser = double(p_geometry.get("grouser", g.wheel.grouser));
	std::string why;
	ERR_FAIL_COND_V_MSG(!marsim::wheel_valid(g.wheel, &why), false, String("set_geometry: ") + why.c_str());
	ERR_FAIL_COND_V_MSG(!(g.mass > 0.0) || !(g.half_track > 0.0) || !(g.rocker_limit > 0.0) || !(g.bogie_limit > 0.0), false, "set_geometry: mass, half_track, rocker_limit, bogie_limit must be > 0");
	// 摇臂和转向架的力臂不能为零（loads() 里要除）
	ERR_FAIL_COND_V_MSG(std::fabs(g.front_f - g.bogie_f) < 1e-3 || std::fabs(g.rear_f - g.middle_f) < 1e-3, false, "set_geometry: front/bogie or middle/rear wheels coincide");
	sim_.geom = g;
	return true;
}

PackedStringArray MarsRoverSim::get_soil_names() const {
	PackedStringArray out;
	for (const marsim::Soil &s : marsim::soil_presets()) {
		out.push_back(String::utf8(s.name.c_str()));
	}
	return out;
}

void MarsRoverSim::reset(const Vector3 &p_position, double p_yaw) {
	sim_.reset(p_position.x, p_position.z, p_yaw);
}

Dictionary MarsRoverSim::step(double p_dt, double p_wheel_omega, double p_yaw_rate) {
	ERR_FAIL_COND_V_MSG(!std::isfinite(p_dt) || !std::isfinite(p_wheel_omega) || !std::isfinite(p_yaw_rate), get_state(), "MarsRoverSim.step: non-finite input");
	off_grid_ = false;
	sim_.step(p_dt, p_wheel_omega, p_yaw_rate);
	return get_state();
}

Dictionary MarsRoverSim::get_state() const {
	const marsim::RoverState &st = sim_.state;
	Dictionary d;
	d["position"] = Vector3(st.x, st.y, st.z);
	d["yaw"] = st.yaw;
	d["pitch"] = st.pitch;
	d["roll"] = st.roll;
	d["rocker"] = st.rocker;
	d["bogie_left"] = st.bogie_l;
	d["bogie_right"] = st.bogie_r;
	d["speed"] = st.speed;
	d["slip"] = st.slip;
	d["slope_deg"] = st.slope_deg;
	d["stuck"] = st.stuck;
	d["skidding"] = st.skidding; // 下坡刹不住
	d["off_grid"] = off_grid_; // 本步取高出了网格：该重传 set_height_grid
	d["slip_evaluations"] = st.slip_evaluations;
	d["kinematics_ok"] = st.kinematics_ok;
	d["power"] = st.power;
	Array wheels;
	for (const marsim::WheelOut &w : st.wheels) {
		Dictionary wd;
		wd["center"] = Vector3(w.center.x, w.center.y, w.center.z);
		wd["load"] = w.load;
		wd["sinkage"] = w.sinkage;
		wd["drawbar_pull"] = w.DP;
		wd["torque"] = w.torque;
		wd["gap"] = w.gap;
		wheels.push_back(wd);
	}
	d["wheels"] = wheels; // 顺序：左前、左中、左后、右前、右中、右后
	return d;
}

Dictionary MarsRoverSim::wheel_query(double p_load, double p_slip) const {
	ERR_FAIL_COND_V_MSG(!std::isfinite(p_load) || !std::isfinite(p_slip), Dictionary(), "wheel_query: non-finite input");
	const marsim::WheelState w = marsim::wheel_at_load(sim_.geom.wheel, sim_.soil, p_load, p_slip, sim_.model);
	Dictionary d;
	d["sinkage"] = w.sinkage;
	d["drawbar_pull"] = w.DP;
	d["torque"] = w.T;
	d["theta1"] = w.theta1;
	d["ok"] = w.ok;
	return d;
}
