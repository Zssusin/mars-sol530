#!/usr/bin/env python3
"""NASA 补充数据下载（docs/NASA补充数据.md）：sol 530 停车点（Wildcat Ridge，26/1222）的气象、多光谱、近拍、声音、位姿。

五个数据集，按优先级，用 --集 选：
  气象   MEDA 标定 + 派生产品，sol 520–540（PDS Atmospheres 节点）
  多光谱 Mastcam-Z 科学标定 IOF/RAD，sol 502–534 的多光谱序列（全部滤镜）+ 同序列定标靶
  近拍   WATSON 彩色 + SHERLOC ACI，Berry Hollow 磨蚀斑、取芯孔、周边岩土（sol 502–520）
  声音   SuperCam 麦克风标定录音：sol 500–545 全部 + 全任务精选（Ingenuity、激光、风）
  位姿   Navcam/Hazcam EDR 的 PDS4 标签（只要 xml）sol 500–545 + MMGIS 航点/轨迹 GeoJSON；
         下完自动从标签抽表 位姿表.csv（车姿 roll/pitch/yaw、摇臂/转向架角、桅杆、机械臂）

照 69 的做法：
  - 先列清单写到 <输出>/清单.json（每项：集、sol、url、本地路径、目录页给的大小）；
  - curl -C - 断点续传；标签（xml）里有 md5 的按 md5 校验，没有的按目录页大小粗核（±3%）；
  - 下好的文件旁边放 .ok 记号，重复运行只补缺的；进度写 <输出>/下载.log。

用法：python3 70_NASA补充数据下载.py [--输出 目录] [--集 气象,多光谱,近拍,声音,位姿] [--只列] [--只抽表]
在 fedora 上用 systemd-run --user 跑（ssh 断了不影响），见文档。
"""
import argparse
import csv
import glob
import hashlib
import json
import math
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

IMG_MIRROR = "https://planetarydata.jpl.nasa.gov/img/data/mars2020"
REGISTRY = "https://pds.mcp.nasa.gov/api/search/1/products"

OUT_DEFAULT = os.path.expanduser("~/Documents/mars-work/地图/资料/NASA补充")
ALL_SETS = ["气象", "多光谱", "近拍", "声音", "位姿"]


# ---------------------------------------------------------------- 通用

def log(out, msg):
    line = time.strftime("%H:%M:%S ") + msg
    print(line, flush=True)
    with open(os.path.join(out, "下载.log"), "a", encoding="utf-8") as f:
        f.write(line + "\n")


def get(url, tries=4, accept=None):
    for k in range(tries):
        try:
            req = urllib.request.Request(url, headers={"Accept": accept} if accept else {})
            with urllib.request.urlopen(req, timeout=120) as r:
                return r.read().decode("utf-8", "replace")
        except Exception as e:  # noqa: BLE001 —— 网络抖动，重试；404（没有这个目录）不重试
            if k == tries - 1 or getattr(e, "code", None) in (403, 404):
                raise
            time.sleep(5 * (k + 1))


_UNITS = {"": 1, "K": 1024, "M": 1024 ** 2, "G": 1024 ** 3}   # Apache 目录页的 K/M/G 是 1024 进制（「3.8M」= 4.0e6 字节）


def listing(url, pattern=r"[^\"/?]+\.[A-Za-z0-9]+"):
    """Apache / 镜像目录页 → {文件名: 大小(字节，目录页的近似值，可能为 None)}。
    兼容两种目录页：planetarydata（表格，大小如 97K）和 pds-geosciences / pds-atmospheres（<pre> 或表格）。"""
    try:
        html = get(url)
    except Exception:  # noqa: BLE001 —— 没有这个目录
        return {}
    out = {}
    iis = "[To Parent Directory]" in html          # pds-geosciences（IIS）：「日期 时间 字节数 <A HREF="/全路径">名</A><br>」
    prev_end = 0
    for m in re.finditer(r'href="([^"]*)"(.*?)(?=href="|$)', html, re.S | re.I):
        before, prev_end = html[prev_end:m.start()], m.end(1)
        name = urllib.parse.unquote(m.group(1).rstrip("/").rsplit("/", 1)[-1])
        if m.group(1).endswith("/") or name.startswith("?") or not re.fullmatch(pattern, name):
            continue
        sz = None
        if iis:
            s = re.search(r"(\d+)\s*<A\s*$", before, re.I)
            if s:
                sz = int(s.group(1))
        else:
            tail = re.sub(r"<[^>]+>", " ", m.group(2)).replace("&nbsp;", " ")
            s = re.search(r"\s(\d+(?:\.\d+)?)([KMG]?)\s*(?:B\b|\s|$)", tail)
            if s:
                sz = int(float(s.group(1)) * _UNITS[s.group(2)])
        if name not in out or (out[name] is None and sz):
            out[name] = sz
    return out


def subdirs(url):
    try:
        html = get(url)
    except Exception:  # noqa: BLE001
        return []
    path = urllib.parse.urlparse(url).path
    out = set()
    for h in re.findall(r'href="([^"?]+)/"', html, re.I):
        if h.startswith("/") and not (h + "/").startswith(path):     # 上级目录
            continue
        d = urllib.parse.unquote(h.rsplit("/", 1)[-1])
        if d and d not in (".", ".."):
            out.add(d)
    return sorted(out)


def registry(q, fields="ops:Data_File_Info.ops:file_ref,ops:Label_File_Info.ops:file_ref", limit=1000):
    """PDS Registry API：返回 [(lidvid, [文件 URL …])]，自动翻页"""
    res, start = [], 0
    while True:
        url = f"{REGISTRY}?q={urllib.parse.quote(q)}&fields={fields}&limit={limit}&start={start}"
        d = json.loads(get(url, accept="application/json"))
        data = d.get("data", [])
        for p in data:
            refs = []
            for v in p.get("properties", {}).values():
                refs += v if isinstance(v, list) else [v]
            res.append((p.get("id", ""), refs))
        hits = d.get("summary", {}).get("hits", 0)
        start += len(data)
        if not data or start >= hits:
            return res


