"""毅力号行驶 / 转向动画：路线 → 逐帧车身位姿、六轮转角、四个角轮的转向角、每轮上下补偿 → 多个机位，godot/实景.gd --视频 照着渲。

车轮几何读 godot/数据/sol0530/rover_rig.json（godot/工具/量车轮.gd 量 NASA 模型：六个轮心、半径 0.263 m；模型 +z 朝前、+y 朝上、+x 朝左）。
运动学（每帧）：
  车身：车体系 6 个轮底点按航向放到地上，取地面高（加实测石块的穹顶，轮子压过石块会抬起来），最小二乘拟合平面 h = h0 + a·u + b·v（u 前、v 左）→ 俯仰 atan a、横滚 atan b；
        各轮剩下的高差（限 ±12 cm）给该轮上下补偿——代替摇臂-转向架的铰接（模型的悬架是一整块，不能真的转）；轮子陷 1 cm。
  转角：每个轮心自己走过的弧长 / 半径（转弯时外侧轮转得多）。
  转向：角轮按刚体运动学，轮心速度方向和车头的夹角（超过 90° 就反过来、倒着转）；中轮不转向（原地转时打滑，和真车一样）。
        两段动作之间先停车、1.2 s 内把角轮转到下一段要的角度（真车也是先停、再打方向）。
速度按显示：直行 0.45 m/s、原地转 15°/s（真车约 4 cm/s，相当于 10 倍速延时）。
运行：.venv/bin/python scripts/Godot/66_车辆动画.py [--帧率 30] [--预览] → 产出/Godot/车辆/路径.json（--预览 另出俯视路线图）
"""
import json, math, sys
from pathlib import Path
import numpy as np

MAP = Path(__file__).resolve().parents[2]
D = MAP/"godot/数据/sol0530"
OUT = MAP/"产出/Godot/车辆"
sys.path.insert(0, str(Path(__file__).parent))
from importlib import import_module
Ground = import_module("65_视频路径").Ground

V_LIN, W_PIV, T_STEER, SINK, DY_MAX = 0.45, math.radians(15), 1.2, 0.01, 0.12
UP = np.array([0.0, 1.0, 0.0])


def ease(u):
    u = min(max(u, 0.0), 1.0); return u*u*(3 - 2*u)


class Route:
    """平面路线：位置 p（Godot x, z）、航向角 ψ（前向 f = (cos ψ, 0, sin ψ)，左 l = (sin ψ, 0, −cos ψ)，左转 ψ 减小）。"""
    def __init__(self, p, psi):
        self.ops = []; self.p, self.psi = np.array(p, float), psi

    @staticmethod
    def fl(psi):
        return np.array([math.cos(psi), 0, math.sin(psi)]), np.array([math.sin(psi), 0, -math.cos(psi)])

    def add(self, kind, *a):
        self.ops.append((kind, a)); return self

    def build(self):
        """→ [(t0, t1, kind, pose(u) -> (p, psi), steer_target)]，u ∈ [0, 1] 已缓动。"""
        segs, t, p, psi = [], 0.0, self.p.copy(), self.psi
        for kind, a in self.ops:
            if kind == "直":
                d = a[0]; f, _ = self.fl(psi); dur = abs(d)/V_LIN + 0.8
                segs.append((t, t + dur, kind, (lambda p0, f, d, s: lambda u: (p0 + f*d*u, s))(p.copy(), f, d, psi)))
                p = p + f*d
            elif kind == "原地转":
                ang = math.radians(a[0]); dur = abs(ang)/W_PIV + 0.8          # 正＝左转
                segs.append((t, t + dur, kind, (lambda p0, s0, ang: lambda u: (p0, s0 - ang*u))(p.copy(), psi, ang)))
                psi -= ang
            elif kind == "弧":
                R, ang = a[0], math.radians(a[1])                              # 角度正＝左转
                f, l = self.fl(psi); C = p + l*R*math.copysign(1, ang); dur = abs(ang)*R/V_LIN + 0.8
                def arc(u, p0=p.copy(), C=C, ang=ang, s0=psi):
                    th = -ang*u; r = p0 - C
                    rr = np.array([r[0]*math.cos(th) - r[2]*math.sin(th), 0, r[0]*math.sin(th) + r[2]*math.cos(th)])
                    return C + rr, s0 - ang*u
                segs.append((t, t + dur, kind, arc))
                p, psi = arc(1.0)
            elif kind == "停":
                dur = a[0]; segs.append((t, t + dur, kind, (lambda p0, s: lambda u: (p0, s))(p.copy(), psi)))
            t += dur
        return segs


