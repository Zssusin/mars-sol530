#!/usr/bin/env bash
# 地图台自测：kwin 虚拟显示里跑实景 + --地图台测试 → ~/holomap/地图台截图/<分辨率>/*.png + 日志，逐项打印 ✓ / ✗。
# 用法：godot/界面/地图台/测试.sh [2560x1440] [额外参数，如 --地图台样张=1]    用户在渲染机上玩时（有 ~/.mars_用户在玩）不跑，退出码 9。
#   日志：~/holomap/日志_<时间>.txt。要测的项见 自测.gd。
set -uo pipefail
[ -e "$HOME/.mars_用户在玩" ] && { echo "用户在玩，不占 GPU"; exit 9; }
HD=$(cd "$(dirname "$0")/../.." && pwd)
G=${GODOT:-$HOME/引擎/godot/bin/godot.linuxbsd.editor.x86_64.mars}
RES=${1:-2560x1440}; shift || true; W=${RES%x*}; H=${RES#*x}
OUT=$HOME/holomap/地图台截图/$RES                    # 截图放在工程外：放在 res:// 里会让 检查.sh 的测帧（远足）慢约 15 %（实测，原因没查）
mkdir -p "$OUT" "$HOME/holomap"
SOCK=marsholo-$$
kwin_wayland --virtual --socket "$SOCK" --width "$W" --height "$H" --no-lockscreen >/dev/null 2>&1 &
KPID=$!; trap 'kill $KPID 2>/dev/null || true' EXIT
for i in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/$SOCK" ] && break; sleep 0.1; done
"$G" --headless --path "$HD" --import >/dev/null 2>&1 || true
LOG=$HOME/holomap/日志_$(date +%H%M%S).txt
WAYLAND_DISPLAY=$SOCK DISPLAY= flock /tmp/mars_gpu.lock timeout -k 10 420 "$G" --display-driver wayland --audio-driver Dummy --path "$HD" --resolution "$RES" --position 0,0 \
  -- --地图台测试="$OUT" "$@" 2>&1 | tee "$LOG" | grep -E "地图台|SCRIPT ERROR|Parse Error|SHADER ERROR|ERROR|错误|at: |C\+\+" | sed 's/^\[实景\] //'
echo "日志 $LOG；截图 $OUT"
