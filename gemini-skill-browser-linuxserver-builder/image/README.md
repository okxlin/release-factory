# gemini-skill-browser-linuxserver image

基于 `linuxserver/chrome` 的镜像构建上下文。

## 设计

- 底座：`lscr.io/linuxserver/chrome:147.0.7727`
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
