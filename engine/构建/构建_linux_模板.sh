#!/usr/bin/env bash
# 在 fedora 上用；产物目录 ~/引擎/多平台产物/，SDK 在 ~/引擎/sdk/，引擎副本 ~/引擎/godot_多平台（git clone 自 ~/引擎/godot 的 mars-4.7 分支）。说明见 docs/多平台_交接.md。
# 用 Godot 官方 buildroot SDK（glibc 2.28, gcc 13.2）编 Linux 导出模板。持 GPU 锁。
set -eo pipefail
while [ -e ~/.mars_用户在玩 ]; do sleep 30; done
SDK=$HOME/引擎/sdk/sdk_2023.08_glibc2.28
export PATH=$SDK/bin:$HOME/.local/venvs/scons/bin:$PATH
export SCONS_CACHE=$HOME/引擎/scons缓存 SCONS_CACHE_LIMIT=20
cd ~/引擎/godot_多平台
flock /tmp/mars_gpu.lock timeout 2400 systemd-run --user --scope -q -p MemoryMax=20G -- nice -n 10 \
  scons platform=linuxbsd target=template_release arch=x86_64 production=yes extra_suffix=mars -j12 \
  > ~/引擎/多平台产物/日志/linux_tpl.log 2>&1
echo EXIT=$? >> ~/引擎/多平台产物/日志/linux_tpl.log
