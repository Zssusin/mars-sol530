#!/usr/bin/env bash
# 发布：从 origin/main 的最新提交出一个可分发的 Linux 试玩包。流程说明见 docs/发布流程.md。
# 用法：工具/发布.sh <版本，如 0.2.0> [平台] [--推送] [--上传]
#   平台（可省，省了就是 linux，行为和以前完全一样）：linux | linux-compat | windows | macos
#   包名：mars-realtime-drive-<版本>-<平台>-<架构>.（tar.zst|zip）；linux-compat 的包名里平台写 linux。
#   1. 前置检查：工作树干净、HEAD 就是 origin/main、子模块就位、有 DEM/ 参考照片、数据和清单一致、用户没在玩（~/.mars_用户在玩）。
#   2. 改版本号：project.godot 的 config/version、CHANGELOG「[未发布]」→「[版本] - 日期」，本地提交（先不推）。
#   3. scripts/检查.sh 全（GPU 锁里跑）。
#   4. 工具/导出.sh --冒烟（GPU 锁里跑）：导出、启动耗时、编辑器版和导出版逐像素比较、导出版照片回归。
#   5. 导出版玩法自测：kwin 虚拟显示里跑导出的可执行文件 + --玩法测试，必须「通过」。
#   6. 打包：产出/发布/mars-realtime-drive-<版本>-<平台>-<架构>.tar.zst（windows 是 .zip；linux-compat 另出 .AppImage）+ .sha256 + 发布说明（CHANGELOG 这一节）。
#      程序包里没有 data/；数据另做成三个平台共用的分卷包 mars-realtime-drive-data-<数据版本>-<n>of<N>.zip（工具/做数据包.sh，这个数据版本的包已在 产出/发布/ 且校验一致就跳过）。
#   --推送：全部通过后把版本提交推到 origin/main，打标签 v<版本> 并推送。不带就只在本地，方便先看包。
#   --上传：再用 gh 建一个草稿 Release（私有仓），附上包、数据包（Release 里已经有的同名文件不重传）和校验和。要 --推送。
#   --预演：在分支上试跑整条流程（改发布脚本、打包方式时用）：不要求 HEAD 是 origin/main、工作树干净、标签不存在；不改版本号、不提交；
#           不能和 --推送 / --上传 一起用。--跳过检查 跳过第 3 步（检查.sh 全）：和 --预演 一起用，或者这个版本的标签已经存在时用（同一个版本出第二、第三个平台，代码已经在第一个平台上检查过）。
# 任何一步失败就停，版本提交留在本地（git reset --hard origin/main 可撤）。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
VER=${1:-}; shift || true
PUSH=0; UPLOAD=0; PLAT=linux; DRY=0; SKIPCHECK=0
for a in "$@"; do case $a in --推送) PUSH=1 ;; --上传) UPLOAD=1; PUSH=1 ;; --预演) DRY=1 ;; --跳过检查) SKIPCHECK=1 ;; linux|linux-compat|windows|macos) PLAT=$a ;; *) echo "不认识的参数：$a" >&2; exit 2 ;; esac; done
die() { echo "✗ $*" >&2; exit 1; }
[ $DRY = 0 ] || [ $PUSH = 0 ] || die "--预演 不能和 --推送 / --上传 一起用"
[ $SKIPCHECK = 0 ] || [ $DRY = 1 ] || git rev-parse -q --verify "refs/tags/v$VER" >/dev/null || die "--跳过检查 只能和 --预演 一起用，或者这个版本的标签已经存在（第一个平台已经过了检查）"
step() { echo; echo "== $*"; }
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || die "版本号要像 0.2.0 或 0.2.0-demo"
G=${GODOT:-$HOME/引擎/godot/bin/godot.linuxbsd.editor.x86_64.mars}
PY=python3; [ -x "$ROOT/.venv/bin/python" ] && PY=$ROOT/.venv/bin/python
NAME=mars-realtime-drive
[ "$PLAT" != macos ] || die "macOS 包在 Mac 上出：工具/导出_macos.sh --冒烟 --包（见 docs/发布流程.md）"
case $PLAT in                                         # 导出目录名后缀、包名里的「平台-架构」
  linux)        SUF=linux;        PKGID=linux-x86_64 ;;
  linux-compat) SUF=linux-compat; PKGID=linux-compat-x86_64 ;;
  windows)      SUF=windows;      PKGID=windows-x86_64 ;;
