# 自动驾驶：跟踪航点（盲开 / 视觉里程计）+ AutoNav 选弧（设计 docs/玩法B.md §4.4、§6）。
#   玩法 B 的预演（玩法/航线.gd，定步长、已知图）和执行（控制.gd 自驾一帧，真值图）用同一份：步(运动态, h) 一次走 h 模拟秒——
#   算指令 → 控制.运动步()（M = 1）→ 地高拟合平面算倾角 → 打滑（只盲开）→ 记能量账 → 判故障 / 到达。
#   坐标：Godot 的 (x, z)；航向 ψ 同 控制.gd：前 f = (cos ψ, sin ψ)，左 l = (sin ψ, −cos ψ)，左转 ψ 减小。
#   没有随机数：同样的输入两次结果逐位相同。
extends RefCounted

const 控制脚本 := preload("res://控制/控制.gd")
const 方式名 := ["盲开", "视觉里程计", "AutoNav"]
const 方式英 := ["BLIND", "VISODOM", "AUTONAV"]
const 速度_mh := [152.0, 135.0, 120.0]          # 盲开 = 真车最高 152 m/h ✔；AutoNav ≈ 120 m/h ✔；视觉里程计 135 m/h 游戏设定
const 到达半径 := [0.5, 0.5, 1.5]               # m（AutoNav 绕行后难正好压上航点，放宽）——游戏设定
const 转向阈 := deg_to_rad(20.0)                # 车头和目标差 > 20° 先原地转（游戏设定）
const 对准阈 := deg_to_rad(3.0)
const 前视 := 3.0                               # 纯追踪前视距离 m（游戏设定）
# AutoNav（游戏设定；思路同 GESTALT：候选弧在可通行性网格上打分）
const 弧κ := [0.0, 0.05, -0.05, 0.1, -0.1, 0.2, -0.2, 0.3, -0.3, 0.4, -0.4]
const 弧长 := 6.0
const 弧步 := 0.5
const 重选 := 1.0
const 权险 := 4.0
const 权近 := 1.0
const 权向 := 0.5

# 输入
var 路 := PackedVector2Array()                  # 航点 (x, z)，第 0 个是出发点
var 方式 := PackedInt32Array()                  # 每段一个
var 禁: Array = []                              # 禁行区 Vector3(x, z, r)
var 通: RefCounted = null                       # 可通行性（玩法/通行.gd 的 图）：风险(x, z)、堵(x, z)、石堵(x, z)；没有就不避障、不判撞石
var 几何 := {}                                  # 控制.gd 的 几何 {W, corner, ZC, ZP, G}
var 地高: Callable                              # (x, z) → 地面高
var 账: RefCounted = null                       # 玩法/能源.gd 的账（过(h)、驾驶(h, v, θ, 方式, w)）；没有就不记
var 外检: Callable                              # (t 模拟秒) → 停车原因（时窗、电量），"" = 继续；可以不设（不要捕获本对象，免得循环引用）
var 倾角上限 := 25.0                            # °（游戏设定）
# 状态
var 段 := 1
var 偏 := Vector2()                             # 盲开：以为的位置 − 真位置（打滑没被发现）
var 已对准 := false
var 对准中 := false
var 弧 := 0.0; var 弧剩 := 0.0                   # AutoNav 当前弧的曲率、还要走多远再重选
var 转剩 := 0.0; var 转累 := 0.0                 # AutoNav 无路时的原地转：还要转多少（rad，左正）、累计
var 油门 := 0.0
var 完 := false
var 原因 := ""
var t := 0.0                                     # 模拟秒
var 里程 := 0.0
var 倾角 := 0.0
var 风险 := 0.0
var 最大倾角 := 0.0
var 事件: Array = []                             # [{类, x, z, t, 值}]
var 高险中 := false
var 绕行中 := false


func 开始(s: Dictionary) -> void:
	段 = 1; 偏 = Vector2(); 已对准 = false; 对准中 = false; 弧剩 = 0.0; 转剩 = 0.0; 转累 = 0.0; 完 = 路.size() < 2; 原因 = "到达" if 完 else ""
	t = 0.0; 里程 = 0.0; 事件.clear(); 最大倾角 = 0.0; 高险中 = false; 绕行中 = false
	量姿(s)


func 当前方式() -> int:
	return 方式[clampi(段 - 1, 0, 方式.size() - 1)] if 方式.size() > 0 else 1


