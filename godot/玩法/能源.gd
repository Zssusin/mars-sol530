# 能量模型和账（docs/玩法B.md §4.3）：MMRTG + 两块电池的简化模型，账目守恒（期末 = 期初 + 发电 − 日常负载 − 驾驶负载 − 弃电）。
#   ✔ 有出处的：MMRTG 起始约 110 W、每年衰减几个百分点；两块电池各约 43 Ah（JPL 发射资料 Power）；车 1025 kg（NASA Rover Components）。
#   其余都是游戏设定（常量旁注明）。时间单位：秒（地球秒）；1 火星日 = 88 775.244 s。
extends RefCounted

const SOL_S := 88775.244                      # 火星日（s）✔ Mars24
const LTST分 := SOL_S/1440.0                  # 1 LTST 分钟 = 61.65 s
const 年_S := 31557600.0                      # 儒略年（s）
const 容量 := 2.0*43.0*28.0                   # Wh：2 块 × 43 Ah ✔ × 28 V（28 V 母线是游戏设定）= 2408 Wh
const 起始比 := 0.80                           # 游戏设定
const 下限比 := 0.30                           # 游戏设定：低于就停车（电量不足）
const P0 := 110.0                              # W ✔ 起始发电
const 衰减 := 0.035                            # 每年（游戏设定；出处只说「a few percent each year」）
const 日常 := 85.0                             # W，全天（游戏设定：航电、加热、通信的日均）
const 驾基 := 90.0                             # W，驾驶时（游戏设定：电机驱动器、转向、相机）
const 方式附加 := [0.0, 10.0, 25.0]            # W：盲开、视觉里程计、AutoNav（游戏设定）
const 质量 := 1025.0                           # kg ✔
const 重力 := 3.71                             # m/s²
const C_rr := 0.15                             # 滚动阻力系数（游戏设定）
const C_转 := 0.30                             # 原地转的擦地系数（游戏设定）
const 效率 := 0.35                             # 电到轮的效率（游戏设定）
const 转臂 := 1.2                              # 原地转时轮子到转心的平均距离 m（按轮位，约）

var sol := 531                                 # 发电按 sol 衰减
var 电量 := 容量*起始比                         # Wh
var 期初 := 0.0
var 发电 := 0.0                                 # Wh（本账期累计）
var 日常用 := 0.0
var 驾驶用 := 0.0
var 弃电 := 0.0
var 驾驶秒 := 0.0


func _init(sol_ := 531, 电量_ := -1.0) -> void:
	sol = sol_
	if 电量_ >= 0.0: 电量 = 电量_
	开账()


func 开账() -> void:
	期初 = 电量; 发电 = 0.0; 日常用 = 0.0; 驾驶用 = 0.0; 弃电 = 0.0; 驾驶秒 = 0.0


func 复制() -> RefCounted:
	var e: RefCounted = get_script().new(sol, 电量)
	return e


static func 发电功率(sol_: int) -> float:
	"""MMRTG：起始 110 W，按着陆后的年数衰减（sol × 88 775 s / 儒略年）。"""
	return P0*pow(1.0 - 衰减, sol_*SOL_S/年_S)


static func 驾驶功率(v: float, θ: float, 方式: int, w: float) -> float:
	"""驾驶附加负载（W）：基线 + 方式附加 + 地面阻力和爬坡 / 效率（下坡不回收，取 ≥ 0）；原地转按轮子划过的弧长 w·转臂 算擦地。"""
	var 机械 := 质量*重力*(C_rr*cos(θ) + sin(θ))*v + 质量*重力*C_转*w*转臂
	return 驾基 + 方式附加[clampi(方式, 0, 2)] + maxf(0.0, 机械)/效率


func 过(h: float) -> void:
	"""过 h 秒：发电和日常负载（驾驶负载另记）。电池满了多出来的记弃电。"""
	var g := 发电功率(sol)*h/3600.0; var b := 日常*h/3600.0
	发电 += g; 日常用 += b
	电量 += g - b
	if 电量 > 容量: 弃电 += 电量 - 容量; 电量 = 容量


func 驾驶(h: float, v: float, θ: float, 方式: int, w: float) -> void:
	var e := 驾驶功率(v, θ, 方式, w)*h/3600.0
	驾驶用 += e; 驾驶秒 += h; 电量 -= e


func 不足() -> bool:
	return 电量 < 容量*下限比


func 差() -> float:
	"""账目误差（应 ≈ 0）：期末 − (期初 + 发电 − 日常 − 驾驶 − 弃电)。"""
	return 电量 - (期初 + 发电 - 日常用 - 驾驶用 - 弃电)


func 表() -> Dictionary:
	return {"期初_Wh": 期初, "期末_Wh": 电量, "发电_Wh": 发电, "日常_Wh": 日常用, "驾驶_Wh": 驾驶用, "弃电_Wh": 弃电, "误差_Wh": 差(), "驾驶_s": 驾驶秒}
