extends SceneTree
# 材质纹理数组打包（scripts/Godot/73_材质规则.py 导出 调用）：每层原始数据（RGBA8 / RG8 / R16，512²，第 0 行在南）→ 生成 mip →
# 压缩（BC7 用 cvtt、BC5 用 etcpak，都只在编辑器版里）→ 写成 DX10 头的 DDS 数组（运行时 load() 直接得到 Texture2DArray）。
# 用法：godot --headless --path godot --script res://工具/打包材质.gd -- <任务.json>
# 任务.json：{"arrays": [{"out": 路径, "layers": [每层 .raw], "w", "h", "src": "RGBA8|RG8|R16", "压缩": "BC7|BC5|R16", "dxgi": 98|83|56}]}

const SRC := {"RGBA8": Image.FORMAT_RGBA8, "RG8": Image.FORMAT_RG8, "R16": Image.FORMAT_R16}


func _init() -> void:
	var a := OS.get_cmdline_user_args()
	var job: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(a[0]))
	for arr in job["arrays"]:
		var t0 := Time.get_ticks_msec()
		var imgs: Array[Image] = []
		for f in arr["layers"]:
			var img := Image.create_from_data(int(arr["w"]), int(arr["h"]), false, SRC[arr["src"]], FileAccess.get_file_as_bytes(f))
			img.generate_mipmaps()
			match arr["压缩"]:
				"BC7": img.compress(Image.COMPRESS_BPTC, Image.COMPRESS_SOURCE_GENERIC)
				"BC5": img.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_GENERIC)   # RG 源 → RGTC_RG（BC5，etcpak）
			imgs.append(img)
		var err := write_dds(arr["out"], imgs, int(arr["dxgi"]))
		print("[打包材质] %s：%d 层 %s，格式 %s，%d 级 mip，%.1f MB，%d ms%s" % [String(arr["out"]).get_file(), imgs.size(), arr["压缩"],
			str(imgs[0].get_format()), imgs[0].get_mipmap_count() + 1,
			FileAccess.get_file_as_bytes(arr["out"]).size()/1e6, Time.get_ticks_msec() - t0, "" if err == OK else "，写入失败 %d" % err])
	quit()


# DDS（Microsoft DDS_HEADER + DDS_HEADER_DXT10）：每个数组元素依次存全部 mip，和 Godot Image 的数据排布一致
func write_dds(path: String, imgs: Array[Image], dxgi: int) -> Error:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null: return FileAccess.get_open_error()
	var im := imgs[0]
	f.store_32(0x20534444)                                          # "DDS "
	f.store_32(124)
	f.store_32(0x1 | 0x2 | 0x4 | 0x1000 | 0x20000 | 0x80000)        # CAPS HEIGHT WIDTH PIXELFORMAT MIPMAPCOUNT LINEARSIZE
	f.store_32(im.get_height()); f.store_32(im.get_width())
	f.store_32(im.get_mipmap_offset(1) if im.has_mipmaps() else im.get_data_size())
	f.store_32(0)                                                   # depth
	f.store_32(im.get_mipmap_count() + 1)
	for i in 11: f.store_32(0)
	f.store_32(32); f.store_32(0x4); f.store_32(0x30315844)         # DDS_PIXELFORMAT：FOURCC "DX10"
	for i in 5: f.store_32(0)
	f.store_32(0x1000 | 0x400000 | 0x8)                             # TEXTURE | MIPMAP | COMPLEX
	for i in 4: f.store_32(0)
	f.store_32(dxgi); f.store_32(3); f.store_32(0); f.store_32(imgs.size()); f.store_32(0)   # DXGI 格式、TEXTURE2D、数组长度
	for img in imgs: f.store_buffer(img.get_data())
	f.close()
	return OK
