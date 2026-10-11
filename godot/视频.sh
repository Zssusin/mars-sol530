#!/usr/bin/env bash
# 无界面渲染视频：65_视频路径.py 出路径 → Godot 逐帧渲（kwin 虚拟合成器，同 渲染.sh）→ ffmpeg 拼 mp4。
# 用法：godot/视频.sh [输出目录，默认 产出/Godot/视频] [Godot 额外参数，如 --只=走近 --超采样=1]
# 车辆动画：GEN=66_车辆动画.py PJ=产出/Godot/车辆/路径.json CUT=sol0530_车辆 godot/视频.sh 产出/Godot/车辆
set -euo pipefail
HD=$(cd "$(dirname "$0")" && pwd)
MAP=$(cd "$HD/.." && pwd)
OUT=$(realpath -m "${1:-$MAP/产出/Godot/视频}"); shift || true
G=${GODOT:-$HOME/引擎/godot/bin/godot.linuxbsd.editor.x86_64.mars}   # 自编引擎（补丁 0001–0004）；官方版缺补丁，测出的数不算
mkdir -p "$OUT"
GEN=${GEN:-65_视频路径.py}                                   # 路径脚本：65 环站视频，66 车辆动画
PJ=${PJ:-$MAP/产出/Godot/视频/路径.json}
[ "$GEN" = 无 ] || "$MAP/.venv/bin/python" "$MAP/scripts/Godot/$GEN" ${PATH_ARGS:-}   # GEN=无：直接用现成的 PJ
SOCK=marsv-$$
kwin_wayland --virtual --socket "$SOCK" --width 1280 --height 720 --no-lockscreen >/dev/null 2>&1 &
KPID=$!
trap 'kill $KPID 2>/dev/null || true' EXIT
for i in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/$SOCK" ] && break; sleep 0.1; done
"$G" --headless --path "$HD" --import > "$OUT/import.log" 2>&1 || true
WAYLAND_DISPLAY=$SOCK DISPLAY= systemd-run --user --scope -q -p MemoryMax=14G -p MemorySwapMax=2G -- \
  "$G" --display-driver wayland --audio-driver Dummy --path "$HD" -- --视频="$PJ" --出="$OUT/帧" "$@" > "$OUT/godot.log" 2>&1 &
GPID=$!
for i in $(seq 1 5400); do                                 # 看门狗：90 分钟；脚本错误立即停
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
grep -E "^\[实景\]|ERROR" "$OUT/godot.log" | tail -20 || true
FPS=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['fps'])" "$PJ")
SHOTS=$(python3 -c "import json,sys;print(' '.join(s['name'] for s in json.load(open(sys.argv[1]))['shots']))" "$PJ")
LIST=()
for n in $SHOTS; do                                         # 按镜头顺序；fedora 的 ffmpeg 没有 libx264，用显卡 NVENC
  d="$OUT/帧/$n"; [ -f "$d/00000.png" ] || continue
  ffmpeg -y -loglevel error -framerate "$FPS" -i "$d/%05d.png" -c:v h264_nvenc -preset p7 -rc vbr -cq 19 -b:v 0 -pix_fmt yuv420p "$OUT/$n.mp4"
  LIST+=("$OUT/$n.mp4"); echo "→ $OUT/$n.mp4"
done
if [ ${#LIST[@]} -gt 1 ]; then
  printf "file '%s'\n" "${LIST[@]}" > "$OUT/拼接.txt"
  ffmpeg -y -loglevel error -f concat -safe 0 -i "$OUT/拼接.txt" -c copy "$OUT/${CUT:-sol0530_Godot}.mp4" && echo "→ $OUT/${CUT:-sol0530_Godot}.mp4"
fi
