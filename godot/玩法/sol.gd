# 玩法 B：sol 规划（设计 docs/玩法B.md）。玩法.gd 的子模块「B」，始终运行（同玩法根节点）。
#   循环：新 sol 09:00 → 下行卡（上个 sol 的状态、Navcam 环视）→ 规划图（航点、禁行区、每段驾驶方式、预演）→ 上传
#        → 执行（控制.gd 自动驾驶，倍率表快进，10:00–15:00 时窗）→ 报告卡 → 过夜 → 下一个 sol。
#   F2：手动驾驶 ⇄ sol 规划。进入时车回任务位置、时刻回任务时钟（手动漫游不计入任务）；执行中按 F2 中止。
#   子节点：图页（规划图.gd）、卡页（下行.gd：下行卡、报告卡）、影（影子.gd：影子车、3D 路径带）。
#   存档 user://玩法B.json（自测用 玩法B_自测.json）。给界面：B状态()。
extends Node

const 能源脚本 := preload("res://玩法/能源.gd")
const 通行脚本 := preload("res://玩法/通行.gd")
const 航线脚本 := preload("res://玩法/航线.gd")
const 版本 := 1
const 晨 := 540.0                                 # 新 sol 从 LTST 09:00 开始（游戏设定）
const 窗 := Vector2(600.0, 900.0)                 # 驾驶时窗 10:00（游戏设定）–15:00（参照好奇号「time-of-day limit … about 15:00」✔）
var 倾角上限 := 25.0                               # °，游戏设定（真车设计上任意方向倾 45° 不翻 ✔）；自测会临时调低
const 起始sol := 531                               # sol 530 的停车点是第一天的出发点
const 默认倍率 := 6                                # 执行时默认 100×（控制.gd RATES 的下标）

var 玩: Node
var P: Node
var 风: RefCounted
var 控: Node = null
var 存档文件 := "user://玩法B.json"
# 任务状态（存档）
var sol := 起始sol
var 阶段 := "下行"                                 # 下行 / 规划 / 执行 / 报告
var 车 := {}                                       # {E, N, 航向}（航向 0 = 北、顺时针，度）
var 时刻 := 晨                                     # 任务时钟（LTST 分钟）
var 账: RefCounted                                 # 能源.gd（本 sol 的账）
var 里程 := 0.0
var 计划: RefCounted                               # 航线.gd
var 历史: Array = []
var 上次 := {}                                     # 上个 sol 的报告（下行卡用）
# 运行
var 开着 := false                                  # 在 sol 规划模式里（相对于手动驾驶）
var 通: RefCounted = null                          # 通行.gd（本 sol）
var 通任务 := -1
var 通新: RefCounted = null
var 叠图: ImageTexture = null
var 险片 := false                                  # --风险层=片：旧的整片着色（琥珀 → 红）；默认稀疏标记 + 很淡的底色
var 险标: PackedByteArray = PackedByteArray()      # 通行.标记图() 的数据（含 mipmap）
var 险标偏移: Array = []
var 预演 := {}                                     # 最近一次预演的结果（计划改了就清空）
var 预演任务 := -1
var 预演盒: Array = []
var 预演版 := 0                                    # 计划版本：预演结果对应哪一版
var 计划版 := 0
var 驾: RefCounted = null                          # 执行中的 自驾
var 执行起分 := 0.0
var 发现前 := {}
var 报告 := {}
var 设时分 := -1.0
var 图页: Node
var 卡页: Node
var 影: Node
var 状态层: CanvasLayer
var 状态画: Control
var 提示 := ""; var 提示时 := 0.0


func _ready() -> void:
	玩 = get_parent(); P = 玩.P; 风 = 玩.风
	process_mode = Node.PROCESS_MODE_ALWAYS
	if P.args.has("玩法测试"): 存档文件 = "user://玩法B_自测.json"
	控 = P.get_node_or_null("控制")
	计划 = 航线脚本.new()
	读档(true)
	for k in [["图页", "res://玩法/规划图.gd"], ["卡页", "res://玩法/下行.gd"], ["影", "res://玩法/影子.gd"]]:
		var n: Node = load(k[1]).new(); n.name = k[0]; add_child(n); set(k[0], n)
	状态层 = CanvasLayer.new(); 状态层.layer = 47; add_child(状态层)               # 执行状态行、提示（提示要压在全屏页上面）
	状态画 = Control.new(); 状态画.set_anchors_preset(Control.PRESET_FULL_RECT); 状态画.mouse_filter = Control.MOUSE_FILTER_IGNORE
	状态画.draw.connect(_画状态); 状态层.add_child(状态画)
	if 控 and 控.has_signal("自驾结束"): 控.自驾结束.connect(_执行完)
	print("[玩法B] sol %d、阶段 %s、电量 %.0f Wh、累计 %.1f m" % [sol, 阶段, 账.电量, 里程])


