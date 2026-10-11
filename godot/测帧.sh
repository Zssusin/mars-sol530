#!/usr/bin/env bash
# 性能基线：kwin 虚拟合成器里按给定分辨率跑 实景.gd --测帧，每组参数一轮。
# 用法：godot/测帧.sh 2560x1440 "默认:" "无SDFGI:--SDFGI=0" "…:--SDFGI=0 --地影=0"
# GODOT_FLAGS= 传给引擎本身的参数（放在 -- 前面），如 --verbose。
set -uo pipefail
[ -e "$(dirname "$0")/override.cfg" ] && echo "注意：godot/override.cfg 存在，项目设置被覆盖：$(tr '\n' ' ' < "$(dirname "$0")/override.cfg")" >&2
HD=$(cd "$(dirname "$0")" && pwd)
G=${GODOT:-$HOME/引擎/godot/bin/godot.linuxbsd.editor.x86_64.mars}   # 自编引擎（补丁 0001–0004）；官方版缺补丁，测出的数不算
RES=$1; shift; W=${RES%x*}; H=${RES#*x}
SOCK=marsb-$$
kwin_wayland --virtual --socket "$SOCK" --width "$W" --height "$H" --no-lockscreen >/dev/null 2>&1 &
KPID=$!; trap 'kill $KPID 2>/dev/null || true' EXIT
for i in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/$SOCK" ] && break; sleep 0.1; done
"$G" --headless --path "$HD" --import >/dev/null 2>&1 || true
TMPL=$(mktemp); FAIL=0
for cfg in "$@"; do
  name=${cfg%%:*}; read -r -a A <<< "${cfg#*:}"
  echo "== $name ${A[*]:-}"
  WAYLAND_DISPLAY=$SOCK DISPLAY= timeout -k 10 150 "$G" ${GODOT_FLAGS:-} --display-driver wayland --audio-driver Dummy --path "$HD" --resolution "$RES" --position 0,0 \
    -- --测帧 "${A[@]}" 2>&1 | tee "$TMPL" | grep -E "测帧|场景搭好|ERROR|CDLOD|错误|石块|慢帧|撒石|地貌|Parse|error|far_cascade_cache|延时结束|换天空|显存|^\[环境\] v|地形取高、选块、撒石" | sed 's/^\[实景\] //'
  # C++ 扩展没加载上会静默退回 GDScript：撒石生成慢、测帧时区块不全，帧时偏乐观（2026-10-09 实测地面 8.73 对 9.47 ms）。除非显式 --C++=0，否则判失败。
  if ! printf '%s\n' "${A[@]}" | grep -qx -- "--C++=0" && ! grep -q "地形取高、选块、撒石：C++" "$TMPL"; then
    echo "✗ $name：C++ 扩展没加载（日志里没有「地形取高、选块、撒石：C++」），这组数不算。检查 godot/扩展/仿真核心/bin 是否存在、是否编过 template_debug 版" >&2; FAIL=1
  fi
done
rm -f "$TMPL"; exit ${FAIL:-0}
