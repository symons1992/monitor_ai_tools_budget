# CodexBar

CodexBar 是一个原生 macOS 菜单栏应用，同时显示 Codex、Claude Code 和 Google Antigravity CLI（agy）的剩余额度。

## 早期版本界面预览

![早期版本的 Codex 额度界面](./example.png)

## 功能

- 菜单栏并排显示三个工具的剩余百分比，例如 `Cx 99 · Cl 96 · Ag 100`，没有数据时显示 `--`
- 下拉菜单按工具显示套餐、各窗口的已用和剩余比例、重置时间及更新时间。agy 按组展示额度，包含共享额度的 Gemini 模型
- Codex 每 5 秒读取本地日志，Claude Code 和 agy 每 60 秒查询额度，也可点击“立即刷新”
- 支持 Codex 返回的主要/次要额度和额外点数
- 自动识别 `~/.codex/sessions`，也支持 `CODEX_HOME`
- 无 Dock 图标，原生 AppKit，macOS 13 及以上

## 构建与运行

只需要 Apple Command Line Tools，不要求安装完整 Xcode：

```bash
./scripts/run.sh
```

`scripts/swift.sh` 会自动选择本机可用的 macOS SDK，兼容 Command Line Tools 中编译器与最新 SDK 小版本暂时不同步的情况。

打包成 `.app`：

```bash
./scripts/package-app.sh
open ./dist/CodexBar.app
```

安装到 `~/Applications`：

```bash
./scripts/install.sh
```

安装并设置登录时自动启动：

```bash
./scripts/install.sh --login
```

卸载（应用与启动项会移动到废纸篓）：

```bash
./scripts/uninstall.sh
```

## 第一次没有数据显示？

Codex 只有在完成请求并收到服务端额度状态后才会把 `rate_limits` 写入任务日志。先在 Codex Desktop 或 Codex CLI 中运行一次普通任务，再点击菜单中的“立即刷新”。

如果 Claude Code 或 agy 提示登录已失效，在终端运行对应的 `claude` 或 `agy` 并登录，再点击“立即刷新”。

## 数据边界

- Codex 的额度来自本机任务日志的 `rate_limits` 字段，数值随 Codex 写入日志的额度快照更新。
- Claude Code 和 agy 的额度来自各自的线上接口。CodexBar 从 macOS 钥匙串读取已登录 CLI 的访问令牌，仅发送给各自的额度接口。令牌不落盘、不写日志。
- Claude Code 和 agy 的额度接口未公开。登录失效或额度查询失败时，菜单会显示原因。
