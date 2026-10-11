# 玩法 A：漫游加摄影（设计见 docs/玩法A.md）；玩法 B：sol 规划（子模块 B = 玩法/sol.gd，设计见 docs/玩法B.md）。实景.gd 实时模式下自动加载成子节点「玩法」（--玩法=0 不加载；测帧默认不带模块）。
#   子模块：拍照（拍照模式）、兴趣点（发现、导览卡）、图鉴（相册页）、复刻（复刻 NASA 照片挑战）、菜单（暂停菜单）。
#   本节点始终运行（PROCESS_MODE_ALWAYS）：世界暂停时也收键、也替 实景.gd 跑地面 / 石块 / 天空的每帧更新（见 世界更新）。
#   按键统一在这里分发（子模块不各自收 _unhandled_input）。本模块比 控制 / 界面 / 天气 / 声音 后加，先收到按键。
# 给界面：标记() → 兴趣点标记（航向带、小地图）；按键() → 帮助页的按键表。
# 进度：user://玩法A.json；相册：user://相册/。数据：数据/sol0530/兴趣点.json（75_兴趣点.py 生成，图在 兴趣点/）。
# 自测：--玩法测试[=目录]（玩法/测试.sh）。
extends Node

signal 进度变了

var 进度文件 := "user://玩法A.json"                # 自测时换成 玩法A_自测.json，不动玩家的进度
const 版本 := 1

var P: Node                                       # 实景.gd
var 风: RefCounted                                 # 风格.gd
var 数据 := {"兴趣点": [], "挑战": []}
var 进度 := {"版本": 版本, "已发现": {}, "挑战": {}, "当前挑战": ""}
var 拍照: Node
var 兴趣: Node
var 图鉴: Node
var 复刻: Node
var 菜单: Node
var B: Node                                       # 玩法 B：sol 规划（玩法/sol.gd）
var 暂停源 := {}                                  # 谁要求暂停（拍照、图鉴、菜单）
var 鼠标原 := Input.MOUSE_MODE_CAPTURED           # 开菜单 / 图鉴前的鼠标状态，关掉时还原
var 用时 := 0.0                                   # 本模块每帧脚本用时（ms，平滑）


func _ready() -> void:
	P = get_parent()
	process_mode = Node.PROCESS_MODE_ALWAYS
	if P.args.has("玩法测试"): 进度文件 = "user://玩法A_自测.json"
	风 = load("res://玩法/风格.gd").new(); 风.量尺(get_viewport())
	get_viewport().size_changed.connect(func(): 风.量尺(get_viewport()))
	读数据(); 读进度()
	for k in [["拍照", "res://玩法/拍照.gd"], ["兴趣", "res://玩法/兴趣点.gd"], ["图鉴", "res://玩法/图鉴.gd"], ["复刻", "res://玩法/复刻.gd"], ["菜单", "res://玩法/菜单.gd"], ["B", "res://玩法/sol.gd"]]:
		if not ResourceLoader.exists(k[1]): continue                     # 子模块按阶段加入，没有就跳过
		var n: Node = load(k[1]).new(); n.name = k[0]; add_child(n); set(k[0], n)
	if P.args.has("玩法测试"):
		var t: Node = load("res://玩法/自测.gd").new(); t.name = "自测"; add_child(t)
	print("[玩法] 兴趣点 %d 个、挑战 %d 个，已发现 %d 个" % [数据["兴趣点"].size(), 数据["挑战"].size(), 进度["已发现"].size()])


# ———————————————————— 数据与进度
func 读数据() -> void:
	var p: String = String(P.D) + "兴趣点.json"
	if not FileAccess.file_exists(p): push_warning("[玩法] 没有 %s（先跑 scripts/Godot/75_兴趣点.py）" % p); return
	var j = JSON.parse_string(FileAccess.get_file_as_string(p))
	if j is Dictionary:
		for k in ["兴趣点", "挑战"]:
			if not j.has(k): continue
			数据[k] = j[k]
			for q in j[k]:                                              # 英文名、说明：数据里的 "en"（75_兴趣点.py 的 英文 表）→ 令.译 的表，画字时按中文原文换
				var en: Dictionary = q.get("en", {})
				for f in en: 令.登记译(String(q.get(f, "")), String(en[f]))


func 图路径(rel: String) -> String:
	return String(P.D) + rel