def md5_of(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 22), b""):
            h.update(b)
    return h.hexdigest()


def label_md5(xml_path, data_name):
    """PDS4 标签里 data_name 对应的 md5（File 块里 file_name 后面最近的 md5_checksum）"""
    t = open(xml_path, encoding="utf-8", errors="replace").read()
    m = re.search(r"<file_name>\s*" + re.escape(data_name) + r"\s*</file_name>(?:(?!<file_name>).)*?<md5_checksum>\s*([0-9a-fA-F]{32})",
                  t, re.S)
    return m.group(1).lower() if m else None


def fetch(url, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    r = subprocess.run(["curl", "-sS", "-f", "-L", "--retry", "5", "--retry-delay", "10", "--connect-timeout", "60",
                        "-C", "-", "-o", dst, url])
    if r.returncode == 33:          # 服务器不支持续传：从头下
        os.remove(dst)
        r = subprocess.run(["curl", "-sS", "-f", "-L", "--retry", "5", "--retry-delay", "10", "-o", dst, url])
    return r.returncode == 0


def item(ds, sol, url, sub, size=None):
    """sub：本地相对路径（不含集名）"""
    return {"集": ds, "sol": sol, "url": url, "本地": f"{ds}/{sub}", "大小": size}


# ---------------------------------------------------------------- ① 气象：MEDA
# PDS Atmospheres 节点 mars2020_meda（第 16 次发布，2026-08-11）。每 sol 每传感器一个 CSV（1 Hz）+ PDS4 标签（带 md5）。
# 风（WS）的标定/派生产品只到 sol 315（风传感器 sol 313/315 被吹起的碎屑打坏），sol 520–540 没有风。
# 所以另取 sol 36–315 的 DER_WS 抽样做「日变化气候」，外加两份公开的光学厚度表（Smith 2024 TIRS 红外 τ、Lemmon Mastcam-Z 可见光 τ）。

MEDA = "https://pds-atmospheres.nmsu.edu/PDS/data/PDS4/Mars2020/mars2020_meda"
MEDA_SOLS = range(520, 541)
# 只要游戏用得上、且不重复的：
#   CAL：ATS（气温）、RDS（辐射与尘埃传感器，天空亮度）、TIRS（地温、上/下行长波、上行短波）
#   DER：PS（气压，单一传感器）、RHS（相对湿度 + 体积混合比）、ANCILLARY（太阳天顶角、车姿）
#   不要：ENG（仪器内务）、CAL_PS / CAL_RHS（DER 已经给了选好的单一值）、DER_TIRS（只是 CAL_TIRS 的长波子集）、原始 EDR
MEDA_CAL = ("ATS", "RDS", "TIRS")
MEDA_DER = ("PS", "RHS", "ANCILLARY")
MEDA_SKYCAM_SOLS = (530,)                                  # SkyCam 天空图只要 sol 530（全 21 sol 有 674 MB）
MEDA_WS_SOLS = (50, 100, 150, 200, 250, 300, 313, 314)     # 风：sol 520–540 没有，取 sol 36–315 里 8 个 sol 的 DER_WS 做日变化参考
MEDA_DOCS = ("meda_env_rdr_sis.pdf", "meda_release_notes.txt", "meda_bundle_sis.pdf")
TAU_FILES = {   # Mendeley Data，CC BY 4.0
    "Smith2024_TIRS_tau_total.txt": "https://data.mendeley.com/public-files/datasets/jb26sh4j57/files/26018c0e-50a4-4430-9bbe-619625a3fc54/file_downloaded",
    "Smith2024_TIRS_tau_dust_ice.txt": "https://data.mendeley.com/public-files/datasets/jb26sh4j57/files/96f2116a-8431-4f62-bbf5-9a49ab5a9301/file_downloaded",
    "Lemmon_MastcamZ_tau.txt": "https://data.mendeley.com/public-files/datasets/gktjp9jptb/files/5eb62f12-eadf-4e87-b4bc-2966f7a5f00c/file_downloaded",
    "Lemmon_MastcamZ_tau_readme.txt": "https://data.mendeley.com/public-files/datasets/gktjp9jptb/files/a7497ea6-eed4-4db8-9666-59ad064ff3af/file_downloaded",
}


def meda_sol_dir(coll, sol):
    lo = 0 if sol < 90 else 90 if sol < 180 else 180 + (sol - 180) // 120 * 120
    hi = 89 if sol < 90 else 179 if sol < 180 else lo + 119
    return f"{MEDA}/{coll}/sol_{lo:04d}_{hi:04d}/sol_{sol:04d}/"


def build_meda():
    items = []
    for sol in MEDA_SOLS:
        for coll, keep in (("data_calibrated_env", MEDA_CAL), ("data_derived_env", MEDA_DER)):
            u = meda_sol_dir(coll, sol)
            for n, sz in listing(u, r"WE__[A-Z0-9_]+\.(?:CSV|xml)").items():
                sensor = re.match(r"WE__\d{4}_+[A-Z]{3}_([A-Z]+)", n).group(1)
                if sensor in keep:
                    items.append(item("气象", sol, u + n, f"sol{sol:04d}/{n}", sz))
        u = f"{MEDA}/data_skycam/sol/{sol:05d}/ids/rdr/"     # SkyCam 天空相机：只要 RDR
        for sub in (subdirs(u) if sol in MEDA_SKYCAM_SOLS else []):
            for n, sz in listing(u + sub + "/", r"[A-Z0-9_]+\.(?:IMG|xml)").items():
                items.append(item("气象", sol, f"{u}{sub}/{n}", f"skycam/sol{sol:04d}/{n}", sz))
    for sol in MEDA_WS_SOLS:
        u = meda_sol_dir("data_derived_env", sol)
        for n, sz in listing(u, r"WE__[A-Z0-9_]+\.(?:CSV|xml)").items():
            if "_DER_WS_" in n:
                items.append(item("气象", sol, u + n, f"风_sol36-315/sol{sol:04d}/{n}", sz))
    for n in MEDA_DOCS:
        items.append(item("气象", 0, f"{MEDA}/document/{n}", f"文档/{n}"))
    items.append(item("气象", 0, f"{MEDA}/readme.txt", "文档/readme.txt"))
    for n, u in TAU_FILES.items():
        items.append(item("气象", 0, u, f"光学厚度/{n}"))
    return items


def _read_meda(path, cols):
    """MEDA CSV → [(LTST 小时数(浮点), {列: 值})]；空值和 9999999999 跳过"""
    rows = []
    with open(path, newline="", encoding="utf-8", errors="replace") as f:
        for r in csv.DictReader(f):
            m = re.match(r"\d+ (\d\d):(\d\d):(\d\d)", r.get("LTST", ""))
            if not m:
                continue
            h = int(m.group(1)) + int(m.group(2)) / 60 + int(m.group(3)) / 3600
            v = {}
            for c in cols:
                try:
                    x = float(r[c])
                    if abs(x) < 1e9:
                        v[c] = x
                except (KeyError, TypeError, ValueError):
                    pass
            rows.append((h, v))
    return rows


def meda_table(out):
    """气象/逐时表.csv：sol 520–540 每个 LTST 小时的均值
    p_pa = DER_PS PRESSURE；t_air_k = 桅杆上 3 个 ATS 每秒取最低（受车体加热最少）再平均；
    t_ground_k = CAL_TIRS GROUND_TEMP（亮温）；rh_pct = DER_RHS LOCAL_RELATIVE_HUMIDITY（相对湿度传感器所在温度下）；
    sw_up = CAL_TIRS UPWARD_SW_IRRADIANCE（地面反射短波，W/m²）"""
    rows_out = []
    for sol in MEDA_SOLS:
        d = os.path.join(out, "气象", f"sol{sol:04d}")
        acc = {}

        def add(h, key, x):
            a = acc.setdefault((int(h), key), [0.0, 0])
            a[0] += x
            a[1] += 1

        for pat, cols, fn in (
                ("*DER_PS_*.CSV", ["PRESSURE"], lambda v: [("p_pa", v["PRESSURE"])] if "PRESSURE" in v else []),
                ("*CAL_ATS_*.CSV", ["ATS_LOCAL_TEMP1", "ATS_LOCAL_TEMP2", "ATS_LOCAL_TEMP3"],
                 lambda v: [("t_air_k", min(v.values()))] if len(v) == 3 else []),
                ("*CAL_TIRS_*.CSV", ["GROUND_TEMP", "UPWARD_SW_IRRADIANCE"],
                 lambda v: [(k2, v[k1]) for k1, k2 in (("GROUND_TEMP", "t_ground_k"), ("UPWARD_SW_IRRADIANCE", "sw_up")) if k1 in v]),
                ("*DER_RHS_*.CSV", ["LOCAL_RELATIVE_HUMIDITY"],
                 lambda v: [("rh_pct", v["LOCAL_RELATIVE_HUMIDITY"])] if v else [])):
            for f in glob.glob(os.path.join(d, pat)):
                for h, v in _read_meda(f, cols):
                    for k, x in fn(v):
                        add(h, k, x)
        for hour in range(24):
            r = {"sol": sol, "ltst_h": hour}
            for k in ("p_pa", "t_air_k", "t_ground_k", "sw_up", "rh_pct"):
                a = acc.get((hour, k))
                r[k] = round(a[0] / a[1], 2) if a else ""
                r["n_" + k] = a[1] if a else 0
            if any(r["n_" + k] for k in ("p_pa", "t_air_k", "t_ground_k")):
                rows_out.append(r)
    cols = ["sol", "ltst_h", "p_pa", "t_air_k", "t_ground_k", "sw_up", "rh_pct",
            "n_p_pa", "n_t_air_k", "n_t_ground_k", "n_sw_up", "n_rh_pct"]
    with open(os.path.join(out, "气象", "逐时表.csv"), "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=cols)
        w.writeheader()
        w.writerows(rows_out)
    log(out, f"气象逐时表：{len(rows_out)} 行（sol × LTST 小时）→ 气象/逐时表.csv")

# ---------------------------------------------------------------- ② 多光谱：Mastcam-Z
# planetarydata 镜像 mars2020_mastcamz_sci_calibrated/data/<sol>/{iof,rad}/。文件名第 2–3 位是滤镜：ZL0–ZL6、ZR0–ZR6（L0/R0 是 Bayer RGB）。
# 选法：
#   - 「多光谱序列」= 一个序列里出现 ≥ 10 种滤镜；ZCAM01025（sol 531，含 L7/R7 太阳滤镜的天空/太阳序列）不要；
#   - 多光谱序列的 IOF 全取（IMG + xml）；
#   - 只留「看地面」的序列：任一帧视线落地点离车 ≤ 6 m（含和 Navcam 工作区 NCAM00712 重叠的、磨蚀斑、车旁岩土），
#     加上同一 sol 的定标靶序列；看天/看远处的（ZCAM03421、03425、03426）不要；
#   - 只取 IOF（IOF 按 IMG 内嵌 ODL 标签的 SCALING_FACTOR 换算就是对的，见文档 §2.3）；
#     RAD 只给 Berry Hollow 磨蚀斑（sol 505 ZCAM03405）和它的定标靶（ZCAM03022），用来核对 IOF = RAD × IOF_CONV_COEFF。
# 定标靶 / 工作区重叠由每个指向的 L0 帧标签算：CAHVOR 模型的 C、A（ROVER_NAV 坐标）→ 视线与地面（z=0）的交点。

ZCAM_SCI = f"{IMG_MIRROR}/mars2020_mastcamz_sci_calibrated/data"
ZCAM_SOLS = range(502, 535)
ZCAM_SKIP = {"ZCAM01025"}
ZCAM_RAD = {(505, "ZCAM03405"), (505, "ZCAM03022")}
ZCAM_NEAR_M = 6.0
WORKSPACE_XY = None          # Navcam 工作区视线落地点（SITE 坐标，x 北 y 东，米），运行时由 workspace_xy() 从下面这个标签算
WORKSPACE_LABEL = f"{IMG_MIRROR}/mars2020_navcam_ops_raw/data/sol/00530/ids/edr/ncam/NLF_0530_0714000362_041EDR_N0261222NCAM00712_01_095J01.xml"


def _vec(el, path):
    e = el.find(path, NS)
    if e is None:
        return None
    try:
        return [float(c.text) for c in list(e)[:3]]
    except (TypeError, ValueError):
        return None


def view_geom(xml_text):
    """标签 → 相机视线：rover / SITE 坐标的方位、俯仰，视线落地点（SITE 坐标）、斜距、太阳高度"""
    root = ET.fromstring(xml_text.encode("utf-8"))
    cm = next(root.iter("{http://pds.nasa.gov/pds4/geom/v1}Camera_Model_Parameters"), None)
    if cm is None:
        return None
    C = _vec(cm, ".//geom:Vector_Center")
    A = _vec(cm, ".//geom:Vector_Axis")
    nav = None
    for csd in root.iter("{http://pds.nasa.gov/pds4/geom/v1}Coordinate_Space_Definition"):
        idx = csd.find("geom:Coordinate_Space_Present/geom:Coordinate_Space_Indexed", NS)
        if idx is not None and (idx.findtext("geom:coordinate_space_frame_type", "", NS) or "").strip() == "ROVER_NAV_FRAME":
            o = [_num(csd, f"geom:Vector_Origin_Offset/geom:{c}_position") for c in "xyz"]
            q = [_num(csd, f"geom:Quaternion_Plus_Direction/geom:{c}") for c in ("qcos", "qsin1", "qsin2", "qsin3")]
            nav = (o, q)
            break
    if not C or not A or not nav or None in nav[0] or None in nav[1]:
        return None
    (ox, oy, oz), (w, x, y, z) = nav
    R = [[1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)],
         [2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)],
         [2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)]]

    def rot(v):
        return [sum(R[i][j] * v[j] for j in range(3)) for i in range(3)]

    As = rot(A)
    g = {"az_site": round(math.degrees(math.atan2(As[1], As[0])) % 360, 2),
         "el_site": round(-math.degrees(math.asin(max(-1, min(1, As[2])))), 2),
         "az_rover": round(math.degrees(math.atan2(A[1], A[0])) % 360, 2),
         "el_rover": round(-math.degrees(math.asin(max(-1, min(1, A[2])))), 2)}
    if A[2] > 0.05:      # 落地点：ROVER_NAV 的 z=0 近似地面（原点在车轮着地面附近，z 向下）
        t = -C[2] / A[2]
        P = [c + t * a for c, a in zip(C, A)]
        Ps = [a + b for a, b in zip(rot(P), (ox, oy, oz))]
        g.update(hit_x_n=round(Ps[0], 3), hit_y_e=round(Ps[1], 3), range_m=round(t, 3),
                 hit_dist_rover=round(math.hypot(P[0], P[1]), 3))
        td = (-1.1 - C[2]) / A[2]            # 甲板高度约 1.1 m：视线在这个高度的位置（rover 坐标）
        g.update(deck_x=round(C[0] + td * A[0], 3), deck_y=round(C[1] + td * A[1], 3))
    m = re.search(r"<geom:solar_elevation[^>]*>([-\d.]+)<", xml_text)
    g["sun_el"] = float(m.group(1)) if m else None
    m = re.search(r"<local_true_solar_time>([^<]+)<", xml_text)
    g["ltst"] = m.group(1) if m else ""
    return g


