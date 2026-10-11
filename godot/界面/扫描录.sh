#!/usr/bin/env bash
# 录扫描脉冲短片：kwin 虚拟显示 + Godot Movie Maker（30 fps）+ --扫描录 → mp4（相机转向最近的险坡，放脉冲，看到小标收回）。
# 用法：godot/界面/扫描录.sh [输出目录，默认 产出/扫描录] [1920x1080] [额外参数]    用户在玩（~/.mars_用户在玩）时不跑，退出码 9。
set -uo pipefail
[ -e "$HOME/.mars_用户在玩" ] && { echo "用户在玩，不占 GPU"; exit 9; }
HD=$(cd "$(dirname "$0")/.." && pwd); MAP=$(cd "$HD/.." && pwd)
OUT=$(realpath -m "${1:-$MAP/产出/扫描录}"); RES=${2:-1920x1080}; shift 2 2>/dev/null || true; W=${RES%x*}; H=${RES#*x}
G=${GODOT:-$HOME/引擎/godot/bin/godot.linuxbsd.editor.x86_64.mars}
rm -rf "$OUT"; mkdir -p "$OUT"
SOCK=marsscanrec-$$
kwin_wayland --virtual --socket "$SOCK" --width "$W" --height "$H" --no-lockscreen >/dev/null 2>&1 &
KPID=$!; trap 'kill $KPID 2>/dev/null || true' EXIT
for i in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/$SOCK" ] && break; sleep 0.1; done
"$G" --headless --path "$HD" --import >/dev/null 2>&1 || true
WAYLAND_DISPLAY=$SOCK DISPLAY= timeout -k 10 300 "$G" --display-driver wayland --audio-driver Dummy --path "$HD" --resolution "$RES" --position 0,0 --always-on-top \
  --write-movie "$OUT/扫描.avi" --fixed-fps 30 -- --扫描录 "$@" > "$OUT/日志.txt" 2>&1
grep -E "SCRIPT ERROR|Parse Error|SHADER|扫描\]" "$OUT/日志.txt" | head -5
ffmpeg -y -loglevel error -i "$OUT/扫描.avi" -vf "scale=$W:$H,format=yuv420p" -c:v libopenh264 -b:v 5M "$OUT/扫描.mp4"
ls -la "$OUT/扫描.mp4"
