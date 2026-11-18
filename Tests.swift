#if SELFTEST
import AppKit

func runSelfTests(_ c: Controller) {
    var assertions = 0
    func check(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard value() else { print("FAIL: " + message); exit(1) }
    }
    func visibleTitles() -> [String] {
        c.menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map(\.title)
    }
    func hasForbiddenCopy() -> Bool {
        c.menu.items.contains { $0.title.contains("外接") || $0.title.contains("盖子") || $0.title.contains("closed-lid") || $0.title.contains("always-unlocked") || $0.title.contains("完成开启") }
    }

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

    c.defaults.removePersistentDomain(forName: "local.reminal.clamshellassistant.selftest")
    var closedOn = false, unlockedOn = false, powerOn = true, writes = 0, commands = 0, sudoOK = true, revertPower = false
    c.testCommand = { path, args in
        commands += 1
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
    check(visibleTitles() == ["未完全关闭：系统禁止睡眠仍开着", "开启合盖运行", "刷新状态", "退出助手"], "mixed state menu has only the allowed items and names the part")
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
        check(c.shown == Look(lidClosed: false, lit: false) && c.header.title == "开启失败：合盖服务未生效", "missing service is a named failure and does not stay Studio")
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
        check(writes <= 3 && c.header.title.hasPrefix("开启失败：系统禁止睡眠未生效"), "fighting program gets at most 3 restores, then a named error: \(c.header.title) writes=\(writes)")
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
                    check(writes == 1 && c.header.title == "未完全关闭：系统禁止睡眠仍开着（需要管理员授权，请点开关重试）" && c.toggle.title == "开启合盖运行", "unauthorized restore is named and not retried: \(c.header.title) writes=\(writes)")
                    check(visibleTitles().count == 4 && !visibleTitles().contains { $0.contains("部分") }, "menu never shows a partial state")
                    c.defaults.removePersistentDomain(forName: "local.reminal.clamshellassistant.selftest")
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
#endif
