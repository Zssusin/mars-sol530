"""地图台数据：路线（NASA/JPL-Caltech MMGIS M20_traverse，sol ≤ 530，转站点系）、已探索点云、样张机位、页底图。
输出到 godot/数据/sol0530/：地图台路线.json、地图台已探索.bin（float32 E,N 对）、地图台机位.json、地图台底.png。
机位和取景按 docs/界面/地图样张/生成/全息.py 模式 F 原样重算（不画深度图）。用法：.venv/bin/python scripts/Godot/90_地图台数据.py"""
import json, math, pathlib, sys
import numpy as np
from PIL import Image, ImageDraw
仓库 = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(仓库 / "docs/界面/主菜单样张/生成"))
import 菜单公共 as C
W, H = C.W, C.H
数据 = 仓库 / "godot/数据/sol0530"
路线文件 = pathlib.Path.home() / "Documents/mars-work/地图/资料/路线/M20_traverse.json"
VE = 3.0; 台 = (-1500.0, 3450.0, -2150.0, 900.0)
R火 = 3396190.0; 纬0 = 18.45864728; 经0 = 77.40592495
HB = np.fromfile(数据 / "heights.bin", np.float32, offset=8).reshape(15, 601, 601)
def 高(E, N):
    E = np.asarray(E, float); N = np.asarray(N, float); x, z = E, -N; r = np.maximum(np.abs(x), np.abs(z))
    def 层(k, m):
        half = 6.0 * 2 ** k; sp = 2 * half / 600
        fi = (x[m] + half) / sp; fj = (z[m] + half) / sp
        i0 = np.clip(np.floor(fi).astype(int), 0, 599); j0 = np.clip(np.floor(fj).astype(int), 0, 599)
        tx = fi - i0; ty = fj - j0; A = HB[k]
        return (A[j0, i0] * (1 - tx) * (1 - ty) + A[j0, i0 + 1] * tx * (1 - ty) + A[j0 + 1, i0] * (1 - tx) * ty + A[j0 + 1, i0 + 1] * tx * ty)
    out = np.full(E.shape, np.nan)
    for k in range(8, 14):
        half = 6.0 * 2 ** k; m = np.isnan(out) & (r < half * 0.995)
        if not m.any(): continue
        h = 层(k, m); t = np.clip((r[m] / half - 0.82) / 0.15, 0, 1); t = t * t * (3 - 2 * t)
        if (t > 0).any(): h = h * (1 - t) + 层(k + 1, m) * t
        out[m] = h
    return out
def 世(E, N, U, 抬=0.0): return np.stack([np.asarray(E, float), np.asarray(U, float) * VE + 抬, -np.asarray(N, float)], -1)
class 机:
    def __init__(s, pos, tgt, hfov):
        s.p = np.array(pos, float); fw = np.array(tgt, float) - s.p; s.f = fw / np.linalg.norm(fw)
        r = np.cross(s.f, [0.0, 1.0, 0.0]); s.r = r / np.linalg.norm(r); s.u = np.cross(s.r, s.f); s.k = (W / 2) / math.tan(math.radians(hfov) / 2)
    def __call__(s, X):
        d = np.asarray(X, float) - s.p; zc = d @ s.f
        return np.stack([W / 2 + (d @ s.r) / zc * s.k, H / 2 - (d @ s.u) / zc * s.k, zc], -1)
中心 = ((台[0] + 台[1]) / 2, (台[2] + 台[3]) / 2)
方位 = math.radians(180.0); 仰 = math.radians(56.0); 视 = 38.0; 框区 = (200.0, 1990.0, 210.0, 1270.0)
def _摆机(距, 偏):
    t = np.array([中心[0] + 偏[0], 0.0, -(中心[1] + 偏[1])])
    return 机(t + 距 * np.array([math.sin(方位) * math.cos(仰), math.sin(仰), -math.cos(方位) * math.cos(仰)]), t, 视), t
def _台角屏(c):
    E = np.array([台[0], 台[1], 台[1], 台[0]] * 2); N = np.array([台[2], 台[2], 台[3], 台[3]] * 2); U = np.array([-40.0] * 4 + [90.0] * 4)
    return c(世(E, N, U))
距, 偏 = 7000.0, np.zeros(2)
for _ in range(30):
    c, _t = _摆机(距, 偏); S = _台角屏(c)
    sx = (S[:, 0].max() - S[:, 0].min()) / (框区[1] - 框区[0]); sy = (S[:, 1].max() - S[:, 1].min()) / (框区[3] - 框区[2])
    距 *= max(sx, sy) ** 0.8
    cx = (S[:, 0].max() + S[:, 0].min()) / 2 - (框区[0] + 框区[1]) / 2; cy = (S[:, 1].max() + S[:, 1].min()) / 2 - (框区[2] + 框区[3]) / 2
    右 = np.array([c.r[0], -c.r[2]]); 前 = np.array([c.f[0], -c.f[2]]); 前 /= np.linalg.norm(前)
    偏 = 偏 + 右 * cx * 距 / c.k * 0.8 - 前 * cy * 距 / c.k / math.sin(仰) * 0.8
