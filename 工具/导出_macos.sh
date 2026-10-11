#!/usr/bin/env bash
# macOS（Apple 芯片）导出：在 Mac 上跑。自编 Metal 模板 + .dylib + PCK，打成 .app，再打成 zip。不含 data/：数据是单独的数据包（工具/做数据包.sh）。
# 用法：工具/导出_macos.sh [--冒烟] [--包]
#   产物：产出/导出/mars-realtime-drive-<版本>-macos/mars-realtime-drive.app
#         --包：另打 产出/发布/mars-realtime-drive-<版本>-macos-arm64.zip + .sha256（数据包在 fedora 上做，三个平台共用，不在 Mac 上做）
#         --冒烟：导出后启动 .app（--首帧退出），日志里要有扩展加载那一行
# 需要（编法见 docs/多平台_交接.md §macOS）：
#   GODOT      Mac 编辑器，默认 /opt/mars/godot-mars-macos/bin/godot.macos.editor.arm64.mars
#   模板 zip   godot/export_presets.cfg「macOS」预设的 custom_template/release（macos_template.zip，里面是 macos_template.app）
#   扩展       godot/扩展/仿真核心/bin/libmars_sim.macos.template_release.arm64.dylib
#   数据       godot/数据/sol0530、资料/地貌参数（从 fedora scp 过来，见 docs/多平台_交接.md）。只用来做冒烟 / 自测的暂存 data/ 和数据包，不进 .app
# 为什么要临时改 project.godot：macOS arm64 导出器强制要求打开「Import ETC2 ASTC」，但 override.cfg 不起作用；
#   脚本导出前加一行、导出后还原（trap），所以 Linux / Windows 的导入设置不受影响。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); HD=$ROOT/godot
OUTROOT=${MARS_OUT:-$ROOT/产出}          # 产物根目录。同一个版本号再导出会 rm -rf 同名目录、覆盖同名 zip：想留着旧的就把 MARS_OUT 指到别处
G=${GODOT:-/opt/mars/godot-mars-macos/bin/godot.macos.editor.arm64.mars}
NAME=mars-realtime-drive
VER=$(sed -n 's/^config\/version="\(.*\)"/\1/p' "$HD/project.godot")
OUT=$OUTROOT/导出/$NAME-$VER-macos; APP=$OUT/$NAME.app
SO=libmars_sim.macos.template_release.arm64.dylib
SMOKE=0; PKG=0
for a in "$@"; do case $a in --冒烟) SMOKE=1 ;; --包) PKG=1 ;; *) echo "用法：工具/导出_macos.sh [--冒烟] [--包]" >&2; exit 2 ;; esac; done
die() { echo "✗ $*" >&2; exit 1; }
[ "$(uname)" = Darwin ] || die "只能在 Mac 上跑"
export COPYFILE_DISABLE=1
[ -x "$G" ] || die "找不到 Mac 编辑器 $G"
[ -f "$HD/扩展/仿真核心/bin/$SO" ] || die "没有 ${SO}（scons platform=macos arch=arm64 target=template_release api_version=4.7，见交接文档）"
[ -d "$HD/数据/sol0530" ] && [ -d "$ROOT/资料/地貌参数" ] || die "数据不在（godot/数据/sol0530、资料/地貌参数）"
TPL=$(awk '/^name="macOS"/ {f=1} f && /^custom_template\/release=/ {gsub(/^[^"]*"|"$/, ""); print; exit}' "$HD/export_presets.cfg")
[ -f "$TPL" ] || die "找不到 macOS 模板 zip：${TPL}（改 godot/export_presets.cfg 里 macOS 预设的路径）"
"$ROOT/工具/构建信息.sh" > /dev/null 2>&1 || true

cp "$HD/project.godot" "$OUTROOT/.project.godot.bak" 2>/dev/null || { mkdir -p "$OUTROOT"; cp "$HD/project.godot" "$OUTROOT/.project.godot.bak"; }
trap 'cp "$OUTROOT/.project.godot.bak" "$HD/project.godot"' EXIT
sed -i '' 's/^\[rendering\]$/[rendering]\
\
textures\/vram_compression\/import_etc2_astc=true/' "$HD/project.godot"
find "$HD" "$ROOT/资料" \( -name '._*' \) -delete 2>/dev/null || true

echo "导出 v$VER → $APP"
rm -rf "$OUT"; mkdir -p "$OUT" "$OUTROOT/导出"
"$G" --headless --path "$HD" --import > "$OUTROOT/导出/导入_macos.log" 2>&1 || true
"$G" --headless --path "$HD" --export-release macOS "$APP" > "$OUTROOT/导出/导出_macos.log" 2>&1 || true
[ -d "$APP/Contents/MacOS" ] || die "导出失败，见 产出/导出/导出_macos.log"
find "$APP" -name '._*' -delete

# 对外文件名 ASCII 化：导出器用项目名「火星实景 sol 530」当可执行文件名和 pck 名
OLD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")
mv "$APP/Contents/MacOS/$OLD" "$APP/Contents/MacOS/$NAME"
[ -f "$APP/Contents/Resources/$OLD.pck" ] && mv "$APP/Contents/Resources/$OLD.pck" "$APP/Contents/Resources/$NAME.pck"
PB=/usr/libexec/PlistBuddy
$PB -c "Set :CFBundleExecutable $NAME" "$APP/Contents/Info.plist"
$PB -c "Set :CFBundleName Mars-Realtime-Drive" "$APP/Contents/Info.plist" 2>/dev/null || true
$PB -c "Set :CFBundleDisplayName Mars-Realtime-Drive" "$APP/Contents/Info.plist" 2>/dev/null || true
[ -f "$APP/Contents/Frameworks/$SO" ] || die "扩展没跟着导出（.gdextension 的 macos.release.arm64）"

