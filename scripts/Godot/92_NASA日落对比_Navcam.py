"""
天空模型 vs 毅力号 Navcam 低太阳照片：蓝色光晕的径向 B/R 对比（docs/全日天空.md §4）。
  python cmp_nasa.py <输出目录>
做法：照片里找太阳（平滑后的最亮斑质心），Navcam 水平视场 45°（1280 px），假设相机水平（滚转 0），
每个像素给出方向（相对太阳的仰角、方位差），用火星大气.py 直接积分这些方向（老模型 / 新模型），
再按离太阳的角距分箱，比较 B/R 随角距的变化。因为照片是没白平衡的拜耳解码、模型是绝对辐亮度，
只比「相对变化」：每条曲线除以 18°–25° 那一箱的 B/R。天空像素 = 仰角 ≥ 太阳高 + 2°（躲开 Jezero 的地平线山）、且三通道都没饱和。
照片 PNG 的灰度映射不明：给两条——按线性值算、按 sRGB 反伽马后算——当作范围。
"""
import sys, math, json, csv, pathlib
import numpy as np
from PIL import Image
sys.path.insert(0, "/home/user/Documents/mars-work/地图_全日/scripts/Blender")
import 火星大气 as AT
import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt

plt.rcParams["font.sans-serif"] = ["Noto Sans CJK SC", "Noto Sans CJK JP", "DejaVu Sans"]
ROOT = pathlib.Path("/home/user/Documents/mars-work/地图/资料/NASA补充/日落")
OUT = pathlib.Path(sys.argv[1]); OUT.mkdir(parents=True, exist_ok=True)
FILES = ["NLF_0073_0673441843", "NLF_0394_0701933046", "NLF_0505_0711787852", "NLF_0511_0712320966", "NLF_0402_0702644287"]
HFOV = 45.0
BINS = [0, 1, 2, 3, 5, 8, 12, 18, 25, 45]
o = np.array([0, 0, AT.R - 2.52])


def gf(geff, wf=0.9, gb=-0.25): return (geff - (1 - wf)*gb)/wf


MODELS = {"旧（三通道同 g）": dict(), "蓝通道前向 g +0.106（第 1 班试过）": dict(g_fwd=(0.72, 0.72, gf(0.623 + 0.106)), shadow_h=-2.52), "Mie 相函数": dict(phase_table=str(pathlib.Path(__file__).resolve().parent/"尘埃相函数_Mie_r1.5.npz"), shadow_h=-2.52), "Mie 全套（相函数 + ω0）": dict(phase_table=str(pathlib.Path(__file__).resolve().parent/"尘埃相函数_Mie_r1.5.npz"), shadow_h=-2.52, ssa=(0.942, 0.886, 0.795))}
rows = {r["file"][:19]: r for r in csv.DictReader(open(ROOT/"index.csv")) if r["file"].startswith("NLF")}
atm = {}
for k, kw in MODELS.items():
    AT.今天(**kw); atm[k] = (AT.Atmosphere(psi_nmu=128 if kw else 32), dict(kw))


def srgb_lin(x): x = x/255.0; return np.where(x <= 0.04045, x/12.92, ((x + 0.055)/1.055)**2.4)


