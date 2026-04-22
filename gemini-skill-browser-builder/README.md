# gemini-skill-browser-builder

这个目录按 `okxlin/release-factory` 的真实仓库布局放置：

- 与 `1panel-builder/` 平级
- 只承载 `gemini-skill-browser` 的 kasm 版镜像构建发布内容
- GitHub Actions workflow 仍放在仓库根下的 `.github/workflows/`

## 目录说明

- `configs/architectures.sh`：维护当前允许发布的平台
- `scripts/resolve-build-params.sh`：把 workflow 输入收敛成最终镜像 tag、base tag 和 build args
- `image/`：独立镜像构建上下文
  - `Dockerfile`
  - `.env.example`
  - `scripts/`
  - `supervisor/`

## 当前策略

- 当前只发布 `linux/amd64`
- 默认镜像仓库名：`ghcr.io/<owner>/gemini-skill-browser`
- workflow 只保留手动触发
- 构建时手动输入浏览器底座 tag
- 发布镜像 tag 默认跟随浏览器底座 tag 并追加 `-kasm`；仅在显式要求时才附带 `latest-kasm` 别名

## PR reviewer 该看什么

- `build-gemini-skill-browser.yml`：是否只保留手动触发、tag 规则是否干净
- `image/Dockerfile`：底座是否固定为 `kasmweb/edge`
- `image/scripts/bootstrap.sh` + `image/supervisor/gemini-skill.conf`：是否确保 Kasm 与 daemon 共存启动
