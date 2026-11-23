#if SELFTEST
import Foundation
import SQLite3

// V2.1 pure-logic tests: the display-only battery/thermal line, agent sessions and per-agent
// counts, the unified decision (fully automatic AI smart mode), lease ownership, hook mapping,
// socket message validation, hook file editing (on temp files only) and the capped log. No real system setting is read or
// written here; every input is injected.
func runPolicyTests(_ expect: (Bool, String) -> Void) {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    func batt(_ p: Int?, ac: Bool?) -> BatteryReading { BatteryReading(present: true, percent: p, onAC: ac) }

    // ---- Battery / thermal: display only -----------------------------------------------
    expect(powerStatusLine(battery: batt(85, ac: true), thermal: .nominal) == "电池 85% · 散热正常", "status line on AC")
    expect(powerStatusLine(battery: batt(12, ac: false), thermal: .critical) == "电池 12% · 散热危急", "status line on battery, critical pressure")
    expect(powerStatusLine(battery: nil, thermal: .fair).hasPrefix("电池未知"), "unreadable battery is shown as unknown")
    expect(powerStatusLine(battery: BatteryReading(present: false, percent: nil, onAC: nil), thermal: .nominal).hasPrefix("无电池"), "Macs without a battery")
    expect(!powerStatusLine(battery: batt(50, ac: true), thermal: .serious).contains("°"), "no temperature in degrees is ever claimed")
    expect(ThermalLevel(.critical) == .critical && ThermalLevel.serious.label == "严重", "thermal levels mirror ProcessInfo; labels are pressure, not degrees")

    // ---- Agent sessions ---------------------------------------------------------------
    func ev(_ k: AgentKind, _ s: String, _ p: AgentPhase, _ t: Double) -> AgentEvent { AgentEvent(kind: k, session: hashSession(s), phase: p, sentAt: t) }
    var tr = AgentTracker()
    tr.apply(ev(.codex, "A", .responding, 1), now: at(0))
    tr.apply(ev(.gemini, "B", .tool, 1), now: at(1))
    expect(tr.counts(now: at(2)).active == 2, "two agents in parallel")
    tr.apply(ev(.codex, "A", .turnDone, 2), now: at(10))
    expect(tr.keepsAwake(now: at(11)) && tr.idleSince == nil, "one finished, the other keeps the Mac awake")
    tr.apply(ev(.gemini, "B", .turnDone, 2), now: at(20))
    expect(!tr.keepsAwake(now: at(21)) && tr.idleSince == at(20), "both finished: idle since the last one")
    // Buffer: decision stays on during grace, new task cancels the pending sleep.
    let cfg = AgentConfig()
    func dec(_ tr: AgentTracker, _ now: Date, intent: Bool? = false, suppressed: Bool = false) -> Decision {
        decidePower(intent: intent, smart: true, agentsAwake: tr.keepsAwake(now: now), idleSince: tr.idleSince, suppressed: suppressed, now: now, config: cfg)
    }
    expect(dec(tr, at(20 + 179)) == Decision(want: true, hold: nil, auto: true), "within the 3-minute buffer: still awake, by AI")
    expect(dec(tr, at(20 + 180)) == Decision(want: false, hold: .smartIdle), "after the buffer: sleep allowed")
    var tr2 = tr
    tr2.apply(ev(.codex, "C", .responding, 3), now: at(100))
    expect(dec(tr2, at(20 + 400)).want == true && tr2.idleSince == nil, "a new task during the buffer cancels the pending sleep")
    expect(dec(AgentTracker(), at(0)) == Decision(want: false, hold: .smartIdle), "AI smart mode with no task: nothing kept awake, no waiting window")
    var opened = AgentTracker()
    opened.apply(ev(.codex, "O", .started, 1), now: at(0))
    expect(opened.idleSince == nil && dec(opened, at(1)).want == false, "a session that only opened is not a task and starts no buffer")
    var relaunch = AgentTracker()
    relaunch.beginGrace(now: at(0))
    expect(dec(relaunch, at(179)).want == true && dec(relaunch, at(181)).want == false, "after a relaunch that held keep-awake: one buffer for agents to report again")
    var cleared = tr
    cleared.clearIdle()
    expect(dec(cleared, at(30)) == Decision(want: false, hold: .smartIdle), "a manual off during the buffer ends it at once")
    // Waiting for approval is bounded.
    var w = AgentTracker()
    w.apply(ev(.codex, "W", .waiting, 1), now: at(0))
    expect(w.keepsAwake(now: at(1799)) && w.counts(now: at(1)).waiting == 1, "waiting for approval keeps awake")
    expect(!w.keepsAwake(now: at(1800)), "waiting longer than 30 minutes no longer keeps awake")
    // Interrupt.
    var it = AgentTracker()
    it.apply(ev(.codex, "I", .tool, 1), now: at(0))
    it.apply(ev(.codex, "I", .interrupted, 2), now: at(5))
    expect(!it.keepsAwake(now: at(6)), "interrupted turn is not activity")
    // Delayed, duplicated, lost events.
    var dl = AgentTracker()
    dl.apply(ev(.grok, "D", .turnDone, 10), now: at(0))
    dl.apply(ev(.grok, "D", .tool, 5), now: at(1))           // arrives late
    expect(!dl.keepsAwake(now: at(2)), "a delayed older event cannot resurrect a finished turn")
    dl.apply(ev(.grok, "D", .tool, 11), now: at(3))
    let before = dl.sessions
    dl.apply(ev(.grok, "D", .tool, 11), now: at(4))         // duplicate
    expect(dl.sessions == before, "a duplicate delivery changes nothing")
    var lost = AgentTracker()
    lost.apply(ev(.codex, "L", .responding, 1), now: at(0))  // Stop never arrives
    expect(lost.liveness(lost.sessions.values.first!, now: at(1199)) == .active, "silent but within lease: active")
    expect(lost.liveness(lost.sessions.values.first!, now: at(1300)) == .unknown && lost.keepsAwake(now: at(1300)), "lease passed: unknown, still counted (bounded check)")
    expect(lost.nextDeadline(now: at(1300)) == at(1800), "unknown has a hard end")
    lost.prune(now: at(1800))
    expect(lost.sessions.isEmpty && lost.idleSince == at(1800), "after the unknown grace the session expires")
    var longTool = AgentTracker()
    longTool.apply(ev(.codex, "T", .tool, 1), now: at(0))
    expect(longTool.keepsAwake(now: at(3000)), "a 50-minute tool call (build/test) is still active")
    // Ended session is removed at once.
    var en = AgentTracker()
    en.apply(ev(.antigravity, "E", .responding, 1), now: at(0))
    en.apply(ev(.antigravity, "E", .ended, 2), now: at(1))
    expect(en.sessions.isEmpty, "ended sessions are dropped immediately")
    // Bounded table.
    var cap = AgentTracker()
    for i in 0..<100 { cap.apply(ev(.other, "S\(i)", i % 2 == 0 ? .turnDone : .responding, Double(i)), now: at(Double(i))) }
    expect(cap.sessions.count <= cap.config.maxSessions, "session table never exceeds 32 entries (\(cap.sessions.count))")
    expect(cap.counts(now: at(100)).active > 0, "eviction prefers inactive sessions")

    // ---- Per-agent counts and submenu lines --------------------------------------------
    var multi = AgentTracker()
    multi.apply(ev(.codex, "c1", .responding, 1), now: at(0))
    multi.apply(ev(.codex, "c2", .tool, 1), now: at(0))
    multi.apply(ev(.gemini, "g1", .waiting, 1), now: at(0))
    multi.apply(ev(.antigravity, "a1", .background, 1), now: at(0))
    multi.apply(ev(.grok, "k1", .turnDone, 1), now: at(0))
    let byKind = multi.countsByKind(now: at(1))
    expect(byKind[.codex] == AgentCount(running: 2) && byKind[.gemini] == AgentCount(waiting: 1) && byKind[.antigravity] == AgentCount(background: 1) && byKind[.grok] == nil,
           "per-agent counts: running, waiting, background; finished agents are not listed")
    expect(agentTaskLines(byKind) == ["Codex：2 个进行中", "Gemini：1 个待确认", "Antigravity：1 个后台"], "one line per agent, in a fixed order")
    expect(agentTaskLines([:]).isEmpty, "no task: no agent lines")
    expect(agentTaskLines(multi.countsByKind(now: at(1300)))[0] == "Codex：1 个进行中，1 个未知", "a silent session is shown as unknown, still counted")
    expect(AgentKind.codex.label == "Codex", "Codex is named briefly")

    // ---- Unified decision priorities ---------------------------------------------------
    func decide(_ intent: Bool?, smart: Bool, agents: Bool, suppressed: Bool = false, idle: Date? = nil) -> Decision {
        decidePower(intent: intent, smart: smart, agentsAwake: agents, idleSince: idle, suppressed: suppressed, now: t0, config: cfg)
    }
    expect(decide(false, smart: true, agents: true) == Decision(want: true, hold: nil, auto: true), "AI smart mode: a running task keeps the Mac awake without any manual switch")
    expect(decide(nil, smart: true, agents: true) == Decision(want: true, hold: nil, auto: true), "AI smart mode works without a saved manual choice too")
    expect(decide(false, smart: true, agents: true, suppressed: true) == Decision(want: false, hold: .smartPaused), "switched off during this batch: no automatic re-enable")
    expect(decide(true, smart: true, agents: false) == Decision(want: true), "the manual switch on keeps the Mac awake regardless of agents")
    expect(decide(false, smart: false, agents: true) == Decision(want: false), "AI smart mode off: agents are irrelevant")
    expect(decide(nil, smart: false, agents: true).want == nil, "no saved choice and AI off: report only, as 1.4.1")
    expect(decide(true, smart: false, agents: false, idle: at(-9999)) == Decision(want: true), "classic one-click mode unchanged")
    // Battery and thermal pressure are not inputs of the decision at all (see decidePower's signature):
    // the controller tests feed 5 % on battery and critical pressure and check nothing changes.

    // ---- Lease ownership --------------------------------------------------------------
    let lease = KeepAwakeLease(pid: 4242, processStart: 777, bootSession: "boot-A", since: t0)
    expect(judgeLease(nil, ownerStart: { _ in 1 }, currentBoot: "boot-A") == .none, "no lease: nothing to recover")
    expect(judgeLease(lease, ownerStart: { $0 == 4242 ? 777 : nil }, currentBoot: "boot-A") == .liveOwner, "live owner is never touched")
    expect(judgeLease(lease, ownerStart: { _ in nil }, currentBoot: "boot-A") == .stale, "owner gone: stale")
    expect(judgeLease(lease, ownerStart: { _ in 999 }, currentBoot: "boot-A") == .stale, "PID reused by another process: stale, not live")
    expect(judgeLease(lease, ownerStart: { _ in 777 }, currentBoot: "boot-B") == .stale, "lease from before a reboot/power loss: stale")
    let leasePath = NSTemporaryDirectory() + "clamshell-selftest-lease-unit.json"
    let store = LeaseStore(path: leasePath)
    store.remove()
    expect(store.write(lease) && store.read() == lease, "lease round-trips through an atomic write")
    let perms = (try? FileManager.default.attributesOfItem(atPath: leasePath))?[.posixPermissions] as? Int
    expect(perms == 0o600, "lease file is 0600")
    store.remove()
    expect(processStartTime(getpid()) != nil && processStartTime(-1) == nil, "process identity from the kernel")
    expect(parseSleepDisabled(" SleepDisabled\t\t1\n") == true && parseSleepDisabled("SleepDisabled 0") == false && parseSleepDisabled("") == nil, "pmset SleepDisabled parsing")

    // ---- Hook mapping (official events only) ------------------------------------------
    expect(phaseFor(agent: .codex, event: "PermissionRequest", details: [:]) == .waiting, "Codex approval → waiting")
    expect(phaseFor(agent: .codex, event: "PreToolUse", details: [:]) == .tool && phaseFor(agent: .codex, event: "Stop", details: [:]) == .turnDone, "Codex tool / turn end")
    expect(phaseFor(agent: .codex, event: "Interrupt", details: [:]) == .interrupted, "Codex interrupt")
    expect(phaseFor(agent: .gemini, event: "Notification", details: ["notification_type": "ToolPermission"]) == .waiting, "Gemini tool permission → waiting")
    expect(phaseFor(agent: .gemini, event: "Notification", details: [:]) == nil, "other Gemini notifications are ignored")
    expect(phaseFor(agent: .antigravity, event: "Stop", details: ["fullyIdle": false]) == .background, "Antigravity: background work still running")
    expect(phaseFor(agent: .antigravity, event: "Stop", details: ["fullyIdle": true]) == .turnDone, "Antigravity: fully idle")
    expect(phaseFor(agent: .antigravity, event: "Stop", details: ["error": "x"]) == .interrupted, "Antigravity: error stop")
    expect(phaseFor(agent: .grok, event: "StopFailure", details: [:]) == .interrupted, "Grok: API error ends the turn")
    expect(phaseFor(agent: .kiro, event: "UserPromptSubmit", details: [:]) == .responding && phaseFor(agent: .kiro, event: "PostToolUse", details: [:]) == .responding
           && phaseFor(agent: .kiro, event: "Stop", details: [:]) == .turnDone && phaseFor(agent: .kiro, event: "SessionEnd", details: [:]) == .ended, "Kiro: prompt / tool / turn end / session end")
    expect(phaseFor(agent: .kiro, event: "PreToolUse", details: [:]) == nil && !HookTarget(kind: .kiro, file: "/x").events.contains("PreToolUse")
           && !HookTarget(kind: .kiro, file: "/x").events.contains("PermissionRequest"), "Kiro: gating events are never registered")
    expect(phaseFor(agent: .codex, event: "PreModelRequest", details: [:]) == nil, "unmapped events are ignored")
    let h = hashSession("thr_123")
    expect(h.count == 16 && h == hashSession("thr_123") && h != hashSession("thr_124") && !h.contains("thr"), "session ids are stored only as a 16-hex hash")

    // ---- Socket message validation ----------------------------------------------------
    let nowMs = t0.timeIntervalSince1970 * 1000
    func msg(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }
    let good = parseAgentMessage(msg(["v": 1, "a": "codex", "s": h, "p": "tool", "t": nowMs]), now: t0)
    expect(good == AgentEvent(kind: .codex, session: h, phase: .tool, sentAt: nowMs), "valid message accepted")
    expect(parseAgentMessage(msg(["v": 2, "a": "codex", "s": h, "p": "tool"]), now: t0) == nil, "unknown version rejected")
    expect(parseAgentMessage(msg(["v": 1, "a": "evil", "s": h, "p": "tool"]), now: t0) == nil, "unknown agent rejected")
    expect(parseAgentMessage(msg(["v": 1, "a": "codex", "s": "not-a-hash", "p": "tool"]), now: t0) == nil, "raw ids rejected")
    expect(parseAgentMessage(msg(["v": 1, "a": "codex", "s": h, "p": "run-forever"]), now: t0) == nil, "unknown phase rejected")
    expect(parseAgentMessage(Data(repeating: 32, count: 600), now: t0) == nil, "oversized message rejected")
    expect(parseAgentMessage(msg(["v": 1, "a": "codex", "s": h, "p": "tool", "t": nowMs + 9e9]), now: t0)?.sentAt == nowMs, "far-future stamp clamped")

    // ---- Hook files: add/remove only our handlers, never others -----------------------
    let home = NSTemporaryDirectory() + "clamshell-selftest-home-\(getpid())"
    try? FileManager.default.removeItem(atPath: home)
    let fm = FileManager.default
    try? fm.createDirectory(atPath: home + "/.codex", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: home + "/.gemini/config", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: home + "/.grok/hooks", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: home + "/.kiro", withIntermediateDirectories: true)
    let userKiro = "{\"version\":\"v1\",\"hooks\":[{\"name\":\"mine\",\"trigger\":\"Stop\",\"action\":{\"type\":\"command\",\"command\":\"say done\"}}]}"
    try? fm.createDirectory(atPath: home + "/.kiro/hooks", withIntermediateDirectories: true)
    _ = fm.createFile(atPath: home + "/.kiro/hooks/mine.json", contents: Data(userKiro.utf8))
    let helper = home + "/bin/clamshell-helper"
    try? fm.createDirectory(atPath: home + "/bin", withIntermediateDirectories: true)
    _ = fm.createFile(atPath: helper, contents: Data("#!/bin/sh\nexit 0\n".utf8), attributes: [.posixPermissions: 0o755])
    let userCodex = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"/usr/local/bin/my-notify\"}]}]},\"description\":\"mine\"}"
    _ = fm.createFile(atPath: home + "/.codex/hooks.json", contents: Data(userCodex.utf8), attributes: [.posixPermissions: 0o640])
    let userGemini = "{\"theme\":\"Dracula\",\"hooks\":{\"BeforeTool\":[{\"matcher\":\"write_file\",\"hooks\":[{\"name\":\"lint\",\"type\":\"command\",\"command\":\"lint.sh\"}]}]}}"
    _ = fm.createFile(atPath: home + "/.gemini/settings.json", contents: Data(userGemini.utf8))
    let userAg = "{\"my-linter\":{\"PostToolUse\":[{\"matcher\":\"run_command\",\"hooks\":[{\"command\":\"./lint.sh\"}]}]}}"
    _ = fm.createFile(atPath: home + "/.gemini/config/hooks.json", contents: Data(userAg.utf8))
    func failure(_ r: Result<Void, HookTarget.Failure>) -> HookTarget.Failure? { if case .failure(let f) = r { return f }; return nil }
    func json(_ path: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: fm.contents(atPath: path) ?? Data())) as? [String: Any] ?? [:] }
    let targets = HookTarget.all(home: home)
    for target in targets {
        expect(target.status() == .notInstalled, "\(target.kind.rawValue): not installed by default")
        expect(failure(target.install(helper: helper)) == nil, "\(target.kind.rawValue): install succeeds")
        expect(target.status() == .installed, "\(target.kind.rawValue): installed")
        expect(failure(target.install(helper: helper)) == nil, "\(target.kind.rawValue): installing twice succeeds without duplicating")
    }
    let codex = json(home + "/.codex/hooks.json")
    let codexStop = ((codex["hooks"] as? [String: Any])?["Stop"] as? [Any]) ?? []
    expect(codex["description"] as? String == "mine" && codexStop.count == 2, "Codex: user's own Stop hook and keys kept; ours added once")
    expect(((try? fm.attributesOfItem(atPath: home + "/.codex/hooks.json"))?[.posixPermissions] as? Int) == 0o640, "file permissions preserved")
    let backups = ((try? fm.contentsOfDirectory(atPath: home + "/.codex")) ?? []).filter { $0.contains("clamshell-backup") }
    expect(!backups.isEmpty, "a backup is made before every change")
    let gem = json(home + "/.gemini/settings.json")
    expect(gem["theme"] as? String == "Dracula" && (((gem["hooks"] as? [String: Any])?["BeforeTool"] as? [Any])?.count == 2), "Gemini: other settings and hooks kept")
    let ag = json(home + "/.gemini/config/hooks.json")
    expect(ag["my-linter"] != nil && ag["clamshell-assistant"] != nil, "Antigravity: our hooks live under their own name")
    let kiro = json(home + "/.kiro/hooks/clamshell-assistant.json")
    let kiroHooks = (kiro["hooks"] as? [[String: Any]]) ?? []
    expect(kiro["version"] as? String == "v1" && kiroHooks.count == 5 && Set(kiroHooks.compactMap { $0["trigger"] as? String }) == ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "SessionEnd"]
           && kiroHooks.allSatisfy { (($0["action"] as? [String: Any])?["command"] as? String)?.contains("clamshell-helper' hook kiro ") == true },
           "Kiro: our own standalone hook file, passive triggers only, each runs the helper")
    expect(json(home + "/.kiro/hooks/mine.json")["hooks"] != nil, "Kiro: the user's own hook file is untouched")
    expect(targets.allSatisfy { $0.isCurrent(helper: helper) } && !targets.contains { $0.isCurrent(helper: home + "/moved/clamshell-helper") },
           "hooks are recognised as pointing at this helper (and not at a moved copy)")
    let movedHelper = home + "/moved/clamshell-helper"
    try? fm.createDirectory(atPath: home + "/moved", withIntermediateDirectories: true)
    _ = fm.createFile(atPath: movedHelper, contents: Data("#!/bin/sh\nexit 0\n".utf8), attributes: [.posixPermissions: 0o755])
    let codexTarget = targets.first { $0.kind == .codex }!
    expect(failure(codexTarget.install(helper: movedHelper)) == nil && codexTarget.isCurrent(helper: movedHelper) && !codexTarget.isCurrent(helper: helper)
           && ((json(home + "/.codex/hooks.json")["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count == 2,
           "re-pointing the hooks at a moved app replaces ours, never duplicates them")
    for target in targets { expect(failure(target.uninstall()) == nil && target.status() == .notInstalled, "\(target.kind.rawValue): uninstalled") }
    let codexAfter = json(home + "/.codex/hooks.json")
    expect(((codexAfter["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count == 1 && codexAfter["description"] as? String == "mine", "Codex: uninstall restores the user's content")
    expect(json(home + "/.gemini/settings.json")["theme"] as? String == "Dracula", "Gemini: uninstall keeps other settings")
    expect(json(home + "/.gemini/config/hooks.json")["my-linter"] != nil && json(home + "/.gemini/config/hooks.json")["clamshell-assistant"] == nil, "Antigravity: only our entry removed")
    expect(!fm.fileExists(atPath: home + "/.grok/hooks/clamshell-assistant.json"), "Grok: our own file is removed")
    expect(!fm.fileExists(atPath: home + "/.kiro/hooks/clamshell-assistant.json") && fm.fileExists(atPath: home + "/.kiro/hooks/mine.json"), "Kiro: our own file is removed, the user's stays")
    _ = fm.createFile(atPath: home + "/.gemini/settings.json", contents: Data("{ // comment\n \"a\": 1 }".utf8))
    let geminiTarget = targets.first { $0.kind == .gemini }!
    expect(failure(geminiTarget.install(helper: helper)) == .unreadable && String(decoding: fm.contents(atPath: home + "/.gemini/settings.json")!, as: UTF8.self).contains("// comment"),
           "JSON with comments is refused and left untouched")
    let missing = HookTarget.all(home: home + "/nobody")
    expect(missing.allSatisfy { $0.status() == .agentMissing } && failure(missing[0].install(helper: helper)) == .agentMissing, "agents that are not installed are never configured")
    let onlyGemini = home + "/only-gemini"
    try? fm.createDirectory(atPath: onlyGemini + "/.gemini", withIntermediateDirectories: true)
    let og = HookTarget.all(home: onlyGemini)
    expect(og.first { $0.kind == .gemini }!.status() == .notInstalled && og.first { $0.kind == .antigravity }!.status() == .agentMissing,
           "Gemini CLI alone does not make Antigravity look installed")
    try? fm.createDirectory(atPath: onlyGemini + "/.gemini/antigravity", withIntermediateDirectories: true)
    expect(og.first { $0.kind == .antigravity }!.status() == .notInstalled, "Antigravity is recognised by its own directory")
    // ---- Codex system-level hooks (/etc/codex/hooks.json, trusted by policy) -----------
    let sysPath = home + "/etc-codex/hooks.json"
    func planData(_ p: CodexSystemHooks.Plan) -> Data? { if case .write(let d) = p { return d }; return nil }
    let firstPlan = planData(CodexSystemHooks.plan(install: true, helper: helper, path: sysPath))
    expect(firstPlan != nil && firstPlan == planData(CodexSystemHooks.plan(install: true, helper: helper, path: sysPath)),
           "Codex system hooks: a new file is planned, byte-identical every time")
    try? fm.createDirectory(atPath: home + "/etc-codex", withIntermediateDirectories: true)
    _ = fm.createFile(atPath: sysPath, contents: firstPlan)
    expect(CodexSystemHooks.isActive(helper: helper, path: sysPath) && CodexSystemHooks.plan(install: true, helper: helper, path: sysPath) == .upToDate,
           "Codex system hooks: written once, then up to date (no repeated password prompts)")
    expect(!CodexSystemHooks.isActive(helper: home + "/moved/clamshell-helper", path: sysPath), "Codex system hooks: a moved app is detected as out of date")
    expect(CodexSystemHooks.plan(install: false, helper: "-", path: sysPath) == .remove, "Codex system hooks: a file holding only ours is deleted on uninstall")
    _ = fm.createFile(atPath: sysPath, contents: Data(userCodex.utf8))
    let merged = (try? JSONSerialization.jsonObject(with: planData(CodexSystemHooks.plan(install: true, helper: helper, path: sysPath)) ?? Data())) as? [String: Any] ?? [:]
    expect(((merged["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count == 2 && merged["description"] as? String == "mine",
           "Codex system hooks: an administrator's own hooks are kept")
    _ = fm.createFile(atPath: sysPath, contents: planData(CodexSystemHooks.plan(install: true, helper: helper, path: sysPath)))
    let stripped = (try? JSONSerialization.jsonObject(with: planData(CodexSystemHooks.plan(install: false, helper: "-", path: sysPath)) ?? Data())) as? [String: Any] ?? [:]
    expect(((stripped["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count == 1 && !HookTarget(kind: .codex, file: sysPath).containsOurs(stripped),
           "Codex system hooks: uninstall removes only ours")
    _ = fm.createFile(atPath: sysPath, contents: Data("{ // comment\n}".utf8))
    expect(CodexSystemHooks.plan(install: true, helper: helper, path: sysPath) == .unreadable, "Codex system hooks: a non-JSON file is never touched")
    try? fm.removeItem(atPath: home)

    // ---- Agents without hooks: AWS Quick's log tags, Codex's state, Codex Keyboard ------------
    expect(quickLogPhase("[2026-11-23T10:15:55Z] [INFO] [rlog:outpost_tool_call_started] {\"event\":1}") == .responding
           && quickLogPhase("[x] [INFO] [OutpostACP] progress") == .responding
           && quickLogPhase("[x] [INFO] [ChatTurn] time_to_complete 1234") == .turnDone
           && quickLogPhase("[x] [INFO] [NookAuth] nook-invoke-agent called") == nil, "AWS Quick: only fixed tags are recognised")
    expect(quickLogLastPhase("a [TTFT] time_to_first_token\nb [ChatTurn] time_to_complete\n") == .turnDone
           && quickLogLastPhase("a [ChatTurn] time_to_complete\nb [rlog:outpost_tool_call_finished]\n") == .responding
           && quickLogLastPhase("nothing here\n") == nil, "AWS Quick: the newest tag in a chunk wins")
    let qdir = NSTemporaryDirectory() + "clamshell-selftest-quicklog-\(getpid())"
    try? FileManager.default.removeItem(atPath: qdir)
    try? FileManager.default.createDirectory(atPath: qdir, withIntermediateDirectories: true)
    _ = FileManager.default.createFile(atPath: qdir + "/quickwork-2026-11-23-10.log", contents: Data("old [rlog:outpost_tool_call_started]\n".utf8))
    var phases: [AgentPhase] = []
    let qm = QuickLogMonitor(dir: qdir) { phases.append($0) }
    qm.start()
    qm.changed()
    expect(phases.isEmpty, "AWS Quick: lines written before launch are never replayed")
    if let h = FileHandle(forWritingAtPath: qdir + "/quickwork-2026-11-23-10.log") {
        h.seekToEndOfFile(); h.write(Data("x [INFO] [rlog:outpost_tool_call_started] {}\n".utf8)); try? h.close()
    }
    qm.changed()
    _ = FileManager.default.createFile(atPath: qdir + "/quickwork-2026-11-23-11.log", contents: Data("y [ChatTurn] time_to_complete\n".utf8))
    qm.changed()
    expect(phases == [.responding, .turnDone] && qm.file?.hasSuffix("-11.log") == true, "AWS Quick: appended lines are read, and the next hour's file from its start")
    qm.stop()
    try? FileManager.default.removeItem(atPath: qdir)

    let nowS = t0.timeIntervalSince1970
    let ck = "{\"observedAt\":\(nowS),\"slots\":[{\"id\":\"01a207e0-aaaa\",\"status\":\"working\"},{\"id\":\"\",\"status\":\"unassigned\"},{\"id\":\"01a207e1-bbbb\",\"status\":\"idle\"}],\"remoteStatuses\":{\"remote-control:env:01a207e5\":\"working\",\"remote-control:env:x\":\"idle\"}}"
    expect(codexKeyboardWorking(Data(ck.utf8), now: t0) == ["01a207e0-aaaa", "remote-control:env:01a207e5"], "Codex Keyboard: local and remote working entries")
    expect(codexKeyboardWorking(Data(ck.utf8), now: t0.addingTimeInterval(3600)) == nil && codexKeyboardWorking(Data("nope".utf8), now: t0) == nil,
           "Codex Keyboard: a stale or broken file concludes nothing")
    let evs = codexStateEvents(before: ["a", "b"], after: ["b", "c"], sentAt: 5)
    expect(evs.filter { $0.phase == .tool }.map(\.session).sorted() == [hashSession("b"), hashSession("c")].sorted()
           && evs.filter { $0.phase == .turnDone }.map(\.session) == [hashSession("a")] && evs.allSatisfy { $0.kind == .codex },
           "Codex state: running turns are refreshed, finished ones end")
    var ctr = AgentTracker()
    for e in codexStateEvents(before: [], after: ["t1"], sentAt: 1) { ctr.apply(e, now: t0) }
    expect(ctr.keepsAwake(now: t0.addingTimeInterval(3000)) && ctr.countsByKind(now: t0)[.codex] == AgentCount(running: 1), "Codex state: a long Work turn keeps the Mac awake")
    for e in codexStateEvents(before: ["t1"], after: [], sentAt: 2) { ctr.apply(e, now: t0.addingTimeInterval(60)) }
    expect(!ctr.keepsAwake(now: t0.addingTimeInterval(61)) && ctr.idleSince == t0.addingTimeInterval(60), "Codex state: the turn ends, the 3-minute buffer starts")
    let dbPath = NSTemporaryDirectory() + "clamshell-selftest-codex-\(getpid()).db"
    try? FileManager.default.removeItem(atPath: dbPath)
    expect(codexActiveTurns(dbPath: dbPath) == nil, "Codex state: a missing database is unreadable, not empty")
    var tdb: OpaquePointer?
    if sqlite3_open(dbPath, &tdb) == SQLITE_OK {
        _ = sqlite3_exec(tdb, "create table active_chat_turns (profile text, account_id text, user_id text, thread_id text, launch_id text, observed_at_ms integer); insert into active_chat_turns values ('p','a','u','01a207e0-x','l',1),('p','a','u','01a207e1-y','l',2);", nil, nil, nil)
    }
    sqlite3_close(tdb)
    expect(codexActiveTurns(dbPath: dbPath) == ["01a207e0-x", "01a207e1-y"], "Codex state: running turns are read from its own database (read-only)")
    try? FileManager.default.removeItem(atPath: dbPath)
    expect(AgentKind.quick.label == "AWS Quick" && HookTarget(kind: .quick, file: "/x").events.isEmpty, "AWS Quick: shown by name, no hook file is ever written for it")

    // ---- Capped log ------------------------------------------------------------------
    let logPath = NSTemporaryDirectory() + "clamshell-selftest-\(getpid()).log"
    let oldLimit = EventLog.limit
    EventLog.limit = 2000
    for i in 0..<200 { EventLog.write("entry \(i)", path: logPath) }
    let size = ((try? fm.attributesOfItem(atPath: logPath))?[.size] as? Int) ?? Int.max
    expect(size <= 2000 + 200, "log size is capped (\(size) bytes)")
    EventLog.limit = oldLimit
    try? fm.removeItem(atPath: logPath); try? fm.removeItem(atPath: logPath + ".1")
}
#endif
