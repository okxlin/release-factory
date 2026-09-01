# Release Factory

**简体中文** | [English](README_EN.md)

Release Factory 集中维护 1Panel 离线安装包、AI 开发工作站、浏览器环境和沙箱镜像的构建与发布流程。每个项目都有独立的构建目录或补丁入口，由 GitHub Actions 负责参数校验、测试、安全门禁和发布。

> 本仓库生成的是社区维护构建物，不代表上游项目官方发行版。使用前请核对项目说明、镜像标签、持久化路径、运行权限和网络暴露范围。

## 项目索引

| 项目 | 产物 | 架构 | 文档与工作流 |
| --- | --- | --- | --- |
| 1Panel 离线安装包 | GitHub Release 中的 `.tar.gz` 与 `.sha256` | `amd64`、`arm64`、`armv7`、`ppc64le`、`s390x` | [构建目录](1panel-builder/) · [Workflow](.github/workflows/build-1panel.yml) |
| Codex Claude Workstation | `ghcr.io/okxlin/codex-claude-workstation` | `linux/amd64`、`linux/arm64` | [说明](codex-claude-workstation-builder/README.md) · [Workflow](.github/workflows/build-codex-claude-workstation.yml) |
| DeepSeek Harness Runtime | `ghcr.io/okxlin/deepseek-harness`；Docker Hub（需配置） | `linux/amd64`、`linux/arm64` | [说明](deepseek-harness-builder/README.zh-CN.md) · [Workflow](.github/workflows/build-deepseek-harness.yml) |
| DeepSeek Harness Workstation | 与 Runtime 共用镜像仓库，使用 `-workstation` 标签 | `linux/amd64`、`linux/arm64` | [说明](deepseek-harness-builder/README.zh-CN.md) · [Compose](deepseek-harness-builder/compose.workstation.yml) · [Workflow](.github/workflows/build-deepseek-harness-workstation.yml) |
| Gemini Skill Browser（Kasm） | `ghcr.io/okxlin/gemini-skill-browser` | `linux/amd64` | [说明](gemini-skill-browser-builder/README.md) · [Workflow](.github/workflows/build-gemini-skill-browser.yml) |
| Gemini Skill Browser（LinuxServer） | 与 Kasm 共用镜像仓库，使用 `-linuxserver` 标签 | `linux/amd64` | [说明](gemini-skill-browser-linuxserver-builder/README.md) · [Workflow](.github/workflows/build-gemini-skill-browser-linuxserver.yml) |
| OpenCode Workstation | `ghcr.io/okxlin/opencode-workstation` | `linux/amd64`、`linux/arm64` | [说明](opencode-workstation-builder/README.md) · [Workflow](.github/workflows/build-opencode-workstation.yml) |
| OpenClaw Sandbox | `ghcr.io/okxlin/openclaw-sandbox` | GitHub Actions runner 默认架构 | [Workflow](.github/workflows/openclaw-upstream-docker.yml) · [加固脚本](scripts/apply-openclaw-runtime-hardening.sh) |

根 README 是导航入口。具体镜像的启动参数、鉴权、持久化、工具链、升级和权限边界，以项目目录中的 README、Compose 文件和工作流为准。

## 快速开始

### 使用已发布镜像

```bash
docker pull ghcr.io/okxlin/codex-claude-workstation:latest
docker pull ghcr.io/okxlin/deepseek-harness:latest
docker pull ghcr.io/okxlin/deepseek-harness:workstation
docker pull ghcr.io/okxlin/opencode-workstation:latest
docker pull ghcr.io/okxlin/openclaw-sandbox:latest

# Gemini aliases are published only when explicitly enabled:
# docker pull ghcr.io/okxlin/gemini-skill-browser:latest-kasm
# docker pull ghcr.io/okxlin/gemini-skill-browser:latest-linuxserver
```

DeepSeek Harness 也会发布到由 GitHub Actions 仓库 Variable 或 Secret `DOCKERHUB_USERNAME` 配置的 Docker Hub 命名空间。各镜像的端口、鉴权、持久化目录和可选 Docker Socket 权限并不相同；启动容器前先阅读上表对应的项目说明，不要把示例密码或高权限挂载直接用于公网环境。

### 手动触发构建

