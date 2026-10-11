"""
75 兴趣点：玩法 A（docs/玩法A.md）的兴趣点和「复刻 NASA 照片」挑战数据。在 fedora 上跑（要联网下载）。
  输出：godot/数据/sol0530/兴趣点.json（进 git）、godot/数据/sol0530/兴趣点/*.jpg（不进 git，本脚本生成；目录带 .gdignore）。
  缓存：资料/NASA补充/兴趣点/（raw 图 API 的每 sol 列表、下载的原图）。

坐标：全部换到本项目的 ENU（E 东、N 北、U 上，m），原点 = 站 26/1222 导航点（57 的 LOCAL_LEVEL_26_1222，O_LL）。
  - 站 26 的位置：站点系（x 北、y 东、z 下）减 O_LL，再 M_SB 换轴（同 57 to_enu）；
  - 别的站：MMGIS 航点（M20_waypoints.json）的经纬度 → ENU（同 界面.gd：N = Δφ·R，E = Δλ·R·cos φ，R = 3396190 m）。
    26/1222 用两种算法差 0；26/1652 差约 1.5 m（MMGIS 是定位解插值），对兴趣点（发现半径 ≥ 6 m）足够。
  - 远处（坑缘、着陆点）：给出经纬度换算的 ENU，界面上只当方位标，拍照时在画面中央一半视场里就算发现。
  每个点打印所在区域：Navcam 精细区 ±50 m、HiRISE 区 ±1 km、CTX 区 ±40 km；近点超出 HiRISE 区就报错。

照片：NASA 火星车原始图像 API（https://mars.nasa.gov/rss/api/?feed=raw_images&category=mars2020&feedtype=json&sol=N）。
  产品号 = imageid（同 PDS 产品名前缀），署名用 API 的 credit（NASA/JPL-Caltech，Mastcam-Z 为 NASA/JPL-Caltech/ASU）。
  缩成 960 px 宽 JPEG。原始图像 API 的图都是原始（未定标）图。

挑战的相机位姿：API 记录里有相机模型（CAHVOR/CAHVORE，ROVER_NAV 系）、车姿四元数（attitude，ROVER_NAV → SITE）和车在站点系的位置（xyz），
  和 PDS 标签里的同一套（GEOMETRIC_CAMERA_MODEL + ROVER_NAV_FRAME）。这里复用 71 的 qrot（四元数 → 旋转）和 cahvor（投影）、
  57 的 O_LL / M_SB（站点系 → ENU）、70 的 parse_pose_label（PDS4 标签里的车姿，用来交叉核对）。
  60_实景回归.py 的对照机位（scene.json 的 对照_*，57 用照片定标出的位姿）拿来核对：同一张 sol 502 Navcam 右眼照片，
  API 位姿和定标位姿的位置差、方向差打印出来（见 核对()）。
  视场：CAHV 的线性部分给针孔等效 hfov = 2·atan(hc/hs)。Navcam 是 CAHVORE（近鱼眼），图边缘实际视角更大；评分只用位置和方向。

用法：.venv/bin/python scripts/Godot/75_兴趣点.py [--只核对 | --只补英文]
数据：NASA/JPL-Caltech、NASA/JPL-Caltech/ASU（照片），MMGIS「Where is Perseverance」航点。事实出处逐条写在 兴趣点.json 里。
"""
import importlib.util, json, math, pathlib, re, subprocess, sys, time
import numpy as np
from PIL import Image

HERE = pathlib.Path(__file__).resolve().parent
MAP = HERE.parent.parent
GD = MAP/"godot"/"数据"/"sol0530"
OUT_IMG = GD/"兴趣点"
CACHE = MAP/"资料"/"NASA补充"/"兴趣点"
POSE = MAP/"资料"/"NASA补充"/"位姿"
API = "https://mars.nasa.gov/rss/api/?feed=raw_images&category=mars2020&feedtype=json&sol={}"


def log(*a): print("[75]", *a, flush=True)


# 英文界面（玩家看到的名字和说明；界面语言 = English 时游戏读 "en" 里的字）。事实同中文版，用自己的话写；地名、样本名按 NASA 原写法。
英文 = {
    "wildcat_ridge": {"名": "Wildcat Ridge", "说明": "A rock about 1 m wide, probably laid down as mud and sand in an evaporating salt lake billions of years ago. On 20 July 2022 Perseverance abraded its surface (Berry Hollow), and SHERLOC found the richest organic signal of the mission so far. Two cores followed: Hazeltop (sol 509) and Bearwallow (sol 516)."},
    "skinner_ridge": {"名": "Skinner Ridge", "说明": "A rock outcrop on the delta front. Here Perseverance cored two sedimentary rocks, Swift Run (sol 490, 2022-07-07) and Skyland (sol 495): its first rock samples from the ancient river delta. Skyland was later placed in the Three Forks depot."},
    "hogwallow_flats": {"名": "Hogwallow Flats", "说明": "A pale, fine-grained rock layer. The team first called it the \"Bacon Strip\" after the light stripes in HiRISE images. Fine-grained rock tends to hold more clay minerals, the best bet for preserving ancient organic molecules. Wildcat Ridge belongs to this layer."},
    "sol535_tracks": {"名": "Sol 535 tracks", "说明": "On sol 535 Perseverance left Wildcat Ridge and drove about 85 m east to stop here, then turned Navcam back on its own tracks. At sol 530 in the game, this drive has not happened yet."},
    "hawksbill_gap": {"名": "Hawksbill Gap", "说明": "A gap in the delta front. In mid-May 2022 Perseverance started climbing the delta front here, planning five close-up science stops in different layers on the way to Rocky Top."},
    "three_forks": {"名": "Three Forks Sample Depot", "说明": "The first sample depot built by humans on another world. On 21 December 2022 (sol 653) Perseverance set down the first tube, Malay; by 28 January 2023 (sol 690) it had laid out 10, zigzagged 5-15 m apart, for a future mission to collect. Skyland and Bearwallow are among them. At sol 530 in the game, the depot does not exist yet."},
    "amalik": {"名": "Amalik Outcrop", "说明": "A sedimentary outcrop on the delta front. On 2 October 2022 (sol 575) Perseverance cored Shuyak here; Mageik, another core from the same outcrop, went into the Three Forks depot."},
    "observation_mountain": {"名": "Observation Mountain", "说明": "A large wind-blown sand ridge (megaripple). Beside it Perseverance collected two regolith samples, Atmo Mountain (2022-12-02) and Crosswind Lake (2022-12-07): the mission's first loose-soil samples, holding dust, sand and small pebbles. Wind carries fine grains far, so one tube reflects a wide area."},
    "enchanted_lake": {"名": "Enchanted Lake", "说明": "From around here Perseverance made remote observations of Enchanted Lake, a finely layered rock that may be some of the oldest delta deposits. After finishing near sol 428 it set off for Hawksbill Gap."},
    "jezero_rim": {"名": "Jezero Crater Rim", "说明": "Jezero crater is about 45 km across. About 3.5 billion years ago it held a lake fed by a river from the west, which built the delta Perseverance is standing on. The distant hills on the horizon are the crater rim. Put it in the middle of the frame to log it."},
    "butler_landing": {"名": "Octavia E. Butler Landing", "说明": "Perseverance landed here on 18 February 2021. On 5 March 2021 NASA named the site for the science fiction writer Octavia E. Butler. The photo is from a front hazard camera on landing day."},
}
英文挑战 = {
    "tracks535": {"名": "Looking back at tracks (sol 535)", "提示": "First stop after Wildcat Ridge: look back at your own tracks."},
    "skinner490": {"名": "Skinner Ridge workspace (sol 490)", "提示": "20 m northeast of the parking spot; Navcam looks down at the rock and ripples in front of the arm."},
    "sol530": {"名": "Arm and far hills (sol 530)", "提示": "At the start point: Navcam looks southwest past the robotic arm."},
    "enchanted427": {"名": "Delta front (sol 427)", "提示": "About 520 m southwest of the parking spot, looking north at the delta-front scarp."},
}


