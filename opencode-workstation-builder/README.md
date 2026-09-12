# opencode-workstation-builder

这个目录按 `okxlin/release-factory` 的目录习惯放置：

- 与 `1panel-builder/` 平级
- 只承载 `opencode-workstation` 的镜像构建发布内容
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
- 默认镜像仓库名：`ghcr.io/<owner>/opencode-workstation`
- workflow 支持手动构建、每周安全刷新，以及按路径触发的 PR 验证
- 默认 tag：`latest`
- 可选附带 `latest` 别名
- `amd64`、`arm64` 分别在原生 runner 构建一次，验证默认插件、服务鉴权及 HOME 持久化后扫描；发布复用同一个镜像摘要，再合并平台 manifest
- workflow 输入会先校验 tag、平台列表和镜像仓库名；BuildKit cache 使用 GitHub Actions cache 的 `mode=min`，减少缓存空间压力
- Tooling: git, gh, ripgrep, fd, jq, yq, shellcheck, shfmt, actionlint, comment-checker, Docker CLI, Go 1.27.0, Rust, Bun 1.4.0, pnpm, yarn
- 默认保留 oh-my-opencode 与可选的 Dynamic Context Pruning（DCP）支持，不再预装 `opencode-gpt-unlocked`

镜像内置 `image/opencode-runtime/package-lock.json` 固定的 OpenCode 基线，首次启动无需联网下载主程序。
默认 DCP 版本也记录在该目录的 `package.json`，仍在用户目录安装；已有 OpenCode 安装会保留，
可用 `OPENCODE_NPM_PACKAGE` 和 `OPENCODE_FORCE_INSTALL=1` 主动切换版本。
TypeScript 由 npm 安装，避免 Debian 的 `node-typescript` 再引入一套旧 Node 运行时。

CI 分别扫描镜像和默认启动后安装的用户目录。OpenCode 是编译后的二进制，Trivy 无法完整识别内部
JavaScript 依赖；上游公告核对及覆盖限制见 [基线说明](image/opencode-runtime/UPSTREAM.md)。
用户自行升级的主程序和插件不等同于该次镜像发布所验证的版本。

## 运行时权限模型

镜像默认仍以 `opencode` 用户运行。入口脚本会先准备 `/workspace`、`/cache` 和官方 HOME 持久化目录，并在检测到 `/var/run/docker.sock` 时按宿主 socket 的 GID 动态创建/加入容器内用户组，然后刷新到普通用户会话。

如果部署系统临时以 root 启动容器，入口脚本完成目录准备后也会降权回 `opencode` 用户继续运行，避免长期以 root 写入持久化数据。

可选修复开关：

- `FIX_WORKSPACE_OWNERSHIP_RECURSIVE=true`：递归修复 `/workspace` ownership
- `FIX_CACHE_OWNERSHIP_RECURSIVE=true`：递归修复 `/cache` ownership

## 运行时目录模型

当前工作站镜像已经改为**直接按 OpenCode 官方 HOME 路径运行**，不再以 `/config/opencode` 作为主运行语义。

### 运行时真实目录

- `~/.config/opencode`
- `~/.agents`
- `~/.claude`
- `~/.opencode`
- `~/.local/share/opencode`
- `~/.local/share/oh-my-opencode`
- `/workspace`

### 推荐持久化挂载

- `/home/opencode/.config`
- `/home/opencode/.agents`
- `/home/opencode/.claude`
- `/home/opencode/.opencode`
- `/home/opencode/.local/share`
- `/workspace`

这样做的原因：

- 与 OpenCode upstream 源码的目录发现逻辑一致
- `skills` / `agents` / `claude-compatible` 扩展不需要额外路径翻译
- 避免 `/config -> HOME` 的单文件同步漂移
- 后续 upstream 扩展 HOME 目录扫描时兼容风险最低

## 运行时配置分层

推荐按三层使用：

1. **部署级环境变量层**
   - 通过 `.env` / CI / 部署平台注入
   - 适合：`OPENCODE_MODEL`、`OPENCODE_SMALL_MODEL`、`OPENCODE_PROVIDER_ID`、`OPENCODE_EXTRA_PLUGINS`、以及各类 `*_BASE_URL` / `*_API_KEY`
2. **生成配置层**
   - `~/.config/opencode/opencode.json`
   - 由 `image/scripts/update_opencode_config.py` 在启动/安装阶段更新
   - 这是生成产物，不建议长期手工维护
3. **用户覆盖层**
   - `~/.config/opencode/opencode.user.json` 或 `~/.config/opencode/opencode.user.jsonc`
   - 适合手工追加 provider、models、plugin 高级配置、额外 MCP 条目

当前脚本会在写完 `opencode.json` 后再合并用户覆盖层：

- `plugin` 数组：追加去重
- `provider` / `models` / `mcp` 等对象：深度合并
- 未知键：保留，不主动删除

升级到包含本迁移的镜像后，入口脚本会在首次启动时从生成的全局配置中移除旧版自动写入的
`opencode-gpt-unlocked` 插件和 `experimental.refusal_patcher` 配置。迁移是幂等的，只改动这两类
已废弃条目，不会删除用户覆盖文件或其它 provider、model、MCP 和插件配置。入口还会把 OMO 的
`~/.omo` 数据桥接到已持久化的 `~/.config/.omo`，避免新版本 OMO 在跨挂载点备份配置时触发
`EXDEV`；已有的 `.omo` 目录会先复制并保留备份。

## Skills / Agents / Claude 兼容目录

### OpenCode skills

- `~/.config/opencode/skills/...`

### agent-compatible skills

- `~/.agents/skills/...`

### claude-compatible skills

- `~/.claude/skills/...`

### agent markdown / command markdown

OpenCode 本身还会读取项目内或兼容目录中的：

- `agents/**/*.md`
- `agent/**/*.md`
- `commands/**/*.md`
- `command/**/*.md`
- `AGENTS.md`
- `.opencode/...`

所以 `/workspace` 也应该是长期持久化目录，而不是短暂临时盘。

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
- 不要把 `~/.config/opencode/opencode.json` 当作长期手工配置源

## PR reviewer 该看什么

- `build-opencode-workstation.yml` 与 `release-workstations.yml`：原生双架构验证、tag / 平台规则及发布摘要绑定
- `image/Dockerfile`：是否仍然以独立镜像上下文承载运行时依赖
- `image/scripts/entrypoint.sh`、`image/scripts/bootstrap-opencode-userland.sh`、`image/scripts/install-oh-my-opencode.sh`：是否继续保证官方 HOME 路径上的持久化语义及废弃配置迁移
- `image/scripts/update_opencode_config.py`：是否继续保留用户覆盖层、插件去重合并和废弃条目清理语义
