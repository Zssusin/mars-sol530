extends SceneTree
# 诊断：Godot 导入后的毅力号材质（两个 glb 对比）。运行：godot --headless --path godot --script res://工具/材质清单.gd [-- --文件=rover_ao.glb]
func tex_desc(t: Texture2D) -> String:
	if t == null: return "-"
	var nm := t.resource_path.get_file() if t.resource_path != "" else t.resource_name
	var img := t.get_image()
	return "%s(%dx%d)" % [nm, t.get_width(), t.get_height()]

func rel(n: Node3D, top: Node3D) -> Transform3D:
	var t := Transform3D()
	while n != top and n != null:
		t = n.transform*t
		n = n.get_parent() as Node3D
	return t

var MODEL: Node3D
func tri_area(mi: MeshInstance3D, s: int) -> float:
	var a := mi.mesh.surface_get_arrays(s)
	var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]; var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
	var xf := rel(mi, MODEL)
	var A := 0.0
	if idx.size() == 0:
		for i in range(0, v.size(), 3): A += ((xf*v[i+1] - xf*v[i]).cross(xf*v[i+2] - xf*v[i])).length()*0.5
	else:
		for i in range(0, idx.size(), 3): A += ((xf*v[idx[i+1]] - xf*v[idx[i]]).cross(xf*v[idx[i+2]] - xf*v[idx[i]])).length()*0.5
	return A

func _init() -> void:
	var D := "res://数据/sol0530/"
	var files := ["rover.glb", "rover_ao.glb"]
	var out := {}
	for f in files:
		var doc := GLTFDocument.new(); var st := GLTFState.new()
		doc.append_from_file(ProjectSettings.globalize_path(D + f), st)
		var model: Node3D = doc.generate_scene(st)
		MODEL = model
		var mats := {}
		for g in model.find_children("*", "MeshInstance3D", true, false):
			var mi := g as MeshInstance3D
			for s in mi.mesh.get_surface_count():
				var m := mi.get_active_material(s) as BaseMaterial3D
				if m == null: continue
				var k := m.resource_name
				if not mats.has(k):
					mats[k] = {"albedo": "%.3f,%.3f,%.3f,%.3f" % [m.albedo_color.r, m.albedo_color.g, m.albedo_color.b, m.albedo_color.a],
						"alb_tex": tex_desc(m.albedo_texture), "metal": m.metallic, "rough": m.roughness, "spec": m.metallic_specular,
						"mr_tex": tex_desc(m.metallic_texture), "m_ch": m.metallic_texture_channel, "r_tex": tex_desc(m.roughness_texture), "r_ch": m.roughness_texture_channel,
						"normal": tex_desc(m.normal_texture) if m.normal_enabled else "-", "nscale": m.normal_scale,
						"transp": m.transparency, "cull": m.cull_mode, "emis": m.emission_enabled, "uv1": str(m.uv1_scale),
						"area": 0.0, "nodes": []}
				mats[k]["area"] += tri_area(mi, s)
				if mats[k]["nodes"].size() < 40 and not (mi.name in mats[k]["nodes"]): mats[k]["nodes"].append(String(mi.name))
		out[f] = mats
		print("== %s：%d 个材质" % [f, mats.size()])
		var ks := mats.keys(); ks.sort_custom(func(a, b): return mats[a]["area"] > mats[b]["area"])
		for k in ks:
			var m: Dictionary = mats[k]
			print("%-34s A=%6.2fm² alb=%s tex=%s M=%.2f R=%.2f mr=%s/%d,%s/%d N=%s(%.2f) tr=%d cull=%d uv=%s %s" % [k, m["area"], m["albedo"], m["alb_tex"], m["metal"], m["rough"], m["mr_tex"], m["m_ch"], m["r_tex"], m["r_ch"], m["normal"], m["nscale"], m["transp"], m["cull"], m["uv1"], ",".join(m["nodes"])])
	var a: Dictionary = out["rover.glb"]; var b: Dictionary = out["rover_ao.glb"]
	print("== 差异（rover.glb → rover_ao.glb）")
	for k in a.keys():
		if not b.has(k): print("缺：", k); continue
		for p in ["albedo", "metal", "rough", "spec", "m_ch", "r_ch", "nscale", "transp", "cull", "uv1"]:
			if str(a[k][p]) != str(b[k][p]): print("%s.%s: %s → %s" % [k, p, a[k][p], b[k][p]])
		for p in ["alb_tex", "mr_tex", "r_tex", "normal"]:
			if str(a[k][p]).replace("rover_ao_", "rover_") != str(b[k][p]).replace("rover_ao_", "rover_"): print("%s.%s: %s → %s" % [k, p, a[k][p], b[k][p]])
	for k in b.keys():
		if not a.has(k): print("多：", k)
	quit()
