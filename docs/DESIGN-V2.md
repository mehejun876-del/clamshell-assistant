# 合盖助手 V2 设计说明

> **2.1.0 更新（以本节为准，下文 2.0.0 的内容凡与本节冲突的均已作废）**
>
> 1. **取消电池与热压力的安全暂停**：`SafetyMonitor`、`SafetyLatch`、确认恢复、低电量通知、IOKit 电池通知源和热压力观察者全部删除。电池和热压力只在子菜单第一行只读显示，打开菜单时读一次（`powerStatusLine`）。启动时清除 2.0.0 遗留的 `SafetyLatch`。兜底是 macOS 自身的硬件保护。
> 2. **AI 智能模式全自动**：`decidePower(intent:smart:agentsAwake:idleSince:suppressed:now:config:)`，优先级：手动开 > AI 智能模式 > 保存的选择。AI 模式下有活动任务（执行中、工具运行、等待确认、状态未知）即阻止睡眠，最后一个任务结束后缓冲 3 分钟再释放。去掉 2.0.0 的 10 分钟 armWindow。只有从“有任务”变为“无任务”才开始缓冲（仅打开会话不算）。
> 3. **释放后睡眠**：AI 释放保活时读一次 `IOPMrootDomain.AppleClamshellState` 和 `IOHIDSystem.HIDIdleTime`。盖子合着且 60 秒内无人操作时执行 `pmset sleepnow`（无需 root）。不轮询。
> 4. **手动关闭**：AI 正在保活时点「关闭合盖运行」，立即释放并设 `suppressed`，直到本批任务全部结束；缓冲期内关闭则直接结束缓冲。
> 5. **Hook 不可见**：子菜单删除「Agent Hook」。勾选 AI 智能模式时（以及已开启时每次启动）`ensureHooks()` 为检测到的 Agent 追加 Hook，只在缺失或指向别的 helper 路径时才改写（`isCurrent`）。Antigravity 按 `~/.gemini/antigravity` 或 `~/.gemini/config` 识别，不再因为只有 `~/.gemini` 就判定已安装。关闭 AI 模式时保留 Hook（没有 socket 时 helper 立即退出、放行），由 `rollback.sh` 移除。首次连接 Codex 时发一次通知，提示在「设置 › Hooks」中信任，不绕过 Codex 的信任机制。
> 6. **子菜单**：状态行 → AI 智能模式 → 按 Agent 的任务行（`countsByKind` / `agentTaskLines`）→ 定时自动停止 → 登录时启动 →（存在时）移除免密规则。菜单打开期间收到事件就重建（NSMenuDelegate），不加定时器。
> 7. **授权**：AI 模式在后台切换需要 1.4.1 的最小免密规则；没有规则时在用户勾选 AI 智能模式那一刻请求一次（同一段脚本 `sudoRuleScript()`），后台不弹窗。
> 8. **自动纠偏预算**：决策目标改变时重置 1.4.1 的“2 分钟 3 次”计数，所以 AI 的正常开关不会被误判为“被其他程序反复改回”。
> 9. **Grokbot**：经核实是 xAI Grok Bot 桌面应用，任务在云端电脑运行，没有本机 Hook 接口，所以暂不支持、菜单中不显示。Grok Build CLI 的适配保留，检测到 `~/.grok` 时自动连接。

基线：`main` @ `ef4f663340bcdd5978fd944600fdc2aec70c8dde`（1.4.1，build 8）。V2 = 2.0.0（build 9）起，当前 2.1.7（build 17），当前 2.1.0（build 10），兼容目标不变：macOS 14+、Apple Silicon。

## 1. 改动范围（只做增补，不重写）

