#!/usr/bin/env python3
"""数据清单：给管线生成、不进 git 的场景数据（godot/数据/sol0530，约 1.8 GB）记账。只用标准库。说明见 docs/工程化方案.md §5。

  生成   重新算清单，写 <目录>/数据清单.json（进 git）。文件内容（大小、哈希）没变就沿用原数据版本号；
         变了就换成今天的 CalVer（YYYY.MM.DD，同一天第二批 YYYY.MM.DD.2）。
  校验   本地数据和清单比，列出缺失、多出、变了的文件；不符时退出码 1。--快：只比大小，不算哈希。
  备份 <目标>
         把数据快照 rsync 到 <目标>/<数据版本>/（目标可以是本地目录或 host:路径）。本地目标里已有别的版本时，
         用 --link-dest 硬链接没变的文件，不重复占空间。数据和清单不符时拒绝（快照的版本号会说谎），--强制 跳过。

  通用参数：--目录 <数据目录>（默认 godot/数据/sol0530，相对仓库根）

哈希：BLAKE2b-128，多线程（hashlib 计算时释放 GIL）。比 sha256 快约一倍，又不用装 xxhash。
跳过：*.import（编辑器生成）、地平线缓存_*（运行时缓存，自带校验键）、*_备份_*、._*（macOS）、数据清单.json 自己。
「来源」按下面的规则表从文件名推断，是给人看的线索，不参与校验；新增一类数据时在 规则 里加一行。
"""
import argparse, datetime, fnmatch, hashlib, json, os, pathlib, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

ROOT = pathlib.Path(__file__).resolve().parents[1]
清单名 = "数据清单.json"
跳过 = ["*.import", "地平线缓存_*", "*_备份_*", "._*", 清单名, ".gdignore"]
规则 = [                                                       # (文件名通配, 生成它的脚本)；按顺序取第一条匹配
    ("rover_ao*", "scripts/Godot/67_车AO.py"),
    ("rover_detail.png", "scripts/Godot/68_车细节.py"),
    ("rover_rig.json", "godot/工具/量车轮.gd"),
    ("rover_材质.json", "手写"),
    ("车辙.*", "scripts/Godot/66_车辆动画.py"),
    ("fine_*", "scripts/Godot/72_近景细化.py"),
    ("rover_n_*", "scripts/Godot/69_车法线.py"),
    ("ripple_field*", "scripts/Godot/80_沙纹场.py"),
    ("地图台*", "scripts/Godot/90_地图台数据.py"),
    ("mat_ctrl_*2f.bin", "scripts/Godot/81_中景丰富度.py"),
    ("mat_gain_lp*", "scripts/Godot/81_中景丰富度.py"),
    ("材质2/*", "scripts/Godot/81_中景丰富度.py"),
    ("mat.json", "scripts/Godot/73_材质规则.py"),
    ("mat_ctrl_*", "scripts/Godot/73_材质规则.py"),
    ("材质/*", "scripts/Godot/73_材质规则.py"),
    ("rover*", "scripts/Godot/61_Godot数据.py"),               # rover.glb 和它引用的贴图
    ("ref_*", "scripts/Godot/61_Godot数据.py（拷自封存 v5 对照照片）"),
    ("*", "scripts/Godot/61_Godot数据.py"),                    # 天空、地形环、高度、地类、反照率、细节、石块、scene.json
]


def 来源(rel: str) -> str:
    for pat, src in 规则:
        if fnmatch.fnmatch(rel, pat): return src
    return "?"


def 列文件(d: pathlib.Path) -> list[str]:
    out = []
    for p in sorted(d.rglob("*")):
        if not p.is_file(): continue
        rel = p.relative_to(d).as_posix()
        if any(fnmatch.fnmatch(p.name, s) for s in 跳过): continue
        out.append(rel)
    return out


def 哈希(p: pathlib.Path) -> str:
    h = hashlib.blake2b(digest_size=16)
    with open(p, "rb") as f:
        while b := f.read(8 << 20): h.update(b)
    return h.hexdigest()


def 扫描(d: pathlib.Path, 算哈希=True) -> dict:
    rels = 列文件(d)
    with ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 4)) as ex:
        hs = list(ex.map(lambda r: 哈希(d/r), rels)) if 算哈希 else [None]*len(rels)
    return {r: {"大小": (d/r).stat().st_size, "哈希": h, "来源": 来源(r)} for r, h in zip(rels, hs)}


def 读清单(d: pathlib.Path) -> dict:
    p = d/清单名
    return json.loads(p.read_text()) if p.exists() else {}


def 新版本(旧: str) -> str:
    today = datetime.date.today().strftime("%Y.%m.%d")
    if not 旧.startswith(today): return today
    n = int(旧.split(".")[3]) + 1 if 旧.count(".") == 3 else 2
    return f"{today}.{n}"