func 步(s: Dictionary, h: float) -> void:
	if 完: return
	var u := 指令(s)
	if 完: return
	var p0: Vector3 = s["p"]; var o0: float = s["odo"]
	控制脚本.运动步(s, 几何, h, u.x, u.y, u.z, 1.0)
	t += h
	var p: Vector3 = s["p"]; var ds: float = float(s["odo"]) - o0
	里程 += ds
	if 弧剩 > 0.0: 弧剩 -= ds
	if 转剩 != 0.0: 转剩 = move_toward(转剩, 0.0, absf(float(s["w"]))*h)
	var a := 量姿(s)                                                   # 前向坡（dh/d前，上坡为正）
	var m := 当前方式()
	var θ := atan(a)*signf(float(s["v"])) if absf(float(s["v"])) > 1e-6 else 0.0
	if m == 0:                                                         # 盲开：打滑没被发现，以为走得比真远
		var 滑 := clampf(0.02 + 0.8*maxf(0.0, sin(θ)), 0.0, 0.6)          # 游戏设定
		偏 += Vector2(p.x - p0.x, p.z - p0.z)*滑
	else: 偏 = Vector2()                                               # 视觉里程计 / AutoNav：边走边纠正
	if 账: 账.过(h); 账.驾驶(h, absf(float(s["v"])), θ, m, absf(float(s["w"])))
	# 故障（先后：倾角、撞石、外部：时窗 / 电量）
	if 倾角 >= 倾角上限: 停(s, "倾角超限", 倾角); return
	if 通 and 通.石堵(p.x, p.z): 停(s, "预计撞石", 0.0); return
	if 外检.is_valid():
		var r: String = 外检.call(t)
		if r != "": 停(s, r, 0.0); return
	if 通:
		风险 = 通.风险(p.x, p.z)
		if 风险 >= 0.66 and not 高险中: 记(s, "高风险", 风险)
		高险中 = 风险 >= 0.66


func 停(s: Dictionary, r: String, 值: float) -> void:
	完 = true; 原因 = r; 油门 = 0.0; 记(s, r, 值)


func 记(s: Dictionary, 类: String, 值: float) -> void:
	var p: Vector3 = s["p"]
	事件.append({"类": 类, "x": p.x, "z": p.z, "t": t, "值": 值})


func 量姿(s: Dictionary) -> float:
	"""六个轮位的地高最小二乘平面（同 控制.gd 平面拟合）→ 倾角（°），返回前向坡 a。"""
	var p: Vector3 = s["p"]; var psi: float = s["psi"]
	var f := Vector3(cos(psi), 0, sin(psi)); var l := Vector3(sin(psi), 0, -cos(psi))
	var W: Array = 几何["W"]; var G: Array = 几何["G"]
	var fit := Vector3()
	for i in 6:
		var c: Vector3 = p + f*W[i].z + l*W[i].x
		fit += (G[i] as Vector3)*float(地高.call(c.x, c.z))
	倾角 = rad_to_deg(atan(sqrt(fit.y*fit.y + fit.z*fit.z)))
	最大倾角 = maxf(最大倾角, 倾角)
	return fit.y


func 指令(s: Dictionary) -> Vector3:
	"""→ (油门, 转向, 原地)，左正。顺带处理到航点 / 到终点。"""
	var p: Vector3 = s["p"]; var psi: float = s["psi"]
	var f := Vector2(cos(psi), sin(psi)); var l := Vector2(sin(psi), -cos(psi))
	var 估 := Vector2(p.x, p.z) + 偏
	var m := 当前方式()
	# 到航点：进到达半径，或越过航点的垂线
	while true:
		var 目 := 路[段]; var 前 := 路[段 - 1]
		var 段向 := (目 - 前).normalized()
		if 估.distance_to(目) < 到达半径[m] or (段向 != Vector2.ZERO and 段向.dot(估 - 目) > 0.0):
			记(s, "到航点", float(段))
			if 段 >= 路.size() - 1:
				完 = true; 原因 = "到达"; 油门 = 0.0; return Vector3.ZERO
			段 += 1; 已对准 = false; 弧剩 = 0.0; 转剩 = 0.0; 转累 = 0.0; m = 当前方式()
		else: break
	var 目 := 路[段]
	var d := 目 - 估
	var 差 := atan2(d.dot(l), d.dot(f))                                  # 目标在左为正
	var 速 := minf(1.0, 速度_mh[m]/3600.0/控制脚本.V_REAL)
	if m == 2: return AutoNav(s, 差, 速)
	# 跟踪：先原地对准，再纯追踪
	if not 已对准:
		if absf(差) > 对准阈: return 原地(差)
		已对准 = true
	var 前 := 路[段 - 1]; var 段向 := (目 - 前).normalized()
	var 投 := 前 + 段向*clampf((估 - 前).dot(段向) + 前视, 0.0, (目 - 前).length())
	var e := 投 - 估
	var α := atan2(e.dot(l), e.dot(f))
	if absf(α) > 转向阈 and e.length() > 0.3: 已对准 = false; return 原地(α)
	var κ := 2.0*sin(α)/maxf(e.length(), 0.5)
	油门 = 速
	return Vector3(速, clampf(κ/控制脚本.K_MAX, -1.0, 1.0), 0.0)


