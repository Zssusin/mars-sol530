"""
天气天空的多次散射定标（61 --天气天空 调用）。
问题：火星大气.py 的多次散射是 Hillaire 2020 的各向同性近似（二阶散射 × 1/(1 − f_ms)）。拿平面平行蒙特卡洛（蒙特卡洛.py，
同一套 τ、相函数、单次散射反照率、地面反照率）当参照，13:07 地面漫射通量 模型 / 参照 ＝ τ 0.67：1.14，τ 5：0.27（见 说明.md）——
尘埃强前向散射，高阶散射的光大多继续往下走，各向同性近似在厚尘里把漫射天光低估好几倍。
做法：天空 = 单次散射（模型原样，含太阳附近的晕）+ k·多次散射项 Ψ，k 按通道、按时刻定：
    让 地面漫射通量(τ) = 模型(τ 0.67) × 参照(τ) / 参照(τ 0.67)
即以已对真照片校过的 τ 0.67 天空为锚，τ 的变化趋势取参照解。τ 0.67 本身 k ≡ 1（不动现有天空）。
"""
import math, sys, pathlib
import numpy as np
HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parents[1]/"scripts"/"Blender"))
import 火星大气 as AT
import 蒙特卡洛 as MC

TAU0 = 0.67
_mc_cache = {}


def mc_diffuse(tau, mu0, n=400_000):
    """参照解：地面向下漫射通量 / (μ0·E0)，三通道。"""
    key = (round(tau, 4), round(mu0, 4))
    if key not in _mc_cache:
        saved = (AT.HR, AT.HM, AT.TAU_R, AT.BETA_R, AT.TAU_M, AT.BETA_ME, AT.SSA_M, AT.BETA_MS)
        tr, tm, ssa = MC.site_taus(tau)
        AT.HR, AT.HM, AT.TAU_R, AT.BETA_R, AT.TAU_M, AT.BETA_ME, AT.SSA_M, AT.BETA_MS = saved   # 恢复当前 τ 的全局量
        d = []
        for c in range(3):
            E, Ed, _ = MC.run(tr[c], tm[c], ssa[c], AT.GROUND_ALBEDO[c], mu0, n=n, seed=17 + c)
            d.append(E - Ed)
        _mc_cache[key] = np.array(d)
    return _mc_cache[key]


def e_sky(atm, o, s, psi=None):
    """低分辨率天空图上积出的地面漫射照度（E0 = 1），三通道。psi 给定时临时替换多次散射表。"""
    keep = atm.psi
    if psi is not None: atm.psi = psi
    _, _, E = AT.env_map(atm, o, s, w=256, h=128, ground_albedo=0.22)
    atm.psi = keep
    return np.asarray(E, float)


def calibrate(atm, E0_sky, o, s, tau):
    """atm：当前 τ 的 Atmosphere（全局量已是这个 τ）；E0_sky：τ 0.67 模型在同一时刻的地面漫射照度（三通道）。
    返回 k（三通道）与目标漫射照度。"""
    mu0 = float(s[2])
    if mu0 <= 0.02: return np.ones(3), None
    target = E0_sky*mc_diffuse(tau, mu0)/mc_diffuse(TAU0, mu0)
    E_ss = e_sky(atm, o, s, psi=np.zeros_like(atm.psi))
    E_all = e_sky(atm, o, s)
    k = (target - E_ss)/np.maximum(E_all - E_ss, 1e-9)
    return np.clip(k, 0.0, 50.0), target


if __name__ == "__main__":                                             # 自检：13:07 各 τ 的 k
    o = np.array([0, 0, AT.R - 2.52])
    el = math.radians(44.478); s = np.array([math.cos(el), 0.0, math.sin(el)])
    AT.今天(tau=TAU0); A0 = AT.Atmosphere(); E0 = e_sky(A0, o, s)
    print("τ 0.67 模型漫射", E0, "参照", mc_diffuse(TAU0, s[2]), flush=True)
    for tau in [float(x) for x in sys.argv[1:]] or [0.3, 1.5, 3, 5]:
        AT.今天(tau=tau); A = AT.Atmosphere()
        k, tg = calibrate(A, E0, o, s, tau)
        print(f"τ {tau}: 模型漫射 {e_sky(A, o, s)}  目标 {tg}  k {k}", flush=True)