| 文件 | 状态 | 作用 |
|---|---|---|
| `Policy.swift` | 新增 | 纯逻辑：电池/热压力状态机、Agent 会话表、**唯一决策函数 `decidePower`**、租约判定、Hook 事件映射。不做 I/O，不含定时器 |
| `Lease.swift` | 新增 | 租约文件、进程启动时间、开机会话 UUID、有大小上限（64 KB）的日志、路径 |
| `Agents.swift` | 新增 | IOKit 电池读取与变化通知、Unix socket 监听与对端校验、可撤销的 Hook 安装 |
| `Helper/main.swift` | 新增 | `clamshell-helper`：Hook 客户端 + 崩溃守护（同一个小二进制） |
| `State.swift` | 小改 | `ModePresentation` 新增可选字段 `hold`、`lowBattery`，默认 nil，保证 1.4.1 的全部文案和行为不变 |
| `main.swift` | 增补 | 主菜单多 1 条分隔线和 1 个子菜单项；reconcile 和 toggle 改为以统一决策为目标；setMode 中写入租约；退出时释放。**动画代码（Pose/Kind/draw*/play/tick）一行未改** |
| `Tests.swift` | 增补 | 原有断言保留（`visibleTitles` 只排除新增的子菜单项），末尾追加 V2 控制器场景 |
| `PolicyTests.swift` | 新增 | 纯逻辑测试与临时文件测试 |
| `ThirdParty/reminal-lid` | **未改动** | Go 源码与 1.4.1 完全相同 |

## 2. 统一决策（优先级从高到低）

1. **安全暂停**（`SafetyLatch`，持久保存）：由电量或热压力触发。只能由用户手动恢复，且恢复时条件必须已经安全。
2. **用户的明确选择**（`ModeIntent`，沿用 1.4.1）：用户关闭后，任何 Agent 活动都不会把它重新开启。
3. **AI 智能模式**（默认关闭）：只在用户选择“开”时生效。开启后有 10 分钟等待首个任务；全部任务结束后缓冲 3 分钟；等待确认最长 30 分钟；状态未知时最多再保持 10 分钟，然后视为过期。
4. **经典模式**：与 1.4.1 相同。

`reconcileIfNeeded()`（1.4.1 的自动纠偏：2 分钟内最多 3 次，并给出具体失败原因）完全保留，只是目标从 `intent` 改为 `decision.want`。因此纠偏不会抵消安全暂停或智能待命；需要自动开启时，还要先通过 `enableBlocker(explicit:false)` 的安全检查。

## 3. 安全保护

- 电池：用 `IOPSCopyPowerSourcesInfo` 读取，用 `IOPSNotificationCreateRunLoopSource` 接收变化通知（事件驱动）。默认使用电池且 ≤25% 时提示一次，≤15% 时暂停；恢复需要接上电源或电量 ≥20%（滞回）。阈值可以用 `defaults write local.reminal.clamshellassistant BatteryStopPercent -int N` 调整，取值会被限制在 5–50 之间。
- 读取失败：按 2 秒、5 秒、15 秒各重读一次，共 3 次；之后显示“电池状态未知”，此时阻止**自动**开启，手动点击仍可开启。
- 热压力：使用 `ProcessInfo.thermalState` 和 `thermalStateDidChangeNotification`。fair（偏高）只记录；serious（严重）持续 60 秒触发暂停，中途回落不足 30 秒不重新计时；critical（危急）立即暂停；恢复要求降温后保持 30 秒。界面只显示“正常/偏高/严重/危急”，从不换算成摄氏度。
- 暂停动作等同于一次自动的“关闭合盖运行”：执行 `pmset disablesleep 0`、关闭 Reminal 的两项设置、停止合盖服务。不会终止任何其他进程。

## 4. 异常退出恢复与 Safety Guard 可行性

| 方案 | 结论 |
|---|---|
| 特权 LaunchDaemon（SMAppService.daemon / SMJobBless） | **不采用**：需要 Developer ID 签名和公证，还需要用户批准后台项目。当前应用是 ad-hoc 签名，无法可靠部署，而且会扩大 root 权限面 |
| 用户级 LaunchAgent（SMAppService.agent） | 技术上可行，但需要触发条件：纯 launchd 只能用 `StartInterval` 周期唤醒（违反“无周期唤醒”）或 `KeepAlive` 常驻；ad-hoc 签名时还要用户在“登录项”里批准。**列为后续选项** |
| **采用：生命线守护进程** `clamshell-helper guard` | 只在持有租约期间存在，阻塞在 stdin 管道读取上，CPU 占用为 0，并通过 `setsid()` 脱离应用的进程组。应用正常释放时先发送 `release`；若直接收到 EOF（崩溃、强制退出、`kill -9`），守护进程先核对租约里的 PID 和开机会话，再确认 `SleepDisabled=1`，然后用已有的免密规则执行 `sudo -n pmset -a disablesleep 0` |
| 下次启动恢复 | 始终保留：遗留租约（进程不存在、启动时间不符或开机会话已变）会被新实例接管，再由统一决策决定保持还是关闭 |