def workspace_xy():
    global WORKSPACE_XY
    if WORKSPACE_XY is None:
        g = view_geom(get(WORKSPACE_LABEL))
        WORKSPACE_XY = (g["hit_x_n"], g["hit_y_e"])
    return WORKSPACE_XY


def zcam_class(g):
    """'定标靶'、'工作区'（落地点离 NCAM00712 视线落地点 ≤ 3 m）或 ''"""
    if g is None:
        return ""
    if g["el_rover"] < -20 and abs(g.get("deck_x", 9)) < 1.0 and abs(g.get("deck_y", 9)) < 1.0:
        return "定标靶"         # 朝下、视线在甲板高度落在车身上：甲板上的定标靶
    if "hit_x_n" in g:
        wx, wy = workspace_xy()
        if math.hypot(g["hit_x_n"] - wx, g["hit_y_e"] - wy) <= 3.0:
            return "工作区"
    return ""


def build_zcam():
    items = []
    for sol in ZCAM_SOLS:
        lists = {k: listing(f"{ZCAM_SCI}/{sol:04d}/{k}/", r"[A-Z0-9_]+\.(?:IMG|xml)") for k in ("iof", "rad")}
        seqs = {}
        for n in lists["iof"]:
            m = re.search(r"(ZCAM\d{5})", n)
            if m and n.endswith(".IMG"):
                seqs.setdefault(m.group(1), set()).add(n[:3])
        for seq, filters in sorted(seqs.items()):
            if len(filters) < 10 or seq in ZCAM_SKIP:
                continue
            classes, near = set(), False
            for n in sorted(lists["iof"]):
                if seq in n and n.startswith("ZL0") and n.endswith(".xml"):
                    try:
                        g = view_geom(get(f"{ZCAM_SCI}/{sol:04d}/iof/{n}"))
                    except Exception:  # noqa: BLE001
                        continue
                    classes.add(zcam_class(g))
                    near |= bool(g) and (g.get("hit_dist_rover") or 99) <= ZCAM_NEAR_M
            if not (near or "定标靶" in classes):
                continue
            for kind in ("iof", "rad") if (sol, seq) in ZCAM_RAD else ("iof",):
                for n, sz in lists[kind].items():
                    if seq in n:
                        items.append(item("多光谱", sol, f"{ZCAM_SCI}/{sol:04d}/{kind}/{n}",
                                          f"sol{sol:04d}/{seq}/{kind}/{n}", sz))
    doc = f"{IMG_MIRROR}/mars2020_mastcamz_sci_calibrated/document"
    for n in ZCAM_DOCS:
        items.append(item("多光谱", 0, f"{doc}/{n}", f"文档/{n}"))
    return items