def 补英文():
    """--只补英文：不联网，只把 英文 / 英文挑战 写进现有的 兴趣点.json（其余字段原样）。"""
    f = GD/"兴趣点.json"; d = json.loads(f.read_text())
    for p in d["兴趣点"]: p["en"] = 英文[p["id"]]
    for c in d["挑战"]: c["en"] = 英文挑战[c["id"]]
    f.write_text(json.dumps(d, ensure_ascii=False, indent=1))
    log(f"补好英文：兴趣点 {len(d['兴趣点'])} 个，挑战 {len(d['挑战'])} 个 → {f}")


if "--只补英文" in sys.argv:                                   # 数据缓存（下面的模块级代码要读）不在时也能补
    补英文(); sys.exit(0)




def load_mod(name, path):
    spec = importlib.util.spec_from_file_location(name, path); m = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(path.parent)); spec.loader.exec_module(m); return m


def m57_consts():
    """57 的常数（不导入 57：它顶层要 Blender 环境的东西不多，但只要几个数，按源码读，保证同源）。"""
    t = (HERE.parent/"Blender"/"57_实景重建.py").read_text(encoding="utf-8")
    LAT, LON, E0 = map(float, re.search(r"^LAT, LON, E0 = ([-\d.]+), ([-\d.]+), ([-\d.]+)", t, re.M).groups())
    R = float(re.search(r"^R_MARS = ([\d.]+)", t, re.M).group(1))
    O = np.array(json.loads(re.search(r"^O_LL = np.array\((\[[^\]]+\])\)", t, re.M).group(1)))
    return LAT, LON, E0, R, O


LAT0, LON0, E0, R_MARS, O_LL = m57_consts()
M_SB = np.array([[0, 1, 0], [1, 0, 0], [0, 0, -1]], float)              # 站点（北、东、下）→ ENU（东、北、上），同 57


def site26_enu(s): return (np.asarray(s, float) - O_LL) @ M_SB.T


def ll_enu(lat, lon):
    return np.array([math.radians(lon - LON0)*R_MARS*math.cos(math.radians(lat)), math.radians(lat - LAT0)*R_MARS])


# ———————————————————— MMGIS 航点
WP = {}
for f in json.loads((POSE/"MMGIS"/"M20_waypoints.json").read_text())["features"]:
    p = f["properties"]; WP[(int(p["site"]), int(p["drive"]))] = p


def wp_enu(site, drive):
    p = WP[(site, drive)]; e = ll_enu(float(p["lat"]), float(p["lon"]))
    return np.array([e[0], e[1], float(p["elev_geoid"]) - E0 - (e @ e)/(2*R_MARS)])


# ———————————————————— raw 图 API
def sol_list(sol):
    p = CACHE/"api"/f"sol_{sol:04d}.json"
    if not p.exists():
        p.parent.mkdir(parents=True, exist_ok=True)
        for k in range(4):
            r = subprocess.run(["curl", "-s", "--max-time", "400", API.format(sol)], capture_output=True)
            try: d = json.loads(r.stdout); break
            except Exception: log(f"sol {sol} 列表第 {k + 1} 次失败，重试"); time.sleep(5)
        else: raise SystemExit(f"sol {sol} 列表下不来")
        p.write_text(json.dumps(d["images"]))
    return json.loads(p.read_text())


def find(sol, iid):
    """按 imageid 找记录：先找完全相同的，没有就找同相机同 sclk、产品类型 EBY（彩色）优先。"""
    im = sol_list(sol)
    for x in im:
        if x["imageid"] == iid: return x
    head = "_".join(iid.split("_")[:3])
    xs = [x for x in im if x["imageid"].startswith(head) and x["sample_type"] == "Full"]
    xs.sort(key=lambda x: (0 if "EBY" in x["imageid"] else 1, len(x["imageid"])))
    if not xs: raise SystemExit(f"找不到 {iid}")
    return xs[0]


def 下载(x):
    u = x["image_files"].get("full_res") or x["image_files"]["large"]
    raw = CACHE/"原图"/(x["imageid"] + pathlib.Path(u).suffix)
    if not raw.exists():
        raw.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["curl", "-s", "--retry", "3", "--max-time", "300", "-o", str(raw), u], check=True)
    return Image.open(raw).convert("RGB")


