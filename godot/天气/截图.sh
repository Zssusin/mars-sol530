#!/usr/bin/env bash
# 天气模块自测：kwin 虚拟合成器里跑实时漫游，天气模块在第 N 帧截图后退出（离线 --渲染 不加载模块，所以用这个）。
# 用法：godot/天气/截图.sh 输出.png [分辨率 1600x900] [其余参数原样给 实景.gd，如 --远机位=E,N,az --天气=3 --天气演示=3]
set -uo pipefail
HD=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(realpath -m "$1"); RES=${2:-1600x900}
G=${GODOT:-$HOME/Documents/manga/dist/4-2D像素版/tools/Godot_v4.7.2-stable_linux.x86_64}
SOCK=wx-$$
kwin_wayland --virtual --socket "$SOCK" --width "${RES%x*}" --height "${RES#*x}" --no-lockscreen >/dev/null 2>&1 &
KPID=$!; trap 'kill $KPID 2>/dev/null || true' EXIT
for i in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/$SOCK" ] && break; sleep 0.1; done
"$G" --headless --path "$HD" --import >/dev/null 2>&1 || true
WAYLAND_DISPLAY=$SOCK DISPLAY= timeout -k 10 180 "$G" --display-driver wayland --audio-driver Dummy --path "$HD" --resolution "$RES" --position 0,0 \
  -- --相机模式=自由 --天气截图="$OUT" "${@:3}" 2>&1 | grep -E "天气|ERROR|SCRIPT|SHADER|Parse|error|场景搭好" | grep -v "^\s*$" | head -40
