# 合盖助手 (Clamshell Assistant)

一个 macOS 菜单栏小工具，一键切换 Reminal 的合盖运行模式，让 Mac 合上盖子后继续跑 Agent 任务。

本应用已内置未经修改的 [Reminal](https://github.com/harshalgajjar/Reminal) 3.19.4，下载安装后即可使用，无需再单独安装 Reminal。

## 功能

- **开启**：关闭系统睡眠（`pmset -a disablesleep 1`），打开 Reminal 的 `closed-lid` 和 `always-unlocked`，并确保 `lid-agent` 会话在运行。
- **关闭**：恢复上述设置。
- 不调亮度、不关屏幕；合盖后内建屏幕是真的关掉。

## 安装

1. 从 [Releases](https://github.com/mehejun876-del/clamshell-assistant/releases) 下载 `ClamshellAssistant-1.1-macOS.zip`，解压后把「合盖助手.app」拖进「应用程序」。
2. 本应用未经过 Apple 公证。第一次打开时，请按住 Control 键单击（或右键单击）应用，选择「打开」，再在提示里确认打开；也可以在「系统设置 › 隐私与安全性」里点「仍要打开」。
3. 如需开机自动启动，请到「系统设置 › 通用 › 登录项」里把「合盖助手」加上。
4. 仅支持 Apple 芯片（Apple silicon）的 Mac，不支持 Intel。

首次切换合盖模式时会请求管理员密码，写入一条只允许 `pmset -a disablesleep 0/1` 的 sudoers 规则。

## 动画与性能

- 菜单栏图标是单色模板图：关闭时是 MacBook Pro，开启时屏幕合上并过渡成 Mac Studio，反向同理；状态灯点亮时带光环扩散。
- 60fps 播放，动画只在切换时存在，结束即释放；空闲 CPU 0%，内存约 14MB，支持「减弱动态效果」。

## 致谢 / 使用的开源项目

本应用打包并调用了 [Reminal](https://github.com/harshalgajjar/Reminal)（作者 [harshalgajjar](https://github.com/harshalgajjar)，版本 3.19.4，许可证 [AGPL-3.0](https://github.com/harshalgajjar/Reminal/blob/v3.19.4/LICENSE)）。打进安装包的是未经修改的官方构建，源代码见该仓库的 [`v3.19.4`](https://github.com/harshalgajjar/Reminal/tree/v3.19.4) 标签。合盖助手用它来开关合盖运行模式（`closed-lid`、`always-unlocked`）并管理 `lid-agent` 会话。详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

本项目因包含 Reminal，同样以 GNU Affero General Public License v3.0 发布，完整文本见 [LICENSE](LICENSE)。

## 从源码构建

需要 Xcode 命令行工具，以及一台已安装 Reminal 的 Mac（默认读取 `~/Applications/reminal.app`，也可用环境变量 `REMINAL_APP` 指定路径）。

```sh
./build.sh
```

脚本会把 Reminal 和许可证文件一并打进应用包，安装到 `~/Applications`，并注册开机自启。