def 拼(sol, x):
    """Navcam 原始图常把一幅拆成几块（imageid 里 _01_、_04_… 是块号，subframeRect 是块在全分辨率里的位置）：
    同一次曝光、同一缩放的块拼回去。返回 (图, 拼后在全分辨率里的矩形 (x0, y0, w, h)（0 起）, 缩放)。"""
    sf = float(x["extended"].get("scaleFactor", "1") or 1)
    if not x["imageid"].startswith("N") or sf <= 0:
        return 下载(x), None, sf
    head = re.sub(r"_\d\d_\d{3}J$", "_", x["imageid"])
    xs = [y for y in sol_list(sol) if y["imageid"].startswith(head) and y["extended"].get("scaleFactor") == x["extended"].get("scaleFactor")
          and y["sample_type"] == "Full"]
    rects = [tup(y["extended"]["subframeRect"]) for y in xs]
    x0 = min(r[0] for r in rects) - 1; y0 = min(r[1] for r in rects) - 1
    x1 = max(r[0] - 1 + r[2] for r in rects); y1 = max(r[1] - 1 + r[3] for r in rects)
    W = round((x1 - x0)/sf); H = round((y1 - y0)/sf)
    ims = [np.asarray(下载(y)).astype(np.float64) for y in xs]
    pos = [(round((r[0] - 1 - x0)/sf), round((r[1] - 1 - y0)/sf)) for r in rects]
    # 各块是分别拉伸过的原始图，亮度不一：用相邻块的重叠条（约 16–32 px）解每块每通道的增益（对数最小二乘，几何平均为 1）
    n = len(ims); rows = []; rhs = []
    for i in range(n):
        for j in range(i + 1, n):
            ax0 = max(pos[i][0], pos[j][0]); ay0 = max(pos[i][1], pos[j][1])
            ax1 = min(pos[i][0] + ims[i].shape[1], pos[j][0] + ims[j].shape[1]); ay1 = min(pos[i][1] + ims[i].shape[0], pos[j][1] + ims[j].shape[0])
            if ax1 - ax0 < 4 or ay1 - ay0 < 4: continue
            a = ims[i][ay0 - pos[i][1]:ay1 - pos[i][1], ax0 - pos[i][0]:ax1 - pos[i][0]].reshape(-1, 3).mean(0)
            b = ims[j][ay0 - pos[j][1]:ay1 - pos[j][1], ax0 - pos[j][0]:ax1 - pos[j][0]].reshape(-1, 3).mean(0)
            e = np.zeros(n); e[i] = 1; e[j] = -1; rows.append(e); rhs.append(np.log(np.maximum(b, 1)/np.maximum(a, 1)))
    g = np.ones((n, 3))
    if rows:
        A_ = np.vstack(rows + [np.ones(n)]); B_ = np.vstack(rhs + [np.zeros(3)])
        g = np.exp(np.linalg.lstsq(A_, B_, rcond=None)[0])
    M = np.zeros((H, W, 3))
    for im, (px, py), gi in zip(ims, pos, g):
        h, w = im.shape[:2]; M[py:py + h, px:px + w] = (im*gi)[:H - py, :W - px]
    return Image.fromarray(M.clip(0, 255).astype(np.uint8)), (x0, y0, x1 - x0, y1 - y0), sf


def photo(sol, iid, tag):
    """下载原图（Navcam 按块拼回整幅），缩成 960 宽 JPEG → 兴趣点/<tag>.jpg，返回照片条目。"""
    x = find(sol, iid)
    im, rect, sf = 拼(sol, x)
    x["_拼"] = (im, rect, sf)
    im2 = im.resize((960, round(960*im.height/im.width)), Image.LANCZOS) if im.width > 960 else im
    OUT_IMG.mkdir(parents=True, exist_ok=True); (OUT_IMG/".gdignore").touch()
    im2.save(OUT_IMG/f"{tag}.jpg", quality=86)
    m = re.search(r"M(\d\d:\d\d)", x["date_taken_mars"])
    return {"文件": f"兴趣点/{tag}.jpg", "产品": x["imageid"], "相机": CAM.get(x["camera"]["instrument"], x["camera"]["instrument"]),
            "sol": int(x["sol"]), "lmst": m.group(1) if m else "", "utc": x["date_taken_utc"][:10], "署名": x["credit"],
            "url": x["link"], "尺寸": list(im2.size), "_rec": x}


CAM = {"MCZ_LEFT": "Mastcam-Z 左", "MCZ_RIGHT": "Mastcam-Z 右", "NAVCAM_LEFT": "Navcam 左", "NAVCAM_RIGHT": "Navcam 右",
       "SHERLOC_WATSON": "WATSON（SHERLOC）", "FRONT_HAZCAM_LEFT_A": "前避障相机 左", "CACHECAM": "CacheCam"}


# ———————————————————— 兴趣点（事实只写出处里有的；坐标来源逐条写明）
SRC = {
    "jpl0915": {"题": "NASA's Perseverance Rover Investigates Geologically Rich Mars Terrain（JPL，2022-09-15）",
                "url": "https://www.jpl.nasa.gov/news/nasas-perseverance-rover-investigates-geologically-rich-mars-terrain/"},
    "样品": {"题": "Mars Rock Samples（NASA 样品表）", "url": "https://science.nasa.gov/mission/mars-2020-perseverance/mars-rock-samples"},
    "berry": {"题": "Sol 0505: Berry Hollow abrasion, Wildcat Ridge（ASU Mastcam-Z 图库）",
              "url": "https://mastcamz.asu.edu/galleries/sol-0505-berry-hollow-abrasion-wildcat-ridge-mastcam-z-mosaic/"},
    "hog": {"题": "Fine-Grained Rocks at Hogwallow Flats（NASA 博客，2022-06-23）", "url": "https://science.nasa.gov/blogs/fine-grained-rocks-at-hogwallow-flats"},
    "hogpaper": {"题": "Diagenetic History and Biosignature Preservation Potential of Fine-Grained Rocks at Hogwallow Flats, Jezero Crater, Mars（Caltech 论文库）",
                 "url": "https://authors.library.caltech.edu/records/qxxth-75h49"},
    "hawk": {"题": "Next Stop: Hawksbill Gap（NASA 博客，2022-05-16）", "url": "https://science.nasa.gov/blog/next-stop-hawksbill-gap"},
    "depot": {"题": "NASA's Perseverance Rover Deposits First Sample on Mars Surface（2022-12-21）",
              "url": "https://phys.org/news/2022-12-nasa-perseverance-rover-deposits-sample.html"},
    "depotmap": {"题": "PIA25682: Perseverance's Three Forks Sample Depot Map", "url": "https://www.jpl.nasa.gov/images/pia25682-perseverances-three-forks-sample-depot-map/"},
    "obs": {"题": "Reading the Ripples at Observation Mountain（NASA 博客）", "url": "https://science.nasa.gov/blog/reading-the-ripples-at-observation-mountain/"},
    "obsv": {"题": "Meet the Mars Samples: Atmo Mountain and Crosswind Lake（JPL）",
             "url": "https://www.jpl.nasa.gov/videos/meet-the-mars-samples-atmo-mountain-and-crosswind-lake-samples-17-and-18/"},
    "butler": {"题": "PIA24483: Welcome to 'Octavia E. Butler Landing'", "url": "https://www.jpl.nasa.gov/images/pia24483-welcome-to-octavia-e-butler-landing/"},
    "jezero": {"题": "Jezero (crater)（维基百科：直径约 45 km，中心 18.38°N 77.58°E）", "url": "https://en.wikipedia.org/wiki/Jezero_(crater)"},
    "mmgis": {"题": "MMGIS「Where is Perseverance」航点与路线（M20_waypoints.json / M20_traverse.json）",
              "url": "https://mars.nasa.gov/mmgis-maps/M20/Layers/json/M20_waypoints.json"},
}