cam, tgt = _摆机(距, 偏)
gE = np.arange(台[0], 台[1] + 0.1, 10.0); gN = np.arange(台[2], 台[3] + 0.1, 10.0); EE, NN = np.meshgrid(gE, gN)
U底 = float(np.nanmin(高(EE, NN))) - 25.0
json.dump({"相机位": cam.p.tolist(), "目标": tgt.tolist(), "hfov": 视, "距": 距, "仰": 56.0, "方位": 180.0, "台": 台, "U底": U底, "VE": VE,
           "台心偏": 偏.tolist()}, open(数据 / "地图台机位.json", "w"), ensure_ascii=False)
print("机位", cam.p, tgt, 距, U底)
# 路线
J = json.load(open(路线文件)); k = math.pi / 180; sol = []; E_ = []; N_ = []; 段 = []
for ft in J["features"]:
    s = ft["properties"]["sol"]
    if s > 530: continue
    g = ft["geometry"]; cs = g["coordinates"] if g["type"] == "LineString" else [c for l in g["coordinates"] for c in l]
    lon = np.array([c[0] for c in cs]); lat = np.array([c[1] for c in cs])
    E = (lon - 经0) * k * R火 * math.cos(纬0 * k); N = (lat - 纬0) * k * R火
    段.append(len(E_)); E_ += [round(float(v), 1) for v in E]; N_ += [round(float(v), 1) for v in N]; sol += [s] * len(E)
json.dump({"来源": "NASA/JPL-Caltech MMGIS M20_traverse.json，sol ≤ 530；站点系 ENU（R=3396190 m，原点 站 26/1222）", "sol": sol, "E": E_, "N": N_, "段起": 段}, open(数据 / "地图台路线.json", "w"), ensure_ascii=False, separators=(",", ":"))
print("路线点", len(E_), "段", len(段))
# 已探索
def 加密(E, N, 间=4.0):
    oE, oN = [E[0]], [N[0]]
    for i in range(1, len(E)):
        n = max(1, int(math.hypot(E[i] - E[i - 1], N[i] - N[i - 1]) / 间)); t = np.arange(1, n + 1) / n
        oE += list(E[i - 1] + (E[i] - E[i - 1]) * t); oN += list(N[i - 1] + (N[i] - N[i - 1]) * t)
    return np.array(oE), np.array(oN)
格 = 4.0; 半宽 = 35.0
gE4 = np.arange(台[0], 台[1], 格); gN4 = np.arange(台[2], 台[3], 格)
im = Image.new("L", (len(gE4), len(gN4)), 0); d = ImageDraw.Draw(im); w = int(2 * 半宽 / 格)
段起 = 段 + [len(E_)]; Ea = np.array(E_); Na = np.array(N_)
for a, b in zip(段起[:-1], 段起[1:]):
    if b - a < 2: continue
    e, n = 加密(Ea[a:b], Na[a:b]); pts = [((x - 台[0]) / 格, (y - 台[2]) / 格) for x, y in zip(e, n)]
    d.line(pts, fill=255, width=w, joint="curve")
    for x, y in pts[::8]: d.ellipse((x - w / 2, y - w / 2, x + w / 2, y + w / 2), fill=255)
cx, cy = (0 - 台[0]) / 格, (0 - 台[2]) / 格; r = 40 / 格; d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=255)
Mk = np.asarray(im) > 0; rng = np.random.default_rng(530)
Ee, Ne = np.meshgrid(gE4, gN4); pE = Ee[Mk] + rng.uniform(-1.6, 1.6, Mk.sum()); pN = Ne[Mk] + rng.uniform(-1.6, 1.6, Mk.sum())
idx = np.random.default_rng(1).permutation(len(pE)); pE = pE[idx]; pN = pN[idx]
np.stack([pE, pN], 1).astype(np.float32).tofile(数据 / "地图台已探索.bin"); print("已探索点", len(pE))
# 页底（样张 底()，灰度；游戏里按色板混色）
p = 仓库 / "docs/宣传/配图/03_高处俯瞰_正午.jpg"
imb = Image.open(p).convert("RGB").resize((W, H), Image.LANCZOS); imb = C.压暗(imb, 0.30, 糊=28, 去饱和=0.55).convert("RGB")
a = np.asarray(imb).astype(np.float32); g = a @ np.array([0.2126, 0.7152, 0.0722], np.float32)
yy, xx = np.mgrid[0:H, 0:W]; rr = np.hypot((xx - W / 2) / (W / 2), (yy - H / 2) / (H / 2)); v = np.clip(1.0 - 0.45 * rr ** 2, 0.35, 1)
g = np.clip(g * v * 0.55 / 0.55, 0, 255)
Image.fromarray(g.astype(np.uint8), "L").resize((1280, 720), Image.LANCZOS).save(数据 / "地图台底.png"); print("底图")
