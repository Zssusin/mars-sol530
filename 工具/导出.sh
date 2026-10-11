#!/usr/bin/env bash
# Linux / Windows 导出：自编模板 + PCK + C++ 扩展。不含 data/（不进 PCK 的原始文件）：数据是单独的数据包（工具/做数据包.sh、工具/数据包.py）。
# 说明见 docs/工程化方案.md §9、engine/README.md、docs/发布流程.md。
# 用法：工具/导出.sh [平台] [--冒烟 | --只冒烟]
#   平台（可省，省了就是 linux，行为和以前完全一样）：
#     linux          fedora 本机编的模板和扩展（要 glibc 2.43，只有新发行版能跑；快，开发自测用）
#     linux-compat   旧 glibc（2.28）SDK 编的模板和扩展，Ubuntu 22.04 起 / Debian 12 / Arch / openSUSE / SteamOS 都能跑；发布用
#     windows        mingw-w64 交叉编的模板和 .dll，在 fedora 上导出（见 docs/多平台_交接.md）
#     macos          在 Mac 上跑：Metal 模板和 .dylib，导出 .app（见 docs/多平台_交接.md）
#   产物：产出/导出/mars-realtime-drive-<版本>-linux/（仓库外，不进 git）
#     mars-realtime-drive.x86_64   双击或命令行运行；实景.gd 的参数照旧写在 -- 后面
#     mars-realtime-drive.pck       代码、着色器、声音、导入过的贴图（load() 读的）
#     libmars_sim.linux.template_release.x86_64.so
#   data/ 不在导出目录里。res:// 里不进 PCK 的文件（FileAccess / GLTF / 字体直接读）在数据包里，目录结构不变，玩家解压到导出目录旁（找 data/ 的顺序见 godot/环境.gd）。
#   冒烟和自测用的 data/ 来自「暂存目录」产出/导出/数据-<数据版本>/data（工具/数据包.py 暂存，有就沿用），通过环境变量 MARS_DATA 指过去。
#   --冒烟：导出后在 kwin 虚拟显示里，编辑器版和导出版各量一次启动耗时（--首帧退出，各跑两次取第二次），
#           再各渲染一次同机位（13:07，超采样 2）逐像素比较，并对导出版的渲染跑照片回归。
#   --只冒烟：不重新导出，只做冒烟。
# 引擎：GODOT=<编辑器>，默认 ~/引擎/godot/bin/godot.linuxbsd.editor.x86_64.mars；模板路径写死在 godot/export_presets.cfg。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); HD=$ROOT/godot
G=${GODOT:-$HOME/引擎/godot/bin/godot.linuxbsd.editor.x86_64.mars}
PY=python3; [ -x "$ROOT/.venv/bin/python" ] && PY=$ROOT/.venv/bin/python
NAME=mars-realtime-drive
VER=$(sed -n 's/^config\/version="\(.*\)"/\1/p' "$HD/project.godot")
die() { echo "✗ $*" >&2; exit 1; }
PLAT=linux
case ${1:-} in linux|linux-compat|windows|macos) PLAT=$1; shift ;; esac
MODE=${1:-}
ART=${MARS_ARTIFACTS:-$HOME/引擎/多平台产物}          # 多平台模板和扩展的产物目录（编法见 docs/多平台_交接.md）
case $PLAT in                                          # 预设名、可执行文件名、扩展文件名、输出目录
  linux)        PRESET=Linux;        EXEN=$NAME.x86_64; SOF=libmars_sim.linux.template_release.x86_64.so; OUT=$ROOT/产出/导出/$NAME-$VER-linux ;;
  linux-compat) PRESET=Linux-compat; EXEN=$NAME.x86_64; SOF=libmars_sim.linux.template_release.x86_64.so; OUT=$ROOT/产出/导出/$NAME-$VER-linux-compat
                COMPAT_SO=${COMPAT_SO:-$ART/linux/$SOF} ;;     # 旧 glibc 编的扩展，导出后换进包里
  windows)      PRESET=Windows;      EXEN=$NAME.exe;    SOF=libmars_sim.windows.template_release.x86_64.dll; OUT=$ROOT/产出/导出/$NAME-$VER-windows ;;
  macos)        die "macos 的导出在 Mac 上跑 工具/导出_macos.sh" ;;
esac
EXE=$OUT/$EXEN
DV=$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["数据版本"])' "$HD/数据/sol0530/数据清单.json")
STAGE=$ROOT/产出/导出/数据-$DV                       # 暂存的 data/（不进导出目录；冒烟、自测用 MARS_DATA 指过来）