ZCAM_DOCS = ("mastcamz_derived_product_sis_v1.5.pdf",   # Bailey 2023：IOF/RAD 定义、标签（§2.1.4、§3.1.2、§3.2.8、§5）
             "mastcamz_radiometric_cal.pdf",            # Kinch 2020：定标靶、IOF 换算（§5.4）
             "mastcamz_release_notes.txt")


def zcam_table(out):
    """多光谱/指向表.csv：每个 L0/R0 帧（一个指向一行）的视线、落地点、分类"""
    rows = []
    for f in sorted(glob.glob(os.path.join(out, "多光谱", "sol*", "ZCAM*", "iof", "Z[LR]0_*.xml"))):
        try:
            g = view_geom(open(f, encoding="utf-8", errors="replace").read())
        except ET.ParseError:
            continue
        n = os.path.basename(f)
        rows.append({"文件": n, "sol": int(n[4:8]), "序列": re.search(r"(ZCAM\d{5})", n).group(1),
                     "分类": zcam_class(g), **(g or {})})
    cols = ["sol", "序列", "文件", "分类", "ltst", "sun_el", "az_site", "el_site", "az_rover", "el_rover",
            "hit_x_n", "hit_y_e", "range_m", "hit_dist_rover", "deck_x", "deck_y"]
    with open(os.path.join(out, "多光谱", "指向表.csv"), "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    log(out, f"多光谱指向表：{len(rows)} 帧；工作区 {sum(r['分类'] == '工作区' for r in rows)}，"
             f"定标靶 {sum(r['分类'] == '定标靶' for r in rows)}；工作区视线落地点 SITE {workspace_xy()}")

