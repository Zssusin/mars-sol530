"""
火星大气（2100 年）—— 物理大气散射，纯 numpy，Blender 自带的 Python 也能跑。

做法照 Bruneton 2008 / Hillaire 2020（UE4 Sky Atmosphere）：
1. 透射率查找表 T(h, μ)：从高度 h 沿天顶角余弦 μ 一直到大气顶的透射率（撞到地面＝0）。
2. 多次散射查找表 Ψ(h, μs)：Hillaire 的近似：二阶散射 × 1/(1 − f_ms)，各向同性，补上单次散射漏掉的那部分天光。
3. 每条视线按段积分单次散射（瑞利 + 尘埃米氏）+ Ψ，段内用解析积分（能量守恒），得到 内散射 L 与 视线透射率 T。
地面颜色 = 地表辐亮度 × T + L；天空 = L + 太阳盘 × T。

长度单位 km，太阳照度 E0 = 1（白），绝对亮度留给后期曝光。
2100 年参数（正典：0.4 atm，CO₂ 为主，天顶比地球蓝，近地平线杏色尘霾；数值为推定）：
- 瑞利：光学厚度取地球的 1.56 倍（与 41_体素第一人称 一致），标高 12 km（CO₂、约 260 K、g = 3.71）。
  基准面（MOLA 0 m）上 0.4 atm；峡谷底 −5 km 处约 0.6 atm，所以谷底的霾更重。
- 尘埃：τ = 0.05、标高 10 km（雨后晴天；尘多了谷底 60 km 外就看不见了。现在的火星 τ ≈ 0.5）；单次散射反照率 R/G/B = 0.97 / 0.91 / 0.78（尘吸蓝，杏色就是这么来的）；
  相函数双 Henyey-Greenstein（前向 g = 0.72 占 90%，后向 −0.25）。
通道：R≈650 nm，G≈550 nm，B≈450 nm，线性 Rec.709。
"""
import math
import numpy as np

R  = 3396.2                     # 火星平均半径（km），MOLA 基准面
RB = R - 12.0                   # 「地面」球：低于它的视线算撞地（希腊盆地才 −8 km）
RT = R + 140.0                  # 大气顶

EARTH_TAU_R = np.array([0.0464, 0.1085, 0.2650])     # 地球瑞利光学厚度（680 / 550 / 440 nm）
HR = 12.0
TAU_R = 1.56*EARTH_TAU_R
BETA_R = TAU_R/HR                                    # 基准面瑞利散射系数（/km）
HM = 10.0
TAU_M = 0.05
BETA_ME = np.full(3, TAU_M/HM)                       # 尘埃消光（/km），中性
SSA_M = np.array([0.97, 0.91, 0.78])
BETA_MS = BETA_ME*SSA_M                              # 尘埃散射
G_FWD, G_BACK, W_FWD = 0.72, -0.25, 0.90             # 旧常量；今天() 会把它们重设成数组/标量（见 今天）
GROUND_ALBEDO = np.array([0.20, 0.12, 0.08])         # 多次散射里地面反射用的平均反照率（尘 + 砂 + 水）

SUN_RADIUS = math.radians(0.35/2)                    # 1.524 AU 处太阳视半径


PHASE_FULL = None                                        # 表的原样（过渡用，见 set_phase_blend）
PHASE_TAB = None                                         # None＝双 HG（g_fwd 等）；否则 (theta[rad], P[3, n])：逐通道查表的尘埃相函数（Mie，见 scripts/Godot/94_尘埃Mie相函数.py、docs/全日天空.md §4）

SHADOW_H = None                                          # None＝旧做法（星球阴影就是 RB 那个球，08:00–17:00 的老天空这么算的）；给数（km）＝日落以后用：太阳光被「高度 SHADOW_H 的地面球」挡住

