#!/bin/bash
# bench.sh <输出名> <场景列表> "名:参数 参数" ...   GPU 锁 + 用户在玩时等待；OVR="键=值;…" 时经 补丁测试.sh 覆盖项目设置
# GODOT 默认共享自编引擎（只读使用）
OUT=$1; SC=$2; shift 2
WT="$HOME/Documents/mars-work/地图_引擎"
G=${GODOT:-/home/user/引擎/godot/bin/godot.linuxbsd.editor.x86_64.mars}
: > ~/engvt/bench/$OUT.txt
for c in "$@"; do
  while [ -e ~/.mars_用户在玩 ]; do sleep 30; done
  ( while :; do o=$(pgrep -af "godot" | grep -v "地图_引擎" | grep "display-driver\|--path" | cut -c1-160); [ -n "$o" ] && echo "干扰 $(date +%T) $o"; sleep 2; done ) > /tmp/engvt_干扰 2>&1 &
  SP=$!
  if [ -n "${OVR:-}" ]; then
    flock /tmp/mars_gpu.lock env GODOT=$G bash "$WT/godot/补丁测试.sh" "$OVR" 测帧.sh 2560x1440 "${c} --场景=${SC}" >> ~/engvt/bench/$OUT.txt 2>&1
  else
    flock /tmp/mars_gpu.lock env GODOT=$G "$WT/godot/测帧.sh" 2560x1440 "${c} --场景=${SC}" >> ~/engvt/bench/$OUT.txt 2>&1
  fi
  kill $SP 2>/dev/null
  [ -s /tmp/engvt_干扰 ] && echo "ERROR 干扰：$(head -1 /tmp/engvt_干扰) … 共 $(wc -l < /tmp/engvt_干扰) 次" >> ~/engvt/bench/$OUT.txt
done
echo 全部完成 >> ~/engvt/bench/$OUT.txt