# ———————————————————— 存档
func 默认车() -> Dictionary:
	if 控 == null: return {"E": 0.0, "N": 0.0, "航向": 0.0}
	var pk: Transform3D = 控.park; var f := pk.basis.z
	return {"E": pk.origin.x, "N": -pk.origin.z, "航向": fposmod(rad_to_deg(atan2(f.x, -f.z)), 360.0)}


func 读档(启动 := false) -> void:
	sol = 起始sol; 阶段 = "下行"; 车 = 默认车(); 时刻 = 晨; 里程 = 0.0; 历史 = []; 上次 = {}
	var e := -1.0
	var j = null
	if not (启动 and P.args.get("玩法新档", "0") == "1") and FileAccess.file_exists(存档文件):
		j = JSON.parse_string(FileAccess.get_file_as_string(存档文件))
	if j is Dictionary and int(j.get("版本", 0)) == 版本:
		sol = int(j["sol"]); 阶段 = String(j.get("阶段", "下行")); 车 = j["车"]; e = float(j["电量_Wh"]); 里程 = float(j.get("里程_m", 0.0))
		时刻 = float(j.get("时刻", 晨)); 历史 = j.get("历史", []); 上次 = 历史[-1] if not 历史.is_empty() else {}
		if j.has("草稿"): 计划.读(j["草稿"])
		if 阶段 == "执行": 阶段 = "规划"                               # 执行中存的档：回到规划（执行不续）
	elif j != null: push_warning("[玩法B] 存档版本不符，不读：%s" % 存档文件)
	账 = 能源脚本.new(sol, e)
	重置起点()


func 存档() -> void:
	var j := {"版本": 版本, "游戏": str(ProjectSettings.get_setting("application/config/version", "?")), "sol": sol, "阶段": 阶段,
		"车": 车, "电量_Wh": 账.电量, "里程_m": 里程, "时刻": 时刻, "草稿": 计划.存(), "历史": 历史}
	var f := FileAccess.open(存档文件, FileAccess.WRITE)
	if f: f.store_string(JSON.stringify(j, "\t", false, true)); f.close()


# ———————————————————— 位姿换算（航向 0 = 北、顺时针 ↔ 控制.gd 的 ψ：前 = (cos ψ, 0, sin ψ)）
static func 航向到ψ(h: float) -> float:
	var r := deg_to_rad(h)
	return atan2(-cos(r), sin(r))


static func ψ到航向(psi: float) -> float:
	return fposmod(rad_to_deg(atan2(cos(psi), -sin(psi))), 360.0)


func 车位G() -> Vector2:
	return Vector2(float(车["E"]), -float(车["N"]))


func 重置起点() -> void:
	"""计划的第 0 个航点 = 任务位置（车挪了、换 sol 时调）。"""
	var e := Vector2(float(车["E"]), float(车["N"]))
	if 计划.航点.is_empty(): 计划.航点.append(e)
	else: 计划.航点[0] = e
	改计划()


func 改计划() -> void:
	计划版 += 1; 预演 = {}
	if 影: 影.清()


# ———————————————————— 进出
func 页开着() -> bool:
	return 开着 and (图页.开着 or 卡页.开着 or 影.预演中)


func 切换() -> void:
	if not 开着: 进入()
	elif 阶段 == "执行": 中止()
	else: 离开()


func 进入() -> void:
	if 控 == null: return
	开着 = true
	var s: Dictionary = 控.状态()
	var 差 := Vector2(float(车["E"]) - s["车位置"].x, float(车["N"]) + s["车位置"].z).length()
	if 差 > 0.5:
		控.teleport(Vector3(float(车["E"]), 0, -float(车["N"])), 航向到ψ(float(车["航向"])))
		提示 = "回到任务位置（手动漫游不计入任务）"; 提示时 = 4.0
	P.set_time_f(时刻); 设时分 = 时刻
	备通()
	打开阶段()


func 打开阶段() -> void:
	match 阶段:
		"下行": 卡页.下行()
		"规划": 图页.打开()
		"报告": 卡页.报告卡()