# 暂存 data/（不进 .app）：冒烟和自测用 MARS_DATA 指过来；玩家的 data/ 来自数据包，放在 .app 旁边（环境.gd 的顺序）
DV=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["数据版本"])' "$HD/数据/sol0530/数据清单.json")
STAGE=$OUTROOT/导出/数据-$DV
python3 "$ROOT/工具/数据包.py" 暂存 --出 "$STAGE" || die "暂存 data/ 失败"
cp "$ROOT/THIRD_PARTY.md" "$ROOT/docs/试玩说明.md" "$HD/build_info.json" "$OUT/"
E=$(dirname "$(dirname "$G")")
cp "$E/LICENSE.txt" "$OUT/GODOT_LICENSE.txt"; cp "$E/COPYRIGHT.txt" "$OUT/GODOT_COPYRIGHT.txt"
cp "$HD/扩展/仿真核心/gdextension/godot-cpp/LICENSE.md" "$OUT/GODOT_CPP_LICENSE.md"
cp "$HD/界面/素材/NotoSansSC_OFL.txt" "$OUT/NotoSansSC_OFL.txt"           # PCK 里有一份 Noto Sans SC 的子集（缺数据提示页用）
cat > "$OUT/说明.txt" <<EOT
火星实景 sol 530 · v${VER}（macOS，Apple 芯片，Metal）
未签名：第一次打开请在 Finder 里对 $NAME.app 右键 →「打开」；或终端：xattr -dr com.apple.quarantine $NAME.app
命令行：$NAME.app/Contents/MacOS/$NAME -- --时刻=15:00 （参数见 godot/实景.gd 开头）
数据是单独的数据包 mars-realtime-drive-data-<数据版本>-<n>of<N>.zip（全部几卷都要）：解压到这个文件夹里（和 .app 并排），得到 data/（见 试玩说明.md）。
MARS_DATA=<data 目录> 或 -- --数据目录=<data 目录> 可指到别处。F1 帮助，F3 性能读数和版本。
非 NASA / JPL 官方产品。来源与许可见 THIRD_PARTY.md。
EOT
echo "  $(du -sh "$APP" | cut -f1) $APP"

if [ $SMOKE = 1 ]; then
  L=$OUTROOT/导出/冒烟_macos_$VER.log
  MARS_DATA="$STAGE/data" perl -e 'alarm 300; exec @ARGV' "$APP/Contents/MacOS/$NAME" -- --首帧退出 > "$L" 2>&1 || true
  grep -E "^\[环境\] v|地形取高、选块、撒石|首帧 [0-9]+ ms|SCRIPT ERROR" "$L" | cut -c1-200
  grep -q "地形取高、选块、撒石：C++" "$L" || die "冒烟失败：扩展没加载（${L}）"
  grep -q "首帧 [0-9]* ms" "$L" || die "冒烟失败：没到首帧（${L}）"
fi
if [ $PKG = 1 ]; then
  # ad-hoc 签名（不是开发者签名，不公证）：Apple 芯片要求可执行文件至少有 ad-hoc 签名；改了文件名和 Info.plist 之后要重签。
  # exFAT 放不下扩展属性，codesign 在上面会失败（找 ._Info.plist），所以拷到内置盘（$TMPDIR，APFS）签，再从那里打包。
  SG=$(mktemp -d); ditto --norsrc "$OUT" "$SG/$(basename "$OUT")"
  # exFAT 上的 ._* 伴生文件会被原样拷过来；不删的话它们被签进封条，打 zip 时又被丢掉，玩家解压后的 .app 就过不了签名校验
  find "$SG" -name '._*' -delete
  # 扩展的安装名是编译时的绝对路径（带本机盘符和目录），对外的包里改成 @rpath 名；改完签名失效，下面的 --deep 重签会补上
  install_name_tool -id "@rpath/$SO" "$SG/$(basename "$OUT")/$NAME.app/Contents/Frameworks/$SO" 2>/dev/null || die "改扩展安装名失败"
  codesign --force --deep -s - "$SG/$(basename "$OUT")/$NAME.app" > "$OUTROOT/导出/codesign_macos.log" 2>&1 || die "ad-hoc 签名失败（产出/导出/codesign_macos.log）"
  codesign --verify --deep --strict "$SG/$(basename "$OUT")/$NAME.app" || die "签名校验没过"
  mkdir -p "$OUTROOT/发布"; Z=$OUTROOT/发布/$NAME-$VER-macos-arm64.zip; rm -f "$Z"
  (cd "$SG" && ditto -c -k --norsrc --keepParent "$(basename "$OUT")" "$Z"); rm -rf "$SG"
  (cd "$OUTROOT/发布" && shasum -a 256 "$(basename "$Z")" > "$(basename "$Z").sha256")
  ls -lh "$Z" | awk '{print $5, $9}'
fi
