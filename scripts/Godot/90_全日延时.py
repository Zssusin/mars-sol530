"""
全日延时的相机路径（给 godot/视频.sh 用，GEN=无 PJ=<路径.json>）：人眼机位不动，偏航跟着太阳方位（太阳在画面左三分之一），
俯仰略抬 4°；钟点分段变速（日出、日落、暮光慢，白天快）。
用法：.venv/bin/python scripts/Godot/90_全日延时.py <输出.json> [--帧率 30] [--起 330] [--止 1160] [--秒 日出 白天 日落]
"""
import importlib.util, json, math, pathlib, sys
import numpy as np
HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("g61", HERE/"61_Godot数据.py"); g61 = importlib.util.module_from_spec(spec); spec.loader.exec_module(g61)


def contact(a):
    """联系表：日出侧、日落侧各 12 个太阳高度（+18° → −12°）各一帧，取 scene.json 里最近的那张天空。"""
    out = pathlib.Path(a[0]); S = json.loads((g61.OUT/"scene.json").read_text()); cam = next(c for c in S["cameras"] if c["name"] == "人眼")
    pos = np.array(cam["pos"]); ks = sorted(S["sky"], key=lambda t: int(t[:2])*60 + int(t[3:]))
    shots = []
    for name, side in (("日出", 0), ("日落", 1)):
        fr = []
        for tg in (17.7, 12, 8, 5, 3, 1, 0, -2, -4, -6, -9, -12):
            k = min((t for t in ks if (int(t[:2])*60 + int(t[3:]) < 720) == (side == 0)), key=lambda t: abs(S["sky"][t]["elev"] - tg))
            m = int(k[:2])*60 + int(k[3:]); s = np.array(S["sky"][k]["sun_enu"]); az = math.atan2(s[0], s[1]); yaw = az + math.radians(15.0); pit = math.radians(8.0)
            f = np.array([math.sin(yaw)*math.cos(pit), math.sin(pit), -math.cos(yaw)*math.cos(pit)])
            r = np.cross(f, [0, 1, 0]); r /= np.linalg.norm(r); up = np.cross(r, f)
            fr.append(dict(pos=[round(float(v), 4) for v in pos], fwd=[round(float(v), 5) for v in f], up=[round(float(v), 5) for v in up], hfov=70.0, t=k))
        shots.append(dict(name=name, frames=fr))
    out.write_text(json.dumps(dict(fps=1, W=1920, H=1080, shots=shots), ensure_ascii=False)); print("[90] 联系表路径 →", out)


def main(a):
    if "--联系表" in a: return contact(a)
    out = pathlib.Path(a[0]); fps = int(a[a.index("--帧率") + 1]) if "--帧率" in a else 30
    t0 = float(a[a.index("--起") + 1]) if "--起" in a else 330.0
    t1 = float(a[a.index("--止") + 1]) if "--止" in a else 1160.0
    secs = [float(x) for x in a[a.index("--秒") + 1:a.index("--秒") + 4]] if "--秒" in a else [6.0, 6.0, 14.0]
    S = json.loads((g61.OUT/"scene.json").read_text()); cam = next(c for c in S["cameras"] if c["name"] == "人眼")
    pos = np.array(cam["pos"])
    seg = [(t0, 480.0, secs[0]), (480.0, 960.0, secs[1]), (960.0, t1, secs[2])]      # 日出段 / 白天 / 日落 + 暮光
    ts = []
    for m0, m1, sec in seg:
        n = int(sec*fps)
        ts += [m0 + (m1 - m0)*i/n for i in range(n)]
    ts.append(t1)
    fr = []; az_prev = None
    for m in ts:
        s = g61.sun_dir(f"{int(m)//60}:{int(m)%60}") if False else None
        H = math.radians((m/60 - 12)*15); p, d = math.radians(g61.LAT), g61.DECL
        s = np.array([-math.cos(d)*math.sin(H), math.cos(p)*math.sin(d) - math.sin(p)*math.cos(d)*math.cos(H), math.sin(p)*math.sin(d) + math.cos(p)*math.cos(d)*math.cos(H)])
        az = math.atan2(s[0], s[1])                                              # 北为 0、东为 +
        yaw = az + math.radians(12.0)                                            # 太阳在画面左边
        pit = math.radians(4.0)
        f = np.array([math.sin(yaw)*math.cos(pit), math.sin(pit), -math.cos(yaw)*math.cos(pit)])   # Godot：x 东、y 上、z 南
        r = np.cross(f, [0, 1, 0]); r /= np.linalg.norm(r); up = np.cross(r, f)
        fr.append(dict(pos=[round(float(v), 4) for v in pos], fwd=[round(float(v), 5) for v in f], up=[round(float(v), 5) for v in up],
                       hfov=60.0, t="%02d:%06.3f" % (int(m)//60, m % 60)))
    out.write_text(json.dumps(dict(fps=fps, W=1920, H=1080, shots=[dict(name="全日", frames=fr)]), ensure_ascii=False))
    print(f"[90] {len(fr)} 帧 {t0:.0f}–{t1:.0f} min → {out}")


if __name__ == "__main__":
    main(sys.argv[1:])
