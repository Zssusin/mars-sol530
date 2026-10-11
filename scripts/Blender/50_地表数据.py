"""
Blender 地表渲染的数据准备（venv 里跑）：给一个数据区域（镜头.py 的 REGIONS，几个镜头可共用）准备高程、影像、水位与底色，
存成 numpy 给 51 读。思路同 NASA/JPL 的 MARTIAN（Blender + 真实 DTM + 正射影像）：近处用观测数据，分辨率以下才用程序细节。

数据（第一次运行联网下载，缓存在 DEM/ 下）：
- 高程：USGS「Mars MGS MOLA – MEX HRSC Blended DEM Global 200 m v2」，HTTP 按行读窗口（约 0.9 GB / 20°×14°），
  缓存 DEM/HRSC_MOLA_<区域>.npy。高度相对 MOLA 基准面，和 11 的水位一致。
- 影像：MRO CTX 全球拼接（Esri OnMars 瓦片，与 38、39 同源），zoom 8 ≈ 82 m/px，瓦片缓存 DEM/CTX缓存/。
  只取亮度的局部起伏（σ 1.5 km 高通、局部标准化），在着色器里调制底色——相当于全色锐化：颜色来自 TES，明暗细节来自 CTX。
  CTX 照片本身带拍摄时的光影，这部分会被一起「烤」进去（MARTIAN 也是这样）。
- 水位：11 的掩膜按 MOLA 细化（refine_water），水位往陆地上按最近水体铺开，着色器画湿岸用。
- 底色：TES 反照率（7.4 km）决定亮尘与暗砂的比例，谷内层状沉积（ILD）沿用 40 的推定范围，反射率表同 40。

产出（DEM/Blender缓存/<区域>/，不进 git）：
- hgt.npy   (ny·2, nx·2) float32：256 px/度（231 m）高程（km），HRSC+MOLA + 200 m 以下的崖壁细节（推定）：
  冲沟（白噪声按 8 个方向在频域里做各向异性滤波，顺坡 2.5 km、横坡 0.35 km，按坡向加权混合，取 −|n| 切 V 形沟）
  + 岩层台阶（陡坡上按 180 m 一级量化，斑块状掺回）。
- aux.npy   (ny, nx, 3)：坡度（tan）、水位（km）、备用；128 px/度
- col.npy   (ny, nx, 3)：线性反照率 RGB（R≈650、G≈550、B≈450 nm）；128 px/度
- ctx.npy   (ny·4, nx·4) uint8：CTX 亮度细节，512 px/度（约 116 m）
- water.npz：64 px/度 的水体编号与各水体水位（建水面网格用）
运行：./.venv/bin/python scripts/Blender/50_地表数据.py [--data 梅拉斯]
"""
import argparse, importlib, json, math, pathlib, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor
import numpy as np
from scipy import ndimage
from PIL import Image
HERE = pathlib.Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parent), str(HERE.parent/"体素")]
import 制图公共 as M
import 镜头 as K
V = importlib.import_module("40_体素地形")

CACHE = M.MAP_DIR/"DEM"/"Blender缓存"
HRSC_URL = "/vsicurl/https://planetarymaps.usgs.gov/mosaic/Mars/HRSC_MOLA_Blend/Mars_HRSC_MOLA_BlendDEM_Global_200mp_v2.tif"
CTX_URL = "https://astro.arcgis.com/arcgis/rest/services/OnMars/CTX/MapServer/tile/{z}/{r}/{c}"
CTX_DIR = M.MAP_DIR/"DEM"/"CTX缓存"
CTX_Z = 8
SEED = 2100
BASINS = (("marineris_ius", "level_ius"), ("marineris_mid", "level_marineris"), ("marineris_eos", "level_eos"))


def refl(key): return np.array(V.REFL[key][::-1], np.float32)            # (450, 550, 650) → RGB

SAND = np.array([0.100, 0.066, 0.045], np.float32)                        # 暗色砂/土：40 的「砂」偏灰（红蓝比 1.7），按 Pancam 暗土调到 2.2


