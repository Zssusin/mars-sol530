# 第三方组件、数据与许可

开发者用的清单，格式参照 `docs/工程化调研_外部.md` §6.5。导出包会附带这份文件，以及 Godot 和 godot-cpp 的许可全文。

以下是对官方条款的整理，不是法律意见。开源前清单和每一项的状态见 `docs/工程化方案.md` §7。

本项目是独立作品，与 NASA、JPL、加州理工学院、亚利桑那大学、Malin Space Science Systems、USGS 均无隶属关系，也没有得到它们的认可或赞助。使用 NASA/JPL 影像不代表 NASA 背书。

## 1. 引擎和代码

| 名称 | 版本 / 提交 | 来源 | 许可 | 在哪里 | 改过吗 |
|---|---|---|---|---|---|
| Godot Engine | 4.7.2-stable（`ed1daf0`），加本项目 4 个补丁，记为 `4.7.2-mars.1`（`5d7782b`） | https://github.com/godotengine/godot | MIT。引擎内含的第三方库（FreeType、HarfBuzz、ICU、mbedTLS、libpng、libjpeg-turbo、zstd、Jolt、meshoptimizer 等）各有许可，全文见引擎的 `COPYRIGHT.txt` | 编辑器和导出模板在 fedora `~/引擎/godot`；导出包附带 `GODOT_LICENSE.txt` 和 `GODOT_COPYRIGHT.txt` | 改过，见 `engine/patches/`、`engine/ENGINE_REF` |
| 补丁 0001 接触阴影 | 移植自上游 PR #118045 | https://github.com/godotengine/godot/pull/118045 | MIT，© Godot Engine contributors（原作者见 PR） | `engine/patches/0001-*.patch` | 为 4.7.2 改写 |
| 补丁 0003 多次反弹 AO | 移植自上游 PR #115426 | https://github.com/godotengine/godot/pull/115426 | MIT，© Godot Engine contributors（原作者见 PR） | `engine/patches/0003-*.patch` | 为 4.7.2 改写 |
| godot-cpp | master `ed672dc`（2026-10-06） | https://github.com/godotengine/godot-cpp | MIT，© Godot Engine contributors | 子模块 `godot/扩展/仿真核心/gdextension/godot-cpp`；导出包附带 `GODOT_CPP_LICENSE.md` | 没改 |

本仓库自己的代码（GDScript、着色器、C++ 仿真核心、Python 管线、Shell 脚本）按 **MIT** 授权，见 `LICENSE`。文档和自制图片按 **CC BY 4.0** 授权，见 `docs/LICENSE.md`。

## 2. 字体

全部是 SIL Open Font License 1.1。许可全文和字体放在同一个目录（`godot/界面/素材/`，数据包里在 `data/界面/素材/`）。程序包的 PCK 里另有一份 Noto Sans SC 的子集（`godot/界面/缺数据/`，只含 ASCII 和 GB2312，缺数据提示页用，`工具/做缺数据字体.py` 生成），许可全文随程序包放在 `NotoSansSC_OFL.txt`。来源细节见 `godot/界面/素材来源.md`。

| 字体 | 文件 | 来源 | 版权与保留名 |
|---|---|---|---|
| Inter 4.1 | `Inter-Regular/Medium/SemiBold.ttf` | https://github.com/rsms/inter | © The Inter Project Authors；`Inter_LICENSE.txt` |
| IBM Plex Mono | `IBMPlexMono-Regular/Medium.ttf` | https://github.com/google/fonts/tree/main/ofl/ibmplexmono | © IBM Corp.，保留名 “Plex”；`IBMPlexMono_OFL.txt` |
| Noto Sans SC（可变字重） | `NotoSansSC-VF.ttf` | https://github.com/google/fonts/tree/main/ofl/notosanssc | © Adobe，保留名 “Source”；`NotoSansSC_OFL.txt` |

OFL 允许随软件嵌入和再分发，但不能单独出售字体文件。

## 3. 声音

全部取自 NASA 行星数据系统（PDS）的归档。美国政府作品，属于公有领域。产品号、处理方法见 `godot/声音/来源.md`。

