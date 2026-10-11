# 计划（航点、每段驾驶方式、禁行区）、校验、预演（docs/玩法B.md §3、§7）。
#   坐标：计划里存 ENU (E, N)；给 自驾 / 通行 用 Godot 的 (x, z) = (E, −N)。
#   预演：定步长 1 s 模拟时间、已知图、能量账的副本，后台线程也能跑；没有随机数，同样输入两次结果逐位相同。
extends RefCounted

const 自驾脚本 := preload("res://控制/自驾.gd")
const 能源脚本 := preload("res://玩法/能源.gd")
const 间距上限 := 100.0                         # 航点间距通常 ≤ 100 m ✔（界面调研 §4.1）
const 步长 := 1.0                               # 预演定步长（模拟秒）
const 采样 := 2.0                               # 轨迹每 2 s 记一个点
const 保险 := 8.0*3600.0                        # 预演最多 8 小时

var 航点: Array = []                             # [Vector2(E, N)]，第 0 个是出发点
var 方式: Array = []                             # 每段一个：0 盲开、1 视觉里程计、2 AutoNav
var 禁: Array = []                               # [Vector3(E, N, 半径)]


static func G(e: Vector2) -> Vector2:
	return Vector2(e.x, -e.y)


func 段数() -> int:
	return maxi(航点.size() - 1, 0)


func 段长(i: int) -> float:
	return (航点[i + 1] as Vector2).distance_to(航点[i])


func 总长() -> float:
	var L := 0.0
	for i in 段数(): L += 段长(i)
	return L


func 校验() -> Array:
	"""返回问题列表（字符串）；空 = 可以上传。"""
	var out: Array = []
	if 航点.size() < 2: out.append("至少放一个航点"); return out
	for i in 段数():
		var L := 段长(i)
		if L > 间距上限: out.append("第 %d 段 %.0f m > %d m（航点间距上限）" % [i + 1, L, int(间距上限)])
	for i in range(1, 航点.size()):
		for z: Vector3 in 禁:
			if (航点[i] as Vector2).distance_to(Vector2(z.x, z.y)) < z.z: out.append("航点 %d 在禁行区里" % i)
	for i in 段数():
		if int(方式[i]) == 2: continue                                   # AutoNav 自己绕开禁行区
		for z: Vector3 in 禁:
			if 线距(Vector2(z.x, z.y), 航点[i], 航点[i + 1]) < z.z:
				out.append("第 %d 段穿过禁行区（%s 不会绕，改 AutoNav 或挪航点）" % [i + 1, 自驾脚本.方式名[int(方式[i])]]); break
	return out


static func 线距(q: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a; var t := clampf((q - a).dot(ab)/maxf(ab.length_squared(), 1e-9), 0.0, 1.0)
	return q.distance_to(a + ab*t)


func 造驾(图: RefCounted, 几何: Dictionary, 地高: Callable, 账: RefCounted, 倾角上限: float) -> RefCounted:
	var d: RefCounted = 自驾脚本.new()
	var 路 := PackedVector2Array()
	for e: Vector2 in 航点: 路.append(G(e))
	d.路 = 路; d.方式 = PackedInt32Array(方式); d.通 = 图; d.几何 = 几何; d.地高 = 地高; d.账 = 账; d.倾角上限 = 倾角上限
	var 禁g: Array = []
	for z: Vector3 in 禁: 禁g.append(Vector3(z.x, -z.y, z.z))
	d.禁 = 禁g
	return d


static func 起态(x: float, z: float, psi: float) -> Dictionary:
	var st := PackedFloat32Array(); st.resize(6)
	return {"p": Vector3(x, 0, z), "psi": psi, "kappa": 0.0, "pivot": false, "v": 0.0, "w": 0.0, "steer": st, "odo": 0.0}


func 预演(起: Dictionary, 图: RefCounted, 几何: Dictionary, 地高: Callable, 账0: RefCounted, 开始分: float, 窗末分: float, 倾角上限: float) -> Dictionary:
	"""起：起态()；账0：sol 的能量账（复制一份，不动原账）；开始分 / 窗末分：LTST 分钟。"""
	var 账: RefCounted = 账0.复制()
	var d: RefCounted = 造驾(图, 几何, 地高, 账, 倾角上限)
	d.外检 = func(t: float) -> String:
		if 开始分 + t/能源脚本.LTST分 >= 窗末分: return "时窗用完"
		if 账.不足(): return "电量不足"
		if t > 保险: return "超时"
		return ""
	var s := 起态((起["p"] as Vector3).x, (起["p"] as Vector3).z, float(起["psi"]))
	d.开始(s)
	var 轨: Array = []; var 下 := 0.0
	var 段表: Array = []; var 电0: float = 账.电量; var 倾0 := 0.0
	轨.append(轨点(s, d, 账))
	while not d.完:
		d.步(s, 步长)
		倾0 = maxf(倾0, d.倾角)
		var 到: int = d.段 if (d.完 and d.原因 == "到达") else d.段 - 1     # 已经到了几个航点（不算出发点）
		while 段表.size() < 到:
			段表.append({"到达_ltst": 开始分 + d.t/能源脚本.LTST分, "耗电_Wh": 电0 - float(账.电量), "最大倾角": 倾0})
			电0 = 账.电量; 倾0 = 0.0
		if d.t >= 下:
			轨.append(轨点(s, d, 账)); 下 += 采样
	轨.append(轨点(s, d, 账))
	var 事: Array = []
	for e: Dictionary in d.事件: 事.append({"类": e["类"], "E": e["x"], "N": -float(e["z"]), "t_s": e["t"], "值": e["值"]})
	var p: Vector3 = s["p"]
	return {"轨迹": 轨, "事件": 事, "段": 段表, "停因": d.原因, "到达": d.原因 == "到达", "用时_s": d.t, "里程_m": d.里程,
		"最大倾角": d.最大倾角, "终": {"E": p.x, "N": -p.z, "psi": float(s["psi"])}, "偏_m": (d.偏 as Vector2).length(),
		"结束_ltst": 开始分 + d.t/能源脚本.LTST分, "账": 账.表()}


func 轨点(s: Dictionary, d: RefCounted, 账: RefCounted) -> Array:
	var p: Vector3 = s["p"]
	return [p.x, -p.z, d.t, d.倾角, 账.电量, float(s["psi"]), d.风险]


func 存() -> Dictionary:
	var a: Array = []; for e: Vector2 in 航点: a.append([e.x, e.y])
	var z: Array = []; for q: Vector3 in 禁: z.append([q.x, q.y, q.z])
	return {"航点": a, "方式": 方式.duplicate(), "禁行": z}


func 读(j: Dictionary) -> void:
	航点.clear(); 方式.clear(); 禁.clear()
	for e in j.get("航点", []): 航点.append(Vector2(float(e[0]), float(e[1])))
	for m in j.get("方式", []): 方式.append(int(m))
	for q in j.get("禁行", []): 禁.append(Vector3(float(q[0]), float(q[1]), float(q[2])))
	while 方式.size() < 段数(): 方式.append(1)
	方式.resize(段数())
