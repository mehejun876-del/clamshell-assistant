#if SELFTEST
import AppKit

func runSelfTests(_ c: Controller) {
    var assertions = 0
    // The self-test suite is per-process (see Controller.selftestSuite), so a crashed or killed
    // run can never leak into the next one. Still remove it on any exit — including a failed
    // assertion — so no orphaned preference files accumulate. atexit covers every exit path;
    // the per-PID name means a non-capturing @convention(c) closure is enough.
    _ = atexit { UserDefaults(suiteName: Controller.selftestSuite)?.removePersistentDomain(forName: Controller.selftestSuite) }
    func check(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard value() else { print("FAIL: " + message); exit(1) }
    }
    // The 1.4.1 menu items. V2 adds only the「高级选项」submenu item (and one separator),
    // which is checked separately below, so every original assertion keeps its exact list.
    func visibleTitles() -> [String] {
        c.menu.items.filter { !$0.isSeparatorItem && !$0.isHidden && $0 !== c.advancedItem }.map(\.title)
    }
    func hasForbiddenCopy() -> Bool {
        c.menu.items.contains { $0.title.contains("外接") || $0.title.contains("盖子") || $0.title.contains("closed-lid") || $0.title.contains("always-unlocked") || $0.title.contains("完成开启") }
    }

    // V2: never touch the user's real support directory, lease, agent configs, power or login items.
    let scratch = NSTemporaryDirectory() + "clamshell-selftest-support-\(getpid())"
    try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
    AppPaths.overrideDir = scratch
    c.hookHome = scratch + "/home"
    c.leaseStore.remove()
    c.defaults.removePersistentDomain(forName: Controller.selftestSuite)
    runPolicyTests { check($0, $1) }
    print("PASS V2 policy: \(assertions) assertions so far (mocked inputs only)")

    if ProcessInfo.processInfo.environment["VERIFY_LIVE"] == "1" {
        let live = try! readState(reminal: ProcessInfo.processInfo.environment["LIVE_REMINAL"] ?? c.reminal) { runCommand($0, $1) }
        print("PASS passive live read: closed=\(live.closed) unlocked=\(live.unlocked) sleepDisabled=\(live.power)")
    }

    let screenshot = ModeState(closed: false, unlocked: false, power: true)
    let off = ModeState(closed: false, unlocked: false, power: false)
    let on = ModeState(closed: true, unlocked: true, power: true)
    let screenshotUI = ModePresentation(state: screenshot, serviceUp: true)
    check(!screenshotUI.consistent && screenshotUI.header == "未完全关闭：系统禁止睡眠仍开着" && screenshotUI.toggleTitle == "开启合盖运行" && screenshotUI.look == Look(lidClosed: false, lit: false), "screenshot regression: leftover SleepDisabled is a named error, never 'partial'")
    check(ModePresentation(state: off, serviceUp: false).header == "正常模式" && ModePresentation(state: off, serviceUp: false).toggleTitle == "开启合盖运行", "all-off is normal mode")
    check(ModePresentation(state: on, serviceUp: true).header == "合盖运行中" && ModePresentation(state: on, serviceUp: true).look == Look(lidClosed: true, lit: true) && ModePresentation(state: on, serviceUp: true).toggleTitle == "关闭合盖运行", "full on is Studio+lit, button disables")
    check(ModePresentation(state: ModeState(closed: true, unlocked: false, power: true), serviceUp: true, intent: true).header == "开启失败：保持解锁未生效", "enable failure names the missing part")
    check(ModePresentation(state: on, serviceUp: false, intent: true).header == "开启失败：合盖服务未生效", "service down is named")
    check(ModePresentation(state: ModeState(closed: false, unlocked: false, power: true), serviceUp: false, intent: true, note: "需要管理员授权，请点开关重试").header == "开启失败：合盖模式、保持解锁未生效（需要管理员授权，请点开关重试）", "failure note is appended")
    for bits in 0..<8 {
        for service in [false, true] {
            for want in [nil, false, true] as [Bool?] {
                let state = ModeState(closed: bits & 1 != 0, unlocked: bits & 2 != 0, power: bits & 4 != 0)
                let ui = ModePresentation(state: state, serviceUp: service, intent: want)
                let wants = want ?? (state.closed && state.unlocked)
                let ready = wants && bits == 7 && service
                check(!ui.header.contains("部分") && ui.look == Look(lidClosed: ready, lit: ready) && ui.toggleTitle == (wants ? "关闭合盖运行" : "开启合盖运行"), "every state is on, off or a named failure; one button follows the choice")
                check(ui.consistent || ui.header.hasPrefix("开启失败：") || ui.header.hasPrefix("未完全关闭："), "inconsistent states always name what failed")
            }
        }
    }

    let parsed = try! parseState(settings: "reminal settings:\n closed-lid\t on\n always-unlocked    on\n", power: " SleepDisabled  1\n")
    check(parsed == on, "whitespace-independent state parsing")
    do { _ = try parseState(settings: "", power: ""); check(false, "malformed state rejected") }
    catch { check(true, "malformed state rejected") }
    do {
        _ = try readState(reminal: "fake") { _, args in args == ["settings"] ? (1, "error") : (0, "") }
        check(false, "command failure rejected")
    } catch { check(true, "command failure rejected") }
    check(runCommand("/bin/sh", ["-c", "exit 7"]).0 == 7, "nonzero exit")
    check(runCommand("/bin/sleep", ["10"], timeout: 0.1).0 == 124, "timeout returns failure")
    let large = runCommand("/usr/bin/awk", ["BEGIN { for(i=0;i<100000;i++) print \"0123456789\" }"])
    check(large.0 == 0 && large.1.utf8.count == 1100000, "large output cannot fill a pipe")

    check(Pose.still(Look(lidClosed: true, lit: true)).mw == 1 && Pose.still(Look(lidClosed: true, lit: true)).led == 1, "ready pose is lit Studio")
    check(Pose.still(Look(lidClosed: false, lit: false)).mw == 0 && Pose.still(Look(lidClosed: false, lit: false)).lapLed == 0, "off pose is dark MacBook")
    for kind in [Kind.close(false, true), .open(true, false)] {
        let end = kind.pose(1)
        switch kind {
        case .close: check(abs(end.mw - 1) < 0.02 && end.led > 0.9, "enable morph ends at lit Studio")
        case .open: check(end.mw < 0.01 && end.led < 0.05, "disable morph ends at MacBook")
        default: break
        }
    }

    c.defaults.removePersistentDomain(forName: Controller.selftestSuite)
    var closedOn = false, unlockedOn = false, powerOn = true, writes = 0, commands = 0, sudoOK = true, revertPower = false, sleeps = 0
    c.testCommand = { path, args in
        commands += 1
        if path == "/usr/bin/pmset" && args == ["sleepnow"] { sleeps += 1; return (0, "") }
        if path == "/usr/bin/sudo" { writes += 1; if sudoOK && !revertPower { powerOn = args.last == "1" }; return sudoOK ? (0, "") : (1, "sudo: a password is required") }
        if path == "/usr/bin/osascript" { print("FAIL automatic restore must never prompt"); exit(1) }
        if args == ["displaysleepnow"] { print("FAIL displaysleepnow must not be issued"); exit(1) }
        if args.count == 3 && args[0] == "settings" { writes += 1; if args[1] == "closed-lid" { closedOn = args[2] == "on" } else { unlockedOn = args[2] == "on" }; return (0, "") }
        if args == ["settings"] { return (0, "closed-lid \(closedOn ? "on" : "off")\nalways-unlocked \(unlockedOn ? "on" : "off")\n") }
        if args == ["-g", "live"] { return (0, "SleepDisabled \(powerOn ? "1" : "0")\n") }
        print("FAIL unexpected command: \(path) \(args)"); exit(1)
    }
    UserDefaults.standard.set("sleep", forKey: "ExternalDisplayWhenLidClosed")
    c.current = screenshot; c.shown = Look(lidClosed: false, lit: false)
    c.updateMenu()
    check(UserDefaults.standard.object(forKey: "ExternalDisplayWhenLidClosed") == nil || visibleTitles() == visibleTitles(), "legacy external preference is not consulted")
    UserDefaults.standard.removeObject(forKey: "ExternalDisplayWhenLidClosed")
    check(c.intent == nil && writes == 0, "first launch without a saved choice writes nothing")
    c.accept(.success(screenshot))
    check(writes == 0 && !c.busy, "no saved choice: mixed state is reported, not changed automatically")
    check(visibleTitles() == [c.fitted("未完全关闭：系统禁止睡眠仍开着", c.mainTextBudget), "开启合盖运行", "刷新状态", "退出助手"] && c.header.toolTip == "未完全关闭：系统禁止睡眠仍开着", "mixed state menu has only the allowed items and names the part")
    check(!hasForbiddenCopy(), "no leftover lid/external/English setting copy")
    check(c.toggle.isEnabled && c.shown == Look(lidClosed: false, lit: false), "mixed state keeps MacBook and the single button")
    c.refreshMenu()
    check(c.intent == false, "explicit refresh adopts the shown choice (off)")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
    check(!powerOn && writes == 1 && c.current == off && c.header.title == "正常模式", "refresh restores off: only the leftover sleep switch is rewritten")

    c.current = off; c.serviceUp = false; c.shown = Look(lidClosed: false, lit: false); c.updateMenu(); writes = 0
    check(visibleTitles() == ["正常模式", "开启合盖运行", "刷新状态", "退出助手"] && c.toggle.title == "开启合盖运行" && c.toggle.isEnabled, "off menu is a single enable button")

    c.refresh()
    c.toggleMode(); c.toggleMode(); c.toggleMode()
    for _ in 0..<100 { c.refresh() }
    check(c.busy && !c.toggle.isEnabled, "toggle guarded during mutation")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        check(c.overlay?.superview === c.status.button && c.link != nil && c.maskLayer?.contents != nil && c.ticks > 1, "enable has attached overlay, live displaylink and rendered mask")
        if case .close = c.pending?.0 {} else { check(false, "enable must use full close morph, not just LED") }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        check(writes == 3, "rapid clicks cause exactly one mode operation (mocked)")
        check(commands < 20, "refresh requests coalesced")
        check(c.current == on && c.serviceUp && c.ready && c.shown == Look(lidClosed: true, lit: true), "full enable is Studio + lit")
        check(c.header.title == "合盖运行中" && c.toggle.title == "关闭合盖运行" && c.toggle.isEnabled && c.intent == true, "on menu is a single disable button; choice saved")
        check(c.renderedCloseFrames > 10 && c.renderedHaloFrames > 0, "enable rendered full morph and halo through real status button displaylink")
        c.settleAnimation()
        c.accept(.failure(StatusError(message: "simulated")))
        check(c.header.title == "状态暂不可用" && !c.toggle.isEnabled && c.shown == Look(lidClosed: true, lit: true), "read failure keeps last icon and reports 状态暂不可用")
        c.accept(.success(on))
        c.settleAnimation()
        c.syncService(false)
        c.updateMenu()
        c.settleAnimation()
        check(c.shown == Look(lidClosed: false, lit: false) && c.header.title == c.fitted("开启失败：合盖服务未生效", c.mainTextBudget) && c.header.toolTip == "开启失败：合盖服务未生效", "missing service is a named failure and does not stay Studio")
        c.accept(.success(on))
        c.settleAnimation()
        check(c.serviceUp && c.shown == Look(lidClosed: true, lit: true), "refresh restarts service and returns to ready Studio")
        // Something else (e.g. UU远程) turns the sleep switch off behind our back: restored without prompting.
        writes = 0; powerOn = false
        c.accept(.success(ModeState(closed: true, unlocked: true, power: false)))
        check(c.busy, "external change starts an automatic restore")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        check(powerOn && writes == 1 && c.current == on && c.header.title == "合盖运行中", "automatic restore rewrites only the changed part")
        // A program that keeps reverting it: bounded retries, then a named error.
        revertPower = true; powerOn = false; writes = 0
        c.accept(.success(ModeState(closed: true, unlocked: true, power: false)))
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
        check(writes <= 3 && (c.header.toolTip ?? "").hasPrefix("开启失败：系统禁止睡眠未生效") && c.header.title == c.fitted(c.header.toolTip ?? "", c.mainTextBudget), "fighting program gets at most 3 restores, then a named error: \(c.header.title) writes=\(writes)")
        revertPower = false; c.refreshMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        check(powerOn && c.header.title == "合盖运行中", "refresh retries and recovers")
        c.settleAnimation()
        c.intent = false
        closedOn = false; unlockedOn = false; powerOn = false
        c.accept(.success(off))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            check(c.link == nil && c.overlay == nil && c.status.button?.image === c.image(Look(lidClosed: false, lit: false)), "latest endpoint reached, animation released")
            check(c.renderedOpenFrames > 10, "disable rendered full reverse morph through real status button displaylink")
            closedOn = true; unlockedOn = true; powerOn = true; c.intent = true; writes = 0
            c.syncService(true); c.current = on; c.shown = Look(lidClosed: true, lit: true)
            c.status.button?.image = c.image(c.shown!)
            c.toggleMode()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                check(c.overlay?.superview === c.status.button && c.link != nil && c.maskLayer?.contents != nil && c.ticks > 1, "disable has attached overlay, live displaylink and rendered mask")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                check(writes == 3 && c.current == off && c.shown == Look(lidClosed: false, lit: false) && c.header.title == "正常模式", "disable reaches normal mode with mocked writes only")
                check(c.overlay == nil && c.link == nil, "disable releases animation resources")
                check(c.intent == false, "disable saved the off choice")
                // Authorization missing during an automatic restore: no prompt, named error, no retry loop.
                sudoOK = false; powerOn = true; writes = 0
                c.accept(.success(screenshot))
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    c.settleAnimation()
                    check(writes == 1 && c.header.toolTip == "未完全关闭：系统禁止睡眠仍开着（需要管理员授权，请点开关重试）" && c.header.title == c.fitted("未完全关闭：系统禁止睡眠仍开着（需要管理员授权，请点开关重试）", c.mainTextBudget) && c.textWidth(c.header.title) <= c.mainTextBudget && c.toggle.title == "开启合盖运行", "unauthorized restore is named and not retried: \(c.header.title) writes=\(writes)")
                    check(visibleTitles().count == 4 && !visibleTitles().contains { $0.contains("部分") }, "menu never shows a partial state")

                    // ---- V2.1 controller scenarios: mocked commands, injected battery/thermal/lid/idle/agents/clock ----
                    var fake = Date(timeIntervalSince1970: 1_900_000_000)
                    c.clock = { fake }
                    func advance(_ s: Double) { fake = fake.addingTimeInterval(s) }
                    func ev(_ k: AgentKind, _ s: String, _ p: AgentPhase, _ t: Double) -> AgentEvent { AgentEvent(kind: k, session: hashSession(s), phase: p, sentAt: t) }
                    func seq(_ steps: [(Double, () -> Void)], _ done: @escaping () -> Void) {
                        guard let first = steps.first else { done(); return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + first.0) { first.1(); seq(Array(steps.dropFirst()), done) }
                    }
                    func advTitles() -> [String] { c.menuNeedsUpdate(c.advancedMenu); return c.advancedMenu.items.map { $0.isSeparatorItem ? "—" : $0.title } }
                    let fm = FileManager.default
                    let home = c.hookHome
                    func target(_ k: AgentKind) -> HookTarget { HookTarget.all(home: home).first { $0.kind == k }! }
                    func backupCount() -> Int { ((try? fm.contentsOfDirectory(atPath: home + "/.codex")) ?? []).filter { $0.contains("clamshell-backup") }.count }
                    let wait = 1.5
                    // 固定菜单宽度：启动时定一次，下面任何状态都不改变它；每行文字都不超过固定宽度。
                    let fixedMain = c.menu.minimumWidth, fixedAdv = c.advancedMenu.minimumWidth
                    func widthsFixed() -> Bool {
                        _ = advTitles()
                        let mainFits = c.menu.items.allSatisfy { $0.isSeparatorItem || c.textWidth($0.title) <= c.mainTextBudget }
                        let advFits = c.advancedMenu.items.allSatisfy { $0.isSeparatorItem || c.textWidth($0.title) <= c.advancedTextBudget }
                        return fixedMain > 0 && fixedAdv > 0 && c.menu.minimumWidth == fixedMain && c.advancedMenu.minimumWidth == fixedAdv
                            && abs(c.menu.size.width - fixedMain) < 0.5 && abs(c.advancedMenu.size.width - fixedAdv) < 0.5 && mainFits && advFits
                    }
                    let v2Steps: [(Double, () -> Void)] = [
                    (0.1, {
                        c.settleAnimation()
                        sudoOK = true; revertPower = false; closedOn = false; unlockedOn = false; powerOn = false
                        c.intent = false; c.smartMode = false; c.autoStopHours = 0; c.autoStopAt = nil; c.suppressed = false
                        c.autoFixes = []; c.note = nil; c.leaseStore.remove(); c.current = off; c.syncService(false)
                        c.batteryReader = { BatteryReading(present: true, percent: 80, onAC: true) }
                        c.thermalReader = { .nominal }
                        c.lidReader = { false }; c.idleReader = { 0 }
                        c.accept(.success(off)); c.settleAnimation(); writes = 0
                        let titles = c.menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
                        check(titles == ["正常模式", "—", "开启合盖运行", "刷新状态", "—", "高级选项", "—", "退出助手"],
                              "V2 main menu keeps the 1.4.1 order and wording, plus one separator and one submenu above 退出助手: \(titles)")
                        var original = titles; original.remove(at: 6); original.remove(at: 5)
                        check(original == ["正常模式", "—", "开启合盖运行", "刷新状态", "—", "退出助手"], "without the two V2 entries the menu is exactly 1.4.1's")
                        check(c.advancedItem.submenu === c.advancedMenu && c.advancedItem.isEnabled && c.advancedItem.view == nil, "advanced entry is a native submenu")
                        let adv = advTitles()
                        let expectedAdv = ["电池 80% · 散热正常", "—", "AI 智能模式", "—", "定时停止", "开机启动"]
                        check(adv == expectedAdv || (adv.last == "移除免密授权…" && Array(adv.dropLast()) == expectedAdv),
                              "submenu: read-only status, AI smart mode, timed stop, login item (and the rule removal only when it exists): \(adv)")
                        let items = c.advancedMenu.items
                        check(items.first { $0.title == "AI 智能模式" }?.state == .off && !c.smartMode, "AI smart mode is off by default")
                        check(!adv.contains { $0.contains("Hook") } && !adv.contains("确认恢复合盖运行"), "no Agent Hook entry and no resume entry: hooks are invisible, there is no safety pause")
                        check(items.first?.isEnabled == false, "the battery/thermal line is read-only")
                        let stops = items.first { $0.title == "定时停止" }?.submenu?.items ?? []
                        check(stops.map(\.title) == ["关闭", "1 小时", "2 小时", "4 小时", "8 小时"] && stops.first?.state == .on, "timed stop: fixed choices, off by default")
                        check(items.allSatisfy { $0.view == nil } && !items.contains { $0.title.unicodeScalars.contains { $0.properties.isEmojiPresentation } }, "native items only: no custom views, no emoji")
                        check(c.policyTimer == nil && c.link == nil, "idle: no timer and no display link")
                        check(fixedMain > 100 && fixedAdv > 100 && widthsFixed(), "fixed menu widths from launch (normal mode)")
                        check(c.advancedMenu.items.allSatisfy { $0.isSeparatorItem || $0.title.count <= 20 }, "submenu lines are short: \(advTitles())")
                        // 和以前一样窄：主菜单不比 1.4.1 的原始菜单（同样的短文字 + ⌘Q）宽，子菜单由电池/热压力那一行决定。
                        let legacy = NSMenu(); legacy.autoenablesItems = false
                        for t in ["AI 智能模式待命", "-", "开启合盖运行", "刷新状态", "-", "退出助手"] {
                            legacy.addItem(t == "-" ? .separator() : NSMenuItem(title: t, action: nil, keyEquivalent: t == "退出助手" ? "q" : ""))
                        }
                        let legacyAdv = NSMenu()
                        legacyAdv.addItem(NSMenuItem(title: "电池 100%（已接电源） · 热压力：正常", action: nil, keyEquivalent: ""))
                        let legacyStops = NSMenuItem(title: "定时自动停止", action: nil, keyEquivalent: ""); legacyStops.submenu = NSMenu(); legacyAdv.addItem(legacyStops)
                        check(fixedMain <= ceil(legacy.size.width) + 24, "main menu is as narrow as before: \(fixedMain) vs \(legacy.size.width)")
                        check(fixedAdv <= ceil(legacyAdv.size.width) + 24, "submenu is as narrow as before: \(fixedAdv) vs \(legacyAdv.size.width)")
                        let longText = String(repeating: "很长的状态文字", count: 10)
                        check(c.fitted(longText, c.mainTextBudget).hasSuffix("…") && c.textWidth(c.fitted(longText, c.mainTextBudget)) <= c.mainTextBudget, "over-long text is cut with … and never widens the menu")
                        check(c.status.length == statusBarLength && statusBarLength == 35 && W == 27 && H == 18, "status item uses the animation pack size (35pt, 27x18 canvas)")
                        // Battery and thermal pressure never matter: 5 % on battery and critical pressure.
                        c.batteryReader = { BatteryReading(present: true, percent: 5, onAC: false) }
                        c.thermalReader = { .critical }
                        check(advTitles().first == "电池 5% · 散热危急", "status line shows battery and thermal pressure, never degrees")
                        c.toggleMode()
                        check(c.busy, "manual enable at 5 % on battery with critical pressure is not refused")
                    }),
                    (wait, {
                        check(c.current == on && c.header.title == "合盖运行中" && c.leaseStore.exists && c.guardRunning, "enable: lease written before sleep is disabled, crash guard running")
                        check(c.policyTimer == nil, "classic mode on: no timer")
                        check(widthsFixed(), "fixed menu widths (manual on)")
                        c.settleAnimation(); writes = 0
                        _ = advTitles(); c.policyChanged(); c.accept(.success(on))
                        check(writes == 0 && !c.busy && c.current == on && c.header.title == "合盖运行中", "battery and thermal readings never pause or change the running mode")
                        c.toggleMode()
                    }),
                    (wait, {
                        check(c.current == off && c.intent == false, "manual off")
                        c.settleAnimation(); writes = 0
                        c.batteryReader = { BatteryReading(present: true, percent: 80, onAC: true) }; c.thermalReader = { .nominal }
                        // Agents present in the (temporary) home: Codex with a hook of the user's own, Gemini; no Grok.
                        try? fm.createDirectory(atPath: home + "/.codex", withIntermediateDirectories: true)
                        try? fm.createDirectory(atPath: home + "/.gemini", withIntermediateDirectories: true)
                        _ = fm.createFile(atPath: home + "/.codex/hooks.json", contents: Data("{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"/usr/local/bin/my-notify\"}]}]}}".utf8))
                        c.helperPath = home + "/clamshell-helper"
                        _ = fm.createFile(atPath: c.helperPath, contents: Data("#!/bin/sh\nexit 0\n".utf8), attributes: [.posixPermissions: 0o755])
                        c.sudoRuleInstalled = false
                        c.toggleSmart()
                        check(!c.smartMode && target(.codex).status() == .notInstalled, "without the one-time authorization AI smart mode stays off and touches nothing")
                        c.sudoRuleInstalled = true
                        c.toggleSmart()
                        check(c.smartMode && writes == 0 && !c.busy && c.policyTimer == nil, "AI smart mode on, no task: nothing changes, no timer")
                        check(target(.codex).status() == .installed && target(.codex).isCurrent(helper: c.helperPath) && target(.gemini).status() == .installed,
                              "turning AI smart mode on installs the hooks of every detected agent by itself")
                        check(target(.grok).status() == .agentMissing && target(.antigravity).status() == .agentMissing, "agents that are not installed are left alone")
                        check(c.defaults.bool(forKey: "CodexTrustNotice"), "the one-time Codex trust notice is sent")
                        let backups = backupCount()
                        c.ensureHooks()
                        check(backupCount() == backups, "hooks already pointing at this helper are not rewritten")
                        let mineKept = ((((try? JSONSerialization.jsonObject(with: fm.contents(atPath: home + "/.codex/hooks.json") ?? Data())) as? [String: Any])?["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count
                        check(mineKept == 2, "the user's own Codex hook is kept next to ours")
                        check(advTitles().contains("无任务") && c.header.title == "AI 智能模式待命", "no task: \(c.header.title)")
                        check(widthsFixed(), "fixed menu widths (AI standby)")
                        c.agentEvent(ev(.codex, "a", .responding, 1))
                        check(c.decision == Decision(want: true, hold: nil, auto: true) && c.busy, "a Codex task starts: AI keeps the Mac awake by itself, no click needed")
                    }),
                    (wait, {
                        check(c.current == on && c.intent == false && c.leaseStore.exists && c.guardRunning, "AI enabled all parts; the manual choice stays off")
                        check(c.header.title == "AI 合盖运行中" && c.header.toolTip == "AI 合盖运行中 · 1 个任务" && c.toggle.title == "关闭合盖运行", "header shows AI keep-awake: \(c.header.title)")
                        check(widthsFixed(), "fixed menu widths (AI running)")
                        c.settleAnimation()
                        check(c.shown == Look(lidClosed: true, lit: true), "AI keep-awake uses the lit Mac Studio icon")
                        writes = 0
                        c.agentEvent(ev(.gemini, "b", .waiting, 1))
                        c.agentEvent(ev(.antigravity, "c", .background, 1))
                        c.agentEvent(ev(.codex, "a2", .tool, 1))
                        let byKind = c.tracker.countsByKind(now: fake)
                        check(byKind[.codex] == AgentCount(running: 2) && byKind[.gemini] == AgentCount(waiting: 1) && byKind[.antigravity] == AgentCount(background: 1), "per-agent counts")
                        let lines = advTitles()
                        check(lines.contains("Codex：2 个进行中") && lines.contains("Gemini：1 个待确认") && lines.contains("Antigravity：1 个后台"), "submenu lists the background tasks per agent: \(lines)")
                        check(widthsFixed(), "fixed menu widths (several agent task lines)")
                        c.menuWillOpen(c.advancedMenu)
                        c.agentEvent(ev(.codex, "a2", .turnDone, 2))
                        check(c.advancedMenu.items.contains { $0.title == "Codex：1 个进行中" }, "an open submenu updates on agent events (no timer)")
                        c.menuDidClose(c.advancedMenu)
                        let finished: [(AgentKind, String)] = [(.codex, "a"), (.gemini, "b"), (.antigravity, "c")]
                        for (k, s) in finished { c.agentEvent(ev(k, s, .turnDone, 3)) }
                        check(c.decision == Decision(want: true, hold: nil, auto: true) && c.policyTimer != nil && writes == 0, "all done: the 3-minute buffer is one one-shot timer")
                        check(advTitles().contains { $0.hasPrefix("约 ") && $0.hasSuffix(" 睡眠") }, "buffer is shown")
                        check(widthsFixed(), "fixed menu widths (buffer line)")
                        advance(120)
                        c.agentEvent(ev(.codex, "d", .responding, 4))
                        advance(200); c.deadlineFired()
                        check(c.decision.want == true && writes == 0, "a new task inside the buffer cancels the pending sleep")
                        c.agentEvent(ev(.codex, "d", .turnDone, 5))
                        c.lidReader = { true }; c.idleReader = { 600 }; sleeps = 0
                        advance(179); c.deadlineFired()
                        check(c.decision.want == true && !c.busy, "still inside the buffer at 179 s")
                        advance(2); c.deadlineFired()
                        check(c.decision == Decision(want: false, hold: .smartIdle) && c.busy, "buffer over: AI releases keep-awake by itself")
                    }),
                    (wait, {
                        check(c.current == off && !c.leaseStore.exists && !c.guardRunning && c.intent == false, "released all parts and the lease")
                        check(sleeps == 1, "lid closed and nobody at the Mac: sleep right away (pmset sleepnow, no root)")
                        check(c.header.title == "AI 智能模式待命" && c.toggle.title == "开启合盖运行" && c.policyTimer == nil, "standby with nothing pending: no timer: \(c.header.title)")
                        c.settleAnimation(); writes = 0
                        c.agentEvent(ev(.codex, "e", .responding, 6))
                        check(c.busy, "the next task re-enables by itself")
                    }),
                    (wait, {
                        check(c.current == on, "re-enabled")
                        c.settleAnimation()
                        c.lidReader = { false }; sleeps = 0
                        c.agentEvent(ev(.codex, "e", .turnDone, 7))
                        advance(181); c.deadlineFired()
                        check(c.busy, "released again")
                    }),
                    (wait, {
                        check(c.current == off && sleeps == 0, "lid open: keep-awake released, but no forced sleep")
                        c.lidReader = { true }; c.idleReader = { 5 }
                        c.agentEvent(ev(.codex, "f", .responding, 8))
                    }),
                    (wait, {
                        check(c.current == on, "on for task f")
                        c.settleAnimation()
                        c.agentEvent(ev(.codex, "f", .turnDone, 9)); advance(181); c.deadlineFired()
                    }),
                    (wait, {
                        check(c.current == off && sleeps == 0, "lid closed but someone used the Mac a moment ago (external keyboard): no forced sleep")
                        c.idleReader = { 600 }
                        c.agentEvent(ev(.codex, "g", .responding, 10))
                    }),
                    (wait, {
                        check(c.current == on, "on for task g")
                        c.settleAnimation()
                        c.toggleMode()
                        check(c.suppressed && c.intent == false, "manual off during a task: AI paused for this batch")
                    }),
                    (wait, {
                        check(c.current == off && c.header.title == "AI 已暂停" && sleeps == 0, "manual off is immediate and explicit: \(c.header.title)")
                        check(widthsFixed(), "fixed menu widths (AI paused)")
                        writes = 0
                        c.agentEvent(ev(.gemini, "h", .tool, 1)); c.accept(.success(off))
                        check(writes == 0 && !c.busy, "while paused, more activity in this batch never re-enables")
                        c.agentEvent(ev(.codex, "g", .turnDone, 11)); c.agentEvent(ev(.gemini, "h", .turnDone, 2))
                        check(!c.suppressed && c.decision == Decision(want: false, hold: .smartIdle) && c.policyTimer == nil && writes == 0, "batch over: pause ends, no buffer, nothing written")
                        c.agentEvent(ev(.codex, "i", .responding, 12))
                        check(c.busy, "the next batch enables by itself again")
                    }),
                    (wait, {
                        check(c.current == on, "next batch on")
                        c.settleAnimation()
                        c.toggleSmart()
                        check(!c.smartMode && c.busy, "AI smart mode off: keep-awake follows the manual choice (off)")
                    }),
                    (wait, {
                        check(c.current == off && target(.codex).status() == .installed, "turning AI off keeps the invisible hooks (the helper exits at once without the socket)")
                        check(advTitles().filter { $0.contains("任务") }.isEmpty, "no task lines while AI smart mode is off")
                        writes = 0
                        c.agentEvent(ev(.codex, "j", .responding, 13))
                        check(writes == 0 && !c.busy, "AI off: agent events are ignored")
                        c.toggleMode()
                    }),
                    (wait, {
                        check(c.current == on && c.leaseStore.exists, "manual on again")
                        writes = 0
                        c.releaseOwnedSleep()
                        check(!powerOn && writes == 1 && !c.leaseStore.exists, "quit turns off a SleepDisabled this app owns")
                        powerOn = true; writes = 0
                        c.releaseOwnedSleep()
                        check(powerOn && writes == 0, "quit never touches a SleepDisabled it does not own")
                        c.leaseStore.write(KeepAwakeLease(pid: 999_999, processStart: 1, bootSession: bootSessionUUID(), since: Date(timeIntervalSince1970: 1_800_000_000)))
                        c.recoverLeaseAtLaunch()
                        check(c.leaseStore.read()?.pid == getpid(), "launch adopts a lease left by an instance that ended without releasing")
                        let mine = KeepAwakeLease(pid: getpid(), processStart: processStartTime(getpid()) ?? 0, bootSession: bootSessionUUID(), since: Date(timeIntervalSince1970: 1_800_000_000))
                        c.leaseStore.write(mine); c.recoverLeaseAtLaunch()
                        check(c.leaseStore.read() == mine, "a live owner's lease is left alone")
                        c.leaseStore.remove()
                        closedOn = true; unlockedOn = true; powerOn = false; writes = 0
                        c.accept(.success(ModeState(closed: true, unlocked: true, power: false)))
                        check(c.busy, "the saved manual choice is restored automatically, as in 1.4.1")
                    }),
                    (wait, {
                        check(c.current == on && writes == 1, "restored only the changed part")
                        let one = NSMenuItem(); one.tag = 1
                        c.setAutoStop(one)
                        check(c.autoStopAt != nil && c.policyTimer != nil, "timed stop arms a single timer")
                        advance(3601); c.settleAnimation(); c.deadlineFired()
                        check(c.intent == false && c.busy, "timed stop turns the mode off like an explicit off")
                    }),
                    (wait, {
                        check(c.current == off && c.policyTimer == nil, "after the timed stop nothing is pending")
                        c.settleAnimation()
                        check(c.link == nil && c.overlay == nil, "no display link or overlay at rest")
                        // Codex system-level hooks (trusted by policy): the user-level copy goes away, so Codex never runs them twice.
                        let sysDir = (c.codexSystemPath as NSString).deletingLastPathComponent
                        if case .write(let data) = CodexSystemHooks.plan(install: true, helper: c.helperPath, path: c.codexSystemPath) {
                            try? fm.createDirectory(atPath: sysDir, withIntermediateDirectories: true)
                            _ = fm.createFile(atPath: c.codexSystemPath, contents: data)
                        }
                        c.ensureHooks()
                        let userCodexRoot = (try? JSONSerialization.jsonObject(with: fm.contents(atPath: home + "/.codex/hooks.json") ?? Data())) as? [String: Any] ?? [:]
                        let userStop = ((userCodexRoot["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count
                        check(CodexSystemHooks.isActive(helper: c.helperPath, path: c.codexSystemPath) && target(.codex).status() == .notInstalled && userStop == 1,
                              "Codex system hooks active: our user-level copy is removed (no double runs), the user's own hook stays")
                        try? fm.removeItem(atPath: sysDir)
                    }),
                    ]
                    seq(v2Steps) {
                        c.defaults.removePersistentDomain(forName: Controller.selftestSuite)
                        c.leaseStore.remove()
                        try? FileManager.default.removeItem(atPath: scratch)
                        print("PASS \(assertions) assertions; rendered close=\(c.renderedCloseFrames), open=\(c.renderedOpenFrames), halo=\(c.renderedHaloFrames); real status-button animation path, mocked writes only")
                        NSApp.terminate(nil)
                    }
                }
            }
        }
        }
        }
        }
    }
    }
}
#endif
