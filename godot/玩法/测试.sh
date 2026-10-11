#!/usr/bin/env bash
# 玩法自测：kwin 虚拟显示里跑实景（实时漫游）+ --玩法测试 → 玩法/截图/<分辨率>/*.png，打印每步结果。
# 用法：godot/玩法/测试.sh [2560x1440] [额外参数；--界面=旧 用 v2 界面跑，截图放 <分辨率>_旧/]
#   用户在渲染机上玩游戏时（有 ~/.mars_用户在玩）不跑，退出码 9。进度用新档（--玩法新档=1），不动玩家的 user://玩法A.json。
set -uo pipefail
[ -e "$HOME/.mars_用户在玩" ] && { echo "用户在玩，不占 GPU"; exit 9; }
HD=$(cd "$(dirname "$0")/.." && pwd)
G=${GODOT:-$HOME/引擎/godot/bin/godot.linuxbsd.editor.x86_64.mars}
RES=${1:-2560x1440}; shift || true; W=${RES%x*}; H=${RES#*x}
OUT=$HD/玩法/截图/$RES; case " $* " in *" --界面=旧 "*) OUT=${OUT}_旧 ;; esac
mkdir -p "$OUT"; touch "$HD/玩法/截图/.gdignore"
SOCK=marsplay-$$
kwin_wayland --virtual --socket "$SOCK" --width "$W" --height "$H" --no-lockscreen >/dev/null 2>&1 &
KPID=$!; trap 'kill $KPID 2>/dev/null || true' EXIT
for i in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/$SOCK" ] && break; sleep 0.1; done
"$G" --headless --path "$HD" --import >/dev/null 2>&1 || true
WAYLAND_DISPLAY=$SOCK DISPLAY= timeout -k 10 900 "$G" --display-driver wayland --audio-driver Dummy --path "$HD" --resolution "$RES" --position 0,0 \
  -- --玩法测试="$OUT" --玩法新档=1 "$@" 2>&1 | tee "$OUT/日志.txt" | grep -E "玩法|拍照|SCRIPT ERROR|Parse Error|ERROR|错误|场景搭好|at: " | sed 's/^\[实景\] //'
