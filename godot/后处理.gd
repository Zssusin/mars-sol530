# 屏幕后处理（颗粒感 §1）：CAS 锐化 + 亮度相关胶片颗粒。CanvasLayer（layer 5，在 HUD 10 之下）里一个全屏 ColorRect，着色器读屏幕纹理
# （色调映射、TAA / FSR2 之后）。只在实时画质（漫游 / 测帧）里建；离线渲染 / 视频用 SubViewport，不经过主窗口的 CanvasLayer。
# 开关：--后处理=0 全关；--锐化=s（CAS 锐度 0..1，0 关；默认 0.5）；--颗粒=a（显示值幅度，0 关；默认 0.02 ≈ 5/255）；--颗粒帧率=24。
# 设置页 / 预设：环境.gd 预设表里的「锐化」「颗粒」键；user://settings.cfg 的 [args] 同名键。
extends Node

var layer: CanvasLayer
var rect: ColorRect
var mat: ShaderMaterial
var hz := 24.0
var t_fixed := -1.0                      # 录制 / 截图用：固定时间（秒），负数 = 用墙钟


func setup(args: Dictionary) -> bool:
	var s := float(args.get("锐化", "0.5")); var g := float(args.get("颗粒", "0.02"))
	hz = maxf(float(args.get("颗粒帧率", "24")), 1.0)
	if args.get("后处理", "1") != "1" or (s <= 0.0 and g <= 0.0): return false
	layer = CanvasLayer.new(); layer.layer = 5; add_child(layer)
	rect = ColorRect.new(); rect.set_anchors_preset(Control.PRESET_FULL_RECT); rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mat = ShaderMaterial.new(); mat.shader = load("res://着色器/锐化颗粒.gdshader")
	mat.set_shader_parameter("sharp", s); mat.set_shader_parameter("grain", g)
	rect.material = mat; layer.add_child(rect)
	if 环境.用设置() and 环境.设置读("后处理", "1", "显示") == "0": layer.visible = false      # 设置页「锐化与颗粒」关
	print("[后处理] CAS 锐度 %.2f，颗粒 %.4f（%.0f Hz）" % [s, g, hz])
	return true


func _process(_dt: float) -> void:
	if mat == null: return
	var t := t_fixed if t_fixed >= 0.0 else Time.get_ticks_msec()/1000.0
	mat.set_shader_parameter("grain_seed", float(int(t*hz) % 4096))


func enable(on: bool) -> void:
	"""设置页开关：立刻生效（不重建）。"""
	if layer: layer.visible = on
