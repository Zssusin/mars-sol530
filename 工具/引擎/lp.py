# lp.py A.png B.png：有符号平均差、按 16 px 块平均后的差（结构 / 亮度偏差）、高频残差能量比（B 的细节相对 A）
import sys, numpy as np
from PIL import Image
a = np.asarray(Image.open(sys.argv[1]).convert("L")).astype(float); b = np.asarray(Image.open(sys.argv[2]).convert("L")).astype(float)
H, W = a.shape; k = 16; h, w = H//k*k, W//k*k
A = a[:h, :w].reshape(h//k, k, w//k, k).mean((1, 3)); B = b[:h, :w].reshape(h//k, k, w//k, k).mean((1, 3))
ha = a[:h, :w] - np.kron(A, np.ones((k, k))); hb = b[:h, :w] - np.kron(B, np.ones((k, k)))
# 只看下半幅（地面）
s = slice(h//2, h)
print("有符号平均差 %.3f DN；16px 块均值差 |平均| %.3f DN、>2 DN %.2f%%；高频细节标准差 A %.2f B %.2f（比 %.3f）" % ((b - a).mean(), np.abs(B - A).mean(), (np.abs(B - A) > 2).mean()*100, ha[s].std(), hb[s].std(), hb[s].std()/ha[s].std()))
