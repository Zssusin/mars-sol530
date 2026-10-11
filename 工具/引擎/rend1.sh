#!/bin/bash
# rend1.sh <输出目录> [渲染.sh 的其余参数…]：GPU 锁 + 用户在玩时等；OVR= 覆盖项目设置
WT="$HOME/Documents/mars-work/地图_引擎"
G=${GODOT:-/home/user/引擎/godot/bin/godot.linuxbsd.editor.x86_64.mars}
o=$1; shift
while [ -e ~/.mars_用户在玩 ]; do sleep 30; done
if [ -n "${OVR:-}" ]; then flock /tmp/mars_gpu.lock env GODOT=$G bash "$WT/godot/补丁测试.sh" "$OVR" 渲染.sh "$o" ${T:-13:07} ${SS:-2} "$@"
else flock /tmp/mars_gpu.lock env GODOT=$G "$WT/godot/渲染.sh" "$o" ${T:-13:07} ${SS:-2} "$@"; fi