fig, axs = plt.subplots(len(FILES), 3, figsize=(15, 3.6*len(FILES)))
prof_all = {}
for r, key in enumerate(FILES):
    row = next(v for k, v in rows.items() if k.startswith(key))
    im = np.asarray(Image.open(ROOT/"img"/row["file"]).convert("RGB")).astype(float)
    H, W, _ = im.shape; pp = HFOV/W
    lum = im.mean(2)
    from scipy.ndimage import uniform_filter
    sm = uniform_filter(lum, 9); m = sm >= sm.max()*0.98
    ys, xs = np.nonzero(m); xs0, ys0 = xs.mean(), ys.mean()
    el_s = float(row["sun_elev_deg"])
    st = 4; yy, xx = np.mgrid[0:H:st, 0:W:st]
    elp = el_s + (ys0 - yy)*pp; dazp = (xx - xs0)*pp/np.cos(np.radians(np.clip(elp, -80, 80)))
    # 方向（太阳在 +x，方位 0）
    e = np.radians(elp); a = np.radians(dazp)
    D = np.stack([np.cos(e)*np.cos(a), np.cos(e)*np.sin(a), np.sin(e)], -1).reshape(-1, 3)
    es = math.radians(el_s); sun = np.array([math.cos(es), 0, math.sin(es)])
    ang = np.degrees(np.arccos(np.clip(D@sun, -1, 1))).reshape(yy.shape)
    pix = im[::st, ::st]
    valid = (elp >= el_s + 2.0) & (pix.max(2) < 245) & (pix.min(2) > 3)
    prof = {}
    def prof_of(R_, G_, B_):
        out = []
        for a0, a1 in zip(BINS[:-1], BINS[1:]):
            mm = valid & (ang >= a0) & (ang < a1)
            out.append((B_[mm].mean()/R_[mm].mean()) if mm.sum() > 20 else np.nan)
        out = np.array(out); ref = out[BINS.index(18)] if not np.isnan(out[BINS.index(18)]) else np.nanmean(out[-3:-1])
        return out/ref
    lin = srgb_lin(pix)
    prof["照片（按线性）"] = prof_of(pix[..., 0], pix[..., 1], pix[..., 2])
    prof["照片（按 sRGB 反伽马）"] = prof_of(lin[..., 0], lin[..., 1], lin[..., 2])
    mimg = {}
    for k, (A, kw) in atm.items():
        AT.今天(**kw)
        L, _ = A.integrate(o, D, np.inf, sun, steps=48); L = L.reshape(yy.shape + (3,)); mimg[k] = L
        prof["模型 " + k] = prof_of(L[..., 0], L[..., 1], L[..., 2])
    prof_all[key] = dict(sol=row["sol"], ltst=row["ltst_h"], el=el_s, prof={k: [None if np.isnan(x) else round(float(x), 3) for x in v] for k, v in prof.items()})
    ax = axs[r, 0]
    ax.imshow(im.astype(np.uint8)); ax.plot([xs0], [ys0], "c+", ms=14); ax.set_title(f"NASA {key[:8]} sol {row['sol']} LTST {float(row['ltst_h']):.2f} h  太阳高 {el_s:+.1f}°", fontsize=9); ax.axis("off")
    # 模型（同像素网格），每条按 18°–25° 远场平均对齐到照片的颜色（只看相对变化）
    ax = axs[r, 1]
    L = mimg["Mie 全套（相函数 + ω0）"]; far = valid & (ang >= 18) & (ang < 25)
    gain = (pix[far].mean(0)/np.maximum(L[far].mean(0), 1e-9)) if far.sum() > 20 else np.ones(3)
    img = np.clip(L*gain/255.0*1.0, 0, 1); img = (img*255).astype(np.uint8)
    Image.fromarray(np.kron(img, np.ones((st, st, 1), np.uint8))[:H, :W]).save(OUT/f"模型_{key}.png")
    ax.imshow(np.kron(img, np.ones((st, st, 1), np.uint8))[:H, :W]); ax.set_title("新模型（同视场，远场对齐到照片颜色）", fontsize=9); ax.axis("off")
    ax = axs[r, 2]; cen = [(a0 + a1)/2 for a0, a1 in zip(BINS[:-1], BINS[1:])]
    sty = {"照片（按线性）": "k-o", "照片（按 sRGB 反伽马）": "k--s", "模型 旧（三通道同 g）": "b-",  "模型 蓝通道前向 g +0.106（第 1 班试过）": "r:", "模型 Mie 相函数": "g-", "模型 Mie 全套（相函数 + ω0）": "m-"}
    for k, v in prof.items(): ax.plot(cen, v, sty[k], label=k, ms=4)
    ax.set_xscale("log"); ax.set_xlabel("离太阳角距（°）"); ax.set_ylabel("B/R ÷ (18°–25° 的 B/R)"); ax.grid(alpha=.3); ax.axhline(1, color="gray", lw=.5)
    if r == 0: ax.legend(fontsize=7)
plt.tight_layout(); plt.savefig(OUT/"对比_B比R径向.png", dpi=110)
(OUT/"对比_B比R径向.json").write_text(json.dumps(prof_all, ensure_ascii=False, indent=1))
print(json.dumps(prof_all, ensure_ascii=False)[:3000])
