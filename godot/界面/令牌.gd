# 界面令牌（design tokens；docs/界面/UI体系.md §1）。autoload「令」。
#   界面里所有的颜色、字号、线宽、描边、间距、图标尺寸、动效时长和缓动、不透明度、扫描脉冲参数都从这里取；
#   组件（界面/件.gd）和页面代码里不写十六进制颜色、不写裸的字号 / 时长常数（地图数据着色这类「数据色」除外，见 UI体系.md）。
#   - 颜色按「角色」取：令.色.主 / 次 / 活 / 活边 / 强 / 注意 / 警告 / 暗 / 页底 / 底。整套色板可换：
#     设色板(名) 或启动参数 --配色=NASA|龙舱|火星互补|全境|丙；换了发「变了」信号（界面重画、地面贴图重生成）。
#   - 尺寸以 1440p 像素记，组件里乘 s（= 屏高 / 1440，0.75–3）；字号再乘 字倍（设置里的「字号」，无障碍）。地面图形以米记。
#   - 默认色板 NASA 标准（用户 2026-10-08 定）：只借颜色值，界面里不出现任何 NASA 徽标形状。
extends Node

signal 变了                                        # 色板或字倍变了

# ———————————————————— 颜色（角色表；docs/界面/主菜单样张/说明.md「配色」）
#   主：常态字和线；次：次要字（整屏页）；活：选中、当前路线、车标；活边：「活」色的描边（深蓝在橙色地面上要白边才站得住）；
#   活亮：「活」在深色渐变页（设置页）上的浅色调——NASA 深蓝 #0B3D91 在深色底上读不出来，选中项的字和下划线、滑条用它；其余色板本来就亮，等于「活」；
#   强：只在深色整屏页上的强调；注意 / 警告：告警（同时换形状：三角 / 八边形）；暗：描边和阴影；页底：整屏页底色；底：菜单 / 图鉴面板。
const 色板 := {
	"NASA": {"名": "NASA 标准", "主": "#FFFFFF", "次": "#C5C9CF", "活": "#0B3D91", "活边": "#FFFFFF", "活亮": "#8DB4F5",  "强": "#FC3D21",
		"注意": "#FFB000", "警告": "#FC3D21", "暗": "#140E0A", "页底": "#0A1020", "底": "#0A1020DC"},
	"龙舱": {"名": "龙舱", "主": "#FFFFFF", "次": "#A3AEBA", "活": "#38BDF8", "活边": "", "活亮": "#38BDF8",  "强": "#38BDF8",
		"注意": "#FFB000", "警告": "#FF3B30", "暗": "#0B0E12", "页底": "#0B0E12", "底": "#0B0E12DC"},
	"火星互补": {"名": "火星互补", "主": "#FFFFFF", "次": "#D9D3CB", "活": "#4FD1E0", "活边": "", "活亮": "#4FD1E0",  "强": "#FF4F00",
		"注意": "#FFB000", "警告": "#FF4B3A", "暗": "#140E0A", "页底": "#081417", "底": "#081417DC"},
	"全境": {"名": "全境 · 火星版", "主": "#A8F0F5", "次": "#6FBEC6", "活": "#FF7A1A", "活边": "", "活亮": "#FF7A1A",  "强": "#FF7A1A",
		"注意": "#FFB000", "警告": "#FF3B30", "暗": "#061013", "页底": "#061013", "底": "#061013DC"},
	"丙": {"名": "丙（全白，对照）", "主": "#FFFFFF", "次": "#FFFFFFE0", "活": "#FFFFFF", "活边": "", "活亮": "#FFFFFF",  "强": "#FFFFFF",
		"注意": "#FFB000", "警告": "#FF4B3A", "暗": "#140E0A", "页底": "#080604F5", "底": "#080604DB"},
}
const 色板序 := ["NASA", "龙舱", "火星互补", "全境", "丙"]
const 默认色板 := "火星互补"       # 界面 5：用户喜欢的样张都是「火星互补」；最终默认由用户定

var 板 := 默认色板
var 色 := {}                                       # 角色 → Color（当前色板）
var 有活边 := false                                 # 当前色板的「活」要不要白边

