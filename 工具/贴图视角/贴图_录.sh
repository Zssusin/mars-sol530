#!/bin/bash
# 贴图_录.sh <标签> <工作树(无空格)> <升|俯仰> <E,N> [额外 godot 参数…]：实时画面逐帧存 PNG → ~/贴图/seq/<标签>/<路径>/，再拼成 mp4
# 升：正下方，1.6 m → 40 m 指数升；俯仰：离点 8 m 的球面上仰角 5° → 89.5°，始终看着那个点。1280×720，视场 60°，360 帧（6 s）。
TAG=$1; WT=$2; SC=$3; PT=$4; shift 4
OUT=$HOME/贴图/seq/$TAG/$SC
rm -rf "$OUT"; mkdir -p "$OUT"
WT=$WT TMO=${TMO:-500} $HOME/颗粒/rt.sh 1280x720 $HOME/贴图/log/seq_${TAG}_$SC.log --实时录="$OUT" --录路径=$SC --录点=$PT --录帧=${FR:-360} --石块=0 "$@"
n=$(ls "$OUT"/*.png 2>/dev/null | wc -l); echo "frames $n"
