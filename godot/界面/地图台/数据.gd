# 地图台数据：高度金字塔（GPU 纹理数组 + CPU 副本，同一个取高函数）、路线、已探索点云、机位。
#   取高同 docs/界面/地图样张/生成/全息.py 的 高()：15 层 601²，[层][z][x]，8 字节头，半宽 6·2^k m；每点取包含它的最细一层（从 kmin 起），外缘 15 % 和下一层交叉淡化。
extends RefCounted

var 目录: String
var 层: Array[PackedFloat32Array] = []
var 纹: Texture2DArray
var 底纹: Texture2D
var 机位: Dictionary = {}
var 路sol := PackedInt32Array()
var 路E := PackedFloat32Array()
var 路N := PackedFloat32Array()
var 段起: Array = []
var 点 := PackedVector2Array()
var kminf := 8.0                                  # CPU 取高用的最细层（连续值，和着色器的 kmin_f 同一个，两侧画出来和点出来的是同一张面）
var 好 := false


func 载(目录_: String) -> bool:
	目录 = 目录_
	var f := FileAccess.open(目录 + "heights.bin", FileAccess.READ)
	if f == null: return false
	var b := f.get_buffer(f.get_length()); f.close()
	var imgs: Array[Image] = []
	var n := 601*601
	for k in 15:
		var seg := b.slice(8 + k*n*4, 8 + (k + 1)*n*4)
		层.append(seg.to_float32_array())
		imgs.append(Image.create_from_data(601, 601, false, Image.FORMAT_RF, seg))
	纹 = Texture2DArray.new(); 纹.create_from_images(imgs)
	机位 = JSON.parse_string(FileAccess.get_file_as_string(目录 + "地图台机位.json"))
	var r = JSON.parse_string(FileAccess.get_file_as_string(目录 + "地图台路线.json"))
	路sol = PackedInt32Array(r["sol"]); 路E = PackedFloat32Array(r["E"]); 路N = PackedFloat32Array(r["N"]); 段起 = r["段起"]
	var pb := FileAccess.get_file_as_bytes(目录 + "地图台已探索.bin").to_float32_array()
	点.resize(pb.size()/2)
	for i in 点.size(): 点[i] = Vector2(pb[2*i], pb[2*i + 1])
	var bi := Image.load_from_file(目录 + "地图台底.png")
	if bi: 底纹 = ImageTexture.create_from_image(bi)
	好 = true
	return true


func _采(k: int, E: float, N: float) -> float:
	var hf := 6.0*pow(2.0, k); var sp := 2.0*hf/600.0
	var fi := (E + hf)/sp; var fj := (-N + hf)/sp
	var i0 := clampi(int(floor(fi)), 0, 599); var j0 := clampi(int(floor(fj)), 0, 599)
	var tx := fi - i0; var ty := fj - j0; var A: PackedFloat32Array = 层[k]
	var a := A[j0*601 + i0]; var b := A[j0*601 + i0 + 1]; var c := A[(j0 + 1)*601 + i0]; var d := A[(j0 + 1)*601 + i0 + 1]
	return (a*(1.0 - tx) + b*tx)*(1.0 - ty) + (c*(1.0 - tx) + d*tx)*ty


func _hk(E: float, N: float, kmin: int) -> float:
	var r := maxf(absf(E), absf(N))
	var k := clampi(ceili(log(maxf(r, 1.0)/5.97)/log(2.0)), kmin, 14)
	var hf := 6.0*pow(2.0, k)
	var h := _采(k, E, N)
	if k < 14:
		var t := clampf((r/hf - 0.82)/0.15, 0.0, 1.0); t = t*t*(3.0 - 2.0*t)
		if t > 0.0: h = h*(1.0 - t) + _采(k + 1, E, N)*t
	return h


func 高(E: float, N: float) -> float:
	"""站点系高度（m，相对原点）。层间交叉淡化和 高度.gdshaderinc 的 H() 完全一致。"""
	var k0 := floorf(kminf)
	var w := smoothstep(0.3, 0.7, kminf - k0)
	var a := _hk(E, N, int(k0))
	if w > 0.001: return lerpf(a, _hk(E, N, int(k0) + 1), w)
	return a


func 坡(E: float, N: float, d := 5.0) -> float:
	var hx := 高(E + d, N) - 高(E - d, N); var hy := 高(E, N + d) - 高(E, N - d)
	return rad_to_deg(atan(Vector2(hx, hy).length()/(2.0*d)))