def 今天(tau=0.67, p_hpa=7.6, h_site_km=-2.52, ssa=(0.975, 0.94, 0.85), g_fwd=None, w_fwd=None, g_back=None, shadow_h=None, phase_table=None, hm_km=None):
    """切到今天的真实火星（在 Atmosphere() 之前调用）。默认＝毅力号 sol 530（Ls 287，耶泽罗 −2.5 km）：
    τ 0.67 为 Mastcam-Z 太阳像实测（Lemmon 等，sol 528 中午 0.68、sol 531 中午 0.65）；地面气压 ≈ 7.6 hPa（MEDA 南半球夏季）；
    CO₂ 约 210 K → 标高 10.8 km；尘单次散射反照率按 Wolff 等 2009 / Lemmon 量级（尘吸蓝）。
    tau 是本地（h_site）的柱光学厚度，可给三通道 (R, G, B)；换算到基准面再存。
    g_fwd / w_fwd / g_back：尘埃相函数（双 HG）逐通道 (R, G, B)，None＝老的三通道同一个值（G_FWD 等模块常量）；
    hm_km：尘埃标高（km），None＝同气体 10.8（尘气混合比不随高度变）；实验用。
    phase_table：尘埃相函数表（.npz 路径，theta[°]、P[3, n] 单位 sr⁻¹ 且 ∫P dΩ = 1，逐通道 R/G/B）；给了就替代双 HG（g_fwd 等被忽略）；
    shadow_h：日落后太阳被地面球挡住的半径（km，一般取站点高度）；None＝老做法。后两项只在新增时刻（低太阳、暮光）用，见 docs/全日天空.md。"""
    global HR, HM, TAU_R, BETA_R, TAU_M, BETA_ME, SSA_M, BETA_MS, G_FWD, W_FWD, G_BACK, SHADOW_H, PHASE_TAB, PHASE_FULL
    PHASE_TAB = PHASE_FULL = None
    if phase_table is not None:
        z = np.load(phase_table); PHASE_TAB = PHASE_FULL = (np.radians(z['theta']).astype(float), np.asarray(z['P'], float))
    G_FWD, W_FWD, G_BACK = ((np.asarray(v, float) if v is not None else d) for v, d in ((g_fwd, 0.72), (w_fwd, 0.90), (g_back, -0.25)))
    SHADOW_H = shadow_h
    HR = HM = 10.8
    if hm_km is not None: HM = hm_km                                  # 实验用：尘埃标高与气体标高分开（默认同 10.8 km）
    TAU_R = 1.56*EARTH_TAU_R*(p_hpa/405.3)/math.exp(-h_site_km/HR)       # 2100 年的 1.56 倍地球对应 0.4 atm（405 hPa）
    BETA_R = TAU_R/HR
    TAU_M = np.broadcast_to(np.asarray(tau, float), (3,))/math.exp(-h_site_km/HM)
    BETA_ME = TAU_M/HM
    SSA_M = np.asarray(ssa, float); BETA_MS = BETA_ME*SSA_M


def set_phase_blend(b):
    """在 今天(phase_table=…) 之后用：尘埃相函数 = (1 − b)·双 HG + b·查表（b=1 全用表，b=0 就是老的双 HG，只是落在表的角度网格上）。
    表只进视线积分，不进 T、Ψ 表，所以逐时刻改 b 不用重建 Atmosphere。"""
    global PHASE_TAB
    if PHASE_FULL is None: return
    th, P = PHASE_FULL; c = np.cos(th)
    hg = np.moveaxis(np.broadcast_to(W_FWD*_hg(c[:, None], G_FWD) + (1 - W_FWD)*_hg(c[:, None], G_BACK), (len(c), 3)), -1, 0)
    PHASE_TAB = (th, (1 - b)*hg + b*P)


def density(h):
    """h（km，可为负）→（瑞利密度，尘埃密度），相对基准面。"""
    h = np.maximum(h, -12.0)
    return np.exp(-h/HR), np.exp(-h/HM)


def phase_r(c): return 3.0/(16*math.pi)*(1 + c*c)

def _hg(c, g): return (1 - g*g)/(4*math.pi*np.power(1 + g*g - 2*g*c, 1.5))

def phase_m(c):
    """c：(...) → (..., 1)（三通道同一个 g）或 (..., 3)（逐通道 g）。"""
    if PHASE_TAB is not None:                                   # 查表：按角度（前向峰窄，θ 比 cosθ 好插）
        th = np.arccos(np.clip(np.asarray(c, float), -1, 1))
        return np.stack([np.interp(th, PHASE_TAB[0], PHASE_TAB[1][k]) for k in range(3)], -1)
    c = np.asarray(c)[..., None]
    return W_FWD*_hg(c, G_FWD) + (1 - W_FWD)*_hg(c, G_BACK)