**边界（如实说明）**：断电、内核崩溃、注销或关机时，守护进程也会结束；守护进程本身被强杀，或免密规则已被撤销时，只能等下次启动恢复。没有租约的 `SleepDisabled=1`（不是本助手设置的）永远不会被自动改动。

不与其他软件持续争夺设置：1.4.1 的“2 分钟内最多 3 次，之后停止并报错”保持不变。安全暂停期间，只有用户手动操作才可能重新开启。

## 5. 权限审计

- root 操作仍然只有 1.4.1 sudoers 规则里的两条命令：`/usr/bin/pmset -a disablesleep 0` 和 `1`。V2 **没有新增任何特权命令**。
- `clamshell-helper` 以普通用户身份运行，只会执行 `pmset -g live`（只读）和 `sudo -n pmset -a disablesleep 0`（规则内命令，非交互，失败时不弹窗）。
- 新增可撤销入口「移除管理员免密规则…」：只在规则文件内容与本助手写入的原文完全一致时才删除，执行前需要管理员确认。
- 安装和回滚脚本都不修改 sudoers。

## 6. AI Agent 兼容性（依据官方文档，2026-11 核实）

| Agent | 官方接口 | 使用的事件 | 可区分的状态 | 局限 |
|---|---|---|---|---|
| Codex CLI | `~/.codex/hooks.json`（官方 Hooks） | SessionStart、UserPromptSubmit、PreToolUse、PostToolUse、PermissionRequest、Stop、Interrupt、SessionEnd | 执行中 / 工具运行 / 等待确认 / 本轮完成 / 中断 / 结束 | 新增 Hook 需在 `/hooks` 中信任；Stop 要求输出 JSON（helper 输出 `{}`） |
| Codex 桌面版 | 官方文档说明，桌面版在「设置 › Hooks」中审阅并信任同一套 Hook | 同上（共用同一个文件） | 同上 | **未在用户这台 Mac 上实际验证**；Hook 数据里没有区分 CLI 与桌面版的字段，两者显示为同一种 Agent |
| Gemini CLI | `~/.gemini/settings.json` 的 `hooks` | SessionStart、BeforeAgent、BeforeTool、AfterTool、Notification(ToolPermission)、AfterAgent、SessionEnd | 执行中 / 工具运行 / 等待确认 / 本轮完成 / 结束 | 没有中断事件，靠租约兜底；timeout 单位是毫秒；stdout 必须是 JSON |
| Antigravity（App / CLI / IDE） | `~/.gemini/config/hooks.json`（按 Hook 名称作键） | SessionStart、PreInvocation、PostToolUse、Stop（含 fullyIdle 和 error） | 执行中 / 后台仍有任务 / 本轮完成 / 出错 | 没有“等待确认”和“会话结束”事件；为了不干预工具审批，不注册 PreToolUse |
| Grok Build（用户说的“Grokbot”，按 xAI 官方 Grok Build CLI 适配） | `~/.grok/hooks/*.json`（使用独立文件 `clamshell-assistant.json`） | SessionStart、UserPromptSubmit、PreToolUse、PostToolUse(Failure)、Stop、StopFailure、SessionEnd | 执行中 / 工具运行 / 本轮完成 / 出错 / 结束 | 没有可靠的“等待确认”事件；PreToolUse 失败时放行（helper 无输出且以 0 退出，表示允许） |
| Claude Code | 未适配 | — | — | 按要求只保留通用扩展位（`AgentKind.other` + 同一 socket 协议） |

任务状态从不靠 CPU、网络或进程扫描来判断。

## 7. StayAwake 逐项评估（已阅读 PowerAssertionManager / LidCloseManager / AppState / LoginItemManager / PrivilegedRunner）

