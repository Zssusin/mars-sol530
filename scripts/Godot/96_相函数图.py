"""尘埃相函数图：Mie 表（逐通道）对老的双 HG 和 Chen-Chen 等 2019（arXiv:1905.01074，MSL 工程相机 650 nm）的双 HG。用法：96_相函数图.py <npz> <输出目录> [npz2 标签2 …]"""
import sys, math, json, numpy as np, pathlib
import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
plt.rcParams["font.sans-serif"] = ["Noto Sans Mono CJK SC", "DejaVu Sans"]; plt.rcParams["axes.unicode_minus"] = False
def hg(c, g): return (1 - g*g)/(4*math.pi*(1 + g*g - 2*g*c)**1.5)
z = np.load(sys.argv[1]); th = z["theta"]; P = z["P"]; res = json.loads(str(z["res"])); c = np.cos(np.radians(th)); out = pathlib.Path(sys.argv[2]); out.mkdir(parents=True, exist_ok=True)
old = 0.9*hg(c, 0.72) + 0.1*hg(c, -0.25)
cc = 0.743*hg(c, 0.889) + 0.257*hg(c, 0.094)      # Chen-Chen 等 (2019b) 式 (1)，α 乘 g1 项
col = {"R": "#c0392b", "G": "#27ae60", "B": "#2c5fd0"}
fig, ax = plt.subplots(1, 3, figsize=(17, 5))
for k, n in enumerate("RGB"): ax[0].plot(th, P[k], color=col[n], label=f"Mie {n}（λeff {res[n]['leff_nm']:.0f} nm，g {res[n]['g']:.3f}）")
ax[0].plot(th, old, "k--", label="老：双 HG（g 0.72/−0.25，w 0.9，g=0.63）"); ax[0].plot(th, cc, ":", color="#555", lw=2, label="Chen-Chen 2019 双 HG（650 nm，g=0.673）")
ax[0].set_yscale("log"); ax[0].set_xlim(0, 180); ax[0].set_xlabel("散射角（°）"); ax[0].set_ylabel("P(θ)（sr⁻¹，∫P dΩ=1）"); ax[0].grid(alpha=.3); ax[0].legend(fontsize=8); ax[0].set_title("尘埃相函数 0–180°（球形 Mie，r_eff %.2g µm，ν_eff %.2g）" % (float(z["reff"]), float(z["veff"])), fontsize=10)
for k, n in enumerate("RGB"): ax[1].plot(th, P[k], color=col[n])
ax[1].plot(th, old, "k--"); ax[1].plot(th, cc, ":", color="#555", lw=2); ax[1].set_yscale("log"); ax[1].set_xlim(0, 25); ax[1].set_xlabel("散射角（°）"); ax[1].grid(alpha=.3); ax[1].set_title("前向峰放大 0–25°", fontsize=10)
m = th <= 40
ax[2].plot(th[m], P[2][m]/P[0][m], color=col["B"], label="Mie B/R"); ax[2].plot(th[m], P[2][m]/P[1][m], color="#7b3fa0", label="Mie B/G"); ax[2].plot(th[m], P[1][m]/P[0][m], color="#b8860b", label="Mie G/R")
ax[2].axhline(1, color="k", lw=.5); ax[2].set_xlabel("散射角（°）"); ax[2].set_ylabel("相函数通道比"); ax[2].grid(alpha=.3); ax[2].legend(fontsize=8); ax[2].set_title("蓝红相函数比（老模型三通道同 g ＝ 恒为 1）", fontsize=10)
for a, lab in zip(sys.argv[3::2], sys.argv[4::2]):
    z2 = np.load(a); ax[2].plot(z2["theta"][m], z2["P"][2][m]/z2["P"][0][m], "--", color=col["B"], lw=1, label=f"B/R {lab}")
ax[2].legend(fontsize=8)
plt.tight_layout(); plt.savefig(out/"相函数_Mie.png", dpi=110)
rows = [0, 0.3, 1, 2, 3, 5, 10, 20, 45, 90, 135, 180]
print("θ°   " + " ".join(f"{n:>9}" for n in ["R", "G", "B", "B/R", "老HG", "ChenChen"]))
for t in rows:
    i = np.argmin(abs(th - t)); print(f"{th[i]:6.2f} " + " ".join(f"{v:9.3g}" for v in [P[0][i], P[1][i], P[2][i], P[2][i]/P[0][i], old[i], cc[i]]))
sinw = 2*math.pi*np.sin(np.radians(th)); print("g：老HG", np.trapezoid(old*sinw*c, np.radians(th)), "ChenChen", np.trapezoid(cc*sinw*c, np.radians(th)), "∫老", np.trapezoid(old*sinw, np.radians(th)))
print(json.dumps(res, ensure_ascii=False))
