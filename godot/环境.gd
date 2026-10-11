# 环境（autoload「环境」）：版本信息、数据路径、启动计时。说明见 docs/工程化方案.md §2、§9。
#
# 版本信息：游戏 SemVer、git 短哈希（+改动）、引擎 4.7.2-mars.N（加引擎提交号）、数据 CalVer。
#   导出包：读打进 PCK 的 res://build_info.json（工具/构建信息.sh 在导出前写）。
#   编辑器：直接问 git（文件可能过时），问不到再读 build_info.json，都没有就写「?」。
#   数据版本：优先读数据目录里的 数据清单.json（反映实际在用的数据），没有再用 build_info.json 里的。
#
# 路径：编辑器里一切都在 res://；导出包里，不进 PCK 的文件放在 data/，目录结构和 res:// 一样：
#   res://数据/sol0530/x.bin → <data>/数据/sol0530/x.bin；res://../资料/… → <data>/资料/…
#   data/ 不在程序包里，是单独下载的「数据包」（mars-realtime-drive-data-<数据版本>-<n>of<N>.zip，docs/发布流程.md），玩家解压到下面某个位置。
#   找 data/ 的顺序，第一个有数据的算（日志 [环境] 那行末尾写用了哪个）：
#     1. 命令行 --数据目录=<data 目录>    2. 环境变量 MARS_DATA=<data 目录>    （这两个是显式指定：指了就只看它，里面没有数据就报错，不往下找）
#     3. 可执行文件旁的 data/（Linux、Windows）
#     4. macOS：X.app/Contents/Resources/data/
#     5. macOS：X.app 旁边的 data/
#     6. AppImage：环境变量 APPIMAGE（AppImage 文件的路径）旁边的 data/
#   找不到、版本和程序要的不一样、或文件不全：不往下走，屏幕上给一页说明（界面/缺数据/缺数据.gd），同时写进日志，按键 / 点击 / 关窗退出。
#   经过导入的贴图（load() 读的）在 PCK 里，用 资源目录()，不用 数据目录()。
#
# 启动计时：每次启动打印「首帧」耗时；--首帧退出 时打印完就退出（量启动耗时用，见 工具/导出.sh 冒烟）。
extends Node

var 信息 := {}                     # 游戏、提交、改动、引擎、引擎提交、数据、来源
var 导出版 := false
var 外置根 := ""                   # 导出包的 data/ 目录（末尾带 /）
var 数据来源 := ""                 # 外置根是从哪一条来的：命令行 / MARS_DATA / 可执行文件旁 / .app 内 / .app 旁 / AppImage 旁 / 无
var 数据问题 := {}                 # 空 = 数据可用；否则 {种类: 缺 | 版本 | 不全, 应放: 解压到哪个目录（data 的上一级）, 找到: 现有 data 目录, 现有 / 需要: 数据版本, 缺: 文件数, 卷: 缺的卷, 共: 总卷数}
const 数据下载页 := "github.com/Zssusin/mars-sol530/releases"   # 提示页上写的下载位置（公开仓库的 Releases 页）


func _init() -> void:
	导出版 = not OS.has_feature("editor")
	if 导出版:
		_找数据()
		if not 外置根.ends_with("/"): 外置根 += "/"
	信息 = _读信息()
	print("[环境] " + 一行() + ("" if not 导出版 else "（data：%s，来源：%s）" % [外置根, 数据来源 if 数据来源 != "" else "无"]))
	if 导出版 and 数据问题.is_empty(): 数据问题 = _核对数据()
	if not 数据问题.is_empty(): _记数据问题()


func _有数据(根: String) -> bool:
	return FileAccess.file_exists(根.path_join("数据包清单.json")) or FileAccess.file_exists(根.path_join("数据/sol0530/数据清单.json"))


func _候选() -> Array:
	"""自动找的位置，按顺序：[[来源名, data 目录], …]。"""
	var exe := OS.get_executable_path().replace("\\", "/")           # Windows 偶尔给反斜杠
	var 目录 := exe.get_base_dir()
	var r := [["可执行文件旁", 目录.path_join("data")]]
	if OS.get_name() == "macOS" and 目录.ends_with(".app/Contents/MacOS"):
		var app := 目录.get_base_dir().get_base_dir()                  # …/X.app
		r.append([".app 内", app.path_join("Contents/Resources/data")])
		r.append([".app 旁", app.get_base_dir().path_join("data")])
	var ai := OS.get_environment("APPIMAGE")
	if ai != "": r.append(["AppImage 旁", ai.replace("\\", "/").get_base_dir().path_join("data")])
	return r