# ---------------------------------------------------------------- ③ 近拍：WATSON / ACI
# planetarydata 镜像 mars2020_imgops/{data_watson_imgops,data_aci_imgops}/sol/<sol5>/ids/{edr,fdr,rdr}/shrlc/。
# WATSON 只有「车上合成的景深合成（z-stack）」有标定彩色产品（RAD，3 波段 1184×1584）；单帧都是原始 Bayer EDR。
# 标签里没有目标名，目标是按 CAHVOR 相机中心（rover 坐标）认的，见文档 §3。
# 本站 sol 502–520 有 WATSON 的 sol：503 504 505 511 514 517；sol 509 / 516（取芯）当天没有 WATSON。

IMGOPS = f"{IMG_MIRROR}/mars2020_imgops"
WATSON_PICKS = [   # (仪器目录, sol, 级别, 序列, 产品类型正则)
    ("watson", 504, "rdr", "SRLC00033", "RAD"),   # Berry Hollow 磨蚀后，景深合成彩色
    ("watson", 504, "edr", "SRLC00033", "EDM"),   #   景深图
    ("watson", 504, "rdr", "SRLC08038", "RAD"),   # Berry Hollow 单帧 RAD
    ("watson", 505, "rdr", "SRLC00009", "RAD"),   # sol 505 景深合成（磨蚀斑 + 周边）
    ("watson", 505, "edr", "SRLC00009", "EDM"),
    ("watson", 505, "edr", "SRLC00448", "EDR"),   # Berry Hollow 全幅原始帧（10 张对焦序列）
    ("watson", 511, "rdr", "SRLC00066", "RAD"),   # sol 511 夜间 LED 照明景深合成（可能是 Hazeltop 取芯点）
    ("watson", 511, "edr", "SRLC00066", "EDM"),
    ("watson", 514, "rdr", "SRLC00003", "RAD"),
    ("aci", 505, "rdr", "SRLC11420", "RAD"),      # SHERLOC ACI 灰度 ~10 µm/像素：Berry Hollow
    ("aci", 513, "rdr", "SRLC10300", "RAD"),
    ("aci", 513, "rdr", "SRLC10402", "RAD"),
    ("aci", 514, "rdr", "SRLC00003", "RAD"),
]
WATSON_BROWSE = [(504, "SRLC00033"), (505, "SRLC00009"), (511, "SRLC00066"), (514, "SRLC00003")]   # EZS 彩色预览 PNG


def latest_versions(names):
    """同一产品（去掉 Jnn 版本号）只留最大版本；IMG 和 xml 一起留"""
    best = {}
    for n in names:
        m = re.match(r"(.+)J(\d\d)\.(IMG|xml|png)$", n)
        if not m or n.endswith(".1.xml"):
            continue
        k = (m.group(1), m.group(3))
        if k not in best or int(m.group(2)) > best[k][0]:
            best[k] = (int(m.group(2)), n)
    return sorted(n for _, n in best.values())


def build_watson():
    items = []
    for inst, sol, lvl, seq, ptype in WATSON_PICKS:
        u = f"{IMGOPS}/data_{inst}_imgops/sol/{sol:05d}/ids/{lvl}/shrlc/"
        files = listing(u, r"[A-Z0-9_]+\.(?:IMG|xml)")
        sel = [n for n in files if re.match(rf"S[IC]\d_{sol:04d}_\d{{10}}_\d{{3}}{ptype}_N\d{{7}}{seq}_", n)]
        for n in latest_versions(sel):
            items.append(item("近拍", sol, u + n, f"{inst}/sol{sol:04d}/{seq}/{n}", files[n]))
    for sol, seq in WATSON_BROWSE:
        u = f"{IMGOPS}/browse/sol/{sol:05d}/ids/edr/shrlc/"
        files = listing(u, r"[A-Za-z0-9_]+\.png")
        sel = [n for n in files if re.match(rf"SI\d_{sol:04d}_\d{{10}}_\d{{3}}EZS_N\d{{7}}{seq}_", n)]
        for n in latest_versions(sel):
            items.append(item("近拍", sol, u + n, f"预览/sol{sol:04d}/{n}", files[n]))
    return items

