#!/usr/bin/env bash
# 在 fedora 的显示器（Plasma 会话）上打开漫游。可以从 ssh 里跑。
# 键位：WASD 走、鼠标看、Shift 快、Q/E 升降、1–4 切机位、T 换时刻、F12 截图（存到 ~/.local/share/godot/app_userdata/火星实景 sol 530/）、Esc 放开鼠标
# 读玩家设置（--设置：user://settings.cfg 的画质预设等，见 godot/环境.gd）。
# 用法：[RES=2560x1440] [FS=1（全屏）] godot/漫游.sh [--SDFGI=0] [--时刻=09:00] …（参数原样传给 实景.gd）
set -euo pipefail
HD=$(cd "$(dirname "$0")" && pwd)
G=${GODOT:-$HOME/引擎/godot/bin/godot.linuxbsd.editor.x86_64.mars}   # 自编引擎（补丁 0001–0004）；官方版缺补丁
"$G" --headless --path "$HD" --import >/dev/null 2>&1 || true
PS=$(pgrep -u "$USER" -x plasmashell | head -1)
[ -n "$PS" ] || { echo "没有找到 Plasma 会话（显示器没登录？）"; exit 1; }
mapfile -t E < <(tr '\0' '\n' < /proc/$PS/environ | grep -E '^(WAYLAND_DISPLAY|DISPLAY|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|XAUTHORITY)=' | sed 's/^/--setenv=/')
systemd-run --user --collect -q --unit "mars-walk-$$" "${E[@]}" -p MemoryMax=14G -- \
  "$G" --path "$HD" --resolution "${RES:-1920x1080}" ${FS:+--fullscreen} -- --设置 "$@"
echo "已在显示器上打开（systemd 单元 mars-walk-$$）"
