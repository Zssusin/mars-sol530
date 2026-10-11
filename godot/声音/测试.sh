#!/usr/bin/env bash
# 声音模块自测：kwin 虚拟显示器里跑 实景.gd --声音测试（自动开车、换机位、录 ~40 s），然后离线分析录音。
# 用法：godot/声音/测试.sh [1280x720] [其它 实景.gd 参数]
# 结果：产出/Godot/声音测试/{录音.wav, 录音.json, godot.log, 分析.png}
set -uo pipefail
HD=$(cd "$(dirname "$0")/.." && pwd)
MAP=$(cd "$HD/.." && pwd)
G=${GODOT:-$HOME/Documents/manga/dist/4-2D像素版/tools/Godot_v4.7.2-stable_linux.x86_64}
RES=${1:-1280x720}; shift || true; W=${RES%x*}; H=${RES#*x}
OUT=$MAP/产出/Godot/声音测试; mkdir -p "$OUT"
SOCK=marss-$$
kwin_wayland --virtual --socket "$SOCK" --width "$W" --height "$H" --no-lockscreen >/dev/null 2>&1 &
KPID=$!; trap 'kill $KPID 2>/dev/null || true' EXIT
for i in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/$SOCK" ] && break; sleep 0.1; done
"$G" --headless --path "$HD" --import >/dev/null 2>&1 || true
WAYLAND_DISPLAY=$SOCK DISPLAY= timeout -k 10 180 "$G" --display-driver wayland --audio-driver ${AUDIO:-Dummy} --path "$HD" --resolution "$RES" --position 0,0 \
  -- --声音测试 --声音录制="$OUT/录音.wav" --声音风速=4 --SDFGI=0 "$@" > "$OUT/godot.log" 2>&1
echo "退出码 $?"
grep -E "声音|SCRIPT ERROR|Parse Error|ERROR|WARNING" "$OUT/godot.log" | head -60
[ -f "$OUT/录音.wav" ] && "$MAP/.venv/bin/python" "$MAP/资料/声音/工具/析录音.py" "$OUT/录音.wav"
