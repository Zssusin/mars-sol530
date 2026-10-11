// GDExtension 绑定：把 core/ 的六轮车准静态仿真和轮土力学暴露给 GDScript。
#pragma once

#include "rocker_bogie.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

namespace godot {

// 高度来源二选一：
//  set_height_callable(Callable)  每次取高调用 GDScript（如 地形LOD.h_cpu），简单但慢（每步几百次调用）；
//  set_height_grid(...)           传一块规则网格（行 = z、列 = x），双线性插值，快。车走出网格范围前由 GDScript 重新传。
class MarsRoverSim : public RefCounted {
	GDCLASS(MarsRoverSim, RefCounted)

	marsim::RockerBogieSim sim_;
	Callable height_callable_;
	PackedFloat32Array grid_;
	int grid_nx_ = 0, grid_nz_ = 0;
	double grid_x0_ = 0, grid_z0_ = 0, grid_cell_ = 1;
	bool use_grid_ = false;
	mutable bool off_grid_ = false; // 本步取高时出过网格（或坐标非有限）：车快走出网格了，GDScript 该重传

	double sample_grid(double p_x, double p_z) const;
	void update_height_fn();

protected:
	static void _bind_methods();

public:
	MarsRoverSim();

	void set_height_callable(const Callable &p_callable);
	void set_height_grid(const PackedFloat32Array &p_heights, int p_nx, int p_nz, double p_x0, double p_z0, double p_cell);

	bool set_soil(const String &p_name); // "M90" / "GRC-3" / "压实风化层"
	bool set_soil_params(const Dictionary &p_params); // {n, kc, kphi, c, phi_deg, K}（SI 单位，同 core/Soil）；不合法时报错、保持原参数
	bool set_geometry(const Dictionary &p_geometry); // RoverGeometry 的同名字段，只改给出的；不合法时报错、保持原参数
	PackedStringArray get_soil_names() const;

	void reset(const Vector3 &p_position, double p_yaw);
	Dictionary step(double p_dt, double p_wheel_omega, double p_yaw_rate);
	Dictionary get_state() const;

	// 单轮查询（不需要地形）：载荷 N、滑转率 → {sinkage, drawbar_pull, torque, theta1, ok}
	Dictionary wheel_query(double p_load, double p_slip) const;
};

} // namespace godot
