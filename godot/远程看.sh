#!/usr/bin/env bash
# 远程看实时漫游：虚拟 KWin + krfb 虚拟显示器（VNC，只听 localhost，经 ssh 隧道从 Mac 看）+ Godot 全屏在虚拟显示器上。
# 用法：godot/远程看.sh <VNC 密码> [分辨率 1600x900] [其余参数给 实景.gd]
# Mac：ssh -N -L 5910:localhost:5900 fedora，然后 open vnc://localhost:5910
set -uo pipefail
HD=$(cd "$(dirname "$0")" && pwd)
PW=$1; RES=${2:-1600x900}; shift; [ $# -gt 0 ] && shift
G=${GODOT:-$HOME/引擎/godot/bin/godot.linuxbsd.editor.x86_64.mars}
SOCK=mars-view
kwin_wayland --virtual --socket "$SOCK" --width 640 --height 360 --no-lockscreen > /tmp/远程看_kwin.log 2>&1 &
KPID=$!
trap 'kill $GPID $VPID $KPID 2>/dev/null || true' EXIT INT TERM
for i in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/$SOCK" ] && break; sleep 0.1; done
WAYLAND_DISPLAY=$SOCK QT_QPA_PLATFORM=wayland krfb-virtualmonitor --resolution "$RES" --name 火星 --password "$PW" --port 5900 > /tmp/远程看_vnc.log 2>&1 &
VPID=$!
sleep 2
WAYLAND_DISPLAY=$SOCK DISPLAY= "$G" --display-driver wayland --audio-driver Dummy --path "$HD" --screen 1 --resolution "$RES" --fullscreen -- "$@" > /tmp/远程看_godot.log 2>&1 &
GPID=$!
wait $GPID
