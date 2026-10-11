#!/usr/bin/env python3
"""贴图随视角变化：在 3 个地面点各拍 3 张正下方俯拍 + 6 张斜视（实时画质，grain / preview 分支的 --实时截图）。
用法：贴图_取景.py <标签> <工作树(无空格路径)> [额外 godot 参数…]   输出 ~/贴图/out/<标签>/<点>_<模式>/斜视N_1307.png
点位与高度来自 点.json（由 --贴图高 打印得来）。每个点跑两次：lit（正常光照）、alb（--着色诊断=5 只看反照率）。"""
import json, math, os, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
P = json.load(open(os.path.join(HERE, "点.json")))
TOPS = [2.0, 8.0, 30.0]
DIST = [5.0, 20.0, 60.0]
ELEV = [25.0, 10.0]
W, H = 2560, 1440

def cams(sp):
    """返回 [(名, 参数串, 描述 dict)]。斜机位格式 E,N,离地高,朝向°,下俯°,hfov,W,H"""
    E, N, y0 = sp["E"], sp["N"], sp["y0"]
    out = []
    for h in TOPS:
        out.append((f"top{int(h)}", f"{E},{N},{h},0,89.9,60,{W},{H}", dict(kind="top", h=h)))
    for el in ELEV:
        for d in DIST:
            hc = y0 + d * math.tan(math.radians(el))          # 相机绝对高度
            gy = sp["cam_gy"][str(int(d))]
            pitch = math.degrees(math.atan2(hc - y0, d))
            out.append((f"obl{int(el)}_{int(d)}", f"{E},{N-d},{hc-gy:.4f},0,{pitch:.4f},60,{W},{H}", dict(kind="obl", D=d, el=el)))
    return out

if __name__ == "__main__":
    tag, wt = sys.argv[1], sys.argv[2]; extra = sys.argv[3:]
    only = os.environ.get("SPOTS")
    meta = {}
    for sname, sp in P.items():
        if only and sname not in only.split(","): continue
        cl = cams(sp)
        meta[sname] = [dict(name=n, **d) for n, _, d in cl]
        for mode, margs in (("lit", []), ("alb", ["--着色诊断=5"])):
            if os.environ.get("MODES") and mode not in os.environ["MODES"].split(","): continue
            out = os.path.expanduser(f"~/贴图/out/{tag}/{sname}_{mode}")
            log = os.path.expanduser(f"~/贴图/log/{tag}_{sname}_{mode}.log")
            os.makedirs(os.path.dirname(log), exist_ok=True)
            cmd = [os.path.expanduser("~/颗粒/rt.sh"), f"{W}x{H}", log, f"--实时截图={out}", "--等帧=150", "--斜机位=" + ";".join(c[1] for c in cl), "--石块=0"] + margs + extra
            env = dict(os.environ, WT=wt, TMO=os.environ.get("TMO", "420"))
            print("RUN", tag, sname, mode, flush=True)
            subprocess.run(cmd, env=env)
            n = len([f for f in os.listdir(out)]) if os.path.isdir(out) else 0
            print("  frames", n, flush=True)
    os.makedirs(os.path.expanduser(f"~/贴图/out/{tag}"), exist_ok=True)
    json.dump(meta, open(os.path.expanduser(f"~/贴图/out/{tag}/meta.json"), "w"), ensure_ascii=False, indent=1)