def site26(n, e): return site26_enu([n, e, O_LL[2]])                     # 站点系 (北, 东) → ENU（高度另取）


def pois():
    P = []
    # ① Wildcat Ridge：Berry Hollow 磨蚀斑。Mastcam-Z 指向表（docs/NASA补充数据.md §2.2）：ZCAM03405 落地点站点系 (67.3 N, −24.0 E)
    P.append(dict(id="wildcat_ridge", 名="Wildcat Ridge 磨蚀斑", 英="Wildcat Ridge · Berry Hollow abrasion patch", 类="近", 发现半径=6.0,
        pos=site26(67.3, -24.0), 坐标来源="Mastcam-Z ZCAM03405 视线落地点（站点系 67.3 N、−24.0 E，docs/NASA补充数据.md §2.2）",
        说明="Wildcat Ridge 是一块约 1 米宽的岩石，可能是几十亿年前泥沙在一个正在蒸发的咸水湖里沉积而成。"
             "2022 年 7 月 20 日毅力号在它表面磨出磨蚀斑 Berry Hollow，SHERLOC 测到了任务迄今最丰富的有机物信号。"
             "随后在这块岩石上取了两根岩芯：Hazeltop（sol 509）和 Bearwallow（sol 516）。",
        事实=["jpl0915", "样品", "berry"], 照片=[(505, "ZL0_0505_0711770325_474EBY_N0261222ZCAM03405_1100LMJ", "wildcat_1")]))
    # ② Skinner Ridge：26/1004 停车点（sol 477–501），取样时机械臂在车前 2 m 左右
    P.append(dict(id="skinner_ridge", 名="Skinner Ridge 取样点", 英="Skinner Ridge", 类="近", 发现半径=6.0,
        pos=wp_enu(26, 1004), 坐标来源="MMGIS 航点 26/1004（sol 477–501 停车处；取样在机械臂工作区，离车约 2 m）",
        说明="三角洲前缘的一处岩石露头。毅力号在这里取了 Swift Run（sol 490，2022-07-07）和 Skyland（sol 495）两根沉积岩岩芯，"
             "这是它在古河流三角洲取到的第一批岩石样品。Skyland 后来被放进了 Three Forks 样品库。",
        事实=["样品", "jpl0915"], 照片=[(490, "NLF_0490_0710456117_926ECM_N0261004NCAM00709_05_095J", "skinner_1"),
                                     (490, "ZL0_0490_0710454524_239EBY_N0261004ZCAM05068_1100LMJ", "skinner_2")]))
    # ③ Hogwallow Flats：sol 472 时「车周围的这片区域」；sol 464–473 车停在 26/756
    P.append(dict(id="hogwallow_flats", 名="Hogwallow Flats", 英="Hogwallow Flats", 类="近", 发现半径=6.0,
        pos=wp_enu(26, 756), 坐标来源="MMGIS 航点 26/756（sol 464–473 停车处；NASA 博客说 sol 472 时这片区域就在车周围）",
        说明="一片浅色、颗粒很细的岩层。团队起初按 HiRISE 图上的样子叫它「培根条」（Bacon Strip），因为浅色条纹像一片培根。"
             "细颗粒岩石往往含较多黏土矿物，最有可能保存古代的有机分子。Wildcat Ridge 就属于这套岩层。",
        事实=["hog", "hogpaper", "jpl0915"], 照片=[(472, "ZL0_0472_0708840281_848EBY_N0260756ZCAM03384_1100LMJ", "hogwallow_1")]))
    # ④ sol 535 离站后第一站 26/1652：Navcam 回望车辙
    P.append(dict(id="sol535_tracks", 名="sol 535 第一站的车辙", 英="Tracks at 26/1652, sol 535", 类="近", 发现半径=12.0,
        pos=site26_enu(SOL535), 坐标来源="PDS Navcam 标签车姿 26/1652（位姿表.csv，站点系）",
        说明="sol 535 毅力号离开 Wildcat Ridge，向东开了约 85 m 停在这里，Navcam 回头拍下了自己的车辙。"
             "在游戏里的 sol 530，这段路还没有开出来。",
        事实=["mmgis"], 照片=[(535, "NLF_0535_0714445546_383ECM_N0261652NCAM02535_01_195J", "tracks_1")]))
    # ⑤ Hawksbill Gap：2022 年 5 月中旬开始爬三角洲前缘；sol 436 停在 24/3900（照片在 24/3290 拍，朝三角洲前缘）
    P.append(dict(id="hawksbill_gap", 名="Hawksbill Gap", 英="Hawksbill Gap", 类="近", 发现半径=15.0,
        pos=wp_enu(24, 3900), 坐标来源="MMGIS 航点 24/3900（sol 436）；按 NASA 博客，5 月中旬毅力号在 Hawksbill Gap 附近开始上三角洲，推断",
        说明="三角洲前缘的一个缺口。2022 年 5 月中旬，毅力号在这一带开始爬上三角洲前缘，"
             "计划沿途在不同的地层做五次近距离科学考察，一直走到 Rocky Top。",
        事实=["hawk", "mmgis"], 照片=[(436, "ZL0_0436_0705645706_223EBY_N0243290ZCAM08453_1100LMJ", "hawksbill_1")]))
    # ⑥ Three Forks 样品库：第一根管 sol 653 放在 32/148 停车处的车底下
    P.append(dict(id="three_forks", 名="Three Forks 样品库", 英="Three Forks sample depot", 类="近", 发现半径=15.0,
        pos=wp_enu(32, 148), 坐标来源="MMGIS 航点 32/148（sol 652–653，第一根样品管 Malay 放下的地方）；十根管之字形排开，彼此相隔 5–15 m",
        说明="人类在别的星球上建的第一个样品库。2022 年 12 月 21 日（sol 653）毅力号放下第一根样品管 Malay，"
             "到 2023 年 1 月 28 日（sol 690）共放下 10 根，之字形排开、彼此相隔 5–15 m，留给未来的任务来取。"
             "在这里取的 Skyland 和 Bearwallow 也在其中。在游戏里的 sol 530，样品库还没有建。",
        事实=["depot", "depotmap", "样品"], 照片=[(653, "SI1_0653_0724915290_933EBY_N0320148SRLC08040_0000LMJ", "three_forks_1")]))
    # ⑦ Amalik：Shuyak sol 575，车停在 29/0（sol 565–591）
    P.append(dict(id="amalik", 名="Amalik 露头", 英="Amalik outcrop", 类="近", 发现半径=15.0,
        pos=wp_enu(29, 0), 坐标来源="MMGIS 航点 29/0（sol 565–591 停车处，sol 575 取 Shuyak）",
        说明="三角洲前缘的一处沉积岩露头。毅力号 2022 年 10 月 2 日（sol 575）在这里取了岩芯 Shuyak；"
             "同一露头的另一根岩芯 Mageik 放进了 Three Forks 样品库。",
        事实=["样品", "mmgis"], 照片=[(575, "ZL0_0575_0717996047_178EBY_N0290000ZCAM05068_1100LMJ", "amalik_1")]))
    # ⑧ Observation Mountain：sol 632–640 停在 31/0
    P.append(dict(id="observation_mountain", 名="Observation Mountain 沙波", 英="Observation Mountain", 类="近", 发现半径=15.0,
        pos=wp_enu(31, 0), 坐标来源="MMGIS 航点 31/0（sol 632–640 停车处，旁边就是这道沙波）",
        说明="一道风吹成的大沙波。毅力号在旁边取了 Atmo Mountain（2022-12-02）和 Crosswind Lake（2022-12-07）两份风化层样品，"
             "是任务的第一批松散沙土样品，里面有尘、沙和小石子。风能把细颗粒吹很远，所以一管沙土能反映很大范围的地貌。",
        事实=["obs", "obsv", "样品"], 照片=[(634, "NLF_0634_0723238492_135ECM_N0310000NCAM00709_05_095J", "obsmtn_1"),
                                             (634, "ZL0_0634_0723237410_895EBY_N0310000ZCAM05135_1100LMJ", "obsmtn_2")]))
    # ⑨ Enchanted Lake 观察点：sol 427 停在 24/1328，远距离观察
    P.append(dict(id="enchanted_lake", 名="Enchanted Lake 观察点", 英="Enchanted Lake (remote science)", 类="近", 发现半径=15.0,
        pos=wp_enu(24, 1328), 坐标来源="MMGIS 航点 24/1328（sol 427 停车处）；露头本身在远处，位置没有公开坐标",
        说明="毅力号在这一带远距离观察了 Enchanted Lake：一片层理很细的岩石，可能是三角洲最底部的沉积。"
             "sol 428 左右完成观察后，它出发前往 Hawksbill Gap。",
        事实=["hawk", "mmgis"], 照片=[(427, "NLF_0427_0704853485_885ECM_N0241328NCAM03427_01_195J", "enchanted_1")]))
    # ⑩ 杰泽罗坑缘（远）：圆形近似，sol 530 Navcam 朝西南的那张照片方向
    az = math.radians(JEZ_AZ); d = JEZ_D
    P.append(dict(id="jezero_rim", 名="杰泽罗陨石坑坑缘", 英="Jezero crater rim", 类="远", 发现半径=0.0,
        pos=np.array([math.sin(az)*d, math.cos(az)*d, 0.0]),
        坐标来源=f"按维基百科的坑中心 18.38°N 77.58°E、直径 45 km 做圆形近似，取方位 {JEZ_AZ:.0f}°（sol 530 那张 Navcam 的朝向）上的坑缘点，约 {d/1000:.0f} km；实际坑缘不是正圆",
        说明="杰泽罗陨石坑直径约 45 km。约 35 亿年前这里是一个湖，一条河从西边流进来，在湖边堆出了毅力号脚下这片三角洲。"
             "地平线上的远山就是坑缘。拍照时把它放进画面中央即可记入图鉴。",
        事实=["jezero", "jpl0915"], 照片=[(530, "NLF_0530_0713995558_005ECM_N0261222NCAM00215_01_295J", "jezero_1")]))
    # ⑪ 着陆点（远）：MMGIS sol 0 航点
    P.append(dict(id="butler_landing", 名="Octavia E. Butler 着陆点", 英="Octavia E. Butler Landing", 类="远", 发现半径=0.0,
        pos=LANDING, 坐标来源="MMGIS 最早的航点 3/0（sol 13，第一次行驶前，18.4446°N 77.4509°E，与维基百科的着陆点坐标一致）",
        说明="2021 年 2 月 18 日毅力号在这里着陆。同年 3 月 5 日，NASA 以科幻作家奥克塔维娅·E·巴特勒的名字命名了这个着陆点。"
             "照片是着陆当天前避障相机拍的。",
        事实=["butler", "mmgis"], 照片=[(0, "FLF_0000_0666958339_058EBY_N0010052AUT_04096_00_0LLJ", "landing_1")]))
    return P


