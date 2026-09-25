# Changelog

## [1.1.1] - 2026-09-25

### Fixed / 修复
- Menu bar panel: clicking the icon again closes it, choosing Settings… closes it too, and buttons respond to the first click.
  菜单栏面板：再次点击图标会收起；点「设置…」后面板也会收起；按钮第一下点击就有反应。
- Antigravity 2.x quota: the local language server was renamed, so AI Dock couldn't find it. The weekly limits are now read as well.
  Antigravity 2.x 的额度：新版本地服务改了名字，之前找不到；现在也能读到每周限额。
- Gemini CLI running state: the CLI runs as a node process and is now recognized from its script path.
  Gemini 命令行的运行状态：它以 node 进程运行，现在按脚本路径识别。

### Added / 新增
- Apps that have quit but still have processes running in the background (for example Cursor's agent) get a dimmed indicator dot, like the system Dock.
  已经退出、但还有子进程在后台运行的 App（比如 Cursor 的 agent），指示灯显示为半透明，和系统 Dock 一样。

### Changed / 改进
- The last plan limits read stay on screen when the tool is closed or offline, and windows past their reset time show as reset.
  工具关闭或暂时连不上时，继续显示上次读到的额度；过了重置时间的按已重置显示。
- Gemini: Google moved the quota of personal accounts to Antigravity, so the Gemini widget shows the Gemini models quota from Antigravity (same Google account only).
  Gemini：Google 已把个人账号的额度移到 Antigravity，Gemini 小组件改为显示 Antigravity 中 Gemini 模型的额度（仅限同一个 Google 账号）。
- Antigravity "working" status comes from its conversation files being written.
  Antigravity 的「工作中」状态来自它的会话文件写入。
- Widgets with more than two limits show the two most-used ones as rings.
  额度超过两项的小组件，圆环显示用得最多的两项。

## [1.1.0] - 2026-09-25

### Added / 新增
- AI widgets can be dragged to reorder, or placed between apps (e.g. Claude · WeChat · Cursor · QQ); among apps they take an icon's size and magnify with the icons.
  AI 小组件可以拖动排序，也可以放到 App 之间（如 Claude、微信、Cursor、QQ 穿插）；放在 App 之间时和图标一样大，并跟着一起放大。
- Plan limits for Antigravity (from its local language server) and Gemini (Gemini Code Assist).
  新增 Antigravity（读取其本地服务）和 Gemini（Gemini Code Assist）的套餐额度。
- Three-state status dot on widgets: working (bright), open (dim), not running (hollow).
  小组件三态状态点：工作中（亮）、已打开（暗）、未打开（空心）。
- Official brand logos are bundled.
  内置官方品牌标志。

### Changed / 改进
- When a quota can't be read, the widget shows usage time instead of an error, with the reason in its popover.
  读不到额度时改为显示使用时长，不显示报错，原因写在详情里。
- CLIs and config dirs are found through the login shell environment and common install locations (nvm, fnm, Volta, pnpm, Bun, asdf, mise…).
  通过登录 shell 环境和常见安装位置查找命令行工具和配置目录。
- "Working" now means the AI is producing output; having an app in front no longer counts.
  「工作中」只看 AI 是否在输出，App 在前台不再算。
- Launch bounce uses a gravity-style arc and lands before stopping.
  启动跳动改为抛物线弹跳，启动完成后落地再停。

### Fixed / 修复
- Clicking the menu bar icon again now closes the panel instead of reopening it.
  再次点击菜单栏图标会收起面板，而不是重新打开。

## [1.0.0] - 2026-09-25

First public release. 首个公开版本。

### Added / 新增
- Dock replacement that matches the system Dock: magnification, labels, launch bounce, drag to reorder / add / remove, file drops, recent apps, Trash.
  与系统 Dock 一致的替代 Dock：放大、名称标签、启动跳动、拖动排序/添加/移除、文件拖放、最近使用的 App、废纸篓。
- Native-style context menus (system wording in every language, callout, ⌥ alternates, keyboard navigation).
  原生样式右键菜单（各语言使用系统原文、带尖角、⌥ 切换、键盘操作）。
- Auto-hide using the system Dock's timing; hides in full screen, shows when you push the pointer to the bottom edge.
  自动隐藏沿用系统 Dock 的节奏；全屏时隐藏，鼠标推到底边会出现。
- Plan-limit rings for Claude Code, ChatGPT/Codex and Cursor, with automatic token renewal for Claude and Codex.
  Claude Code、ChatGPT/Codex、Cursor 套餐额度圆环；Claude、Codex 登录令牌自动续期。
- AI activity chart (active time or tokens, 24 h / 7 d), auto-detection of 30 AI tools, local models, API balances.
  AI 活动图（使用时长或 Token，24 小时/7 天），自动识别 30 种 AI 工具，本地模型，API 余额。
- Menu bar panel, tabbed settings, 8 UI languages.
  菜单栏面板、分页设置、8 种界面语言。
