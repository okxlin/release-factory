# DeepSeek Harness 镜像构建器

[English](README.md) | **简体中文**

这个构建器把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 与自定义 [Caddy](https://github.com/caddyserver/caddy)、[caddy-security](https://github.com/greenpau/caddy-security) 和 [caddy-ratelimit](https://github.com/mholt/caddy-ratelimit) 打包到同一个镜像体系中。它在 DSH 前提供浏览器登录表单和源站侧爆破防护，同时让 DSH 应用本身只绑定到容器内 loopback。

一个 Dockerfile 会产出两个独立测试的变体，并发布到同一个镜像仓库：

| 浮动标签 | 固定标签格式 | Docker target | 用途 |
| --- | --- | --- | --- |
| `latest` | `<DSH_VERSION>` | `runtime` | 轻量级 1Panel 服务镜像，包含必要 Shell 和仓库工具。它仍是默认最终 target。 |
| `workstation` | `<DSH_VERSION>-workstation` | `workstation` | 完整交互式开发环境，包含编译器和语言工具链。 |

两个工作流都会把相同标签发布到 `ghcr.io/okxlin/deepseek-harness` 和 `docker.io/$DOCKERHUB_USERNAME/deepseek-harness`。请把 `DOCKERHUB_USERNAME` 配置为 GitHub Actions 仓库变量或 Secret，并把 `DOCKERHUB_TOKEN` 配置为仓库 Secret。Docker Hub token 只用于 Registry 登录，不会传入镜像构建上下文。

定时任务会解析 npm 中已发布 `@deepseek-ai/dsh` 的最高 SemVer，更新镜像构建上下文，并发布匹配的 `<DSH_VERSION>` 和 `<DSH_VERSION>-workstation` 标签。该默认行为有意不依赖可能落后于新预发布版本的 `latest` dist-tag；手动显式传入 `latest`、`next` 或准确版本时，仍按请求的 npm selector 解析。手动工作流也可覆盖发布标签。AppStore `latest` 通道使用浮动标签，编号 AppStore 版本使用匹配的版本标签。

组件的准确固定版本由 [Dockerfile](image/Dockerfile)、[package.json](image/package.json)、[pnpm-lock.yaml](image/pnpm-lock.yaml)，以及 [runtime](../.github/workflows/build-deepseek-harness.yml) 和 [workstation](../.github/workflows/build-deepseek-harness-workstation.yml) 工作流定义。这些构建输入是唯一版本来源；README 只说明能力和更新策略，不重复维护具体版本号。

影响 DeepSeek Harness 构建输入的 PR 会运行一个只读的组件固定输入契约检查。它会拒绝浮动基础镜像标签、格式错误的 checksum，以及 Dockerfile 内重复版本声明或源码 URL 不再一致的半更新。另一个 PR 工作流会使用提交的输入构建本地 amd64 runtime 和 workstation 镜像，再运行依赖审计、冒烟契约、Caddy 门禁和 Trivy 门禁。两个工作流都不会获得 registry 凭据、登录或发布镜像；多架构发布仍由发布工作流负责。

另有一个每日只读工作流，会把固定组件版本与 GitHub、Go module proxy、Go、Node.js、npm、PyPI 和 Python 的权威版本源进行比较。它会把更新候选写入 Actions Summary 并发出 warning，但不会修改文件、创建 PR 或阻断定时发布。版本源或策略错误会让检查失败；手动运行时也可以启用严格模式，在发现更新时失败。报告出的版本只是待审候选，仍需更新对应 checksum 和镜像 digest，并通过现有构建、smoke 与漏洞门禁。

Go 跟随官方稳定版本端点 <https://go.dev/VERSION?m=text>，其 Docker Official Image index 固定 digest，用于可复现地选择 `amd64` 和 `arm64`。actionlint 使用该固定 Go 工具链从 checksum 固定的官方源码归档重新构建；其他独立 workstation 工具从各自官方 GitHub Release 下载，并按架构固定 SHA-256 checksum。

workstation 中的三个 Docker 客户端二进制文件使用已固定的 Go 版本从校验和固定的官方源码归档重新构建。Buildx 源码闭包只为了冻结的随机名称生成器而导入旧 `github.com/docker/docker` 模块；构建会在本地保留该 vendored 包，并在编译 Buildx 和 Compose 前移除无关 daemon 模块。这样可以把 daemon-only AuthZ 问题 [CVE-2026-34040](https://github.com/moby/moby/security/advisories/GHSA-x744-4wpc-v9h2) 排除在客户端依赖图之外，而不是放宽镜像扫描阈值。

镜像会为 `linux/amd64` 和 `linux/arm64` 构建并测试。

## 运行时布局

```text
browser
  -> HTTPS reverse proxy (1Panel/OpenResty)
  -> host loopback port, for example 127.0.0.1:56789
  -> Caddy + 认证限速 + caddy-security on container port 8080
  -> DeepSeek Harness on 127.0.0.1:3080 inside the container
```

只有 Caddy 监听容器接口。DSH 端口不会暴露给同宿主的其他容器或宿主网络。轻量镜像把 Caddy、认证、JWT 和 DSH 状态持久化到 `/data`，把用户工作目录放在 `/workspace`。workstation 把认证、Caddy 和 DSH 状态放在 `/data`，把用户安装的工具放在挂载到 `/home/node` 的 HOME 卷里，并用单独的直接 `/workspace` 挂载承载项目文件。workstation 的这两个路径都不是符号链接。

## 构建

```bash
# 默认/轻量镜像。默认解析已发布的最高 DSH 版本。
deepseek-harness-builder/scripts/build-local.sh \
  --target runtime \
  --tag deepseek-harness:local

# 完整开发 workstation。
deepseek-harness-builder/scripts/build-local.sh \
  --target workstation \
  --tag deepseek-harness-workstation:local
```

本地构建辅助脚本会解析请求的 `@deepseek-ai/dsh` npm 版本，在临时构建上下文中更新 `package.json` 和 `pnpm-lock.yaml`，并把解析后的版本作为 Docker `DSH_VERSION` 传入。未给 selector 时会按 SemVer 优先级比较全部已发布版本；使用 `--version <release>` 或 npm dist-tag 可以指定准确版本或发布通道。直接 `docker build` 仍支持已提交的基线上下文；未提供构建参数时会从 `package.json` 推导 `DSH_VERSION`。

生产依赖闭包由活跃构建上下文中的 `pnpm-lock.yaml` 固定。pnpm 生命周期脚本 fail-closed，并限制在 `pnpm-workspace.yaml` 中已审查的软件包内。

镜像构建会对 DSH browse 目录选择器应用一个范围很小、并且会校验源码形状的兼容性补丁，使网页的 **Add workspace** 对话框在未指定路径时从 `DSH_WORKSPACE` 开始，而不是从进程 `HOME` 开始。如果上游实现发生变化，构建会 fail-closed，直到重新审查补丁和 smoke 合约。该补丁不会改变 workstation 的 `HOME` 值或工具持久化路径。

自定义 Caddy 构建会校验 Caddy 和 go-authcrunch 源码归档 checksum，移除 go-authcrunch 未使用的 GPG 公钥解析器，并在链接前运行上游 identity 包测试。它会对固定 Caddy 源码应用上游的两行 CEL 兼容修复，再将 `cel-go` 提升到已修复版本。caddy-security 仍保留 SSH 公钥支持，同时生成的 `CADDY_GO_PACKAGES.txt` 清单不得包含 `golang.org/x/crypto/openpgp` 包。限速模块及其许可证也会在同一构建中固定和校验。构建还会把 `grpc`、`klauspost/compress` 和 `x/text` 提升到已修复版本。

两个镜像都包含校验和固定的独立 pnpm bundle，并移除 Corepack，避免所选 pnpm 版本静默跟随包管理器通道。轻量 runtime 还会移除 npm 和 npx；workstation 会用单独校验和固定的 npm 11 bundle 替换 Node.js 自带的旧 npm，为开发兼容性提供 npm 和 npx，并在镜像构建及 smoke 测试中校验版本。

## 开发环境

轻量镜像在现有 Bash、Git、curl 运行时基础上加入这些低开销基础工具：

- OpenSSH client、jq、ripgrep、less、procps、file、unzip
- 独立 pnpm

它有意不包含 npm、Python、Go、Rust、GCC/G++ 和 Make。

workstation 镜像继承相同的 DSH/认证运行时，并额外包含：

- Node.js、npm、npx 和 pnpm
- Python 3.12.14，含 pip、venv、pipx、pytest 和开发头文件
- Go
- Docker CLI、Compose 和 Buildx，仅客户端工具
- GCC/G++、Clang、clang-format、GDB、CMake、Ninja、Autoconf/Automake、libtool、pkg-config 和常见原生库头文件
- actionlint、yq、uv/uvx、Ruff、ShellCheck、shfmt、yamllint 和 pre-commit
- Git LFS、GitHub CLI、just、hyperfine、entr、fd、bat、fzf、tmux、Vim、SQLite、ncdu，以及常见网络、调试、归档工具

默认 workstation 有意不包含 Rust 和 Cargo；需要它们的项目可以把项目专用工具链安装到持久化 HOME 卷。它也不包含 code-server、Codex/Claude CLI、代理守护进程、`sudo` 或 Docker daemon。镜像中有 Docker 客户端工具，但默认不会挂载 daemon socket，因此默认 workstation 没有宿主-容器控制通道。用户安装在 `/home/node` 下的工具会随 workstation HOME 卷持久化，项目则通过直接 `/workspace` 挂载持久化。

## 在 1Panel/OpenResty 后运行

复制 `image/.env.example` 到私有环境文件，并至少修改 `PUBLIC_URL` 和 `AUTH_PASSWORD`。不要提交这个文件。

**升级时注意：持久化路径已变更。** 当前镜像把应用状态保存到 `/data`，
并要求把 `/data` 挂载为宿主机路径或 Docker 命名卷。仅映射旧的
`/home/node/.local/share/deepseek-harness` 无法持久化新版本。为了防止静默丢失状态，
当 `/data` 未挂载时，entrypoint 会输出中英文错误并终止启动；请重新创建容器并加入
持久化的 `/data` 挂载。

```bash
sudo install -d -m 0750 /opt/deepseek-harness/data /opt/deepseek-harness/workspace

docker run -d \
  --name deepseek-harness \
  --restart unless-stopped \
  -p 127.0.0.1:56789:8080 \
  --env-file /opt/deepseek-harness/runtime.env \
  -v /opt/deepseek-harness/data:/data \
  -v /opt/deepseek-harness/workspace:/workspace \
  ghcr.io/okxlin/deepseek-harness:latest
```

轻量镜像建议把宿主机目录绑定到 `/data`。这样认证、Caddy、JWT 和 DSH
状态会直接保存在 `/opt/deepseek-harness/data`，宿主机的备份和迁移工具可以
直接访问。entrypoint 会先规范化绑定根目录，再为 `node` 用户（UID/GID `1000:1000`）
创建所需的子目录和文件；请保持绑定源是普通目录，并在复制或恢复数据时保留其
所有权和权限。

`/opt/deepseek-harness` 是示例宿主路径，可以替换为你控制的任意持久目录。

workstation 使用相同端口和认证变量。它通过 `/data` 持久化应用状态，通过一个命名卷持久化 HOME，并直接挂载项目目录：

```bash
docker run -d \
  --name deepseek-harness-workstation \
  --restart unless-stopped \
  -p 127.0.0.1:56789:8080 \
  --env-file /opt/deepseek-harness/runtime.env \
  -v /opt/deepseek-harness/data:/data \
  -v dsh-home:/home/node \
  -v /opt/deepseek-harness/workspace:/workspace \
  ghcr.io/okxlin/deepseek-harness:workstation
```

HOME 卷包含用户安装的 pnpm、pipx、uv、Go 及其他项目专用工具。应用状态位于 `/data`。镜像工作目录和 `DSH_WORKSPACE` 都默认是 `/workspace`；网页的 **Add workspace** 对话框也会从这里打开，里面的 `Home` 快捷入口也解析到 `/workspace`。`/home/node` 是用户 HOME 和工具持久卷，不是默认项目目录。workspace bind 用于项目文件，以及宿主侧备份或文件访问。

Docker CLI、Compose 和 Buildx 可以通过远程 `DOCKER_HOST` 工作，不需要额外挂载。若要控制宿主 Docker daemon，必须显式加入：

```bash
-v /var/run/docker.sock:/var/run/docker.sock
```

entrypoint 会在可能时把 socket 的数字 group 映射给非特权 `node` 用户。挂载这个 socket 会让工具和模型驱动终端实质上拥有宿主 Docker daemon 控制权；除非明确需要这项权限，否则保持禁用。

两个 Compose 文件都采用相同的可选 Docker socket 合约。复制 `image/.env.example` 到 `image/.env`，并至少设置 `PUBLIC_URL` 和 `AUTH_PASSWORD`，然后在 Docker 访问禁用状态下启动任一变体。

仓库中的 Compose 文件使用包内的 `./data/data`、`./data/workspace` 和 `dsh-home` 布局。上面的手动 `docker run` 示例使用推荐的 `/opt/deepseek-harness/data:/data` 路径绑定。如果通过 Compose 部署，请在本地 Compose override 或本地副本中使用相同的路径绑定；不要把特定环境的宿主路径提交到仓库：

```bash
docker compose -f deepseek-harness-builder/compose.yml up -d
```

workstation 把应用状态持久化到 `./data/data`，把 HOME 持久化到命名卷 `dsh-home`，并把项目目录绑定到 `./data/workspace`：

```bash
docker compose -f deepseek-harness-builder/compose.workstation.yml up -d
```

共享 socket 挂载为：

```yaml
volumes:
  - ${DOCKER_SOCK_SRC:-/dev/null}:/var/run/docker.sock
```

未设置或为空时会挂载 `/dev/null`，它不是 Unix socket，因此 daemon 访问保持禁用。只有在部署确实需要时，才启用高风险宿主控制路径：

```bash
DOCKER_SOCK_SRC=/var/run/docker.sock \
  docker compose -f deepseek-harness-builder/compose.yml up -d
```

任一变体都接受相同的 `DOCKER_SOCK_SRC`；workstation 请替换为 `compose.workstation.yml`。

两个 Compose 文件默认把容器端口 `8080` 发布为 `127.0.0.1:56789`。1Panel 应用包通过 `DOCKER_SOCK_PATH` 暴露相同的可选 socket 合约，`/dev/null` 为禁用默认值，`/var/run/docker.sock` 为显式高风险选择。

在 1Panel 中创建 HTTPS 网站，并代理到 `http://127.0.0.1:56789`。保持容器端口绑定到宿主 loopback；不要发布为 `0.0.0.0:56789`。

反向代理必须保留公网 authority 和 scheme，并允许 WebSocket 升级：

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

location / {
    proxy_pass http://127.0.0.1:56789;
    proxy_http_version 1.1;

    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
}
```

1Panel 常规反向代理模板通常已经提供大部分指令；请确认 WebSocket 支持以及三个 Host/scheme 头，而不是创建重复 location。如果 CDN 在 OpenResty 前终止 TLS，请确保 `X-Forwarded-Proto` 仍代表浏览器面对的 HTTPS scheme。错误值会导致登录重定向和 Cookie 处理使用错误 scheme。

把 `PUBLIC_URL` 设置为精确浏览器 origin，例如：

```dotenv
PUBLIC_URL=https://dsh.example.com
AUTH_COOKIE_INSECURE=false
CADDY_TRUSTED_PROXIES=private_ranges
```

有意拒绝 `https://example.com/dsh` 这类子路径部署。请使用独立域名或子域名。

镜像会按解析后的客户端 IP 对用户名阶段 POST 限制为每分钟 10 次，对密码阶段 POST 限制为每 10 分钟 10 次；被拒绝的请求返回 HTTP 429 和 `Retry-After`。仍建议在 1Panel WAF 或外层 OpenResty 中保留同类限速，作为纵深防御。

这两个额度是镜像默认值，定义在 [`image/Caddyfile`](image/Caddyfile) 中，有意不从运行时环境变量读取。若要修改，必须编辑该文件、重新构建镜像，并重新运行 smoke 测试；`CADDY_TRUSTED_PROXIES` 则可以单独在运行时配置。

`CADDY_TRUSTED_PROXIES` 定义 Caddy 解析 `X-Forwarded-For` 时可以信任的代理节点。Caddy 会按追加式代理链的推荐方式严格从右向左解析。默认 `private_ranges` 适用于本文档规定的 loopback/私网反代部署；若客户端直接连接 Caddy，应设为 `none`。若 Cloudflare 或其他 CDN 位于 OpenResty 前，应在外层代理规范化真实客户端 IP，或把 CDN 与直接上游代理的全部可信 CIDR 都加入此变量。entrypoint 会拒绝无限制的 `/0` 范围，因为它们会允许任意对端伪造限速键。参见 Caddy 的 [`trusted_proxies`](https://caddyserver.com/docs/caddyfile/options#trusted-proxies) 与 [`trusted_proxies_strict`](https://caddyserver.com/docs/caddyfile/options#trusted-proxies-strict) 文档。

`/healthz` 有意不需要认证，只返回 `ok`，因此 1Panel 和 Docker 可以在没有会话的情况下探测就绪状态。

## 配置参考

### Compose 变量

在 shell 或 Compose 文件旁的 `.env` 中设置这些变量，可以不编辑 Compose 文件就定制部署。

| 变量 | 默认值（轻量 / workstation） | 说明 |
| --- | --- | --- |
| `DSH_IMAGE` | `ghcr.io/okxlin/deepseek-harness:latest` / `:workstation` | 覆盖镜像标签，例如固定日期或版本标签。 |
| `CONTAINER_NAME` | `deepseek-harness` / `deepseek-harness-workstation` | 容器名称。 |
| `RUNTIME_ENV_FILE` | `./image/.env` | 运行时环境文件路径；复制 `image/.env.example` 到这里并编辑。 |
| `BIND_ADDRESS` | `127.0.0.1` | 发布 HTTP 端口的宿主接口。位于 1Panel/OpenResty 后时保持 loopback。 |
| `HOST_PORT` | `56789` | 映射到容器端口 `8080` 的宿主端口。 |
| `DOCKER_SOCK_SRC` | `/dev/null` | Docker socket 源。`/dev/null` 或空值禁用 daemon 访问；`/var/run/docker.sock` 启用访问。 |
| `HOME_VOLUME_NAME` | `dsh-home` | Compose 持久 HOME 卷名称。 |

### 运行时环境变量

复制 `image/.env.example` 到 `RUNTIME_ENV_FILE`，默认为 `image/.env`，并至少设置 `PUBLIC_URL` 和 `AUTH_PASSWORD`。`AUTH_PASSWORD`、`AUTH_PASSWORD_FILE`、`AUTH_PASSWORD_HASH` 三者只能设置一个。

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PUBLIC_URL` | *必填* | 浏览器 origin，例如 `https://dsh.example.com`。拒绝子路径。 |
| `AUTH_MODE` | `caddy-security` | 登录层；`none` 会禁用它，`dsh` 为预留模式并 fail closed。 |
| `AUTH_USERNAME` | `admin` | 单一 DSH 用户。 |
| `AUTH_PASSWORD` | *必填* | 明文密码，至少 12 个字符。 |
| `AUTH_PASSWORD_FILE` | *未设置* | 可读 secret 文件路径，例如 Docker secret。 |
| `AUTH_PASSWORD_HASH` | *未设置* | `bcrypt:<cost>:<hash>`，cost 为 `12-31`。 |
| `AUTH_TOKEN_LIFETIME` | `3600` | 访问 token 和 Cookie 生命周期，范围 `300`-`2592000` 秒。 |
| `CADDY_TRUSTED_PROXIES` | `private_ranges` | 空格分隔的可信代理 CIDR、`private_ranges`，或用于客户端直连的 `none`。 |
| `AUTH_COOKIE_INSECURE` | `false` | 仅用于隔离 HTTP 测试；会移除 `Secure` 和 `HttpOnly`。 |
| `DSH_TRUSTED_HOSTS` | *空* | 逗号分隔的额外 DSH Host authority。 |
| `PORT` | `8080` | Caddy 监听的容器端口；通过 loopback 发布。 |
| `DSH_INTERNAL_PORT` | `3080` | 容器内 DSH loopback 端口。 |
| `GOMEMLIMIT` | `128MiB` | Caddy Go runtime 软内存限制；不限制 DSH 工作负载内存。 |
| `GOMAXPROCS` | `2` | Caddy Go runtime CPU 限制。 |
| `DSH_TELEMETRY_DISABLED` | `1` | 禁用 DSH telemetry。 |

## 通过 IP 地址访问

`PUBLIC_URL` 接受 IP authority；烟雾测试会使用 IPv4 地址和端口验证 HTTPS 代理合约。实际传输层仍决定部署是否安全：

- 当外层代理或其他 TLS 端点提供对该 IP 有效的证书，且 `PUBLIC_URL` 使用相同 origin 时，HTTPS IP origin 可以工作。
- 明文 HTTP IP origin 需要 `AUTH_COOKIE_INSECURE=true`。它没有传输保密性，并且在当前 caddy-security 行为下会同时移除 Cookie 的 `Secure` 和 `HttpOnly`。请仅限隔离测试网络使用。
- Caddy 的 `tls internal` 可以为 IP 创建私有证书，但每个浏览器都必须先信任容器的私有 CA，否则用户会看到证书警告。Caddy 在 <https://caddyserver.com/docs/automatic-https#local-https> 记录了这个本地 CA 行为。

Let's Encrypt 在 2026 年开放了公共 IPv4/IPv6 证书，但证书有效期为 160 小时，并要求 ACME `shortlived` profile：<https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability/>。当前固定的 Caddy 版本支持该 profile，但成功签发仍要求该 IP 上的公开 `http-01` 或 `tls-alpn-01` 校验。本镜像默认模式不启用直接 ACME，因为 1Panel/OpenResty 已经拥有 80/443 和公网 TLS。未来如果加入 direct-TLS 模式，应作为单独显式部署 profile，而不是自动 fallback。

## 认证

默认 `AUTH_MODE=caddy-security` 会使用 `AUTH_USERNAME` 以及下列互斥凭据输入之一创建一个 DSH 用户：

- `AUTH_PASSWORD`：由部署 secret 机制提供的明文密码，至少 12 个字符。
- `AUTH_PASSWORD_FILE`：可读文件，例如 Docker secret。
- `AUTH_PASSWORD_HASH`：精确的 `bcrypt:<cost>:<hash>` 值，cost 匹配 `12-31`。

无需在宿主安装 Caddy 即可生成可接受的 hash：

```bash
password_hash="$({ printf '%s\n' 'replace-this-password'; } | \
  docker run --rm -i --entrypoint caddy \
  ghcr.io/okxlin/deepseek-harness:latest \
  hash-password --algorithm bcrypt --bcrypt-cost 12)"
docker run ... -e "AUTH_PASSWORD_HASH=bcrypt:12:${password_hash}" ...
```

除非按当前 Compose 版本要求转义美元符号，否则不要把 bcrypt hash 直接放入 Compose `.env` 文件。secret 文件更不容易出错。

登录表单会把字段标记为 `autocomplete="username"` 和 `autocomplete="current-password"`，因此浏览器密码管理器可以填充。正常 HTTPS 部署的访问 Cookie 使用 `Secure`、`HttpOnly` 和 `SameSite=Strict`。

`AUTH_TOKEN_LIFETIME` 接受 `300` 到 `2592000` 秒，即 5 分钟到 30 天。它同时控制签名访问 token 生命周期和浏览器 Cookie 生命周期。在固定的 caddy-security 实现中，refresh Cookie 不会自动签发替代访问 token，因此过期后用户需要重新登录。短会话可保留默认 1 小时，个人 workstation 可选择更长但有边界的生命周期。

`AUTH_COOKIE_INSECURE=true` 只用于明确可信、隔离的 HTTP 测试。按当前 caddy-security 行为，它不仅移除 `Secure`，还会移除 `HttpOnly`。

caddy-security 在本地身份库初始化时还会创建一个带随机密码的内部 `webadmin` 记录。DSH 授权策略只允许 `authp/user`；该内部 admin 角色不能访问 DSH。

当前 Caddy 和 caddy-security 依赖由仓库的 [安全扫描策略](../SECURITY_SCAN.md)和 CI 漏洞门禁评估。具体 advisory 结果应查看最新工作流运行，不依赖 README 中的静态快照。

其他模式：

- `AUTH_MODE=none` 禁用登录层，只应在另一个已审查认证边界之后使用。此模式下 Caddy 会把请求作为 loopback 代理转给 DSH，使 Web UI 可以管理设置和凭据；因此，任何能够访问 Caddy 的人也能访问这些特权 API。请保持 `PORT` 私有，并在流量到达容器前强制认证。
- `AUTH_MODE=dsh` 为未来 DSH 原生密码发布预留，目前 fail closed。这可以防止未来原生认证加入后两个认证系统静默叠加。

生成的 JWT 签名密钥在轻量镜像和 workstation 中都存储于 `/data/auth/jwt-secret`。请持久化对应的路径绑定或命名卷；否则每次替换容器都会让现有会话失效。

## 备份与恢复

推荐的轻量部署把状态保存在宿主机路径绑定 `/opt/deepseek-harness/data`，而 workstation
把应用状态也保存在同一个路径绑定、把用户安装工具保存在命名卷 `dsh-home`。这些路径都位于
1Panel 应用安装目录之外，因此普通 1Panel 应用备份不包含它们。创建一致归档前请停止容器，
并通过 1Panel 或宿主文件系统单独备份 `/opt/deepseek-harness/workspace` 路径绑定。

### 轻量镜像

推荐的宿主机路径绑定保存 Caddy、认证、JWT 和 DSH 状态。容器停止后再备份：

```bash
docker stop deepseek-harness

sudo tar -C /opt/deepseek-harness/data \
  -czf /opt/deepseek-harness/deepseek-harness-data.tar.gz .

docker start deepseek-harness
```

只恢复到已停止容器，最好恢复到空的数据目录，并保留现有 `node` 所有权和文件权限：

```bash
docker stop deepseek-harness

sudo tar -C /opt/deepseek-harness/data \
  -xzf /opt/deepseek-harness/deepseek-harness-data.tar.gz

docker start deepseek-harness
```

仓库中的 Compose 文件使用包内的 `./data/data`、`./data/workspace` 和 `dsh-home` 布局。若在仓库本地运行 Compose，请直接备份这些目录。

### Workstation

```bash
docker stop deepseek-harness-workstation

docker run --rm --entrypoint tar \
  -v dsh-home:/source:ro \
  -v "$PWD":/backup \
  ghcr.io/okxlin/deepseek-harness:workstation \
  -C /source -czf /backup/dsh-home.tar.gz .

docker start deepseek-harness-workstation
```

只恢复到已停止 workstation，最好恢复到空 HOME 卷：

```bash
docker run --rm --entrypoint tar \
  -v dsh-home:/target \
  -v "$PWD":/backup:ro \
  ghcr.io/okxlin/deepseek-harness:workstation \
  -C /target -xzf /backup/dsh-home.tar.gz
```

删除容器或执行普通 `docker compose down` 会保留命名卷。`docker compose down --volumes`、
`docker volume rm` 和 `docker volume prune` 可能删除命名卷。绑定到
`/opt/deepseek-harness/data` 的宿主机目录不是 Docker volume，不会被这些命令删除；只有在确认不再需要其中数据后，才应单独删除或替换该宿主机目录。

## 资源使用

当前 amd64 认证烟雾测试稳定在约 `167-180 MiB` 和约 `20-21` 个 PID。workstation 工具链空闲时不会显著提高内存，但会提高磁盘占用：当前本地 amd64 Docker size 在 registry 压缩前约为轻量镜像 `670-700 MB`、workstation `2.1-2.2 GB`，具体取决于解析到的 DSH 版本。Debian 重建可能改变这些数字。

CI 对空闲流程的上限仍为 `256 MiB`。这不是工作负载限制：终端、仓库、语言服务器、编译器和模型工具可能需要更多内存。

`GOMEMLIMIT=128MiB` 和 `GOMAXPROCS=2` 只限制 Caddy 的 Go runtime。如果 1Panel 需要容器内存限制，轻量镜像建议从 `512 MiB` 开始，workstation 至少从 `1 GiB` 开始，再按观测工作负载调整，不要把 Caddy 限制当成整个容器预算。

## 验证

运行完整 amd64 合约：

```bash
deepseek-harness-builder/scripts/smoke-test.sh \
  --image deepseek-harness:local \
  --profile full \
  --variant runtime
```

测试使用临时宿主 bind 的 `/data`，以及 HOME 和 workspace 的命名测试卷。workstation 会把 HOME 直接挂到 `/home/node`，把测试 workspace 直接挂到 `/workspace`；它会模拟 1Panel/OpenResty 头，并检查登录重定向、浏览器自动填充属性、错误密码拒绝、受保护 Cookie、伪造 identity header、两个 DSH WebSocket、登出、loopback 绑定、secret 隔离、JWT 状态持久化、容器重建持久化、目录选择器默认打开 `/workspace`、资源使用、fail-closed 配置错误、Node.js 包管理器合约和所选镜像变体。

如果认证由外部反向代理承担，还应运行透传合约：

```bash
deepseek-harness-builder/scripts/passthrough-smoke-test.sh \
  --image deepseek-harness:local \
  --public-url https://dsh.example.test
```

它会以 `AUTH_MODE=none` 启动镜像，使用浏览器 origin 的 `Host` 和 `Origin` 头通过 Caddy 请求，然后验证 settings 和 credentials API 能成功到达 DSH，并验证 Caddy 在规范化上游请求前拒绝不匹配的浏览器 `Origin`。此测试本身不提供认证；外部代理必须在请求进入容器前强制认证。

运行轻量 Compose 合约：

```bash
deepseek-harness-builder/scripts/check-compose.sh
```

它会证明包内状态 bind 挂载到 `/data`、包内 workspace 挂载到 `/workspace`、默认 socket 源是 `/dev/null`、启用源是 `/var/run/docker.sock`，并且 HTTP 端口保持 loopback 绑定。

运行两个 workstation 合约：

```bash
deepseek-harness-builder/scripts/check-workstation-compose.sh

deepseek-harness-builder/scripts/smoke-test.sh \
  --image deepseek-harness-workstation:local \
  --profile full \
  --variant workstation

deepseek-harness-builder/scripts/workstation-smoke-test.sh \
  --image deepseek-harness-workstation:local
```

Compose 合约检查会解析 socket 开关的两种状态，并证明包内状态 bind 直接挂载到 `/data`、一个命名卷直接挂载到 `/home/node`、包内 workspace 直接挂载到 `/workspace`、默认 socket 源是 `/dev/null`、启用源是 `/var/run/docker.sock`，且 HTTP 端口保持 loopback 绑定。workstation 专用镜像测试会编译并运行 C、C++、Go 探针，创建 Python 虚拟环境，验证 checksum 固定的 actionlint、yq、uv/uvx 和 Ruff，检查普通和登录 shell 的 PATH 行为，验证 CLI 集合，确认 Rust 和 Cargo 保持缺席，确认所有 Docker 客户端二进制文件都使用已固定的 Go 工具链且不包含旧 daemon 模块，确认 Docker 默认没有 daemon 访问，使用隔离 Unix socket 刻画可选 socket group 映射，验证镜像只声明 `/home/node`，并确认 HOME、应用状态和 workspace 都是真实可写目录而不是符号链接。它还会在 `no-new-privileges` 下运行已安装的 DSH sandbox executor：`workspace-write` 必须允许项目写入并拒绝 workspace 外可写路径，而显式 `danger-full-access` 重试必须允许外部写入且不增加容器特权。

构建镜像后运行 Caddy 漏洞门禁：

```bash
deepseek-harness-builder/scripts/check-caddy-vulnerabilities.sh \
  --image deepseek-harness:local
```

Caddy 生产二进制文件已 stripped。Go 文档说明，在没有可提取符号的二进制扫描中，扫描器可能退回到 required module 的所有漏洞：<https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck#hdr-Limitations>。因此门禁只在 `GO-2026-5932` 是唯一 finding、符号不可用、且构建产出的包清单证明没有链接 OpenPGP 包时接受它。任何额外 finding 都会失败。

两个 arm64 CI lane 使用 QEMU 在可发布多平台镜像前验证原生 `node-pty` 构建、Caddy 插件模块、认证流程、架构和 loopback 边界。workstation lane 也会在 arm64 上运行编译器探针。由于 Landlock enforcement 取决于宿主内核且在 QEMU user-mode emulation 下不可靠，该 lane 只明确跳过 DSH sandbox enforcement 探针；amd64 workstation lane 仍运行完整探针。

## 升级行为

两个镜像变体都必须挂载 `/data`。升级旧 workstation 部署时，首次启动请保留原有的
`/home/node` 卷或直接挂载的 `/home/node/.local/share/deepseek-harness`，同时新增
`/data` 挂载。如果新的认证状态为空，entrypoint 会把旧 workstation 应用状态复制到
`/data`。确认迁移数据后，后续容器仍必须挂载 `/data`；旧路径不能替代它。

Caddy 和 caddy-security 会一起编译并固定版本。不能假设只更新 Caddy 是安全的。定时发布工作流会解析 npm 中 `@deepseek-ai/dsh` 已发布的最高 SemVer，在构建 workspace 中临时更新 `package.json` 和 `pnpm-lock.yaml`，把解析出的版本作为 Docker `DSH_VERSION` 构建参数，并把 `runtime` target 发布为 `latest` 加 `<DSH_VERSION>`，把 `workstation` target 发布为 `workstation` 加 `<DSH_VERSION>-workstation`。手动运行可以覆盖 DSH 包准确版本或 dist-tag，也可覆盖最终镜像标签，同时保留相同验证和可选浮动标签行为。每个工作流都会先审计冻结的 pnpm 生产依赖树、重建并验证插件、运行 Caddy 依赖图和 `govulncheck` 门禁，并执行 amd64 和 arm64 烟雾合约，然后才把验证过的多平台 manifest 推送到 GHCR 和 Docker Hub。runtime 发布继续应用零可修复 HIGH/CRITICAL Trivy 门禁；工具链范围更广的 workstation 会阻断可修复 CRITICAL，并报告可修复 HIGH 供确定性审查，同时由每日组件检查发现新的上游版本。任一 registry 登录或发布失败，工作流都会失败，而不是报告完整发布。