def wheel_xz(p, psi, W):
    f, l = Route.fl(psi)
    return np.array([p + w[2]*f + w[0]*l for w in W])                      # 模型 (x 左, z 前)


def main(a):
    fps = int(a[a.index("--帧率") + 1]) if "--帧率" in a else 30
    J = json.loads((D/"scene.json").read_text()); rig = json.loads((D/"rover_rig.json").read_text())
    Wc = np.array([w["c"] for w in rig["wheels"]]); r = float(np.mean([w["r"] for w in rig["wheels"]]))
    corner = [i for i, w in enumerate(rig["wheels"]) if w["corner"]]
    g0 = Ground(6)
    rk = json.loads(str(np.load(MAP/"DEM/Blender缓存/_素材/PDS/站26_1222/重建/石块.npz")["inst"]))
    RK = np.array([[k["pos"][0], -k["pos"][1], k["D"]/2, k["H"]] for k in rk])          # Godot x, z、半径、高
    def g(x, z):
        """地面高 + 实测石块的穹顶（石块是单独的网格，不在地面高程里；轮子要从上面压过去）。"""
        d = np.hypot(RK[:, 0] - x, RK[:, 1] - z)/RK[:, 2]
        return g0(x, z) + float(np.max(np.where(d < 1, RK[:, 3]*np.sqrt(np.clip(1 - d*d, 0, 1)), 0), initial=0))
    # 起点：停车位姿（scene.json 的 basis_cols、桅杆头 ↔ NavCams 中心）
    B0 = np.array(J["rover"]["basis_cols"]).T; f0 = B0[:, 2]; psi0 = math.atan2(f0[2], f0[0])
    pc = np.array(rig["navcams_center"]); o0 = np.array(J["rover"]["mast"]) - B0 @ pc
    R = Route(np.array([o0[0], 0, o0[2]]), psi0)
    R.add("停", 1.0).add("直", 3.0).add("原地转", -90).add("弧", 4.0, -90).add("直", 2.0).add("停", 1.0)   # 西南西 → 原地右转 90° 朝北北西 → 右弧 90° 朝东北东 → 直（都在 2 cm 数据区西北半边）
    segs = R.build()
    # 每段的目标转向角（角轮）：取段中点的刚体运动学
    def steer_of(seg):
        t0, t1, kind, pose = seg
        if kind == "停": return None
        (pa, sa), (pb, sb) = pose(0.49), pose(0.51)
        A, Bw = wheel_xz(pa, sa, Wc), wheel_xz(pb, sb, Wc); f, l = Route.fl(0.5*(sa + sb)); out = []
        for i in range(6):
            v = Bw[i] - A[i]; d = math.atan2(v @ l, v @ f) if np.linalg.norm(v) > 1e-9 else 0.0
            if d > math.pi/2: d -= math.pi
            if d < -math.pi/2: d += math.pi
            out.append(d if i in corner else 0.0)
        return out
    targets = [steer_of(s) for s in segs]
    # 时间轴：动作段之间插转向过渡（停车打方向）
    tl, t, prev = [], 0.0, [0.0]*6
    for seg, tg in zip(segs, targets):
        t0, t1, kind, pose = seg
        if tg is not None and np.max(np.abs(np.array(tg) - np.array(prev))) > math.radians(2):
            tl.append((t, t + T_STEER, "打方向", (lambda P: lambda u: P)(pose(0.0)), (list(prev), list(tg)))); t += T_STEER
        tl.append((t, t + (t1 - t0), kind, pose, tg if tg is not None else list(prev)))
        t += t1 - t0
        if tg is not None: prev = tg
    T = t; n = int(T*fps) + 1
    def simulate(rate):
        """按 rate 帧/秒逐帧算车身、轮转、转向、上下补偿。"""
        n = int(T*rate) + 1
        spin = np.zeros(6); last = None; frames_r = []
        for k in range(n):
            tt = min(k/rate, T - 1e-6)
            seg = next(s for s in tl if s[0] <= tt < s[1] + 1e-9)
            u = ease((tt - seg[0])/(seg[1] - seg[0]))
            p, psi = seg[3](u) if seg[2] != "打方向" else seg[3](0)
            st = (list(np.array(seg[4][0]) + (np.array(seg[4][1]) - np.array(seg[4][0]))*u) if seg[2] == "打方向" else seg[4])
            f, l = Route.fl(psi)
            wx = wheel_xz(p, psi, Wc)
            h = np.array([g(x[0], x[2]) for x in wx])
            U = np.stack([np.ones(6), Wc[:, 2], Wc[:, 0]], 1)                  # h = h0 + a·u + b·v
            (h0, aa, bb), *_ = np.linalg.lstsq(U, h, rcond=None)
            dy = np.clip(h - U @ [h0, aa, bb], -DY_MAX, DY_MAX) - SINK
            F = f + aa*UP; F /= np.linalg.norm(F); L = l + bb*UP; L /= np.linalg.norm(L)
            Y = np.cross(F, L); Y /= np.linalg.norm(Y); L = np.cross(Y, F)
            org = np.array([p[0], h0, p[2]])
            if last is not None:                                               # 各轮自己走过的距离（沿轮子朝向的分量）
                for i in range(6):
                    dv = wx[i] - last[i]; d = st[i]
                    head = math.cos(d)*f + math.sin(d)*l
                    spin[i] += (dv @ head)/r
            last = wx
            frames_r.append(dict(t=tt, seg=seg[2], o=org.round(4).tolist(), b=np.stack([L, Y, F], 1).T.round(5).tolist(),
                                 spin=spin.round(4).tolist(), steer=np.round(st, 4).tolist(), dy=dy.round(4).tolist()))
        return frames_r
    frames_r = simulate(fps); n = len(frames_r)
    print(f"[66] 路线 {T:.1f} s、{n} 帧：" + "，".join(f"{s[2]} {s[1] - s[0]:.1f}s" for s in tl))
    pos = np.array([fr["o"] for fr in frames_r])
    print(f"[66] 车体原点范围 x {pos[:, 0].min():.1f}…{pos[:, 0].max():.1f}，z {pos[:, 2].min():.1f}…{pos[:, 2].max():.1f}；"
          f"上下补偿最大 {max(max(abs(x) for x in fr['dy']) for fr in frames_r)*100:.0f} cm")
    tracks(simulate(max(fps, 60)), Wc, r)                               # 车辙按 ≥60 帧/秒印（每步 < 1 cm），和出片帧率无关
    shots = make_shots(frames_r, fps, g)
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT/"路径.json").write_text(json.dumps(dict(fps=fps, W=1920, H=1080, shots=shots), ensure_ascii=False))
    print(f"[66] {len(shots)} 个镜头、{sum(len(s['frames']) for s in shots)} 帧 → {OUT/'路径.json'}")
    if "--预览" in a: preview(frames_r, Wc, g)