esac
DV=$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["数据版本"])' godot/数据/sol0530/数据清单.json)
STAGE=$ROOT/产出/导出/数据-$DV                       # 暂存的 data/（工具/导出.sh 做的）；导出版自测用 MARS_DATA 指过来
LOCK=/tmp/mars_gpu.lock
REL=$ROOT/产出/发布; mkdir -p "$REL"
LOG=$REL/发布-$VER.log; : > "$LOG"
exec > >(tee -a "$LOG") 2>&1

step "1. 前置检查"
[ -e "$HOME/.mars_用户在玩" ] && die "用户在玩（~/.mars_用户在玩），不占 GPU"
git fetch -q origin
if [ $DRY = 0 ]; then
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "工作树有未提交的改动"
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "HEAD 不是 origin/main（先 git pull --ff-only）"
fi
REUSE=0   # 标签已存在 = 这个版本已经出过别的平台的包：不再改版本号、不再推标签，只出这个平台的包（HEAD 要在标签的提交上或之后，且 config/version 已是 $VER）
if [ $DRY = 1 ]; then
  grep -q "^config/version=\"$VER\"" godot/project.godot || die "--预演 要用 project.godot 里现在的版本号 $VER"; REUSE=1; echo "（预演：不改版本号、不检查提交和标签）"
elif git rev-parse -q --verify "refs/tags/v$VER" >/dev/null; then
  [ "$PLAT" != linux ] || die "标签 v$VER 已存在"
  grep -q "^config/version=\"$VER\"" godot/project.godot || die "标签 v$VER 已存在，但 project.godot 的版本不是 $VER"; REUSE=1
fi
[ -z "$(git submodule status --recursive | grep -v '^ ')" ] || die "子模块没初始化或不在记录的提交上（git submodule update --init --recursive）"
[ -d DEM/Blender缓存/_素材/PDS/站26_1222/重建/导出 ] || die "缺 DEM/（照片回归的参考照片；工作树里 ln -s ../地图/DEM DEM）"
"$PY" 工具/数据清单.py 校验 --目录 godot/数据/sol0530 || die "数据和清单不符"
echo "提交 $(git rev-parse --short HEAD)，版本 $VER"

step "2. 版本号"
if [ $REUSE = 1 ]; then echo "标签 v$VER 已存在，沿用（不改版本号）"; else
sed -i "s/^config\/version=\".*\"/config\/version=\"$VER\"/" godot/project.godot
grep -q "^## \[未发布\]" CHANGELOG.md || die "CHANGELOG 里没有「## [未发布]」"
sed -i "0,/^## \[未发布\]/s//## [未发布]\n\n## [$VER] - $(date +%F)/" CHANGELOG.md
git commit -q -am "发布 v$VER

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
echo "本地提交 $(git rev-parse --short HEAD)（还没推）"
fi

step "3. 检查（全）"
if [ $SKIPCHECK = 1 ]; then echo "（跳过）"; else flock "$LOCK" scripts/检查.sh 全 || die "检查没过"; fi

step "4. 导出 + 冒烟"
OUT=$ROOT/产出/导出/$NAME-$VER-$SUF
if [ "$PLAT" = windows ]; then          # Windows 在 fedora 上只导出（没有原生运行环境）；wine 冒烟见 docs/多平台_交接.md
  flock "$LOCK" 工具/导出.sh windows || die "Windows 导出没过"
  [ -f "$OUT/$NAME.exe" ] || die "找不到导出的 $OUT/$NAME.exe"
else
  flock "$LOCK" 工具/导出.sh $PLAT --冒烟 || die "导出或冒烟没过"
  [ -x "$OUT/$NAME.x86_64" ] || die "找不到导出的 $OUT/$NAME.x86_64"
fi