# ———————————————————— 字（Inter + Noto Sans SC 可变字重；数字等宽 tnum；IBM Plex Mono 做等宽表）
#   正 Regular / 中 Medium / 粗 SemiBold（中文 400 / 500 / 700）；等 / 等中：Plex Mono；标：中 + 字距 2（小号英文标签）。
const 号 := {"注": 16, "小": 18, "次": 20, "正": 22, "中": 24, "读": 26, "大读": 28, "题": 32, "方位": 30,
	"大题": 42, "页题": 56, "片名": 96}          # 字号阶梯（1440p 像素）
const 行距 := 1.45
const 描系 := 4.5                                   # draw_string_outline 的 outline_size = 外扩 px × 描系（界面 6 实测：outline_size 8 在 2560×1440 上只有约 2.3 px 实心描边，天空 / 亮沙上带 1–3 px 要全实心，所以取 4.5 倍才得到名义外扩）
var 字 := {}

# ———————————————————— 线、描边（可读性：没有暗底板，靠描边 + 阴影；docs/界面/UI体系.md §3）
const 宽 := {"细": 1.5, "常": 2.0, "框": 2.5, "粗": 3.0, "重": 4.0, "强": 5.0}   # 线宽（1440p 像素）
const 描 := {
	"线外": 4.0, "线影": 3.0, "线a": 0.85, "影a": 0.22, "影移": 2.0,           # 线：深色外扩 +3.2 px（a 0.55），阴影下移 2 px（a 0.22）
	"字影": 5.0, "字外": 10.0, "字内": 4.5, "字影a": 0.22, "字外a": 0.26, "字内a": 0.72,   # 字：阴影 5 / 宽淡外圈 10 / 深色内圈 4.5（描边宽，px）
	"点外": 1.6, "图外": 1.8, "图影a": 0.30, "图晕a": 0.6,                       # 点、图标的深色外扩
	"活边": 2.0, "活加宽": 0.5,                                                  # 「活」色带白边时：白边外扩（px）、线芯加宽（px）
}
# ———————————————————— 间距、图标
const 距 := {"xs": 4, "s": 8, "m": 12, "l": 16, "xl": 24, "xxl": 32, "节": 44, "边": 60, "页边": 120}
const 图 := {"小": 20, "中": 28, "常": 32, "大": 36, "题": 40, "警": 60, "徽": 128}
# ———————————————————— 不透明度
#   对比度规范（docs/界面/界面减字与交互规范.md §5）：文字不透明度 ≥ 0.85（次要文字靠颜色区分，不靠降透明度）；禁用 0.5 并配划线 / 空心；「字」= 文字的最低不透明度。
const 透 := {"字": 0.85, "次": 0.85, "三": 0.85, "灰": 0.85, "淡": 0.5, "禁": 0.5, "提示": 0.75, "面": 0.10, "页暗": 0.72}
# ———————————————————— 动效（每个元素 0.2–0.6 s，没有一直循环的装饰动画；docs/界面/UI体系.md §5）
const 时 := {"闪": 0.10, "快": 0.15, "中": 0.25, "慢": 0.40, "长": 0.60, "错": 0.06, "错细": 0.04, "数": 0.30,
	"提示留": 2.0, "停淡": 2.0, "呼": 1.4, "环出": 0.6,
	"悬": 0.08, "弹回": 0.12, "滑": 0.12, "提示延": 0.35, "提示淡": 0.10}      # 界面 5：悬停高亮 0.08、按下回弹 0.12、选项下划线 / 竖线滑动 0.12、悬停提示延迟 0.35 + 淡入 0.1；数 = 数字数到新值（件.趋 指数趋近，「到位」≈ 这个时间）
#   鼠标（规范 §3）：可点范围 ≥ 44 px（1440p），外扩 8 px 容差；按下缩到 0.97
const 点击 := {"最小": 44.0, "容差": 8.0, "按缩": 0.97, "滚轮": 5.0}
#   呼：警告呼吸一周期；环出：罗盘环从车身长出来
# ———————————————————— 扫描脉冲（docs/界面/UI体系.md §4.8；扫描.gd、扫描.gdshader）
#   键：Space 或鼠标中键（Tab 被玩法 A 的相册占了）；要换键只改这两项。环时：环扫完半径用的时间；时长：世界效果总时间；留：小标停留。
const 扫 := {"键": KEY_SPACE, "鼠标": MOUSE_BUTTON_MIDDLE, "半径": 60.0, "环时": 1.5, "时长": 2.6, "点距": 0.5, "点径": 0.026, "命": 0.40, "尾": 0.8,
	"留": 6.0, "冷却": 6.0, "强": 2.4, "环强": 1.0, "点强": 1.0, "边强": 0.8, "晕白": 0.2, "排车": 2.0}
