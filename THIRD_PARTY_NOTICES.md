This application bundles a MODIFIED, closed-lid-only build of Reminal 3.19.4
by harshalgajjar, licensed under the GNU Affero General Public License v3.0.

Modifications (2026, for Clamshell Assistant): only the closed-lid parts are
built — the closed-lid/always-unlocked settings, the sleep inhibitors, the lid
dimmer for the built-in screen and the virtual display used while headless.
Removed: terminal sharing and sessions, relay networking, window/desktop
mirroring and remote input, file transfer, port exposure, owners/machines,
upgrades, MCP and agent integrations. Each modified file carries a notice.

Modified source: ThirdParty/reminal-lid in
https://github.com/mehejun876-del/clamshell-assistant
Original source: https://github.com/harshalgajjar/Reminal/tree/v3.19.4
License: see Reminal-LICENSE in this directory.

本应用内置 Reminal 3.19.4（作者 harshalgajjar，AGPL-3.0）的修改版，仅保留合盖相关功能
（closed-lid / always-unlocked 设置、防睡眠、内屏调暗、无显示器时的虚拟显示器），
删除了远程终端、会话、中继联网、远程窗口/桌面与输入控制、文件传输、端口转发、设备配对、
自动升级与 MCP/Agent 集成。修改后的源码位于本项目 ThirdParty/reminal-lid，
原始源码：https://github.com/harshalgajjar/Reminal/tree/v3.19.4

---

Design references (no code copied):
- StayAwake by TY-teo (MIT License, https://github.com/TY-teo/StayAwake). Clamshell Assistant V2
  adopts two ideas after reviewing its source: checking at launch for a `disablesleep` the app itself
  left behind (StayAwake `LidCloseManager.reconcileOnLaunch`), and registering the login item with
  `SMAppService.mainApp` (StayAwake `LoginItemManager`). V2's implementation (lease with PID + start
  time + boot session, crash guard, ownership checks) is original and written for this project.
- Agent hook formats follow the official documentation of OpenAI Codex, Google Gemini CLI,
  Google Antigravity and xAI Grok Build. No code from those projects is included.

设计参考（未复制代码）：StayAwake（MIT）的“启动时检查本程序遗留的 disablesleep”与“SMAppService 登录项”两点思路；
各 Agent 的 Hook 格式依据其官方文档。V2 的租约、崩溃守护与归属判断为本项目原创实现。