| 候选功能 | StayAwake 的实际实现 | 结论 |
|---|---|---|
| IOPMAssertion 防空闲睡眠 | 已实现（PreventUserIdleSystemSleep / DisplaySleep） | **不值得引入**：Reminal 精简服务已经用 `caffeinate -i/-d`（以 `-w` 绑定进程），再加一套断言只会重复，还会带来释放时序冲突 |
| 屏幕可关、后台继续运行 | 用 DisplayPolicy 释放显示断言 | **已有（部分）**：合盖时 Reminal 会把内屏调暗到 0；“保持解锁”依赖 `caffeinate -d`，改动它会改变 1.4.1 的模式语义，所以不改 |
| 定时自动停止 | 已实现（Timer 每秒触发一次） | **适合新增，并做了改良**：改为一个一次性的截止定时器，不再每秒触发；到时间后等同于用户明确关闭 |
| 启动时检查遗留的禁睡眠 | `reconcileOnLaunch`：只要标记为真就无条件关闭 | **需要增强，已实现**：用“PID + 启动时间 + 开机会话”的租约判断归属，并加了崩溃守护；不是本助手设置的不碰 |
| 官方登录项 | `SMAppService.mainApp` | **适合新增，已实现**（子菜单「登录时启动」） |
| 最小权限授权与撤销 | 安装/卸载 `/etc/sudoers.d/stayawake` | **已有，并增强**：沿用 1.4.1 的规则，新增“内容完全一致才删除”的撤销入口 |
| 可替换的电源接口 | `PrivilegedRunner` 协议 | **已有，并增强**：1.4.1 已有 `testCommand` 替身，V2 增加了 `batteryReader`、`clock` 和 Agent 事件注入 |

StayAwake 没有电池保护、温度保护和 Agent 感知，这三项不是从它借鉴的。

## 8. 资源占用评估

- 空闲时（经典模式、未开智能模式）V2 新增的常驻部分：一个 IOKit run loop source、一个热压力通知观察者、一个唤醒通知观察者。**没有定时器，也没有 socket。**
- 开启合盖运行后：多一个 `clamshell-helper guard`，阻塞在管道读取上，预计 RSS 约 1–2 MB（**待实机测量**）。
- 开启智能模式后：多一个监听 socket（GCD read source，事件驱动）；每个 Hook 事件启动一次 helper，约几毫秒后退出。
- 会话表最多 32 条，每条只存 kind、phase 和三个时间戳；日志上限 64 KB，超出后轮转一次。
- 动画：沿用 1.4.1，只在状态切换时创建 CADisplayLink（60 Hz，约 0.7–0.9 秒），结束后立即释放，静止时不重绘。自检会断言静止时 `link == nil`。
- Reminal Go 服务保持 1.4.1 的资源占用：每 2 秒读一次设置、每 12 秒检查一次显示器（原有行为，未改动）。
- 实测命令：`zsh measure.sh 60`（会运行 ps、footprint、`top -stats cpu,idlew,power` 和 pmset 断言查询）。**尚未实测**，与 1.4.1 的对比也待实机完成。

## 9. 测试矩阵

| 场景 | 位置 | 类型 |
|---|---|---|
| 原有开关、刷新、动画、纠偏、授权缺失（1.4.1 全部断言） | Tests.swift | 模拟命令 + 真实状态栏动画路径 |
| 主菜单项数、顺序、文案 = 1.4.1 + 分隔线 + 子菜单；子菜单默认状态 | Tests.swift V2 | 同上 |
| 电量阈值、滞回、只提示一次、无电池、读取失败与有界重试 | PolicyTests + Tests V2 | 注入数据 |
| 热压力升级（59 秒 / 60 秒）、短暂回落、critical、恢复滞回 | PolicyTests + Tests V2 | 注入时钟 |
| 两个 Agent 并行其一先完成、等待确认上限、中断、事件延迟/重复/丢失、缓冲期内新任务、会话表上限 | PolicyTests + Tests V2 | 注入事件 |
| 用户关闭后不被自动重启；安全暂停不被纠偏或智能模式覆盖 | Tests V2 | 模拟 |
| 断电、重新接电（不自动恢复） | Tests V2 | 注入数据 |
| 进程异常退出与重启（接管遗留租约、存活的所有者不碰、PID 复用、重启后租约失效） | PolicyTests + Tests V2 | 模拟 |
| 退出时只释放自己持有的设置 | Tests V2 | 模拟 |
| 无管理员授权 | Tests（1.4.1 原有） | 模拟 |
| 其他软件反复改回（最多恢复 3 次） | Tests（1.4.1 原有） | 模拟 |
| Hook 安装/卸载不覆盖他人条目、保留文件权限、先备份、拒绝带注释的 JSON、Agent 未安装时不配置 | PolicyTests（临时目录） | 真实文件读写（仅临时目录） |
| socket 消息校验（版本、未知 Agent 或阶段、原始 ID、超长、未来时间戳） | PolicyTests | 纯函数 |
| 空闲时没有定时器和 DisplayLink | Tests V2 + test.sh 静态检查 | 断言 |
| helper 对各 Agent 的 stdout 输出约定 | test.sh | 真实进程，不连接 Agent |
| **真实合盖与开盖、虚拟显示器、内屏调暗、真实电池和热压力事件、真实 Agent Hook、崩溃守护、登录项、资源占用** | — | **待实机验证** |

