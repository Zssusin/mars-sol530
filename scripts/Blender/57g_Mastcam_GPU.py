"""
Mastcam-Z 第二遍（累积）的 GPU 版（PyTorch，测试机）：逐步对应 57_实景重建.py mastcam_albedo() 的 ②，
只把每帧的投影（CAHVOR）、深度缓冲、车体盒求交、金字塔取色、颜色检验、累加，以及按太阳的阴影，搬到显卡上；
读图（read_z）、Ground 几何（高度、法线、天空可见度）、Navcam 参考仍用 57 的函数。
比 CPU 版多两处（去拼接缝，2026-10-05）：金字塔层间线性过渡、画面边缘 40 px 羽化。CPU 版的 ② 不再维护，正式用这个。
配准（①）不重算：读 57 写的 mastcam_配准.json（须是全量），按 57 现行规则重做增益/平移修正（NaN 帧平移清零）。
运行：.venv/bin/python scripts/Blender/57g_Mastcam_GPU.py [中] [近] [--正式] [--不检颜色]   # 默认写 反照率Z_<层>_gpu.npz；--正式 覆盖 反照率Z_<层>.npz
     .venv/bin/python scripts/Blender/57g_Mastcam_GPU.py 对照                   # 与 CPU 版 反照率Z_<层>.npz 逐格比
"""
import concurrent.futures as cf, importlib.util, json, math, pathlib, sys, time
import numpy as np
import torch

HERE = pathlib.Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("m57", HERE/"57_实景重建.py")
M = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(M)
OUT = M.OUT
dev = torch.device("cuda")
CHECK = True                                                             # 颜色一致性检验（--不检颜色 关掉，对照用）
FEATHER = 40.0                                                           # 边缘羽化宽度（合并后像素）
DIAG = None; DIAGS = []                                                  # --诊断 x0 x1 y0 y1（ENU m）：列出往这块区域贴得最亮的帧
SOLS = (0, 9999)                                                         # 只用这个 sol 范围的帧（--sol 502 530，诊断用）
F64, F32 = torch.float64, torch.float32


def log(*a): print("[57g]", *a, flush=True)


def T(a, dt=F32): return torch.as_tensor(np.ascontiguousarray(a), dtype=dt, device=dev)


def cahvor(cam, P):
    """同 57.cahvor，P 为 (m, 3) float64 张量（站点系）。"""
    C, A, H, V, O = (cam["_t"][k] for k in "CAHVO"); R = cam["R"]
    p = P - C; lam = p @ O
    rho = p - lam[:, None]*O; tau = (rho*rho).sum(1)/torch.clamp(lam*lam, min=1e-12)
    mu = R[0] + R[1]*tau + R[2]*tau*tau
    pp = p + mu[:, None]*rho; den = pp @ A
    return (pp @ H)/den, (pp @ V)/den, den


