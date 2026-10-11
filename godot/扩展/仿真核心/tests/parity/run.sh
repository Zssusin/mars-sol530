#!/usr/bin/env bash
# 对拍：C++ 移植 vs GDScript 原版（同一台机器、同一份合成输入）。
#   run.sh [Godot 路径] [工作目录]
# Mac：Godot 默认 /opt/mars/tools/godot/Godot.app/Contents/MacOS/Godot；fedora 上传 GODOT 二进制路径。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CORE="$HERE/../../core"
GODOT="${1:-/opt/mars/tools/godot/Godot.app/Contents/MacOS/Godot}"
WORK="${2:-${TMPDIR:-/tmp}/marsim_parity}"
mkdir -p "$WORK/proj" "$WORK/data"
# -ffp-contract=off：GDScript 每个运算单独舍入，C++ 不能合成 FMA
c++ -std=c++17 -O2 -ffp-contract=off -pthread -Wall -Wextra -I"$CORE" "$CORE/terrain_core.cpp" "$CORE/scatter_core.cpp" "$HERE/../parity_dump.cpp" -o "$WORK/parity_dump"
"$WORK/parity_dump" "$WORK/data"
cp "$HERE/原版/"*.gd "$HERE/宿主桩.gd" "$HERE/对拍.gd" "$WORK/proj/"
printf '[application]\nconfig/name="对拍"\n' > "$WORK/proj/project.godot"
"$GODOT" --headless --path "$WORK/proj" --script res://对拍.gd -- "$WORK/data" 2>&1 | grep -v "^Godot Engine\|^$" || true
python3 "$HERE/parity_compare.py" "$WORK/data"