func 离开() -> void:
	图页.关(); 卡页.关(); 影.停预演()
	开着 = false
	暂停页(false); 玩.还鼠标()
	存档()


var 界显 := true

func 暂停页(on: bool) -> void:
	"""全屏页开着：世界暂停、放开鼠标、HUD 藏起来（不然 HUD 从半透明的页底下透出来）。"""
	var 界: Node = P.get_node_or_null("界面")
	if on and not 玩.暂停源.has("B"):
		if 界: 界显 = 界.visible; 界.visible = false
	elif not on and 玩.暂停源.has("B"):
		if 界: 界.visible = 界显
	玩.暂停("B", on)
	if on: 玩.放鼠标()


# ———————————————————— 可通行性（每个 sol 建一次，后台）
func 备通() -> void:
	if 通 != null or 通任务 >= 0: return
	var core: Object = P.lod.core if P.lod else null
	if core == null or 控 == null: return
	var t := 通行脚本.new(); var c := 车位G()
	var ab: Array = 控.rk_ab; var fx: Array = 控.rk_fixed
	通新 = t
	通任务 = WorkerThreadPool.add_task(func(): t.建(core, ab, fx, c.x, c.y, c))


func 通好了() -> bool:
	return 通 != null and 通.好了


func 画险标(c: CanvasItem, tl: Vector2, ppm: float, 剪: Rect2) -> void:
	"""规划图 / 下行卡的稀疏风险标记：块里不可通行格 ≥ 35 % 画红色小叉，高风险 + 不可通行 ≥ 50 % 画琥珀空心小三角。
	tl：网格左上角（x0, z0）在屏幕上的位置；ppm：像素 / m。块大小按缩放取 2^L m，使标记间距 ≥ 26 px（1440p）。
	成片的区域只有边上的块每块都画，里面的块隔一行隔一列画（密度 1/4），看得出范围又不成片。"""
	if 险标.is_empty() or not 通好了(): return
	var s: float = 风.s
	var L := clampi(ceili(log(26.0*s/ppm)/log(2.0)), 0, 5)
	var n: int = 通.N >> L; var o: int = 险标偏移[L]; var bp := float(1 << L)*ppm
	var i0 := clampi(floori((剪.position.x - tl.x)/bp), 0, n); var i1 := clampi(ceili((剪.end.x - tl.x)/bp), 0, n)
	var j0 := clampi(floori((剪.position.y - tl.y)/bp), 0, n); var j1 := clampi(ceili((剪.end.y - tl.y)/bp), 0, n)
	var 内 := 剪.grow(-7.0*s)
	var 类 := func(i: int, j: int) -> int:                               # 0 无、1 高风险、2 不可通行
		if i < 0 or j < 0 or i >= n or j >= n: return 0
		var k := o + (j*n + i)*2
		return 2 if 险标[k] >= 90 else (1 if int(险标[k]) + int(险标[k + 1]) >= 128 else 0)
	for j in range(j0, j1):
		for i in range(i0, i1):
			var t: int = 类.call(i, j)
			if t == 0: continue
			if (i % 2 != 0 or j % 2 != 0) and 类.call(i - 1, j) == t and 类.call(i + 1, j) == t and 类.call(i, j - 1) == t and 类.call(i, j + 1) == t: continue
			var q := tl + Vector2(i + 0.5, j + 0.5)*bp
			if not 内.has_point(q): continue
			if t == 2: 险叉(c, q)
			else: 险角(c, q)


func 险叉(c: CanvasItem, q: Vector2) -> void:
	var r: float = 4.5*风.s; var w: float = 1.6*风.s
	for d: Vector2 in [Vector2(r, r), Vector2(r, -r)]: c.draw_line(q - d, q + d, Color(风.暗色, 0.55), w + 2.4*风.s)
	for d: Vector2 in [Vector2(r, r), Vector2(r, -r)]: c.draw_line(q - d, q + d, 风.红, w)


func 险角(c: CanvasItem, q: Vector2) -> void:
	var r: float = 4.5*风.s; var w: float = 1.6*风.s
	var t := PackedVector2Array([q + Vector2(0, -r*1.1), q + Vector2(r, r*0.8), q + Vector2(-r, r*0.8), q + Vector2(0, -r*1.1)])
	c.draw_polyline(t, Color(风.暗色, 0.55), w + 2.4*风.s); c.draw_polyline(t, 风.琥珀, w)


