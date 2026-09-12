# gemini-skill-browser-linuxserver image

基于 `linuxserver/chrome` 的运行文件；构建上下文是仓库根目录。

## 设计

- 底座：解析 `linuxserver/docker-chrome` 最新稳定 release 后固定的 `docker.io/linuxserver/chrome` digest
- Web 访问端口：`3001`
- Web 登录：`CUSTOM_USER` / `PASSWORD`
- 通过覆盖 `/usr/bin/wrapped-chrome` 注入远程调试参数
- 通过 s6 新增 `svc-gemini-skill-daemon`，让 `gemini-skill` daemon 与桌面基座并行启动

## 关键环境变量

- `CUSTOM_USER`
- `PASSWORD`
- `BROWSER_DEBUG_PORT`（默认 `9222`）
- `BROWSER_USER_DATA_DIR`（默认 `/config/browser-profile`）
- `DAEMON_PORT`（默认 `40225`）
- `OUTPUT_DIR`（默认 `/output`）