func _找数据() -> void:
	"""定 外置根 / 数据来源。显式指定（命令行、MARS_DATA）就只看它；否则按 _候选() 顺序取第一个有数据的；都没有，外置根 留成第一个应放的位置（提示页写它）。"""
	var 指定 := ""
	var 来 := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--数据目录="): 指定 = a.trim_prefix("--数据目录="); 来 = "命令行 --数据目录"
	if 指定 == "" and OS.get_environment("MARS_DATA") != "": 指定 = OS.get_environment("MARS_DATA"); 来 = "环境变量 MARS_DATA"
	if 指定 != "":
		外置根 = 指定.replace("\\", "/")
		if _有数据(外置根): 数据来源 = 来
		else: 数据问题 = _问题("缺", 外置根, "", 来)
		return
	var 候选 := _候选()
	for c in 候选:
		if _有数据(c[1]): 外置根 = c[1]; 数据来源 = c[0]; return
	外置根 = _应放目录(候选)
	数据问题 = _问题("缺", 外置根, "", "")


func _应放目录(候选: Array) -> String:
	"""没找到数据时建议玩家放的 data 目录：AppImage 旁 > macOS .app 旁 > 可执行文件旁。"""
	for n in ["AppImage 旁", ".app 旁"]:
		for c in 候选: if c[0] == n: return c[1]
	return 候选[0][1]


func _本地路径(p: String) -> String:
	return p.replace("/", "\\") if OS.get_name() == "Windows" else p


func _问题(种类: String, data目录: String, 找到: String, 来: String) -> Dictionary:
	var d := data目录.trim_suffix("/")
	return {"种类": 种类, "应放": _本地路径(d.get_base_dir()), "data": _本地路径(d), "找到": 找到, "来": 来,
		"translocated": OS.get_executable_path().contains("/AppTranslocation/")}


func _要的数据版本() -> String:
	return str(_读json("res://build_info.json").get("数据", ""))


func _核对数据() -> Dictionary:
	"""找到了 data/：版本对不对、清单里的文件在不在、大小对不对。只 stat，不算哈希（4 GB 太慢；完整校验用 工具/数据包.py 校验）。"""
	var 根 := 外置根
	var 包 := _读json(根 + "数据包清单.json")
	var 清 := _读json(根 + "数据/sol0530/数据清单.json")
	var 有 := str(包.get("数据版本", 清.get("数据版本", "")))
	var 要 := _要的数据版本()
	var 问 := _问题("版本", 根, 根, 数据来源)
	问["现有"] = 有; 问["需要"] = 要
	if 要 != "" and 要 != "?" and 有 != 要: return 问
	var 缺 := 0
	var 缺卷 := {}
	var 查 := {}                                                       # 相对 data/ 的路径 → [大小, 在第几卷]
	if 包.has("文件"):
		for k in 包["文件"]: 查[k] = [int(包["文件"][k][0]), int(包["文件"][k][1])]
	else:                                                              # 没有 数据包清单.json（比如直接指到开发机上的数据）：只查 数据清单.json 列的文件和地貌参数
		var 文件: Dictionary = 清.get("文件", {})
		for k in 文件: 查["数据/sol0530/" + k] = [int(文件[k]["大小"]), 0]
		查["资料/地貌参数/地貌参数.json"] = [-1, 0]
	for k in 查:
		var f := FileAccess.open(根 + k, FileAccess.READ)
		if f == null or (查[k][0] >= 0 and f.get_length() != 查[k][0]):
			缺 += 1
			if 查[k][1] > 0: 缺卷[查[k][1]] = true
		if f: f.close()
	if 缺 == 0 and 查.is_empty(): 缺 = 1                                 # 有 data/ 但清单一个都读不到
	if 缺 > 0:
		问["种类"] = "不全"; 问["缺"] = 缺; var 卷表: Array = 缺卷.keys(); 卷表.sort(); 问["卷"] = 卷表; 问["共"] = int(包.get("卷数", 0))
		return 问
	return {}