def tracks(fr, Wc, r, cs=0.005, sink=0.005, groove=0.004, n_grouser=48, halfw=0.168, patch=0.06):
    """车辙图：每帧把六个轮子的着地块印进 5 mm 格网 → 数据/sol0530/车辙.bin（float32 RG：R 深度 m、G 第一次压到的时刻 s）
    ＋ 车辙.json（范围，ENU）。轮面 48 条略弯的抓地齿（毅力号），沿车辙的相位＝该轮滚过的距离，所以齿印和轮子转动对得上。
    着色器（地形.gdshader）只显示「时刻 ≤ 当前帧」的格，车辙随车往前长。"""
    pts = []
    for f in fr:
        b = np.array(f["b"]).T; o = np.array(f["o"])
        for i, w in enumerate(Wc):
            c = o + b @ (w - [0, w[1], 0] + [0, f["dy"][i], 0])
            d = f["steer"][i]; hw = math.cos(d)*b[:, 2] + math.sin(d)*b[:, 0]; lw = -math.sin(d)*b[:, 2] + math.cos(d)*b[:, 0]
            pts.append((c, hw, lw, f["spin"][i]*r, f["t"]))
    C = np.array([p[0] for p in pts]); pad = 0.5
    E0, E1 = C[:, 0].min() - pad, C[:, 0].max() + pad; N0, N1 = -C[:, 2].max() - pad, -C[:, 2].min() + pad
    W, H = int((E1 - E0)/cs) + 1, int((N1 - N0)/cs) + 1
    dep = np.zeros(H*W, np.float32); tim = np.full(H*W, 1e9, np.float32)
    u = np.arange(-patch, patch + cs/2, cs*0.7); v = np.arange(-halfw, halfw + cs/2, cs*0.7); U, V = np.meshgrid(u, v)
    U, V = U.ravel(), V.ravel(); period = 2*math.pi*r/n_grouser
    edge = 1 - (np.abs(V)/halfw)**6
    for c, hw, lw, s_roll, t in pts:
        X = c[0] + U*hw[0] + V*lw[0]; Z = c[2] + U*hw[2] + V*lw[2]
        ph = (s_roll + U)/period + 0.25*(V/halfw)**2                        # 略弯的齿
        q = (ph % 1.0) - 0.5
        d = (sink + groove*np.exp(-(q/0.12)**2))*edge
        col = ((X - E0)/cs).astype(np.int64); row = ((N1 + Z)/cs).astype(np.int64)    # 第 0 行在北（N = −z）
        ok = (col >= 0) & (col < W) & (row >= 0) & (row < H); k = row[ok]*W + col[ok]
        np.maximum.at(dep, k, d[ok].astype(np.float32)); np.minimum.at(tim, k, np.float32(t))
    with open(D/"车辙.bin", "wb") as f:
        np.array([W, H], np.int32).tofile(f); np.stack([dep, tim], -1).astype(np.float32).tofile(f)
    (D/"车辙.json").write_text(json.dumps(dict(说明="车辙图范围（ENU，m）与格距；66_车辆动画.py 生成", E0=E0, E1=E1, N0=N0, N1=N1, cs=cs, W=W, H=H)))
    print(f"[66] 车辙 {W}×{H}（{cs*1000:.0f} mm），压到 {(dep > 0).mean()*100:.1f}% 的格 → {D/'车辙.bin'}")


