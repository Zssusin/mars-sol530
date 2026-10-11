"""
火星尘埃 Mie 相函数表（逐通道）—— docs/全日天空.md §4。
输入（都来自文献，见 docs）：
  复折射率  Wolff 等 2009（JGR 114 E00D04, doi 10.1029/2009JE003350）的表，取 NASA Ames 火星气候模型组公布的
            Dust_Refractive_Indicies.txt（Cockell 等 2017 arXiv:1701.01373 脚注 5 引的就是这个文件），本地副本
            资料/NASA补充/文献/Wolff2009_Dust_Refractive_Indicies.txt（0.44–0.95 µm 的行）
  粒径分布  对数正态，r_eff=1.5 µm，ν_eff=0.3（Hansen & Travis 1974 定义；Tomasko 等 1999、Wolff 等 2009、Chen-Chen 等 2019 用 0.3）
  球形粒子  Mie（miepython）。Wolff 2009 的折射率是按圆柱 D/L=1 反演的，这里用球，见文档的可信角度范围。
通道：CIE1931 2° 色匹配 → 线性 sRGB 的正部分当三通道响应（负瓣截掉），波长间隔 10 nm，不乘太阳光谱（太阳 400–700 nm 近平）。
每个波长的 dσ/dΩ、Csca、Cext 都存进 npz（400–730 nm），别的通道权重（如 Mastcam 的 Bayer）可从中重算，不用再跑 Mie。
输出：尘埃相函数_Mie.npz（theta[°], P[3, n] 单位 sr^-1，∫P dΩ = 1；ω0、Q_ext 比、g）。
"""
import sys, math, json, numpy as np, miepython as mp   # 本版 miepython 3.3.0

REFF, VEFF = 1.5, 0.3

def load_nk(path):
    a = np.loadtxt(path, skiprows=1)
    return a[:, 0], a[:, 1], a[:, 2]

def lognormal_weights(reff, veff, nr=300):
    """Hansen-Travis r_eff, v_eff 的对数正态：lnσ² = ln(1+veff)；r_eff = rg·exp(2.5 lnσ²)。返回 r(µm), 数密度权重 n(r) dlnr"""
    s2 = math.log(1 + veff); rg = reff/math.exp(2.5*s2)
    lnr = np.linspace(math.log(rg) - 6*math.sqrt(s2), math.log(rg) + 6*math.sqrt(s2) + 1.0, nr)
    r = np.exp(lnr)
    w = np.exp(-0.5*(lnr - math.log(rg))**2/s2)
    # 数值核对 r_eff, v_eff
    G = w*math.pi*r*r; reff_n = np.sum(r*G)/np.sum(G); veff_n = np.sum((r - reff_n)**2*G)/(reff_n**2*np.sum(G))
    return r, w, reff_n, veff_n

def theta_grid():
    return np.concatenate([np.linspace(0, 6, 601)[:-1], np.linspace(6, 180, 1741)])   # 度；前向 0.01°，其余 0.1°

def cross_sections(lam, m, r, w, theta):
    """一个波长：返回 dσ/dΩ(θ)（µm²/sr，对 w 加权和）、Csca、Cext（µm²，同权）"""
    mu = np.cos(np.radians(theta))
    k = 2*math.pi/lam
    ds = np.zeros(len(theta)); csca = 0.0; cext = 0.0
    for ri, wi in zip(r, w):
        x = k*ri
        S1, S2 = (0.5*a for a in mp.S1_S2(m, x, mu, norm='bohren'))   # 本版 miepython 的 bohren 归一比 BHMIE 大 2 倍（见 miecheck.py），下面 chk 用能量恒等式核对
        ds += wi*(np.abs(S1)**2 + np.abs(S2)**2)/2/k**2
        qext, qsca, qback, g = mp.efficiencies_mx(m, x)
        csca += wi*qsca*math.pi*ri*ri; cext += wi*qext*math.pi*ri*ri
    return ds, csca, cext

def channel_weights(wl):
    import colour
    cm = colour.MSDS_CMFS['CIE 1931 2 Degree Standard Observer'].copy().align(colour.SpectralShape(wl[0], wl[-1], wl[1] - wl[0]))
    M = colour.models.RGB_COLOURSPACES['sRGB'].matrix_XYZ_to_RGB
    rgb = np.clip(cm.values @ M.T, 0, None)
    return rgb  # (nwl, 3)