## 10. 2.1.1–2.1.7 的变化（详见 CHANGELOG.md）

**没有 Hook 的识别来源（2.1.6 起，`Agents.swift` 末尾）**

| 来源 | 读什么 | 什么时候读 | 防止误判 |
|---|---|---|---|
| Codex 状态库 `~/.codex/sqlite/codex.db` | 只读打开（`SQLITE_OPEN_READONLY`，忙等 200 ms），只查 `active_chat_turns` 的 `thread_id` | `sqlite/` 目录、库文件和 `-wal` 有变化时（kqueue），0.5 秒内多次变化合并成一次 | ChatGPT / Codex App 没在运行时，表里残留的行一律不算；读失败时保持上次结果，不当作“已结束”；每个轮次按 `.tool` 阶段记，租约 60 分钟 + 10 分钟“未知” |
| AWS Quick 桌面日志 `~/Library/Logs/quickwork/quickwork-YYYY-MM-DD-HH.log` | 只看新追加的部分（单次最多 512 KB），只认 `[rlog:outpost_tool_call_started/finished]`、`[OutpostACP]`、`[ChatTurn] time_to_first*`、`[TTFT]`（进行中）和 `[ChatTurn] time_to_complete`（本轮结束） | 日志目录和当前文件有变化时；启动前的历史不回放；整点换新文件时从头读新文件 | 不保存任何日志内容；只在云端思考、不操作本机时不计为任务（这时 Mac 睡眠不影响它） |

两者都只在 AI 智能模式开启时存在，关闭即撤销文件监听。会话 ID 和其他来源一样只保存哈希。

**去掉的来源**：2.1.6 曾同时读取 Codex Keyboard 的灯光状态文件（含远程 Work），但其中远程任务的状态会在任务结束后长时间停在 `working`，导致电脑一直不睡。2.1.7 起不再读取，纯远程 Work 不再识别（它在云端执行，不受本机睡眠影响）。

**Codex 系统级 Hook（2.1.4）**：Codex 把 `/etc/codex/hooks.json` 视为受管来源、按策略信任。App 只用 `--codex-system-hooks <helper>` 计算文件内容（键排序，输出稳定），由安装脚本在一次管理员授权后写入（root:wheel 0644，原文件先备份）；生效后 App 移除用户级 `~/.codex/hooks.json` 里自己的条目，避免每个事件执行两次。

**Kiro（2.1.3）**：使用 CLI 3 的独立 Hook 文件 `~/.kiro/hooks/clamshell-assistant.json`（`{"version":"v1","hooks":[…]}`），只注册 SessionStart、UserPromptSubmit、PostToolUse、Stop、SessionEnd；`PreToolUse` / `PermissionRequest` 会阻塞 Kiro，所以从不注册。

**菜单（2.1.1–2.1.5）**：两个菜单在启动时按固定的几项短文字量一次原生宽度，设为 `minimumWidth`，之后不再改变；动态文字超出时截断加“…”，全文放在 toolTip。菜单栏动画换成动画包版本（W=27、H=18、`statusBarLength` 35pt、22 帧 / 24fps），绘制与播放路径（`CADisplayLink` + 复用位图 + 遮罩图层）不变。

**测试隔离（2.1.1）**：自检使用每个进程独立的偏好域和租约文件，退出时（包括断言失败）清理，不读写正在运行的 App 的设置。