func _记数据问题() -> void:
	"""写日志：缺什么、去哪下、放哪（和屏幕上那页一样的内容）。"""
	var d := 数据问题
	var 版本 := _要的数据版本()
	var 包名 := "mars-realtime-drive-data-%s-<n>of<N>.zip" % 版本
	match d["种类"]:
		"缺":
			print("[数据] 没有找到游戏数据。" + ("（%s 指到的目录里没有数据：%s）" % [d["来"], d["data"]] if d["来"] != "" else ""))
		"版本":
			print("[数据] 数据版本不对：%s 里的是 %s，这个程序要 %s。" % [d["data"], d["现有"], d["需要"]])
		"不全":
			print("[数据] 数据不全：%s 里缺 %d 个文件%s。" % [d["data"], d["缺"], "（在第 %s 卷里）" % "、".join(PackedStringArray((d["卷"] as Array).map(func(x): return str(x)))) if not (d["卷"] as Array).is_empty() else ""])
	print("[数据] 需要数据包 %s，全部卷都下载。下载：%s" % [包名, 数据下载页])
	print("[数据] 全部解压到 %s ，解压后这里要有 data 文件夹，然后重新打开游戏。" % d["应放"])
	if d.get("translocated", false): print("[数据] 程序被 macOS 隔离到了临时位置，看不到 .app 旁边的 data；先在终端运行 xattr -dr com.apple.quarantine 加 .app 的路径，再重新打开。")


func 进度(步: String, x: float) -> void:
	"""实景.gd 搭场景的各步之间调：有载入画面（令.载入层，走主菜单启动时）就记时间、画一帧；没有就什么都不做。"""
	var 层: Node = 令.载入层
	if 层 and is_instance_valid(层) and 层.is_inside_tree() and 层.has_method("进度"): 层.进度(步, x)


func _exit_tree() -> void:
	"""退出保险：Wayland 下进程偶尔卡在 DisplayServerWayland 的析构里不退（docs/发布流程.md「已知问题」），
	自动化跑的时候会一直占着显卡锁，别的任务只能等它超时。树拆掉时起一个独立的小进程，10 秒后本进程还在就结束它；
	正常退出时那个 kill 落空，什么也不发生。子进程先把标准输入输出换成 /dev/null，不然会拖住接在后面的 tee / grep。"""
	if OS.get_name() == "Linux" and DisplayServer.get_name().to_lower() == "wayland":
		OS.create_process("/bin/sh", ["-c", "exec </dev/null >/dev/null 2>&1; sleep 10; kill -9 %d" % OS.get_process_id()])


func _ready() -> void:
	if not 数据问题.is_empty():                                         # 数据不可用：只给提示页，不往下走（实景.gd、载入、令 的字体都认这个标志）
		var 页: Node = load("res://界面/缺数据/缺数据.gd").new()
		页.问题 = 数据问题; 页.版本 = _要的数据版本(); 页.下载页 = 数据下载页
		get_tree().root.add_child.call_deferred(页)
		return
	_应用显示()
	if DisplayServer.get_name() == "headless": await get_tree().process_frame   # 无头时不画，frame_post_draw 不来
	else: await RenderingServer.frame_post_draw
	print("[环境] 首帧 %d ms（引擎启动起）" % Time.get_ticks_msec())
	if "--首帧退出" in OS.get_cmdline_user_args():
		for i in 3: await get_tree().process_frame
		var s := get_tree().current_scene
		if s and s.has_method("quit_clean"): s.quit_clean()
		else: get_tree().quit()


# ———————————————————— 路径
func 外置(p: String) -> String:
	"""p 相对 res:// 根（可以是 ../ 开头，指项目外，如 ../资料/…）。编辑器 → res:// 或项目外的绝对路径；导出包 → data/ 下。"""
	if not 导出版:
		if p.begins_with("../"): return ProjectSettings.globalize_path("res://").path_join(p).simplify_path()
		return "res://" + p
	return 外置根 + p.trim_prefix("../")