#   配色（扫描.gd 设色）：环芯 = 白（亮度对比，橙地上最亮）；环晕 = 「活」向白提亮 晕白（NASA：#0B3D91 → 约 #8A9FC9 的冷蓝，和橙地互补）；
#   点 = 「主」；边缘高光 = 环晕色；坡度到注意 / 警告线的表面，点 = 「注意」/「警告」（红）。命：点亮度衰减时间常数；尾：环后拖光长度 m；排车：车周围不参与的半径 m。
# ———————————————————— 地面图形（界面/地面.gd）
const 地 := {"亮": 0.85, "环R": 2.3, "环暗": 0.45}

# ———————————————————— 标题（占位；用户还没定片名，改片名只改这两行）
const 片名 := "杰泽罗"
const 片名中 := "SOL 530"
const 图标路径 := "res://界面/游戏图标/图标_256.png"      # 游戏图标（火星车日落剪影，用户 2026-10-08 定）：主菜单、载入画面的图标位

# ———————————————————— 设置（主菜单「设置」页；user://设置.cfg；只在走主菜单启动时读，自测和测帧用默认值）
#   地亮 = 百分数（50–130；旧版存的是 0/1/2 档，读到小于 10 的值按 [60, 85, 110] 换算）；缩放 / AA = 画质预设之上的手改（空串 = 跟预设；非空 → 设置页显示「自定义」，写进 [参数] 节覆盖预设）。
#   存取走 环境.设置读 / 设置写 / 设置存（user://settings.cfg 的 [args] 节，docs/工程化方案.md §6.0）；键名：画质预设、界面档、地亮、单位、语言、配色、字号、动效、上次
const 设置默认 := {"画质": "高", "界面档": 1, "地亮": 85, "缩放": "", "AA": "", "单位": 0, "语言": 0, "配色": 默认色板, "字号": 0, "动效": 0, "上次": ""}
var 设置 := 设置默认.duplicate()
var 单位 := 0                                      # 0 公制 / 1 英制（距字()、速字()）
var 载入层: CanvasLayer = null                     # 启动载入画面（界面/载入.gd），主菜单接手后清掉
var 载入记: Array = []                             # 载入各步的时间 [[步, ms], …]

var s := 1.0                                       # 以 1440 高为 1
var 字倍 := 1.0                                    # 设置里的字号倍率（0.85–1.3）
var 动倍 := 1.0                                    # 设置里的「界面动效」：1 正常 / 0.5 减半 / 0 关（XAG 117：动效要能整个关掉）


func _init() -> void:
	设色板(默认色板, false)


func _ready() -> void:
	载字()
	get_tree().root.size_changed.connect(量尺)
	量尺()
	if 要菜单():
		读设置()
		pass                                                            # 载入画面是 autoload「载入」（project.godot），在主场景之前进树；它自己挂 令.载入层
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--配色="): 设色板(a.trim_prefix("--配色="), false)
		if a.begins_with("--语言="): 语言覆盖 = a.trim_prefix("--语言="); 设语言(语言覆盖, false)      # --语言=en|zh：盖过设置和系统语言（不存进设置）
		if a.begins_with("--动倍="): 动倍 = clampf(float(a.trim_prefix("--动倍=")), 0.0, 1.0)         # 自测 / 录像：不进设置页，直接指定界面动效倍率（1 正常 / 0.5 减半 / 0 关）


func 要菜单() -> bool:
	"""玩的时候（导出版，或带 --设置，漫游.sh 会带）走主菜单；自测、测帧、渲染、视频、--菜单=0 都不走；--菜单 / --菜单测试 强制走。"""
	if DisplayServer.get_name() == "headless": return false
	var a := " ".join(OS.get_cmdline_user_args())
	if a.contains("--菜单测试") or a.contains("--菜单录="): return true
	for k in ["--界面测试", "--玩法测试", "--控制测试", "--测帧", "--渲染", "--视频", "--菜单=0", "--首帧退出"]:
		if a.contains(k): return false
	return 环境.用设置() or a.contains("--菜单")


