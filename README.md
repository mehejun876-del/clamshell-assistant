# 合盖助手 (Clamshell Assistant)

一个 macOS 菜单栏小工具，一键切换 Reminal 的合盖运行模式，让 Mac 合上盖子后继续跑 Agent 任务。

## 功能

- **开启**：关闭系统睡眠（`pmset -a disablesleep 1`），打开 Reminal 的 `closed-lid` 和 `always-unlocked`，并确保 `lid-agent` 会话在运行。
- **关闭**：恢复上述设置。
- 不调亮度、不关屏幕；合盖后内建屏幕是真的关掉。

## 动画与性能

- 菜单栏图标是单色模板图：关闭时是 MacBook Pro，开启时屏幕合上并过渡成 Mac Studio，反向同理；状态灯点亮时带光环扩散。
- 60fps 播放，动画只在切换时存在，结束即释放；空闲 CPU 0%，内存约 14MB，支持「减弱动态效果」。

## 构建安装

需要 Xcode 命令行工具和已安装的 Reminal（`~/.local/bin/reminal`）。

```sh
./build.sh
```

首次切换时会请求管理员密码，写入一条只允许 `pmset -a disablesleep 0/1` 的 sudoers 规则。
