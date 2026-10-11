"""Curiosity sol 956 日落（Mastcam-34 左眼，滤光片 0＝宽带 Bayer RGB，PDS 辐射标定 DRXX 产品）：模型 vs 实测的径向 I/F 剖面与并排图。
DRXX：解压、减暗电流、平场，16 位；DN × RADIANCE_SCALING_FACTOR(R,G,B) ＝ I/F（Caplinger 2013, MSL_MMM_CAL.TXT：I/F ＝ 与「被垂直入射、近日点距离的阳光照亮的理想白板」之比）。
太阳高度、方位、曝光、LTST 取自产品标签（SOLAR_ELEVATION 等），像元角度取自标签里的 CAHVOR 模型（hs、vs）。没有额外颜色处理，没有白平衡。
用法：95_Mastcam日落剖面.py <输出目录>
"""
import sys, math, json, re, importlib.util, pathlib, numpy as np
from PIL import Image
from scipy import ndimage as ndi
import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
plt.rcParams["font.sans-serif"] = ["Noto Sans Mono CJK SC", "DejaVu Sans"]; plt.rcParams["axes.unicode_minus"] = False
WT = pathlib.Path("/home/user/Documents/mars-work/地图_全日"); MAIN = WT.parent/"地图"
sys.path.insert(0, str(WT/"scripts/Blender")); import 火星大气 as AT
spec = importlib.util.spec_from_file_location("mie94", WT/"scripts/Godot/94_尘埃Mie相函数.py"); M94 = importlib.util.module_from_spec(spec); spec.loader.exec_module(M94)
OUT = pathlib.Path(sys.argv[1]); OUT.mkdir(parents=True, exist_ok=True)
D = MAIN/"资料/NASA补充/Mastcam_sol956"; CAL = MAIN/"资料/NASA补充/文献/MSL_MMM_CAL.TXT"
NPZ = pathlib.Path.home()/"全日/out/mie_r13.npz"                     # r_eff 1.3 µm（Chen-Chen 等 2019 sol 952：1.32 ± 0.19）
def read_sf(name):
    s = open(D/(name + "_DRXX.LBL")).read(); m = re.search(r"RADIANCE_SCALING_FACTOR\s*=\s*\(([^)]*)\)", s)
    return np.array([float(v) for v in m.group(1).replace("\n", " ").split(",")])
FR = [("0956ML0042280030403633C00", 3.8698, 256.5955), ("0956ML0042290080403634C00", 3.2251, 256.5512), ("0956ML0042290160403635C00", 2.7101, 256.5146)]
HS = 4645.16; VS = 4644.81; HC = 669.18; VC = 601.33; IFOV = math.degrees(1/HS)
H_SITE = -4.4; P_SITE = 7.6*math.exp((H_SITE + 2.52)/-10.8)  # Gale ≈ −4.4 km（约）；气压按 10.8 km 标高从耶泽罗值折算，不是 REMS 实测
F_RATIO = 1.0      # I/F ＝ π L_模型(E0=1)。核对：标签的 SF 随曝光变，SF×(参考白板 DN 9343 × 曝光/10 ms × (2.07e8/dsun)²) = 1 在 dsun=2.206e8 km（1.475 AU）处成立，所以 I/F 已含当日日地距离（相对当日太阳）

def rd(f):
    raw = open(f, "rb").read(); n = 1200*1344*3
    return np.frombuffer(raw[-n*2:], ">u2").reshape(3, 1200, 1344).astype(float)

def rays(x, y, el_c, az_c):
    ux = (x - HC)/HS; uy = (y - VC)/VS
    f = np.array([math.cos(el_c)*math.cos(az_c), math.cos(el_c)*math.sin(az_c), math.sin(el_c)]); r = np.array([-math.sin(az_c), math.cos(az_c), 0]); u = np.cross(f, r)   # 向上
    d = f[None, None] + ux[..., None]*r[None, None] - uy[..., None]*u[None, None] if np.ndim(x) == 2 else f + ux*r - uy*u
    return d/np.linalg.norm(d, axis=-1, keepdims=True)

def pointing(x0, y0, EL, AZ=0.0):
    el_c, az_c = math.radians(EL), math.radians(AZ)
    s = np.array([math.cos(math.radians(EL))*math.cos(math.radians(AZ)), math.cos(math.radians(EL))*math.sin(math.radians(AZ)), math.sin(math.radians(EL))])
    for _ in range(8):
        d = rays(np.array(x0), np.array(y0), el_c, az_c)
        e = math.asin(d[2]); a = math.atan2(d[1], d[0])
        el_c += math.radians(EL) - e; az_c += math.radians(AZ) - a
    return el_c, az_c, s

def ridge_rows(G):
    """每列：天空/山脊交界行（竖直梯度最陡的下降）。"""
    g = ndi.gaussian_filter(G, 3); gy = np.gradient(g, axis=0)
    rr = np.argmin(gy[250:800], axis=0) + 250
    return ndi.median_filter(rr, 31)