func 读设置(强 := false) -> void:
	设置 = 设置默认.duplicate()
	if not 测菜单() or 强:                                                  # 菜单自测用默认值，不读也不写玩家的设置
		for k in 设置.keys():
			var v := 环境.设置读(_键(k), "")
			if v != "": 设置[k] = v if 设置默认[k] is String else int(v)
	if int(设置["地亮"]) < 10: 设置["地亮"] = [60, 85, 110][clampi(int(设置["地亮"]), 0, 2)]
	设色板(String(设置["配色"]), false)
	if 环境.设置读("语言", "") == "": 设置["语言"] = 1 if _系统语言() != "zh" else 0           # 第一次启动：中文系统用中文，其它用英文
	设语言(语言码[clampi(int(设置["语言"]), 0, 语言码.size() - 1)], false)
	单位 = int(设置["单位"]); 字倍 = [1.0, 1.15, 1.3][clampi(int(设置["字号"]), 0, 2)]; 动倍 = [1.0, 0.5, 0.0][clampi(int(设置["动效"]), 0, 2)]


# ———————————————————— 语言（界面/翻译/；docs/界面/英文界面_交接.md）
#   界面原文是中文：所有画出来的字都经 件.gd 的 字串 / 宽度 / 段落，那里调 令.译(原文)；中文模式原样返回，英文模式查 界面/翻译/英文.gd 的表。
#   表的键 = 中文原文；原文里的数字写成 #（按出现顺序填回，英文要换序写 #1 #2）；整句查不到再按 " · " 和换行拆开逐段查；还查不到且含汉字 → 记进 译缺 并打印 [译缺]。
#   加语言：写 界面/翻译/<名>.gd（const 表），在 翻译表 和 语言码 里各加一项，设置页的选项表也加一个名字。
const 翻译表 := {"en": preload("res://界面/翻译/英文.gd")}
const 语言码 := ["zh", "en"]                          # 设置里「语言」的选项号 → 语言码
var 语言 := "zh"
const 分隔 := [["\n", "\n"], [" · ", " · "], ["：", ": "], ["　", "   "], ["。", ". "], ["（", " ("], ["）", ")"], ["，", ", "], ["、", ", "], ["；", "; "]]
var 语言覆盖 := ""                                   # 命令行 --语言= 给的；非空时设置页里改了也不动当前语言
var 译缺: Dictionary = {}                             # 英文模式下没译到的含汉字串 → 次数（自测检查它是空的）
var 译缺记 := true
var _表: Dictionary = {}
var _词: Array = []                                   # 词表：整串、分段都查不到时，把里面的已知词换掉（版本行这类拼出来的串用）
var _译缓: Dictionary = {}
var _数 := RegEx.create_from_string("[+-]?\\d+(?:\\.\\d+)?")


func _系统语言() -> String:
	return OS.get_locale_language()


func 设语言(码: String, 发 := true) -> void:
	if 语言覆盖 != "" and 码 != 语言覆盖: return
	if not 语言码.has(码): 码 = "zh"
	if 码 == 语言: return
	语言 = 码; _译缓.clear()
	_表 = 翻译表[码].表 if 翻译表.has(码) else {}
	_词 = 翻译表[码].词.duplicate() if 翻译表.has(码) else []
	_词.sort_custom(func(a, b): return String(a[0]).length() > String(b[0]).length())
	if 发: 变了.emit()


func 英() -> bool:
	return 语言 != "zh"


func 登记译(中: String, 英: String) -> void:
	"""运行时往英文表里补一条（兴趣点、挑战的名字和说明来自数据文件的 "en"）。"""
	if 中 == "" or 英 == "": return
	_数据译[中] = 英; _译缓.erase(中)


var _数据译: Dictionary = {}


func 译(t: String) -> String:
	"""界面原文（中文）→ 当前语言。中文模式原样返回。"""
	if 语言 == "zh" or t.is_empty(): return t
	var r: Variant = _译缓.get(t)
	if r != null: return r
	var o := _译查(t)
	if _译缓.size() > 4000: _译缓.clear()
	_译缓[t] = o
	return o


