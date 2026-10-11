extends SceneTree
# 量 NASA 毅力号模型的车轮 → 数据/sol0530/rover_rig.json（66_车辆动画.py 和 实景.gd 的车轮拆分都读它）。
# 模型坐标：+y 上、+z 前、+x 左。Wheels_objs 是六个轮子合成的一块网格：按 x 正负 × z 前中后分成六个，取包围盒中心和半高。
# 运行：godot --headless --path godot --script res://工具/量车轮.gd
func rel(n: Node3D, top: Node3D) -> Transform3D:
	var t := Transform3D()
	while n != top:
		t = n.transform*t
		n = n.get_parent() as Node3D
	return t

func _init() -> void:
	var D := "res://数据/sol0530/"
	var J: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(D + "scene.json"))
	var doc := GLTFDocument.new(); var st := GLTFState.new()
	doc.append_from_file(ProjectSettings.globalize_path(D + J["rover"]["file"]), st)
	var model: Node3D = doc.generate_scene(st)
	var wm := model.find_child("Wheels_objs", true, false) as MeshInstance3D
	var nav := model.find_child("NavCams", true, false) as MeshInstance3D
	var M := rel(wm, model)
	var wheels := []
	for side in [1.0, -1.0]:
		for zc in [1.1, 0.0, -1.1]:
			var lo := Vector3(1e9, 1e9, 1e9); var hi := -lo
			for s in wm.mesh.get_surface_count():
				for v in wm.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]:
					var w: Vector3 = M*v
					if signf(w.x) == side and absf(w.z - zc) < 0.45: lo = lo.min(w); hi = hi.max(w)
			var c := (lo + hi)/2.0
			wheels.append({"c": [c.x, c.y, c.z], "r": (hi.y - lo.y)/2.0, "w": hi.x - lo.x, "corner": absf(zc) > 0.5})
	var ab := nav.get_aabb(); var xf := rel(nav, model); var pc := Vector3.ZERO
	for k in 8: pc += xf*ab.get_endpoint(k)
	pc /= 8.0
	var out := {"说明": "NASA 毅力号模型（rover.glb）的车轮，模型坐标 +y 上、+z 前、+x 左；c 轮心、r 半径、w 宽；corner＝能转向的角轮。由 工具/量车轮.gd 生成。",
		"wheels": wheels, "navcams_center": [pc.x, pc.y, pc.z]}
	var f := FileAccess.open(D + "rover_rig.json", FileAccess.WRITE); f.store_string(JSON.stringify(out, " ")); f.close()
	print("[量车轮] ", wheels.size(), " 个轮子 → rover_rig.json")
	quit()
