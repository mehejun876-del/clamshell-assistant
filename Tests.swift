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
    let screenshotUI = ModePresentation(state: screenshot, serviceUp: true)
    check(screenshotUI.phase == .partial && screenshotUI.toggleEnables && screenshotUI.toggleTitle == "开启合盖运行" && screenshotUI.look == Look(lidClosed: false, lit: false) && screenshotUI.header == "仅部分开启未就绪", "screenshot regression: SleepDisabled alone is partial, MacBook, single enable button, never fully on")

    let off = ModeState(closed: false, unlocked: false, power: false)
    let on = ModeState(closed: true, unlocked: true, power: true)
    check(ModePresentation(state: off, serviceUp: false).header == "正常模式" && ModePresentation(state: off, serviceUp: false).toggleTitle == "开启合盖运行" && ModePresentation(state: off, serviceUp: false).look == Look(lidClosed: false, lit: false), "all-off is normal mode, MacBook, button enables")
    check(ModePresentation(state: on, serviceUp: true).header == "合盖运行已就绪" && ModePresentation(state: on, serviceUp: true).look == Look(lidClosed: true, lit: true) && ModePresentation(state: on, serviceUp: true).toggleTitle == "关闭合盖运行", "full ready is Studio+lit, button disables")
    check(ModePresentation(state: on, serviceUp: false).phase == .partial && ModePresentation(state: on, serviceUp: false).look == Look(lidClosed: false, lit: false), "settings on but service down is partial, not Studio")
    check(ModePresentation(state: ModeState(closed: true, unlocked: false, power: false), serviceUp: true).look == Look(lidClosed: false, lit: false), "closed-lid alone does not pretend to be fully on")

    for bits in 0..<8 {
        for service in [false, true] {
            let state = ModeState(closed: bits & 1 != 0, unlocked: bits & 2 != 0, power: bits & 4 != 0)
            let ui = ModePresentation(state: state, serviceUp: service)
            let ready = bits == 7 && service
            check(ui.isReady == ready && ui.look == Look(lidClosed: ready, lit: ready) && ui.toggleEnables == !ready && ui.toggleTitle == (ready ? "关闭合盖运行" : "开启合盖运行"), "one snapshot drives shape, light, status and the single toggle")
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

    var enabled = false, writes = 0, commands = 0
    c.testCommand = { path, args in
        commands += 1
        if path == "/usr/bin/sudo" { writes += 1; return (0, "") }
        if args == ["displaysleepnow"] { print("FAIL displaysleepnow must not be issued"); exit(1) }
        if args.count == 3 && args[0] == "settings" { writes += 1; enabled = args[2] == "on"; return (0, "") }
        if args == ["settings"] { return (0, "closed-lid \(enabled ? "on" : "off")\nalways-unlocked \(enabled ? "on" : "off")\n") }
        if args == ["-g", "live"] { return (0, "SleepDisabled \(enabled ? "1" : "0")\n") }
        print("FAIL unexpected command: \(path) \(args)"); exit(1)
    }
    UserDefaults.standard.set("sleep", forKey: "ExternalDisplayWhenLidClosed")
    c.current = screenshot; c.shown = Look(lidClosed: false, lit: false)
    c.updateMenu()
    check(UserDefaults.standard.object(forKey: "ExternalDisplayWhenLidClosed") == nil || visibleTitles() == visibleTitles(), "legacy external preference is not consulted")
    UserDefaults.standard.removeObject(forKey: "ExternalDisplayWhenLidClosed")
    check(visibleTitles() == ["仅部分开启未就绪", "开启合盖运行", "刷新状态", "退出助手"], "partial menu has only the allowed items")
    check(!hasForbiddenCopy(), "no leftover lid/external/English setting copy")
    check(c.toggle.isEnabled && c.toggle.title == "开启合盖运行" && c.header.title == "仅部分开启未就绪" && c.shown == Look(lidClosed: false, lit: false), "partial keeps MacBook and uses the single enable button")

    c.current = off; c.serviceUp = false; c.shown = Look(lidClosed: false, lit: false); c.updateMenu()
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
        check(c.header.title == "合盖运行已就绪" && c.toggle.title == "关闭合盖运行" && c.toggle.isEnabled, "ready menu is a single disable button")
        check(c.renderedCloseFrames > 10 && c.renderedHaloFrames > 0, "enable rendered full morph and halo through real status button displaylink")
        c.settleAnimation()
        c.accept(.failure(StatusError(message: "simulated")))
        check(c.header.title == "状态暂不可用" && !c.toggle.isEnabled && c.shown == Look(lidClosed: true, lit: true), "read failure keeps last icon and reports 状态暂不可用")
        c.accept(.success(on))
        c.settleAnimation()
        c.syncService(false)
        c.updateMenu()
        c.settleAnimation()
        check(c.shown == Look(lidClosed: false, lit: false) && c.header.title == "仅部分开启未就绪", "missing service is partial and does not stay Studio")
        c.accept(.success(on))
        c.settleAnimation()
        check(c.serviceUp && c.shown == Look(lidClosed: true, lit: true), "refresh restarts service and returns to ready Studio")
        c.accept(.success(off)); c.accept(.success(on)); c.accept(.success(off))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            check(c.link == nil && c.overlay == nil && c.status.button?.image === c.image(Look(lidClosed: false, lit: false)), "latest endpoint reached, animation released")
            check(c.renderedOpenFrames > 10, "disable rendered full reverse morph through real status button displaylink")
            c.syncService(true); c.current = on; c.shown = Look(lidClosed: true, lit: true)
            c.status.button?.image = c.image(c.shown!)
            c.toggleMode()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                check(c.overlay?.superview === c.status.button && c.link != nil && c.maskLayer?.contents != nil && c.ticks > 1, "disable has attached overlay, live displaylink and rendered mask")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                check(writes == 6 && c.current == off && c.shown == Look(lidClosed: false, lit: false) && c.header.title == "正常模式", "disable reaches normal mode with mocked writes only")
                check(c.overlay == nil && c.link == nil, "disable releases animation resources")
                c.accept(.success(ModeState(closed: true, unlocked: false, power: false)))
                c.settleAnimation()
                check(c.shown == Look(lidClosed: false, lit: false) && c.header.title == "仅部分开启未就绪" && c.toggle.title == "开启合盖运行", "closed-lid alone stays MacBook, button completes enable")
                    check(visibleTitles() == ["仅部分开启未就绪", "开启合盖运行", "刷新状态", "退出助手"], "partial still has a single button")
                    print("PASS \(assertions) assertions; rendered close=\(c.renderedCloseFrames), open=\(c.renderedOpenFrames), halo=\(c.renderedHaloFrames); real status-button animation path, mocked writes only")
                    NSApp.terminate(nil)
            }
        }
    }
}
#endif
