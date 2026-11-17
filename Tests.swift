#if SELFTEST
import AppKit

func runSelfTests(_ c: Controller) {
    var assertions = 0
    func check(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard value() else { print("FAIL: " + message); exit(1) }
    }
    if ProcessInfo.processInfo.environment["VERIFY_LIVE"] == "1" {
        let live = try! readState(reminal: ProcessInfo.processInfo.environment["LIVE_REMINAL"] ?? c.reminal) { runCommand($0, $1) }
        print("PASS passive live read: closed-lid=\(live.closed) unlocked=\(live.unlocked) sleepDisabled=\(live.power) lidClosed=\(readLidClosed()) external=\(hasExternalDisplay())")
    }
    let off = ModeState(closed: false, unlocked: false, power: false)
    let on = ModeState(closed: true, unlocked: true, power: true)
    let parsed = try! parseState(settings: "reminal settings:\n closed-lid\t on\n always-unlocked    on\n", power: " SleepDisabled  1\n")
    check(parsed == on, "whitespace-independent state parsing")
    for bits in 0..<8 {
        let s = ModeState(closed: bits & 1 != 0, unlocked: bits & 2 != 0, power: bits & 4 != 0)
        check(s.allOn == (bits == 7) && s.configured == (bits != 0), "readiness combinations")
    }
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

    // Pose semantics: shape = closed-lid mode, light = ready.
    check(Pose.still(Look(lidClosed: true, lit: false)).mw == 1 && Pose.still(Look(lidClosed: true, lit: false)).led == 0, "closed lid shows Studio, dark light")
    check(Pose.still(Look(lidClosed: false, lit: true)).mw == 0 && Pose.still(Look(lidClosed: false, lit: true)).lapLed == 1, "open lid shows MacBook, lit light")
    for kind in [Kind.close(true, false), .close(false, true), .open(true, false), .open(false, true), .led(true, true), .led(false, false)] {
        let end = kind.pose(1), start = kind.pose(0)
        switch kind {
        case .close(let f, let t): check(abs(end.mw - 1) < 0.02 && (end.led > 0.9) == t && (start.lapLed > 0.9) == f, "close endpoints")
        case .open(let f, let t): check(end.mw < 0.01 && (end.lapLed > 0.9) == t && (start.led > 0.9) == f, "open endpoints")
        case .led(let cl, let o): check(((cl ? end.led : end.lapLed) > 0.9) == o && (cl ? end.mw == 1 : end.mw == 0), "led endpoints keep shape")
        default: break
        }
    }

    // All mode writes are intercepted: no pmset/settings mutation is executed. No `list`/`new` session commands may appear.
    var enabled = false, writes = 0, commands = 0, displaySleeps = 0
    c.testCommand = { path, args in
        commands += 1
        if path == "/usr/bin/sudo" { writes += 1; return (0, "") }
        if args == ["displaysleepnow"] { displaySleeps += 1; return (0, "") }
        if args.count == 3 && args[0] == "settings" { writes += 1; enabled = args[2] == "on"; return (0, "") }
        if args == ["settings"] { return (0, "closed-lid \(enabled ? "on" : "off")\nalways-unlocked \(enabled ? "on" : "off")\n") }
        if args == ["-g", "live"] { return (0, "SleepDisabled \(enabled ? "1" : "0")\n") }
        print("FAIL unexpected command: \(path) \(args)"); exit(1)
    }
    UserDefaults.standard.removeObject(forKey: c.externalKey)
    check(!c.externalSleeps, "external display choice defaults to keep on")
    c.current = off; c.shown = Look(lidClosed: false, lit: false)
    c.refresh()
    c.toggleMode(); c.toggleMode(); c.toggleMode()
    for _ in 0..<100 { c.refresh() }
    check(c.busy && !c.toggle.isEnabled, "toggle guarded during mutation")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        check(c.overlay?.superview === c.status.button && c.link != nil && c.maskLayer?.contents != nil && c.ticks > 1, "toggle enable has attached overlay, live displaylink and rendered mask")
        if case .close = c.pending?.0 {} else { check(false, "enable must use full close morph, not just LED") }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        check(writes == 3, "rapid clicks cause exactly one mode operation (mocked)")
        check(commands < 20, "refresh requests coalesced")
        check(c.current == on && c.serviceUp && c.ready, "enable starts closed-lid service; ready")
        check(c.shown == Look(lidClosed: true, lit: true), "open physical lid + enabled mode: Studio with light")
        check(c.renderedCloseFrames > 10 && c.renderedHaloFrames > 0, "toggle enable rendered full morph and halo through real status button displaylink")
        // Physical lid only updates the menu; never suppresses the mode animation.
        c.settleAnimation()
        c.lidChanged(true)
        check(c.shown == Look(lidClosed: true, lit: true) && c.lidItem.title == "盖子：已合上", "lid close -> Studio")
        c.accept(.failure(StatusError(message: "simulated")))
        check(c.header.title == "状态暂不可用" && !c.toggle.isEnabled && c.shown == Look(lidClosed: true, lit: true), "read failure reported, light kept, not hidden")
        c.accept(.success(on))
        c.settleAnimation()
        // Lid opens with service lost: shape MacBook, light off, menu names the missing part.
        c.syncService(false); c.lidChanged(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            check(c.shown == Look(lidClosed: true, lit: false) && c.detail.title.contains("合盖服务"), "missing service keeps Studio and darkens light, menu reports missing service")
            c.accept(.success(on))    // refresh restarts the service
            check(c.serviceUp, "refresh restarts service")
            // External display choice: only when chosen, ready, lid closed, external present.
            c.externalDisplayPresent = { true }
            c.lidChanged(true)              // default keep: nothing
            c.settleAnimation(); c.lidChanged(false); c.settleAnimation()
            c.chooseExternal(c.externalSleep)
            check(c.externalSleeps && c.externalSleep.state == .on, "choice persisted, applied only on next lid close")
            check(displaySleeps == 0, "choosing does not sleep a display")
            c.lidChanged(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                check(displaySleeps == 1, "sleep choice: one display sleep after lid close")
                c.settleAnimation(); c.lidChanged(false); c.settleAnimation()
                c.externalDisplayPresent = { false }; c.lidChanged(true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                    check(displaySleeps == 1, "no external display: nothing slept")
                    UserDefaults.standard.removeObject(forKey: c.externalKey)
                    // Opposite targets mid-animation end at the latest one.
                    c.settleAnimation()
                    c.accept(.success(off)); c.accept(.success(on)); c.accept(.success(off))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                        check(c.link == nil && c.overlay == nil && c.status.button?.image === c.image(Look(lidClosed: false, lit: false)), "latest endpoint reached, animation released")
                        check(c.renderedOpenFrames > 10, "disable rendered full reverse morph through real status button displaylink")
                        // Exercise the actual toggle selector in the other direction too (commands intercepted).
                        c.syncService(true); c.current = on; c.shown = Look(lidClosed: true, lit: true)
                        c.status.button?.image = c.image(c.shown!)
                        c.toggleMode()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            check(c.overlay?.superview === c.status.button && c.link != nil && c.maskLayer?.contents != nil && c.ticks > 1, "toggle disable has attached overlay, live displaylink and rendered mask")
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                            check(writes == 6 && c.current == off && c.shown == Look(lidClosed: false, lit: false), "toggle disable reaches normal mode with mocked writes only")
                            check(c.overlay == nil && c.link == nil, "disable releases animation resources")
                            c.accept(.success(ModeState(closed: true, unlocked: false, power: false)))
                            check(c.shown == Look(lidClosed: true, lit: false) && c.detail.title.contains("未就绪"), "closed-lid setting alone selects Studio; missing readiness honestly reported")
                            print("PASS \(assertions) assertions; rendered close=\(c.renderedCloseFrames), open=\(c.renderedOpenFrames), halo=\(c.renderedHaloFrames); real status-button animation path, mocked writes only")
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        }
    }
}
#endif
