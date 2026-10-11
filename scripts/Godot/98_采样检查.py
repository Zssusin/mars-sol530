"""采样检查：Mie 相函数的前向峰有多窄、视线积分步数和 1024×512 等距圆柱天空图（0.352°/格）在太阳附近够不够。太阳高 2°、Perseverance 站点。"""
import sys, math, pathlib, numpy as np
WT = pathlib.Path("/home/user/Documents/mars-work/地图_全日"); sys.path.insert(0, str(WT/"scripts/Blender")); import 火星大气 as AT
PZ = str(WT/"scripts/Godot/尘埃相函数_Mie_r1.5.npz")
AT.今天(phase_table=PZ, shadow_h=-2.52); atm = AT.Atmosphere(psi_nmu=128)
EL = 2.0; s = np.array([math.cos(math.radians(EL)), 0, math.sin(math.radians(EL))]); o = np.array([0, 0, AT.R - 2.52])
def dirs(az, el): e, a = np.radians(el), np.radians(az); return np.stack([np.cos(e)*np.cos(a), np.cos(e)*np.sin(a), np.sin(e)], -1)
# 1) 步数：太阳上方 α 度、同方位
al = np.array([0.3, 0.6, 1, 2, 4, 8]); D = dirs(0, EL + al)
L = {n: atm.integrate(o, D, np.inf, s, steps=n)[0] for n in (48, 64, 192)}
print("步数 48/64 对 192 的最大相对差（三通道）：", [float(np.max(abs(L[n]/L[192] - 1))) for n in (48, 64)])
# 2) 等距圆柱图 1024×512：把天空图格点的值双线性插到任意方向，对比直接积分
W, H = 1024, 512; dth = 360/W
az0 = np.arange(-6, 6.001, dth); el0 = EL + np.arange(-6, 6.001, 180/H)
AZ, EL_ = np.meshgrid(az0, el0); G = atm.integrate(o, dirs(AZ, EL_).reshape(-1, 3), np.inf, s, steps=64)[0].reshape(AZ.shape + (3,))
rng = np.random.default_rng(0); az = rng.uniform(-3, 3, 300); el = EL + rng.uniform(-3, 3, 300)
fa = (az - az0[0])/dth; fe = (el - el0[0])/(180/H); i0 = np.floor(fa).astype(int); j0 = np.floor(fe).astype(int); u = (fa - i0)[:, None]; v = (fe - j0)[:, None]
bi = (1 - u)*(1 - v)*G[j0, i0] + u*(1 - v)*G[j0, i0 + 1] + (1 - u)*v*G[j0 + 1, i0] + u*v*G[j0 + 1, i0 + 1]
dr = atm.integrate(o, dirs(az, el), np.inf, s, steps=64)[0]
ang = np.degrees(np.arccos(np.clip(dirs(az, el) @ s, -1, 1)))
for a0, a1 in ((0, 0.5), (0.5, 1), (1, 2), (2, 4)):
    m = (ang >= a0) & (ang < a1)
    if m.sum(): print(f"离太阳 {a0}–{a1}°：{int(m.sum())} 点，天空图双线性 / 直接积分 − 1：最大 {np.max(abs(bi[m]/dr[m] - 1)):.3%}，均值 {np.mean(abs(bi[m]/dr[m] - 1)):.3%}")
th, P = AT.PHASE_TAB; i = lambda a: np.argmin(abs(np.degrees(th) - a))
print("P_G(θ)：0°", P[1][i(0)], " 1°", P[1][i(1)], " 3°", P[1][i(3)], " 半高宽（P 降到 P(0) 一半的角）≈", np.degrees(th[np.argmax(P[1] < P[1][0]/2)]), "°")
