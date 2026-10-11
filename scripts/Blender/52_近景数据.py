"""
近景（火星车视角）数据：HiRISE 2 m 高程 + 0.5 m 正射影像 + 程序撒石（venv 里跑）。

为什么要单做：50/51 的高程 200 m、影像 82 m，离地两米看就是一团泥。火星车照片的真实感来自米到厘米级的东西——
石块、砾石、沙纹、层理。思路同 NASA/JPL MARTIAN：近处直接用 HiRISE 立体像对做的 DTM 和正射影像，
再往下（< 0.5 m）的石块、沙纹、层理用统计规律和程序细节补。

数据（第一次运行联网下载到 DEM/HiRISE/<名>/）：
- HiRISE DTM「Melas_Chasma_2891E_131S」（ESP_031125_1670 / ESP_031903_1670，2 m 一格，−2771…−1175 m，
  与 MOLA 平均差 −0.01 m），梅拉斯深谷南部的浅色层状沉积：北边台地、中间陡坎、南边沙丘。
- 正射影像 RED（全色）：0.5 m（相机前方一块）与 2 m（整条）。

处理：
1. 去烘焙光影：照片是下午拍的，自带光影。用 DTM 法线回归出拍摄时的太阳方向（亮度 ≈ a + b·max(n·s, 0)），
   把这部分光影从影像里减掉，免得和渲染的光影叠两遍（2 m 以下的光影减不掉，石块的影子会留着）。
2. 材质分区：沙（暗、平滑）、基岩（亮或陡）、风化层（其余）。
3. 撒石：Golombek & Rapp (1997) 的石块丰度模型，累计覆盖率 F(D) = k·exp(−q·D)，q = 1.79 + 0.152/k；
   基岩区 k = 0.06、风化层 0.03、沙上不撒。按离相机远近分三档最小直径（近处 4 cm，远处 0.6 m），只撒在视野里。
产出：DEM/Blender缓存/<镜头>/near_*.npy、rocks.npz、near.json
运行：./.venv/bin/python scripts/Blender/52_近景数据.py [--shot 梅拉斯层状沉积]
"""
import argparse, json, math, pathlib, subprocess, sys, time
import numpy as np
from scipy import ndimage
HERE = pathlib.Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parent)]
import 制图公共 as M
import 镜头 as K

HIRISE = {
    "Melas_2891E_131S": dict(
        url="https://www.uahirise.org/PDS/DTM/ESP/ORB_031100_031199/ESP_031125_1670_ESP_031903_1670",
        dtm="DTEED_031125_1670_031903_1670_A01.IMG",
        ortho_b="ESP_031125_1670_RED_B_01_ORTHO.JP2", ortho_d="ESP_031125_1670_RED_D_01_ORTHO.JP2",
        # 拍摄时太阳（RDR 标签 ESP_031125_1670_RED.LBL：SUB_SOLAR_AZIMUTH 157.27°（图像里从右顺时针，北在 270°）
        # → 罗盘方位 247.3°；INCIDENCE_ANGLE 38.41° → 高度 51.6°；当地 14:36，Ls 284°）
        sun=(247.3, 51.6)),
}
CACHE = M.MAP_DIR/"DEM"/"Blender缓存"
SEED = 2101


def fetch(name):
    h = HIRISE[name]
    d = M.MAP_DIR/"DEM"/"HiRISE"/name
    d.mkdir(parents=True, exist_ok=True)
    for k in ("dtm", "ortho_b", "ortho_d"):
        f = d/h[k]
        if not f.exists() or f.stat().st_size < 1e6:
            print("  下载", h[k]); subprocess.run(["curl", "-sS", "-o", str(f), f"{h['url']}/{h[k]}"], check=True)
    return d, h


