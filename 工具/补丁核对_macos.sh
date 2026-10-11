#!/usr/bin/env bash
# 在 Mac（Metal）上核对引擎补丁 0001–0004：每个补丁单独打开，渲染同机位（13:07，超采样 1，1280x720），和全关基线逐像素比较，
# 并检查日志里有没有着色器 / Metal 错误。结果在 产出/导出/补丁核对_macos/。编辑器版（Mac 自编）跑，不用 .app。
# 用法：工具/补丁核对_macos.sh
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); HD=$ROOT/godot
G=${GODOT:-/opt/mars/godot-mars-macos/bin/godot.macos.editor.arm64.mars}
O=$ROOT/产出/导出/补丁核对_macos_$(date +%H%M); mkdir -p "$O"; export COPYFILE_DISABLE=1
trap 'rm -f "$HD/override.cfg"' EXIT
渲染() {  # 名 覆盖项（rendering/ 下，分号分隔） 额外参数…
  local n=$1 sets=$2; shift 2; mkdir -p "$O/$n"
  { echo "[rendering]"; echo "$sets" | tr ';' '\n' | sed '/^$/d'; } > "$HD/override.cfg"
  perl -e 'alarm 600; exec @ARGV' "$G" --path "$HD" --rendering-driver metal --resolution 1280x720 -- --渲染="$O/$n" --时刻=13:07 --超采样=1 "$@" > "$O/$n.log" 2>&1
  rm -f "$HD/override.cfg"
  echo "${n}：ERROR $(grep -c 'ERROR' "$O/$n.log") 行，着色器相关 $(grep -ciE 'shader|metal.*(fail|error)|MSL' "$O/$n.log") 行，出图 $(ls "$O/$n" | wc -l) 张"
}
渲染 基线 ""
渲染 0001接触阴影 "lights_and_shadows/contact_shadow/enabled=true"
渲染 0002远级联缓存2 "lights_and_shadows/directional_shadow/far_cascade_update_interval=2"
渲染 0003多次反弹AO "lights_and_shadows/multi_bounce_occlusion/enabled=true"
渲染 0004预通道简化关 "" --预通道简化=0
python3 - "$O" <<'PY'
import sys, pathlib, numpy as np
from PIL import Image
o = pathlib.Path(sys.argv[1]); base = o/"基线"
for d in sorted(p for p in o.iterdir() if p.is_dir() and p.name != "基线"):
    for f in sorted(p for p in base.glob("*.png") if not p.name.startswith("._")):
        x = np.asarray(Image.open(f).convert("RGB"), np.float64); y = np.asarray(Image.open(d/f.name).convert("RGB"), np.float64)
        e = (y - x); a = np.abs(e).max(2)
        print(f"{d.name:14s} {f.stem[:6]:8s} 平均亮度变化 {e.mean():+.3f} DN，平均绝对差 {a.mean():.3f}，>4 DN {np.mean(a>4)*100:.3f}%，>8 DN {np.mean(a>8)*100:.3f}%")
PY
