import numpy as np
from scipy.ndimage import gaussian_filter
d=np.load("资料/地貌参数/dtm_enu_1m.npy").astype(np.float64)
h=d-gaussian_filter(d,10.0)                  # 去 >~20 m 的地形
Z=np.load("资料/沙纹/相位.npz"); az=Z["az"];lam=Z["lam"];A=Z["a"];c=Z["c"];rho=Z["rho"]
pc=__import__("json").load(open("资料/地貌参数/pc_calib.json")); cal=__import__("json").load(open("资料/沙纹/标定.json"))
rows,cols=np.nonzero((A>0.5)&(lam>2.6)&(rho>0.6)&(np.abs(c)>0))
print("cells",len(rows))
R=7; yy,xx=np.mgrid[-R:R+1,-R:R+1].astype(float)   # 行=北,列=东（DTM 行0=南）
out=[]
hp=np.pad(h,R)
for r,cc in zip(rows,cols):
    P_=hp[r:r+2*R+1,cc:cc+2*R+1]
    l=lam[r,cc];a=az[r,cc];kx=2*np.pi/l*np.sin(a);ky=2*np.pi/l*np.cos(a)
    g=np.exp(-(xx**2+yy**2)/(2*(0.45*l)**2)); e=np.exp(-1j*(kx*xx+ky*yy))
    out.append(2*(g*P_*e).sum()/g.sum())
hc=np.array(out); cc_=c[rows,cols]; l=lam[rows,cols]; a=az[rows,cols]
Ibar=cal["Ibar"]; k=2*np.pi/l
bk=cal["bx_log"]*k*np.sin(a)+cal["by_log"]*k*np.cos(a)
ratio=cc_/hc
for lo,hi in [(2.6,3.0),(3.0,3.5),(3.5,5)]:
    m=(l>=lo)&(l<hi)&(np.abs(hc)>0.002)
    if m.sum()<50: continue
    ph=np.angle(ratio[m]); print(lo,hi,m.sum(),"cos(phase) mean",np.cos(ph).mean().round(3),"median |ratio|",np.median(np.abs(ratio[m])).round(2),"|hc| med cm",np.median(np.abs(hc[m])*100).round(2),"median |a+ibk|",np.median(np.abs(cal["a"]+1j*bk[m])).round(2), "cos pred(a>0)",np.cos(np.angle(cal["a"]+1j*bk[m])).mean().round(3))
    # sensitivity to bk: low bk subset -> sign of a
    q=np.abs(bk)<np.quantile(np.abs(bk),0.4); mm=m&q
    print("  low |bk| subset",mm.sum(),np.cos(np.angle(ratio[mm])).mean().round(3), " frac cos>0",(np.cos(np.angle(ratio[mm]))>0).mean().round(3))
print("median |hc| overall cm",np.median(np.abs(hc))*100, "p90",np.percentile(np.abs(hc),90)*100)
