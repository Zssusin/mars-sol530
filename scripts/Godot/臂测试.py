# 收臂测试：取车辆路径第一帧的车身位姿，前 / 左前 / 顶三台相机
import json, numpy as np, sys
P = json.load(open(sys.argv[1])); fr = P["shots"][0]["frames"][0]["rover"]
B = np.array(fr["b"]).T; o = np.array(fr["o"]); F, L, Y = B[:, 2], B[:, 0], B[:, 1]
def cam(pos, tgt, name):
    f = tgt - pos; f /= np.linalg.norm(f); r = np.cross(f, [0, 1, 0]); r /= np.linalg.norm(r); u = np.cross(r, f)
    return dict(name=name, frames=[dict(pos=pos.tolist(), fwd=f.tolist(), up=u.tolist(), hfov=50.0, t="15:00", rover=fr)])
c = o + Y*0.8
shots = [cam(c + F*4.5 + Y*0.6, c, "前"), cam(c + F*3.0 + L*3.0 + Y*1.2, c, "左前"), cam(c + F*3.0 - L*3.0 + Y*1.2, c, "右前"),
         cam(c + Y*5.0 + F*0.3, c + F*0.3, "顶")]
json.dump(dict(fps=1, W=960, H=540, shots=shots), open(sys.argv[2], "w"), ensure_ascii=False)