func 读进度() -> void:
	if P.args.get("玩法新档", "0") == "1" or not FileAccess.file_exists(进度文件): return
	var j = JSON.parse_string(FileAccess.get_file_as_string(进度文件))
	if j is Dictionary and int(j.get("版本", 0)) == 版本:
		for k in ["已发现", "挑战", "当前挑战"]: if j.has(k): 进度[k] = j[k]
	else: push_warning("[玩法] 进度文件版本不符，不读：%s" % 进度文件)


func 存进度() -> void:
	进度["版本"] = 版本; 进度["游戏"] = str(ProjectSettings.get_setting("application/config/version", "?"))
	var f := FileAccess.open(进度文件, FileAccess.WRITE)
	if f: f.store_string(JSON.stringify(进度, "\t")); f.close()
	进度变了.emit()


func 点(id: String) -> Dictionary:
	for q in 数据["兴趣点"]: if q["id"] == id: return q
	return {}


func 挑战(id: String) -> Dictionary:
	for q in 数据["挑战"]: if q["id"] == id: return q
	return {}


# ———————————————————— 暂停（世界停，玩法模块照常）
func 暂停(源: String, on: bool) -> void:
	var 前 := not 暂停源.is_empty()
	if on: 暂停源[源] = true
	else: 暂停源.erase(源)
	var 后 := not 暂停源.is_empty()
	if 前 != 后: get_tree().paused = 后


func 放鼠标() -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE: 鼠标原 = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func 还鼠标() -> void:
	Input.mouse_mode = 鼠标原


func 世界更新(cam: Camera3D) -> void:
	"""世界暂停时 实景.gd 的 _process 不跑：替它做地面 LOD、石块分级、换天空、地平线 GI 和天气光照（函数都是现成的）。"""
	if cam == null: return
	var pa: float = deg_to_rad(cam.fov)/get_viewport().get_visible_rect().size.x
	P.poll_sky()
	if P.hz: P.hz.poll()
	P.ground_mat.set_shader_parameter("pixel_angle", pa)
	if P.lod: P.lod.update(cam.global_position, pa)
	P.rocks_update(cam.global_position, pa, false)
	var w: Node = P.get_node_or_null("天气")
	if w and w.has_method("update_light"): w.update_light()


# ———————————————————— 车
func 车位() -> Vector3:
	"""车体原点（Godot 坐标）；没有车就用当前相机。"""
	var rr: Node3D = P.rover_root
	if rr and is_instance_valid(rr): return rr.global_position
	var c := get_viewport().get_camera_3d()
	return c.global_position if c else Vector3.ZERO


func 地高(x: float, z: float) -> float:
	return P.lod.h_cpu(x, z, 0) if P.lod else 0.0


# ———————————————————— 键
func _unhandled_input(ev: InputEvent) -> void:
	var t0 := Time.get_ticks_usec()
	if 菜单 and 菜单.开着:
		菜单.输入(ev); return
	if B and B.页开着():                                                 # sol 规划的全屏页（下行卡、规划图、报告卡、3D 预演）
		B.输入(ev); get_viewport().set_input_as_handled(); return
	if 图鉴 and 图鉴.开着:
		图鉴.输入(ev); get_viewport().set_input_as_handled(); return
	if 复刻 and 复刻.结果开着:
		复刻.输入(ev); get_viewport().set_input_as_handled(); return
	if 拍照 and 拍照.开着:
		拍照.输入(ev); get_viewport().set_input_as_handled(); return
	if not (ev is InputEventKey and ev.pressed and not ev.echo): return
	match ev.keycode:
		KEY_ESCAPE:
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or 菜单 == null: return   # 第一次：让 控制 放开鼠标
			菜单.打开()
		KEY_C: if 拍照: 拍照.进入()
		KEY_TAB: if 图鉴: 图鉴.打开()
		KEY_F: if 兴趣: 兴趣.切卡()
		KEY_F2: if B: B.切换()
		_: return
	get_viewport().set_input_as_handled()
	用时 = (Time.get_ticks_usec() - t0)/1000.0


func 按键() -> Array:
	return [["C", "拍照"], ["Tab", "图鉴"], ["F", "导览卡"], ["Esc ×2", "暂停菜单"]] + (B.按键() if B else [])


func 标记() -> Array:
	"""给界面：[{E, N, 名, 已发现, 远}]（ENU m）；当前挑战的大致位置也算一个（类型「挑战」）。"""
	return 兴趣.标记() if 兴趣 else []
