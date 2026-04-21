# AGENTS.md

> 本文件面向 AI 编程助手。阅读者被假设对该项目一无所知。
> 项目内主要文档、配置注释和脚本注释均使用中文，因此本文件以中文撰写。

---

## 项目概览

这是一个 **Windows 平台下的个人 mpv 便携包自动部署仓库**（`JsonBorn98/mpv-lazy`），不是常规意义上的源码仓库。

- **核心目标**：把“作者自己的 mpv 配置、VapourSynth 模型资源和部署脚本”稳定迁移到任意一台 Windows 电脑。
- **上游基础**：基于 `hooke007/mpv_PlayKit` 和 `mpv-player/mpv` 的预构建二进制发行版。
- **工作模式**：用 `scoop` 管理 mpv 本体更新，用本仓库同步个人配置层与模型层，通过 PowerShell 脚本完成分层叠加、缓存清理与回滚。

仓库根目录包含大量预构建二进制和运行时（`mpv.exe`、`python.exe`、`VSPipe.exe`、`Lib/`、`vs-plugins/` 等），这些属于**Vendor 资产**，不应随意修改。真正可编辑的表层是 `portable_config/` 以及 `deploy/manifest.json`。

---

## 技术栈与运行时架构

| 层级 | 技术/组件 | 说明 |
|------|-----------|------|
| 播放器核心 | mpv (C) | `mpv.exe` + `mpv.com`（控制台封装）+ `umpv.exe`（单实例启动器） |
| 脚本扩展 | Lua | mpv 内置 Lua 引擎，自动加载 `portable_config/scripts/*.lua` |
| UI 套件 | uosc (Lua) |  vendored  minimalist UI，替换原生 OSC，位于 `scripts/uosc/` |
| 缩略图引擎 | thumbfast (Lua) | vendored 缩略图后台进程，位于 `scripts/thumbfast.lua` |
| 视频处理管线 | VapourSynth (C++/Python) | 通过 `vf vapoursynth` 将 Python `.vpy` 脚本接入 mpv |
| 嵌入式 Python | CPython 3.14 | `python.exe` + `python314._pth` 实现完全隔离的便携环境 |
| Python 包 | NumPy, ONNX, protobuf, ml_dtypes, vapoursynth, k7sfunc | 服务于 GPU 推理补帧/超分/降噪 |
| GPU 推理后端 | CUDA / TensorRT / DirectML | `vs-plugins/vsmlrt-cuda/` 与 `vs-plugins/vsort/` 下的运行时 DLL |
| 部署工具 | PowerShell 5.1+ | `bootstrap.ps1`、`deploy.ps1`、`deploy/DeploySupport.ps1` |
| 系统集成 | Windows Batch | `installer/` 下的 `.bat` 脚本，负责注册表/文件关联/右键菜单 |
| 着色器 | GLSL | `portable_config/shaders/` 下约 400+ 个计算着色器 |

**分层运行时架构**：

1. **基础运行时层**：上游预构建包（mpv、Python、VapourSynth、插件 DLL）。
2. **个人配置层**：`portable_config/`（不含 `_cache/`、`saved-props.json`）。
3. **模型资源层**：`vs-plugins/models/`（不含 `.engine` / `.engine.cache`）。
4. **运行时缓存层**：目标机本地产物，不纳入 Git，也不随部署同步。

---

## 目录结构与代码组织

