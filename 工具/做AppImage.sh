#!/usr/bin/env bash
# 把 工具/导出.sh linux-compat 的导出目录打成 AppImage。在 fedora 上跑（用 podman；没有 sudo 也行）。
# 用法：工具/做AppImage.sh <导出目录> <输出.AppImage>
#   需要：podman 镜像 mars-appimage（见 engine/容器/appimage.Containerfile）、appimagetool（环境变量 APPIMAGETOOL，
#         默认 ~/引擎/多平台产物/appimagetool，来自 github.com/AppImage/appimagetool 的 continuous 版）。
# AppDir 布局：整个导出目录原样放进 usr/bin/（环境.gd 找 data/ 在可执行文件旁，不用改）；AppRun 只转发。
set -euo pipefail
SRC=$(cd "$1" && pwd); OUT=$2; NAME=mars-realtime-drive
TOOL=${APPIMAGETOOL:-$HOME/引擎/多平台产物/appimagetool}
die() { echo "✗ $*" >&2; exit 1; }
[ -x "$SRC/$NAME.x86_64" ] || die "$SRC 里没有 $NAME.x86_64"; [ -x "$TOOL" ] || die "找不到 appimagetool：$TOOL"
T=$(mktemp -d "${TMPDIR:-/tmp}/appdir.XXXXXX"); trap 'rm -rf "$T"' EXIT
A=$T/$NAME.AppDir; mkdir -p "$A/usr/bin"
cp -a --reflink=auto "$SRC/." "$A/usr/bin/"
cp "$SRC/$NAME.png" "$A/$NAME.png"; cp "$SRC/$NAME.png" "$A/.DirIcon"
cat > "$A/$NAME.desktop" <<EOT
[Desktop Entry]
Type=Application
Name=Mars Realtime Drive
Name[zh_CN]=火星实景
Comment=Real-time Mars rover scene (sol 530), unofficial fan project
Exec=$NAME
Icon=$NAME
Categories=Game;Simulation;
Terminal=false
EOT
printf '#!/bin/sh\nH=$(dirname "$(readlink -f "$0")")\nexec "$H/usr/bin/%s.x86_64" "$@"\n' "$NAME" > "$A/AppRun"; chmod +x "$A/AppRun"
cp "$TOOL" "$T/appimagetool"
podman run --rm --security-opt label=disable -v "$T":/w -e ARCH=x86_64 -w /w mars-appimage \
  ./appimagetool --appimage-extract-and-run --comp zstd "$NAME.AppDir" "$NAME.AppImage" > "$T/build.log" 2>&1 || { tail -20 "$T/build.log"; die "appimagetool 失败"; }
mv "$T/$NAME.AppImage" "$OUT"; chmod +x "$OUT"; ls -lh "$OUT" | awk '{print $5, $9}'
