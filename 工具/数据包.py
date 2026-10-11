#!/usr/bin/env python3
"""数据包：把游戏的 data/（场景数据、界面字体和图标、地貌参数，约 4.4 GB）做成三个平台共用的分卷 zip。只用标准库，Python 3.9+（Mac 自带的也行）。
说明见 docs/发布流程.md「数据包」。

  暂存 --出 <目录>          从源码树（godot/数据/sol0530、godot/界面/素材、godot/界面/图标、资料/地貌参数）整理出 <目录>/data/，
                            和导出包里以前的 data/ 完全一样（去掉 *.import、._*、*_备份_*、.gdignore、地平线缓存_*）。
                            <目录>/data/ 已经有、数据版本相同、文件大小都对，就不重做。--重做 强制重做。
  打包 --根 <目录> --出 <发布目录>
                            把 <目录>/data/ 打成 mars-realtime-drive-data-<数据版本>-<n>of<N>.zip + .sha256。
                            先在 <目录>/data/ 里写 数据包清单.json（每卷都带一份，游戏用它判断缺哪几卷）。
                            这个版本的包已经在 <发布目录> 里且 .sha256 都对得上，就跳过。
  校验 --目录 <data 目录>   玩家解压完以后的样子：数据包清单.json 里每个文件都在、大小对；sol0530 里的文件再按 数据清单.json 比哈希。

分卷方法（确定性，同一份数据每次分出来一样）：
  文件按相对路径排序（Unicode 码点序），顺序装箱：当前卷装得下（未压缩大小累计 ≤ 1.88e9 字节）就装，否则开下一卷。
  zip 里不存目录项；文件名 UTF-8；时间戳固定 2026-01-01；权限固定 0644；压缩 deflate 级别 6。
  所以同一份数据、同一版 zlib 下，每卷的字节和 SHA-256 都一样。每卷上限用「未压缩大小」算：deflate 最坏只胀 0.03% 左右，
  1.88e9 的未压缩量压出来不会超过 1.9e9 字节（打完会再量一遍，超了就报错）。
"""
import argparse, fnmatch, hashlib, json, os, pathlib, shutil, subprocess, sys, zipfile
from concurrent.futures import ThreadPoolExecutor

ROOT = pathlib.Path(__file__).resolve().parents[1]
清单名 = "数据包清单.json"
卷上限 = 1_880_000_000             # 每卷未压缩字节数上限
卷硬上限 = 1_900_000_000           # 压缩后的 zip 不得超过
跳过 = ["*.import", "._*", "*_备份_*", ".gdignore", "地平线缓存_*", "数据清单.json.bak"]
时间戳 = (2026, 1, 1, 0, 0, 0)
NAME = "mars-realtime-drive"


def 要跳过(name: str) -> bool:
    return any(fnmatch.fnmatch(name, s) for s in 跳过)


def 复制树(src: pathlib.Path, dst: pathlib.Path) -> None:
    for d, dirs, fs in os.walk(src):
        dirs[:] = sorted(x for x in dirs if not 要跳过(x))
        for f in sorted(fs):
            if 要跳过(f): continue
            p = pathlib.Path(d) / f
            q = dst / p.relative_to(src)
            q.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(p, q)                     # Linux 上走 copy_file_range：btrfs 里是 reflink，不占额外空间


def 数据版本(data: pathlib.Path) -> str:
    return json.loads((data / "数据/sol0530/数据清单.json").read_text(encoding="utf-8"))["数据版本"]


def 列文件(data: pathlib.Path) -> dict:
    out = {}
    for d, dirs, fs in os.walk(data):
        for f in fs:
            p = pathlib.Path(d) / f
            rel = p.relative_to(data).as_posix()
            if rel == 清单名 or 要跳过(f): continue                 # 游戏运行时会往 data/ 里写地平线缓存等，不算数据
            out[rel] = p.stat().st_size
    return out


def 暂存(出: pathlib.Path, 重做: bool) -> None:
    data = 出 / "data"
    src = ROOT / "godot/数据/sol0530"
    if not (src / "数据清单.json").exists(): sys.exit("✗ 源码树里没有 godot/数据/sol0530/数据清单.json")
    want = json.loads((src / "数据清单.json").read_text(encoding="utf-8"))["数据版本"]
    if data.exists() and not 重做 and (data / 清单名).exists():
        try:
            doc = 读清单(data)
            if doc["数据版本"] == want:
                fs = 列文件(data)
                if len(fs) == len(doc["文件"]) and all(fs.get(k) == v[0] for k, v in doc["文件"].items()):
                    print(f"暂存目录已有数据 {want}，沿用：{data}"); return
        except Exception:
            pass
    if data.exists(): shutil.rmtree(data)
    print(f"暂存 data/（数据 {want}）→ {data}")
    复制树(src, data / "数据/sol0530")
    复制树(ROOT / "godot/界面/素材", data / "界面/素材")
    复制树(ROOT / "godot/界面/图标", data / "界面/图标")
    p = ROOT / "资料/地貌参数/地貌参数.json"
    (data / "资料/地貌参数").mkdir(parents=True, exist_ok=True)
    shutil.copyfile(p, data / "资料/地貌参数/地貌参数.json")
    r = subprocess.run([sys.executable, str(ROOT / "工具/数据清单.py"), "校验", "--目录", str(data / "数据/sol0530")])
    if r.returncode != 0: sys.exit("✗ 暂存的数据和清单不符")
    写清单(data)