```
├── bootstrap.ps1                 # 首次部署 / 新电脑入口
├── deploy.ps1                    # 日常更新、清缓存、回滚、状态查看
├── deploy/
│   ├── DeploySupport.ps1         # 部署公共函数（路径、压缩、备份、状态）
│   └── manifest.json             # 部署清单：包版本、附加包、同步规则、缓存排除、备份策略
├── installer/                    # 系统集成与测试沙盒脚本
│   ├── mpv-register.bat / mpv-unregister.bat
│   ├── umpv-install.bat / umpv-uninstall.bat
│   ├── mpv-测试模式.bat / mpv-纯净模式.bat / mpv-跑分模式.bat / mpv-输入模式.bat
│   ├── mpv-test.conf / mpv-BenchMark.conf
│   └── mpv-icon.ico
├── portable_config/              # 【主要可编辑区】mpv 配置与脚本
│   ├── mpv.conf                  # 根配置（引用 profiles.conf、script-opts.conf、input_uosc.conf）
│   ├── profiles.conf             # 条件自动配置（profile-cond）
│   ├── script-opts.conf          # 各脚本参数覆盖
│   ├── input_uosc.conf           # 主键位绑定 + uosc 菜单项（#! 语法）
│   ├── input_contextmenu_plus.conf  # 右键菜单骨架（#@ 动态关键字）
│   ├── saved-props.json          # 持久化全局状态（volume、mute）
│   ├── scripts/
│   │   ├── uosc/                 # vendored UI 套件（≈ 勿改源码，优先改 script-opts.conf）
│   │   ├── thumbfast.lua         # vendored 缩略图引擎
│   │   ├── contextmenu_plus.lua  # 第三方派生右键菜单构建器
│   │   ├── input_plus.lua        # 自定义高级指令（音频设备轮询、OP/ED 跳过、文件对话框等）
│   │   └── save_global_props.lua # 持久化指定属性到 saved-props.json
│   ├── shaders/                  # GLSL 着色器库（400+ 文件，分类存放）
│   ├── vs/                       # VapourSynth 滤镜预设（.vpy）
│   ├── fonts/                    # 界面字体（LXGWWenKai、MaterialIcons、uosc 纹理字体）
│   └── _cache/                   # 运行时缓存（ICC、shader、字幕、watch_later）
├── vs-plugins/                   # VapourSynth 插件 DLL 与模型
│   ├── models/                   # ONNX 模型（RIFE、ArtCNN、RealESRGAN 等）
│   ├── vsmlrt-cuda/              # CUDA / TensorRT 运行时
│   ├── vsort/                    # DirectML / ONNXRuntime
│   └── *.dll                     # 30+ 个 VS 插件（fmtconv、bm3d、EEDI3、NNEDI3 等）
├── vs-coreplugins/               # VS 核心插件（AvsCompat.dll）
├── vs-scripts/                   # 用户 VS 脚本占位目录（当前仅有 .keep）
├── vsgenstubs4/                  # 生成 VapourSynth 类型存根的小工具
├── python314._pth                # 便携 Python 路径配置
├── portable.vs                   # VapourSynth 便携模式标记文件（空文件）
└── [顶层二进制]                   # mpv.exe、python.exe、7z.exe、yt-dlp.exe 等
```

---

## 部署与日常维护命令

### 首次部署（推荐）

假设本机已通过 `scoop` 安装 mpv：

```powershell
.\bootstrap.ps1 -ScoopApp mpv
```

默认从 `https://github.com/JsonBorn98/mpv-lazy.git` 拉取最新配置。也可叠加手动下载的 `vsNV` 附加包：

```powershell
.\bootstrap.ps1 -ScoopApp mpv -AddonArchive C:\Downloads\mpv-lazy-vsNV.7z
```

### 基础包模式（无 scoop 时）

```powershell
.\bootstrap.ps1 `
  -TargetDir D:\Apps\mpv-lazy-personal `
  -BaseArchive C:\Temp\mpv-lazy.7z
```

### 日常更新

```powershell
.\deploy.ps1 -Action Update -TargetDir C:\Path\To\Mpv
```

支持叠加额外目录：

```powershell
.\deploy.ps1 -Action Update -TargetDir C:\Path\To\Mpv -OverlayDirectories C:\Temp\mpv-lazy-vsNV
```

### 清缓存

```powershell
.\deploy.ps1 -Action ClearCache -TargetDir C:\Path\To\Mpv
```

清理范围：`portable_config/_cache`、`saved-props.json`、`vs-plugins/models/**/*.engine`、`vs-plugins/models/**/*.engine.cache`。

### 回滚

```powershell
.\deploy.ps1 -Action Status -TargetDir C:\Path\To\Mpv    # 查看状态与备份列表
.\deploy.ps1 -Action Rollback -TargetDir C:\Path\To\Mpv   # 回滚到最近备份
```