class Geo:
    """HiRISE 等距圆柱：x = R·(λ − λ0)·cos φts，y = R·φ。"""
    def __init__(self, ds):
        crs = ds.crs.to_wkt()
        import re
        self.R = float(re.search(r'SPHEROID\["[^"]*",([0-9.]+)', crs).group(1))
        self.lon0 = float(re.search(r'central_meridian",([-0-9.]+)', crs).group(1))
        self.lat_ts = float(re.search(r'standard_parallel_1",([-0-9.]+)', crs).group(1))
        self.T = ds.transform

    def lonlat(self, row, col, T=None):
        T = T or self.T
        x = T.c + (np.asarray(col) + 0.5)*T.a; y = T.f + (np.asarray(row) + 0.5)*T.e
        lon = self.lon0 + np.degrees(x/(self.R*math.cos(math.radians(self.lat_ts))))
        return lon, np.degrees(y/self.R)

    def rowcol(self, lon, lat, T=None):
        T = T or self.T
        x = np.radians(np.asarray(lon) - self.lon0)*self.R*math.cos(math.radians(self.lat_ts))
        y = np.radians(lat)*self.R
        return (y - T.f)/T.e - 0.5, (x - T.c)/T.a - 0.5


def deshade(img, z, px, valid, sun):
    """按拍摄时的太阳方向（标签给的）回归光影强度，减掉 DTM 尺度上的光影。img、z 同网格（2 m），z 已填洞。
    只回归强度、方向不回归；而且在 30 m 以下的带通里回归：这里浅色岩层恰好长在朝南的坎面上，全局回归会被反照率带偏。"""
    gy, gx = np.gradient(ndimage.gaussian_filter(z, 1.0), px)
    n = np.stack([-gx, gy, np.ones_like(gx)], -1)                         # x 东、y 北（行向下所以 gy 取正号）
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    ok = valid & (img > 5) & np.isfinite(n).all(-1)
    sub = np.zeros_like(ok); sub[::7, ::7] = True; sel = ok & sub
    I = img[sel].astype(np.float64); N = n[sel]
    az, el = sun
    s = np.array([math.cos(math.radians(el))*math.sin(math.radians(az)),
                  math.cos(math.radians(el))*math.cos(math.radians(az)), math.sin(math.radians(el))])
    shf = np.maximum(n @ s, 0)
    hp = lambda a: a - ndimage.gaussian_filter(a, 15)                      # 带通：去掉 30 m 以上的反照率起伏
    Ih = hp(np.where(ok, img, np.nanmedian(img[ok]))); Sh = hp(shf)
    x, y = Sh[sel], Ih[sel]
    b = max(float(np.sum(x*y)/np.sum(x*x)), 0.0)
    r2 = 1 - np.sum((y - b*x)**2)/np.sum((y - y.mean())**2)
    coef = np.array([float(np.median(img[ok])), b])
    print(f"  拍摄时太阳：方位 {az}°、高度 {el}°；带通光影回归 R² = {r2:.2f}，亮度 ≈ … + {b:.0f}·cos")
    sh = np.maximum(n @ s, 0)
    flat = img - coef[1]*(sh - np.nanmean(sh[ok]))
    return flat, s, coef


