"""
实景回归 / 封存（venv 里跑）：sol 530 这一站封存后当「标准答案」，以后改 57/58 或做生成器，都拿它对照。
  对照：对每台对照机位（与 NASA Navcam 真照片同位姿同内参），
        ① 对真照片：每通道拟合增益 + 偏移（NASA RAS 调色会抬黑位），Huber 式迭代降权，取拟合后中位误差（DN）；
        ② 对封存基准渲染：不拟合，直接比中位差和 > 8 DN 的像素比例（看改动有没有把画面改坏）；
        → 指标打印 + 指标.json + 三联图（真照片 | 渲染 | 套调色后的渲染）。
  封存：把 导出/、实景_sol0530.blend、56–60 脚本 + 火星大气.py + 实景地形系统.md、渲染图与动画、日志、指标
        拷到 站26_1222/封存_<版本>/（btrfs 上走 reflink，不多占空间），写 清单.sha256，全部设只读。
运行：.venv/bin/python scripts/Blender/60_实景回归.py 对照 [--基准 站26_1222/封存_v5/渲染] [--渲染目录 产出/Godot/实景]
       （--渲染目录：量别的渲染器的出图，例如 Godot 版；三联图和 指标.json 写进那个目录）
     .venv/bin/python scripts/Blender/60_实景回归.py 封存 v5
数据：NASA/JPL-Caltech（对照照片），PDS Imaging Node。
"""
import hashlib, json, pathlib, shutil, subprocess, sys, time
import numpy as np
from PIL import Image

HERE = pathlib.Path(__file__).resolve().parent
MAP = HERE.parent.parent
SITE = MAP/"DEM"/"Blender缓存"/"_素材"/"PDS"/"站26_1222"
RB = SITE/"重建"; EX = RB/"导出"
REN = MAP/"产出"/"Blender"/"实景"
LTST = "1307"


def log(*a): print("[60]", *a, flush=True)


def load(p, size=None):
    im = Image.open(p).convert("RGB")
    if size and im.size != size: im = im.resize(size, Image.LANCZOS)
    return np.asarray(im).astype(np.float64)


def fit_grade(r, p, ok):
    """每通道 p ≈ g·r + o，迭代降权（残差 > 15 DN 的按 15/残差 降），返回套调色后的渲染与参数。"""
    f = r.copy(); fit = []
    for c in range(3):
        x, y = r[..., c][ok], p[..., c][ok]; w = np.ones_like(x)
        for _ in range(5):
            A = np.stack([x, np.ones_like(x)], 1)
            g, o = np.linalg.lstsq(A*np.sqrt(w)[:, None], y*np.sqrt(w), rcond=None)[0]
            w = np.minimum(1, 15/np.maximum(np.abs(y - (g*x + o)), 1e-6))
        f[..., c] = np.clip(g*r[..., c] + o, 0, 255); fit.append((round(float(g), 3), round(float(o), 1)))
    return f, fit


def compare(base=None, ren_dir=None):
    global REN
    if ren_dir: REN = pathlib.Path(ren_dir) if pathlib.Path(ren_dir).is_absolute() else MAP/ren_dir
    out = {}
    for ref in sorted(EX.glob("对照_*.png")):
        name = ref.stem
        ren = REN/f"{name}_{LTST}.png"
        if not ren.exists(): log(f"缺渲染 {ren.name}"); continue
        p = load(ref); r = load(ren, (p.shape[1], p.shape[0]))
        ok = p.max(2) > 5                                                  # 照片黑角
        f, fit = fit_grade(r, p, ok)
        m = dict(对照片_拟合后中位误差=round(float(np.median(np.abs(f[ok] - p[ok]))), 2), 调色=fit, 像素=int(ok.sum()))
        if base:
            b = pathlib.Path(base)/ren.name
            if b.exists():
                q = load(b, (r.shape[1], r.shape[0])); d = np.abs(r - q).max(2)
                m.update(对基准_中位差=round(float(np.median(d)), 2), 对基准_超8DN比例=round(float(np.mean(d > 8)), 4))
        out[name] = m
        Image.fromarray(np.concatenate([p, r, f], 1).astype(np.uint8)).save(REN/f"三联_{name}.png")
        log(name, m)
    ((REN if ren_dir else RB)/"指标.json").write_text(json.dumps(dict(时间=time.strftime("%F %T"), 机位=out), ensure_ascii=False, indent=1))
    return out


def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""): h.update(b)
    return h.hexdigest()


def freeze(ver):
    dst = SITE/f"封存_{ver}"
    if dst.exists(): sys.exit(f"{dst} 已存在：封存不覆盖，换个版本号")
    plan = {"导出": EX, "实景_sol0530.blend": RB/"实景_sol0530.blend", "相机.json": RB/"相机.json",
            "日志/全量.log": RB/"全量.log", "日志/mastcam.log": RB/"mastcam.log", "日志/mastcam_配准.json": RB/"mastcam_配准.json",
            "指标.json": RB/"指标.json", "封存说明.md": RB/"封存说明.md", "脚本/实景地形系统.md": HERE/"实景地形系统.md", "脚本/火星大气.py": HERE/"火星大气.py"}
    for s in sorted(HERE.glob("5[6-9]*_*.py")) + sorted(HERE.glob("60_*.py")): plan[f"脚本/{s.name}"] = s   # 含 57g（GPU 版）
    plan["车体盒.json"] = SITE/"车体盒.json"
    for s in sorted(REN.glob(f"*_{LTST}.png")) + sorted(REN.glob("三联_*.png")): plan[f"渲染/{s.name}"] = s
    for s in sorted((REN/"动画").glob("*.mp4")): plan[f"渲染/{s.name}"] = s
    for k, s in plan.items():
        if not s.exists(): log(f"跳过（不存在）{s}"); continue
        d = dst/k; d.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["cp", "-r", "--reflink=auto", str(s), str(d)], check=True)
    files = sorted(p for p in dst.rglob("*") if p.is_file())
    (dst/"清单.sha256").write_text("".join(f"{sha(p)}  {p.relative_to(dst)}\n" for p in files))
    subprocess.run(["chmod", "-R", "a-w", str(dst)], check=True)
    log(f"封存 → {dst}（{len(files)} 个文件，{sum(p.stat().st_size for p in files)/1e6:.0f} MB，只读）")


if __name__ == "__main__":
    a = sys.argv[1:] or ["对照"]
    if a[0] == "对照": compare(a[a.index("--基准") + 1] if "--基准" in a else None, a[a.index("--渲染目录") + 1] if "--渲染目录" in a else None)
    elif a[0] == "封存": freeze(a[1] if len(a) > 1 else time.strftime("%Y%m%d"))
