#!/usr/bin/env bash
# 地图台录屏（1080p MP4）：录.sh 开场|鼠标 [输出目录]    Movie Maker 逐帧（30 fps），窗口置顶；转码用 libopenh264（渲染机的 ffmpeg 没有 libx264）。
set -uo pipefail
[ -e "$HOME/.mars_用户在玩" ] && { echo "用户在玩，不占 GPU"; exit 9; }
HD=$(cd "$(dirname "$0")/../.." && pwd)
G=${GODOT:-$HOME/引擎/godot/bin/godot.linuxbsd.editor.x86_64.mars}
W=1920; H=1080; M=${1:-鼠标}; OUT=${2:-$HOME/样张临时/地图台2}
mkdir -p "$OUT" "$HOME/holomap"
SOCK=marsrec-$$
kwin_wayland --virtual --socket "$SOCK" --width $W --height $H --no-lockscreen >/dev/null 2>&1 &
KPID=$!; trap 'kill $KPID 2>/dev/null || true' EXIT
for i in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/$SOCK" ] && break; sleep 0.1; done
AVI=$HOME/holomap/地图台_$M.avi; rm -f "$AVI"
WAYLAND_DISPLAY=$SOCK DISPLAY= flock /tmp/mars_gpu.lock timeout -k 10 300 "$G" --display-driver wayland --audio-driver Dummy --path "$HD" --resolution ${W}x${H} --position 0,0 --always-on-top \
  --write-movie "$AVI" --fixed-fps 30 -- --地图台测试="$HOME/holomap/录_$M" --地图台样张=1 --地图台录="$M" 2>&1 | grep -E "地图台|SCRIPT ERROR|Parse Error|ERROR|C\+\+" | head -20
ffmpeg -y -loglevel error -i "$AVI" -c:v libopenh264 -b:v 12M -pix_fmt yuv420p "$OUT/地图台_$M.mp4" && echo "→ $OUT/地图台_$M.mp4"