# ———————————————————— 挑战：真实 Navcam 照片 + 相机位姿
CH = [  # (id, 名, sol, imageid, 提示)
    ("tracks535", "回望车辙（sol 535）", 535, "NLF_0535_0714445546_383ECM_N0261652NCAM02535_01_195J", "离开 Wildcat Ridge 后的第一站，往回看自己的车辙。"),
    ("skinner490", "Skinner Ridge 工作区（sol 490）", 490, "NLF_0490_0710456117_926ECM_N0261004NCAM00709_05_095J", "停车点东北 20 m，Navcam 低头看机械臂前的岩石和沙纹。"),
    ("sol530", "sol 530 的机械臂与远山", 530, "NLF_0530_0713995558_005ECM_N0261222NCAM00215_01_295J", "就在出发点，Navcam 越过机械臂朝西南看。"),
    ("enchanted427", "三角洲前缘（sol 427）", 427, "NLF_0427_0704853485_885ECM_N0241328NCAM03427_01_195J", "停车点西南约 520 m，朝北看三角洲前缘的陡坎。"),
]


def tup(s): return np.array([float(v) for v in s.strip("()").split(",")])


def cam_pose(x, enu_of_rover, rect=None):
    """API 记录 → 这张图（不是整幅传感器）的相机（ENU）：C、前、上、hfov。enu_of_rover(site, drive, xyz_site) → 车原点 ENU。
    原始图常是子帧（subframeRect，传感器全分辨率像素，1 起）再缩小 scaleFactor 倍，相机模型却是整幅的，而且在 2×2 合并后的
    像素格里（Navcam：hc ≈ 1289，即 5120/2 宽的格；比例 m = 5120/(2·hc)）。所以图心方向、左右边的夹角都要先把子帧换到模型格，
    再反投影：针孔初值 + 用 71 的 cahvor（CAHVORE 正投影）做高斯-牛顿，残差 < 0.01 px。"""
    comps = [tup(c) for c in x["camera"]["camera_model_component_list"].split(";")]
    q = tup(x["attitude"]); R = M71.qrot(q)                                      # ROVER_NAV → SITE
    xyz = tup(x["extended"]["xyz"])
    site = int(re.search(r"_N(\d{3})", x["imageid"]).group(1)); drive = int(x["drive"])
    names = "CAHVORE"[:min(len(comps), 7)]
    cam = {k: comps[i] for i, k in enumerate(names)}
    if "O" not in cam: cam["O"] = cam["A"]
    if "R" not in cam: cam["R"] = np.zeros(3)
    T = int(comps[7][0]) if x["camera"]["camera_model_type"] == "CAHVORE" and len(comps) > 8 else 1
    cam["L"] = {1: 1.0, 2: 0.0}.get(T, float(comps[8][0]) if len(comps) > 8 else 1.0)
    A, H, V = cam["A"], cam["H"], cam["V"]
    hc = A @ H; hs = np.linalg.norm(np.cross(A, H)); vc = A @ V; vs = np.linalg.norm(np.cross(A, V))
    Hp = (H - hc*A)/hs; Vp = (V - vc*A)/vs

    def ray(u, v):                                                               # 像素 (u, v)（全分辨率）→ 车体系单位方向
        d = A + (u - hc)/hs*Hp + (v - vc)/vs*Vp; d /= np.linalg.norm(d)
        for _ in range(20):
            pu, pv, _z = M71.cahvor(cam, (cam["C"] + d*10.0)[None])
            r = np.array([pu[0] - u, pv[0] - v])
            if np.abs(r).max() < 0.01: break
            J = np.zeros((2, 2)); e1 = Hp; e2 = Vp
            for k, e in enumerate((e1, e2)):
                dd = d + e*1e-5; dd /= np.linalg.norm(dd)
                qu, qv, _z = M71.cahvor(cam, (cam["C"] + dd*10.0)[None]); J[:, k] = [(qu[0] - pu[0])/1e-5, (qv[0] - pv[0])/1e-5]
            st = np.linalg.solve(J, -r); d = d + st[0]*e1 + st[1]*e2; d /= np.linalg.norm(d)
        return d

    m = 2.0**round(math.log2(5120.0/(2*hc))) if x["imageid"].startswith("N") else 1.0   # 全分辨率像素 / 模型像素
    if rect is None:
        sx, sy, sw, sh = tup(x["extended"].get("subframeRect", "(1,1,%d,%d)" % (2*hc*m, 2*vc*m))); x0, y0 = sx - 1, sy - 1
    else: x0, y0, sw, sh = rect; sx, sy = x0 + 1, y0 + 1
    x0, y0, sw, sh = x0/m, y0/m, sw/m, sh/m                                      # → 模型格
    cx, cy = x0 + sw/2, y0 + sh/2
    c = ray(cx, cy); l = ray(x0, cy); r = ray(x0 + sw, cy); t = ray(cx, y0)
    rover = enu_of_rover(site, drive, xyz)
    to = lambda v: (R @ v) @ M_SB.T
    f = to(c); up = to(t) - f*(to(t) @ f); up /= np.linalg.norm(up)
    hfov = math.degrees(math.acos(np.clip(l @ r, -1, 1)))
    return dict(pos=rover + to(cam["C"]), fwd=f/np.linalg.norm(f), up=up, hfov=hfov, sub=(sx, sy, sw, sh),
                site=site, drive=drive, rover=rover, R=R, xyz=xyz, q=q, cam=cam, c=c, t=t, to=to, m=m, axis=to(A))


