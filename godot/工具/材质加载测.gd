extends SceneTree
# 材质纹理数组的加载时间（73_材质规则.py 加载测 调用；要真显卡就在 kwin 虚拟合成器里跑，否则 --headless 只量 CPU 一侧）。
# 三种方式：① load() DDS（引擎 DDS 加载器 → Texture2DArray）；② 自己读 DDS、Image.create_from_data 拼数组；
# ③ 运行时从原始 RGBA8 生成 mip 再 Image.compress（BC7 要编辑器版的 cvtt，导出模板默认没有）。另量控制图（RGBA8 原始数据 → ImageTexture）。
# 用法：godot --path godot --script res://工具/材质加载测.gd -- <数据目录 res://…/> <导出暂存目录（绝对路径）>

func ms(t: int) -> float: return (Time.get_ticks_usec() - t)/1000.0


func _init() -> void:
	var a := OS.get_cmdline_user_args(); var D: String = a[0]; var stage: String = a[1]
	var man: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(D + "mat.json"))
	print("[加载测] 渲染器 %s，%s" % [RenderingServer.get_current_rendering_method(), RenderingServer.get_video_adapter_name()])
	var tot := 0.0
	for k in man["数组"]:
		var f: String = D + man["数组"][k]["file"]
		var t := Time.get_ticks_usec()
		var tex = ResourceLoader.load(f, "", ResourceLoader.CACHE_MODE_IGNORE)
		var dt := ms(t); tot += dt
		var info := "失败"
		if tex is Texture2DArray: info = "Texture2DArray %d 层 %d² 格式 %d mip %s" % [tex.get_layers(), tex.get_width(), tex.get_format(), str(tex.has_mipmaps())]
		elif tex: info = tex.get_class()
		print("[加载测] ① load() %s：%.1f ms，%s" % [k, dt, info])
	print("[加载测] ① 合计 %.1f ms" % tot)
	tot = 0.0
	for k in man["数组"]:
		var t := Time.get_ticks_usec()
		var arr := read_dds(D + man["数组"][k]["file"])
		var dt := ms(t); tot += dt
		print("[加载测] ② 自己读 %s：%.1f ms，%d 层" % [k, dt, arr.get_layers() if arr else -1])
	print("[加载测] ② 合计 %.1f ms" % tot)
	# ③ 运行时压缩：中观 ah（BC7）、d（BC5）
	for kind in [["ah", Image.FORMAT_RGBA8, Image.COMPRESS_BPTC], ["d", Image.FORMAT_RG8, Image.COMPRESS_S3TC]]:
		var t := Time.get_ticks_usec(); var imgs: Array[Image] = []
		var files := DirAccess.get_files_at(stage)
		for fn in files:
			if fn.begins_with("中观_") and fn.ends_with("_%s.raw" % kind[0]):
				var img := Image.create_from_data(int(man["层"]), int(man["层"]), false, kind[1], FileAccess.get_file_as_bytes(stage.path_join(fn)))
				img.generate_mipmaps(); img.compress(kind[2]); imgs.append(img)
		var arr := Texture2DArray.new(); arr.create_from_images(imgs)
		print("[加载测] ③ 运行时压缩 中观 %s：%d 层 %.1f ms" % [kind[0], imgs.size(), ms(t)])
	# BC7 误差：中观 ah 第 0 层 mip 0 解压后和原始字节比
	var tex: Texture2DArray = ResourceLoader.load(D + man["数组"]["mat_meso_ah"]["file"], "", ResourceLoader.CACHE_MODE_IGNORE)
	var im := tex.get_layer_data(0); im.clear_mipmaps(); im.decompress()
	var raw := FileAccess.get_file_as_bytes(stage.path_join("中观_M1_0_ah.raw"))
	var got := im.get_data(); var e := [0.0, 0.0, 0.0, 0.0]; var mx := 0
	for i in range(0, raw.size(), 4*7):                             # 隔 7 个像素抽样
		for c in 4:
			var d := absi(int(got[i + c]) - int(raw[i + c])); e[c] += d; mx = maxi(mx, d)
	var n := raw.size()/(4*7)
	print("[加载测] BC7 误差（第 0 层 = M1_1，第 0 级，8 位单位）：R %.2f G %.2f B %.2f A %.2f，最大 %d" % [e[0]/n, e[1]/n, e[2]/n, e[3]/n, mx])
	# 控制图
	for fn in ["mat_ctrl_4cm.bin", "mat_ctrl_1m.bin"]:
		var t := Time.get_ticks_usec()
		var b := FileAccess.get_file_as_bytes(D + fn); var hd := b.slice(0, 8).to_int32_array()
		var img := Image.create_from_data(hd[0], hd[1], false, Image.FORMAT_RGBA8, b.slice(8))
		var it := ImageTexture.create_from_image(img)
		print("[加载测] 控制图 %s：%d²，%.1f ms" % [fn, hd[0], ms(t)])
	quit()


func read_dds(path: String) -> Texture2DArray:
	var b := FileAccess.get_file_as_bytes(path)
	var h := b.slice(0, 148).to_int32_array()                       # 4 + 124 + 20
	var H := h[3]; var W := h[4]; var mips := h[7]
	var dxgi := h[32]; var n := h[35]
	var fmt: int = {98: Image.FORMAT_BPTC_RGBA, 83: Image.FORMAT_RGTC_RG, 56: Image.FORMAT_R16}[dxgi]
	var size := Image.create_empty(W, H, mips > 1, fmt).get_data_size()   # 一层（含全部 mip）的字节数
	var imgs: Array[Image] = []; var o := 148
	for i in n:
		imgs.append(Image.create_from_data(W, H, mips > 1, fmt, b.slice(o, o + size))); o += size
	var arr := Texture2DArray.new(); arr.create_from_images(imgs)
	return arr