| 素材 | 来源 | 署名（惯例） |
|---|---|---|
| `风_平静`、`风_湍流`、`尘卷风` | Mars 2020 SuperCam 麦克风标定产品，`urn:nasa:pds:mars2020_supercam`，sol 526 / 148 / 215 | Mars 2020 SuperCam 团队（LANL / CNES / IRAP 等），PDS Geosciences Node |
| `行驶` | Mars 2020 EDLCAM 麦克风，`urn:nasa:pds:m2020_edlcam_raw`，sol 16 | Mars 2020 EDLCAM 团队（JPL），PDS Cartography and Imaging Sciences Node |
| `热泵` | 自己合成，频率和幅度取自上面几段录音的实测值 | — |

## 4. 科学数据与模型

全部由管线脚本下载和加工，不进仓库。原始文件在 fedora 的 `DEM/`、`资料/`，加工结果在 `godot/数据/sol0530/`，清单见 `数据清单.json`。下载地址写在各脚本开头，主要是 `scripts/Blender/56_实景数据.py`。

| 数据 | 产品 / 来源 | 权利状态 | 署名 |
|---|---|---|---|
| HiRISE 1 m 高程、25 cm 正射（Jezero，Mars 2020 TRN 拼接） | USGS Astrogeology `mars2020_trn`：`JEZ_hirise_soc_006_DTM_…_1m`、`JEZ_hirise_soc_007_orthoMosaic_25cm`；另有 `ESP_084883_1985` 等 | 公有领域。HiRISE 使用政策写明“任何人使用都没有限制” | Image: NASA/JPL/University of Arizona |
| CTX 20 m 高程、5 m 正射（JPL 科研底图） | `M20_JezeroCrater_CTXDEM_20m`、`M20_JezeroCrater_CTXortho_mosaic_5m` | NASA 任务数据 | NASA/JPL-Caltech/MSSS |
| MOLA、HRSC-MOLA 全球高程 | USGS Astrogeology / PDS | 公有领域 | NASA/JPL/GSFC（MOLA）；ESA/DLR/FU Berlin（HRSC） |
| Navcam 立体网格、标定照片（site 26 / drive 1222，sol 502–533）；对照照片 `NRF_0M196RAS_`、`NRF_5M362RAS_` | PDS Imaging Node `mars2020_navcam_ops_mesh`、`mars2020_navcam_ops_calibrated` | NASA 任务数据 | NASA/JPL-Caltech |
| sol 502 到站全景 | NASA MMGIS `N_LRGB_0502_RAS_0261222_CYL_S_AUTOGENJ01` | NASA 任务数据 | NASA/JPL-Caltech |
| 地面样块（Mastcam-Z、WATSON、SuperCam RMI 等） | PDS，产品号见 `scripts/Godot/样块站点.json`、`docs/地面材质/` | NASA 任务数据 | NASA/JPL-Caltech/ASU/MSSS/LANL |
| 毅力号 3D 模型 | NASA 3D Resources `25042_Perseverance.glb` | 3D Resources 写明可以免费下载和使用；NASA 媒体指南说贴图和多边形数据在美国通常不受版权保护 | NASA/JPL-Caltech |
| 毅力号行驶路线（sol 0–530，全屏地图的路线线） | NASA MMGIS `M20_traverse.json`（原件 `资料/路线/`），经 `scripts/Godot/90_地图台数据.py` 按 R = 3396190 m 换到站点系，存 `godot/数据/sol0530/地图台路线.json` | NASA 任务数据 | NASA/JPL-Caltech MMGIS |

**NASA 媒体使用指南的约束**（2026-08-13 版）：
- 不得暗示 NASA 背书；
- 商业宣传里出现 NASA 标志另有要求；
- NASA 标志不得出现在 AI 生成的图像里。

## 5. 商标：NASA 和 JPL 标志

车模型的贴图上带有 NASA 徽标（meatball）、字标（worm）和 JPL 标志。

- 这些标志**不在公有领域**，受 14 CFR 1221 保护。用于模型、玩具一类的产品，需要 NASA 传播办公室事先批准。JPL 标志另需 JPL 书面批准。
- 自用构建和公开分发的构建都保留这些标志（2026-10-10 项目所有者决定，理由是保真）。没有取得 NASA 传播办公室和 JPL 的书面同意，这一点由项目所有者自行承担。
- 界面、标题、截图说明里一律不用这些标志。
- 去标志贴图的开关方案（没有做）和审批流程见方案 §7、调研 §6.2；以后要隐藏标志，按那里的方案做。
