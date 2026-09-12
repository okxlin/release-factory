# gemini-skill-browser-linuxserver-builder

这个目录与 `1panel-builder/`、`gemini-skill-browser-builder/` 平级，承载基于 `linuxserver/chrome` 的 Gemini Skill Browser 镜像构建内容。

## 目录说明

- `configs/architectures.sh`：维护当前允许发布的平台
- `scripts/resolve-build-params.sh`：把 workflow 输入收敛成最终镜像 tag、base tag 和 build args
- `image/`：运行文件；Docker 构建上下文为仓库根目录
  - `Dockerfile`
  - `usr/bin/wrapped-chrome`：覆盖上游 wrapper，注入 CDP 远程调试参数

## 当前策略

- 当前只发布 `linux/amd64`
- 默认镜像仓库名：`ghcr.io/<owner>/gemini-skill-browser`
- workflow 支持手动构建、每周刷新和按路径触发的 PR 验证
- 底座 tag 默认来自 `linuxserver/docker-chrome` 的最新稳定 release；解析失败会停止构建
- 发布 tag 为 `<底座 tag>-linuxserver`；周更新维护 `latest-linuxserver`，手动构建可选择是否更新该别名
- 与 Kasm 共用 `gemini-skill-browser-builder/configs/components.json` 及受控 npm 锁文件；Node 24、底座 digest 和应用提交在构建前固定
- daemon 等待桌面 Chrome 的 CDP 端口就绪，避免同时启动两个浏览器争用 profile
- Debian Nginx 尚未提供当前漏洞修复时，使用校验和固定的 nginx.org 包，并构建匹配版本的 fancyindex 模块；保留桌面文件浏览功能

本地构建参照 [Kasm 说明](../gemini-skill-browser-builder/README.md)，将解析器的 `--variant`、
Dockerfile 路径和 smoke 变体改为 `linuxserver`。构建上下文仍为仓库根目录。

## PR reviewer 该看什么

- `build-gemini-skill-browser-linuxserver.yml` 与 `release-gemini-browser.yml`：固定输入、PR 门禁、发布摘要绑定
- `image/Dockerfile`：底座是否固定为 `linuxserver/chrome`
- `image/usr/bin/wrapped-chrome`：Chrome 进程是否真正带上 remote debugging 参数