# ---------------------------------------------------------------- ④ 声音：SuperCam 麦克风
# PDS Geosciences 节点 mars2020_supercam/data_calibrated_audio。每个产品一个 FITS（SOUND 表，单位 Pa）+ 一个 WAV（float32），各带 xml。
# 只取 FITS（Pa 标定；godot/声音/来源.md 已说明 WAV 是归一化过的，不能当 Pa 用），全任务精选里 WAV 也取一份方便试听。
# CA2 = 独立录音（25 kHz），CA0 = 激光同步录音（100 kHz）。

SCAM_AUDIO = "https://pds-geosciences.wustl.edu/m2020/urn-nasa-pds-mars2020_supercam/data_calibrated_audio"
AUDIO_SOLS = range(500, 546)
AUDIO_CA0_TARGETS = ("berry_hollow", "hazeltop", "bearwallow")         # 本站的激光声：磨蚀斑、两个取芯点
AUDIO_PICKS = [   # (sol, 文件名里要有的字样, 要不要 WAV)：全任务精选
    (69, "_heli_", True),               # Ingenuity 第 4 次飞行
    (37, "_hedgehog_", True),            # 激光打岩石（Hedgehog），取前 3 个点
    (114, "_rsm_", True),               # 桅杆电机
]   # 尘卷风 sol 215、正午阵风 sol 148、本站 sol 525/526/538 已在 资料/声音/pds/（godot/声音/来源.md）
NASA_SOUNDS = "https://assets.science.nasa.gov/content/dam/science/psd/mars/downloadable_items"
NASA_SOUND_FILES = [   # NASA 公开发布的「火星之声」，见文档 §4.3 许可
    "4/46086_20210507_HelicopterFliesOnMars.wav",
    "4/5/45830_SCAM_MIC_SOL012_RUN001.wav",
    "4/5/45827_SCAM_MIC_SOL004_RUN001.wav",
    "4/5/45824_SCAM_MIC_SOL001_RUN001.wav",
    "4/5/45856_FILTERED_HIGHLIGHTS_-_Sol16RoverDriveHighlights.wav",
    "4/5/45704_1st_Sounds_from_Mars_filters_out_rover_self-noise.wav",
    "4/8/48520_E1-PIA26041-The_Sound_of_MOXIE_at_Work_on_Mars.wav",
]
AUDIO_HAVE = os.path.expanduser("~/Documents/mars-work/地图/资料/声音/pds")   # 已有的录音不再下
SCAM_DOCS = (   # 麦克风观测表（每段录音的 sol、LTST、目标距离、增益…）和用户指南、发布说明
    "https://pds-geosciences.wustl.edu/m2020/urn-nasa-pds-mars2020_supercam/data_derived_audio/supercam_microphone.csv",
    "https://pds-geosciences.wustl.edu/m2020/urn-nasa-pds-mars2020_supercam/data_derived_audio/supercam_microphone.xml",
    "https://pds-geosciences.wustl.edu/m2020/urn-nasa-pds-mars2020_supercam/document/SuperCam_PDS_Userguide.pdf",
    "https://pds-geosciences.wustl.edu/m2020/urn-nasa-pds-mars2020_supercam/document/mars2020_supercam_release_notes.txt",
)


def build_audio():
    items = []
    sols = list(AUDIO_SOLS) + [s for s, _, _ in AUDIO_PICKS]
    for sol in sols:
        u = f"{SCAM_AUDIO}/sol_{sol:05d}/"
        files = listing(u, r"[a-z0-9_]+\.(?:fits|wav|xml)")
        picks = [(k, w) for s, k, w in AUDIO_PICKS if s == sol]
        for n in sorted(files):
            stem = n[:-4] if n.endswith((".wav", ".xml")) else n[:-5]
            is_wav = stem.startswith("ascam_")
            if sol in AUDIO_SOLS:
                want = "_ca2_" in n or any(t in n for t in AUDIO_CA0_TARGETS)
                want = want and not is_wav
            else:
                hit = [w for k, w in picks if k in n]
                want = bool(hit) and (not is_wav or hit[0])
                if want and "_hedgehog_" in n:
                    want = re.search(r"_0[123]p0\d\.", n) is not None
            if want and os.path.exists(os.path.join(AUDIO_HAVE, n)):
                continue
            if want:
                items.append(item("声音", sol, u + n, f"supercam/sol{sol:04d}/{n}", files[n]))
    for f in NASA_SOUND_FILES:
        items.append(item("声音", 0, f"{NASA_SOUNDS}/{f}", f"NASA公开/{f.rsplit('/', 1)[-1]}"))
    for u in SCAM_DOCS:
        if os.path.exists(os.path.join(AUDIO_HAVE, u.rsplit("/", 1)[-1])):
            continue
        items.append(item("声音", 0, u, f"文档/{u.rsplit('/', 1)[-1]}"))
    return items

# ---------------------------------------------------------------- ⑤ 位姿：工程相机标签 + MMGIS

POSE_SOLS = range(500, 546)
MMGIS = "https://mars.nasa.gov/mmgis-maps/M20/Layers/json"


def pick_labels(names):
    """同一张图（同一相机 + 同一 sclk）只留一个标签：EDR 优先、左眼优先、版本号最大"""
    best = {}
    for n in names:
        m = re.match(r"([NFR])([LR])([A-Z])_(\d{4})_(\d{10})_(\d{3})(\w{3})_.*J(\d\d)\.xml$", n)
        if not m:
            continue
        cam, eye, _, _, sclk, ms, ptype, ver = m.groups()
        key = (cam, sclk, ms)
        score = (ptype == "EDR", eye == "L", int(ver))
        if key not in best or score > best[key][0]:
            best[key] = (score, n)
    return sorted(n for _, n in best.values())