func _译查(t: String) -> String:
	if _表.has(t): return _表[t]
	if _数据译.has(t): return _数据译[t]
	var 空 := t.strip_edges()
	if 空 != t and not 空.is_empty():                                     # 前后的空格、换行原样留着
		var i0 := t.find(空); return t.substr(0, i0) + _译查(空) + t.substr(i0 + 空.length())
	var m := _数.search_all(t)
	if not m.is_empty():
		var 数: Array[String] = []
		for x in m: 数.append(x.get_string())
		var 模 := _数.sub(t, "#", true)
		if _表.has(模): return _填(String(_表[模]), 数)
	for 隔 in 分隔:                                                       # 拆开逐段译：[原文里的分隔, 英文里的分隔]
		if t.contains(隔[0]):
			var 段 := t.split(隔[0]); var out := PackedStringArray()
			for x in 段: out.append(_译查(x))
			return String(隔[1]).join(out)
	if _有汉字(t) and not _词.is_empty():
		var r := t
		for w in _词: r = r.replace(String(w[0]), String(w[1]))
		if not _有汉字(r): return r
	if _有汉字(t):
		if 译缺记 and not 译缺.has(t): print("[译缺] ", t)
		译缺[t] = int(译缺.get(t, 0)) + 1
	return t


func _填(en: String, 数: Array[String]) -> String:
	if en.contains("#1"):
		for i in range(数.size(), 0, -1): en = en.replace("#%d" % i, 数[i - 1])
		return en
	var out := ""; var k := 0
	for ch in en:
		if ch == "#" and k < 数.size(): out += 数[k]; k += 1
		else: out += ch
	return out


func _有汉字(t: String) -> bool:
	for i in t.length():
		var c := t.unicode_at(i)
		if (c >= 0x2E80 and c <= 0x9FFF) or (c >= 0xFF00 and c <= 0xFFEF) or (c >= 0x3000 and c <= 0x303F): return true
	return false


func 菜单录() -> String:
	"""--菜单录=<目录>：录主菜单短片（界面/菜单录.sh）。载入各步的画面存成 载入_NN.png，其余由 Movie Maker 录。"""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--菜单录="): return a.trim_prefix("--菜单录=")
	return ""


func 测菜单() -> bool:
	return " ".join(OS.get_cmdline_user_args()).contains("--菜单测试") or 菜单录() != ""


func 存设置(强 := false) -> void:
	if 测菜单() and not 强: return                                            # 自测不动玩家的设置
	for k in 设置.keys(): 环境.设置写(_键(k), 设置[k])
	环境.设置存()


func _键(k: String) -> String:
	return "画质预设" if k == "画质" else k


func 距字(m: float) -> String:
	"""距离（按设置的单位）：公制 m / km，英制 ft / mi。"""
	if 单位 == 1:
		var ft := m*3.28084
		return ("%.1f mi" % (m/1609.344)) if ft >= 5280.0 else ("%d ft" % roundi(ft))
	return ("%.1f km" % (m/1000.0)) if m >= 1000.0 else ("%d m" % roundi(m))


func 速字(mps: float) -> String:
	return ("%.3f ft/s" % (mps*3.28084)) if 单位 == 1 else ("%.3f m/s" % mps)


var _图标: Texture2D = null
func 图标贴图() -> Texture2D:
	if _图标 == null and ResourceLoader.exists(图标路径):
		var t := load(图标路径) as Texture2D
		if t: _图标 = ImageTexture.create_from_image(t.get_image())
	return _图标


func 设色板(名: String, 发 := true) -> void:
	if not 色板.has(名): push_warning("[令] 没有色板 %s，用 %s" % [名, 默认色板]); 名 = 默认色板
	板 = 名; var d: Dictionary = 色板[名]
	色 = {}
	for k in d:
		if k == "名": continue
		色[k] = Color.html(d[k]) if d[k] != "" else Color(0, 0, 0, 0)
	有活边 = d["活边"] != ""
	if not 有活边: 色["活边"] = 色["暗"]
	if 发: 变了.emit()


func 设字倍(k: float) -> void:
	字倍 = clampf(k, 0.85, 1.3); 变了.emit()