def sphere_hits(o, d, rad):
    """射线 o + t·d 与球 |x| = rad 的两个交点 t（没交到给 nan）。o, d：(..., 3)。"""
    b = np.sum(o*d, -1)
    c = np.sum(o*o, -1) - rad*rad
    disc = b*b - c
    s = np.sqrt(np.where(disc >= 0, disc, np.nan))
    return -b - s, -b + s


def ray_extent(o, d):
    """从 o 沿 d 走到大气顶或撞地：返回 (长度, 是否撞地)。"""
    _, t_top = sphere_hits(o, d, RT)
    t_top = np.nan_to_num(t_top, nan=0.0)
    g0, _ = sphere_hits(o, d, RB)
    ground = np.isfinite(g0) & (g0 > 0)
    return np.where(ground, g0, np.maximum(t_top, 0.0)), ground


# ── 透射率表 ─────────────────────────────────────────────────────
NH_T, NMU_T = 160, 512
H_MIN, H_MAX = -12.0, RT - R

def _h_of(i, n): return H_MIN + (H_MAX - H_MIN)*(np.asarray(i)/(n - 1))**2     # 低处格子密

def _i_of(h, n): return np.sqrt(np.clip((h - H_MIN)/(H_MAX - H_MIN), 0, 1))*(n - 1)


