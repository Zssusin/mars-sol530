"""
实景（真三维）数据：毅力号 site 26 / drive 1222 这一站（sol 502 到站 … sol 533 离开，耶泽罗三角洲前缘）。
55 是投影贴图（一张图），这里要的是能从任何角度、任何太阳下渲染的真模型，所以把这一站和周围的全部原始数据拉齐：
  ① 这一站全部 Navcam 立体网格（ops_mesh，到站 360° 环拍 NCAM03502 + 臂工作区 + 臂前方）及其照片的官方标签
     （CAHVORE 相机模型、拍摄时的太阳方位/高度）→ 去光影、投贴图用。
  ② HiRISE 1 m 高程（USGS Mars 2020 TRN 拼接，DeltaGeoid）±2 km、25 cm 正射 ±1.5 km → 中景。
  ③ CTX 20 m 高程、10 m 正射（JPL 科研底图，5 m 隔一抽一）±40 km → 远景到东西坑缘；CTX 没盖到的用本地 MOLA 463 m（±90 km）补。
  ④ sol 502 到站全景全分辨率 JPG（NASA MMGIS，18584×5914）→ 颜色参考。
  ⑤ NASA 官方毅力号模型（25042_Perseverance.glb）。
运行：.venv/bin/python scripts/Blender/56_实景数据.py [网格|轨道|其他]（不给就全做；已下过的跳过）
数据：NASA/JPL-Caltech/ASU/MSSS/University of Arizona/USGS，PDS Imaging Node、USGS Astrogeology、NASA 3D Resources。
"""
import json, math, pathlib, re, sys, urllib.request
import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
MAP = HERE.parent.parent
OUT = MAP/"DEM"/"Blender缓存"/"_素材"/"PDS"/"站26_1222"
SOL530 = MAP/"DEM"/"Blender缓存"/"_素材"/"PDS"/"sol0530"                 # 55 已下的 sol 530 网格，不重复下
SITE, DRIVE = 26, 1222
SOLS = (502, 504, 509, 516, 520, 521, 525, 526, 527, 528, 529, 530, 531, 532)
LAT, LON = 18.45864728, 77.40592495                                     # NASA 定位（end-of-drive localization）
R_MARS = 3396190.0
PDS = "https://planetarydata.jpl.nasa.gov/img/data/mars2020/"
MESH = PDS + "mars2020_navcam_ops_mesh/data/sol/{:05d}/ids/rdr/mesh/"
CAL = PDS + "mars2020_navcam_ops_calibrated/data/sol/{:05d}/ids/rdr/ncam/"
S3 = "/vsicurl/https://asc-pds-services.s3.us-west-2.amazonaws.com/mosaic/mars2020_trn/"
HI_DTM = S3 + "HiRISE/JEZ_hirise_soc_006_DTM_MOLAtopography_DeltaGeoid_1m_Eqc_latTs0_lon0_blend40.tif"
HI_ORT = S3 + "HiRISE/JEZ_hirise_soc_007_orthoMosaic_25cm_Ortho_blend120.tif"
CTX_DTM = S3 + "CTX/ScienceInvestigationMaps_JPL/M20_JezeroCrater_CTXDEM_20m.tif"
CTX_ORT = S3 + "CTX/ScienceInvestigationMaps_JPL/M20_JezeroCrater_CTXortho_mosaic_5m.tif"
PANO502 = "https://mars.nasa.gov/mmgis-maps/M20/Layers/mosaics/N_LRGB_0502_RAS_0261222_CYL_S_AUTOGENJ01.jpg"
ROVER = "https://assets.science.nasa.gov/content/dam/science/psd/mars/resources/gltf_files/25042_Perseverance.glb"


def log(*a): print("[56]", *a, flush=True)


def get(url, path):
    if path.exists() and path.stat().st_size > 0: return False
    tmp = path.with_suffix(path.suffix + ".part")
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})   # mars.nasa.gov 拒绝 Python 默认 UA
    with urllib.request.urlopen(req, timeout=600) as r, open(tmp, "wb") as fh:
        while chunk := r.read(1 << 20): fh.write(chunk)
    tmp.rename(path); return True