扩展release() {                       # release 版扩展要和当前 C++ 源码一致：按源码哈希记戳，不一致就重编（只用 CPU）
  local SO=$1 D=$HD/扩展/仿真核心
  local H; H=$(cd "$D" && find core gdextension/src gdextension/SConstruct -type f \( -name '*.cpp' -o -name '*.h' -o -name SConstruct \) | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -c1-16)
  if [ -f "$SO" ] && [ "$(cat "$SO.stamp" 2>/dev/null)" = "$H" ]; then return; fi
  local SC=${SCONS:-$(command -v scons || echo "$HOME/.local/venvs/scons/bin/scons")}
  [ -x "$SC" ] || die "扩展 release 版过期或不存在，又找不到 scons（SCONS=…）"
  echo "扩展 release 版和源码不一致（源码 $H），重编…"
  (cd "$D/gdextension" && "$SC" platform=linux target=template_release api_version=4.7 -j"$(nproc)" > "$ROOT/产出/导出/扩展编译.log" 2>&1) || die "扩展编译失败（产出/导出/扩展编译.log）"
  [ -f "$SO" ] || die "编完没有 $SO"
  echo "$H" > "$SO.stamp"
}

导出() {
  local TPL=$(awk -v n="name=\"$PRESET\"" '$0==n {f=1} f && /^custom_template\/release=/ {gsub(/^[^"]*"|"$/, ""); print; exit}' "$HD/export_presets.cfg")
  local SO=$HD/扩展/仿真核心/bin/$SOF
  [ -x "$G" ] || die "找不到编辑器 $G"
  [ -x "$TPL" ] || die "找不到导出模板 $TPL（编法见 engine/README.md）"
  if [ "$PLAT" = linux ]; then 扩展release "$SO"; else
    [ "$PLAT" = linux-compat ] && { [ -f "$COMPAT_SO" ] || die "没有旧 glibc 版扩展 $COMPAT_SO"; [ -f "$SO" ] || cp "$COMPAT_SO" "$SO"; }   # 导出器要求 bin/ 里有；包里会换成 COMPAT_SO
    [ -f "$SO" ] || die "没有扩展 $SO（先按 docs/多平台_交接.md 编）"
  fi
  "$ROOT/工具/构建信息.sh" > /dev/null
  echo "导出 v$VER → $OUT"
  local t0=$(date +%s); mkdir -p "$ROOT/产出/导出"
  "$G" --headless --path "$HD" --import > "$ROOT/产出/导出/导入.log" 2>&1 || true      # 官方 4.7.2 退出时偶尔 SIGABRT，不影响
  rm -rf "$OUT"; mkdir -p "$OUT"
  "$G" --headless --path "$HD" --export-release "$PRESET" "$EXE" > "$ROOT/产出/导出/导出.log" 2>&1 || true
  grep -E "ERROR|错误" "$ROOT/产出/导出/导出.log" | grep -v "resources still in use" | head -5 || true
  { [ -x "$EXE" ] || { [ "$PLAT" = windows ] && [ -f "$EXE" ]; }; } && [ -f "$OUT/$NAME.pck" ] || die "导出失败，见 产出/导出/导出.log"
  [ -f "$OUT/$(basename "$SO")" ] || die "扩展没跟着导出（.gdextension 的对应平台条目）"
  [ "$PLAT" = linux-compat ] && cp "$COMPAT_SO" "$OUT/$SOF"

  # data/ 不进导出目录（数据包单独发）；暂存一份给冒烟和自测用，目录结构和 res:// 一样
  "$PY" "$ROOT/工具/数据包.py" 暂存 --出 "$STAGE" || die "暂存 data/ 失败"

  # 许可：Godot（MIT，含第三方库署名）、godot-cpp（MIT）、字体 OFL 已在 data/界面/素材/
  cp "$ROOT/THIRD_PARTY.md" "$OUT/"
  cp "$ROOT/docs/试玩说明.md" "$OUT/试玩说明.md"                             # 给玩家的说明（docs/试玩说明.md）
  local E=$(dirname "$(dirname "$G")")
  cp "$E/LICENSE.txt" "$OUT/GODOT_LICENSE.txt"; cp "$E/COPYRIGHT.txt" "$OUT/GODOT_COPYRIGHT.txt"
  cp "$HD/扩展/仿真核心/gdextension/godot-cpp/LICENSE.md" "$OUT/GODOT_CPP_LICENSE.md"
  cp "$HD/build_info.json" "$OUT/build_info.json"
  cp "$HD/界面/素材/NotoSansSC_OFL.txt" "$OUT/NotoSansSC_OFL.txt"          # PCK 里有一份 Noto Sans SC 的子集（缺数据提示页用），OFL 要随字体一起发
  cp "$HD/界面/游戏图标/图标_512.png" "$OUT/$NAME.png"                      # 游戏图标放在可执行文件旁（桌面文件 / 启动器用）；窗口图标在 project.godot config/icon
  cat > "$OUT/说明.txt" <<EOF
火星实景 sol 530 · v$VER（$(sed -n 's/.*"提交": "\(.*\)".*/\1/p' "$HD/build_info.json")）
运行：双击 $EXEN，或命令行 ./$EXEN [-- 参数]，参数和编辑器版相同（见 godot/实景.gd 开头），例如：
  ./$EXEN -- --时刻=15:00
  ./$EXEN -- --渲染=/tmp/渲染      （渲染四台相机后退出）
F1 帮助，F3 性能读数和版本。
数据是单独的数据包 mars-realtime-drive-data-<数据版本>-<n>of<N>.zip（全部几卷都要）：解压到可执行文件所在的文件夹，得到 data/（见 试玩说明.md）。
非 NASA / JPL 官方产品。来源与许可见 THIRD_PARTY.md。
EOF
  if [ "$PLAT" = linux-compat ]; then     # 桌面入口：tar 包解开后运行 ./install-desktop.sh 把启动器写进 ~/.local/share/applications（AppImage 自带 .desktop）
    cat > "$OUT/install-desktop.sh" <<'EOT'
#!/bin/sh
# 在应用菜单里加「火星实景」启动器（路径按这个目录的当前位置写；挪了目录要重跑）。删除：rm ~/.local/share/applications/mars-realtime-drive.desktop
D=$(cd "$(dirname "$0")" && pwd); A=${XDG_DATA_HOME:-$HOME/.local/share}/applications; mkdir -p "$A"
cat > "$A/mars-realtime-drive.desktop" <<EOD
[Desktop Entry]
Type=Application
Name=Mars Realtime Drive
Name[zh_CN]=火星实景
Comment=Real-time Mars rover scene (sol 530), unofficial fan project
Exec=$D/mars-realtime-drive.x86_64
Path=$D
Icon=$D/mars-realtime-drive.png
Categories=Game;Simulation;
Terminal=false
EOD
echo "已写入 $A/mars-realtime-drive.desktop"
EOT
    chmod +x "$OUT/install-desktop.sh"
  fi
  echo "用时 $(( $(date +%s) - t0 )) s"
  ( cd "$OUT" && for f in $EXEN $NAME.pck libmars_sim.* .; do du -sh --apparent-size "$f"; done | sed 's/^/  /' )
}

