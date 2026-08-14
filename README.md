# Release Factory

**简体中文** | [English](README_EN.md)

集中维护 1Panel 离线安装包、AI 开发工作站、浏览器环境和沙箱镜像的构建与发布流程。每个项目都有独立的构建目录或补丁入口，由 GitHub Actions 完成参数校验、测试、安全门禁和发布。

> 本仓库生成的是社区维护构建物。使用前请核对上游版本、镜像标签、运行权限和各项目目录中的说明。

## 构建矩阵

| 项目 | 发布产物 | 支持架构 | 触发方式 | 构建入口 |
| --- | --- | --- | --- | --- |
| 1Panel 离线安装包 | GitHub Release 中的 `.tar.gz` 与 `.sha256` | `amd64`、`arm64`、`armv7`、`ppc64le`、`s390x` | 手动 | [构建目录](1panel-builder/) · [Workflow](.github/workflows/build-1panel.yml) · [运行](https://github.com/okxlin/release-factory/actions/workflows/build-1panel.yml) |
| Codex Claude Workstation | `ghcr.io/okxlin/codex-claude-workstation` | `linux/amd64`、`linux/arm64` | 手动、每周日 03:17 UTC | [说明](codex-claude-workstation-builder/README.md) · [Workflow](.github/workflows/build-codex-claude-workstation.yml) · [运行](https://github.com/okxlin/release-factory/actions/workflows/build-codex-claude-workstation.yml) |
| DeepSeek Harness Runtime | `ghcr.io/okxlin/deepseek-harness`、`moelin/deepseek-harness` | `linux/amd64`、`linux/arm64` | 手动、每周日 03:43 UTC | [说明](deepseek-harness-builder/README.md) · [Workflow](.github/workflows/build-deepseek-harness.yml) · [运行](https://github.com/okxlin/release-factory/actions/workflows/build-deepseek-harness.yml) |
| DeepSeek Harness Workstation | 与 Runtime 共用镜像仓库，使用 `-workstation` 标签 | `linux/amd64`、`linux/arm64` | 手动、每周日 04:13 UTC | [说明](deepseek-harness-builder/README.md) · [Compose](deepseek-harness-builder/compose.workstation.yml) · [Workflow](.github/workflows/build-deepseek-harness-workstation.yml) · [运行](https://github.com/okxlin/release-factory/actions/workflows/build-deepseek-harness-workstation.yml) |
| Gemini Skill Browser（Kasm） | `ghcr.io/okxlin/gemini-skill-browser` | `linux/amd64` | 手动 | [说明](gemini-skill-browser-builder/README.md) · [Workflow](.github/workflows/build-gemini-skill-browser.yml) · [运行](https://github.com/okxlin/release-factory/actions/workflows/build-gemini-skill-browser.yml) |
| Gemini Skill Browser（LinuxServer） | 与 Kasm 变体共用镜像仓库，使用 `-linuxserver` 标签 | `linux/amd64` | 手动 | [说明](gemini-skill-browser-linuxserver-builder/README.md) · [Workflow](.github/workflows/build-gemini-skill-browser-linuxserver.yml) · [运行](https://github.com/okxlin/release-factory/actions/workflows/build-gemini-skill-browser-linuxserver.yml) |
| OpenCode Workstation | `ghcr.io/okxlin/opencode-workstation` | `linux/amd64`、`linux/arm64` | 手动 | [说明](opencode-workstation-builder/README.md) · [Workflow](.github/workflows/build-opencode-workstation.yml) · [运行](https://github.com/okxlin/release-factory/actions/workflows/build-opencode-workstation.yml) |
| OpenClaw Sandbox | `ghcr.io/okxlin/openclaw-sandbox` | Workflow 运行器默认平台，当前为 `linux/amd64` | 手动、每天 02:00 UTC | [Workflow](.github/workflows/openclaw-upstream-docker.yml) · [加固补丁](patches/openclaw-runtime-hardening.patch) · [运行](https://github.com/okxlin/release-factory/actions/workflows/openclaw-upstream-docker.yml) |

## 快速使用

### 拉取镜像

```bash
docker pull ghcr.io/okxlin/codex-claude-workstation:latest
docker pull ghcr.io/okxlin/deepseek-harness:latest
docker pull ghcr.io/okxlin/deepseek-harness:workstation
docker pull moelin/deepseek-harness:workstation
docker pull ghcr.io/okxlin/opencode-workstation:latest
docker pull ghcr.io/okxlin/openclaw-sandbox:latest
```

各镜像的端口、鉴权、持久化目录和可选 Docker Socket 权限并不相同。启动容器前请先阅读上表对应的项目说明；不要直接把示例密码或高权限挂载用于公网环境。

### 手动运行 Workflow

可以在 [Actions](https://github.com/okxlin/release-factory/actions) 页面选择工作流并点击 **Run workflow**，也可以使用 GitHub CLI：

```bash
gh workflow run build-deepseek-harness.yml \
  --repo okxlin/release-factory \
  --ref main \
  -f image_tag=20260815 \
  -f platforms=linux/amd64,linux/arm64 \
  -f push_latest=true

gh workflow run build-1panel.yml \
  --repo okxlin/release-factory \
  --ref main \
  -f version=v2.1.3
```

DeepSeek Harness 同时发布到 GHCR 和 Docker Hub。运行这两个工作流前，需要配置仓库变量或 Secret `DOCKERHUB_USERNAME`，以及 Secret `DOCKERHUB_TOKEN`。Token 只用于 Registry 登录，不会传入镜像构建上下文。

## 标签与发布策略

| 项目 | 主要版本/日期标签 | 可选浮动标签 |
| --- | --- | --- |
| 1Panel | Release：`1panel-<actor>-<version>`；文件：`1panel-<actor>-<version>-<arch>.tar.gz` | 不适用 |
| Codex Claude Workstation | UTC 日期 `YYYYMMDD` | `latest`，手动触发默认启用，定时任务始终更新 |
| DeepSeek Harness Runtime | UTC 日期 `YYYYMMDD` | `latest`，手动触发默认启用，定时任务始终更新 |
| DeepSeek Harness Workstation | `YYYYMMDD-workstation`；手动标签缺少后缀时自动补全 | `workstation`，手动触发默认启用，定时任务始终更新 |
| Gemini Skill Browser（Kasm） | `<browser_base_tag>-kasm` | `latest-kasm`，仅显式启用时发布 |
| Gemini Skill Browser（LinuxServer） | `<browser_base_tag>-linuxserver` | `latest-linuxserver`，仅显式启用时发布 |
| OpenCode Workstation | `latest` 或手动指定标签 | 可显式附带 `latest` |
| OpenClaw Sandbox | `<upstream_release>-sandbox` | `latest` |

除 DeepSeek Harness 外，容器工作流默认只发布到当前仓库所有者的 GHCR 命名空间。1Panel 工作流不发布容器镜像，而是把每个架构的安装包和 SHA-256 校验文件写入同一个 GitHub Release。

## 质量与安全门禁

发布流程按项目组合使用以下检查：

- 校验镜像仓库名、标签、目标平台和手动输入，拒绝不支持的架构。
- 在推送前构建本地测试镜像，并运行项目对应的容器、鉴权、WebSocket、工具链或运行时烟雾测试。
- 使用 [Trivy 门禁](SECURITY_SCAN.md)统计可修复的 HIGH/CRITICAL 漏洞；阈值按镜像类型独立配置，并非所有工作流都采用零阈值。
- DeepSeek Harness 额外执行 pnpm 审计、Caddy 依赖图检查、`govulncheck`、双架构烟雾测试和 Workstation Compose 权限契约检查。
- Codex Workstation 校验 Paseo 的供应链记录与运行时契约；OpenClaw 校验上游 Release 标签、应用仓库内加固补丁，并固定关键基础镜像摘要。

安全扫描通过不等于不存在任何漏洞。当前 Trivy 门禁只统计带修复版本的 HIGH/CRITICAL 漏洞；使用者仍需结合镜像来源、权限、网络暴露和业务环境评估风险。

## 仓库结构

| 路径 | 用途 |
| --- | --- |
| [`.github/workflows/`](.github/workflows/) | 构建、测试和发布工作流 |
| [`1panel-builder/`](1panel-builder/) | 1Panel 多架构离线包准备、构建与打包脚本 |
| [`codex-claude-workstation-builder/`](codex-claude-workstation-builder/) | Codex、Claude Code、code-server 与 Paseo 工作站镜像 |
| [`deepseek-harness-builder/`](deepseek-harness-builder/) | DeepSeek Harness Runtime/Workstation、Caddy 鉴权和 Compose 配置 |
| [`gemini-skill-browser-builder/`](gemini-skill-browser-builder/) | 基于 Kasm Edge 的 Gemini Skill Browser |
| [`gemini-skill-browser-linuxserver-builder/`](gemini-skill-browser-linuxserver-builder/) | 基于 LinuxServer Chrome 的 Gemini Skill Browser |
| [`opencode-workstation-builder/`](opencode-workstation-builder/) | OpenCode 持久化开发工作站 |
| [`patches/`](patches/) | 经审查的上游构建或运行时补丁 |
| [`scripts/`](scripts/) | 跨项目共享的 CI 门禁脚本 |
| [`SECURITY_SCAN.md`](SECURITY_SCAN.md) | 漏洞阈值、DeepSeek Caddy 例外和 Docker 客户端依赖说明 |

## 贡献

- 从最新 `main` 创建短期分支，每个 PR 聚焦一个构建目标或一类文档变更。
- 修改平台、标签或发布策略时，同时更新对应的架构配置、参数解析脚本、Workflow 和项目 README。
- 新增或更新镜像时，先提供可重复的本地构建、项目级烟雾测试和发布前安全门禁。
- 固定关键上游版本、源码归档或基础镜像摘要，并保留来源、许可证和必要补丁记录。
- 不要提交 Token、密码、私钥或真实 `.env` 文件；Registry 凭据应放在 GitHub Actions Variables/Secrets 中。

提交 PR 前，请检查变更范围、Markdown/脚本格式、相关测试结果以及工作流权限是否仍然最小化。
