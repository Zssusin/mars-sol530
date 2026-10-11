#!/usr/bin/env bash
# 在 fedora 上用；产物目录 ~/引擎/多平台产物/，SDK 在 ~/引擎/sdk/，引擎副本 ~/引擎/godot_多平台（git clone 自 ~/引擎/godot 的 mars-4.7 分支）。说明见 docs/多平台_交接.md。
# 容器（mars-win-cross：Ubuntu 24.04 + mingw-w64 GCC 13 posix）里交叉编 Windows 导出模板。持 GPU 锁。
set -eo pipefail
while [ -e ~/.mars_用户在玩 ]; do sleep 30; done
mkdir -p ~/引擎/多平台产物/windows
flock /tmp/mars_gpu.lock timeout 2400 podman run --rm --userns=keep-id --security-opt label=disable \
  --memory=20g -v $HOME/引擎/godot_多平台:/src -v $HOME/引擎/scons缓存:/cache -e SCONS_CACHE=/cache -e SCONS_CACHE_LIMIT=20 -w /src mars-win-cross \
  nice -n 10 scons platform=windows target=template_release arch=x86_64 use_mingw=yes d3d12=no accesskit=no production=yes extra_suffix=mars -j12 \
  > ~/引擎/多平台产物/日志/windows_tpl.log 2>&1
echo EXIT=$? >> ~/引擎/多平台产物/日志/windows_tpl.log