def 针孔(p, img, rect, sf, hfov, W=1024, H=768):
    """把（拼好的）原图去畸变成针孔：图心方向、上方向同原图，水平视场 hfov，W×H。
    每个针孔像素的视线（车体系）用 71 的 cahvor 正投影到全分辨率像素，再按拼图的位置和缩放取样（双线性）。同 57 做对照照片的办法。"""
    c = p["c"]; t = p["t"]; u = t - c*(t @ c); u /= np.linalg.norm(u); r = np.cross(c, u)
    k = math.tan(math.radians(hfov)/2)/(W/2)
    jj, ii = np.meshgrid(np.arange(W) + 0.5 - W/2, np.arange(H) + 0.5 - H/2)
    d = c[None, None] + (jj*k)[..., None]*r[None, None] - (ii*k)[..., None]*u[None, None]
    d = d.reshape(-1, 3); d /= np.linalg.norm(d, axis=1, keepdims=True)
    pu, pv, z = M71.cahvor(p["cam"], p["cam"]["C"][None] + d*10.0)
    x0, y0 = rect[0], rect[1]                                                     # 拼图在全分辨率里的左上角
    fx = (pu*p["m"] - x0)/sf - 0.5; fy = (pv*p["m"] - y0)/sf - 0.5
    a = np.asarray(img).astype(np.float32); h, w = a.shape[:2]
    ok = (fx >= 0) & (fy >= 0) & (fx < w - 1) & (fy < h - 1) & (z > 0)
    fx = np.clip(fx, 0, w - 1.001); fy = np.clip(fy, 0, h - 1.001); i0 = fy.astype(int); j0 = fx.astype(int); ty = (fy - i0)[:, None]; tx = (fx - j0)[:, None]
    o = a[i0, j0]*(1 - ty)*(1 - tx) + a[i0 + 1, j0]*ty*(1 - tx) + a[i0, j0 + 1]*(1 - ty)*tx + a[i0 + 1, j0 + 1]*ty*tx
    o[~ok] = 0
    return Image.fromarray(o.reshape(H, W, 3).clip(0, 255).astype(np.uint8)), float(ok.mean())