def 分卷(files: dict) -> list:
    """顺序装箱 → [[rel, …], …]。"""
    vols, cur, n = [], [], 0
    for rel in sorted(files):
        sz = files[rel]
        if sz > 卷上限: sys.exit(f"✗ {rel} 单个文件 {sz} 字节，超过每卷上限")
        if cur and n + sz > 卷上限: vols.append(cur); cur, n = [], 0
        cur.append(rel); n += sz
    if cur: vols.append(cur)
    return vols


def 写清单(data: pathlib.Path) -> dict:
    files = 列文件(data)
    vols = 分卷(files)
    doc = {"数据版本": 数据版本(data), "卷数": len(vols), "文件数": len(files), "总大小": sum(files.values()),
           "说明": "工具/数据包.py 生成；每卷都带一份。文件：路径 → [大小, 在第几卷]。",
           "文件": {rel: [files[rel], i + 1] for i, v in enumerate(vols) for rel in v}}
    (data / 清单名).write_text(json.dumps(doc, ensure_ascii=False, indent=0, sort_keys=True) + "\n", encoding="utf-8")
    return doc


def 读清单(data: pathlib.Path) -> dict:
    return json.loads((data / 清单名).read_text(encoding="utf-8"))


def sha256(p: pathlib.Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        while b := f.read(8 << 20): h.update(b)
    return h.hexdigest()


def 写卷(data: pathlib.Path, rels: list, out: pathlib.Path) -> None:
    tmp = out.with_name(out.name + ".part")
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True) as z:
        for rel in [清单名] + rels:
            zi = zipfile.ZipInfo("data/" + rel, 时间戳)
            zi.compress_type = zipfile.ZIP_DEFLATED; zi.external_attr = 0o100644 << 16; zi.create_system = 3
            zi._compresslevel = 6
            with open(data / rel, "rb") as f, z.open(zi, "w", force_zip64=False) as w:
                while b := f.read(8 << 20): w.write(b)
    os.replace(tmp, out)


def 已有且对(发布: pathlib.Path, ver: str, n: int) -> bool:
    for i in range(1, n + 1):
        z = 发布 / f"{NAME}-data-{ver}-{i}of{n}.zip"; s = 发布 / (z.name + ".sha256")
        if not z.exists() or not s.exists(): return False
        if s.read_text().split()[0] != sha256(z): return False
    return len(list(发布.glob(f"{NAME}-data-{ver}-*of*.zip"))) == n


def 打包(根: pathlib.Path, 发布: pathlib.Path) -> None:
    data = 根 / "data"
    if not (data / "数据/sol0530/数据清单.json").exists(): sys.exit(f"✗ {data} 里没有数据（先 暂存）")
    ver = 数据版本(data)
    doc = 写清单(data)
    n = doc["卷数"]
    发布.mkdir(parents=True, exist_ok=True)
    if 已有且对(发布, ver, n):
        print(f"数据包 {ver} 的 {n} 卷已在 {发布}，校验一致，跳过")
        return
    for old in 发布.glob(f"{NAME}-data-{ver}-*of*.zip*"): old.unlink()
    vols = 分卷(列文件(data))
    print(f"数据 {ver}：{doc['文件数']} 个文件，{doc['总大小']/1e9:.2f} GB → {n} 卷")
    names = [发布 / f"{NAME}-data-{ver}-{i+1}of{n}.zip" for i in range(n)]
    with ThreadPoolExecutor(max_workers=n) as ex:
        list(ex.map(lambda a: 写卷(data, a[0], a[1]), zip(vols, names)))
    for i, z in enumerate(names):
        sz = z.stat().st_size
        if sz > 卷硬上限: sys.exit(f"✗ {z.name} {sz} 字节，超过 {卷硬上限}")
        h = sha256(z)
        (发布 / (z.name + ".sha256")).write_text(f"{h}  {z.name}\n")
        print(f"  {z.name}  {sz:,} 字节  {len(vols[i])} 个文件  {h}")


def 校验(data: pathlib.Path) -> int:
    if not (data / 清单名).exists(): print(f"✗ {data} 里没有 {清单名}"); return 1
    doc = 读清单(data)
    bad = []
    for rel, (sz, vol) in doc["文件"].items():
        p = data / rel
        if not p.is_file() or p.stat().st_size != sz: bad.append((rel, vol))
    if bad:
        print(f"✗ 缺或大小不对 {len(bad)} 个文件，在第 {sorted({v for _, v in bad})} 卷；例：{bad[0][0]}"); return 1
    r = subprocess.run([sys.executable, str(ROOT / "工具/数据清单.py"), "校验", "--目录", str(data / "数据/sol0530")])
    if r.returncode != 0: return 1
    print(f"数据包 {doc['数据版本']}（{doc['卷数']} 卷）：{doc['文件数']} 个文件，大小都对，sol0530 哈希都对 → {data}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    a = sp.add_parser("暂存"); a.add_argument("--出", required=True); a.add_argument("--重做", action="store_true")
    b = sp.add_parser("打包"); b.add_argument("--根", required=True); b.add_argument("--出", required=True)
    c = sp.add_parser("校验"); c.add_argument("--目录", required=True)
    x = ap.parse_args()
    for k in ("出", "根", "目录"):
        if getattr(x, k, None): setattr(x, k, str(pathlib.Path(getattr(x, k)).resolve()))     # 相对路径按当前目录算，不是仓库根
    if x.cmd == "暂存": 暂存(pathlib.Path(x.出), x.重做)
    elif x.cmd == "打包": 打包(pathlib.Path(x.根), pathlib.Path(x.出))
    else: return 校验(pathlib.Path(x.目录))
    return 0


if __name__ == "__main__":
    sys.exit(main())