def build_pose():
    items = []
    for sol in POSE_SOLS:
        for bundle, cams in (("navcam", ("ncam",)), ("hazcam", ("fcam", "rcam"))):
            for cam in cams:
                u = f"{IMG_MIRROR}/mars2020_{bundle}_ops_raw/data/sol/{sol:05d}/ids/edr/{cam}/"
                files = listing(u, r"[A-Z0-9_]+\.xml")
                for n in pick_labels(files):
                    items.append(item("位姿", sol, u + n, f"标签/sol{sol:04d}/{n}", files[n]))
    for n in ("M20_waypoints.json", "M20_traverse.json", "M20_waypoints_current.json"):
        items.append(item("位姿", 0, f"{MMGIS}/{n}", f"MMGIS/{n}"))
    return items


NS = {"geom": "http://pds.nasa.gov/pds4/geom/v1"}


def _num(el, path):
    e = el.find(path, NS)
    return float(e.text) if e is not None and e.text not in (None, "") else None


def quat_rpy(w, x, y, z):
    """ROVER_NAV → SITE 的四元数 → roll/pitch/yaw（度，ZYX 欧拉角）。
    已核对：sol 530 Navcam 标签算出 −14.25 / −1.94 / −107.79，与 MMGIS 航点 26/1222 的 −14.24 / −1.87 / −107.79 一致。"""
    r00 = 1 - 2 * (y * y + z * z)
    r10 = 2 * (x * y + w * z)
    r20 = 2 * (x * z - w * y)
    r21 = 2 * (y * z + w * x)
    r22 = 1 - 2 * (x * x + y * y)
    return (math.degrees(math.atan2(r21, r22)), math.degrees(math.asin(max(-1, min(1, -r20)))),
            math.degrees(math.atan2(r10, r00)))


def parse_pose_label(path):
    t = open(path, encoding="utf-8", errors="replace").read()
    row = {"文件": os.path.basename(path)}
    for k, pat in (("sol", r"<mars2020:sol_number>(\d+)<"), ("sclk", r"<mars2020:spacecraft_clock_start>([\d.]+)<"),
                   ("utc", r"<start_date_time>([^<]+)<"), ("ltst", r"<local_true_solar_time>([^<]+)<"),
                   ("lmst", r"<mars2020:start_local_mean_solar_time>([^<]+)<")):
        m = re.search(pat, t)
        row[k] = m.group(1) if m else ""
    root = ET.fromstring(t.encode("utf-8"))
    # 一个标签可能有好几个 Geometry_Lander（Telemetry = 车上遥测；Initial 等只放相机模型）。
    # 关节角和 ROVER_NAV 坐标系在哪个块里就从哪个块取。
    landers = list(root.iter("{http://pds.nasa.gov/pds4/geom/v1}Geometry_Lander"))
    devs = [d for g in landers for d in g.findall("geom:Articulation_Device_Parameters", NS)]
    csds = [c for g in landers for c in g.findall("geom:Coordinate_Space_Definition", NS)]
    if not landers:
        return None
    for dev in devs:
        did = (dev.findtext("geom:device_id", "", NS) or "").strip()
        if did not in ("CHASSIS", "RSM", "ARM"):
            continue
        for a in dev.findall("geom:Device_Angle/geom:Device_Angle_Index", NS):
            name = (a.findtext("geom:index_id", "", NS) or "").strip()
            v = a.findtext("geom:index_value_angle", None, NS)
            if v is None:
                continue
            if did == "CHASSIS" and ("BOGIE" in name or "DIFFERENTIAL" in name or "STEER" in name):
                row[name.lower().replace(" ", "_") + "_deg"] = round(math.degrees(float(v)), 4)
            elif did == "RSM" and name in ("AZIMUTH FINAL-RESOLVER", "ELEVATION FINAL-RESOLVER"):
                row["rsm_" + name.split()[0].lower() + "_deg"] = round(math.degrees(float(v)), 3)
            elif did == "ARM" and name.endswith("-RESOLVER"):
                row["arm_" + name.split()[1].lower() + "_deg"] = round(math.degrees(float(v)), 3)
    navs = []
    for csd in csds:
        idx = csd.find("geom:Coordinate_Space_Present/geom:Coordinate_Space_Indexed", NS)
        if idx is not None and (idx.findtext("geom:coordinate_space_frame_type", "", NS) or "").strip() == "ROVER_NAV_FRAME":
            sol_id = (idx.findtext("geom:solution_id", "", NS) or "").strip()
            navs.append((sol_id == "TELEMETRY", csd, idx, sol_id))     # 有地面重新定位的解就优先用
    for _, csd, idx, sol_id in sorted(navs, key=lambda n: n[0])[:1]:
        for i in idx.findall("geom:Coordinate_Space_Index", NS):
            k = (i.findtext("geom:index_id", "", NS) or "").strip()
            if k in ("SITE", "DRIVE", "POSE"):
                row[k.lower()] = int(i.findtext("geom:index_value_number", "0", NS))
        row["定位解"] = sol_id
        row["姿态测法"] = (csd.findtext("geom:Coordinate_Space_Quality/geom:quaternion_measurement_method", "", NS) or "").strip()
        x, y, z = (_num(csd, f"geom:Vector_Origin_Offset/geom:{c}_position") for c in "xyz")
        q = [_num(csd, f"geom:Quaternion_Plus_Direction/geom:{c}") for c in ("qcos", "qsin1", "qsin2", "qsin3")]
        row.update(site_x_n=x, site_y_e=y, site_z_down=z)
        if None not in q:
            row.update(qw=q[0], qx=q[1], qy=q[2], qz=q[3])
            r, p, yw = quat_rpy(*q)
            row.update(roll_deg=round(r, 3), pitch_deg=round(p, 3), yaw_deg=round(yw, 3))
    return row