def rover_enu(site, drive, xyz):
    if site == 26: return site26_enu(xyz)
    return wp_enu(site, drive)


def 核对():
    """① 同一张 sol 502 Navcam 右眼照片（scene.json 对照_NRF_0M196RAS_，57 定标）：API 位姿 vs 定标位姿；
    ② sol 535 挑战图：API 车姿 vs PDS4 标签（70 parse_pose_label）；③ 26/1652：站点系 vs MMGIS。"""
    J = json.loads((GD/"scene.json").read_text())
    ref = next(c for c in J["cameras"] if c["name"].startswith("对照_NRF_0M196"))
    gp = np.array(ref["pos"]); gf = np.array(ref["fwd"])
    ref_pos = np.array([gp[0], -gp[2], gp[1]]); ref_fwd = np.array([gf[0], -gf[2], gf[1]])
    # 对照名 = 文件名前 4 字 + [18:27]（57）：在 PDS 目录里找回原文件名，取 sclk，再在 API 里找同一张图
    pds = MAP/"DEM"/"Blender缓存"/"_素材"/"PDS"/"站26_1222"
    fn = next(f.name for f in sorted(pds.glob("NRF_0502_*.png")) if f.name[18:27] == ref["name"].split("_", 1)[1][4:13])
    x = next(x for x in sol_list(502) if x["imageid"].startswith(fn[:19]) and "_" + fn[20:23] in x["imageid"])
    p = cam_pose(x, rover_enu)
    ax = p["axis"]/np.linalg.norm(p["axis"])
    dp = np.linalg.norm(p["pos"] - ref_pos); da = math.degrees(math.acos(np.clip(ax @ ref_fwd, -1, 1)))
    log(f"核对① {x['imageid'][:40]}：API 相机模型 vs 57 照片定标（光轴 A 对定标光轴）位置差 {dp*100:.1f} cm、方向差 {da:.2f}°；"
        f"这张原始图是传感器的子帧 {tuple(int(v) for v in p['sub'])}，图心视线和光轴差 {math.degrees(math.acos(np.clip(ax @ p['fwd'], -1, 1))):.1f}°")
    m70 = load_mod("m70", HERE/"70_NASA补充数据下载.py")                      # 70 的 PDS4 标签解析（位姿/标签/*.xml）
    for sol, iid in [(535, CH[0][3]), (530, CH[2][3])]:
        x = find(sol, iid); dr = x["drive"]
        labs = [l for l in sorted((POSE/"标签").glob(f"N??_{sol:04d}_*N026{int(dr):04d}*.xml"))]
        if not labs: log(f"核对② {iid[:30]}：位姿/标签 里没有同站同 drive 的 PDS 标签"); continue
        r = m70.parse_pose_label(str(labs[0]))
        d = np.linalg.norm(np.array([r["site_x_n"], r["site_y_e"], r["site_z_down"]]) - tup(x["extended"]["xyz"]))
        dq = abs(abs(np.dot([r["qw"], r["qx"], r["qy"], r["qz"]], tup(x["attitude"]))) - 1)
        log(f"核对② {iid[:30]}：API 车姿 vs PDS4 标签 {labs[0].name[:34]}（同 26/{dr}）位置差 {d*100:.2f} cm、四元数 1−|q·q'| = {dq:.1e}")
    import csv
    for sol, iid in [(530, CH[2][3]), (535, CH[0][3])]:
        x = find(sol, iid); sc = x["imageid"].split("_")[2]
        r = next((r for r in csv.DictReader(open(POSE/"位姿表.csv", encoding="utf-8")) if r["sclk"].startswith(sc.lstrip("0"))), None)
        if r: log(f"核对④ LTST：{iid[:30]} 算出 {估ltst(x)}，PDS 标签 {r['ltst'][:5]}")
    a = site26_enu(SOL535_XYZ); b = wp_enu(26, 1652)
    log(f"核对③ 26/1652：站点系 E {a[0]:.1f} N {a[1]:.1f}，MMGIS E {b[0]:.1f} N {b[1]:.1f}，水平差 {np.linalg.norm(a[:2] - b[:2]):.2f} m")


def 区(p):
    r = max(abs(p[0]), abs(p[1]))
    return "Navcam 精细区（±50 m）" if r <= 50 else ("HiRISE 区（±1 km）" if r <= 1000 else ("CTX 区（±40 km）" if r <= 40000 else "范围外"))


