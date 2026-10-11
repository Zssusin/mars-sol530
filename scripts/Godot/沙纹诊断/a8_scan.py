import importlib.util, numpy as np, json
spec=importlib.util.spec_from_file_location("m","scripts/Godot/80_沙纹场.py"); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
Z=dict(np.load("资料/沙纹/相位.npz")); cal=json.load(open("资料/沙纹/标定.json")); c=Z["c"]; az=Z["az"]; lam=Z["lam"]; n=c.shape[0]
cx,cy=-32,-185; S=34.6; nn=int(S/0.25)
xs=cx-S/2+(np.arange(nn)+0.5)*0.25; ys=cy+S/2-(np.arange(nn)+0.5)*0.25; X,Y=np.meshgrid(xs,ys)
fx=(X+1000)-0.5; fy=(Y+1000)-0.5; i0=np.floor(fx).astype(int); j0=np.floor(fy).astype(int); tx=fx-i0; ty=fy-j0
B=0
for dj in (0,1):
  for di in (0,1):
    i=i0+di; j=j0+dj; w=(tx if di else 1-tx)*(ty if dj else 1-ty)
    k=2*np.pi/lam[j,i]; B=B+w*np.real(c[j,i]*np.exp(1j*(k*np.sin(az[j,i])*(X-(i+0.5-1000))+k*np.cos(az[j,i])*(Y-(j+0.5-1000)))))
orig=m.profile_phase
for crest_dark in (False,True):
    out=[]
    for d in range(-90,91,15):
        m.profile_phase=lambda lee=0.3,d=d: np.radians(d)
        img=m.bake_arrays(Z,cal,(0.05,0.11,0.3,0.04),crest_dark); h,As,rho=m.rf_eval(img,1.0,X,-Y,0.3,0.3)
        mk=As>0.3; out.append((d,round(float(np.corrcoef(h[mk],B[mk])[0,1]),2)))
    print("crest_dark",crest_dark,out)