def pose_table(out):
    files = sorted(glob.glob(os.path.join(out, "位姿", "标签", "sol*", "*.xml")))
    rows = []
    for f in files:
        if not os.path.exists(f + ".ok"):
            continue
        try:
            r = parse_pose_label(f)
        except ET.ParseError:
            continue
        if r and "roll_deg" in r:
            rows.append(r)
    rows.sort(key=lambda r: float(r["sclk"] or 0))
    cols = ["sol", "sclk", "utc", "lmst", "ltst", "site", "drive", "pose", "定位解", "姿态测法",
            "site_x_n", "site_y_e", "site_z_down", "qw", "qx", "qy", "qz", "roll_deg", "pitch_deg", "yaw_deg",
            "left_bogie_deg", "right_bogie_deg", "left_differential_deg", "right_differential_deg",
            "left_front_wheel_steer_motor_deg", "right_front_wheel_steer_motor_deg",
            "left_rear_wheel_steer_motor_deg", "right_rear_wheel_steer_motor_deg",
            "rsm_azimuth_deg", "rsm_elevation_deg"]
    cols += sorted({k for r in rows for k in r if k.startswith("arm_")}) + ["文件"]
    dst = os.path.join(out, "位姿", "位姿表.csv")
    with open(dst, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    # 每个 (site, drive, pose) 一行的精简表：同一停车姿态下标签数值相同，取第一张
    seen, uniq = set(), []
    for r in rows:
        k = (r.get("site"), r.get("drive"), r.get("pose"))
        if k not in seen:
            seen.add(k)
            uniq.append(r)
    with open(os.path.join(out, "位姿", "位姿表_按姿态.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        w.writerows(uniq)
    log(out, f"位姿表：{len(rows)} 张图 → {len(uniq)} 个 (site, drive, pose)；位姿/位姿表.csv、位姿表_按姿态.csv")


# ---------------------------------------------------------------- 主流程

BUILDERS = {}   # 集名 → 列清单函数（下面登记）


def verify(dst, size_hint):
    name = os.path.basename(dst)
    stem, ext = os.path.splitext(dst)
    if ext.lower() != ".xml":
        for lab in (stem + ".xml", stem + ".XML", stem + ".lblx"):
            if os.path.exists(lab):
                want = label_md5(lab, name)
                if want:
                    return md5_of(dst) == want, "md5"
    if size_hint and size_hint > 50_000:          # 目录页大小只有 3 位有效数字
        got = os.path.getsize(dst)
        return abs(got - size_hint) <= 0.03 * size_hint + 1024, "大小"
    return os.path.getsize(dst) > 0, "非空"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--输出", default=OUT_DEFAULT)
    ap.add_argument("--集", default=",".join(ALL_SETS), help="逗号分隔：" + ",".join(ALL_SETS))
    ap.add_argument("--只列", action="store_true", help="只写清单，不下")
    ap.add_argument("--只抽表", action="store_true", help="不下载，只从已下的标签抽位姿表")
    a = ap.parse_args()
    out = a.输出
    os.makedirs(out, exist_ok=True)
    want = [s for s in a.集.split(",") if s]
    for s in want:
        if s not in BUILDERS:
            sys.exit(f"未知数据集 {s}；可选 {ALL_SETS}")
    if a.只抽表:
        post(out, want)
        return

    man_path = os.path.join(out, "清单.json")
    old = json.load(open(man_path, encoding="utf-8")) if os.path.exists(man_path) else []
    items = [it for it in old if it["集"] not in want]       # 其他集的清单保留
    for s in want:
        got = BUILDERS[s]()
        seen = set()
        got = [it for it in got if not (it["url"] in seen or seen.add(it["url"]))]
        tot = sum(it["大小"] or 0 for it in got)
        log(out, f"{s}：{len(got)} 个文件，目录页合计约 {tot / 1e6:.0f} MB")
        items += got
    json.dump(items, open(man_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    log(out, f"清单 {len(items)} 个文件 → 清单.json")
    if a.只列:
        return

    # 先下标签（小，校验要用），再下数据
    todo = [it for it in items if it["集"] in want]
    todo.sort(key=lambda it: (not it["本地"].lower().endswith((".xml", ".lblx")), want.index(it["集"]), it["sol"]))
    ok = bad = 0
    for k, it in enumerate(todo):
        dst = os.path.join(out, it["本地"])
        if os.path.exists(dst + ".ok"):
            ok += 1
            continue
        name = os.path.basename(dst)
        for attempt in range(2):
            if not fetch(it["url"], dst):
                log(out, f"失败 {it['url']}")
                continue
            good, how = verify(dst, it["大小"])
            if not good:
                log(out, f"{how}不符，重下 {name}")
                os.remove(dst)
                continue
            open(dst + ".ok", "w").close()
            break
        if os.path.exists(dst + ".ok"):
            ok += 1
            sz = os.path.getsize(dst)
            if sz > 5e6 or (k + 1) % 200 == 0:
                log(out, f"[{k + 1}/{len(todo)}] {it['集']} sol {it['sol']} {name}（{sz / 1e6:.1f} MB）")
        else:
            bad += 1
    log(out, f"下载完成：成功 {ok}，失败 {bad}")
    post(out, want)
    du = {}
    for it in items:
        p = os.path.join(out, it["本地"])
        if os.path.exists(p):
            du[it["集"]] = du.get(it["集"], 0) + os.path.getsize(p)
    log(out, "各集大小：" + "，".join(f"{k} {v / 1e6:.0f} MB" for k, v in du.items()) + f"；合计 {sum(du.values()) / 1e9:.2f} GB")
    sys.exit(1 if bad else 0)


def post(out, want):
    """下完后的抽表：位姿表、多光谱指向表、气象逐时表"""
    for name, fn in (("位姿", pose_table), ("多光谱", zcam_table), ("气象", meda_table)):
        if name in want:
            try:
                fn(out)
            except Exception as e:  # noqa: BLE001 —— 抽表失败不影响下载结果
                log(out, f"{name} 抽表失败：{e!r}")


BUILDERS.update({"气象": build_meda, "多光谱": build_zcam, "近拍": build_watson, "声音": build_audio, "位姿": build_pose})

if __name__ == "__main__":
    main()
