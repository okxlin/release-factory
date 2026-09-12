# gemini-skill-browser-builder

这个目录按 `okxlin/release-factory` 的真实仓库布局放置：

- 与 `1panel-builder/` 平级
- 只承载 `gemini-skill-browser` 的 kasm 版镜像构建发布内容
- GitHub Actions workflow 仍放在仓库根下的 `.github/workflows/`

## 目录说明

- `configs/architectures.sh`：维护当前允许发布的平台
- `scripts/resolve-build-params.sh`：把 workflow 输入收敛成最终镜像 tag、base tag 和 build args
- `configs/components.json`：两种浏览器共用的来源、维护通道和安全补丁版本
- `image/`：运行文件；Docker 构建上下文为仓库根目录
  - `Dockerfile`
  - `.env.example`
  - `scripts/`
  - `supervisor/`

## 当前策略

- 当前只发布 `linux/amd64`
- 默认镜像仓库名：`ghcr.io/<owner>/gemini-skill-browser`
- workflow 支持手动构建、每周刷新和按路径触发的 PR 验证
- 底座默认跟随 `components.json` 的 Kasm 周更新通道；手动输入仍可覆盖 tag
- 发布 tag 为 `<底座 tag>-kasm`；周更新维护 `latest-kasm`，手动构建可选择是否更新该别名
- 解析器先固定底座和 Node 24 镜像 digest、应用提交；两种浏览器复用受控 npm 锁文件
- Kasm 桌面和 daemon 以 `kasm-user` 运行；发布前验证桌面、CDP、截图和 Cookie 持久化

## 本地构建

在仓库根目录执行：

```bash
python3 gemini-skill-browser-builder/scripts/resolve-browser-inputs.py --variant kasm --output /tmp/gemini-kasm-inputs.json
docker build -f gemini-skill-browser-builder/image/Dockerfile \
  --build-arg BASE_IMAGE="$(jq -r .base_image /tmp/gemini-kasm-inputs.json)" \
  --build-arg NODE_IMAGE="$(jq -r .node_image /tmp/gemini-kasm-inputs.json)" \
  --build-arg GEMINI_SKILL_REF="$(jq -r .gemini_skill_ref /tmp/gemini-kasm-inputs.json)" \
  -t gemini-kasm:local .
python3 scripts/smoke-gemini-browser.py gemini-kasm:local kasm
```

## PR reviewer 该看什么

- `build-gemini-skill-browser.yml` 与 `release-gemini-browser.yml`：固定输入、PR 门禁、发布摘要绑定
- `image/Dockerfile`：底座是否固定为 `kasmweb/edge`
- `image/scripts/bootstrap.sh` + `image/supervisor/gemini-skill.conf`：是否确保 Kasm 与 daemon 共存启动