def 生成(d: pathlib.Path) -> int:
    old = 读清单(d)
    files = 扫描(d)
    same = old.get("文件") and {k: (v["大小"], v["哈希"]) for k, v in old["文件"].items()} == {k: (v["大小"], v["哈希"]) for k, v in files.items()}
    ver = old["数据版本"] if same else 新版本(old.get("数据版本", ""))
    total = sum(v["大小"] for v in files.values())
    doc = {"数据版本": ver, "目录": d.relative_to(ROOT).as_posix() if d.is_relative_to(ROOT) else str(d),
           "哈希": "blake2b-128", "生成于": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
           "文件数": len(files), "总大小": total, "说明": "工具/数据清单.py 生成；docs/工程化方案.md §5",
           "文件": files}
    if same: doc["生成于"] = old.get("生成于", doc["生成于"])          # 内容没变：整个文件保持不变，不产生 git 改动
    (d/清单名).write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n")
    unknown = [k for k, v in files.items() if v["来源"] == "?"]
    print(f"数据版本 {ver}（{'未变' if same else '已更新'}）：{len(files)} 个文件，{total/1e9:.2f} GB → {d/清单名}")
    if unknown: print("来源未知（在 规则 里补）：", ", ".join(unknown))
    return 0


def 比较(d: pathlib.Path, 快=False) -> tuple[list, list, list]:
    old = 读清单(d).get("文件")
    if old is None: sys.exit(f"没有清单：{d/清单名}（先跑 生成）")
    now = 扫描(d, 算哈希=not 快)
    缺 = sorted(set(old) - set(now)); 多 = sorted(set(now) - set(old)); 变 = []
    for k in sorted(set(old) & set(now)):
        a, b = old[k], now[k]
        if a["大小"] != b["大小"]: 变.append(f"{k}（大小 {a['大小']} → {b['大小']}）")
        elif not 快 and a["哈希"] != b["哈希"]: 变.append(f"{k}（内容变了，大小相同）")
    return 缺, 多, 变


def 校验(d: pathlib.Path, 快=False) -> int:
    缺, 多, 变 = 比较(d, 快)
    ver = 读清单(d).get("数据版本", "?")
    if not (缺 or 多 or 变):
        print(f"数据和清单一致：{ver}，{len(列文件(d))} 个文件{'（只比大小）' if 快 else ''}"); return 0
    print(f"数据和清单（{ver}）不符：缺 {len(缺)}，多 {len(多)}，变 {len(变)}")
    for t, xs in (("缺", 缺), ("多", 多), ("变", 变)):
        for x in xs[:40]: print(f"  {t} {x}")
        if len(xs) > 40: print(f"  …另有 {len(xs) - 40} 个")
    return 1


def 备份(d: pathlib.Path, 目标: str, 强制=False) -> int:
    m = 读清单(d)
    if not m: sys.exit("没有清单，先跑 生成")
    if not 强制 and 校验(d) != 0: sys.exit("数据和清单不符，快照的版本号会不对：先跑 生成（或加 --强制）")
    ver = m["数据版本"]; dst = 目标.rstrip("/") + "/" + ver + "/"
    cmd = ["rsync", "-a", "--info=stats1", "--exclude=*.import", "--exclude=._*"]
    if ":" not in 目标 and pathlib.Path(目标).is_dir():         # 本地：拿最近的另一个快照做硬链接基准
        prev = sorted(p for p in pathlib.Path(目标).iterdir() if p.is_dir() and p.name != ver and (p/清单名).exists())
        if prev: cmd.append(f"--link-dest={prev[-1].resolve()}"); print(f"硬链接基准：{prev[-1].name}")
    elif ":" not in 目标: pathlib.Path(目标).mkdir(parents=True)
    cmd += [str(d) + "/", dst]
    print(" ".join(cmd)); r = subprocess.run(cmd).returncode
    if r == 0: print(f"快照 → {dst}")
    return r


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("命令", choices=["生成", "校验", "备份"])
    ap.add_argument("目标", nargs="?")
    ap.add_argument("--目录", default="godot/数据/sol0530")
    ap.add_argument("--快", action="store_true")
    ap.add_argument("--强制", action="store_true")
    a = ap.parse_args()
    d = (ROOT/a.目录).resolve()
    if not d.is_dir(): sys.exit(f"数据目录不存在：{d}")
    if a.命令 == "生成": sys.exit(生成(d))
    if a.命令 == "校验": sys.exit(校验(d, a.快))
    if not a.目标: sys.exit("备份要给目标路径：工具/数据清单.py 备份 <目录或 host:路径>")
    sys.exit(备份(d, a.目标, a.强制))
