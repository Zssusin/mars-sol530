"""E(2)：太阳在低仰角时的直射透射率，手算（球面几何、指数密度、逐段积分，和 T 查找表无关的独立写法）对 T 查找表；再看 Mastcam 饱和下限。
τ 取 站点：尘 0.67/(…) 的天顶光学厚度（今天() 默认）+ 瑞利；密度标高 10.8 km，站点 −2.52 km。"""
import sys, math, pathlib, numpy as np
WT = pathlib.Path("/home/user/Documents/mars-work/地图_全日"); sys.path.insert(0, str(WT/"scripts/Blender")); import 火星大气 as AT
AT.今天(); atm = AT.Atmosphere(psi_nmu=32); R = AT.R; hs = -2.52
def tau_slant(el, n=400000, top=120.0):
    mu = math.sin(math.radians(el)); r0 = R + hs
    # 沿射线 t（km）走到 top 高度；用细均匀步长，中点积分
    b = r0*mu; tmax = -b + math.sqrt(b*b + (R + top)**2 - r0*r0)
    t = (np.arange(n) + 0.5)/n*tmax; r = np.sqrt(r0*r0 + 2*b*t + t*t); h = r - R
    dr, dm = AT.density(h); dt = tmax/n
    return (AT.BETA_R[None, :]*dr[:, None] + AT.BETA_ME[None, :]*dm[:, None]).sum(0)*dt
print("天顶光学厚度（站点，R/G/B）：", np.round(AT.BETA_R*AT.HR*math.exp(-hs/AT.HR) + AT.BETA_ME*AT.HM*math.exp(-hs/AT.HM), 3))
print("太阳高 | 手算 τ 斜（G）| 空气质量 τ斜/τ天顶 | 手算 T（R G B）| 查找表 T（R G B）| 比")
for el in (10, 5.5, 3.87, 2.71, 2, 1, 0.5, 0.0):
    ts = tau_slant(el); T = np.exp(-ts); Tl = atm.transmittance(np.array([hs]), np.array([math.sin(math.radians(el))]))[0]
    z = AT.BETA_R*AT.HR*math.exp(-hs/AT.HR) + AT.BETA_ME*AT.HM*math.exp(-hs/AT.HM)
    print(f"{el:5.2f}° | {ts[1]:7.2f} | {ts[1]/z[1]:5.1f} | " + " ".join(f"{v:.3g}" for v in T) + " | " + " ".join(f"{v:.3g}" for v in Tl) + " | " + " ".join(f"{a/b:.3f}" for a, b in zip(Tl, T)))
# 太阳盘 vs 周围天光：直射辐亮度 = T/(π r²) ；天光（太阳 el 处，α=3° 的模型辐亮度）
r = AT.SUN_RADIUS
for el in (5.47, 2.0, 1.0):
    s = np.array([math.cos(math.radians(el)), 0, math.sin(math.radians(el))]); o = np.array([0, 0, R + hs]); e2 = math.radians(el + 3)
    L, _ = atm.integrate(o, np.array([[math.cos(e2), 0, math.sin(e2)]]), np.inf, s, steps=64)
    T = atm.transmittance(np.array([hs]), np.array([s[2]]))[0]
    print(f"太阳高 {el}°：太阳盘辐亮度 {T[1]/(math.pi*r*r):.3g}（E0=1，绿）；离太阳 3° 的天光（老模型）{L[0, 1]:.3g}；比 {T[1]/(math.pi*r*r)/L[0, 1]:.2g}")
# Mastcam sol 956：太阳盘 I/F ＝ π L_盘 / E0 ＝ T/r² 。饱和 DN≈1900 × SF
for el, sf in ((3.87, 8.668e-4), (3.23, 6.26e-4), (2.71, 4.173e-4)):
    need = 1900*sf; print(f"Mastcam 绿通道饱和需 I/F ≥ {need:.2f} → 太阳盘 I/F = T/r² → T ≥ {need*r*r:.2e}")