def listing(url):
    try: return urllib.request.urlopen(url, timeout=120).read().decode()
    except Exception as e: log(f"列表失败 {url}: {e}"); return ""


NEIGH = [(490, 1004), (491, 1004), (495, 1004), (499, 1004), (535, 1229), (535, 1235)]   # 邻站：到站前 21 m 外的 drive 1004、离站途中


def meshes():
    """这一站（和邻站）每个 sol 的全部网格（obj/mtl/png）＋ 每张照片的标定标签（同 sclk 的 RAS 或任意 xml）。"""
    OUT.mkdir(parents=True, exist_ok=True); (OUT/"邻站").mkdir(exist_ok=True)
    n_new = 0
    for sol, drive in [(s, DRIVE) for s in SOLS] + NEIGH:
        tag = f"N{SITE:03d}{drive:04d}"
        names = sorted(set(re.findall(rf'href="(N[LR][FM]_[A-Z0-9_]*{tag}[A-Z0-9_]*)\.obj"', listing(MESH.format(sol)))))
        cal = listing(CAL.format(sol))
        for b in names:
            here = SOL530 if (SOL530/f"{b}.obj").exists() else (OUT if drive == DRIVE else OUT/"邻站")
            for ext in ("obj", "mtl", "png"):
                n_new += get(MESH.format(sol) + f"{b}.{ext}", here/f"{b}.{ext}")
            # 标签：网格名 NLF_0530_0713995035M362RAS_… ↔ 标定图 NLF_0530_0713995035_362xxx_…
            m = re.match(r"(N[LR][FM]_\d{4}_\d{10})M(\d{3})", b)
            cands = re.findall(rf'href="({m.group(1)}_{m.group(2)}[A-Z]{{3}}[A-Z_]*{tag}[A-Z0-9_]*\.xml)"', cal)
            if cands:
                pick = next((c for c in cands if c[24:27] == "RAS"), cands[0])
                get(CAL.format(sol) + pick, here/f"{b}.label.xml")
        log(f"sol {sol} drive {drive}: {len(names)} 块")
    log(f"网格完成，新下 {n_new} 个文件 → {OUT}")


