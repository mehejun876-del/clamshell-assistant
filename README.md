# 合盖助手 (Clamshell Assistant)

一个 macOS 菜单栏小工具，一键切换 Reminal 的合盖运行模式，让 Mac 合上盖子后继续跑 Agent 任务。

本应用已内置未经修改的 [Reminal](https://github.com/harshalgajjar/Reminal) 3.19.4，下载安装后即可使用，无需再单独安装 Reminal。

## 功能

- **开启**：关闭系统睡眠（`pmset -a disablesleep 1`），打开 Reminal 的 `closed-lid` 和 `always-unlocked`，并确保 `lid-agent` 会话在运行。
- **关闭**：把上述三项开关关闭；不会终止既有的 `lid-agent` 远程终端会话。会话自身的防空闲睡眠可能继续存在，这不等于禁止合盖睡眠。
- Reminal 的合盖功能还会在无物理显示器时按需创建虚拟显示器，并在合盖时调暗内建屏幕、开盖时恢复；并不是助手自己调用显示器电源开关。
- `always-unlocked` 会阻止显示器空闲休眠/自动锁屏，并不绕过手动锁屏或登录认证。开启合盖模式同时开启这一项，注意隐私、散热及电池消耗，运行时不要放进包内。

## 安装

1. 从 [Releases](https://github.com/mehejun876-del/clamshell-assistant/releases) 下载 `ClamshellAssistant-1.1-macOS.zip`，解压后把「合盖助手.app」拖进「应用程序」。
2. 本应用未经过 Apple 公证。第一次打开时，请按住 Control 键单击（或右键单击）应用，选择「打开」，再在提示里确认打开；也可以在「系统设置 › 隐私与安全性」里点「仍要打开」。
3. 如需开机自动启动，请到「系统设置 › 通用 › 登录项」里把「合盖助手」加上。
4. 仅支持 Apple 芯片（Apple silicon）的 Mac，不支持 Intel。

首次切换合盖模式时会请求管理员密码，写入一条只允许 `pmset -a disablesleep 0/1` 的 sudoers 规则。

## 动画与性能

- 菜单栏图标是单色模板图：关闭时是 MacBook Pro，开启时屏幕合上并过渡成 Mac Studio，反向同理；状态灯点亮时带光环扩散。
- 60fps 播放，动画只在切换时存在，结束即释放；不设置永久轮询定时器，支持「减弱动态效果」。实际 CPU/内存以当前版本实测为准。

## 致谢 / 使用的开源项目

本应用打包并调用了 [Reminal](https://github.com/harshalgajjar/Reminal)（作者 [harshalgajjar](https://github.com/harshalgajjar)，版本 3.19.4，许可证 [AGPL-3.0](https://github.com/harshalgajjar/Reminal/blob/v3.19.4/LICENSE)）。打进安装包的是未经修改的官方构建，源代码见该仓库的 [`v3.19.4`](https://github.com/harshalgajjar/Reminal/tree/v3.19.4) 标签。合盖助手用它来开关合盖运行模式（`closed-lid`、`always-unlocked`）并管理 `lid-agent` 会话。详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

本项目因包含 Reminal，同样以 GNU Affero General Public License v3.0 发布，完整文本见 [LICENSE](LICENSE)。

## 从源码构建

需要 Xcode 命令行工具，以及一台已安装 Reminal 的 Mac（默认读取 `~/Applications/reminal.app`，也可用环境变量 `REMINAL_APP` 指定路径）。

```sh
./build.sh
```

脚本仅构建 `build/合盖助手.app`（可用 `APP_OUTPUT` 指定目标），包含 Reminal 及其许可证。不会修改 LaunchAgent、电源设置或 Reminal 偏好；安装/重启需单独操作。

## 本机修复 1.2（未发布）

- 串行读取和切换；切换期间禁用按钮并拒绝重复操作，丢弃切换前的过期读取。
- 状态读取检查退出码、使用空白不敏感的字段解析；读取失败明确显示未知并保留上次图标，不再误报正常模式。
- 登录/唤醒、显示器变化、Reminal 设置文件变化时刷新；会话恢复期间最多补读三次，没有永久轮询。
- 动画中收到相反状态时，先完成当前单设备变形再转向最新状态，避免从错误端点跳变；唤醒/屏幕变化会清理悬挂的动画图层。
- 外部命令有超时，并使用文件缓冲避免管道阻塞；读取会话失败不会盲目新建同名会话。
- 仍然优先使用 `~/.local/bin/reminal`，不存在时才用内置版本。

非侵入回归测试（切换命令全部替身模拟，不改电源设置）：

```sh
swiftc -D SELFTEST -Osize -wmo main.swift State.swift Tests.swift -o /tmp/clamshell-tests
/tmp/clamshell-tests
# VERIFY_LIVE=1 /tmp/clamshell-tests  # 额外只读检查本机当前状态
```

Reminal 是完整的远程访问软件，具有终端共享、远程窗口/桌面查看和控制、文件传输、端口转发等功能，并非单纯的合盖工具。助手没有为这些功能提供额外菜单，但会创建供 Reminal 使用的后台终端会话；不能把它描述成完全不涉及远程访问的纯本地工具。