class Atmosphere:
    def __init__(self, steps=200, psi_nmu=32):
        """psi_nmu：Ψ 表的太阳高度档数。32（老天空）在地平线附近只有 3 档，暮光（太阳在地平线下）要 128。"""
        self._build_transmittance(steps)
        self._build_multiscatter(nmu=psi_nmu)

    # T(h, μ)
    def _build_transmittance(self, steps):
        h = _h_of(np.arange(NH_T), NH_T)
        mu = np.linspace(-1, 1, NMU_T)
        H, MU = np.meshgrid(h, mu, indexing="ij")
        r = R + H
        o = np.stack([np.zeros_like(r), np.zeros_like(r), r], -1)
        d = np.stack([np.sqrt(1 - MU*MU), np.zeros_like(MU), MU], -1)
        L, ground = ray_extent(o, d)
        if SHADOW_H is not None:                                         # 地面球挡光：射线撞到它，或从地下往下射
            g1, _ = sphere_hits(o, d, R + SHADOW_H)
            ground = ground | (np.isfinite(g1) & (g1 > 1e-6)) | ((H < SHADOW_H) & (MU < 0))
        tau = np.zeros(H.shape + (3,))
        for k in range(steps):
            t = L*(k + 0.5)/steps
            hh = np.sqrt(r*r + t*t + 2*r*t*MU) - R
            dr, dm = density(hh)
            tau += (BETA_R*dr[..., None] + BETA_ME*dm[..., None])*(L/steps)[..., None]
        T = np.exp(-tau)
        T[ground] = 0.0
        self.T_lut = T.astype(np.float32)

    def transmittance(self, h, mu):
        """双线性查 T(h, μ)，h、μ 同形状任意维 → (..., 3)。"""
        fi = _i_of(np.asarray(h, np.float64), NH_T)
        fj = (np.clip(mu, -1, 1) + 1)/2*(NMU_T - 1)
        i0 = np.clip(np.floor(fi).astype(int), 0, NH_T - 2); j0 = np.clip(np.floor(fj).astype(int), 0, NMU_T - 2)
        a = (fi - i0)[..., None]; b = (fj - j0)[..., None]
        T = self.T_lut
        return ((1 - a)*(1 - b)*T[i0, j0] + a*(1 - b)*T[i0 + 1, j0] + (1 - a)*b*T[i0, j0 + 1] + a*b*T[i0 + 1, j0 + 1])

    # Ψ(h, μs)：Hillaire 2020 的多次散射近似
    def _build_multiscatter(self, nh=32, nmu=32, ndir=64, steps=40):
        h = _h_of(np.arange(nh), nh)
        mus = np.linspace(-1, 1, nmu)
        k = np.arange(ndir) + 0.5                                         # Fibonacci 球面方向
        z = 1 - 2*k/ndir; phi = math.pi*(1 + 5**0.5)*k
        dirs = np.stack([np.sqrt(1 - z*z)*np.cos(phi), np.sqrt(1 - z*z)*np.sin(phi), z], -1)
        H, MU, _ = np.meshgrid(h, mus, np.arange(ndir), indexing="ij")
        r = R + H
        o = np.stack([np.zeros_like(r), np.zeros_like(r), r], -1)
        d = np.broadcast_to(dirs, H.shape + (3,))
        s = np.stack([np.sqrt(1 - MU*MU), np.zeros_like(MU), MU], -1)
        L, ground = ray_extent(o, d)
        Tv = np.ones(H.shape + (3,)); L2 = np.zeros_like(Tv); F = np.zeros_like(Tv)
        dt = (L/steps)[..., None]
        for i in range(steps):
            p = o + d*(L*(i + 0.5)/steps)[..., None]
            rp = np.linalg.norm(p, axis=-1)
            hp = rp - R
            dr, dm = density(hp)
            ss = BETA_R*dr[..., None] + BETA_MS*dm[..., None]
            se = BETA_R*dr[..., None] + BETA_ME*dm[..., None]
            Ts = self.transmittance(hp, np.sum(p*s, -1)/rp)
            seg = np.exp(-se*dt)
            integ = (1 - seg)/np.maximum(se, 1e-9)                         # ∫ T dt 段内解析
            L2 += Tv*ss*Ts/(4*math.pi)*integ
            F += Tv*ss*integ                                               # f_ms：不带相函数（Hillaire 2020 式 7）
            Tv *= seg
        # 撞地：地面朗伯反射
        pg = o + d*L[..., None]
        rg = np.linalg.norm(pg, axis=-1)
        mug = np.sum(pg*s, -1)/rg
        Tg = self.transmittance(rg - R, mug)
        L2 += np.where(ground[..., None], Tv*Tg*np.maximum(mug, 0)[..., None]*GROUND_ALBEDO/math.pi, 0)
        L2 = L2.mean(2); F = F.mean(2)                                    # 对方向取平均＝∫ (1/4π) dω
        self.psi = (L2/(1 - F)).astype(np.float32)
        self._ms_n = (nh, nmu)

    def multiscatter(self, h, mus):
        nh, nmu = self._ms_n
        fi = _i_of(np.asarray(h, np.float64), nh)
        fj = (np.clip(mus, -1, 1) + 1)/2*(nmu - 1)
        i0 = np.clip(np.floor(fi).astype(int), 0, nh - 2); j0 = np.clip(np.floor(fj).astype(int), 0, nmu - 2)
        a = (fi - i0)[..., None]; b = (fj - j0)[..., None]
        P = self.psi
        return ((1 - a)*(1 - b)*P[i0, j0] + a*(1 - b)*P[i0 + 1, j0] + (1 - a)*b*P[i0, j0 + 1] + a*b*P[i0 + 1, j0 + 1])

    # ── 视线积分 ─────────────────────────────────────────────────
    def integrate(self, o, d, tmax, sun, steps=48, chunk=262144):
        """o：射线起点（相对火星中心，km），d：单位方向，tmax：到地物的距离（天空给 inf）。
        返回（内散射 L，视线透射率 T），都是 (N, 3)。"""
        o = np.asarray(o, np.float64).reshape(-1, 3); d = np.asarray(d, np.float64).reshape(-1, 3)
        tmax = np.broadcast_to(np.asarray(tmax, np.float64), (len(d),))
        if o.shape[0] == 1: o = np.broadcast_to(o, d.shape)
        sun = np.asarray(sun, np.float64)
        Lout = np.zeros((len(d), 3), np.float32); Tout = np.ones((len(d), 3), np.float32)
        for a in range(0, len(d), chunk):
            oo, dd, tm = o[a:a + chunk], d[a:a + chunk], tmax[a:a + chunk]
            # 先进大气：相机在大气外时从大气顶开始
            t_in, t_out = sphere_hits(oo, dd, RT)
            inside = np.linalg.norm(oo, axis=-1) < RT
            t0 = np.where(inside, 0.0, np.nan_to_num(t_in, nan=0.0))
            ext, _ = ray_extent(oo, dd)
            t1 = np.where(inside, ext, np.nan_to_num(t_out, nan=0.0))
            g0, _ = sphere_hits(oo, dd, RB)
            t1 = np.where(np.isfinite(g0) & (g0 > 0), np.minimum(t1, g0), t1)
            t1 = np.minimum(t1, tm)
            span = np.maximum(t1 - t0, 0)
            cth = dd @ sun
            pr, pm = phase_r(cth)[:, None], phase_m(cth)
            L = np.zeros((len(dd), 3)); T = np.ones((len(dd), 3))
            prev = np.zeros(len(dd))
            for i in range(steps):                                       # 平方分布：近处步子小
                u = ((i + 1)/steps)**2
                tc = span*u
                dt = (tc - prev)[:, None]
                tmid = t0 + (prev + tc)/2
                prev = tc
                p = oo + dd*tmid[:, None]
                rp = np.linalg.norm(p, axis=-1)
                hp = rp - R
                dr, dm = density(hp)
                sr = BETA_R*dr[:, None]; sm = BETA_MS*dm[:, None]
                se = sr + BETA_ME*dm[:, None]
                mus = (p @ sun)/rp
                Ts = self.transmittance(hp, mus)
                S = (sr*pr + sm*pm)*Ts + (sr + sm)*self.multiscatter(hp, mus)
                seg = np.exp(-se*dt)
                L += T*S*(1 - seg)/np.maximum(se, 1e-9)
                T *= seg
            Lout[a:a + chunk] = L; Tout[a:a + chunk] = T
        return Lout, Tout

    def sun_disc(self, d, sun):
        """太阳盘辐亮度（E0 = 1），带临边昏暗；d：(N, 3)。"""
        c = np.clip(d @ np.asarray(sun), -1, 1)
        ang = np.arccos(c)
        x = np.clip(ang/SUN_RADIUS, 0, 1)
        limb = 1 - 0.6*(1 - np.sqrt(1 - x*x))
        rad = 1/(math.pi*SUN_RADIUS**2)/0.8                                # 0.8：临边昏暗的盘面平均
        return np.where((ang < SUN_RADIUS)[:, None], (rad*limb)[:, None]*np.ones(3), 0.0)


