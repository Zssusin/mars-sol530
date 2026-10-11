# 引擎 / 材质缓存测量脚本（engine-vt）

在 fedora 上用，路径写死为 `~/Documents/mars-work/地图_引擎`，结果写 `~/engvt/`。

- bench.sh：测帧（GPU 锁、用户在玩时等、干扰记录；OVR=键=值 覆盖项目设置）
- rend1.sh：渲染（同上；T= 时刻、SS= 超采样）
- prof.sh：--gpu-profile 分段
- cmp.py：两张图的对照卡（上排原图、左下差×k、右下局部放大）
- lp.py：有符号平均差、16 px 块差、高频细节标准差比

详见 docs/引擎/现代渲染优化调研.md。
