#!/usr/bin/env bash
# 在 fedora 上用；产物目录 ~/引擎/多平台产物/，SDK 在 ~/引擎/sdk/，引擎副本 ~/引擎/godot_多平台（git clone 自 ~/引擎/godot 的 mars-4.7 分支）。说明见 docs/多平台_交接.md。
# 持一次 GPU 锁：导出 native 和 compat → 各自冒烟（编辑器对导出逐像素）→ native 对 compat 逐像素 → 测帧 A/B/A/B（2560x1440）
set -uo pipefail
while [ -e ~/.mars_用户在玩 ]; do sleep 30; done
W=~/Documents/"mars-work"/地图_多平台; L=~/引擎/多平台产物/日志/验证_linux.log
exec > "$L" 2>&1
cd "$W"; export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
PY=$W/.venv/bin/python
工具/导出.sh linux > /dev/null || echo "native 导出失败"
VER=$(sed -n 's/^config\/version="\(.*\)"/\1/p' godot/project.godot)
工具/导出.sh linux-compat > /dev/null || echo "compat 导出失败"
for p in linux linux-compat; do
  echo "######## 冒烟 $p"; 工具/导出.sh $p --只冒烟 2>&1
  rm -rf 产出/导出/冒烟_${p}; cp -a 产出/导出/冒烟_$VER 产出/导出/冒烟_${p}
done
echo "######## native 导出 vs compat 导出（同机位 13:07 超采样 2）"
"$PY" - 产出/导出/冒烟_linux/导出 产出/导出/冒烟_linux-compat/导出 <<'EOF'
import sys, pathlib, numpy as np
from PIL import Image
a, b = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
for p in sorted(a.glob("*.png")):
    x=np.asarray(Image.open(p).convert("RGB"),np.float64); y=np.asarray(Image.open(b/p.name).convert("RGB"),np.float64); d=np.abs(x-y).max(2)
    print(f"  {p.stem}：平均差 {d.mean():.4f} DN，最大 {d.max():.0f}，不同像素 {np.mean(d>0)*100:.4f}%，>2 DN {np.mean(d>2)*100:.4f}%")
EOF
echo "######## 测帧 A/B（2560x1440，kwin 虚拟显示）"
SOCK=marsv-$$
kwin_wayland --virtual --socket "$SOCK" --width 2560 --height 1440 --no-lockscreen >/dev/null 2>&1 & K=$!
for i in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/$SOCK" ] && break; sleep 0.1; done
for round in 1 2; do for p in linux linux-compat; do
  echo "== $p 第 $round 轮"
  WAYLAND_DISPLAY=$SOCK DISPLAY= timeout -k 10 200 "产出/导出/mars-realtime-drive-$VER-$p/mars-realtime-drive.x86_64" --display-driver wayland --audio-driver Dummy --resolution 2560x1440 --position 0,0 -- --测帧 2>&1 | grep -E "测帧 [^ ]+：帧|地形取高" | cut -c1-200
done; done
kill $K 2>/dev/null
echo DONE
