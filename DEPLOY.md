# DEPLOY

## 目标

这个仓库现在面向两类部署方式：

1. 推荐方式：`scoop` 负责安装或更新现成的 mpv / mpv-lazy 运行目录，本仓库负责同步个人配置、模型资源，以及按需叠加上游附加包。
2. 备用方式：用 `bootstrap.ps1` 直接从显式提供的基础包归档或已解压目录构建一个完整目标目录。

核心分层如下：

- 基础运行时层：由 `scoop` 安装的现有目录，或你显式提供的上游基础包。
- 个人配置层：当前仓库中的 `portable_config/`，但不包含 `_cache/` 和 `saved-props.json`。
- 模型资源层：当前仓库中的 `vs-plugins/models/`，但不包含 `.engine` / `.engine.cache`。
- 运行时缓存层：目标机本地产物，不纳入部署资产，也不会从仓库同步。

## 推荐工作流

如果你已经用 `scoop` 装好了运行时，最省心的方式是只做“就地增强”：

```powershell
.\bootstrap.ps1 -ScoopApp mpv
```

上面这条命令现在会默认从你的 GitHub 仓库拉最新配置：

- `https://github.com/JsonBorn98/mpv-lazy.git`

如果你希望显式写出来，也可以这样运行：

```powershell
.\bootstrap.ps1 `
  -ScoopApp mpv `
  -ConfigRepoUrl https://github.com/JsonBorn98/mpv-lazy.git
```

如果你的 `scoop` 包名不是 `mpv`，就把 `-ScoopApp` 换成你自己的包名。  
如果你更愿意传运行目录，也可以直接指定：

```powershell
.\bootstrap.ps1 -TargetDir C:\Users\<you>\scoop\apps\<app>\current
```

## `vsNV` 附加包

你补充的当前习惯是：

- `shader` 包通常从 GitHub 上游仓库拉取并复制。
- `vsNV` 补丁包在每次懒人包更新时发布在 upstream release 页面里。

当前仓库已经跟踪了 `portable_config/shaders`，所以只要你用这个仓库作为配置源，常规 shader 同步已经包含在部署流程里，不需要额外再拷一遍。

`vsNV` 则被视为可选附加包。当前清单已经记录了对应的 release 页和分流入口，但还没有写死某个直链归档，因此有两种用法：

1. 先手动下载 `vsNV` 归档，再交给脚本叠加：

```powershell
.\bootstrap.ps1 `
  -ScoopApp mpv `
  -ConfigRepoUrl https://github.com/JsonBorn98/mpv-lazy.git `
  -AddonArchive C:\Downloads\mpv-lazy-vsNV.7z
```

2. 你自己知道确切直链时，直接传 URL：

```powershell
.\bootstrap.ps1 `
  -ScoopApp mpv `
  -ConfigRepoUrl https://github.com/JsonBorn98/mpv-lazy.git `
  -AddonUrl https://example.invalid/mpv-lazy-vsNV.7z `
  -NoChecksum
```

后续如果你把 `deploy/manifest.json` 里的 `playkit-20260210-vsnv.downloadUrl` 和 `sha256` 补齐，脚本就能直接用：

```powershell
.\bootstrap.ps1 -ScoopApp mpv -AddonIds playkit-20260210-vsnv
```

## 基础包模式

如果你不想依赖现成的 `scoop` 运行目录，也可以显式指定基础包来源：

```powershell
.\bootstrap.ps1 `
  -TargetDir D:\Apps\mpv-lazy-personal `
  -BaseArchive C:\Temp\mpv-lazy.7z
```

或者直接指向已经解压好的上游目录：

```powershell
.\bootstrap.ps1 `
  -TargetDir D:\Apps\mpv-lazy-personal `
  -BaseDirectory C:\Temp\mpv-lazy
```

这条路径仍然支持附加包叠加与配置同步。

如果你偶尔就是想强制使用当前本地工作树，而不是默认去 GitHub 拉最新配置，可以显式传空字符串：

```powershell
.\bootstrap.ps1 -ScoopApp mpv -ConfigRepoUrl ''
```

## 日常更新

当目标运行目录已经存在时，建议直接用 `deploy.ps1`：

```powershell
.\deploy.ps1 -Action Update -TargetDir C:\Path\To\Mpv
```

如果配置源不是当前仓库，而是某个单独 checkout：

```powershell
.\deploy.ps1 `
  -Action Update `
  -TargetDir C:\Path\To\Mpv `
  -SourceRoot C:\Path\To\ConfigCheckout
```

如果要在更新时一起叠加已解压的附加包：

```powershell
.\deploy.ps1 `
  -Action Update `
  -TargetDir C:\Path\To\Mpv `
  -OverlayDirectories C:\Temp\mpv-lazy-vsNV
```

## 清缓存

只清理运行时缓存，不动模型和配置本体：

```powershell
.\deploy.ps1 -Action ClearCache -TargetDir C:\Path\To\Mpv
```

会清理这些路径：

- `portable_config/_cache`
- `portable_config/saved-props.json`
- `vs-plugins/models/**/*.engine`
- `vs-plugins/models/**/*.engine.cache`

## 回滚

每次成功切换前，脚本都会把旧目标目录整体备份到：

```text
<TargetDir>._backups\<timestamp>
```

查看状态和备份列表：

```powershell
.\deploy.ps1 -Action Status -TargetDir C:\Path\To\Mpv
```

回滚到最近一次备份：

```powershell
.\deploy.ps1 -Action Rollback -TargetDir C:\Path\To\Mpv
```

回滚到指定备份：

```powershell
.\deploy.ps1 `
  -Action Rollback `
  -TargetDir C:\Path\To\Mpv `
  -BackupId 20260420-153000
```

默认只保留最近 2 份完整备份，可在 `deploy/manifest.json` 里改 `backupPolicy.retain`。

## manifest 说明

`deploy/manifest.json` 现在承担三类信息：

- `packages`
  记录整包基础运行时版本。
- `addons`
  记录可选附加包，比如 `vsNV`。
- `sourceLayers` / `cacheRules`
  记录个人配置层、模型层和缓存排除规则。

如果你后续拿到了更稳定的 upstream 下载直链，建议只改 manifest，不改脚本：

1. 给对应的 `downloadUrl` 填入直链。
2. 给对应的 `sha256` 填入实际值。
3. 保持 `archiveType` 正确，例如 `zip` 或 `7z`。

## 已知限制

- 当前 manifest 里已经锁定了 release 版本、release 页面和 OneDrive 分流链接，但没有写死 `vsNV` 的可直下归档 URL，所以 `-AddonIds playkit-20260210-vsnv` 还需要你先补齐直链或改用 `-AddonArchive`。
- `deploy.ps1` 会拒绝把仓库根目录或仓库子目录当成目标运行目录，避免误把源仓库自己覆盖掉。
- 如果你选择 `noVS` 基础包，但又同步了本仓库里的 VS 脚本与模型，功能是否能跑起来取决于你有没有额外补齐对应的 VS 运行时内容。
- 当前方案不接管系统级注册、右键菜单、PATH 配置；这部分继续沿用 `installer/` 里的脚本，按需手动执行。
