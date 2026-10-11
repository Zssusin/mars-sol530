#!/usr/bin/env bash
# 主菜单自测：kwin 虚拟显示里跑实景 + --菜单测试 → 界面/截图/菜单/<分辨率>/*.png（载入、落地、各选中项、设置、关于、进游戏、Esc 回来），打印每步结果和计时。
# 用法：godot/界面/菜单测试.sh [2560x1440] [额外参数]    用户在渲染机上玩时（有 ~/.mars_用户在玩）不跑，退出码 9。
set -uo pipefail
[ -e "$HOME/.mars_用户在玩" ] && { echo "用户在玩，不占 GPU"; exit 9; }
HD=$(cd "$(dirname "$0")/.." && pwd)
G=${GODOT:-$HOME/引擎/godot/bin/godot.linuxbsd.editor.x86_64.mars}
RES=${1:-2560x1440}; shift || true; W=${RES%x*}; H=${RES#*x}
OUT=$HD/界面/截图/菜单/$RES
mkdir -p "$OUT"; touch "$HD/界面/截图/.gdignore"
SOCK=marsmenu-$$
kwin_wayland --virtual --socket "$SOCK" --width "$W" --height "$H" --no-lockscreen >/dev/null 2>&1 &
KPID=$!; trap 'kill $KPID 2>/dev/null || true' EXIT
for i in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/$SOCK" ] && break; sleep 0.1; done
"$G" --headless --path "$HD" --import >/dev/null 2>&1 || true
WAYLAND_DISPLAY=$SOCK DISPLAY= timeout -k 10 480 "$G" --display-driver wayland --audio-driver Dummy --path "$HD" --resolution "$RES" --position 0,0 \
  -- --菜单测试="$OUT" "$@" 2>&1 | tee "$OUT/日志.txt" | grep -E "菜单|载入|首帧|SCRIPT ERROR|Parse Error|ERROR|错误|场景搭好|at: " | sed 's/^\[实景\] //'
