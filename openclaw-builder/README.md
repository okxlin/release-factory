# OpenClaw Sandbox 构建

从 `openclaw/openclaw` 最新稳定 release 的确定提交构建，发布仓库为
`ghcr.io/okxlin/openclaw-sandbox`，标签为 `<上游 release>-sandbox` 和 `latest`。

`configs/components.json` 统一记录 Node 维护通道、npm、Docker CLI/Compose 源码和 Go 工具链，
以及内嵌依赖补丁和测试镜像。正常版本维护先改清单，Dockerfile 的安装逻辑由
`scripts/apply-openclaw-runtime-hardening.sh` 根据上游构建阶段生成。

每日 workflow 使用 Registry Bearer 认证读取已发布镜像。只有 404 表示不存在；认证、网络及元数据
校验失败会停止。上游提交、基础镜像 digest、构建配方变化或构建满七天都会触发重建；
手动输入 `force_rebuild=true` 可强制重建。解析结果随 CI 保留，包含本次确定的输入和重建原因。

验证在原生 amd64 runner 上完成：网关启动、错误 token 拒绝、带凭据的健康查询，以及 OpenClaw
实际创建、执行、列出和重建沙箱。测试使用独立 Docker daemon、临时命名卷和无网络沙箱，
不会把宿主 Docker socket 交给应用。该测试不调用外部模型。arm64 尚未纳入此镜像的发布范围。

Copilot 平台包内的 Foundry SDK 自带 `adm-zip`，无法通过 OpenClaw 的 pnpm override 更新。
构建只替换其中受影响的 0.5.17 副本，使用 SHA-512 固定的 MIT 许可版 0.6.0；保留许可和补丁记录。
回归检查覆盖正常 ZIP 读取，并阻止伪造大小字段触发巨额预分配：
<https://github.com/advisories/GHSA-xcpc-8h2w-3j85>。

镜像扫描采用 `configs/trivy-policy.json`：可修复 CRITICAL 阻断，应用目录的 HIGH/CRITICAL 阻断，
其余开发工具和系统包 HIGH 保留报告。测试和扫描通过后发布同一个镜像摘要，不再二次构建。

本地可先运行以下检查，再按解析出的 `build_args` 构建上游检出目录：

```bash
python3 scripts/test-resolve-openclaw-inputs.py
bash scripts/test-apply-openclaw-runtime-hardening.sh
python3 scripts/resolve-openclaw-inputs.py --output /tmp/openclaw-inputs.json
# 上游目录必须检出为 openclaw-inputs.json 中的 upstream_sha
bash scripts/apply-openclaw-runtime-hardening.sh /path/to/openclaw-src
python3 scripts/smoke-openclaw.py your-local-image
```
