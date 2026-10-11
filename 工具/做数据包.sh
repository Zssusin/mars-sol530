#!/usr/bin/env bash
# 做数据包：把 data/（godot/数据/sol0530、界面字体和图标、资料/地貌参数）做成三个平台共用的分卷 zip，放进 产出/发布/：
#   mars-realtime-drive-data-<数据版本>-<n>of<N>.zip + .sha256（每卷 ≤ 1.9 GB，每卷能单独解压，顶层都是 data/）
# 用法：工具/做数据包.sh        （在有数据的工作树里跑；Linux 和 Mac 都行）
# 这个数据版本的包已经在 产出/发布/ 里且 .sha256 都对得上就跳过。分卷方法和格式见 工具/数据包.py 开头、docs/发布流程.md。
# 暂存目录 产出/导出/数据-<数据版本>/data 也是 工具/导出.sh、工具/导出_macos.sh 冒烟和自测时 MARS_DATA 指的地方。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
PY=python3; [ -x "$ROOT/.venv/bin/python" ] && PY=$ROOT/.venv/bin/python
DV=$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["数据版本"])' godot/数据/sol0530/数据清单.json) || { echo "✗ 没有 godot/数据/sol0530/数据清单.json" >&2; exit 1; }
STAGE=$ROOT/产出/导出/数据-$DV
"$PY" 工具/数据包.py 暂存 --出 "$STAGE"
"$PY" 工具/数据包.py 打包 --根 "$STAGE" --出 "$ROOT/产出/发布"
