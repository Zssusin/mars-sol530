#!/usr/bin/env bash
# 无界面渲染四台相机（Godot 跑在不可见的 kwin 虚拟合成器里，同 manga 项目 tools/render.sh 的做法）。
# 用法：godot/渲染.sh [输出目录，默认 产出/Godot/实景] [时刻，默认 13:07] [超采样，默认 2] [其余参数原样给 实景.gd，如 --网格=LOD]
# 之后：.venv/bin/python scripts/Blender/60_实景回归.py 对照 --渲染目录 产出/Godot/实景 --基准 <封存_v5/渲染>
set -euo pipefail
[ -e "$(dirname "$0")/override.cfg" ] && echo "注意：godot/override.cfg 存在，项目设置被覆盖：$(tr '\n' ' ' < "$(dirname "$0")/override.cfg")" >&2
HD=$(cd "$(dirname "$0")" && pwd)
MAP=$(cd "$HD/.." && pwd)
OUT=$(realpath -m "${1:-$MAP/产出/Godot/实景}")
T=${2:-13:07}
SS=${3:-2}
G=${GODOT:-$HOME/引擎/godot/bin/godot.linuxbsd.editor.x86_64.mars}   # 自编引擎（补丁 0001–0004）；官方版缺补丁，测出的数不算
mkdir -p "$OUT"
SOCK=mars-$$
kwin_wayland --virtual --socket "$SOCK" --width 1280 --height 720 --no-lockscreen >/dev/null 2>&1 &
KPID=$!
trap 'kill $KPID 2>/dev/null || true' EXIT
for i in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/$SOCK" ] && break; sleep 0.1; done
"$G" --headless --path "$HD" --import > "$OUT/import.log" 2>&1 || true
WAYLAND_DISPLAY=$SOCK DISPLAY= systemd-run --user --scope -q -p MemoryMax=14G -p MemorySwapMax=2G -- \
  "$G" --display-driver wayland --audio-driver Dummy --path "$HD" -- --渲染="$OUT" --时刻="$T" --超采样="$SS" "${@:4}" > "$OUT/godot.log" 2>&1 &
GPID=$!
for i in $(seq 1 600); do                                  # 看门狗：10 分钟；脚本错误立即停
  kill -0 $GPID 2>/dev/null || break
  if grep -qE "SCRIPT ERROR|Parse Error|SHADER ERROR" "$OUT/godot.log" 2>/dev/null; then
    echo "出错，中止："; grep -A3 -E "SCRIPT ERROR|Parse Error|SHADER ERROR" "$OUT/godot.log" | head -30
    kill -9 $GPID 2>/dev/null || true; exit 1
  fi
  if grep -q "全部渲染完" "$OUT/godot.log" 2>/dev/null; then
    for j in $(seq 1 10); do kill -0 $GPID 2>/dev/null || break; sleep 0.5; done
    kill -0 $GPID 2>/dev/null && { echo "退出卡住，TERM"; kill $GPID; sleep 2; kill -9 $GPID 2>/dev/null || true; }
    break
  fi
  sleep 1
done
kill -0 $GPID 2>/dev/null && { echo "超时，TERM"; kill $GPID; }
wait $GPID 2>/dev/null || true
grep -E "^\[实景\]|ERROR" "$OUT/godot.log" | head -40 || true
# C++ 扩展没加载上会静默退回 GDScript（撒石区块可能不全），渲染结果不能当回归用。除非显式 --C++=0，否则判失败。
if ! printf "%s\n" "${@:4}" | grep -qx -- "--C++=0" && ! grep -q "地形取高、选块、撒石：C++" "$OUT/godot.log"; then
  echo "✗ C++ 扩展没加载（$OUT/godot.log 里没有「地形取高、选块、撒石：C++」）。检查 godot/扩展/仿真核心/bin" >&2; exit 1
fi
