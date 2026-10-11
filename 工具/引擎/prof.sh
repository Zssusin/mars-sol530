#!/bin/bash
# prof.sh <输出名> <场景> "名:参数 …" …：--gpu-profile 分段计时，取每组最后一个完整的 GPU PROFILE 块
OUT=$1; SC=$2; shift 2
WT="$HOME/Documents/mars-work/地图_引擎"; HD="$WT/godot"
G=/home/user/引擎/godot/bin/godot.linuxbsd.editor.x86_64.mars
mkdir -p ~/engvt/prof; : > ~/engvt/prof/$OUT.txt
for cfg in "$@"; do
  while [ -e ~/.mars_用户在玩 ]; do sleep 30; done
  name=${cfg%%:*}; read -r -a A <<< "${cfg#*:}"
  flock /tmp/mars_gpu.lock bash -c '
    SOCK=marsp-$$; kwin_wayland --virtual --socket "$SOCK" --width 2560 --height 1440 --no-lockscreen >/dev/null 2>&1 & KP=$!
    for i in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/$SOCK" ] && break; sleep 0.1; done
    WAYLAND_DISPLAY=$SOCK DISPLAY= timeout -k 10 150 "$0" --gpu-profile --display-driver wayland --audio-driver Dummy --path "$1" --resolution 2560x1440 --position 0,0 -- --测帧 --场景="$2" "${@:3}" > /tmp/engvt_prof.log 2>&1
    kill $KP' "$G" "$HD" "$SC" "${A[@]}"
  echo "== $name ${A[*]}" >> ~/engvt/prof/$OUT.txt
  grep "测帧 $SC" /tmp/engvt_prof.log | sed "s/（.*GPU 平均/ GPU/; s/ 95%.*//" >> ~/engvt/prof/$OUT.txt
  python3 - >> ~/engvt/prof/$OUT.txt <<'P'
import re
L=open('/tmp/engvt_prof.log',errors='replace').read().split('\n')
blocks=[];cur=None
for l in L:
    if l.startswith('GPU PROFILE'): cur=[l]; blocks.append(cur)
    elif cur is not None and l.startswith('\t-'): cur.append(l)
    else: cur=None
b=blocks[-3] if len(blocks)>=3 else (blocks[-1] if blocks else ['无'])
items=sorted([(float(re.search(r': ([\d.e-]+)ms',x).group(1)),x.strip()) for x in b[1:]],reverse=True)
print(b[0]); [print('  ',x[1]) for x in items[:14]]
P
done