可以在 [Actions](https://github.com/okxlin/release-factory/actions) 页面选择工作流并点击 **Run workflow**，也可以使用 GitHub CLI：

```bash
gh workflow run build-deepseek-harness.yml \
  --repo okxlin/release-factory \
  --ref main \
  -f platforms=linux/amd64,linux/arm64 \
  -f push_latest=true
```

该示例省略了 DeepSeek Harness 的 `dsh_version` 和 `image_tag`，因此会解析当前 npm 版本并使用对应版本标签。其他项目的输入字段和默认值请直接查看对应工作流；发布前必须确认仓库所需的 Variables、Secrets 和目标镜像仓库已配置。

## 标签与发布

| 项目 | 版本标签 | 浮动标签 |
| --- | --- | --- |
| 1Panel | `1panel-<actor>-<version>`；文件为 `1panel-<actor>-<version>-<arch>.tar.gz` | 不适用 |
| Codex Claude Workstation | UTC 日期 `YYYYMMDD` | `latest` |
| DeepSeek Harness Runtime | 解析到的 `@deepseek-ai/dsh` 版本 `<DSH_VERSION>` | `latest` |
| DeepSeek Harness Workstation | `<DSH_VERSION>-workstation` | `workstation` |
| Gemini Skill Browser（Kasm） | `<browser_base_tag>-kasm` | `latest-kasm`，仅显式启用时发布 |
| Gemini Skill Browser（LinuxServer） | `<browser_base_tag>-linuxserver` | `latest-linuxserver`，仅显式启用时发布 |
| OpenCode Workstation | 手动指定标签或 `latest` | 可显式附带 `latest` |
| OpenClaw Sandbox | `<upstream_release>-sandbox` | `latest` |

除 DeepSeek Harness 外，容器工作流默认只发布到当前仓库所有者的 GHCR 命名空间。DeepSeek Harness 需要同时配置 Docker Hub 凭据；1Panel 工作流不发布容器镜像，而是把各架构安装包和 SHA-256 校验文件写入 GitHub Release。

## 验证与安全

发布流程按项目组合使用以下门禁：

- 校验镜像仓库名、标签、目标平台和手动输入，拒绝不支持的架构。
- 在推送前构建本地测试镜像，并运行项目对应的容器、鉴权、WebSocket、工具链或运行时冒烟测试。
- 使用 [Trivy 门禁](SECURITY_SCAN.md)统计可修复的 HIGH/CRITICAL 漏洞；阈值按镜像类型独立配置，不代表所有工作流都采用零阈值。
- DeepSeek Harness 额外执行 pnpm audit、Caddy 依赖图检查、`govulncheck`、双架构冒烟测试和 Workstation Compose 权限契约检查。
- Codex Workstation 校验 Paseo 供应链记录与运行时契约；OpenClaw 校验上游 Release 标签、仓库内加固脚本和关键基础镜像摘要。

通过安全扫描不等于不存在任何漏洞。门禁主要约束有修复版本的 HIGH/CRITICAL 问题；使用者仍需结合镜像来源、运行权限、网络暴露和业务环境评估风险。

## 事实源

| 信息 | 事实源 |
| --- | --- |
| 构建输入、平台和发布标签 | [`.github/workflows/`](.github/workflows/) 与 [`scripts/`](scripts/) |
| 镜像依赖与上游固定版本 | 各项目的 Dockerfile、包清单和锁文件 |
| 运行时、持久化和权限 | 对应项目 README、Compose 文件和镜像入口脚本 |
| 漏洞阈值与安全例外 | [`SECURITY_SCAN.md`](SECURITY_SCAN.md) 与 [`scripts/trivy-image-gate.sh`](scripts/trivy-image-gate.sh) |

当根 README 与项目 README 或工作流出现差异时，以更靠近实际构建或运行边界的事实源为准；根 README 不重复维护当前组件版本或动态漏洞结论。

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
| [`scripts/`](scripts/) | 跨项目共享的 CI 门禁脚本 |
| [`SECURITY_SCAN.md`](SECURITY_SCAN.md) | 漏洞阈值、安全例外和客户端依赖说明 |

## 贡献

- 从最新 `main` 创建短期分支，每个 PR 聚焦一个构建目标或一类文档变更。
- 修改平台、标签或发布策略时，同时更新对应工作流、参数解析脚本、测试契约和项目 README。
- 新增或更新镜像时，提供可重复的本地构建、项目级冒烟测试和发布前安全门禁。
- 固定关键上游版本、源码归档或基础镜像摘要，并保留来源、许可证和必要补丁记录。
- 不要提交 Token、密码、私钥或真实 `.env` 文件；registry 凭据必须放在 GitHub Actions Variables/Secrets 中。

提交 PR 前请检查变更范围、Markdown/脚本格式、相关测试结果和工作流权限是否仍然最小化。
