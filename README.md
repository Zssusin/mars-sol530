# mars-realtime-drive

在 Godot 里实时驾驶毅力号：杰泽罗陨石坑 sol 530 停车点，NASA 公开数据重建的实景地形。

非 NASA / JPL 官方产品。数据与影像：NASA/JPL-Caltech/ASU/MSSS/University of Arizona/USGS。

[English](README.en.md)

## 目录

| 路径 | 内容 |
|---|---|
| `godot/` | 游戏工程（GDScript、着色器、界面、天气、声音、控制） |
| `godot/扩展/仿真核心/` | C++ GDExtension（`core/` 纯 C++，`gdextension/` 绑定，`tests/` 单元测试）；`godot-cpp` 是子模块 |
| `godot/数据/sol0530/` | 场景数据。仓库里只有手写的 json 配置，其余（约 1.7 GB）由管线生成 |
| `scripts/Blender/` | 数据管线与离线参照：50–60（地表、近景、实景重建、Cycles 回归），`实景地形系统.md` 是系统总文档 |
| `scripts/Godot/` | Godot 数据导出 61、视频 65–66、车 AO 67、车细节 68 |
| `engine/` | 自编引擎：基于 4.7.2-stable 的补丁和构建说明，`ENGINE_REF` 记确切提交 |
| `工具/` | 工程脚本：构建信息、数据清单、导出（`docs/工程化方案.md`） |
| `scripts/检查.sh` | 一键检查：`托管`、`快`（推送前跑）、`全`（改了画面或性能时跑） |
| `docs/` | 试玩说明和文档许可。设计与调研文档没有放进公开仓库，代码注释里提到的其它 `docs/…` 文件不在这里 |

## 试玩

Releases 页有两样东西：按系统选一个**程序包**（Linux、Windows、macOS arm64，几百 MB），再加**数据包**（`mars-realtime-drive-data-<数据版本>-<n>of<N>.zip` 几卷，三个系统共用，每卷不到 2 GB，全部都要）。数据包解压到程序旁边的 `data/` 文件夹；缺数据或版本不对时，游戏会在屏幕上说明该去哪下、解压到哪。三个系统各自怎么装、按键和已知问题见 `docs/试玩说明.md`。从源码构建见下一节，需要自己编引擎并用管线生成约 1.7 GB 的场景数据。

## 许可

- 代码（GDScript、着色器、C++、Python、Shell）：MIT，见 `LICENSE`。
- 文档和本项目自己制作的图片：CC BY 4.0，见 `docs/LICENSE.md`。
- 引擎、字体、声音、NASA 数据和车模型的来源与权利状态：见 `THIRD_PARTY.md`。
- 车模型贴图上的 NASA 徽标、字标和 JPL 标志不在上述许可范围内，见 `THIRD_PARTY.md` §5。

## 从源码构建（Linux）

1. 按 `engine/README.md` 编自编引擎。
2. 编 C++ 扩展：
   ```sh
   git submodule update --init
   cd godot/扩展/仿真核心/gdextension
   scons platform=linux target=template_debug api_version=4.7 use_static_cpp=no -j12
   ```
3. 生成数据：见 `scripts/Blender/实景地形系统.md`（需要 `DEM/`、`资料/` 里的原始数据，不在仓库里）。
4. 运行：`godot --path godot`；按 F1 看按键。

## 版本

版本号在 `godot/project.godot` 的 `application/config/version`，游戏帮助页（F1）显示；变化记在 `CHANGELOG.md`，发布打 `vX.Y.Z` 标签。