def bins_edges(): return np.array([0.7, 1.0, 1.4, 2.0, 2.8, 4.0, 5.6, 8.0, 11.0])

def build_models(tau550_by_name):
    z = np.load(NPZ); th = z["theta"]; wl = z["wl"]
    wm = M94.mastcam_weights(wl, CAL)
    P, res = M94.band_phase(th, wl, z["dsl"], z["cs"], z["ce"], wm)
    np.savez(OUT/"mastcam_phase.npz", theta=th, P=P, res=json.dumps(res), reff=float(z["reff"]), veff=float(z["veff"]))
    return res, OUT/"mastcam_phase.npz"

def main():
    res, pz = build_models(None)
    print("Mastcam Bayer 带的 Mie：", json.dumps(res, ensure_ascii=False))
    # τ(880 nm) → τ(各通道)：Mie 的 Cext 比。880 nm 另算
    z = np.load(NPZ); r, w, _, _ = M94.lognormal_weights(float(z["reff"]), float(z["veff"])); wn, nr, ni = M94.load_nk(MAIN/"资料/NASA补充/文献/Wolff2009_Dust_Refractive_Indicies.txt")
    def cext(lam): return sum(wi*M94.mp.efficiencies_mx(complex(np.interp(lam, wn, nr), -np.interp(lam, wn, ni)), 2*math.pi*ri/lam)[0]*math.pi*ri*ri for ri, wi in zip(r, w))
    c880 = cext(0.880); wl = z["wl"]; wm = M94.mastcam_weights(wl, CAL)
    cb = np.array([(wm[:, k]*z["ce"]).sum()/wm[:, k].sum() for k in range(3)])
    q = cb/c880
    print("Cext(band)/Cext(880):", q)
    TAU880 = float(sys.argv[2]) if len(sys.argv) > 2 else 0.85
    taus = TAU880*q                                   # 各通道本地光学厚度
    variants = {"老：双 HG、ω0 0.975/0.94/0.85": dict(tau=TAU880*np.array([1.0, 1.0, 1.0])*q[1]),
                "Mie 相函数（ω0、Cext 沿用老）": dict(tau=TAU880*q[1], phase_table=str(pz)),
                "Mie 全套（相函数 + ω0 + Cext）": dict(tau=taus, phase_table=str(pz), ssa=tuple(res[n]["omega0"] for n in "RGB")),
                "Mie 全套，尘标高 25 km": dict(tau=taus, phase_table=str(pz), ssa=tuple(res[n]["omega0"] for n in "RGB"), hm_km=25.0),
                "Mie 全套，τ×2": dict(tau=2*taus, phase_table=str(pz), ssa=tuple(res[n]["omega0"] for n in "RGB"))}
    print("τ 各通道", taus)
    # 实测
    obs = []; sky_masks = []
    E = bins_edges(); cen = np.sqrt(E[:-1]*E[1:])
    fr1 = rd(D/(FR[0][0] + "_DRXX.IMG")); g1 = fr1[1]; m = g1 >= 0.9*g1.max(); lab, n = ndi.label(m); k = np.argmax(ndi.sum(m, lab, range(1, n + 1))) + 1; ys, xs = np.nonzero(lab == k); X1, Y1 = xs.mean(), ys.mean()
    print("太阳像素（frame 1 饱和斑重心）", X1, Y1)
    out = {}
    for fi, (name, EL, AZ) in enumerate(FR):
        x0 = X1 + (AZ - FR[0][2])*math.cos(math.radians(EL))/IFOV; y0 = Y1 + (FR[0][1] - EL)/IFOV
        SF = read_sf(name); im = rd(D/(name + "_DRXX.IMG"))*SF[:, None, None]; Gdn = rd(D/(name + "_DRXX.IMG"))[1]
        el_c, az_c, s = pointing(x0, y0, EL)
        st = 3; yy, xx = np.mgrid[0:1200:st, 0:1344:st]
        d = rays(xx.astype(float), yy.astype(float), el_c, az_c); ang = np.degrees(np.arccos(np.clip(d@s, -1, 1)))
        rr = ridge_rows(Gdn)[::st*1][None, :]; rr = np.repeat(ndi.zoom(ridge_rows(Gdn).astype(float), 1/st, order=1)[None, :xx.shape[1]], xx.shape[0], 0)
        sky = (yy < rr - 14) & (abs(xx - x0) > 16) & (d[..., 2] > 0)
        sat = (rd(D/(name + "_DRXX.IMG")).max(0) >= 1750)[::st, ::st]
        sky &= ~sat
        pix = im[:, ::st, ::st]
        o = np.array([[np.median(pix[c][sky & (ang >= a0) & (ang < a1)]) if (sky & (ang >= a0) & (ang < a1)).sum() > 30 else np.nan for a0, a1 in zip(E[:-1], E[1:])] for c in range(3)])
        cnt = [int((sky & (ang >= a0) & (ang < a1)).sum()) for a0, a1 in zip(E[:-1], E[1:])]
        o_ = dict(obs=o, cnt=cnt, x0=x0, y0=y0, el=EL)
        # 模型
        o_["model"] = {}; o_["img"] = {}
        origin = np.array([0, 0, AT.R + H_SITE]); Dv = d[sky]
        for vn, kw in variants.items():
            AT.今天(tau=kw["tau"], p_hpa=P_SITE, h_site_km=H_SITE, ssa=kw.get("ssa", (0.975, 0.94, 0.85)), phase_table=kw.get("phase_table"), shadow_h=H_SITE, hm_km=kw.get("hm_km"))
            if (vn, ) not in globals().setdefault("_A", {}): globals()["_A"][(vn,)] = AT.Atmosphere(psi_nmu=128)
            A = globals()["_A"][(vn,)]
            AT.今天(tau=kw["tau"], p_hpa=P_SITE, h_site_km=H_SITE, ssa=kw.get("ssa", (0.975, 0.94, 0.85)), phase_table=kw.get("phase_table"), shadow_h=H_SITE, hm_km=kw.get("hm_km"))  # 相函数是模块级全局，换变体时重设
            L, _ = A.integrate(origin, Dv, np.inf, s, steps=64)
            ifm = np.pi*L*F_RATIO
            full = np.full(pix.shape, np.nan); 
            for c in range(3): full[c][sky] = ifm[:, c]
            o_["model"][vn] = np.array([[np.median(full[c][(ang >= a0) & (ang < a1) & sky]) if ((ang >= a0) & (ang < a1) & sky).sum() > 30 else np.nan for a0, a1 in zip(E[:-1], E[1:])] for c in range(3)])
        out[name] = o_
        print(name, "EL", EL, "x0,y0", round(x0, 1), round(y0, 1), "bins n", cnt)
        for vn in variants:
            mo = o_["model"][vn]; print(f"  {vn}: 模型/实测 R", np.round(mo[0]/o[0], 2), " B", np.round(mo[2]/o[2], 2)); print("     B/R 实测", np.round(o[2]/o[0], 3), "模型", np.round(mo[2]/mo[0], 3))
    np.save(OUT/"mastcam_profiles.npy", dict(cen=cen, edges=E, out=out, taus=taus, res=res, variants=list(variants)), allow_pickle=True)
    plot(out, cen, list(variants), taus)

