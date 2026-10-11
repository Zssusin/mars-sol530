#!/usr/bin/env bash
# 写 godot/build_info.json（不进 git）：游戏版本、git 短哈希、有无未提交改动、引擎版本串、数据版本、生成时间。
# 导出前由 工具/导出.sh 调用；编辑器里运行时 godot/环境.gd 直接问 git，这个文件只作后备。
# 用法：工具/构建信息.sh [输出路径，默认 godot/build_info.json]；打印写入的内容。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$ROOT/godot/build_info.json}

GAME=$(sed -n 's/^config\/version="\(.*\)"/\1/p' "$ROOT/godot/project.godot")
COMMIT=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "?")
DIRTY=false
[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ] && DIRTY=true
ENGINE=$(sed -n 's/^版本=//p' "$ROOT/engine/ENGINE_REF" 2>/dev/null | head -1)
ENGINE_COMMIT=$(sed -n 's/^提交=//p' "$ROOT/engine/ENGINE_REF" 2>/dev/null | head -1 | cut -c1-9)
DATA=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["数据版本"])' \
  "$ROOT/godot/数据/sol0530/数据清单.json" 2>/dev/null || echo "?")

cat > "$OUT" <<EOF
{
 "游戏": "${GAME:-?}",
 "提交": "$COMMIT",
 "改动": $DIRTY,
 "引擎": "${ENGINE:-?}",
 "引擎提交": "${ENGINE_COMMIT:-?}",
 "数据": "$DATA",
 "生成": "$(date -u +%FT%TZ)"
}
EOF
cat "$OUT"