# 跑 <日志> <命令…>：后台运行，看门狗 10 分钟；脚本错误立即停；出现「全部渲染完」后最多等 5 s 退出
跑() {
  local log=$1; shift
  "$@" > "$log" 2>&1 & local pid=$!
  for i in $(seq 1 600); do
    kill -0 $pid 2>/dev/null || break
    if grep -qE "SCRIPT ERROR|Parse Error|SHADER ERROR" "$log"; then grep -m3 -A2 -E "SCRIPT ERROR|Parse Error|SHADER ERROR" "$log"; kill -9 $pid; return 1; fi
    if grep -q "全部渲染完" "$log"; then
      for j in $(seq 1 10); do kill -0 $pid 2>/dev/null || break; sleep 0.5; done
      kill -0 $pid 2>/dev/null && { kill $pid; sleep 2; kill -9 $pid 2>/dev/null || true; }
      break
    fi
    sleep 1
  done
  kill -0 $pid 2>/dev/null && { echo "超时"; kill -9 $pid; return 1; }
  wait $pid 2>/dev/null || true
}

冒烟() {
  [ -x "$EXE" ] || die "没有导出包 $EXE"
  local D=$ROOT/产出/导出/冒烟_$VER; rm -rf "$D"; mkdir -p "$D"
  local SOCK=marsx-$$
  kwin_wayland --virtual --socket "$SOCK" --width 1280 --height 720 --no-lockscreen > /dev/null 2>&1 &
  local KPID=$!; trap "kill $KPID 2>/dev/null || true" EXIT
  for i in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/$SOCK" ] && break; sleep 0.1; done
  local W=(env WAYLAND_DISPLAY=$SOCK DISPLAY= "MARS_DATA=$STAGE/data" systemd-run --user --scope -q -p MemoryMax=14G -p MemorySwapMax=2G --)
  local ED=("$G" --display-driver wayland --audio-driver Dummy --path "$HD")
  local EX=("$EXE" --display-driver wayland --audio-driver Dummy)

  echo "== 启动耗时（--首帧退出，各两次，取第二次：磁盘缓存是热的）"
  for v in 编辑器 导出; do
    local -n C=$([ $v = 编辑器 ] && echo ED || echo EX)
    local wall=0
    for i in 1 2; do                                   # 墙钟量到日志里出现「首帧」为止（编辑器版退出时偶尔卡住，不算在内）
      local log=$D/启动_${v}_$i.log t0=$(date +%s%N)
      "${W[@]}" "${C[@]}" -- --首帧退出 > "$log" 2>&1 & local pid=$!
      for k in $(seq 1 1200); do grep -q '^\[环境\] 首帧' "$log" && break; kill -0 $pid 2>/dev/null || break; sleep 0.1; done
      wall=$(( ($(date +%s%N) - t0)/1000000 ))
      for k in $(seq 1 50); do kill -0 $pid 2>/dev/null || break; sleep 0.2; done
      kill -0 $pid 2>/dev/null && { kill $pid; sleep 1; kill -9 $pid 2>/dev/null || true; }
      wait $pid 2>/dev/null || true
    done
    grep -q '首帧 [0-9]* ms' "$D/启动_${v}_2.log" || die "$v 版第二次启动 120 s 内没到首帧（$D/启动_${v}_2.log）"
    printf '  %s：引擎计时 %s，墙钟（启动命令到「首帧」日志）%d ms\n' "$v" "$(grep -o '首帧 [0-9]* ms' "$D/启动_${v}_2.log" || echo '没有首帧')" "$wall"
    grep -E "^\[环境\] v" "$D/启动_${v}_2.log" | sed 's/^/    /' || true
  done

  echo "== 同机位渲染（13:07，超采样 2）"
  跑 "$D/编辑器.log" "${W[@]}" "${ED[@]}" -- --渲染="$D/编辑器" --时刻=13:07 --超采样=2 || die "编辑器版渲染失败"
  跑 "$D/导出.log" "${W[@]}" "${EX[@]}" -- --渲染="$D/导出" --时刻=13:07 --超采样=2 || die "导出版渲染失败"
  echo "  日志里的 ERROR 行：编辑器版 $(grep -c ERROR "$D/编辑器.log" || true)，导出版 $(grep -c ERROR "$D/导出.log" || true)"
  "$PY" - "$D/编辑器" "$D/导出" <<'EOF'
import sys, pathlib, numpy as np
from PIL import Image
a, b = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]); worst = 0.0
for p in sorted(a.glob("*.png")):
    q = b/p.name
    if not q.exists(): print(f"  {p.name}：导出版没有"); worst = 99; continue
    x = np.asarray(Image.open(p).convert("RGB"), np.float64); y = np.asarray(Image.open(q).convert("RGB"), np.float64)
    d = np.abs(x - y).max(2)
    print(f"  {p.stem}：平均差 {d.mean():.3f} DN，99% {np.percentile(d, 99):.1f}，最大 {d.max():.0f}，>2 DN {np.mean(d > 2)*100:.3f}%，>8 DN {np.mean(d > 8)*100:.3f}%")
    worst = max(worst, d.mean())
