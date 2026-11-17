# 合盖助手 (Clamshell Assistant)

一个 macOS 菜单栏小工具，一键切换合盖运行模式，让 Mac 合上盖子后继续跑 Agent 任务。

本应用内置 [Reminal](https://github.com/harshalgajjar/Reminal) 3.19.4 的**合盖精简版**（源码在 [`ThirdParty/reminal-lid`](ThirdParty/reminal-lid)），只保留合盖相关功能，已去掉全部远程功能，无需再单独安装 Reminal。

## 功能

- **开启**：关闭系统睡眠（`pmset -a disablesleep 1`），打开 `closed-lid` 和 `always-unlocked`，并在助手运行期间启动本地合盖服务（`reminal service`）。
- **关闭**：把上述三项关闭并停止合盖服务。
- 合盖服务等价替代原来的 `lid-agent` 远程会话里与合盖有关的部分：`closed-lid` 开时防止空闲睡眠（`caffeinate -i`），`always-unlocked` 开时防止显示器空闲休眠/自动锁屏（`caffeinate -d`）；无物理显示器时按需创建虚拟显示器，合盖时调暗内建屏幕、开盖时恢复。退出助手会释放这些防休眠项（`disablesleep` 是系统设置，会保留）。
- **图标**：设备形状表示合盖工作模式——`closed-lid` 开启是 Mac Studio，关闭是 MacBook；切换模式时播放原来的完整设备变形、亮灯和扩散光环。状态灯表示模式是否全部就绪（三项开关 + 合盖服务），实际盖子开合在菜单单独显示。未就绪时菜单会列出缺了什么；状态读取失败会明确提示并保留上次图标，不会伪装成正常。
- **合盖时外接显示器**（菜单可选，默认「保持亮着」）：选「熄屏，Mac 继续工作」后，每次合盖且模式就绪、接有外接显示器时，助手执行一次系统显示器睡眠（`pmset displaysleepnow`）。这是系统的显示器睡眠，不是把亮度调成 0；按键盘、动鼠标会把屏幕唤醒（`always-unlocked` 开着时之后不会再自动熄灭）。选择本身不会立刻改变任何屏幕或电源状态。
- `always-unlocked` 不绕过手动锁屏或登录认证。注意隐私、散热及电池消耗，运行时不要放进包内。

## 安装

1. 从 [Releases](https://github.com/mehejun876-del/clamshell-assistant/releases) 下载最新 zip，解压后把「合盖助手.app」拖进「应用程序」。
2. 本应用未经过 Apple 公证。第一次打开时，请按住 Control 键单击应用选择「打开」；也可以在「系统设置 › 隐私与安全性」里点「仍要打开」。
3. 如需开机自动启动，请到「系统设置 › 通用 › 登录项」里把「合盖助手」加上。
4. 仅支持 Apple 芯片的 Mac。

首次切换合盖模式时会请求管理员密码，写入一条只允许 `pmset -a disablesleep 0/1` 的 sudoers 规则。

## 精简版 Reminal 保留/去掉了什么

- 保留（逻辑原样复制）：`closed-lid`/`always-unlocked` 设置（同一个 `~/.reminal/settings.json`）、防睡眠、内屏调暗 `liddim`、虚拟显示器 `vdisplay` 及其协调逻辑。
- 去掉：远程终端与会话、中继联网、远程窗口/桌面查看与控制、文件传输、端口转发、账号/设备配对、自动升级、MCP/Agent 集成；也不再需要 `lid-agent` 会话。
- 如果本机另外装了完整版 Reminal，它们共用设置文件；虚拟显示器/调暗由已运行的 Reminal 守护进程优先负责，精简版自动让位。

## 动画与性能

- 单色模板图标，启用/关闭合盖模式时 MacBook 与 Mac Studio 互相变形，状态灯点亮带光环；60fps 播放，只在变化时存在，无永久轮询（盖子用系统事件通知），支持「减弱动态效果」。

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
