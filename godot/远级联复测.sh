#!/usr/bin/env bash
# 0002 远级联缓存复测（2026-10-06 改为默认保留紧凑剔除之后）：基线、间隔 2/4、间隔 4 + 旧做法（余量区不剔除）、出图。
set -uo pipefail
HD=$(cd "$(dirname "$0")" && pwd); M=$(cd "$HD/.." && pwd)
MARS=$HOME/引擎/godot/bin/godot.linuxbsd.editor.x86_64.mars
O="$M/产出/Godot/补丁验收"; R=2560x1440; K=lights_and_shadows/directional_shadow
fps() { grep -E "^== |测帧 (地面|绕车|高空|远足)|慢帧|far_cascade_cache" ; }
GODOT=$MARS bash "$HD/测帧.sh" $R "自编:" | fps
for n in 2 4; do bash "$HD/补丁测试.sh" "$K/far_cascade_update_interval=$n" 测帧.sh $R "远级联$n:" | fps; done
bash "$HD/补丁测试.sh" "$K/far_cascade_update_interval=4;$K/far_cascade_cull_margin=true" 测帧.sh $R "远级联4_余量不剔除:" | fps
GODOT=$MARS bash "$HD/测帧.sh" $R "自编再测:" | fps
echo "### 复用率（--verbose，只看统计，不看帧时）"
GODOT_FLAGS=--verbose bash "$HD/补丁测试.sh" "$K/far_cascade_update_interval=4" 测帧.sh $R "远级联4统计:" | grep -E "^== |far_cascade_cache"
bash "$HD/补丁测试.sh" "$K/far_cascade_update_interval=4" 渲染.sh "$O/远级联4" 13:07 2 > /dev/null 2>&1
echo "远级联4: $(ls "$O/远级联4"/*.png 2>/dev/null | wc -l) 张"
echo "### 完"
