import numpy as np, sys, pathlib
p = np.load(pathlib.Path.home()/"样张临时/全日2/mastcam/mastcam_profiles.npy", allow_pickle=True).item(); cen = p["cen"]
print("角距中心 °:", np.round(cen, 2))
for name, o in p["out"].items():
    print(f"## 太阳高 {o['el']:.2f}°  实测 B/R:", np.round(o["obs"][2]/o["obs"][0], 2), " 实测 G I/F:", np.round(o["obs"][1], 2))
    for vn, m in o["model"].items():
        br = m[2]/m[0]; ro = o["obs"][2]/o["obs"][0]
        print(f"  {vn[:24]:26s} B/R {np.round(br, 2)}  |ln(B/R模/实)|均值 {np.mean(abs(np.log(br/ro))):.2f}  G亮度 模/实 几何均值 {np.exp(np.mean(np.log(m[1]/o['obs'][1]))):.2f}  （0.8°–2.8°: {np.exp(np.mean(np.log(m[1][:4]/o['obs'][1][:4]))):.2f}）")
