#if SELFTEST
import AppKit

func runSelfTests(_ c: Controller) {
    var assertions = 0
    func check(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard value() else { print("FAIL: " + message); exit(1) }
    }
    if ProcessInfo.processInfo.environment["VERIFY_LIVE"] == "1" {
        let live = try! readState(reminal: c.reminal) { runCommand($0, $1) }
        print("PASS passive live read: closed=\(live.closed) unlocked=\(live.unlocked) power=\(live.power) session=\(live.session)")
    }
    let off = ModeState(closed: false, unlocked: false, power: false, session: true)
    let on = ModeState(closed: true, unlocked: true, power: true, session: true)
    let settings = "reminal settings:\n closed-lid\t on\n always-unlocked    on\n"
    let parsed = try! parseState(settings: settings, power: " SleepDisabled  1\n", sessions: "  lid-agent ABCD1234 idle 2h title\n")
    check(parsed == on, "whitespace-independent state parsing")
    check(!off.active && !off.configured, "remaining session alone is not lid mode")
    for bits in 0..<16 {
        let s = ModeState(closed: bits & 1 != 0, unlocked: bits & 2 != 0, power: bits & 4 != 0, session: bits & 8 != 0)
        check(s.active == (bits == 15), "all readiness combinations")
        check(s.configured == (bits & 7 != 0), "partial settings not normal")
    }
    do { _ = try parseState(settings: "", power: "", sessions: ""); check(false, "malformed state rejected") }
    catch { check(true, "malformed state rejected") }
    do {
        _ = try readState(reminal: "fake") { _, args in args == ["settings"] ? (1, "network error") : (0, "") }
        check(false, "command failure rejected")
    } catch { check(true, "command failure rejected") }
    check(runCommand("/bin/echo", ["hello"]).1 == "hello\n", "command output")
    check(runCommand("/bin/sh", ["-c", "exit 7"]).0 == 7, "nonzero exit")
    check(runCommand("/not/a/program", []).0 != 0, "launch failure")
    let start = Date()
    check(runCommand("/bin/sleep", ["10"], timeout: 0.1).0 == 124, "timeout returns failure")
    check(Date().timeIntervalSince(start) < 3, "timeout bounded")
    let large = runCommand("/usr/bin/awk", ["BEGIN { for(i=0;i<100000;i++) print \"0123456789\" }"])
    check(large.0 == 0 && large.1.utf8.count == 1100000, "large output cannot fill a pipe")

    // All mode writes below are intercepted: no pmset/settings/session mutation is executed.
    var enabled = false, writes = 0, commands = 0
    c.testCommand = { path, args in
        commands += 1
        if path == "/usr/bin/sudo" { writes += 1; return (0, "") }
        if args.count == 3 && args[0] == "settings" { writes += 1; enabled = args[2] == "on"; return (0, "") }
        if args == ["settings"] { return (0, "closed-lid \(enabled ? "on" : "off")\nalways-unlocked \(enabled ? "on" : "off")\n") }
        if args == ["-g", "live"] { return (0, "SleepDisabled \(enabled ? "1" : "0")\n") }
        if args == ["list", "lid-agent"] { return (0, " lid-agent ABCD1234 idle 2h title\n") }
        print("FAIL unexpected command: \(path) \(args)"); exit(1)
    }
    c.current = off; c.shownActive = false; c.status.button?.image = c.offImage
    c.refresh()
    c.toggleMode(); c.toggleMode(); c.toggleMode()
    for _ in 0..<100 { c.refresh() }
    check(c.busy && !c.toggle.isEnabled, "toggle guarded and menu disabled during mutation")
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        check(writes == 3, "rapid clicks cause exactly one mode operation (mocked)")
        check(commands < 20, "refresh requests coalesced")
        check(c.current == on && !c.busy && !c.checking, "stale pre-toggle read cannot overwrite final state")
        c.accept(.failure(StatusError(message: "simulated offline")))
        check(c.current == on && c.shownActive == true, "failed reads preserve last icon and state")
        check(c.header.title == "状态暂不可用" && !c.toggle.isEnabled, "unknown state explicitly reported")
        c.accept(.success(on))
        check(c.toggle.isEnabled, "successful read recovers")
        c.settleAnimation()
        check(c.link == nil && c.overlay == nil && c.ctx == nil, "wake/screen-change settles and releases animation")
        // Opposite state arrives mid-transition; finish current morph before reversing.
        c.shownActive = false; c.current = on; c.updateMenu()
        c.current = off; c.updateMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            check(c.shownActive == false && c.link == nil && c.overlay == nil, "opposite state during animation reaches latest endpoint")
            check(c.status.button?.image === c.offImage, "final image matches state")
            print("PASS \(assertions) assertions; mocked mode writes only; no power or Reminal setting changes")
            NSApp.terminate(nil)
        }
    }
}
#endif