def plot(out, cen, vnames, taus):
    cols = ["#c0392b", "#27ae60", "#2c5fd0"]; ls = dict(zip(vnames, ["--", "-.", "-", ":", (0, (6, 2, 1, 2))]))
    fig, axs = plt.subplots(3, 3, figsize=(17, 13))
    for i, (name, o) in enumerate(out.items()):
        ax = axs[i, 0]
        for c, cn in enumerate("RGB"):
            ax.plot(cen, o["obs"][c], "o-", color=cols[c], ms=4, lw=1.5, label=f"实测 {cn}")
            for vn in vnames: ax.plot(cen, o["model"][vn][c], linestyle=ls[vn], color=cols[c], lw=1, alpha=.9)
        ax.set_xscale("log"); ax.set_yscale("log"); ax.set_xlabel("离太阳角距（°）"); ax.set_ylabel("I/F"); ax.grid(alpha=.3, which="both"); ax.set_title(f"太阳高 {o['el']:.2f}°：实测（点线）与模型（虚线 老 / 点划线 Mie相函数 / 实线 Mie全套）", fontsize=9)
        ax = axs[i, 1]
        ax.plot(cen, o["obs"][2]/o["obs"][0], "ko-", label="实测 B/R", ms=4)
        for vn in vnames: ax.plot(cen, o["model"][vn][2]/o["model"][vn][0], linestyle=ls[vn], color="#2c5fd0", label=vn)
        ax.set_xscale("log"); ax.set_xlabel("离太阳角距（°）"); ax.set_ylabel("B/R（绝对，I/F 比）"); ax.grid(alpha=.3); ax.legend(fontsize=7); ax.set_title("B/R 随角距", fontsize=10)
        ax = axs[i, 2]; ref = 5
        ax.plot(cen, o["obs"][2]/o["obs"][0]/(o["obs"][2][ref]/o["obs"][0][ref]), "ko-", ms=4, label="实测")
        for vn in vnames: ax.plot(cen, o["model"][vn][2]/o["model"][vn][0]/(o["model"][vn][2][ref]/o["model"][vn][0][ref]), linestyle=ls[vn], color="#2c5fd0", label=vn)
        ax.set_xscale("log"); ax.set_xlabel("离太阳角距（°）"); ax.set_ylabel(f"B/R ÷ （{cen[ref]:.1f}° 处的 B/R）"); ax.grid(alpha=.3); ax.legend(fontsize=7); ax.set_title("相对形状（消掉整体颜色偏差）", fontsize=10)
    plt.tight_layout(); plt.savefig(OUT/"对比_Mastcam径向.png", dpi=100)

if __name__ == "__main__": main()