默认保留最近 **2 份**备份，可在 `deploy/manifest.json` 的 `backupPolicy.retain` 修改。

### 修改清单而非改脚本

若后续拿到更稳定的 upstream 下载直链，优先只改 `deploy/manifest.json`：
1. 给对应 `downloadUrl` 填入直链。
2. 给对应 `sha256` 填入实际值。
3. 保持 `archiveType` 正确（`zip` 或 `7z`）。

---

## 测试与验证策略

本项目**没有传统单元测试**。验证依赖 mpv 自带的配置沙盒与几个批处理辅助脚本：

| 脚本 | 用途 |
|------|------|
| `installer\mpv-测试模式.bat` | 隔离测试单条配置：`mpv.com --config=no --include=installer/mpv-test.conf` |
| `installer\mpv-纯净模式.bat` | 近似上游原生行为，验证是否为配置层引入的问题 |
| `installer\mpv-输入模式.bat` | 开启 `--input-test=yes`，检查键位绑定与原始输入事件 |
| `installer\mpv-跑分模式.bat` | 渲染性能基准测试，带锁定的 benchmark 配置与可切换的 scaler profile |

**CLI 快速检查**：始终使用仓库根目录的 `mpv.com`，而不是全局安装的 `mpv`。

---

## 开发规范与代码风格

### 换行符与编码

- **文本文件**（`.conf`、`.lua`、`.vpy`、`.md`、`.txt`、`.json`、`.glsl`、`.hook`、`.ps1`）：**UTF-8 + LF**。`README.MD` 明确说明：若 mpv 读取到非 UTF-8/LF 文件可能解析失败。
- **批处理文件**（`.bat`）：**CRLF**（`chcp 936`，GBK 控制台输出）。
- **二进制文件**（`.dll`、`.exe`、`.pyd`、`.zip`、`.ico`、`.ttf`、`.otf`、`.pdf`）：按 binary 处理。

相关规则已写入 `.gitattributes`，请保持。

### 编辑边界（Vendor Boundaries）

- **`portable_config/scripts/uosc/`** 视为 vendored `uosc` 代码；优先在 `script-opts.conf` 中改配置，而非直接改源码。
- **`portable_config/scripts/thumbfast.lua`** 视为 vendored `thumbfast`；同上。
- **`portable_config/scripts/contextmenu_plus.lua`** 为第三方派生（源自 `tsl0922/mpv-menu-plugin`）；优先改 `input_contextmenu_plus.conf`，必须改脚本时才动 `.lua`。
- 若必须编辑 vendor 派生文件，**保留文件头中的上游来源/提交标记**。

### 可编辑区域优先级

| 目标 | 应编辑的文件 |
|------|-------------|
| 键位与菜单触发动作 | `portable_config/input_uosc.conf` |
| 右键菜单结构 | `portable_config/input_contextmenu_plus.conf` |
| 脚本参数（uosc、thumbfast、contextmenu_plus、save_global_props、console/stats） | `portable_config/script-opts.conf` |
| 全局播放/渲染默认值 | `portable_config/mpv.conf` |
| 条件行为（HDR、deband、save-position 覆盖等） | `portable_config/profiles.conf` |
| 自定义高级 Lua 指令 | `portable_config/scripts/input_plus.lua` |
| 持久化属性逻辑 | `portable_config/scripts/save_global_props.lua` |

---

## 核心配置 wiring

```
mpv.conf (根配置)
    ├── include → profiles.conf        (条件自动配置)
    ├── include → script-opts.conf     (脚本参数覆盖)
    ├── input-conf → input_uosc.conf   (所有键位 + #! 菜单项)
    │
    ├── glsl-shaders-append → ~~/shaders/...   (默认着色器栈)
    │
    ├── script-opts.conf 指向 contextmenu_plus
    │   读取 input_contextmenu_plus.conf (右键菜单骨架)
    │
    └── 自动加载脚本：
         ├── uosc/main.lua             (主 UI：时间轴、控制栏、菜单)
         │      └── 集成 thumbfast.lua (时间轴缩略图)
         ├── thumbfast.lua             (后台缩略图提取进程)
         ├── contextmenu_plus.lua      (右键菜单构建器)
         ├── input_plus.lua            (自定义高级命令)
         └── save_global_props.lua     (持久化 volume/mute)
```