def band_phase(th, wl, dsl, cs, ce, wts):
    """给定每个波长的 dσ/dΩ、Csca、Cext 和三通道的波长权重 wts (nwl, 3)，返回 P[3, n]（∫P dΩ=1）和每通道的 ω0、Cext 相对绿、g、有效波长。"""
    sinw = 2*math.pi*np.sin(np.radians(th)); P = np.zeros((3, len(th))); res = {}
    for c, name in enumerate("RGB"):
        wc = wts[:, c]
        num = (wc[:, None]*dsl).sum(0)
        P[c] = num/np.trapezoid(num*sinw, np.radians(th))
        res[name] = dict(leff_nm=float((wc*wl).sum()/wc.sum()), omega0=float((wc*cs).sum()/(wc*ce).sum()), cext_rel=float((wc*ce).sum()/wc.sum()),
                         g=float(np.trapezoid(P[c]*sinw*np.cos(np.radians(th)), np.radians(th))))
    gref = res["G"]["cext_rel"]
    for n in "RGB": res[n]["cext_rel"] /= gref
    return P, res

def mastcam_weights(wl, cal_txt, filt0=True):
    """Mastcam-34 的 Bayer 三通道（滤光片 0＝宽带红外截止，即「CLEAR」）波长权重：QE_c(λ) × T_f0(λ) × 黑体 5772 K（粗略代替太阳谱）。
    表来自 PDS MSLMST_0001/CALIB/MSL_MMM_CAL.TXT（Caplinger, MSSS, 2013）的 KAI-2020CM 量子效率（红/绿/蓝）与 Filter 0 透过率。"""
    L = open(cal_txt).read().split("\n")
    def tab(a, b):
        o = []
        for l in L[a:b]:
            p = l.split()
            if len(p) == 2:
                try: o.append((float(p[0]), float(p[1])))
                except ValueError: pass
        return np.array(o)
    qe = [tab(139, 229), tab(229, 319), tab(319, 409)]; f0 = tab(583, 1588)
    bb = lambda l: 1/(l**5*(np.exp(1.4388e7/(l*5772)) - 1))
    return np.stack([np.interp(wl, q[:, 0], q[:, 1])*np.interp(wl, f0[:, 0], f0[:, 1])*bb(wl) for q in qe], -1)

def main(nk_path, out, reff=REFF, veff=VEFF):
    wn, nr, ni = load_nk(nk_path)
    wl = np.arange(400, 731, 10.0)
    rgbw = channel_weights(wl)
    th = theta_grid()
    r, w, re, ve = lognormal_weights(reff, veff)
    print(f"r_eff={re:.4f} v_eff={ve:.4f} (target {reff}, {veff})")
    from multiprocessing import Pool
    jobs = [(lam/1000, complex(np.interp(lam/1000, wn, nr), -np.interp(lam/1000, wn, ni)), r, w, th) for lam in wl]
    with Pool(8) as pool: out_ = pool.starmap(cross_sections, jobs)
    dsl = [o[0] for o in out_]; cs = [o[1] for o in out_]; ce = [o[2] for o in out_]
    dsl = np.array(dsl); cs = np.array(cs); ce = np.array(ce)
    sinw = 2*math.pi*np.sin(np.radians(th))
    # 核对：∫dσ/dΩ dΩ = Csca
    chk = np.trapezoid(dsl*sinw, np.radians(th), axis=1)/cs
    print("∫dσ/dΩ dΩ / Csca  min/max:", chk.min(), chk.max())
    P, res = band_phase(th, wl, dsl, cs, ce, rgbw)
    print(json.dumps(res, indent=1))
    import os; os.makedirs(os.path.dirname(out) or '.', exist_ok=True)
    np.savez(out, theta=th, P=P, wl=wl, rgbw=rgbw, dsl=dsl, cs=cs, ce=ce, res=json.dumps(res), reff=reff, veff=veff)
    return th, P, res

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], *(float(a) for a in sys.argv[3:5]))