def 主():
    global M71, SOL535, SOL535_XYZ, LANDING, JEZ_AZ, JEZ_D
    M71 = load_mod("m71", HERE/"71_地面样块.py")
    import csv
    rows = list(csv.DictReader(open(POSE/"位姿表_按姿态.csv", encoding="utf-8")))
    r = next(r for r in rows if r["drive"] == "1652")
    SOL535_XYZ = [float(r["site_x_n"]), float(r["site_y_e"]), float(r["site_z_down"])]; SOL535 = SOL535_XYZ
    sol0 = min(WP.values(), key=lambda p: (int(p["sol"]), int(p["drive"])))      # 最早的航点：sol 13 的 3/0，第一次行驶（sol 14）之前，就是着陆点
    e = ll_enu(float(sol0["lat"]), float(sol0["lon"])); LANDING = np.array([e[0], e[1], float(sol0["elev_geoid"]) - E0 - (e @ e)/(2*R_MARS)])
    # 坑缘：sol 530 那张 Navcam 的朝向上的坑缘点（圆形近似）
    xj = find(530, CH[2][3]); pj = cam_pose(xj, rover_enu); JEZ_AZ = math.degrees(math.atan2(pj["fwd"][0], pj["fwd"][1])) % 360
    c = ll_enu(18.38, 77.58); dvec = np.array([math.sin(math.radians(JEZ_AZ)), math.cos(math.radians(JEZ_AZ))])
    pc = -c; b = pc @ dvec; JEZ_D = -b + math.sqrt(b*b - (pc @ pc - 22500.0**2))
    核对()
    if "--只核对" in sys.argv: return
    out = {"版本": 1, "生成": "scripts/Godot/75_兴趣点.py", "时间": time.strftime("%F %T"),
           "原点": "站 26/1222 导航点（LOCAL_LEVEL_26_1222，站点系 %s）；ENU：E 东、N 北、U 上（m）" % O_LL.tolist(),
           "说明": "照片在 兴趣点/（75 生成，不进 git）。类：近 = 开到发现半径内发现；远 = 拍照时在画面中央一半视场内发现。",
           "兴趣点": [], "挑战": []}
    log("兴趣点：")
    for p in pois():
        pos = np.asarray(p.pop("pos"), float); 照 = [photo(*t) for t in p.pop("照片")]
        z = 区(pos)
        if p["类"] == "近" and z not in ("Navcam 精细区（±50 m）", "HiRISE 区（±1 km）"): raise SystemExit(f"{p['id']} 不在地形范围内：{pos}")
        for f in 照: f.pop("_rec")
        p.update(E=round(float(pos[0]), 2), N=round(float(pos[1]), 2), U=round(float(pos[2]), 2), 区域=z, 照片=照,
                 事实来源=[SRC[k] for k in p.pop("事实")])
        p["en"] = 英文[p["id"]]
        out["兴趣点"].append(p)
        log(f"  {p['名']:<22} E {pos[0]:>9.1f}  N {pos[1]:>9.1f}  {z}  照片 {', '.join(f['产品'][:26] for f in 照)}")
    log("挑战：")
    for cid, 名, sol, iid, 提示 in CH:
        f = photo(sol, iid, "挑战_" + cid); x = f.pop("_rec"); img, rect, sf = x.pop("_拼")
        c = cam_pose(x, rover_enu, rect)
        hf = round(min(81.9, 0.85*c["hfov"]), 1)                             # 针孔视场：整幅 Navcam 用对照机位的 81.9°（4:3 角上仍在鱼眼画面里）
        pin, ok = 针孔(c, img, rect if rect else (c["sub"][0] - 1, c["sub"][1] - 1), sf, hf)
        pin.save(OUT_IMG/f"挑战_{cid}_针孔.jpg", quality=88)
        z = 区(c["pos"])
        if z not in ("Navcam 精细区（±50 m）", "HiRISE 区（±1 km）"): raise SystemExit(f"挑战 {cid} 不在范围内")
        m = re.search(r"M(\d\d:\d\d)", x["date_taken_mars"])
        ltst = 估ltst(x)
        yaw = math.degrees(math.atan2(*(c["R"] @ np.array([1.0, 0, 0]))[[1, 0]])) % 360    # 车头（站点系 x 北 y 东）→ 方位
        out["挑战"].append({"id": cid, "名": 名, "提示": 提示, "en": 英文挑战[cid], "产品": x["imageid"], "相机": CAM.get(x["camera"]["instrument"]),
            "sol": sol, "lmst": m.group(1) if m else "", "ltst": ltst, "utc": x["date_taken_utc"][:10], "署名": x["credit"], "url": x["link"],
            "图": f["文件"], "W": f["尺寸"][0], "H": f["尺寸"][1], "区域": z,
            "图针孔": f"兴趣点/挑战_{cid}_针孔.jpg", "针孔有效": round(ok, 3), "原图视场": round(c["hfov"], 1),
            "位姿": {"pos": [round(float(v), 3) for v in c["pos"]], "fwd": [round(float(v), 5) for v in c["fwd"]],
                     "up": [round(float(v), 5) for v in c["up"]], "hfov": hf, "离地": round(float(-(c["R"] @ tup(x["camera"]["camera_position"]))[2]), 3)},
            "车": {"E": round(float(c["rover"][0]), 2), "N": round(float(c["rover"][1]), 2), "航向": round(yaw, 1), "站": f"{c['site']}/{c['drive']}"}})
        log(f"  {名:<26} 相机 E {c['pos'][0]:.1f} N {c['pos'][1]:.1f}（{z}），朝向方位 {math.degrees(math.atan2(c['fwd'][0], c['fwd'][1])) % 360:.0f}°、"
            f"俯仰 {math.degrees(math.asin(c['fwd'][2])):.0f}°，原图视场 {c['hfov']:.1f}° → 针孔 {hf}°（有效 {ok:.0%}），LTST {ltst}")
    (GD/"兴趣点.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
    log(f"写好 {GD/'兴趣点.json'}：兴趣点 {len(out['兴趣点'])} 个，挑战 {len(out['挑战'])} 个；照片 {len(list(OUT_IMG.glob('*.jpg')))} 张在 {OUT_IMG}")


def 估ltst(x):
    """API 只给 LMST。LTST = LMST + 均时差 EOT（Mars24 算法，Allison & McEwen 2000；用拍摄时的 UTC 算）。
    核对：位姿表.csv 里 PDS 标签同时有 LMST 和 LTST，主() 里拿 sol 530、535 各一张比。"""
    import datetime as dt
    m = re.search(r"M(\d\d):(\d\d):(\d\d)", x["date_taken_mars"]); lm = int(m.group(1))*60 + int(m.group(2)) + int(m.group(3))/60
    t = lm + eot_min(dt.datetime.fromisoformat(x["date_taken_utc"][:19]).replace(tzinfo=dt.timezone.utc).timestamp())
    t %= 1440.0
    return "%02d:%02d" % (int(t)//60, int(t) % 60)


def eot_min(unix):
    """火星均时差（分钟，LTST − LMST），Mars24 / AM2000 式。"""
    jd = unix/86400.0 + 2440587.5 + (37 + 32.184)/86400.0; d = jd - 2451545.0
    M = math.radians(19.3871 + 0.52402073*d); afms = 270.3871 + 0.524038496*d
    A = [0.0071, 0.0057, 0.0039, 0.0037, 0.0021, 0.0020, 0.0018]; T = [2.2353, 2.7543, 1.1177, 15.7866, 2.1354, 2.4694, 32.8493]
    F = [49.409, 168.173, 191.837, 21.736, 15.704, 95.528, 49.095]
    pbs = sum(a*math.cos(math.radians(0.985626*d/t + f)) for a, t, f in zip(A, T, F))
    vm = (10.691 + 3.0e-7*d)*math.sin(M) + 0.623*math.sin(2*M) + 0.050*math.sin(3*M) + 0.005*math.sin(4*M) + 0.0005*math.sin(5*M) + pbs
    ls = math.radians(afms + vm)
    eot = 2.861*math.sin(2*ls) - 0.071*math.sin(4*ls) + 0.002*math.sin(6*ls) - vm
    return eot*4.0                                                         # 1° = 4 分钟


if __name__ == "__main__":
    主()
