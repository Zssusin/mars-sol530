# 自编引擎

基于 Godot `4.7.2-stable`（提交 `ed1daf0bf001b61586d9930840f2f1394092c079`），在上面加 `patches/` 里的 4 个补丁：

| 补丁 | 内容 |
|---|---|
| 0001 接触阴影 | 移植 #118045：方向光屏幕空间接触阴影（4.8）→ 4.7.2 |
| 0002 远级联缓存 | 方向光远处级联隔帧渲染、其余帧复用（Forward+） |
| 0003 多次反弹 AO | 移植 #115426：多次反弹 AO（4.8，按反照率逐通道）→ 4.7.2 |
| 0004 深度预通道常量 | 空间着色器新增内建常量 IN_DEPTH_PREPASS、IN_NORMAL_PREPASS（Forward+） |

详细说明见 `docs/补丁与功能清单.md`、`docs/自编引擎计划.md`。

## 版本

- 引擎版本记为 `4.7.2-mars.N`：补丁队列每变一次，N 加 1；上游升级时改前缀，N 从 1 重新数。
- 确切的上游提交、分支提交和产物写在 `ENGINE_REF`。
- 游戏启动日志、F1、F3 都会显示版本串，读的是 `godot/环境.gd`。

## 构建（Linux，fedora）

引擎仓库在 fedora 的 `~/引擎/godot`，分支 `mars-4.7`。scons 用 `~/.local/venvs/scons/bin/scons`。

渲染机平时有别的任务占着 CPU，所以：
- 编译一律加 `nice -n 19`，用 `-j6`；
- 用 `systemd-run --user` 限制内存。LTO 链接时大约要 7 GB 内存。

```sh
git clone https://github.com/godotengine/godot.git && cd godot
git checkout -b mars-4.7 4.7.2-stable
git am ../mars-realtime-drive/engine/patches/*.patch
S=~/.local/venvs/scons/bin/scons
# 编辑器（开发用，带调试符号）
systemd-run --user --scope -p MemoryMax=16G nice -n 19 $S platform=linuxbsd target=editor production=yes debug_symbols=yes separate_debug_symbols=yes extra_suffix=mars -j6
# 导出模板（release；production=yes 即静态 libstdc++、LTO、不带符号），fedora 上 -j6 约 10 分钟
systemd-run --user --scope -p MemoryMax=16G nice -n 19 $S platform=linuxbsd target=template_release arch=x86_64 production=yes extra_suffix=mars -j6
```

产物：
- `bin/godot.linuxbsd.editor.x86_64.mars`，约 146 MB；
- `bin/godot.linuxbsd.template_release.x86_64.mars`，约 77 MB。

两者必须从同一个提交编出来，否则补丁加的项目设置、着色器常量在导出版里不存在。编完以后：
- 更新 `ENGINE_REF` 里的「提交」「编辑器」「模板」三行；
- 跑 `scripts/检查.sh 全` 和 `工具/导出.sh --冒烟`。

**模板不装进** `~/.local/share/godot/export_templates/`。它的路径写死在 `godot/export_presets.cfg` 的 `custom_template/release` 里，和官方模板不会混用。现在只编了 release 模板，没有 debug 模板，所以导出只用 `--export-release`。

## C++ 扩展（仿真核心）

导出版用 `template_release` 版的扩展。导出器会按 `mars_sim.gdextension` 里的 `linux.release.x86_64` 条目，把它复制到可执行文件旁边。

```sh
cd godot/扩展/仿真核心/gdextension
nice -n 19 $S platform=linux target=template_debug   api_version=4.7 use_static_cpp=no -j6   # 编辑器里用
nice -n 19 $S platform=linux target=template_release api_version=4.7 use_static_cpp=no -j6   # 导出用
```

`use_static_cpp=no` 只适合在 fedora 本机跑。要拿到别的发行版上跑，改成 `use_static_cpp=yes`，并在旧 glibc 的环境里编（调研 §1.3）。

## 导出

```sh
工具/导出.sh            # → 产出/导出/mars-realtime-drive-<版本>-linux/
工具/导出.sh --冒烟     # 另外：编辑器版和导出版各量一次启动耗时，再各渲染一次同机位，逐像素比较，并跑照片回归
```

包里的布局、数据怎么读，见 `docs/工程化方案.md` §9。

## 更新补丁

在引擎仓库里提交以后运行：

```sh
git format-patch 4.7.2-stable..HEAD -o <本仓库>/engine/patches/
```

然后把 `ENGINE_REF` 的版本号加 1。
