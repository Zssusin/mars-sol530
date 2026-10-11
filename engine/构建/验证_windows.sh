#!/usr/bin/env bash
# 在 fedora 上用；产物目录 ~/引擎/多平台产物/，SDK 在 ~/引擎/sdk/，引擎副本 ~/引擎/godot_多平台（git clone 自 ~/引擎/godot 的 mars-4.7 分支）。说明见 docs/多平台_交接.md。
# 持 GPU 锁：wine + winewayland + Vulkan 直通 NVIDIA，在 kwin 虚拟显示里渲染同机位（13:07 超采样 2），和 Linux 导出版逐像素比较
set -uo pipefail
while [ -e ~/.mars_用户在玩 ]; do sleep 30; done
W=~/Documents/"mars-work"/地图_多平台; L=~/引擎/多平台产物/日志/验证_windows.log
exec > "$L" 2>&1
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)} LC_ALL=C.UTF-8
cd "$W"; VER=0.1.0
D=$HOME/引擎/多平台产物/冒烟_windows; mkdir -p $D/导出
SOCK=marsw-$$
kwin_wayland --virtual --socket "$SOCK" --width 1280 --height 720 --no-lockscreen >/dev/null 2>&1 & K=$!
for i in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/$SOCK" ] && break; sleep 0.1; done
cd 产出/导出/mars-realtime-drive-$VER-windows
(WAYLAND_DISPLAY=$SOCK DISPLAY= WINEPREFIX=$HOME/引擎/多平台产物/wineprefix3 WINEDEBUG=err+all timeout -k 10 600 wine ./mars-realtime-drive.exe --rendering-driver vulkan --audio-driver Dummy --resolution 1280x720 -- --渲染=Z:$D/导出 --时刻=13:07 --超采样=2 > $D/wine.log 2>&1) &
P=$!
for i in $(seq 1 600); do kill -0 $P 2>/dev/null || break; grep -aq "全部渲染完" $D/wine.log && { sleep 5; break; }; sleep 1; done
wineserver -k 2>/dev/null; kill $K 2>/dev/null
grep -aE "Vulkan|D3D|环境\] v|地形取高|首帧|全部渲染完|ERROR" $D/wine.log | head -12 | cut -c1-200
ls $D/导出
echo DONE
