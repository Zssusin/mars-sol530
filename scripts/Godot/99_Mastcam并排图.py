"""并排图：Curiosity sol 956 日落（Mastcam DRXX I/F，不加白平衡）与模型在同一太阳高度、同一视场、同一显示映射下的天空。
列：实测 | 老模型（双 HG）| Mie 全套 | Mie 全套（把 8–11° 的绿通道对到实测，只对亮度，看颜色和梯度）。行：太阳高 3.87°、2.71°。山脊以下不画模型。
显示：I/F 线性 → 乘 2.0 → sRGB 伽马；没有逐通道增益。用法：99_Mastcam并排图.py <输出目录>（要先跑 95）"""
import sys, math, importlib.util, pathlib, numpy as np
from PIL import Image
spec = importlib.util.spec_from_file_location("m95", pathlib.Path(__file__).parent/"95_Mastcam日落剖面.py"); M = importlib.util.module_from_spec(spec); sys.argv = [sys.argv[0], sys.argv[1]]; spec.loader.exec_module(M)
OUT = pathlib.Path(sys.argv[1]); AT = M.AT; np_ = np
prof = np.load(OUT/"mastcam_profiles.npy", allow_pickle=True).item(); taus = prof["taus"]; res = prof["res"]
ssa = tuple(res[n]["omega0"] for n in "RGB"); pz = str(OUT/"mastcam_phase.npz")
VAR = {"老模型": dict(tau=float(taus[1]), ssa=(0.975, 0.94, 0.85)), "Mie 全套": dict(tau=taus, phase_table=pz, ssa=ssa)}
def disp(x): x = np.clip(x*2.0, 0, 1); return (np.where(x <= 0.0031308, 12.92*x, 1.055*np.power(x, 1/2.4) - 0.055)*255).astype(np.uint8)
rows = []
for fi in (0, 2):
    name, EL, AZ = M.FR[fi]; x0 = prof["out"][name]["x0"]; y0 = prof["out"][name]["y0"]
    raw = M.rd(M.D/(name + "_DRXX.IMG")); sf = M.read_sf(name); obs = raw*sf[:, None, None]; Gdn = raw[1]
    el_c, az_c, s = M.pointing(x0, y0, EL); st = 2; yy, xx = np.mgrid[0:1200:st, 0:1344:st]
    d = M.rays(xx.astype(float), yy.astype(float), el_c, az_c)
    rr = np.repeat(M.ndi.zoom(M.ridge_rows(Gdn).astype(float), 1/st, order=1)[None, :xx.shape[1]], xx.shape[0], 0)
    sky = (yy < rr - 6) & (d[..., 2] > 0)
    origin = np.array([0, 0, AT.R + M.H_SITE]); imgs = {}
    for vn, kw in VAR.items():
        AT.今天(tau=kw["tau"], p_hpa=M.P_SITE, h_site_km=M.H_SITE, ssa=kw["ssa"], phase_table=kw.get("phase_table"), shadow_h=M.H_SITE)
        A = AT.Atmosphere(psi_nmu=128); L, _ = A.integrate(origin, d[sky], np.inf, s, steps=64)
        im = np.zeros(sky.shape + (3,)); im[sky] = math.pi*L; imgs[vn] = im
    o = np.moveaxis(obs[:, ::st, ::st], 0, 2)
    far = sky & (np.degrees(np.arccos(np.clip(d@s, -1, 1))) >= 8) & (abs(xx - x0) > 16)
    k = o[far][:, 1].mean()/imgs["Mie 全套"][far][:, 1].mean()
    sunpx = (np.hypot(xx - x0, yy - y0) < 6)
    cols = [o, imgs["老模型"], imgs["Mie 全套"], imgs["Mie 全套"]*k]
    rows.append(np.hstack([disp(c) for c in cols]))
    print(f"太阳高 {EL}°：Mie 全套 对齐 8–11° 绿通道的亮度倍数 k = {k:.2f}")
Image.fromarray(np.vstack(rows)).save(OUT/"并排_Mastcam对模型.png")
