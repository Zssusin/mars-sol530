#!/usr/bin/env bash
# 自编引擎补丁 A/B：临时写 override.cfg（覆盖项目设置，不动 project.godot），跑完删掉，再调用 渲染.sh 或 测帧.sh。
# 用法：godot/补丁测试.sh "键=值;键=值" 渲染.sh <渲染.sh 的参数…>
#       godot/补丁测试.sh "lights_and_shadows/contact_shadow/enabled=true" 测帧.sh 2560x1440 "接触阴影:"
#   键写 rendering/ 下面的部分；第一个参数给空串 = 不覆盖。默认用自编引擎（GODOT= 可改）。
set -euo pipefail
HD=$(cd "$(dirname "$0")" && pwd)
SETS=$1; shift; CMD=$1; shift
export GODOT=${GODOT:-$HOME/引擎/godot/bin/godot.linuxbsd.editor.x86_64.mars}
[ -e "$HD/override.cfg" ] && { echo "override.cfg 已存在（上次没删干净？）先删掉再跑"; exit 1; }
trap 'rm -f "$HD/override.cfg"' EXIT
trap 'exit 143' TERM INT HUP                                   # 被 systemctl stop / Ctrl-C 杀时也走 EXIT，删掉 override.cfg
{ echo "[rendering]"; IFS=';' read -ra KV <<< "$SETS"; for kv in "${KV[@]}"; do [ -n "$kv" ] && echo "$kv"; done; } > "$HD/override.cfg"
echo "引擎 $GODOT；覆盖：${SETS:-无}"
bash "$HD/$CMD" "$@"