func 画险标图例(c: CanvasItem, p: Vector2) -> void:
	"""图例一行：p 为左端基线。"""
	var s: float = 风.s
	险角(c, p + Vector2(8*s, -7*s)); 风.字串(c, p + Vector2(22*s, 0), "高风险", 风.号["小"], 风.灰, "正")
	var x: float = p.x + 22*s + 风.宽度("高风险", 风.号["小"], "正") + 24*s
	险叉(c, Vector2(x + 8*s, p.y - 7*s)); 风.字串(c, Vector2(x + 22*s, p.y), "不可通行", 风.号["小"], 风.灰, "正")


func _process(dt: float) -> void:
	if 通任务 >= 0 and WorkerThreadPool.is_task_completed(通任务):
		WorkerThreadPool.wait_for_task_completion(通任务); 通任务 = -1
		通 = 通新; 通新 = null
		险片 = String(P.args.get("风险层", "")) == "片"
		var 色 := {"中": 风.险中, "高": 风.险高, "堵": 风.险堵, "透明": 风.险透明} if 险片 else {"中": 风.险中, "高": 风.险高, "堵": Color(风.险高, 0.10), "透明": 0.07, "门": 0.5}
		叠图 = ImageTexture.create_from_image(通.叠图(通.知, 色))
		险标 = PackedByteArray(); 险标偏移 = []
		if not 险片:
			var im: Image = 通.标记图(通.知); 险标 = im.get_data()
			for L in 6: 险标偏移.append(im.get_mipmap_offset(L))
		print("[玩法B] 可通行性 %s，石块 %d 块（大 %d），已知图 %s" % [str(通.用时), 通.石块数, 通.大石数, str(通.统计(通.知))])
		if 图页.开着: 图页.刷新()
	if 预演任务 >= 0 and WorkerThreadPool.is_task_completed(预演任务):
		WorkerThreadPool.wait_for_task_completion(预演任务); 预演任务 = -1
		var r: Dictionary = 预演盒[0] if not 预演盒.is_empty() else {}
		if int(r.get("版", -1)) == 计划版:
			预演 = r; 影.放(预演, false)
			print("[玩法B] 预演：%s，%.1f m、%.0f s、到 %s、耗电 %.1f Wh、最大倾角 %.1f°" % [预演["停因"], 预演["里程_m"], 预演["用时_s"],
				分到字(预演["结束_ltst"]), float(预演["账"]["期初_Wh"]) - float(预演["账"]["期末_Wh"]), 预演["最大倾角"]])
		if 图页.开着: 图页.刷新()
	if 提示时 > 0.0:
		提示时 -= dt
		状态画.queue_redraw()
	if 驾 != null and not get_tree().paused:
		时刻 = 执行起分 + float(驾.t)/能源脚本.LTST分
		if absf(时刻 - 设时分) >= 1.0: P.set_time_f(时刻); 设时分 = 时刻
		if 控.自驾 != null:
			var 倾 := rad_to_deg(acos(clampf((控.body.basis.y as Vector3).normalized().y, -1.0, 1.0)))   # 悬架解算出来的真车身倾角
			驾.最大倾角 = maxf(float(驾.最大倾角), 倾)
			if 倾 >= 倾角上限: 驾.停({"p": 控.p}, "倾角超限", 倾); 控.停自驾("倾角超限")
		状态画.queue_redraw()


# ———————————————————— 规划 → 预演 → 上传
func 地高() -> Callable:
	return func(x: float, z: float) -> float: return P.lod.h_cpu(x, z, 0) if P.lod else 0.0


func 起态() -> Dictionary:
	var g := 车位G()
	return {"p": Vector3(g.x, 0, g.y), "psi": 航向到ψ(float(车["航向"]))}


func 跑预演(同步 := false) -> Dictionary:
	"""后台跑（同步 = true 时当场跑完返回，自测用）。"""
	if not 通好了() or 计划.段数() == 0: return {}
	var 版 := 计划版; var 线: RefCounted = 计划; var 图: RefCounted = 通.知; var 几何: Dictionary = 控.几何
	var 高 := 地高(); var 账副: RefCounted = 账.复制(); var 起 := 起态(); var 开始: float = maxf(时刻, 窗.x); var 限 := 倾角上限
	if 时刻 < 窗.x: 账副.过((窗.x - 时刻)*能源脚本.LTST分)              # 等到时窗开始：只有发电和日常负载
	账副.开账()
	var job := func() -> Dictionary:
		var r: Dictionary = 线.预演(起, 图, 几何, 高, 账副, 开始, 窗.y, 限); r["版"] = 版
		return r
	if 同步:
		var r: Dictionary = job.call(); 预演 = r; 影.放(预演, false); return r
	if 预演任务 >= 0: return {}
	var 盒: Array = []; 预演盒 = 盒
	预演任务 = WorkerThreadPool.add_task(func(): 盒.append(job.call()))
	return {}


