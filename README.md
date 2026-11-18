# 合盖助手 (Clamshell Assistant)

一个 macOS 菜单栏小工具，一键切换合盖运行模式，让 Mac 合上盖子后继续跑 Agent 任务。

本应用内置 [Reminal](https://github.com/harshalgajjar/Reminal) 3.19.4 的**合盖精简版**（源码在 [`ThirdParty/reminal-lid`](ThirdParty/reminal-lid)），只保留合盖相关功能，已去掉全部远程功能，无需再单独安装 Reminal。

## 功能

- **开启合盖运行**：关闭系统睡眠（`pmset -a disablesleep 1`），打开合盖与保持解锁，并在助手运行期间启动本地合盖服务。
- **关闭合盖运行**：把上述三项关闭并停止合盖服务。
- 合盖服务会在合盖相关设置打开时防止空闲睡眠（`caffeinate -i`）和显示器空闲休眠/自动锁屏（`caffeinate -d`）；无物理显示器时按需创建虚拟显示器，合盖时调暗内建屏幕、开盖时恢复。退出助手会释放这些防休眠项（系统禁睡眠设置会保留）。
- **菜单栏图标**：合盖运行中是 Mac Studio 且状态灯亮起，正常模式是 MacBook。开关成功时播放原来的设备变形、亮灯和扩散光环。读取失败会显示「状态暂不可用」并保留上次图标。
- **只有开或关，没有“部分开启”**：助手记住你最后选的是开还是关。合盖模式、保持解锁、系统禁止睡眠三项里任何一项被别的程序（例如 UU远程的“保持唤醒”、独立 Reminal 命令行）改掉，助手会在刷新、唤醒、启动或检测到设置变化时自动改回，不弹密码框；改不回来就直接报错并指明是哪一项，例如「开启失败：保持解锁未生效」「未完全关闭：系统禁止睡眠仍开着」。被反复改回时 2 分钟内最多自动恢复 3 次，然后停下报错，点「刷新状态」会再试。
- 从旧版升级后、还没按过开关时，助手以 Reminal 的两项设置为准，不会自动写入；点一次开关或「刷新状态」后才记住选择。
- 菜单只有当前状态、一个开启或关闭按钮、刷新状态和退出助手。
- 保持解锁不绕过手动锁屏或登录认证。注意隐私、散热及电池消耗，运行时不要放进包内。

应用图标采用与菜单栏合盖态相同的单色 Mac Studio 外形。菜单栏图标仍按模式切换，不会始终显示主机。

## 安装

1. 从 [Releases](https://github.com/mehejun876-del/clamshell-assistant/releases) 下载最新 zip，解压后把「合盖助手.app」拖进「应用程序」。
2. 本应用未经过 Apple 公证。第一次打开时，请按住 Control 键单击应用选择「打开」；也可以在「系统设置 › 隐私与安全性」里点「仍要打开」。
3. 如需开机自动启动，请到「系统设置 › 通用 › 登录项」里把「合盖助手」加上。
4. 仅支持 Apple 芯片的 Mac，需要 macOS 14 或更高版本。

首次切换合盖模式时会请求管理员密码，写入一条只允许 `pmset -a disablesleep 0/1` 的 sudoers 规则。

## 精简版 Reminal 保留/去掉了什么

- 保留（逻辑原样复制）：合盖 / 保持解锁设置（同一个 `~/.reminal/settings.json`）、防睡眠、内屏调暗、虚拟显示器及其协调逻辑。
- 去掉：远程终端与会话、中继联网、远程窗口/桌面查看与控制、文件传输、端口转发、账号/设备配对、自动升级、MCP/Agent 集成；也不再需要远程合盖会话。
- 如果本机另外装了完整版 Reminal，它们共用设置文件；虚拟显示器/调暗由已运行的 Reminal 守护进程优先负责，精简版自动让位。

## 从源码构建

需要 Xcode 命令行工具和 Go 1.26（或用 `REMINAL_LID_BIN` 指向从 `ThirdParty/reminal-lid` 交叉编译的 darwin/arm64 二进制）。

```sh
./build.sh
```

只构建 `build/合盖助手.app`，不修改 LaunchAgent、电源设置或 Reminal 偏好。

非侵入回归测试（写操作全部替身模拟）：

```sh
swiftc -D SELFTEST -Osize -wmo main.swift State.swift Tests.swift -o /tmp/clamshell-tests
/tmp/clamshell-tests
```

## 致谢 / 许可证

本应用包含修改过的 [Reminal](https://github.com/harshalgajjar/Reminal)（作者 [harshalgajjar](https://github.com/harshalgajjar)，3.19.4，[AGPL-3.0](https://github.com/harshalgajjar/Reminal/blob/v3.19.4/LICENSE)），修改说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，每个修改过的文件都有标注。本项目同样以 GNU AGPL v3.0 发布，见 [LICENSE](LICENSE)。
