# gemini-skill-browser-linuxserver-builder

这个目录与 `1panel-builder/`、`gemini-skill-browser-builder/` 平级，承载基于 `linuxserver/chrome` 的 Gemini Skill Browser 镜像构建内容。

## 目录说明

- `configs/architectures.sh`：维护当前允许发布的平台
- `scripts/resolve-build-params.sh`：把 workflow 输入收敛成最终镜像 tag、base tag 和 build args
- `image/`：独立镜像构建上下文
  - `Dockerfile`
  - `usr/bin/wrapped-chrome`：覆盖上游 wrapper，注入 CDP 远程调试参数

## 当前策略

- 当前只发布 `linux/amd64`
- 默认镜像仓库名：`ghcr.io/<owner>/gemini-skill-browser`
- workflow 只保留手动触发
- 构建时手动输入浏览器底座 tag；留空时兜底回退到 `147.0.7727`
- 发布镜像 tag 默认跟随浏览器底座 tag 并追加 `-linuxserver`；仅在显式要求时才附带 `latest-linuxserver` 别名

## PR reviewer 该看什么

- `build-gemini-skill-browser-linuxserver.yml`：是否只保留手动触发、tag 规则是否干净
- `image/Dockerfile`：底座是否固定为 `linuxserver/chrome`
- `image/usr/bin/wrapped-chrome`：Chrome 进程是否真正带上 remote debugging 参数