func 上传() -> bool:
	if not 计划.校验().is_empty() or not 通好了() or 控 == null: return false
	图页.关(); 卡页.关(); 影.停预演()
	阶段 = "执行"
	if 时刻 < 窗.x:                                                    # 等到时窗开始
		账.过((窗.x - 时刻)*能源脚本.LTST分); 时刻 = 窗.x
	P.set_time_f(时刻); 设时分 = 时刻
	执行起分 = 时刻
	发现前 = (玩.进度["已发现"] as Dictionary).duplicate()
	var 账驾: RefCounted = 账
	驾 = 计划.造驾(通.真, 控.几何, 地高(), 账驾, 倾角上限)
	var 起分 := 执行起分; var 窗末: float = 窗.y
	驾.外检 = func(t: float) -> String:
		if 起分 + t/能源脚本.LTST分 >= 窗末: return "时窗用完"
		if 账驾.不足(): return "电量不足"
		return ""
	var s: Dictionary = 控.运动态()
	驾.开始(s)
	影.执行带()
	控.set_mode("跟车")
	控.rate_i = maxi(控.rate_i, 默认倍率)
	控.自动驾驶(驾)
	暂停页(false); 玩.还鼠标()
	存档()
	print("[玩法B] 上传：%d 段、%.0f m，%s 开始执行" % [计划.段数(), 计划.总长(), 分到字(时刻)])
	return true


func 中止() -> void:
	if 控 and 控.自驾 != null: 驾.停({"p": 控.p}, "玩家中止", 0.0); 控.停自驾("玩家中止")


func _执行完(原因: String) -> void:
	if 驾 == null: return
	var d := 驾; 驾 = null
	时刻 = 执行起分 + float(d.t)/能源脚本.LTST分; P.set_time_f(时刻); 设时分 = 时刻
	var st: Dictionary = 控.状态()
	var pos: Vector3 = st["车位置"]
	车 = {"E": pos.x, "N": -pos.z, "航向": float(st["航向_deg"])}
	里程 += float(d.里程)
	var 末: Vector2 = 计划.航点[-1]
	var 新: Array = []
	for k in (玩.进度["已发现"] as Dictionary).keys():
		if not 发现前.has(k): 新.append(k)
	var n绕 := 0; var n险 := 0
	for e: Dictionary in d.事件:
		if e["类"] == "绕行": n绕 += 1
		elif e["类"] == "高风险": n险 += 1
	报告 = {"sol": sol, "停因": 原因 if 原因 != "" else String(d.原因), "到达": 原因 == "到达", "距离_m": float(d.里程), "计划_m": 计划.总长(),
		"起_ltst": 执行起分, "止_ltst": 时刻, "用时_min": float(d.t)/60.0, "最大倾角": float(d.最大倾角),
		"离终点_m": Vector2(pos.x, -pos.z).distance_to(末), "绕行": n绕, "高风险": n险, "发现": 新,
		"账": 账.表(), "电量_Wh": 账.电量, "预演停因": 预演.get("停因", ""), "预演里程_m": float(预演.get("里程_m", 0.0)),
		"方式": 计划.方式.duplicate()}
	历史.append({"sol": sol, "距离_m": snappedf(float(d.里程), 0.01), "用时_min": snappedf(float(d.t)/60.0, 0.1),
		"耗电_Wh": snappedf(float(账.期初) - float(账.电量), 0.1), "到达": 报告["到达"], "停因": 报告["停因"], "发现": 新})
	上次 = 历史[-1]
	阶段 = "报告"
	影.清(); 状态画.queue_redraw()
	计划.航点 = [Vector2(float(车["E"]), float(车["N"]))]; 计划.方式 = []; 改计划()     # 下一个 sol 从新位置重新规划（禁行区留着）
	存档()
	print("[玩法B] 执行结束：%s，%.1f m、%.0f min、电量 %.0f Wh，账误差 %s Wh" % [报告["停因"], 报告["距离_m"], 报告["用时_min"], 账.电量, str(账.差())])
	var 事: Array = []
	for e: Dictionary in d.事件: 事.append("%s@%.0fs(%.1f,%.1f)" % [e["类"], e["t"], e["x"], -float(e["z"])])
	print("[玩法B]   事件 ", " ".join(事.slice(0, 30)), " · 终点 E %.1f N %.1f · 计划终点 E %.1f N %.1f" % [pos.x, -pos.z, 末.x, 末.y])
	if 开着: 卡页.报告卡()