def env_map(atm, origin, sun, w=512, h=256, ground_albedo=0.15):
    """给 Blender 世界用的等距圆柱天空图（Blender 的方向约定，第 0 行在下），不含太阳盘。
    地平线以下给一块均匀的朗伯地面。"""
    v = (np.arange(h) + 0.5)/h; u = (np.arange(w) + 0.5)/w
    U, V = np.meshgrid(u, v)
    th = (V - 0.5)*math.pi; ph = -(U - 0.5)*2*math.pi
    d = np.stack([np.cos(th)*np.cos(ph), np.cos(th)*np.sin(ph), np.sin(th)], -1).reshape(-1, 3)
    up = origin/np.linalg.norm(origin)
    L, _ = atm.integrate(origin, d, np.inf, sun, steps=64)
    L = L.reshape(h, w, 3)
    # 地面：太阳直射 + 天光（上半球余弦加权）
    hz = float(np.linalg.norm(origin) - R)
    mus = float(up @ sun)
    E_sun = atm.transmittance(np.array([hz]), np.array([mus]))[0]*max(mus, 0)
    dz = (d @ up).reshape(h, w)
    dw = (math.pi/h)*(2*math.pi/w)*np.cos(th)
    E_sky = np.sum(L*(np.maximum(dz, 0)*dw)[..., None], (0, 1))
    Lg = ground_albedo/math.pi*(E_sun + E_sky)
    L = np.where((dz < 0)[..., None], Lg, L)
    return L.astype(np.float32), E_sun, E_sky


if __name__ == "__main__":                                              # 自检：天顶 / 地平线颜色
    import time
    t0 = time.time(); A = Atmosphere(); print(f"查找表 {time.time() - t0:.1f} s")
    o = np.array([0, 0, R + 0.0])
    for el in (90, 45, 20, 10, 5, 2, 0.5):
        sun = np.array([math.cos(math.radians(el)), 0, math.sin(math.radians(el))])
        for name, dv in (("天顶", [0, 0, 1]), ("背日地平", [-1, 0, 0.02]), ("向日地平", [1, 0, 0.02])):
            dv = np.array(dv, float); dv /= np.linalg.norm(dv)
            L, T = A.integrate(o, dv[None], np.inf, sun)
            print(f"太阳 {el:4}° {name}：L = {np.round(L[0], 4)}")
        print("   日照 T =", np.round(A.transmittance(np.array([0.0]), np.array([math.sin(math.radians(el))]))[0], 3))
