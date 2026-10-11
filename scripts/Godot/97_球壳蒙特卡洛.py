"""球壳蒙特卡洛（反向路径追踪 + 逐顶点向太阳的 next-event 估计，Woodcock 零碰撞）：检验 火星大气.py 的「单次散射 + 各向同性 Ψ」在尘埃前向峰很窄时漏了多少。
同一个大气（今天() 的设置、同一张尘埃相函数表），球形行星，观察者在站点高度，几何同 integrate()。逐通道算（三个通道各一遍）。
用法：97_球壳蒙特卡洛.py <太阳高°> <变体 老|Mie|Mie全套> [光子数] [标高km]
"""
import sys, math, json, pathlib, numpy as np
WT = pathlib.Path("/home/user/Documents/mars-work/地图_全日"); sys.path.insert(0, str(WT/"scripts/Blender")); import 火星大气 as AT
EL = float(sys.argv[1]); VAR = sys.argv[2]; N = int(float(sys.argv[3])) if len(sys.argv) > 3 else 200000; HMK = float(sys.argv[4]) if len(sys.argv) > 4 else None
H_SITE = -4.4; TAU550 = 0.75
PZ = pathlib.Path.home()/"样张临时/全日2/mastcam/mastcam_phase.npz"
res = json.loads(str(np.load(PZ)["res"]))
kw = dict(tau=TAU550, p_hpa=9.0, h_site_km=H_SITE, shadow_h=H_SITE, hm_km=HMK)
if VAR != "老": kw["phase_table"] = str(PZ)
if VAR == "Mie全套": kw["ssa"] = tuple(res[n]["omega0"] for n in "RGB")
AT.今天(**kw); atm = AT.Atmosphere(psi_nmu=128)
rng = np.random.default_rng(1)
s = np.array([math.cos(math.radians(EL)), 0, math.sin(math.radians(EL))]); o = np.array([0, 0, AT.R + H_SITE])
RG = AT.R + H_SITE
def basis(d):
    a = np.where(abs(d[:, 2:3]) < 0.9, np.array([[0, 0, 1.0]]), np.array([[1.0, 0, 0]])); u = np.cross(d, a); u /= np.linalg.norm(u, axis=1, keepdims=True); return u, np.cross(d, u)
def rotate(d, ct, ph):
    u, v = basis(d); st = np.sqrt(np.maximum(1 - ct*ct, 0)); return d*ct[:, None] + (u*np.cos(ph)[:, None] + v*np.sin(ph)[:, None])*st[:, None]
def sample_dust(c, n):
    th, P = AT.PHASE_TAB; pdf = P[c]*np.sin(th); cdf = np.concatenate([[0], np.cumsum(0.5*(pdf[1:] + pdf[:-1])*np.diff(th))]); cdf /= cdf[-1]
    return np.cos(np.interp(rng.random(n), cdf, th))
def sample_ray(n):                                           # (1+μ²) 分布：拒绝采样
    out = np.empty(0)
    while out.size < n:
        m = rng.uniform(-1, 1, 2*n); k = rng.random(2*n)*2 < (1 + m*m); out = np.concatenate([out, m[k]])
    return out[:n]
