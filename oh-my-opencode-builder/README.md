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

## 运行时配置分层

推荐按三层使用，避免“手改一次，重启回滚一次”：

1. **部署级环境变量层**
   - 通过 `.env` / CI / 部署平台注入
   - 适合：`OPENCODE_MODEL`、`OPENCODE_SMALL_MODEL`、`OPENCODE_PROVIDER_ID`、`OPENCODE_EXTRA_PLUGINS`、以及各类 `*_BASE_URL` / `*_API_KEY`
2. **生成配置层**
   - `/config/opencode/opencode.json`
   - 由 `image/scripts/update_opencode_config.py` 在启动/安装阶段更新
   - 这是生成产物，不建议长期手工维护
3. **用户覆盖层**
   - `/config/opencode/opencode.user.json` 或 `/config/opencode/opencode.user.jsonc`
   - 适合手工追加 provider、models、plugin 高级配置、额外 MCP 条目

当前脚本会在写完 `opencode.json` 后再合并用户覆盖层：

- `plugin` 数组：追加去重
- `provider` / `models` / `mcp` 等对象：深度合并
- 未知键：保留，不主动删除

## `opencode.user.json` 怎么写

### 只加插件

```json
{
  "plugin": [
    "my-custom-plugin",
    "@org/another-plugin"
  ]
}
```

### 给现有 provider 增加更多模型

```json
{
  "provider": {
    "mimo": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Mimo",
      "options": {
        "baseURL": "{env:OPENAI_BASE_URL}",
        "apiKey": "{env:OPENAI_API_KEY}"
      },
      "models": {
        "mimo-v2.5": { "name": "mimo-v2.5" },
        "mimo-v2-pro": { "name": "mimo-v2-pro" }
      }
    }
  }
}
```

### 插件 + provider 一起扩展

```json
{
  "plugin": [
    "my-custom-plugin"
  ],
  "provider": {
    "mimo": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Mimo",
      "options": {
        "baseURL": "{env:OPENAI_BASE_URL}",
        "apiKey": "{env:OPENAI_API_KEY}"
      },
      "models": {
        "mimo-v2.5": { "name": "mimo-v2.5" },
        "mimo-v2-pro": { "name": "mimo-v2-pro" }
      }
    }
  }
}
```

建议：

- 默认主模型仍优先通过 `OPENCODE_MODEL` 设置
- 对于 `mimo` 这类自定义 provider，推荐在 `opencode.user.json` 中显式声明 `provider.<id>`；环境变量自动写入 `baseURL` 目前只覆盖脚本内置映射的 provider
- 不要把真实密钥硬编码进 `opencode.user.json`，优先用 `{env:...}`
- 不要把 `/config/opencode/opencode.json` 当作长期手工配置源

## PR reviewer 该看什么

- `build-oh-my-opencode-runtime.yml`：是否只保留手动触发、tag 规则是否干净
- `image/Dockerfile`：是否仍然以独立镜像上下文承载运行时依赖
- `image/scripts/entrypoint.sh`、`image/scripts/bootstrap-opencode-userland.sh`、`image/scripts/install-oh-my-opencode.sh`：是否继续保证 `/data` 与 `/config` 上的持久化语义
- `image/scripts/update_opencode_config.py`：是否继续保留用户覆盖层与插件去重合并语义
