#!/usr/bin/env bash
# 在 fedora 上用；产物目录 ~/引擎/多平台产物/，SDK 在 ~/引擎/sdk/，引擎副本 ~/引擎/godot_多平台（git clone 自 ~/引擎/godot 的 mars-4.7 分支）。说明见 docs/多平台_交接.md。
# 旧 glibc SDK 编 Linux 扩展 .so（静态 libstdc++）；输出到 多平台产物/linux/，不碰工作树 bin/ 里的 fedora 本机版。
set -eo pipefail
W=${1:-$HOME/Documents/"mars-work"/地图_多平台}
SDK=$HOME/引擎/sdk/sdk_2023.08_glibc2.28
export PATH=$SDK/bin:$HOME/.local/venvs/scons/bin:$PATH
cd "$W/godot/扩展/仿真核心/gdextension"
flock /tmp/mars_gpu.lock nice -n 10 scons platform=linux target=template_release api_version=4.7 use_static_cpp=yes -j12 > ~/引擎/多平台产物/日志/linux_ext.log 2>&1
mv "$W/godot/扩展/仿真核心/bin/libmars_sim.linux.template_release.x86_64.so" ~/引擎/多平台产物/linux/
echo EXIT=0 >> ~/引擎/多平台产物/日志/linux_ext.log