- `mpv.conf` 设置了 `osc = no` 与 `input-builtin-bindings = no`，因此**所有默认行为完全依赖上述自定义文件**。
- `mpv.conf` 还设置了 `use-filedir-conf = yes`：媒体所在文件夹的外部配置文件可能影响播放行为与测试结果。
- `input_contextmenu_plus.conf` **不会被 mpv.conf 直接加载**；它由 `script-opts.conf` 通过 `contextmenu_plus-input_conf=~~/input_contextmenu_plus.conf` 传递给 `contextmenu_plus.lua`。其中的 `#@` 动态关键字（`#@tracks`、`#@playlist`、`#@chapters` 等）由脚本解析，不是普通键位绑定。

---

## 便携运行时细节

- **`python314._pth`**：隔离 bundled Python，显式加入 `vs-scripts` 目录。修改 Python/VapourSynth 环境时必须考虑此便携路径设定。
- **`portable.vs`**：空标记文件，告诉 VapourSynth 工具链以便携模式运行（从本地 `vs-plugins/` / `vs-coreplugins/` 加载，而非系统路径）。
- Python `sys.path` 实际包含：`python314.zip`（冻结标准库）→ 仓库根目录 `.` → `vs-scripts/` → `Lib/site-packages/`（通过 `import site`）。

---

## 已知陷阱 (Gotchas)

- **配置不生效？检查 `saved-props.json`**：`mpv.conf` 的当前预设由 `save_global_props.lua` 持久化 `volume` 和 `glsl-shaders`。若修改了相关配置后行为未变，尝试删除 `portable_config/saved-props.json`。
- **installer 配置里 `~~/` 不生效**：`installer/mpv-test.conf` 与 `installer/mpv-BenchMark.conf` 明确说明该模式下 `~~/` 相对路径不受支持，需要时使用绝对路径。
- **部署脚本的安全锁**：`deploy.ps1` 会**拒绝**把仓库根目录或其子目录当作目标运行目录，防止误覆盖源仓库自身。
- **附加包 `vsNV` 未写死直链**：`manifest.json` 中 `playkit-20260210-vsnv` 的 `downloadUrl` 与 `sha256` 当前为空，无法直接通过 `-AddonIds` 自动下载，需手动提供归档或补齐直链。
- **系统级脚本需要管理员权限**：`installer/umpv-install.bat`、`installer/umpv-uninstall.bat` 修改注册表、文件关联和开始菜单；非 shell 集成任务不要运行它们。

---

## 安全与权限注意事项

- **注册表/系统修改**：`installer/umpv-install.bat`、`installer/umpv-uninstall.bat`、`installer/mpv-register.bat`、`installer/mpv-unregister.bat` 会修改 Windows 注册表与文件关联。仅在明确需要 shell 集成时以管理员身份运行。
- **部署安全**：`bootstrap.ps1` / `deploy.ps1` 会从外部来源下载压缩包并解压到目标目录；使用 `-NoChecksum` 会跳过 SHA256 校验，仅在可信网络环境使用。
- **备份机制**：每次 `Update` 操作会自动将旧目标目录完整备份到 `<TargetDir>._backups\<timestamp>`，降低更新导致不可恢复损坏的风险。

---

## 许可证说明

本项目包含**多许可证混合**内容。`LICENSE.MD` 指出大量文件原始来自上游，分别使用不同协议；未列出的文件默认视作 **UNLICENSED**。主要组件：

- **mpv / umpv**：上游 mpv Copyright
- **Python**：Python Software Foundation License（含多个历史条款）
- **VapourSynth**：LGPL
- **installer**：`rossy/mpv-install` 协议
- **scripts / shaders / vapoursynth64/plugins**：协议通常集成在文件内部，或参见对应维基页面

修改 vendor 派生文件时，应保留其原有许可证声明与上游来源标记。