func 原地(差: float) -> Vector3:
	油门 = 0.0
	return Vector3(0.0, 0.0, signf(差)*clampf(absf(差)/0.08, 0.15, 1.0))


func AutoNav(s: Dictionary, 差: float, 速: float) -> Vector3:
	if 转剩 != 0.0: return 原地(转剩)                                    # 无路时的原地转还没转完
	if absf(差) > deg_to_rad(100.0): 已对准 = false                       # 绕过头、目标跑到身后：重新对准
	if not 已对准:
		if absf(差) > deg_to_rad(60.0): 对准中 = true
		if 对准中 and absf(差) > deg_to_rad(10.0): return 原地(差)
		对准中 = false; 已对准 = true
	if 弧剩 <= 0.0:
		var best := INF; var 选 := NAN; var 左堵 := 0; var 右堵 := 0; var 中堵 := false
		var p: Vector3 = s["p"]; var psi: float = s["psi"]
		var f := Vector2(cos(psi), sin(psi)); var l := Vector2(sin(psi), -cos(psi))
		var 目 := 路[段]; var 距0 := Vector2(p.x, p.z).distance_to(目)
		for k: float in 弧κ:
			var 险 := 0.0; var ok := true; var q := Vector2(p.x, p.z); var fq := f
			var n := int(弧长/弧步)
			for j in range(1, n + 1):
				var u := j*弧步
				if absf(k) > 1e-6: q = Vector2(p.x, p.z) + f*(sin(k*u)/k) + l*((1.0 - cos(k*u))/k); fq = f*cos(k*u) + l*sin(k*u)
				else: q = Vector2(p.x, p.z) + f*u
				if (通 and 通.堵(q.x, q.y)) or 在禁(q): ok = false; break
				if 通: 险 += 通.风险(q.x, q.y)*弧步
			if not ok:
				if k > 0.0: 左堵 += 1
				elif k < 0.0: 右堵 += 1
				else: 中堵 = true
				continue
			var dq := 目 - q
			var 向差 := absf(atan2(dq.dot(Vector2(fq.y, -fq.x)), dq.dot(fq))) if dq.length() > 0.5 else 0.0
			var c := 权险*险 + 权近*(dq.length() - 距0) + 权向*向差
			if c < best: best = c; 选 = k
		if is_nan(选):                                                  # 全堵：往堵得少的一侧原地转 30°
			转累 += deg_to_rad(30.0)
			if 转累 > TAU + 0.01: 停(s, "AutoNav 无路", 0.0); return Vector3.ZERO
			if not 绕行中: 记(s, "绕行", 0.0)
			绕行中 = true
			转剩 = deg_to_rad(30.0)*(1.0 if 左堵 <= 右堵 else -1.0)
			return 原地(转剩)
		var 堵数 := 左堵 + 右堵 + (1 if 中堵 else 0)
		if 堵数 > 0 and not 绕行中: 记(s, "绕行", 选)
		绕行中 = 堵数 > 0
		转累 = 0.0; 弧 = 选; 弧剩 = 重选
	油门 = 速
	return Vector3(速, clampf(弧/控制脚本.K_MAX, -1.0, 1.0), 0.0)


func 在禁(q: Vector2) -> bool:
	for z: Vector3 in 禁:
		if Vector2(z.x, z.y).distance_to(q) < z.z: return true
	return false
