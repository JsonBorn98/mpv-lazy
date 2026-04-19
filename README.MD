# JsonBorn98 的个人 mpv 自动部署仓库

这个仓库不是上游 `mpv-lazy` 的完整运行时镜像，而是我自己的 `mpv` 配置、模型资源和部署脚本仓库。

它的目标很直接：

- 用 `scoop` 管理 `mpv` / `mpv-lazy` 本体更新
- 用这个仓库同步我的个人 `portable_config`
- 保留我实际会用到的 `vs-plugins/models`
- 避免把 `_cache`、`saved-props.json`、`.engine`、`.engine.cache` 这类运行时产物带进部署资产

## 这个仓库包含什么

- `portable_config/`
  个人配置层，已经纳入版本管理
- `vs-plugins/models/`
  模型资源层，保留模型本体，排除运行时编译缓存
- `bootstrap.ps1`
  新电脑或新运行目录的入口脚本
- `deploy.ps1`
  日常更新、清缓存、回滚入口
- `deploy/manifest.json`
  部署清单，记录默认基础包、附加包和分层同步规则

## 推荐用法

如果本机已经用 `scoop` 安装好了 `mpv`，直接运行：

```powershell
.\bootstrap.ps1 -ScoopApp mpv
```

默认会从这个仓库拉最新配置：

- `https://github.com/JsonBorn98/mpv-lazy.git`

如果我已经手动下载了 `vsNV` 附加包，也可以一起叠加：

```powershell
.\bootstrap.ps1 `
  -ScoopApp mpv `
  -AddonArchive C:\Downloads\mpv-lazy-vsNV.7z
```

## 日常维护

- 首次部署、Scoop 工作流、附加包、缓存清理、回滚
  见 [DEPLOY.md](DEPLOY.md)
- 想看原本上游风格的说明文案
  见 [README.upstream.MD](README.upstream.MD)

## 与上游的关系

这个仓库基于这些上游内容做个人化维护：

- [hooke007/mpv_PlayKit](https://github.com/hooke007/mpv_PlayKit)
- [mpv-player/mpv](https://github.com/mpv-player/mpv)

这里的重点不是继续整理一份通用懒人包说明，而是把“我自己的配置如何稳定迁移到另一台 Windows 电脑”这件事做顺。
