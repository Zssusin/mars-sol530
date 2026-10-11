#!/usr/bin/env bash
# 自编引擎（4.7.2 + 补丁 0001–0004）验收：等价性、各补丁效果与开销。结果在 产出/Godot/补丁验收/。
set -uo pipefail
HD=$(cd "$(dirname "$0")" && pwd); M=$(cd "$HD/.." && pwd)
OFF=$HOME/Documents/manga/dist/4-2D像素版/tools/Godot_v4.7.2-stable_linux.x86_64
MARS=$HOME/引擎/godot/bin/godot.linuxbsd.editor.x86_64.mars
O="$M/产出/Godot/补丁验收"; mkdir -p "$O"
R=2560x1440
fps() { grep -E "^== |测帧 (地面|绕车|高空|远足)|慢帧" ; }
echo "### 1 等价：官方 vs 自编（补丁全关），交替两轮"
for k in 1 2; do
  GODOT=$OFF bash "$HD/测帧.sh" $R "官方$k:" | fps
  GODOT=$MARS bash "$HD/测帧.sh" $R "自编$k:" | fps
done
echo "### 2 0001 接触阴影：开销"
bash "$HD/补丁测试.sh" "lights_and_shadows/contact_shadow/enabled=true" 测帧.sh $R "接触阴影:" | fps
echo "### 3 0002 远级联缓存：间隔 2、4"
for n in 2 4; do bash "$HD/补丁测试.sh" "lights_and_shadows/directional_shadow/far_cascade_update_interval=$n" 测帧.sh $R "远级联$n:" | fps; done
echo "### 4 0004 法线预通道简化"
GODOT=$MARS bash "$HD/测帧.sh" $R "预通道简化:--预通道简化=1" | fps
echo "### 5 出图：自编（全关）、接触阴影、接触阴影+补光、预通道简化、多次反弹AO"
GODOT=$MARS bash "$HD/渲染.sh" "$O/自编" 13:07 2 > /dev/null 2>&1
GODOT=$MARS bash "$HD/渲染.sh" "$O/自编b" 13:07 2 > /dev/null 2>&1
bash "$HD/补丁测试.sh" "lights_and_shadows/contact_shadow/enabled=true" 渲染.sh "$O/接触阴影" 13:07 2 > /dev/null 2>&1
bash "$HD/补丁测试.sh" "lights_and_shadows/contact_shadow/enabled=true" 渲染.sh "$O/接触阴影_补光" 13:07 2 --补光=0.05 > /dev/null 2>&1
GODOT=$MARS bash "$HD/渲染.sh" "$O/自编_补光" 13:07 2 --补光=0.05 > /dev/null 2>&1
GODOT=$MARS bash "$HD/渲染.sh" "$O/预通道简化" 13:07 2 --预通道简化=1 > /dev/null 2>&1
bash "$HD/补丁测试.sh" "lights_and_shadows/multi_bounce_occlusion/enabled=true" 渲染.sh "$O/多次反弹AO" 13:07 2 > /dev/null 2>&1
for d in 自编 自编b 接触阴影 接触阴影_补光 自编_补光 预通道简化 多次反弹AO; do echo "$d: $(ls "$O/$d"/*.png 2>/dev/null | wc -l) 张；$(grep -ciE 'error' "$O/$d/godot.log" 2>/dev/null) 个 error"; done
echo "### 完"
