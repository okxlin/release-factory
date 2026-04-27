# oh-my-opencode-builder

这个目录按 `okxlin/release-factory` 的目录习惯放置：

- 与 `1panel-builder/` 平级
- 只承载 `oh-my-opencode-runtime` 的镜像构建发布内容
- GitHub Actions workflow 放在仓库根下的 `.github/workflows/`

## 目录说明

- `configs/architectures.sh`：维护当前允许发布的平台
- `scripts/resolve-build-params.sh`：把 workflow 输入收敛成最终镜像 tag 与平台列表
- `image/`：独立镜像构建上下文
  - `Dockerfile`
  - `.env.example`
  - `scripts/`

## 当前策略

- 默认发布 `linux/amd64,linux/arm64`
- 默认镜像仓库名：`ghcr.io/<owner>/oh-my-opencode-runtime`
- workflow 只保留手动触发
- 默认 tag：`latest`
- 可选附带 `latest` 别名

## PR reviewer 该看什么

- `build-oh-my-opencode-runtime.yml`：是否只保留手动触发、tag 规则是否干净
- `image/Dockerfile`：是否仍然以独立镜像上下文承载运行时依赖
- `image/scripts/entrypoint.sh`、`image/scripts/bootstrap-opencode-userland.sh`、`image/scripts/install-oh-my-opencode.sh`：是否继续保证 `/data` 与 `/config` 上的持久化语义
