#!/usr/bin/env bash
# 控制模块自测：kwin 虚拟显示器（有 GPU、无窗口）里跑 实景.gd --控制测试，截图到 产出/Godot/控制测试/，日志 godot.log。
# 用法：godot/控制/测试.sh [1920x1080] [其它 实景.gd 参数，如 --SDFGI=0]
set -uo pipefail
HD=$(cd "$(dirname "$0")/.." && pwd)
MAP=$(cd "$HD/.." && pwd)
G=${GODOT:-$HOME/Documents/manga/dist/4-2D像素版/tools/Godot_v4.7.2-stable_linux.x86_64}
RES=${1:-1920x1080}; shift || true; W=${RES%x*}; H=${RES#*x}
OUT=$MAP/产出/Godot/控制测试; mkdir -p "$OUT"
SOCK=marsc-$$
kwin_wayland --virtual --socket "$SOCK" --width "$W" --height "$H" --no-lockscreen >/dev/null 2>&1 &
KPID=$!; trap 'kill $KPID 2>/dev/null || true' EXIT
for i in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/$SOCK" ] && break; sleep 0.1; done
"$G" --headless --path "$HD" --import >/dev/null 2>&1 || true
WAYLAND_DISPLAY=$SOCK DISPLAY= timeout -k 10 150 "$G" --display-driver wayland --audio-driver Dummy --path "$HD" --resolution "$RES" --position 0,0 \
  -- --控制测试 --控制出="$OUT" "$@" > "$OUT/godot.log" 2>&1
echo "退出码 $?"
grep -E "控制|自测|SCRIPT ERROR|Parse Error|SHADER ERROR|ERROR" "$OUT/godot.log" | sed 's/^\[自测\] //' | head -80
