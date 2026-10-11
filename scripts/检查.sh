#!/usr/bin/env bash
# 一键检查。说明见 docs/工程化方案.md §8。
#   scripts/检查.sh [托管|快|全] [--写基准] [--轮=N]
#   托管：C++ 单元测试、Python 编译、JSON 合法性（不要数据、不要自编引擎；GitHub Actions 跑这一档）
#   快  ：托管 + GDScript 语法检查 + 控制自测（无头）+ 数据清单校验（只警告），约 2 分钟，不要 GPU
#   全  ：快 + 照片回归 + 测帧（2560×1440，四个场景，每场景取 N 轮里最快的一次，默认 2 轮），和 工具/检查基准.json 比：
#         回归（对照片拟合后中位误差）变差 > 0.05 DN，或帧时间（平均）变差 > 3%，就失败。
#   --写基准：全档跑完把这次的数写进 工具/检查基准.json（确认变化是有意的之后再用；和改动一起提交，提交信息写原因）。
# 退出码：0 全部通过；1 有失败。日志在 产出/检查/<时间>/（仓库外，不进 git）。
# 引擎：GODOT=<编辑器路径>，默认 ~/引擎/godot/bin/godot.linuxbsd.editor.x86_64.mars。
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TIER=${1:-快}; shift || true
WRITE=0; ROUNDS=2
for a in "$@"; do case $a in --写基准) WRITE=1 ;; --轮=*) ROUNDS=${a#--轮=} ;; *) echo "不认识的参数：$a" >&2; exit 2 ;; esac; done
case $TIER in 托管|快|全) ;; *) echo "用法：scripts/检查.sh [托管|快|全] [--写基准] [--轮=N]" >&2; exit 2 ;; esac
G=${GODOT:-$HOME/引擎/godot/bin/godot.linuxbsd.editor.x86_64.mars}
PY=python3; [ -x "$ROOT/.venv/bin/python" ] && PY=$ROOT/.venv/bin/python
LOG=$ROOT/产出/检查/$(date +%Y%m%d_%H%M%S)_$TIER
[ "$TIER" = 托管 ] && LOG=${RUNNER_TEMP:-/tmp}/检查_$$
mkdir -p "$LOG"
FAIL=0; T0=$(date +%s)

# 步 <名字> <函数>：函数的输出进 $LOG/<名字>.log；最后一行以「摘要：」开头时打印出来。
步() {
  local name=$1; shift; local t=$(date +%s.%N) r
  "$@" > "$LOG/$name.log" 2>&1; r=$?
  local dt=$(awk "BEGIN{printf \"%.0f\", $(date +%s.%N) - $t}")
  local sum=$(grep '^摘要：' "$LOG/$name.log" | tail -1 | sed 's/^摘要：//')
  if [ $r -eq 0 ]; then printf '  ✓ %4ss  %s：%s\n' "$dt" "$name" "$sum"
  elif [ $r -eq 3 ]; then printf '  ⚠ %4ss  %s：%s\n' "$dt" "$name" "$sum"
  else printf '  ✗ %4ss  %s：%s（日志 %s）\n' "$dt" "$name" "$sum" "$LOG/$name.log"; FAIL=$((FAIL + 1)); fi
}