func 数据目录() -> String:                     # FileAccess、GLTF、Image.load_from_file 直接读的原始文件
	return 外置("数据/sol0530/")


func 资源目录() -> String:                     # load() 读的、经过导入的资源（贴图）：在 PCK 里
	return "res://数据/sol0530/"


func 地貌参数() -> String:
	return 外置("../资料/地貌参数/地貌参数.json")


# ———————————————————— 版本信息
func 一行() -> String:
	var g: String = 信息["提交"] + ("+改动" if 信息["改动"] else "")
	return "v%s · %s · 引擎 %s（%s）· 数据 %s" % [信息["游戏"], g, 信息["引擎"], 信息["引擎提交"], 信息["数据"]]


func _读信息() -> Dictionary:
	var d := {"游戏": str(ProjectSettings.get_setting("application/config/version", "?")), "提交": "?", "改动": false,
		"引擎": "?", "引擎提交": str(Engine.get_version_info().get("hash", "?")).left(9), "数据": "?", "来源": "无"}
	var f := _读json("res://build_info.json")
	if not 导出版 and _问git(d): d["来源"] = "git"
	elif not f.is_empty():
		d["来源"] = "build_info.json"
		for k in ["提交", "改动"]: if f.has(k): d[k] = f[k]
	if f.has("游戏") and 导出版: d["游戏"] = str(f["游戏"])
	if f.has("引擎"): d["引擎"] = str(f["引擎"])
	if f.has("数据"): d["数据"] = str(f["数据"])
	if not 导出版:                                                    # 编辑器：引擎版本直接读 engine/ENGINE_REF
		var ref := 外置("../engine/ENGINE_REF")
		if FileAccess.file_exists(ref):
			for l in FileAccess.get_file_as_string(ref).split("\n"):
				if l.begins_with("版本="): d["引擎"] = l.trim_prefix("版本=").strip_edges()
	var m := _读json(数据目录() + "数据清单.json")
	if m.has("数据版本"): d["数据"] = str(m["数据版本"])
	return d


func _问git(d: Dictionary) -> bool:
	var repo := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	var out := []
	if OS.execute("git", ["-C", repo, "rev-parse", "--short", "HEAD"], out) != 0 or out.is_empty(): return false
	d["提交"] = String(out[0]).strip_edges()
	out = []
	if OS.execute("git", ["-C", repo, "status", "--porcelain", "--untracked-files=no"], out) == 0 and not out.is_empty():
		d["改动"] = String(out[0]).strip_edges() != ""
	return true


func _读json(p: String) -> Dictionary:
	if not FileAccess.file_exists(p): return {}
	var v = JSON.parse_string(FileAccess.get_file_as_string(p))
	return v if v is Dictionary else {}


# ———————————————————— 参数与设置（docs/工程化方案.md §6）
# 合并顺序，后者覆盖前者：代码里的默认值 < 画质预设 < user://settings.cfg 的 [参数] 节 < 命令行。
# 设置只在「玩」的时候生效：导出版，或命令行带 --设置（godot/漫游.sh 会加）。
# 测帧、渲染、自测、检查.sh 都不带 --设置，所以结果不受玩家设置影响；它们仍可用 --画质预设=<名> 显式选一档。
# 设置页（界面）只通过下面的 设置读 / 设置写 / 设置存 / 预设列表 / 预设内容 / 重启 读写，不自建存储。
const 设置文件 := "user://settings.cfg"
const 预设顺序 := ["低", "中", "性能", "高"]
const 预设表 := {
	"高": {},                                                     # = 代码默认值；测帧、照片回归的基准就是这一档
	"性能": {"AA": "FSR2", "缩放": "0.77"},                        # FSR2 渲染 77%（引擎调研实测远足 11.54 → 9.15 ms）
	"中": {"AA": "FSR2", "缩放": "0.77", "SSAO半": "1", "阴影距": "100", "撒石像素": "4", "地面像素": "10", "砾石像素": "6"},
	"低": {"AA": "FSR2", "缩放": "0.67", "SSAO": "0", "阴影距": "80", "级联": "2", "撒石像素": "6", "地面像素": "12",
		"位移距": "15", "SDFGI慢": "1", "颗粒": "0", "缓存阴影": "0", "砾石": "0"},   # 颗粒感：低档不要颗粒、不烘微观自阴影（后处理锐化仍开：FSR2 放大后更需要）
}
var _参数 := {}
var _设: ConfigFile = null