func 下一个sol() -> void:
	"""过夜：从现在到下一个 sol 的 09:00，只有发电和日常负载。"""
	var 夜 := (1440.0 - 时刻 + 晨)*能源脚本.LTST分
	var 电0: float = 账.电量
	账.过(夜)
	sol += 1
	账 = 能源脚本.new(sol, 账.电量)
	时刻 = 晨; P.set_time_f(时刻); 设时分 = 时刻
	阶段 = "下行"
	通 = null; 叠图 = null; 备通()
	重置起点()
	存档()
	print("[玩法B] 进入 sol %d，电量 %.0f Wh（过夜 %+.0f Wh）" % [sol, 账.电量, 账.电量 - 电0])
	if 开着: 卡页.下行()


# ———————————————————— 键（玩法.gd 在页开着时转过来）
func 输入(ev: InputEvent) -> void:
	if 影.预演中: 影.输入(ev); return
	if 卡页.开着: 卡页.输入(ev); return
	if 图页.开着: 图页.输入(ev); return


func 按键() -> Array:
	return [["F2", "sol 规划 ⇄ 手动驾驶（执行中：中止）"]]


# ———————————————————— 给界面
func B状态() -> Dictionary:
	var 路 := PackedVector2Array(); var 航 := PackedVector2Array(); var 段 := 0; var 路式: Array = []   # 路式：路 每一段的驾驶方式
	if 开着 or 驾 != null:
		for e: Vector2 in 计划.航点: 航.append(e)
		if 驾 != null:
			段 = int(驾.段)
			var p: Vector3 = 控.p
			路.append(Vector2(p.x, -p.z))
			for i in range(段, 计划.航点.size()): 路.append(计划.航点[i]); 路式.append(int(计划.方式[i - 1]) if i >= 1 and i - 1 < 计划.方式.size() else 1)
		else:
			路 = 航; 路式 = 计划.方式.duplicate()
	var 预完 := float(预演.get("结束_ltst", -1.0))
	var 预电 := float(预演["账"]["期末_Wh"]) if not 预演.is_empty() else -1.0
	return {"开": 开着, "阶段": 阶段, "sol": sol, "执行": 驾 != null, "电量": 账.电量, "容量": 能源脚本.容量, "下限": 能源脚本.容量*能源脚本.下限比,
		"窗": 窗, "时刻": 时刻, "预计完": 预完, "预计电量": 预电, "路": 路, "路式": 路式, "航点": 航, "段": 段, "禁": 计划.禁,
		"方式": int(驾.当前方式()) if 驾 != null else -1}


static func 分到字(m: float) -> String:
	var mm := int(round(m)); return "%02d:%02d" % [posmod(mm/60, 24), mm % 60]


func _画状态() -> void:
	"""执行中：航向带下方一行状态（只描边，不加暗底）；进出模式的提示。"""
	var c := 状态画; var vs := c.size; var s: float = 风.s
	if 驾 != null and not 风.丙(P):                                      # 界面 v3「丙」：执行状态写在顶部居中、按键在底部提示里（界面.gd）
		var m: int = 驾.当前方式()
		var t := "SOL %d · AUTO · 段 %d/%d %s · LTST %s" % [sol, mini(int(驾.段), 计划.段数()), 计划.段数(), 驾.方式英[m], 分到字(时刻)]
		if not 预演.is_empty(): t += " · 预计 %s" % 分到字(float(预演["结束_ltst"]))
		风.字串(c, Vector2(vs.x*0.5, 250*s), t, 风.号["正"], 风.白, "等中", HORIZONTAL_ALIGNMENT_CENTER)
		风.字串(c, Vector2(vs.x*0.5, 278*s), "F2 中止 · − / = 快进 · C 拍照", 风.号["小"], 风.灰, "正", HORIZONTAL_ALIGNMENT_CENTER)
	if 提示时 > 0.0:
		风.字串(c, Vector2(vs.x*0.5, vs.y*0.36), 提示, 风.号["中题"], Color(风.琥珀, clampf(提示时, 0.0, 1.0)), "正", HORIZONTAL_ALIGNMENT_CENTER)