C++单测() {
  local d=$ROOT/godot/扩展/仿真核心
  local src=(); local f; for f in "$d"/core/*.cpp; do [[ $(basename "$f") == ._* ]] || src+=("$f"); done
  nice -n 19 ${CXX:-c++} -std=c++17 -O2 -pthread -ffp-contract=off -I"$d/core" "${src[@]}" "$d/tests/test_core.cpp" -o "$LOG/test_core" || { echo "摘要：编译失败"; return 1; }
  "$LOG/test_core"; local r=$?
  echo "摘要：$(grep -c '✓' "$LOG/C++单测.log") 项通过，$(grep -c '✗' "$LOG/C++单测.log") 项失败"; return $r
}

Python() {
  cd "$ROOT" && git ls-files -z -co --exclude-standard -- '*.py' | "$PY" -c '
import sys
files = [f for f in sys.stdin.buffer.read().decode().split("\0") if f and not f.split("/")[-1].startswith("._")]; bad = 0
for f in files:
    try: compile(open(f, "rb").read(), f, "exec", dont_inherit=True)
    except SyntaxError as e: bad += 1; print("✗", f, e)
print(f"摘要：{len(files)} 个文件，{bad} 个有语法错误（Python {sys.version.split()[0]}）"); sys.exit(1 if bad else 0)'
}

JSON() {
  cd "$ROOT" && git ls-files -z -co --exclude-standard -- '*.json' | "$PY" -c '
import json, sys
files = [f for f in sys.stdin.buffer.read().decode().split("\0") if f and not f.split("/")[-1].startswith("._")]; bad = 0
for f in files:
    try: json.load(open(f, encoding="utf-8"))
    except Exception as e: bad += 1; print("✗", f, e)
print(f"摘要：{len(files)} 个文件，{bad} 个不合法"); sys.exit(1 if bad else 0)'
}

GDScript() {
  timeout 120 "$G" --headless --path "$ROOT/godot" --script res://工具/语法检查.gd; local r=$?
  echo "摘要：$(grep '^\[语法\] .*个脚本' "$LOG/GDScript.log" | sed 's/^\[语法\] //')"; return $r
}

控制自测() {
  # --车辙=0：车辙模块要从 GPU 读回贴图，无头时读不到；--声音=0：无头没有混音
  timeout -k 10 200 "$G" --headless --path "$ROOT/godot" -- --控制测试 --控制出="$LOG/控制测试" --车辙=0 --声音=0; local r=$?
  local n=$(grep -cE 'SCRIPT ERROR|Parse Error|SHADER ERROR' "$LOG/控制自测.log")
  grep -q '^\[自测\] 完' "$LOG/控制自测.log" || { echo "摘要：没跑完（退出码 $r）"; return 1; }
  echo "摘要：跑完，$(grep -o '车身抖动.*最大 俯仰 [0-9.]*°' "$LOG/控制自测.log" | head -1)，脚本错误 $n"
  [ "$n" -eq 0 ] && [ $r -eq 0 ]
}

数据清单() {
  [ -d "$ROOT/godot/数据/sol0530" ] || { echo "摘要：没有数据，跳过"; return 0; }
  "$PY" "$ROOT/工具/数据清单.py" 校验 && { echo "摘要：$(tail -1 "$LOG/数据清单.log")"; return 0; }
  echo "摘要：数据和清单不符（见日志）；数据是有意改的就跑 工具/数据清单.py 生成"; return 3
}

照片回归() {
  GODOT=$G "$ROOT/godot/渲染.sh" "$LOG/渲染" 13:07 2 || { echo "摘要：渲染失败"; return 1; }
  "$PY" "$ROOT/scripts/Blender/60_实景回归.py" 对照 --渲染目录 "$LOG/渲染" || { echo "摘要：回归脚本失败"; return 1; }
  对比 回归 "$LOG/渲染/指标.json"
}

测帧() {
  for i in $(seq 1 "$ROUNDS"); do
    echo "== 第 $i 轮"; GODOT=$G "$ROOT/godot/测帧.sh" 2560x1440 "默认:" | tee "$LOG/测帧_$i.txt"
  done
  对比 测帧 "$LOG"/测帧_*.txt
}

# 对比 回归 <指标.json> | 对比 测帧 <日志…>：和基准比，打印每项，超阈值返回 1；--写基准 时把这次的数写回基准。
对比() {
  "$PY" - "$ROOT/工具/检查基准.json" "$WRITE" "$@" <<'EOF'
import json, re, sys, time, subprocess, pathlib
基准p, 写, 类 = pathlib.Path(sys.argv[1]), sys.argv[2] == "1", sys.argv[3]; 输入 = sys.argv[4:]
B = json.loads(基准p.read_text()); 阈 = B["阈值"]; 坏 = []; 摘 = []
if 类 == "回归":
    now = {k: v["对照片_拟合后中位误差"] for k, v in json.loads(pathlib.Path(输入[0]).read_text())["机位"].items()}
    for k, v in now.items():
        b = B["回归"].get(k); d = None if b is None else v - b
        print(f"{k}：{v:.2f} DN（基准 {b}，{'' if d is None else f'{d:+.2f}'}）")
        摘.append(f"{v:.2f}" + ("" if d is None else f"({d:+.2f})"))
        if d is not None and d > 阈["回归_DN"]: 坏.append(k)
else:
    runs = {}
    for f in 输入:
        for m in re.finditer(r"测帧 (\S+)：帧 平均 ([\d.]+) ms.*?GPU 平均 ([\d.]+)", open(f).read()):
            runs.setdefault(m[1], []).append((float(m[2]), float(m[3])))
    now = {k: min(v)[0] for k, v in runs.items()}
    for k in B["测帧"]["场景"]:
        if k not in now: print(f"{k}：没测到"); 坏.append(k); continue
        b = B["测帧"]["场景"][k]; r = now[k]/b - 1
        print(f"{k}：{now[k]:.2f} ms（各轮 {[x[0] for x in runs[k]]}，GPU {[x[1] for x in runs[k]]}；基准 {b}，{r*100:+.1f}%）")
        摘.append(f"{k} {now[k]:.2f}({r*100:+.1f}%)")
        if r > 阈["帧时间_比例"]: 坏.append(k)
if 写:
    if 类 == "回归": B["回归"] = now
    else: B["测帧"]["场景"] = now
    提交 = subprocess.run(["git", "-C", str(基准p.parent), "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
    B.setdefault("记录", {})[类] = f"{time.strftime('%F %T')}，提交 {提交}"
    基准p.write_text(json.dumps(B, ensure_ascii=False, indent=1) + "\n"); print("已写基准", 基准p)
print("摘要：" + " ".join(摘) + (f"；超阈值：{', '.join(坏)}" if 坏 else "") + ("（已写基准）" if 写 else ""))
sys.exit(1 if 坏 and not 写 else 0)
EOF
}

echo "检查（$TIER）：$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)$([ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ] && echo +改动)，日志 $LOG"
[ "$TIER" != 托管 ] && "$ROOT/工具/构建信息.sh" > /dev/null 2>&1
步 C++单测 C++单测
步 Python Python
步 JSON JSON
if [ "$TIER" != 托管 ]; then
  [ -x "$G" ] || { echo "  ✗ 找不到引擎 $G（GODOT= 指定）"; exit 1; }
  步 GDScript GDScript
  步 控制自测 控制自测
  步 数据清单 数据清单
fi
if [ "$TIER" = 全 ]; then
  command -v kwin_wayland > /dev/null || { echo "  ✗ 全档要 kwin_wayland 和 GPU"; exit 1; }
  步 照片回归 照片回归
  步 测帧 测帧
fi
echo "$([ $FAIL -eq 0 ] && echo 通过 || echo "失败 $FAIL 项")，用时 $(( $(date +%s) - T0 )) s"
[ $FAIL -eq 0 ]