func 命令行() -> Dictionary:
	"""--键=值 / --键（值为空串）→ 字典。"""
	var a := {}
	for s in OS.get_cmdline_user_args():
		var kv := s.trim_prefix("--").split("=", true, 1)
		a[kv[0]] = kv[1] if kv.size() > 1 else ""
	return a


func 用设置() -> bool:
	return 导出版 or 命令行().has("设置")


func 参数() -> Dictionary:
	"""实景.gd 和各模块的 args。只算一次；返回的是同一个字典，别改它。"""
	if not _参数.is_empty(): return _参数
	var 命 := 命令行()
	var r := {}
	var 档 := ""
	if 用设置(): 档 = 设置读("画质预设", "高")
	if 命.has("画质预设"): 档 = 命["画质预设"]
	if 档 != "":
		if not 预设表.has(档): push_warning("[环境] 不认识的画质预设「%s」，按「高」" % 档); 档 = "高"
		r.merge(预设表[档], true)
	if 用设置():
		var 存: Dictionary = _节("参数")
		for k in 存: if k != "画质预设": r[k] = str(存[k])
	r.merge(命, true)
	if 档 != "": r["画质预设"] = 档
	_参数 = r
	var 外来 := []
	for k in r: if not 命.has(k) or k == "画质预设": 外来.append("%s=%s" % [k, r[k]])
	if not 外来.is_empty(): print("[环境] 设置 / 预设带来的参数：" + " ".join(外来))
	return r


func 设置() -> ConfigFile:
	if _设 == null:
		_设 = ConfigFile.new()
		if FileAccess.file_exists(设置文件) and _设.load(设置文件) != OK:
			push_warning("[环境] %s 读不了，按默认设置" % 设置文件); _设 = ConfigFile.new()
	return _设


# 文件格式：每节一个字典值，如 [参数] v={"画质预设": "低", "阴影距": "90"}。Godot 4.7 的 ConfigFile 读非 ASCII 的键名会乱码
# （值没问题），所以中文键都放在字典里，节名和键名用 ASCII：参数 → [args]，显示 → [display]。
const _节名 := {"参数": "args", "显示": "display"}


func _节(节: String) -> Dictionary:
	var v = 设置().get_value(_节名.get(节, 节), "v", {})
	return v if v is Dictionary else {}


func 设置读(键: String, 默认: String = "", 节: String = "参数") -> String:
	return str(_节(节).get(键, 默认))


func 设置写(键: String, 值, 节: String = "参数") -> void:
	"""值为 null 或空串：删掉这一项（回到预设 / 默认）。写完要 设置存()；多数参数要重启后生效。"""
	var d := _节(节)
	if 值 == null or str(值) == "": d.erase(键)
	else: d[键] = str(值)
	设置().set_value(_节名.get(节, 节), "v", d)


func 设置存() -> Error:
	设置().set_value("meta", "game_version", 信息.get("游戏", "?"))
	var e := 设置().save(设置文件)
	if e != OK: push_error("[环境] 存不了 %s（%s）" % [设置文件, error_string(e)])
	return e


func 预设列表() -> Array:
	return 预设顺序.duplicate()


func 预设内容(名: String) -> Dictionary:
	return 预设表.get(名, {}).duplicate()


func 重启() -> void:
	"""设置改完、需要重建场景时用：带着原来的命令行重新启动。"""
	OS.set_restart_on_exit(true, OS.get_cmdline_args())
	var s := get_tree().current_scene
	if s and s.has_method("quit_clean"): s.quit_clean()
	else: get_tree().quit()


func _应用显示() -> void:
	"""[显示] 节：全屏、垂直同步。只在 用设置() 时，由 _ready 调。"""
	if not 用设置() or DisplayServer.get_name() == "headless": return
	if 设置读("全屏", "0", "显示") == "1": DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if 设置读("垂直同步", "1", "显示") == "1" else DisplayServer.VSYNC_DISABLED)