# ── 下载 ───────────────────────────────────────────────────────────
def hrsc_window(name, region):
    """HRSC+MOLA 200 m 窗口（米，int16 → float32），第 0 行在北；返回 (数组, 西经界, 北纬界, px/度)。"""
    f = M.MAP_DIR/"DEM"/f"HRSC_MOLA_{name}.npz"
    if f.exists():
        z = np.load(f); return z["a"].astype(np.float32), float(z["lon"]), float(z["lat"]), float(z["ppd"])
    import rasterio
    from rasterio.windows import Window
    lon0, lon1, lat0, lat1 = region
    with rasterio.Env(GDAL_HTTP_MULTIRANGE="YES", CPL_VSIL_CURL_CHUNK_SIZE=8*1024*1024, GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR"):
        ds = rasterio.open(HRSC_URL)
        ppd = 1/ds.res[0]
        c0 = int(math.floor((((lon0 + 180) % 360) - 180 + 180)*ppd)) - 2
        r0 = int(math.floor((90 - lat0)*ppd)) - 2
        w = int(math.ceil((lon1 - lon0)*ppd)) + 4; h = int(math.ceil((lat0 - lat1)*ppd)) + 4
        t0 = time.time(); a = np.empty((h, w), np.int16)
        for i in range(0, h, 256):                                         # 分块读，打印进度
            n = min(256, h - i)
            a[i:i + n] = ds.read(1, window=Window(c0, r0 + i, w, n))
            print(f"\r  HRSC+MOLA 下载 {i + n}/{h} 行（{time.time() - t0:.0f} s）", end="", flush=True)
        print()
    lonw = c0/ppd - 180 + 360 if lon0 > 180 else c0/ppd - 180
    latn = 90 - r0/ppd
    np.savez(f, a=a, lon=lonw, lat=latn, ppd=ppd)
    return a.astype(np.float32), lonw, latn, ppd


def ctx_fetch(z, r, c):
    f = CTX_DIR/f"z{z}_{r}_{c}.png"
    if not f.exists() or f.stat().st_size < 1000:
        subprocess.run(["curl", "-sS", "--max-time", "60", "-A", "Mozilla/5.0", "-o", str(f), CTX_URL.format(z=z, r=r, c=c)])
    return f


def ctx_mosaic(region, z=CTX_Z):
    """CTX 灰度拼图（东经）；返回 (数组, 西界, 北界, 度/px)。"""
    lon0, lon1, lat0, lat1 = region
    res = 0.3515625/2**z; dt = res*512; n = 2**z
    l0, l1 = lon0 - 360, lon1 - 360                                        # 瓦片按 −180…180
    c0, c1 = int(math.floor((l0 + 180)/dt)), int(math.floor((l1 + 180)/dt))
    r0, r1 = int(math.floor((90 - lat0)/dt)), int(math.floor((90 - lat1)/dt))
    jobs = [(r, c % (2*n)) for r in range(r0, r1 + 1) for c in range(c0, c1 + 1)]
    CTX_DIR.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    with ThreadPoolExecutor(8) as ex: list(ex.map(lambda j: ctx_fetch(z, *j), jobs))
    print(f"  CTX zoom {z}：{len(jobs)} 张瓦片（{time.time() - t0:.0f} s）")
    out = np.full(((r1 - r0 + 1)*512, (c1 - c0 + 1)*512), np.nan, np.float32)
    for r in range(r0, r1 + 1):
        for c in range(c0, c1 + 1):
            try: im = np.asarray(Image.open(ctx_fetch(z, r, c % (2*n))).convert("L"), np.float32)
            except Exception: continue
            out[(r - r0)*512:(r - r0 + 1)*512, (c - c0)*512:(c - c0 + 1)*512] = im
    return out, -180 + c0*dt + 360, 90 - r0*dt, res


def resample(a, lonw, latn, ppd_src, region, ppd_out, order=3):
    """把 (第 0 行在北、西界 lonw、北界 latn、ppd_src) 的栅格重采样到 region 的 ppd_out 像元中心网格。"""
    lon0, lon1, lat0, lat1 = region
    ny, nx = round((lat0 - lat1)*ppd_out), round((lon1 - lon0)*ppd_out)
    lat = lat0 - (np.arange(ny) + 0.5)/ppd_out
    lon = lon0 + (np.arange(nx) + 0.5)/ppd_out
    ri = (latn - lat)*ppd_src - 0.5; ci = (lon - lonw)*ppd_src - 0.5
    out = np.empty((ny, nx), np.float32)
    for i in range(0, ny, 512):                                            # 分块，省内存
        R_, C_ = np.meshgrid(ri[i:i + 512], ci, indexing="ij")
        out[i:i + 512] = ndimage.map_coordinates(a, [R_, C_], order=order, mode="nearest")
    return out


# ── 崖壁细节（推定）──────────────────────────────────────────────
def wall_detail(dem_km, slope, lat_c, ppd):
    ny, nx = dem_km.shape
    py = M.KMPD/ppd; px = py*math.cos(math.radians(lat_c))
    g = ndimage.gaussian_filter(dem_km, 6)
    gy, gx = np.gradient(g)
    theta = np.arctan2(gy/py, gx/px)                                       # 上坡方向
    rng = np.random.default_rng(SEED)
    fy = np.fft.fftfreq(ny, py)[:, None]; fx = np.fft.rfftfreq(nx, px)[None, :]
    W = np.fft.rfft2(rng.normal(size=(ny, nx)).astype(np.float32))
    acc = np.zeros_like(dem_km); w2 = np.zeros_like(dem_km)
    lal, lac = 2.5, 0.35                                                   # 顺坡、横坡波长（km）；更大的 HRSC 自己有
    for k in range(8):
        phi = k*math.pi/8
        fu = fx*math.cos(phi) + fy*math.sin(phi); fv = -fx*math.sin(phi) + fy*math.cos(phi)
        n = np.fft.irfft2(W*np.exp(-(fu*lal)**2 - (fv*lac)**2), s=(ny, nx)).astype(np.float32)
        n /= n.std() + 1e-9
        wk = np.cos(theta - phi)**16
        acc += wk*n; w2 += wk*wk
    n = acc/np.sqrt(w2 + 1e-9)
    amp = 0.12*np.clip(slope/0.35, 0, 1)**1.3
    return amp*(0.75 - np.abs(n))


def terraces(dem_km, slope, step=0.18):
    t = dem_km/step
    f = t - np.floor(t)
    stair = (np.floor(t) + np.clip((f - 0.72)/0.28, 0, 1)**2)*step
    rng = np.random.default_rng(SEED + 1)
    patch = ndimage.gaussian_filter(rng.normal(size=dem_km.shape).astype(np.float32), 24)
    patch = np.clip(patch/patch.std()*0.6 + 0.3, 0, 1)
    w = 0.5*np.clip((slope - 0.12)/0.3, 0, 1)*patch
    return w*(stair - dem_km)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="梅拉斯", choices=list(K.REGIONS))
    arg = ap.parse_args()
    region = K.REGIONS[arg.data]
    lon0, lon1, lat0, lat1 = region
    t0 = time.time()
    dem = M.read_dem_window(lon0, lon1, lat0, lat1, K.PPD)               # MOLA（米）：水位、坡度、颜色用
    ny, nx = dem.shape
    lat = lat0 - (np.arange(ny) + 0.5)/K.PPD
    lon = lon0 + (np.arange(nx) + 0.5)/K.PPD
    LO, LA = np.meshgrid(lon, lat)

    # 高程：HRSC+MOLA 200 m → 256 px/度
    hr, hlon, hlat, hppd = hrsc_window(arg.data, region)
    hi = resample(hr, hlon, hlat, hppd, region, 2*K.PPD)/1000
    mola_hi = ndimage.zoom(dem/1000, 2, order=1)
    print(f"  HRSC+MOLA {hr.shape[1]}×{hr.shape[0]}（{hppd:.1f} px/度）；与 MOLA 差 中位 {np.median(hi - mola_hi)*1000:.0f} m，"
          f"95% {np.percentile(np.abs(hi - mola_hi), 95)*1000:.0f} m")
    dy = M.KMPD/(2*K.PPD); dx = dy*np.cos(np.radians(LA.mean()))
    gy, gx = np.gradient(ndimage.gaussian_filter(hi, 1.0))
    sl2 = np.hypot(gx/dx, gy/dy).astype(np.float32)
    hi = hi + terraces(hi, sl2)
    hi = hi + wall_detail(hi, sl2, (lat0 + lat1)/2, 2*K.PPD)
    slope = sl2.reshape(ny, 2, nx, 2).mean((1, 3))

    # 水
    Z = M.load_masks()
    level = np.full(dem.shape, np.nan, np.float32)
    basin = np.zeros(dem.shape, np.uint8)
    levels = []
    for b, (mk, lk) in enumerate(BASINS, 1):
        lv = float(Z[lk]); levels.append(lv)
        w = M.refine_water(Z[mk], lv, dem, K.PPD, lon0, lat0) & np.isnan(level)
        level[w] = lv; basin[w] = b
        print(f"  {mk}：水位 {lv:.0f} m，{w.mean()*100:.1f}% 的格子")
    idx = ndimage.distance_transform_edt(np.isnan(level), return_distances=False, return_indices=True)
    level_f = level[idx[0], idx[1]] if np.isfinite(level).any() else np.full(dem.shape, -99000, np.float32)

    # 底色
    alb = M.ALBEDO_MID + M.ALBEDO_HALF*M.albedo_at(LO, LA)                  # albedo_at 是归一化值，换回反照率
    t = np.clip((alb - 0.13)/(0.25 - 0.13), 0, 1)[..., None]
    floor = np.clip((-dem - 500)/2500, 0, 1)[..., None]                   # 谷底多暗砂
    t = t*(1 - 0.6*floor)
    col = SAND*(1 - t) + refl("dust")*t
    V.PPB = K.PPD
    ild = ndimage.gaussian_filter(V.ild_mask(LO, LA, dem).astype(np.float32), K.PPD/40)[..., None]
    col = col*(1 - ild) + refl("ild")*ild

    # CTX 亮度细节 → 512 px/度
    cimg, clon, clat, cres = ctx_mosaic(region)
    valid = np.isfinite(cimg)
    cimg = np.where(valid, cimg, np.nanmedian(cimg))
    sig = 1.5/(M.KMPD*cres)                                               # 1.5 km
    mu = ndimage.gaussian_filter(cimg, sig); hp = cimg - mu
    sd = np.sqrt(ndimage.gaussian_filter(hp*hp, sig*2)) + 2.0
    zc = np.clip(hp/sd, -3, 3)*valid
    ctx = resample(zc, clon, clat, 1/cres, region, 4*K.PPD, order=1)
    ctx8 = np.clip(ctx/6 + 0.5, 0, 1)*255
    print(f"  CTX 细节 {ctx8.shape[1]}×{ctx8.shape[0]}（有影像 {valid.mean()*100:.1f}%）")

    aux = np.stack([slope, level_f/1000, np.zeros_like(slope)], -1).astype(np.float32)
    f = K.PPD//K.PPD_WATER
    bl = basin[:ny//f*f, :nx//f*f].reshape(ny//f, f, nx//f, f).max((1, 3))
    grow = ndimage.grey_dilation(bl, size=(5, 5))
    bl = np.where(bl > 0, bl, grow)

    out = CACHE/arg.data
    out.mkdir(parents=True, exist_ok=True)
    np.save(out/"hgt.npy", hi.astype(np.float32))
    np.save(out/"aux.npy", aux)
    np.save(out/"col.npy", col.astype(np.float32))
    np.save(out/"ctx.npy", ctx8.astype(np.uint8))
    np.savez_compressed(out/"water.npz", basin=bl, levels=np.array(levels, np.float32)/1000)
    (out/"meta.json").write_text(json.dumps(dict(region=region, ppd=K.PPD, ppd_water=K.PPD_WATER,
                                                  shape=[ny, nx], hgt="HRSC+MOLA 200 m v2", ctx_zoom=CTX_Z), ensure_ascii=False))
    print(f"→ {out}（{time.time() - t0:.0f} s）")


if __name__ == "__main__":
    main()
