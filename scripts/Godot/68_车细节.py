"""毅力号材质细节纹理（实景地形系统.md §17）：一张 512² 可平铺 RGBA8 → godot/数据/sol0530/rover_detail.png。
  R、G = 微起伏高度场的法线 x、y（0.5 + 0.5·n，切线空间，平铺一周 = 着色器里的 detail_m 米）；
  B = 粗糙度起伏（均值 0.5）；A = 细颗粒（落尘里的深色砂粒，取最高 4% 作阈值）。
做法：频域合成（随机相位 × 幅度谱），整周期频率 → 天然无缝平铺。确定性（种子固定）。
运行：.venv/bin/python scripts/Godot/68_车细节.py"""
import pathlib, numpy as np
from PIL import Image
N = 512
OUT = pathlib.Path(__file__).resolve().parents[2]/"godot"/"数据"/"sol0530"/"rover_detail.png"
rng = np.random.default_rng(530)
k = np.fft.fftfreq(N)*N; KX, KY = np.meshgrid(k, k); K = np.hypot(KX, KY); K[0, 0] = 1

def field(lo, hi, slope):
    """带通 1/f^slope 噪声：lo..hi 周期/平铺，平滑过渡；归一化到均值 0、标准差 1。"""
    amp = K**(-slope)*np.exp(-(K/hi)**2)*(1 - np.exp(-(K/lo)**2)); amp[0, 0] = 0
    f = np.real(np.fft.ifft2(amp*np.exp(2j*np.pi*rng.random((N, N)))))
    return (f - f.mean())/f.std()

h = field(6, 90, 1.0)                                  # 微起伏：漆面橘皮、机加工面的细纹（拉丝在着色器里沿一个轴拉长采样）
gx = (np.roll(h, -1, 1) - np.roll(h, 1, 1))/2; gy = (np.roll(h, -1, 0) - np.roll(h, 1, 0))/2
s = 1.0/np.percentile(np.hypot(gx, gy), 99)            # 99% 的斜率落在 ±1 内（着色器再乘强度）
nx, ny = np.clip(-gx*s, -1, 1), np.clip(-gy*s, -1, 1)
r = field(3, 40, 0.8); r = np.clip(0.5 + 0.18*r, 0, 1) # 粗糙度起伏
g = field(60, 200, 0.0); g = (g > np.percentile(g, 96)).astype(float)   # 砂粒：最高 4%
img = np.stack([0.5 + 0.5*nx, 0.5 + 0.5*ny, r, g], -1)
Image.fromarray((img*255 + 0.5).astype(np.uint8), "RGBA").save(OUT)
print("写出", OUT, "法线斜率标定", round(float(s), 3), "砂粒占比", round(float(g.mean()), 3))