def cam(pos, target, hfov, t, rv):
    f = np.asarray(target, float) - pos; f /= np.linalg.norm(f)
    rr = np.cross(f, UP); rr /= np.linalg.norm(rr); up = np.cross(rr, f)
    return dict(pos=np.round(pos, 4).tolist(), fwd=np.round(f, 5).tolist(), up=np.round(up, 5).tolist(), hfov=hfov, t=t, rover=rv)


def make_shots(fr, fps, g, sun="15:00"):
    """机位按车的位姿取：同一条路线、不同时间段配不同机位，最后拼成一条。"""
    T = len(fr); shots = []
    def F(i): return np.array(fr[i]["b"]).T[:, 2]                         # 车头方向（世界）
    def Lv(i): return np.array(fr[i]["b"]).T[:, 0]
    def O(i): return np.array(fr[i]["o"])
    def idx(seg): return [i for i in range(T) if fr[i]["seg"] == seg]
    straight1 = [i for i in range(T) if fr[i]["seg"] in ("停", "直") and fr[i]["t"] < fr[idx("原地转")[0]]["t"]]      # 停 + 第一段直行
    # 1 起步：正前方偏右低机位，车朝镜头开过来
    i0 = straight1[0]; c0 = O(i0) + F(i0)*7.5 - Lv(i0)*2.5; c0[1] = g(c0[0], c0[2]) + 0.9
    shots.append(dict(name="起步", frames=[cam(c0, O(i) + UP*0.8, 50.0, sun, fr[i]) for i in straight1]))
    # 2 侧面跟拍：打方向 + 原地转，镜头在车左侧 4.5 m、离地 1.0 m，和车一起停
    seq = [i for i in range(T) if fr[i]["seg"] in ("打方向", "原地转") and fr[i]["t"] < fr[idx("原地转")[-1]]["t"] + 0.01]
    seq = [i for i in seq if i >= straight1[-1]]
    s0 = seq[0]; base = O(s0) + Lv(s0)*4.5 + F(s0)*0.5; base[1] = g(base[0], base[2]) + 1.0
    shots.append(dict(name="原地转向", frames=[cam(base, O(i) + UP*0.6, 55.0, sun, fr[i]) for i in seq]))
    # 3 弧线：无人机跟拍，车后上方 7 m、高 4.5 m，平滑跟随
    arc = [i for i in range(T) if i > seq[-1] and fr[i]["seg"] in ("打方向", "弧")]
    sm = None; frames = []
    for i in arc:
        want = O(i) - F(i)*6.0 + Lv(i)*2.0 + UP*4.5
        sm = want if sm is None else sm + (want - sm)*0.06
        frames.append(cam(sm, O(i) + UP*0.5 + F(i)*1.5, 55.0, sun, fr[i]))
    shots.append(dict(name="弧线转弯", frames=frames))
    # 4 轮子特写：最后一段直行，镜头贴地（0.35 m）放在车右侧 2.8 m（离轮子约 1.6 m），车从镜头前开过
    last = [i for i in range(T) if i > arc[-1]]
    mid = last[len(last)//2]; cpos = O(mid) - Lv(mid)*2.8 + F(mid)*0.8; cpos[1] = g(cpos[0], cpos[2]) + 0.35
    shots.append(dict(name="车轮特写", frames=[cam(cpos, O(i) + UP*0.35 - Lv(i)*1.0 + F(i)*0.6, 55.0, sun, fr[i]) for i in last]))
    # 5 俯拍全程：12 m 高、3 倍速
    allf = list(range(0, T, 3)); ctr = np.mean([O(i) for i in allf], 0)
    top = ctr + UP*16 + np.array([0.01, 0, 0.01])
    shots.append(dict(name="俯拍全程", frames=[cam(top, ctr, 60.0, sun, fr[i]) for i in allf]))
    return shots


def preview(fr, Wc, g):
    from PIL import Image, ImageDraw
    A = Image.open(D/"albedo_near.png").convert("RGB"); n = A.size[0]; half = 10.0; s = n/(2*half)
    d = ImageDraw.Draw(A)
    def px(x, z): return ((x + half)*s, (z + half)*s)                     # PNG 第 0 行在北＝Godot z = −10
    rk = json.loads(str(np.load(MAP/"DEM/Blender缓存/_素材/PDS/站26_1222/重建/石块.npz")["inst"]))   # 实测石块：pos（ENU）、D
    track = []
    for i in range(0, len(fr), 2):
        b = np.array(fr[i]["b"]).T; o = np.array(fr[i]["o"])
        for w in Wc:
            q = o + b @ (w - [0, w[1], 0]); track.append(q); u = px(q[0], q[2]); d.ellipse([u[0] - 3, u[1] - 3, u[0] + 3, u[1] + 3], fill=(255, 0, 255))
    track = np.array(track); hit = []
    for k in rk:
        c = px(k["pos"][0], -k["pos"][1]); rr = k["D"]/2*s
        d.ellipse([c[0] - rr, c[1] - rr, c[0] + rr, c[1] + rr], outline=(0, 255, 255), width=3)
        gap = np.min(np.hypot(track[:, 0] - k["pos"][0], track[:, 2] + k["pos"][1])) - k["D"]/2 - 0.17   # 轮宽一半 17 cm
        if gap < 0.05: hit.append((round(k["D"], 2), round(k["H"], 2), round(gap, 2)))
    print(f"[66] 轮迹碰到的实测石块（直径、高、间隙 m）：{hit or '无'}")
    A.resize((1000, 1000)).save(OUT/"路线预览.jpg", quality=88)
    print(f"[66] 预览 → {OUT/'路线预览.jpg'}")


if __name__ == "__main__":
    main(sys.argv[1:])