def window(src, cx, cy, half, out, kind, dec=1):
    """从远程 GeoTIFF 读 (cx, cy)±half（该文件自己的投影坐标）一窗，存 npy + 地理参数；dec＞1 就隔 dec 抽一（远景用）。"""
    import rasterio
    from rasterio.windows import from_bounds
    if (OUT/f"{out}.npy").exists(): log(f"{out} 已有"); return
    with rasterio.open(src) as d:
        w = from_bounds(cx - half, cy - half, cx + half, cy + half, d.transform).round_offsets().round_lengths()
        shp = (int(w.height)//dec, int(w.width)//dec)
        a = d.read(1, window=w, out_shape=shp, boundless=True, fill_value=d.nodata if d.nodata is not None else 0)
        t = d.window_transform(w)*rasterio.Affine.scale(w.width/shp[1], w.height/shp[0])
        meta = dict(src=src.split("/")[-1], crs=d.crs.to_proj4(), transform=list(t)[:6], nodata=d.nodata,
                    res=d.res[0]*dec, shape=a.shape, kind=kind)
    np.save(OUT/f"{out}.npy", a); (OUT/f"{out}.json").write_text(json.dumps(meta, indent=1, default=float))
    v = a[np.isfinite(a) & (a > -1e30) & (a != (meta["nodata"] or -9e99))] if a.dtype.kind == "f" else a[a > 0]
    log(f"{out}: {a.shape}，{meta['res']} m/像素，值 {np.percentile(v, 1):.1f}…{np.percentile(v, 99):.1f}，有效 {v.size/a.size*100:.0f}%")


def lonlat_to(crs, lon, lat):
    from rasterio.warp import transform
    x, y = transform(f"+proj=longlat +R={R_MARS} +no_defs", crs, [lon], [lat]); return x[0], y[0]


def orbital():
    import rasterio
    OUT.mkdir(parents=True, exist_ok=True)
    for src, half, out, kind, dec in ((HI_DTM, 2000, "hirise_dtm_1m", "高程", 1), (HI_ORT, 1500, "hirise_ortho_25cm", "正射", 1),
                                      (CTX_DTM, 40000, "ctx_dtm_20m", "高程", 1),          # ±40 km：东坑缘离车约 33 km
                                      (CTX_ORT, 40000, "ctx_ortho_10m", "正射", 2),
                                      (str(MAP/"DEM"/"Mars_MGS_MOLA_DEM_mosaic_global_463m.tif"), 90000, "mola_463m", "高程", 1)):
        with rasterio.open(src) as d: crs = d.crs.to_proj4()
        cx, cy = lonlat_to(crs, LON, LAT)
        log(f"{out}：车在 {crs.split()[0]} ({cx:.1f}, {cy:.1f})")
        window(src, cx, cy, half, out, kind, dec)


def others():
    OUT.mkdir(parents=True, exist_ok=True)
    if get(ROVER, OUT/"毅力号.glb"): log("毅力号模型 ✓")
    try:
        if get(PANO502, OUT/"sol0502_全景.jpg"): log("sol 502 全景 ✓")
    except Exception as e: log(f"sol 502 全景下不到（{e}），只是颜色参考，跳过")
    (OUT/"站点.json").write_text(json.dumps(dict(site=SITE, drive=DRIVE, lat=LAT, lon=LON, elev_geoid=-2523.168,
        roll=-14.23768937, pitch=-1.871436595, yaw=-107.7939695, sols=SOLS,
        sun_sol530=dict(ltst="13:06:45", az_site=201.5, el=44.3125)), indent=1, ensure_ascii=False))


ZSCI = PDS + "mars2020_mastcamz_sci_calibrated/data/{:04d}/iof/"


def mastcam():
    """⑥ Mastcam-Z 科学标定 IOF（ASU，物理反射率 I/F，带 CAHVOR 相机模型）：本站 ZL0/ZR0 RGB 全幅（>2 MB），约 1900 张、7 GB。"""
    from concurrent.futures import ThreadPoolExecutor
    out = OUT/"mastcamz"; out.mkdir(parents=True, exist_ok=True)
    tag = f"N{SITE:03d}{DRIVE:04d}"; jobs = []
    for sol in range(502, 534):
        h = listing(ZSCI.format(sol))
        for name, size in re.findall(rf'href="(Z[LR]0_[^"]*{tag}[^"]*)\.IMG">[^<]*</a></td><td class="indexcollastmod">[^<]*</td>'
                                     rf'<td class="indexcolsize">\s*([\d.]+[KMG]?)<', h):
            v = float(size.rstrip("KMG"))*{"K": 1e3, "M": 1e6, "G": 1e9}.get(size[-1], 1)
            if v > 2e6:
                jobs += [(ZSCI.format(sol) + f"{name}.{e}", out/f"{name}.{e}") for e in ("xml", "IMG")]
    log(f"Mastcam-Z：{len(jobs)//2} 张待下")
    def one(j):
        try: return get(*j)
        except Exception as e: log(f"失败 {j[1].name}: {e}"); return False
    with ThreadPoolExecutor(4) as ex: n = sum(ex.map(one, jobs))
    log(f"Mastcam-Z 完成，新下 {n} 个文件 → {out}")


if __name__ == "__main__":
    step = sys.argv[1] if len(sys.argv) > 1 else "全部"
    if step in ("网格", "全部"): meshes()
    if step in ("轨道", "全部"): orbital()
    if step in ("其他", "全部"): others()
    if step in ("Mastcam", "全部"): mastcam()
