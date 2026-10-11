#!/usr/bin/env bash
# 在 fedora 上用；产物目录 ~/引擎/多平台产物/，SDK 在 ~/引擎/sdk/，引擎副本 ~/引擎/godot_多平台（git clone 自 ~/引擎/godot 的 mars-4.7 分支）。说明见 docs/多平台_交接.md。
set -eo pipefail
W=${1:-$HOME/Documents/"mars-work"/地图_多平台}
flock /tmp/mars_gpu.lock podman run --rm --userns=keep-id --security-opt label=disable -v "$W":/w -w /w/godot/扩展/仿真核心/gdextension mars-win-cross \
  nice -n 10 scons platform=windows use_mingw=yes target=template_release api_version=4.7 use_static_cpp=yes arch=x86_64 -j12 \
  > ~/引擎/多平台产物/日志/windows_ext.log 2>&1
echo EXIT=$? >> ~/引擎/多平台产物/日志/windows_ext.log
