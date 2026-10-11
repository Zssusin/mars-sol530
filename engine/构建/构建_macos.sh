#!/usr/bin/env bash
# macOS（Apple 芯片）：在 Mac 上编模板、编辑器、扩展，并装成 macos_template.zip。详见 docs/多平台_交接.md §macOS。
# 引擎源码：git clone <fedora>:~/引擎/godot（分支 mars-4.7，带补丁 0001–0004）到 $E；scons 在 venv 里（pip install scons）。
# exFAT 外置盘会生成 ._* 文件，scons 会把 ._*.cpp 当源码编，所以编之前先删。
set -euo pipefail
E=${E:-/opt/mars/godot-mars-macos}; SC=${SC:-/opt/mars/venv-scons/bin/scons}
cd "$E"; export COPYFILE_DISABLE=1; find . -name '._*' -delete
# 模板（release）：约 4 分钟（M5，-j6）
nice -n 10 "$SC" platform=macos arch=arm64 target=template_release production=yes lto=thin vulkan=no accesskit=no extra_suffix=mars -j6
# 编辑器（在 Mac 上跑渲染、导入、导出用）：约 5 分钟
nice -n 10 "$SC" platform=macos arch=arm64 target=editor production=no vulkan=no accesskit=no extra_suffix=mars -j6
# 导出器要的模板包：zip 里是 macos_template.app，可执行文件名 godot_macos_release.arm64
rm -rf bin/macos_template.app bin/macos_template.zip; cp -R misc/dist/macos_template.app bin/; mkdir -p bin/macos_template.app/Contents/MacOS
cp bin/godot.macos.template_release.arm64.mars bin/macos_template.app/Contents/MacOS/godot_macos_release.arm64
(cd bin && zip -qr -y macos_template.zip macos_template.app -x '*/._*')
# 扩展 .dylib（release 给导出，debug 给编辑器）
cd "$(dirname "$0")/../../godot/扩展/仿真核心/gdextension"
for t in template_release template_debug; do nice -n 10 "$SC" platform=macos arch=arm64 target=$t api_version=4.7 -j6; done
