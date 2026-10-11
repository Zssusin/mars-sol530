#!/usr/bin/env python3
"""地面材质用的 PDS 原始数据下载（docs/地面材质/方案.md、调研_地表类型与数据.md §7）。

三批，按优先级：
  ① Navcam 工作区全分辨率（sol 502–532，NCAM00708/00709/00712）：立体包的 XYZ、UVW（左眼），标定包的 RAS（左右眼）
  ② Mastcam-Z 110 mm（sol 520/531 ZCAM08544、523 ZCAM08547、538 ZCAM08558）：立体包的 XYZ、UVW（PDS Registry，r13），
     科学标定包的 IOF（左右眼，planetarydata 镜像）
  ③ 沿途 sol 535–543 的 Navcam 半分辨率：XYZ（左眼）+ RAS（左眼）

每个文件连同 PDS4 标签（.xml）一起下；断点续传（curl -C -），下完按标签里的 md5 校验，不对就删了重下一次。
清单先写到 <输出>/清单.json，进度写 <输出>/下载.log。重复运行只补缺的。

用法：python3 69_地面材质下载.py [--输出 目录] [--批 1,2,3] [--只列]
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request

MIRROR = "https://planetarydata.jpl.nasa.gov/img/data/mars2020"
REGISTRY = "https://pds.mcp.nasa.gov/api/search/1/products"

NAV_WORKSPACE = {502: "NCAM00708", 504: "NCAM00709", 509: "NCAM00709", 516: "NCAM00709",
                 520: "NCAM00712", 521: "NCAM00712", 526: "NCAM00712", 527: "NCAM00712", 528: "NCAM00712",
                 529: "NCAM00712", 530: "NCAM00712", 531: "NCAM00712", 532: "NCAM00712"}
ZCAM = [(520, "ZCAM08544"), (531, "ZCAM08544"), (523, "ZCAM08547"), (538, "ZCAM08558")]
TRAVERSE_SOLS = range(535, 544)


def log(out, msg):
    line = time.strftime("%H:%M:%S ") + msg
    print(line, flush=True)
    with open(os.path.join(out, "下载.log"), "a", encoding="utf-8") as f:
        f.write(line + "\n")


def get(url, tries=4):
    for k in range(tries):
        try:
            with urllib.request.urlopen(url, timeout=120) as r:
                return r.read().decode("utf-8", "replace")
        except Exception as e:  # noqa: BLE001 —— 网络抖动，重试
            if k == tries - 1:
                raise
            time.sleep(5 * (k + 1))


def listing(url):
    """镜像目录页里的文件名"""
    return sorted(set(re.findall(r'href="([A-Z0-9_]+\.(?:IMG|xml))"', get(url))))


def nav_dir(bundle, sol):
    return f"{MIRROR}/mars2020_navcam_ops_{bundle}/data/sol/{sol:05d}/ids/rdr/ncam/"


def batch1():
    items = []
    for sol, seq in NAV_WORKSPACE.items():
        st, ca = nav_dir("stereo", sol), nav_dir("calibrated", sol)
        sfiles, cfiles = listing(st), listing(ca)
        # 帧 = 左眼 XYZ 的 sclk 前缀（NLF_0527_0713726823_925）
        frames = sorted({f[:23] for f in sfiles if f.startswith("NLF_") and f"XYZ_N" in f and seq in f and f.endswith(".IMG")})
        for fr in frames:
            tag = fr[4:]                                              # 0527_0713726823_925
            for f in sfiles:
                if f.startswith(fr) and seq in f and re.search(r"(XYZ|UVW)_N", f):
                    items.append((1, sol, st + f))
            for f in cfiles:
                if f[4:].startswith(tag) and seq in f and f[:3] in ("NLF", "NRF") and "RAS_N" in f:
                    items.append((1, sol, ca + f))
    return items


def registry_refs(lid_like):
    q = f'(lid like "{lid_like}")'
    url = f"{REGISTRY}?q={urllib.parse.quote(q)}&fields=ops:Data_File_Info.ops:file_ref&limit=1000"
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        d = json.load(r)
    refs = []
    for p in d.get("data", []):
        for v in p.get("properties", {}).values():
            refs += v if isinstance(v, list) else [v]
    return refs


def batch2():
    items = []
    for sol, seq in ZCAM:
        refs = registry_refs(f"urn:nasa:pds:mars2020_mastcamz_ops_stereo:data:zlf_{sol:04d}*")
        for r in refs:
            if seq in r and re.search(r"(XYZ|UVW)_N.*\.IMG$", r):
                items.append((2, sol, r))
                items.append((2, sol, r[:-4] + ".xml"))
        iof = f"{MIRROR}/mars2020_mastcamz_sci_calibrated/data/{sol:04d}/iof/"
        for f in listing(iof):
            if seq in f and f[:3] in ("ZL0", "ZR0"):
                items.append((2, sol, iof + f))
    return items


def batch3():
    items = []
    for sol in TRAVERSE_SOLS:
        st, ca = nav_dir("stereo", sol), nav_dir("calibrated", sol)
        try:
            sfiles, cfiles = listing(st), listing(ca)
        except Exception:  # noqa: BLE001 —— 没开车拍照的 sol 没有目录
            continue
        # 半分辨率全景：左眼 XYZ，大小 2560×1920 一档（文件名里看不出，按序列号 NCAM02xxx / 03xxx 取）
        frames = sorted({f[:23] for f in sfiles if f.startswith("NLF_") and "XYZ_N" in f and re.search(r"NCAM0[23]\d\d\d", f)})
        for fr in frames:
            for f in sfiles:
                if f.startswith(fr) and "XYZ_N" in f:
                    items.append((3, sol, st + f))
            for f in cfiles:
                if f.startswith(fr) and "RAS_N" in f:
                    items.append((3, sol, ca + f))
    return items


def md5_of(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 22), b""):
            h.update(b)
    return h.hexdigest()


def label_md5(xml_path, img_name):
    t = open(xml_path, encoding="utf-8", errors="replace").read()
    m = re.search(r"<file_name>\s*" + re.escape(img_name) + r"\s*</file_name>.*?<md5_checksum>\s*([0-9a-f]{32})", t, re.S)
    return m.group(1) if m else None


def fetch(url, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    r = subprocess.run(["curl", "-sS", "-f", "-L", "--retry", "5", "--retry-delay", "10", "-C", "-", "-o", dst, url])
    return r.returncode == 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--输出", default=os.path.expanduser("~/Documents/mars-work/地图/资料/地面材质/PDS"))
    ap.add_argument("--批", default="1,2,3")
    ap.add_argument("--只列", action="store_true")
    a = ap.parse_args()
    out = a.输出
    os.makedirs(out, exist_ok=True)
    want = {int(x) for x in a.批.split(",")}

    items = []
    for b, fn in ((1, batch1), (2, batch2), (3, batch3)):
        if b in want:
            got = fn()
            # IMG 都配上同名 xml（镜像清单里已有的会重复，去重）
            got += [(b, s, u[:-4] + ".xml") for b, s, u in got if u.endswith(".IMG")]
            items += got
            log(out, f"第 {b} 批：{len({u for _, _, u in got})} 个文件")
    seen, uniq = set(), []
    for b, s, u in items:
        if u not in seen:
            seen.add(u)
            uniq.append({"批": b, "sol": s, "url": u, "本地": f"批{b}/sol{s:04d}/{os.path.basename(u)}"})
    json.dump(uniq, open(os.path.join(out, "清单.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    log(out, f"清单 {len(uniq)} 个文件 → 清单.json")
    if a.只列:
        return

    # 先下全部 xml（小，校验要用），再按批次下 IMG
    order = sorted(uniq, key=lambda it: (not it["url"].endswith(".xml"), it["批"], it["sol"]))
    ok = bad = 0
    for k, it in enumerate(order):
        dst = os.path.join(out, it["本地"])
        name = os.path.basename(dst)
        if os.path.exists(dst + ".ok"):
            continue
        for attempt in range(2):
            if not fetch(it["url"], dst):
                log(out, f"失败 {name}")
                continue
            if name.endswith(".IMG"):
                want_md5 = label_md5(dst[:-4] + ".xml", name) if os.path.exists(dst[:-4] + ".xml") else None
                if want_md5 and md5_of(dst) != want_md5:
                    log(out, f"md5 不符，重下 {name}")
                    os.remove(dst)
                    continue
            open(dst + ".ok", "w").close()
            break
        if os.path.exists(dst + ".ok"):
            ok += 1
            if name.endswith(".IMG"):
                log(out, f"[{k + 1}/{len(order)}] 第 {it['批']} 批 sol {it['sol']} {name}（{os.path.getsize(dst) / 1e6:.0f} MB）")
        else:
            bad += 1
    log(out, f"完成：成功 {ok}，失败 {bad}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
