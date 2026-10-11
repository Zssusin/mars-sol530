import importlib.util, numpy as np, json
spec=importlib.util.spec_from_file_location("m","scripts/Godot/80_沙纹场.py"); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
Z=dict(np.load("资料/沙纹/相位.npz")); c=Z["c"]; az=Z["az"]; lam=Z["lam"]; Aw=Z["a"]; n=c.shape[0]
img,cell,meta=m.load_field(); I=np.flipud(np.asarray(m.ortho(),np.float32))
cx,cy=-32,-185; S=34.6; nn=int(S/0.25)
xs=cx-S/2+(np.arange(nn)+0.5)*0.25; ys=cy+S/2-(np.arange(nn)+0.5)*0.25; X,Y=np.meshgrid(xs,ys)
hh,As,rho=m.rf_eval(img,cell,X,-Y,meta["H"],meta["lee"])
# 亮度重建：同样 4 格双线性、平面波外推；Z 行0=南 → 行 j ↔ y=j+0.5-1000
fx=(X+1000)/1.0-0.5; fy=(Y+1000)/1.0-0.5; i0=np.floor(fx).astype(int); j0=np.floor(fy).astype(int); tx=fx-i0; ty=fy-j0
B=0
for dj in (0,1):
  for di in (0,1):
    i=i0+di; j=j0+dj; w=(tx if di else 1-tx)*(ty if dj else 1-ty)
    k=2*np.pi/lam[j,i]; kx=k*np.sin(az[j,i]); ky=k*np.cos(az[j,i]); cxc=i+0.5-1000; cyc=j+0.5-1000
    B=B+w*np.real(c[j,i]*np.exp(1j*(kx*(X-cxc)+ky*(Y-cyc))))
c0=int((cx-S/2+1000)*4); r0=int((1000-(cy+S/2))*4)
O=np.nan_to_num(I[r0:r0+nn,c0:c0+nn],nan=0.3); P=np.pad(np.log(np.clip(O,0.02,None)),((0,1024-nn),(0,1024-nn)),mode="reflect"); fb=m.bandpass_tile(P)[0][:nn,:nn]
mk=As>0.3
print("corr(B_model, HiRISE bp)",np.corrcoef(B[mk],fb[mk])[0,1].round(3)," corr(h,B_model)",np.corrcoef(hh[mk],B[mk])[0,1].round(3)," corr(h,fb)",np.corrcoef(hh[mk],fb[mk])[0,1].round(3), "a sign meta",meta.get("冠暗"))
H=meta["H"]; s1=hh/H*2   # = 2 As g (f-0.5)
print("std B_model(mask) %.4f  std stripe per unit alb %.4f  std fb %.4f"%(B[mk].std(),s1[mk].std(),fb[mk].std()))
print("需要的 alb（反照率部分 = 0.85·std B）: %.3f"%(0.85*B[mk].std()/s1[mk].std()))
# 全检出格（A>0.5）的 |c| 与 As：条纹 = alb·As 的幅度
