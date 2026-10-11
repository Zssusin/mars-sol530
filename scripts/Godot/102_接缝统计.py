"""接缝与连续性：17:00（老天空，太阳 5.47°）前后几张天空图的 E_sky、离太阳 3–6° 和 12–30° 环的 B/R、上半球平均 B/R。用法：102_接缝统计.py [数据目录]"""
import json, math, sys, pathlib, numpy as np
D = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path("/home/user/Documents/mars-work/地图_全日/godot/数据/sol0530")
S = json.loads((D/"scene.json").read_text())["sky"]; mins = lambda t: int(t[:2])*60 + int(t[3:])
ks = [k for k in sorted(S, key=mins) if 15*60 + 50 <= mins(k) <= 17*60 + 33]
print("时刻   太阳高°  E_sky  上半球B/R  3–6°环B/R  12–30°环B/R  3–6°环G亮度  远场(30–90°)G亮度")
for k in ks:
    f = D/S[k]["file"]; raw = np.fromfile(f, np.float32, offset=8); w, h = np.fromfile(f, np.int32, 2); L = raw.reshape(h, w, 3)
    i = np.arange(h)[::-1]; th = ((i + 0.5)/h - 0.5)*math.pi; u = (np.arange(w) + 0.5)/w; ph = -(u - 0.5)*2*math.pi
    TH, PH = np.meshgrid(th, ph, indexing="ij"); d = np.stack([np.cos(TH)*np.cos(PH), np.cos(TH)*np.sin(PH), np.sin(TH)], -1)
    s = np.array(S[k]["sun_enu"]); ang = np.degrees(np.arccos(np.clip(d@s, -1, 1))); up = d[..., 2] > 0.02; wgt = np.cos(TH)
    def ring(a0, a1):
        m = up & (ang >= a0) & (ang < a1); w_ = wgt[m]; return (L[m]*w_[:, None]).sum(0)/w_.sum()
    r1, r2, r3, hem = ring(3, 6), ring(12, 30), ring(30, 90), (L[up]*wgt[up][:, None]).sum(0)/wgt[up].sum()
    print(f"{k}  {S[k]['elev']:6.2f}  {S[k]['E_sky']:6.2f}  {hem[2]/hem[0]:.3f}  {r1[2]/r1[0]:.3f}  {r2[2]/r2[0]:.3f}  {r1[1]:.4g}  {r3[1]:.4g}")