if [ "$PLAT" != windows ]; then
step "5. 导出版玩法自测"
T=$REL/自测-$VER; rm -rf "$T"; mkdir -p "$T"
flock "$LOCK" bash -c '
  set -uo pipefail
  SOCK=marsrel-$$
  kwin_wayland --virtual --socket "$SOCK" --width 2560 --height 1440 --no-lockscreen >/dev/null 2>&1 &
  K=$!; trap "kill $K 2>/dev/null || true" EXIT
  for i in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/$SOCK" ] && break; sleep 0.1; done
  # 用自己的空用户目录：自测按默认设置判断（比如界面档 1），不能读到这台机器上玩家自己改过的 settings.cfg
  XDG_DATA_HOME="$2/用户目录" MARS_DATA="$3/data" WAYLAND_DISPLAY=$SOCK DISPLAY= timeout -k 10 900 "$1/'"$NAME"'.x86_64" --display-driver wayland --audio-driver Dummy --resolution 2560x1440 --position 0,0 \
    -- --玩法测试="$2" --玩法新档=1 > "$2/日志.txt" 2>&1
  true' _ "$OUT" "$T" "$STAGE"
grep -E "^\[玩法自测\] (通过|失败)" "$T/日志.txt" | tail -1
grep -q "^\[玩法自测\] 通过" "$T/日志.txt" || die "导出版玩法自测没过（$T/日志.txt）"
fi

step "6. 打包"
if [ "$PLAT" = windows ]; then
  PKG=$REL/$NAME-$VER-$PKGID.zip; rm -f "$PKG"
  "$PY" - "$(dirname "$OUT")" "$(basename "$OUT")" "$PKG" <<'EOPY'
import sys, os, zipfile
base, name, out = sys.argv[1:4]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:      # 文件名按 UTF-8 存（置 0x800 标志位）
    for d, _, fs in os.walk(os.path.join(base, name)):
        for f in sorted(fs):
            p = os.path.join(d, f); z.write(p, os.path.relpath(p, base))
EOPY
else
  PKG=$REL/$NAME-$VER-$PKGID.tar.zst
  tar -C "$(dirname "$OUT")" --zstd -cf "$PKG" "$(basename "$OUT")"
  if [ "$PLAT" = linux-compat ]; then     # 另出 AppImage
    flock "$LOCK" 工具/做AppImage.sh "$OUT" "$REL/$NAME-$VER-$PKGID.AppImage" || die "AppImage 打包失败"
    (cd "$REL" && sha256sum "$NAME-$VER-$PKGID.AppImage" > "$NAME-$VER-$PKGID.AppImage.sha256")
  fi
fi
(cd "$REL" && sha256sum "$(basename "$PKG")" > "$(basename "$PKG").sha256")
awk -v v="$VER" '$0 ~ "^## \\["v"\\]" {f=1; next} f && /^## \[/ {exit} f' CHANGELOG.md > "$REL/发布说明-$VER.md"
ls -lh "$PKG" | awk '{print $5, $9}'; cat "$PKG.sha256"
step "6b. 数据包（程序包里没有 data/）"
工具/做数据包.sh || die "数据包没做成"
DATAPKGS=$(ls "$REL/$NAME-data-$DV-"*of*.zip "$REL/$NAME-data-$DV-"*of*.zip.sha256)

if [ "$PUSH" = 1 ]; then
  step "7. 推送"
  if [ $REUSE = 0 ]; then
    git push origin HEAD:main
    git tag -a "v$VER" -m "v$VER"
    git push origin "v$VER"
  fi
  if [ "$UPLOAD" = 1 ]; then
    EXTRA=(); [ "$PLAT" = linux-compat ] && EXTRA=("$REL/$NAME-$VER-$PKGID.AppImage" "$REL/$NAME-$VER-$PKGID.AppImage.sha256")
    if gh release view "v$VER" >/dev/null 2>&1; then
      HAVE=$(gh release view "v$VER" --json assets --jq '.assets[].name')
      for f in $DATAPKGS; do grep -qxF "$(basename "$f")" <<<"$HAVE" || EXTRA+=("$f"); done      # 数据包同名的已经传过就不重传
      gh release upload "v$VER" "$PKG" "$PKG.sha256" "${EXTRA[@]}"
    else
      gh release create "v$VER" --draft --title "v$VER（试玩）" --notes-file "$REL/发布说明-$VER.md" "$PKG" "$PKG.sha256" "${EXTRA[@]}" $DATAPKGS
    fi
  fi
else
  echo; echo "没推送：版本提交只在本地。看过包没问题再：git push origin HEAD:main && git tag -a v$VER -m v$VER && git push origin v$VER"
fi
echo; echo "✓ 发布 v$VER 完成，日志 $LOG"