class GroundGPU:
    """57.Ground 的数据搬上显卡；阴影在显卡上算（同 57.shadow 的步进）。"""
    def __init__(self, G):
        self.G = G; self.n, self.cs = G.n, G.cs
        self.Z2 = T(G.Z); self.Z = self.Z2.reshape(-1)
        self.N = T(G.N.reshape(-1, 3)); self.K = T(G.K.reshape(-1)); self.under = T(G.under, torch.bool)
        self.c = T(M.grid_xy(G.cs, G.n), F64)
        self.bc = T(G.bc, F64); self.br, self.B, self.nb = G.br, G.B, G.nb
        self.sh = {}

    def site(self, idx):                                                   # 格 → 站点系（ENU (x, y, z) → (y, x, −z) + O_LL）
        x = self.c[idx % self.n]; y = self.c[idx//self.n]; z = self.Z[idx].double()
        return torch.stack([y, x, -z], 1) + T(M.O_LL, F64)

    def enu(self, idx):
        return torch.stack([self.c[idx % self.n], self.c[idx//self.n], self.Z[idx].double()], 1)

    def cells_of_blocks(self, blocks):
        B, nb, n = self.B, self.nb, self.n
        o = torch.arange(B, device=dev)
        rows = (blocks//nb)[:, None, None]*B + o[None, :, None]; cols = (blocks % nb)[:, None, None]*B + o[None, None, :]
        return (rows*n + cols).reshape(-1)

    def shade(self, sun):
        key = (round(sun[0]), round(sun[1]))
        if key not in self.sh:
            if len(self.sh) > 24: self.sh.pop(next(iter(self.sh)))
            s = M.sun_enu(*key); Z = self.Z2; n0, n1 = Z.shape
            h = math.hypot(s[0], s[1]); dx, dy = s[0]/h, s[1]/h; tn = s[2]/h
            V = torch.ones_like(Z, dtype=torch.bool); t = 1
            a0 = torch.arange(n0, device=dev); a1 = torch.arange(n1, device=dev)
            while t*self.cs <= 4.0:
                r = (a0 + int(round(t*dy))).clamp(0, n0 - 1); c = (a1 + int(round(t*dx))).clamp(0, n1 - 1)
                V &= Z[r][:, c] <= Z + t*self.cs*tn
                t += max(1, t//20)
            d = torch.clamp(self.N @ T(s), min=0)*V.reshape(-1)
            self.sh[key] = torch.floor(d*255 + 0.5).to(torch.uint8)       # 与 CPU 版同样量化成 8 位
        return self.sh[key]


def rays_hit_rover(C, P):
    """同 57.rays_hit_rover：线段 C→P（ENU，张量）是否穿过车体盒（车体系 slab）。"""
    Rb = T(M.rover_R(), F64); MSB = T(M.M_SB, F64); fz = T([1, 1, -1.0], F64)
    to_b = lambda q: (q @ MSB @ Rb)*fz
    C = C.expand_as(P); hit = torch.zeros(len(P), dtype=torch.bool, device=dev)
    c0 = T([0.0, 0.0, 0.9], F64)
    dc = P - C; t = torch.clamp(((c0 - C)*dc).sum(1)/torch.clamp((dc*dc).sum(1), min=1e-12), 0, 1)
    near = torch.linalg.norm(C + t[:, None]*dc - c0, dim=1) < 3.2
    if not near.any(): return hit
    c = to_b(C[near]); d = to_b(P[near]) - c
    d = torch.where(d.abs() < 1e-9, torch.full_like(d, 1e-9), d)
    h = torch.zeros(len(d), dtype=torch.bool, device=dev)
    for (xa, xb), (ya, yb), (za, zb) in M.ROVER_BOXES_TIGHT:
        lo = (T([xa, ya, za], F64) - c)/d; hi = (T([xb, yb, zb], F64) - c)/d
        tmin = torch.minimum(lo, hi).amax(1); tmax = torch.maximum(lo, hi).amin(1)
        h |= (tmax >= torch.clamp(tmin, min=0.0)) & (tmin <= 1.0)
    hit[near] = h
    return hit


def fixed_meta():
    mp = OUT/"mastcam_配准.json"; meta = json.loads(mp.read_text())
    if not meta.pop("_全量", False): sys.exit("mastcam_配准.json 不是全量配准：先跑 57 Mastcam（不带帧数）")
    seqg = {}                                                              # 下面两段与 57 ① 之后的修正逐字一致
    for v in meta.values():
        if v.get("ok") and v.get("g") and (v.get("ncc") or 0) > 0.4: seqg.setdefault(v["seq"], []).append(v["g"])
    allg = float(np.median([g for gs in seqg.values() for g in gs])) if seqg else 1.0
    for v in meta.values():
        if not v.get("ok"): continue
        nc = v.get("ncc"); nc = None if nc is None or not np.isfinite(nc) else nc
        if not (v.get("g") and (nc or 0) > 0.4): v["g"] = float(np.median(seqg.get(v["seq"], [allg])))
        if nc is None or nc < 0.2 or (max(abs(v["shift"][0]), abs(v["shift"][1])) > 40 and nc < 0.5): v["shift"] = (0.0, 0.0)
    return meta


def accumulate(lv, meta, nav, beta, proxy, formal=False):
    from scipy.ndimage import gaussian_filter
    t0 = time.time()
    G = M.Ground(*M.ZALB[lv]); g = GroundGPU(G); n = G.n
    log(f"{lv}层格 {n}²×{G.cs} m 就绪（{time.time() - t0:.0f} s）")
    nv_ = nav[lv]; An_ = nv_["A"].astype(np.float32); csn_, nn_ = float(nv_["cs"]), int(nv_["n"])
    cg = M.grid_xy(G.cs, n); NREF = np.empty((n*n, 3), np.float32)
    for ch in range(3):
        g_ = gaussian_filter(np.where(nv_["cov"] > 0, An_[..., ch], 0), 0.1/csn_)/np.maximum(gaussian_filter((nv_["cov"] > 0).astype(np.float32), 0.1/csn_), 1e-3)
        for r0 in range(0, n, 500):
            Xr, Yr = np.meshgrid(cg, cg[r0:r0 + 500])
            NREF[r0*n:(r0 + Xr.shape[0])*n, ch] = M.sample(g_, csn_, nn_, Xr.ravel(), Yr.ravel())
    hasref = M.sample((gaussian_filter((nv_["cov"] > 0).astype(np.float32), 0.1/csn_) > 0.5).astype(np.float32), csn_, nn_, *[a.ravel() for a in np.meshgrid(cg, cg)]) > 0.5
    NREF = T(NREF); hasref = T(hasref, torch.bool)
    S1 = torch.zeros((n*n, 3), dtype=F32, device=dev); S0 = torch.zeros(n*n, dtype=F32, device=dev)
    xmls = [x for x in sorted(M.ZDIR.glob("Z*.xml")) if meta.get(x.stem, {}).get("ok")]
    log(f"{lv}层：{len(xmls)} 帧，Navcam 参考就绪（{time.time() - t0:.0f} s）")
    nbad = nused = 0; tz = time.time()
    with cf.ThreadPoolExecutor(2) as ex:                                   # 读图（CPU/硬盘）和显卡计算重叠
        futs = [ex.submit(M.read_z, x) for x in xmls[:3]]; nxt = 3
        for fi in range(len(xmls)):
            z = futs[fi].result(); futs[fi] = None
            if nxt < len(xmls): futs.append(ex.submit(M.read_z, xmls[nxt])); nxt += 1
            if z is None or not (SOLS[0] <= z["sol"] <= SOLS[1]): continue
            v = meta[z["name"]]; cam = z["cam"]
            cam["_t"] = {k: T(cam[k], F64) for k in "CAHVO"}
            img = T(z["img"]); h, w = img.shape[:2]; sx, sy = v["shift"]
            pyr = [img]
            for _ in range(3):
                a = torch.nan_to_num(pyr[-1])[:pyr[-1].shape[0]//2*2, :pyr[-1].shape[1]//2*2]
                pyr.append(a.reshape(a.shape[0]//2, 2, a.shape[1]//2, 2, 3).mean((1, 3)))
            # z_project：1 m 块剔视锥 → 块内各格
            fpx = float(np.linalg.norm(cam["H"] - (cam["H"] @ cam["A"])*cam["A"])/2)
            x, y, d = cahvor(cam, g.bc)
            bx = (x - cam["fs"] - 0.5)/2 + sx; by = (y - cam["fl"] - 0.5)/2 + sy
            rb = torch.linalg.norm(g.bc - cam["_t"]["C"], dim=1); mg = g.br*fpx/torch.clamp(rb, min=0.3) + 4
            keep = torch.nonzero((d > 0.3) & (bx > -mg) & (by > -mg) & (bx < w + mg) & (by < h + mg)).squeeze(1)
            if not keep.numel(): continue
            gi = g.cells_of_blocks(keep); P = g.site(gi)
            x, y, d = cahvor(cam, P)
            bx = (x - cam["fs"] - 0.5)/2 + sx; by = (y - cam["fl"] - 0.5)/2 + sy
            ok = (d > 0.5) & (bx >= 1) & (by >= 1) & (bx < w - 2) & (by < h - 2)
            gi, P, bx, by = gi[ok], P[ok], bx[ok], by[ok]
            if not gi.numel(): continue
            rr = torch.linalg.norm(P - cam["_t"]["C"], dim=1); fp = G.cs*fpx/rr
            # 深度缓冲（地面 + 车体代理点），3×3 取最小
            # 深度缓冲：每格按自己在画面上的投影大小溅射（横向 fp、纵向 fp×cosθ，θ＝视线与地面法线夹角）。
            # 原来每格只写中心一个像素：长焦近拍（臂工作区，63 mm、2 m）时一格占几十像素，满是空洞，
            # 远处 4–8 m 的格从空洞里漏进来、被贴上工作区亮基岩的颜色 → 地上一道道弧形「划痕」
            k = 2; Wk, Hk = w//k + 1, h//k + 1
            zb = torch.full((Wk*Hk,), float("inf"), dtype=F32, device=dev)
            pxk = (bx/k).long(); pyk = (by/k).long(); pix = pyk*Wk + pxk; rrf = rr.float()
            nE = g.N[gi]; nS = torch.stack([nE[:, 1], nE[:, 0], -nE[:, 2]], 1).double()       # 法线 ENU → 站点系
            cth = ((cam["_t"]["C"] - P)*nS).sum(1).abs()/rr
            hx = torch.clamp(torch.ceil(fp/(2*k) - 0.5), 0, 12).long(); hy = torch.clamp(torch.ceil(fp*cth/(2*k) - 0.5), 0, 12).long()
            zb.scatter_reduce_(0, pix, rrf, "amin")
            big = torch.nonzero((hx > 0) | (hy > 0)).squeeze(1)
            if big.numel():
                key = hx[big]*13 + hy[big]
                for kv in torch.unique(key).tolist():
                    sel = big[key == kv]; ax, ay = kv//13, kv % 13; X, Y, D = pxk[sel], pyk[sel], rrf[sel]
                    for dy in range(-ay, ay + 1):
                        yy = (Y + dy).clamp(0, Hk - 1)*Wk
                        for dx in range(-ax, ax + 1):
                            zb.scatter_reduce_(0, yy + (X + dx).clamp(0, Wk - 1), D, "amin")
            px, py, pd = cahvor(cam, proxy)
            pbx = (px - cam["fs"] - 0.5)/2 + sx; pby = (py - cam["fl"] - 0.5)/2 + sy
            okp = (pd > 0.05) & (pbx >= 0) & (pby >= 0) & (pbx < w - 1) & (pby < h - 1)
            zb.scatter_reduce_(0, (pby[okp]/k).long()*Wk + (pbx[okp]/k).long(), torch.linalg.norm(proxy[okp] - cam["_t"]["C"], dim=1).float(), "amin")
            zb = -torch.nn.functional.max_pool2d(-zb.reshape(1, 1, Hk, Wk), 3, 1, 1).reshape(-1)
            vis = (rr <= zb[pix].double() + 0.02 + 0.01*rr) & ~g.under[gi]
            # 视线穿车体（从相机外 0.35 m 起算）
            iv = torch.nonzero(vis).squeeze(1)
            if iv.numel():
                Pe = g.enu(gi[iv]); Ce = T(M.to_enu(cam["C"][None])[0], F64)
                u = Pe - Ce; u = u/torch.linalg.norm(u, dim=1, keepdim=True)
                vis[iv[rays_hit_rover(Ce + 0.35*u, Pe)]] = False
            gi, bx, by, rr, fp = gi[vis], bx[vis], by[vis], rr[vis], fp[vis]
            if not gi.numel(): continue
            direct = g.shade(z["sun"])[gi].float()/255
            sh = direct + beta*g.K[gi]
            # 金字塔层间线性过渡（三线性）：原来按足迹在层间硬切，切换处是以相机为圆心的等距圈 → 地上一道道弧线
            lf = torch.clamp(torch.log2(torch.clamp(fp, min=1)), 0, 3)
            l0 = torch.clamp(torch.floor(lf), 0, 2).long(); tl = (lf - l0).float()[:, None]
            def bil(L, sel):
                a = pyr[L]
                xx = torch.clamp((bx[sel] + 0.5)/2**L - 0.5, 0, a.shape[1] - 1.001); yy = torch.clamp((by[sel] + 0.5)/2**L - 0.5, 0, a.shape[0] - 1.001)
                i0 = yy.long(); j0 = xx.long(); fy = (yy - i0).float()[:, None]; fx = (xx - j0).float()[:, None]
                return a[i0, j0]*(1 - fy)*(1 - fx) + a[i0 + 1, j0]*fy*(1 - fx) + a[i0, j0 + 1]*(1 - fy)*fx + a[i0 + 1, j0 + 1]*fy*fx
            col = torch.zeros((gi.numel(), 3), dtype=F32, device=dev)
            for L in range(3):
                m = l0 == L
                if not m.any(): continue
                c0, c1 = bil(L, m), bil(L + 1, m)
                col[m] = torch.where(tl[m] < 1e-6, c0, c0*(1 - tl[m]) + c1*tl[m])   # 第 0 层带 NaN（坏像素），纯第 0 层时不让 NaN 混进来
            good = torch.isfinite(col).all(1) & (col.amin(1) > 0) & (sh > 0.05)
            alb = col/(v["g"]*sh[:, None])
            wgt = torch.clamp(fp.float(), max=1.0)**2*(0.03 + 0.97*torch.clamp(direct/0.3, 0, 1))*(1.0 if (v.get("ncc") or 0) > 0.4 else 0.3)
            # 边缘羽化：样本离画面边缘 40 px（合并后）内权重平滑降到 0 —— 全景里各帧上下边是等仰角线，投到地上是绕桅杆的弧，曝光差一点就是一道缝
            e = torch.minimum(torch.minimum(bx, by), torch.minimum(w - 1 - bx, h - 1 - by)).float()
            fe = torch.clamp(e/FEATHER, 0, 1); wgt = wgt*fe*fe*(3 - 2*fe)
            m = good & (alb.amax(1) < 1.2)
            ref = NREF[gi]; hr = hasref[gi] & (ref.amin(1) > 1e-4)
            lr = torch.log(torch.clamp(alb.mean(1), min=1e-4)/torch.clamp(ref.mean(1), min=1e-4))
            chd = (alb/torch.clamp(alb.sum(1, keepdim=True), min=1e-6) - ref/torch.clamp(ref.sum(1, keepdim=True), min=1e-6)).abs().amax(1)
            sel = m & hr
            if CHECK and int(sel.sum()) > 200 and float(((lr[sel].abs() < 0.7) & (chd[sel] < 0.05)).float().mean()) < 0.5:
                nbad += 1; continue
            if CHECK: m &= ~hr | ((lr.abs() < 1.0) & (chd < 0.08))
            if DIAG:                                                       # 诊断：这一帧落进可疑区域（ENU 矩形）的样本，比 Navcam 亮多少
                xe = g.c[gi % n]; ye = g.c[gi//n]; x0, x1, y0, y1 = DIAG
                rg = m & hr & (xe >= x0) & (xe <= x1) & (ye >= y0) & (ye <= y1)
                if int(rg.sum()) > 500: DIAGS.append((z["name"], z["sol"], int(rg.sum()), float(lr[rg].median()), float((lr[rg] > 0.25).float().mean()), float(wgt[rg].sum())))
            S0.index_add_(0, gi[m], wgt[m]); S1.index_add_(0, gi[m], alb[m]*wgt[m, None]); nused += 1
            if fi % 200 == 0: log(f"  {lv} {fi}/{len(xmls)}：{z['name'][:30]}（{time.time() - tz:.0f} s）")
    torch.cuda.synchronize()
    log(f"{lv}层：用 {nused} 帧，{nbad} 帧颜色与 Navcam 不符整帧丢弃；累加 {time.time() - tz:.0f} s，显存峰值 {torch.cuda.max_memory_allocated()/1e9:.1f} GB")
    S0 = S0.cpu().numpy(); S1 = S1.cpu().numpy()
    A = (S1/np.maximum(S0, 1e-12)[:, None]).reshape(n, n, 3); cov = S0.reshape(n, n)
    return G, A, cov


def save(lv, G, A, cov, nav, z_scale, formal):
    """定标与存盘，同 57 ② 末尾。"""
    nv = nav[lv]; An = nv["A"].astype(np.float32); csn_, nn_ = float(nv["cs"]), int(nv["n"])
    c = M.grid_xy(G.cs, G.n); X, Y = np.meshgrid(c, c)
    m = (cov.ravel() > 0) & (np.abs(X.ravel()) < csn_*nn_/2) & (np.abs(Y.ravel()) < csn_*nn_/2)
    a_n = np.stack([M.sample(An[..., ch], csn_, nn_, X.ravel()[m], Y.ravel()[m], order=1) for ch in range(3)], -1)
    okn = M.sample(nv["cov"], csn_, nn_, X.ravel()[m], Y.ravel()[m], order=0) > 0
    scale = np.median(a_n[okn]/np.maximum(A.reshape(-1, 3)[m][okn], 1e-6), 0) if okn.sum() > 1000 else np.ones(3)
    A = A*(z_scale if (lv == "近" and z_scale is not None) else scale)
    f = OUT/(f"反照率Z_{lv}.npz" if formal else f"反照率Z_{lv}_gpu{'' if CHECK else '_不检'}{'' if SOLS == (0, 9999) else f'_sol{SOLS[0]}-{SOLS[1]}'}.npz")
    np.savez_compressed(f, A=A.astype(np.float16), cov=cov.astype(np.float32), cs=G.cs, n=G.n, scale=scale)
    log(f"→ {f.name}：有覆盖 {np.mean(cov > 0)*100:.0f}%，对 Navcam 定标 {np.round(scale, 2)}")
    return scale


def compare():
    for lv in ("中", "近"):
        a, b = OUT/f"反照率Z_{lv}.npz", OUT/f"反照率Z_{lv}_gpu.npz"
        if not (a.exists() and b.exists()): log(f"{lv}：缺文件，跳过"); continue
        A, B = np.load(a), np.load(b)
        ca, cb = A["cov"] > 0, B["cov"] > 0; both = ca & cb
        d = np.abs(A["A"].astype(np.float32) - B["A"].astype(np.float32)).max(-1)[both]
        log(f"{lv}：覆盖 CPU {ca.mean()*100:.1f}% / GPU {cb.mean()*100:.1f}%，只有一边有 {np.mean(ca ^ cb)*100:.2f}%；"
            f"两边都有处 |Δ反照率| 中位 {np.median(d):.4f}，99% {np.percentile(d, 99):.4f}，>0.01 的 {np.mean(d > 0.01)*100:.2f}%；"
            f"定标 CPU {np.round(A['scale'], 3)} GPU {np.round(B['scale'], 3)}")


if __name__ == "__main__":
    a = sys.argv[1:]
    if a and a[0] == "对照": compare(); sys.exit()
    lvs = [x for x in ("中", "近") if x in a] or ["中", "近"]
    formal = "--正式" in a; CHECK = "--不检颜色" not in a
    if "--sol" in a: i = a.index("--sol"); SOLS = (int(a[i + 1]), int(a[i + 2]))
    if "--诊断" in a: i = a.index("--诊断"); DIAG = tuple(float(x) for x in a[i + 1:i + 5])
    nav = {lv: np.load(OUT/f"反照率_{lv}.npz") for lv in ("近", "中")}
    r_ = nav["近"]["b"]/np.maximum(nav["近"]["a"], 1e-9); beta = float(np.median(r_[np.isfinite(r_)]))
    meta = fixed_meta(); proxy = T(M.enu_to_site(M.rover_proxy()), F64)
    log(f"配准缓存 {sum(1 for v in meta.values() if v.get('ok'))} 帧可用，β = {beta:.2f}，{torch.cuda.get_device_name(0)}")
    z_scale = None
    for lv in ("中", "近"):                                                # 近层定标沿用中层（同 57）
        if lv not in lvs: continue
        G, A, cov = accumulate(lv, meta, nav, beta, proxy, formal)
        sc = save(lv, G, A, cov, nav, z_scale, formal)
        if lv == "中": z_scale = sc
        del G, A, cov; torch.cuda.empty_cache()
    if DIAG:
        DIAGS.sort(key=lambda r: -r[4]*r[5])
        log("诊断区域 x∈[%g, %g] y∈[%g, %g]：按「偏亮比例 × 权重」排前 20" % DIAG)
        for r in DIAGS[:20]: log(f"  {r[0][:34]} sol {r[1]}  样本 {r[2]:>7}  中位 log 亮度比 {r[3]:+.2f}  偏亮(>×1.28) {r[4]*100:4.0f}%  权重 {r[5]:.0f}")
