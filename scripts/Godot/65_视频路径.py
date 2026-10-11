"""Godot 实景视频的相机路径：逐帧写出位置、朝向、视场、时刻，godot/实景.gd 的 --视频 模式照着渲。

离地高度按 godot/数据/sol0530/ring_KK.bin（就是渲染用的地面网格，Godot 坐标 x 东、y 上、z 南）插值，
所以相机不会钻地。三个镜头：
  走近：东边 30 m 外人眼高度（1.6 m）走到车旁 6 m，13:07；
  环绕：离车 7 m、离地 2.2 m 绕一圈，太阳 10:00 → 16:00 延时；
  升空：从离地 1.2 m 斜看脚下沙地，升到 60 m 高处看西南 1 km 外的三角洲前缘，13:07。
运行：.venv/bin/python scripts/Godot/65_视频路径.py [--帧率 30] [--只 走近,环绕] → 产出/Godot/视频/路径.json
"""
import json, math, sys
from pathlib import Path
import numpy as np
from scipy.spatial import cKDTree

MAP = Path(__file__).resolve().parents[2]
D = MAP/"godot/数据/sol0530"
OUT = MAP/"产出/Godot/视频"


class Ground:
    """地面高度：取包含该点的最细一环，最近 4 点反距离加权。"""
    def __init__(self, n=8):
        self.rings = []
        for k in range(n):
            b = (D/f"ring_{k:02d}.bin").read_bytes()
            nv = int(np.frombuffer(b[:4], np.int32)[0])
            V = np.frombuffer(b[12:12 + nv*12], np.float32).reshape(-1, 3).astype(np.float64)
            self.rings.append((np.abs(V[:, [0, 2]]).max(), cKDTree(V[:, [0, 2]]), V[:, 1]))

    def __call__(self, x, z):
        for half, tree, y in self.rings:
            if max(abs(x), abs(z)) < 0.9*half:
                d, i = tree.query([x, z], k=4); w = 1/np.maximum(d, 1e-6)
                return float((y[i]*w).sum()/w.sum())
        return 0.0


def ease(u):
    return u*u*(3 - 2*u)


def frame(pos, target, hfov, t):
    f = np.asarray(target, float) - pos; f /= np.linalg.norm(f)
    r = np.cross(f, [0, 1, 0]); r /= np.linalg.norm(r); up = np.cross(r, f)
    return dict(pos=[round(float(v), 4) for v in pos], fwd=[round(float(v), 5) for v in f],
                up=[round(float(v), 5) for v in up], hfov=hfov, t=t)


def main(a):
    fps = int(a[a.index("--帧率") + 1]) if "--帧率" in a else 30
    only = a[a.index("--只") + 1].split(",") if "--只" in a else None
    g = Ground()
    J = json.loads((D/"scene.json").read_text())
    rover = np.array([-0.3, g(-0.3, 0.1) + 0.9, 0.1])          # 车身中心（导航点在原点，桅杆在左前）
    shots = []

    # 走近：ENU (30, 4) → (6, 1.5)，Godot z = −N；视线从前方地面慢慢转到车上
    n = 12*fps; fr = []
    for i in range(n):
        u = ease(i/(n - 1))
        x = 30 - 24*u; z = -(4 - 2.5*u) + 0.15*math.sin(i/fps*2.2)   # 轻微左右晃
        p = np.array([x, g(x, z) + 1.6 + 0.02*math.sin(i/fps*9.0), z])
        ahead = p + np.array([-10, -1.4, 0.8])
        w = ease(min(1.0, i/(0.6*n)))
        fr.append(frame(p, (1 - w)*ahead + w*rover, 60.0, "13:07"))
    shots.append(dict(name="走近", frames=fr))

    # 环绕：从东侧开始逆时针一圈，延时 10:00 → 16:00
    n = 16*fps; fr = []
    for i in range(n):
        u = i/(n - 1); az = math.radians(10 + 360*u)
        x = rover[0] + 7*math.cos(az); z = rover[2] - 7*math.sin(az)
        p = np.array([x, g(x, z) + 2.2, z])
        m = 600 + 360*u; t = f"{int(m//60):02d}:{m % 60:05.2f}"
        fr.append(frame(p, rover - [0, 0.3, 0], 55.0, t))
    shots.append(dict(name="环绕", frames=fr))

    # 升空：近地相机位置离地 1.2 m 斜看 → 往东北后退升到 60 m，看西南 1 km 外
    n = 14*fps; fr = []
    p0 = np.array([-4.3, 0, -0.7]); p0[1] = g(p0[0], p0[2]) + 1.2
    for i in range(n):
        u = ease(i/(n - 1))
        x = p0[0] + 40*u; z = p0[2] - 30*u
        h = 1.2 + 58.8*u**1.6
        p = np.array([x, max(g(x, z) + 0.5, g(x, z) + h), z])
        look0 = p0 + np.array([-2.6, -1.2, 0.8])                  # 先斜看脚下沙地（约 25° 俯角）
        look1 = np.array([-900, -20.0, 650])                      # 再看西南 1 km 外（地平线在画面中部偏上）
        w = ease(min(1.0, i/(0.8*n)))
        fr.append(frame(p, (1 - w)*look0 + w*look1, 60.0, "13:07"))
    shots.append(dict(name="升空", frames=fr))

    if only: shots = [s for s in shots if s["name"] in only]
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT/"路径.json").write_text(json.dumps(dict(fps=fps, W=1920, H=1080, shots=shots), ensure_ascii=False))
    print(f"[65] {sum(len(s['frames']) for s in shots)} 帧 → {OUT/'路径.json'}；地面高：车 {rover[1] - 0.9:.2f} m")


if __name__ == "__main__":
    main(sys.argv[1:])
