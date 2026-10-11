extends SceneTree
# 诊断：毅力号各网格在模型坐标（+y 上、+z 前、+x 左）里的包围盒。运行：godot --headless --path godot --script res://工具/车部件框.gd
func rel(n: Node3D, top: Node3D) -> Transform3D:
	var t := Transform3D()
	while n != top and n != null:
		t = n.transform*t
		n = n.get_parent() as Node3D
	return t
func _init() -> void:
	var doc := GLTFDocument.new(); var st := GLTFState.new()
	doc.append_from_file(ProjectSettings.globalize_path("res://数据/sol0530/rover_ao.glb"), st)
	var model: Node3D = doc.generate_scene(st)
	for g in model.find_children("*", "MeshInstance3D", true, false):
		var mi := g as MeshInstance3D; var xf := rel(mi, model); var ab := mi.get_aabb()
		var lo := Vector3(INF, INF, INF); var hi := -lo
		for k in 8: var p := xf*ab.get_endpoint(k); lo = lo.min(p); hi = hi.max(p)
		var sz := hi - lo
		var ms := []
		for s in mi.mesh.get_surface_count():
			var m := mi.get_active_material(s)
			if m: ms.append(m.resource_name)
		print("%-26s c=(%.2f,%.2f,%.2f) s=(%.2f,%.2f,%.2f) %s" % [mi.name, (lo.x+hi.x)/2, (lo.y+hi.y)/2, (lo.z+hi.z)/2, sz.x, sz.y, sz.z, ",".join(ms)])
	quit()
