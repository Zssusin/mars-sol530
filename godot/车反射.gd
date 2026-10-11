# 车反射（实景地形系统.md §17.1）：跟着毅力号的盒投影反射探针，让车身反射脚下真实的地面（含车自己的影子）、石块和天空，
# 不再只反射天空环境图（环境图的下半球是一块均匀的地面辐亮度，没有车影、没有近处的明暗）。
# - 只有车收这个探针（reflection_mask = 车层），探针也不拍车自己（cull_mask 去掉车层）：车放到第 20 层，别的东西都在第 1 层。
# - UPDATE_ONCE：Godot 在一帧里画完 6 个面（引擎 renderer_scene_cull.cpp _render_reflection_probe_step），之后几帧做粗糙度滤波。
#   探针只在 车走过 ≥ 步长、太阳方向变了 ≥ 阈值、换天空 时挪一下 / 重画，平时不花时间。
# - 盒子：底面贴着车原点（轮底）所在的地面，拍摄点在地面上方 拍高 m；盒投影让近处地面的反射位置对得上（视差）。
# 开关：--车反射=0（默认）/ ssr / 探针 / 探针+ssr；--探针步=2（m）、--探针盒=8（m，水平边长）、--探针盒高=6、--探针高=1（m，拍摄点离地）、
#       --探针距=60（m）、--探针强度=1、--探针LOD=4、--探针影=0；--探针测=N 每 N 帧强制重画（测帧用）。
# 代价（2560×1440、测试机，§17.1）：平时 +0.2–0.3 ms（集群里多一个探针）；重画那一帧 +5 ms（画影子 +8 ms，但实测反射里看不出差别，默认不画），所以步长取 2 m。
extends Node

const ROVER_LAYER := 1 << 19                                       # 第 20 层：只放车
var P: Node                                                        # 实景
var probe: ReflectionProbe
var step_m := 2.0
var sun_deg := 0.5
var last_pos := Vector3(INF, INF, INF)
var last_sun := Vector3.ZERO
var last_sky := ""
var n_update := 0
var force_n := 0                                                   # --探针测=N：每 N 帧强制重画一次（测帧量重画的代价）
var frame := 0
var layered := 0                                                   # 已挪到车层的件数（rig_rover 拆网格后会多出新件，所以每次更新都扫一遍）


func setup(p: Node) -> void:
	P = p
	step_m = float(P.args.get("探针步", "2"))
	force_n = int(P.args.get("探针测", "0"))


# 探针等第一帧再建：rig_rover 在 rover_materials 之后才把网格拆成新件，要先把所有件放到车层再把探针加进场景。
# Godot 只在包围盒「新重叠」时按 reflection_mask 配对（renderer_scene_cull.cpp _instance_pair），之后改 layers 不会重配，
# 所以顺序反了的话车永远收不到这个探针（第一版就是这样，反射图和不开探针一模一样）。
func make_probe() -> void:
	var a: Dictionary = P.args
	var S := float(a.get("探针盒", "8")); var H := float(a.get("探针盒高", "6")); var eye := float(a.get("探针高", "1"))
	probe = ReflectionProbe.new(); probe.name = "车反射探针"
	probe.update_mode = ReflectionProbe.UPDATE_ONCE
	probe.box_projection = true
	probe.size = Vector3(S, H, S)
	probe.origin_offset = Vector3(0.0, -H*0.5 + eye, 0.0)          # 节点放在盒子中心，盒底 = 地面
	probe.max_distance = float(a.get("探针距", "60"))
	probe.cull_mask = 0xFFFFF & ~ROVER_LAYER
	probe.reflection_mask = ROVER_LAYER
	probe.ambient_mode = ReflectionProbe.AMBIENT_DISABLED          # 只管反射；漫反射的环境光照旧（天空 + 地平线 GI + 车 AO，§17 已按照片定标）
	probe.enable_shadows = P.args.get("探针影", "0") == "1"
	probe.intensity = float(a.get("探针强度", "1"))
	probe.mesh_lod_threshold = float(a.get("探针LOD", "4"))
	probe.position = P.rover_root.global_position + Vector3(0.0, H*0.5, 0.0)
	P.add_child(probe)
	print("[实景] 车反射探针：盒 %.0f×%.0f×%.0f m、拍高 %.1f m、步长 %.1f m" % [S, H, S, eye, step_m])


func _process(_dt: float) -> void:
	var rr: Node3D = P.rover_root
	if rr == null: return
	if probe == null: _layers(rr); make_probe()
	var pos: Vector3 = rr.global_position
	var sd: Vector3 = P.sun.global_transform.basis.z if P.sun else Vector3.UP
	var sky: String = str(P.get("sky_now"))
	var moved := pos.distance_to(last_pos) >= step_m
	var lit := rad_to_deg(sd.angle_to(last_sun)) >= sun_deg or sky != last_sky
	frame += 1
	if force_n > 0 and frame % force_n == 0: lit = true
	if not (moved or lit): return
	_layers(rr)
	# 挪节点（transform 变）会让 Godot 把探针标脏、下一帧重画；只是光变了不挪时，用 0.1 mm 抖动触发
	var H := probe.size.y
	var c := pos + Vector3(0.0, H*0.5, 0.0)
	if not moved: c.x += 1e-4 if (n_update & 1) == 0 else -1e-4
	probe.global_position = c
	last_pos = pos if moved else last_pos; last_sun = sd; last_sky = sky
	n_update += 1


func _layers(rr: Node3D) -> void:
	var n := 0
	for g in rr.find_children("*", "VisualInstance3D", true, false):
		var v := g as VisualInstance3D
		if v.layers != ROVER_LAYER: v.layers = ROVER_LAYER; n += 1
	layered += n
	if n > 0 and n_update == 0: print("[实景] 车反射：%d 件放到车层" % n)