print(f"  逐像素：最差的平均差 {worst:.3f} DN")
EOF
  local REF=$ROOT/DEM/Blender缓存/_素材/PDS/站26_1222/重建/导出
  ls "$REF"/对照_*.png > /dev/null 2>&1 || die "照片回归的参考照片不在 $REF（工作树要 ln -s ../地图/DEM DEM）"
  for v in 编辑器 导出; do
    "$PY" "$ROOT/scripts/Blender/60_实景回归.py" 对照 --渲染目录 "$D/$v" > "$D/回归_$v.log" 2>&1 || die "回归脚本失败（$v）"
    local m; m=$("$PY" -c 'import json,sys; m=json.load(open(sys.argv[1]))["机位"]; assert m, "没有机位"; print(" / ".join(f"{v["对照片_拟合后中位误差"]:.2f}" for v in m.values()))' "$D/$v/指标.json") || die "照片回归没出结果（$v，看 $D/回归_$v.log）"
    echo "  照片回归 $v：$m DN"
  done
  echo "冒烟结果在 $D"
}

case $MODE in
  "") 导出 ;;
  --冒烟) 导出; 冒烟 ;;
  --只冒烟) 冒烟 ;;
  *) die "用法：工具/导出.sh [linux|linux-compat|windows|macos] [--冒烟 | --只冒烟]" ;;
esac
