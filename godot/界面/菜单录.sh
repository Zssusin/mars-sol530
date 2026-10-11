#!/usr/bin/env bash
# 录主菜单短片：kwin 虚拟显示 + Godot Movie Maker（30 fps 固定步长）+ --菜单录（载入各步另存静帧）→ 拼成 mp4。
# 用法：godot/界面/菜单录.sh [输出目录，默认 产出/菜单录] [1920x1080]    用户在玩（~/.mars_用户在玩）时不跑，退出码 9。
set -uo pipefail
[ -e "$HOME/.mars_用户在玩" ] && { echo "用户在玩，不占 GPU"; exit 9; }
HD=$(cd "$(dirname "$0")/.." && pwd); MAP=$(cd "$HD/.." && pwd)
OUT=$(realpath -m "${1:-$MAP/产出/菜单录}"); RES=${2:-1920x1080}; W=${RES%x*}; H=${RES#*x}
G=${GODOT:-$HOME/引擎/godot/bin/godot.linuxbsd.editor.x86_64.mars}
rm -rf "$OUT"; mkdir -p "$OUT"
SOCK=marsrec-$$
kwin_wayland --virtual --socket "$SOCK" --width "$W" --height "$H" --no-lockscreen >/dev/null 2>&1 &
KPID=$!; trap 'kill $KPID 2>/dev/null || true' EXIT
for i in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/$SOCK" ] && break; sleep 0.1; done
"$G" --headless --path "$HD" --import >/dev/null 2>&1 || true
WAYLAND_DISPLAY=$SOCK DISPLAY= timeout -k 10 300 "$G" --display-driver wayland --audio-driver Dummy --path "$HD" --resolution "$RES" --position 0,0 --always-on-top \
  --write-movie "$OUT/菜单.avi" --fixed-fps 30 -- --菜单录="$OUT/载入" "$@" > "$OUT/日志.txt" 2>&1
grep -E "SCRIPT ERROR|Parse Error|ERROR" "$OUT/日志.txt" | head -5
# 载入静帧每张停 0.4 s（前面）+ 游戏录像
ls "$OUT/载入"/载入_*.png >/dev/null 2>&1 && ffmpeg -y -loglevel error -framerate 2.5 -i "$OUT/载入/载入_%02d.png" -vf "scale=$W:$H,fps=30,format=yuv420p" -c:v libopenh264 -b:v 4M "$OUT/a.mp4"
ffmpeg -y -loglevel error -i "$OUT/菜单.avi" -vf "scale=$W:$H,format=yuv420p" -c:v libopenh264 -b:v 4M "$OUT/b.mp4"
if [ -f "$OUT/a.mp4" ]; then printf "file 'a.mp4'\nfile 'b.mp4'\n" > "$OUT/l.txt"; ffmpeg -y -loglevel error -f concat -i "$OUT/l.txt" -c copy "$OUT/菜单.mp4"; else mv "$OUT/b.mp4" "$OUT/菜单.mp4"; fi
ls -la "$OUT/菜单.mp4"