def mc(d0, c, single=False):
    """方向 d0、通道 c 的辐亮度（E0=1）。"""
    betaR = AT.BETA_R[c]; betaE = np.broadcast_to(AT.BETA_ME, (3,))[c]; betaS = np.broadcast_to(AT.BETA_MS, (3,))[c]; alb = AT.GROUND_ALBEDO[c]
    sM = betaR + betaE                                       # 主导消光（海拔最低处，h=0 基准面密度＝1；站点在 −4.4 km 密度更大）
    sM = (betaR + betaE)*np.exp(-H_SITE/min(AT.HR, AT.HM)) * 1.0
    p = np.tile(o, (N, 1)); d = np.tile(d0, (N, 1)); w = np.ones(N); L = np.zeros(N); alive = np.ones(N, bool); order = np.zeros(N, int)
    for it in range(4000):
        idx = np.nonzero(alive)[0]
        if idx.size == 0: break
        pp, dd = p[idx], d[idx]
        t = -np.log(rng.random(idx.size))/sM
        tg, _ = AT.sphere_hits(pp, dd, RG); hitg = np.isfinite(tg) & (tg > 1e-9) & (tg < t)
        pn = pp + dd*np.where(hitg, tg, t)[:, None]; r = np.linalg.norm(pn, axis=1); h = r - AT.R
        out = (r > AT.RT) & ~hitg
        alive[idx[out]] = False
        # 地面
        gi = idx[hitg]
        if gi.size:
            ph_ = pn[hitg]; n_ = ph_/np.linalg.norm(ph_, axis=1, keepdims=True); mu = n_ @ s
            T = atm.transmittance(np.full(gi.size, RG - AT.R), mu)[:, c]
            L[gi] += w[gi]*alb/math.pi*np.maximum(mu, 0)*T
            if single or order[gi].max(initial=0) >= 0 and single: alive[gi] = False
            else:
                ct = np.sqrt(rng.random(gi.size)); ph = rng.random(gi.size)*2*math.pi; dn = rotate(n_, ct, ph)
                p[gi] = ph_ + n_*1e-6; d[gi] = dn; w[gi] *= alb; order[gi] += 1
        # 介质碰撞（真 / 零）
        rest = ~hitg & ~out
        ri = idx[rest]
        if ri.size:
            hh = h[rest]; dr, dm = AT.density(hh)
            se = betaR*dr + betaE*dm; real = rng.random(ri.size) < se/sM
            p[ri] = pn[rest]
            ci = ri[real]
            if ci.size:
                hc = hh[real]; drc, dmc = dr[real], dm[real]; sr = betaR*drc; sm = betaS*dmc; sec = betaR*drc + betaE*dmc
                pc = p[ci]; dc = d[ci]; mus = (pc @ s)/np.linalg.norm(pc, axis=1); Ts = atm.transmittance(hc, mus)[:, c]
                cth = dc @ s; pr = AT.phase_r(cth); pm = np.broadcast_to(AT.phase_m(cth), (len(cth), 3))[:, c]
                L[ci] += w[ci]*(sr*pr + sm*pm)/sec*Ts
                if single: alive[ci] = False
                else:
                    w[ci] *= (sr + sm)/sec; order[ci] += 1
                    isd = rng.random(ci.size) < sm/np.maximum(sr + sm, 1e-30)
                    ct = np.where(isd, sample_dust(c, ci.size) if AT.PHASE_TAB is not None else 0, sample_ray(ci.size)) if AT.PHASE_TAB is not None else sample_ray(ci.size)
                    d[ci] = rotate(dc, ct, rng.random(ci.size)*2*math.pi)
            if it > 200:                                       # 俄罗斯轮盘：权重很小的路径掐掉
                lo = ri[w[ri] < 1e-3]; keep = rng.random(lo.size) < 0.5; alive[lo[~keep]] = False; w[lo[keep]] *= 2
    return L.mean(), L.std()/math.sqrt(N)
dirs = []
for a in (0.8, 2.0, 4.0, 8.0):
    e = math.radians(EL + a); dirs.append((a, np.array([math.cos(e), 0, math.sin(e)])))
print(f"太阳高 {EL}°，变体 {VAR}，τ550 {TAU550}，标高 {HMK or 10.8} km，光子 {N}")
print("角距 通道 |  模型总 模型单次 | MC总 ±  MC单次 | MC总/模型总")
psi0 = atm.psi.copy()
for a, dv in dirs:
    for c, cn in enumerate("RGB"):
        Lm, _ = atm.integrate(o, dv[None], np.inf, s, steps=96); atm.psi = psi0*0; Ls, _ = atm.integrate(o, dv[None], np.inf, s, steps=96); atm.psi = psi0
        m1, e1 = mc(dv, c); m2, _ = mc(dv, c, single=True)
        print(f"{a:4.1f}° {cn} | {Lm[0, c]:.4g} {Ls[0, c]:.4g} | {m1:.4g} ±{e1:.2g}  {m2:.4g} | {m1/Lm[0, c]:.2f}", flush=True)