def golombek(k, d0, d1, area):
    """面积 area（m²）里直径 d0…d1（m）的石块数与直径抽样。"""
    q = 1.79 + 0.152/k
    F = lambda D: k*np.exp(-q*D)
    edges = np.geomspace(d0, d1, 40)
    out = []
    rng = np.random.default_rng(SEED)
    for a, b in zip(edges[:-1], edges[1:]):
        dm = math.sqrt(a*b)
        n = (F(a) - F(b))*area/(math.pi*dm*dm/4)
        out.append(rng.uniform(a, b, rng.poisson(n)))
    return np.concatenate(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shot", default="梅拉斯层状沉积", choices=[k for k, v in K.SHOTS.items() if "near" in v])
    arg = ap.parse_args()
    shot = K.SHOTS[arg.shot]
    name = shot["near"]
    import rasterio
    from rasterio.windows import Window
    t0 = time.time()
    d, h = fetch(name)
    with rasterio.open(d/h["dtm"]) as ds:
        G = Geo(ds); z = ds.read(1).astype(np.float32); px = ds.transform.a
    z[z < -1e30] = np.nan
    valid = np.isfinite(z)
    print(f"  DTM {z.shape[1]}×{z.shape[0]}，{px:.2f} m，{np.nanmin(z):.0f}…{np.nanmax(z):.0f} m")

    # 相机：镜头里给经纬度；高度＝附近最高处 + agl
    clon, clat = shot["cam"][:2]
    cr, cc = G.rowcol(clon, clat)
    cr, cc = int(round(cr)), int(round(cc))
    win = z[cr - 10:cr + 11, cc - 10:cc + 11]
    gnd = float(np.nanmax(win))
    print(f"  相机处地面 {gnd:.1f} m（行 {cr}、列 {cc}）")

    # 2 m 正射 + 去光影
    with rasterio.open(d/h["ortho_d"]) as o:
        rr, cc_ = G.rowcol(*G.lonlat(0, 0), T=o.transform)
        img = o.read(1).astype(np.float32)
    off_r, off_c = int(round(rr)), int(round(cc_))                       # 正射 D 与 DTM 的像元偏移（应接近 0）
    img = np.roll(img, (-off_r, -off_c), (0, 1))[:z.shape[0], :z.shape[1]]
    idx = ndimage.distance_transform_edt(~valid, return_distances=False, return_indices=True)
    zf = z[idx[0], idx[1]]                                                 # 高程填洞（最近邻）
    flat, s_img, coef = deshade(img, zf, px, valid, h["sun"])

    # 边缘裙边（面片边缘往下钻，钻到大地形下面）
    dist = ndimage.distance_transform_edt(valid)*px
    edge = np.clip(1 - dist/150, 0, 1)                                     # 离无数据处 150 m 内渐变

    # 材质分区（2 m）
    fl = np.where(valid, flat, np.nan)
    med = np.nanmedian(fl)
    loc = ndimage.uniform_filter(np.nan_to_num(fl, nan=med), 9)
    std = np.sqrt(np.maximum(ndimage.uniform_filter(np.nan_to_num(fl, nan=med)**2, 9) - loc**2, 0))
    gy, gx = np.gradient(ndimage.gaussian_filter(zf, 1.5), px)
    slope = np.degrees(np.arctan(np.hypot(gx, gy)))
    bright = np.clip((loc - med)/(0.6*np.nanstd(fl)), 0, 1)
    sand = np.clip((med - loc)/(0.5*np.nanstd(fl)) + 0.5, 0, 1)*np.clip((14 - std)/8, 0, 1)*np.clip((22 - slope)/8, 0, 1)
    sand = ndimage.gaussian_filter(sand, 3)
    rock = np.clip(np.maximum(bright, np.clip((slope - 18)/12, 0, 1)) - sand, 0, 1)
    rock = ndimage.gaussian_filter(rock, 2)
    o8 = np.clip(fl/np.nanpercentile(fl, 99.5), 0, 1)
    mat = np.stack([np.nan_to_num(o8, nan=0.4), sand, rock], -1)

    # 行裁剪：相机以北全要，以南留 1.5 km（够投影）
    r0, r1 = 0, min(z.shape[0], cr + int(1500/px))
    out = CACHE/arg.shot; out.mkdir(parents=True, exist_ok=True)
    np.save(out/"near_hgt.npy", np.stack([zf[r0:r1]/1000, edge[r0:r1], np.zeros_like(edge[r0:r1])], -1).astype(np.float32))
    np.save(out/"near_mat.npy", (np.clip(mat[r0:r1], 0, 1)*255).astype(np.uint8))

    # 0.5 m 正射：相机前方 4 km × 4 km
    with rasterio.open(d/h["ortho_b"]) as o:
        Tb = o.transform
        br, bc = G.rowcol(clon, clat, T=Tb)
        span = int(4000/Tb.a)
        wr0 = max(0, int(br) - span); wc0 = max(0, int(bc) - span//2)
        wr1 = min(o.height, int(br) + int(300/Tb.a)); wc1 = min(o.width, wc0 + span)
        ob = o.read(1, window=Window(wc0, wr0, wc1 - wc0, wr1 - wr0)).astype(np.float32)
    # 0.5 m 也减光影：用 2 m 的光影场放大
    zz = ndimage.map_coordinates(zf, np.meshgrid((np.arange(wr0, wr1) + 0.5)*Tb.a/px - 0.5 + (Tb.f - G.T.f)/G.T.e,
                                                 (np.arange(wc0, wc1) + 0.5)*Tb.a/px - 0.5 + (Tb.c - G.T.c)/G.T.a, indexing="ij"), order=1)
    gy, gx = np.gradient(ndimage.gaussian_filter(zz, 2.0), Tb.a)
    nb = np.stack([-gx, gy, np.ones_like(gx)], -1); nb /= np.linalg.norm(nb, axis=-1, keepdims=True)
    shb = np.maximum(nb @ s_img, 0)
    okb = ob > 5
    ob = ob - coef[1]*(shb - shb[okb].mean())
    ob8 = (np.clip(ob/np.nanpercentile(fl, 99.5), 0, 1)*255).astype(np.uint8)
    ob8[~okb] = 0
    np.save(out/"near_ortho.npy", ob8)
    print(f"  0.5 m 正射 {ob8.shape[1]}×{ob8.shape[0]}")

    # 撒石（只在视野 ±40° 里）
    rng = np.random.default_rng(SEED)
    hd = math.radians(shot["heading"])
    pts = []
    for (rmin, rmax, dmin) in ((2, 45, 0.04), (45, 350, 0.18), (350, 2500, 0.6)):
        ang = math.radians(40)
        area = 0.5*(rmax**2 - rmin**2)*2*ang
        for k_, wkey in ((0.06, "rock"), (0.03, "reg")):
            D = golombek(k_, dmin, 3.0, area)
            n = len(D)
            r = np.sqrt(rng.uniform(rmin**2, rmax**2, n)); a = hd + rng.uniform(-ang, ang, n)
            de, dn = r*np.sin(a), r*np.cos(a)                              # 东、北（米）
            rr_ = cr - dn/px; cc2 = cc + de/px
            ok = (rr_ > 0) & (rr_ < z.shape[0] - 1) & (cc2 > 0) & (cc2 < z.shape[1] - 1)
            rr_, cc2, D = rr_[ok], cc2[ok], D[ok]
            ri, ci = rr_.astype(int), cc2.astype(int)
            w = rock[ri, ci] if wkey == "rock" else np.clip(1 - rock[ri, ci] - sand[ri, ci], 0, 1)
            keep = (rng.random(len(D)) < w) & valid[ri, ci] & (edge[ri, ci] < 0.01)
            rr_, cc2, D = rr_[keep], cc2[keep], D[keep]
            zz_ = ndimage.map_coordinates(zf, [rr_, cc2], order=1)
            pts.append(np.stack([rr_, cc2, zz_, D], -1))
    P = np.concatenate(pts)
    lon, lat = G.lonlat(P[:, 0] - 0.5, P[:, 1] - 0.5)
    n = len(P)
    rot = np.stack([rng.normal(0, 0.25, n), rng.normal(0, 0.25, n), rng.uniform(0, 2*math.pi, n)], -1)
    np.savez(out/"rocks.npz", lon=lon, lat=lat, z=P[:, 2]/1000, d=P[:, 3], rot=rot,
             kind=rng.integers(0, 12, n), seed=rng.random(n))
    print(f"  撒石 {n:,} 块（≥ 1 m 的 {int((P[:, 3] >= 1).sum())} 块）")

    # 范围与坐标
    lon_a, lat_a = G.lonlat(np.array([r0, r0, r1 - 1, r1 - 1]), np.array([0, z.shape[1] - 1, 0, z.shape[1] - 1]))
    meta = dict(R=G.R, lon0=G.lon0, lat_ts=G.lat_ts, px=px, T=[G.T.c, G.T.a, G.T.f, G.T.e], rows=[r0, r1],
                cols=z.shape[1], cam_ground_km=gnd/1000,
                ortho=dict(T=[Tb.c, Tb.a, Tb.f, Tb.e], r0=wr0, c0=wc0, shape=list(ob8.shape)),
                img_sun=s_img.tolist())
    (out/"near.json").write_text(json.dumps(meta, ensure_ascii=False))
    print(f"→ {out}（{time.time() - t0:.0f} s）")


if __name__ == "__main__":
    main()