func 量尺() -> void:
	var h := float(get_tree().root.get_visible_rect().size.y) if get_tree() else 1440.0
	s = clampf(h/1440.0, 0.75, 3.0)


func 边(c: Color) -> Color:
	"""一个前景色该配的描边色：「活」色在有活边的色板里配白边，其余配暗色。"""
	return 色["活边"] if 有活边 and 是活(c) else 色["暗"]


func 是活(c: Color) -> bool:
	var a: Color = 色["活"]
	return absf(c.r - a.r) + absf(c.g - a.g) + absf(c.b - a.b) < 0.01


func 态色(态: String) -> Color:
	"""组件状态 → 颜色：常 / 悬 / 选 / 禁 / 注意 / 警告。"""
	match 态:
		"选": return 色["活"]
		"选亮": return 色["活亮"]                                    # 深色渐变页上的选中（设置页）
		"禁": return Color(色["主"], 透["禁"])
		"注意": return 色["注意"]
		"警告": return 色["警告"]
		_: return 色["主"]


func 时长(名: String) -> float:
	"""动效时长（乘 动倍；0 = 关动效，调用方按 0 直接跳到终态）。"""
	return float(时[名])*动倍


func 透色(角色: String, a: float) -> Color:
	var c: Color = 色[角色]; return Color(c, c.a*a)


func 缓(t: float, 式 := "出") -> float:
	"""缓动：出 = ease-out cubic（出现）；入 = ease-in cubic（消失）；入出 = 两头慢；弹 = 轻微回弹（小标立杆）。"""
	t = clampf(t, 0.0, 1.0)
	match 式:
		"入": return t*t*t
		"入出": return t*t*(3.0 - 2.0*t)
		"弹":
			var c1 := 1.4; return 1.0 + (c1 + 1.0)*pow(t - 1.0, 3.0) + c1*pow(t - 1.0, 2.0)
		_: return 1.0 - pow(1.0 - t, 3.0)


func 载字() -> void:
	if not 环境.数据问题.is_empty():                                         # 没有数据：data/界面/素材 里的字体读不到，全部用 PCK 里的子集字体（界面/缺数据.gd）
		var f: Font = load("res://界面/缺数据/NotoSansSC-400-GB2312.ttf")
		for k in ["正", "中", "粗", "等", "等中", "标", "细", "片"]: 字[k] = f
		return
	var 素材: String = 环境.外置("界面/素材/")
	var cjk := FontFile.new(); cjk.load_dynamic_font(素材 + "NotoSansSC-VF.ttf")
	var w := {}
	var 轴: int = TextServerManager.get_primary_interface().name_to_tag("wght")      # 变量字体的字重轴要用整数标签当键；用字符串键「wght」不生效，中文一直是默认的 Thin 100（界面 4 发现）
	for k in [[4, 400], [5, 500], [7, 700]]:
		var v := FontVariation.new(); v.base_font = cjk; v.variation_opentype = {轴: k[1]}; w[k[0]] = v
	for k in [["正", "Inter-Regular.ttf", 4], ["中", "Inter-Medium.ttf", 5], ["粗", "Inter-SemiBold.ttf", 7]]:
		var f := FontFile.new(); f.load_dynamic_font(素材 + k[1])
		var fb: Array[Font] = [w[k[2]]]; f.fallbacks = fb
		var t := FontVariation.new(); t.base_font = f; t.opentype_features = {"tnum": 1}   # 等宽数字：读数不跳
		字[k[0]] = t
	for k in [["等", "IBMPlexMono-Regular.ttf"], ["等中", "IBMPlexMono-Medium.ttf"]]:
		var f := FontFile.new(); f.load_dynamic_font(素材 + k[1])
		var fb: Array[Font] = [字["正"], w[4]]                 # 中文回退用 400 字重（原来是没设字重的 cjk = Thin 100，等宽小字里的中文发虚）; f.fallbacks = fb
		字[k[0]] = f
	var sp := FontVariation.new(); sp.base_font = 字["中"]; sp.spacing_glyph = 2
	字["标"] = sp
	字["细"] = w[4]                                 # 片名用（Noto 400；片名大字另设字重）
	var th := FontVariation.new(); th.base_font = cjk; th.variation_opentype = {轴: 300}; 字["片"] = th
