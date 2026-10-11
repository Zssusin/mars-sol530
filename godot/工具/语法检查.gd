# 语法检查：解析 res:// 下全部 .gd（跳过有 .gdignore 的目录、_备份_* 和 .godot），有错时退出码 1。scripts/检查.sh 快档调用。
# 用法：godot --headless --path godot --script res://工具/语法检查.gd
# 加载即做解析和静态分析（类型、autoload、preload 的依赖），错误由引擎打印成 SCRIPT ERROR / Parse Error。
extends SceneTree


func _initialize() -> void:
	var bad: Array[String] = []
	var all := _列("res://")
	for p in all:
		var s = ResourceLoader.load(p)               # 不能用 CACHE_MODE_IGNORE：会重编正在运行的本脚本，字节码坏掉
		if not (s is GDScript and s.can_instantiate()): bad.append(p)
	for p in bad: print("[语法] ✗ ", p)
	print("[语法] %d 个脚本，%d 个有错" % [all.size(), bad.size()])
	quit(1 if bad.size() else 0)


func _列(d: String) -> Array[String]:
	var out: Array[String] = []
	if FileAccess.file_exists(d.path_join(".gdignore")): return out
	for f in DirAccess.get_files_at(d):
		if f.get_extension() == "gd" and not f.begins_with("._"): out.append(d.path_join(f))
	for sub in DirAccess.get_directories_at(d):
		if sub.begins_with(".") or sub.begins_with("_备份_"): continue
		out.append_array(_列(d.path_join(sub)))
	return out
