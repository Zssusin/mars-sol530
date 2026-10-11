"""PIA19400（Curiosity Mastcam-34 左眼，sol 956 日落，NASA 白平衡版）：B/R 随离太阳角距的变化，对模型。IFOV 0.218 mrad（Bell 等 2017, Mastcam M-34）。"""
import sys, math, json, numpy as np, pathlib
from PIL import Image
from scipy.ndimage import uniform_filter
sys.path.insert(0, "/home/user/Documents/mars-work/地图_全日/scripts/Blender")
import 火星大气 as AT
import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
plt.rcParams["font.sans-serif"] = ["Noto Sans Mono CJK SC", "DejaVu Sans"]
OUT = pathlib.Path(sys.argv[1]); EL = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
f = pathlib.Path("/home/user/Documents/mars-work/地图/资料/NASA补充/日落/ref/PIA19400.jpg")
im = np.asarray(Image.open(f).convert("RGB")).astype(float); H, W, _ = im.shape; pp = math.degrees(0.218e-3)
lum = uniform_filter(im.mean(2), 15); ys, xs = np.nonzero(lum >= lum.max()*0.97); x0, y0 = xs.mean(), ys.mean()
print("sun px", x0, y0, "pp deg", pp)
def gf(g, wf=0.9, gb=-0.25): return (g - (1 - wf)*gb)/wf
M = {"旧": dict(), "新": dict(g_fwd=(0.72, 0.72, gf(0.729)), shadow_h=-2.52)}
st = 6; yy, xx = np.mgrid[0:H:st, 0:W:st]
elp = EL + (y0 - yy)*pp; dazp = (xx - x0)*pp/np.cos(np.radians(elp))
e = np.radians(elp); a = np.radians(dazp); D = np.stack([np.cos(e)*np.cos(a), np.cos(e)*np.sin(a), np.sin(e)], -1).reshape(-1, 3)
sun = np.array([math.cos(math.radians(EL)), 0, math.sin(math.radians(EL))]); ang = np.degrees(np.arccos(np.clip(D@sun, -1, 1))).reshape(yy.shape)
pix = im[::st, ::st]; valid = (yy < y0 - 45) & (ang > 0.4)       # 地平线山脊在太阳之下；去掉太阳盘
def lin(x): x = x/255.0; return np.where(x <= 0.04045, x/12.92, ((x + 0.055)/1.055)**2.4)
BINS = [0.4, 0.8, 1.5, 2.5, 4, 6, 8, 11]
def prof(R, B):
    o = [B[valid & (ang >= a0) & (ang < a1)].mean()/R[valid & (ang >= a0) & (ang < a1)].mean() for a0, a1 in zip(BINS[:-1], BINS[1:])]
    o = np.array(o); return o/o[-2]
res = {"照片（按线性）": prof(pix[..., 0], pix[..., 2]), "照片（按 sRGB 反伽马）": prof(lin(pix)[..., 0], lin(pix)[..., 2])}
o = np.array([0, 0, AT.R - 2.52]); imgs = {}
for k, kw in M.items():
    AT.今天(**kw); A = AT.Atmosphere(psi_nmu=128 if kw else 32)
    L, _ = A.integrate(o, D, np.inf, sun, steps=48); L = L.reshape(yy.shape + (3,)); imgs[k] = L; res["模型 " + k] = prof(L[..., 0], L[..., 2])
cen = [(a0 + a1)/2 for a0, a1 in zip(BINS[:-1], BINS[1:])]
fig, ax = plt.subplots(1, 3, figsize=(16, 4.6))
ax[0].imshow(im.astype(np.uint8)); ax[0].set_title("NASA PIA19400 Curiosity sol 956 日落（白平衡）", fontsize=9); ax[0].axis("off")
L = imgs["新"]; far = valid & (ang >= 6) & (ang < 11); g = pix[far].mean(0)/L[far].mean(0)
mi = np.clip(L*g/255, 0, 1); mi = np.kron((mi*255).astype(np.uint8), np.ones((st, st, 1), np.uint8))[:H, :W]
ax[1].imshow(mi); ax[1].set_title(f"新模型 太阳高 {EL}°（同视场，远场对齐）", fontsize=9); ax[1].axis("off")
Image.fromarray(mi).save(OUT/"模型_PIA19400.png")
sty = {"照片（按线性）": "k-o", "照片（按 sRGB 反伽马）": "k--s", "模型 旧": "b-", "模型 新": "r-"}
for k, v in res.items(): ax[2].plot(cen, v, sty[k], label=k, ms=4)
ax[2].set_xscale("log"); ax[2].set_xlabel("离太阳角距（°）"); ax[2].set_ylabel("B/R ÷ (6°–8° 的 B/R)"); ax[2].grid(alpha=.3); ax[2].legend(fontsize=8)
plt.tight_layout(); plt.savefig(OUT/"对比_PIA19400.png", dpi=110)
print(json.dumps({k: [round(float(x), 3) for x in v] for k, v in res.items()}, ensure_ascii=False)); print("bins", BINS)
