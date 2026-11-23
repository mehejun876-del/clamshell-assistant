import Foundation

// Clamshell Assistant V2 — pure decision logic (no AppKit, no IOKit, no I/O).
//
// Everything here is a value type driven by explicit inputs and an explicit `now`, so
// the self-tests replay agent sequences without touching the real system. Nothing in this file schedules timers: each model only reports the next instant
// at which its answer could change (`nextDeadline`), and the controller arms at most ONE
// one-shot timer (with tolerance) for the earliest of them. With nothing pending there is
// no timer at all, so an idle assistant adds no periodic wake-ups.

// MARK: - Battery and thermal pressure (display only)

// V2.1: battery and thermal pressure are shown in the submenu and never take part in any
// decision. They are read once each time the submenu opens; nothing watches them. macOS's own
// hardware protection still applies (it shuts the Mac down when it is too hot or the battery is empty).

/// One reading of the internal battery. `present == false` on Macs without a battery.
struct BatteryReading: Equatable {
    var present: Bool
    var percent: Int?      // 0...100, nil when the capacity keys are missing
    var onAC: Bool?        // nil when the power source state is missing
}

/// macOS reports *thermal pressure*, not a temperature. These levels mirror
/// ProcessInfo.ThermalState and are never converted to degrees.
enum ThermalLevel: Int, Comparable {
    case nominal = 0, fair, serious, critical
    static func < (a: ThermalLevel, b: ThermalLevel) -> Bool { a.rawValue < b.rawValue }
    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }
    var label: String {
        switch self {
        case .nominal: return "正常"
        case .fair: return "偏高"
        case .serious: return "严重"
        case .critical: return "危急"
        }
    }
}

/// The read-only first line of the advanced submenu.
func powerStatusLine(battery: BatteryReading?, thermal: ThermalLevel) -> String {
    let power: String
    if let b = battery {
        if !b.present { power = "无电池" }
        else { power = "电池 " + (b.percent.map { "\($0)%" } ?? "--") }
    } else { power = "电池未知" }
    return power + " · 散热" + thermal.label
}

// MARK: - AI agent sessions

enum AgentKind: String, CaseIterable {
    case codex, gemini, antigravity, grok, kiro, quick, other
    var label: String {
        switch self {
        case .codex: return "Codex"      // the Codex app, the ChatGPT app's Codex and the CLI share ~/.codex
        case .gemini: return "Gemini"
        case .antigravity: return "Antigravity"
        case .grok: return "Grok Build"
        case .kiro: return "Kiro"
        case .quick: return "AWS Quick"
        case .other: return "其他 Agent"
        }
    }
}

/// What a hook event says about one session. Only these phases are ever stored —
/// never prompts, replies, tool arguments, paths or keys.
enum AgentPhase: String {
    case started      // session opened, idle until the user submits a prompt
    case responding   // the model is working on a turn
    case tool         // a tool call is running
    case waiting      // waiting for the user's approval
    case background   // the turn ended but background work is still running (Antigravity fullyIdle=false)
    case turnDone     // this turn completed
    case interrupted  // the turn was interrupted or failed
    case ended        // the session closed
}

struct AgentEvent: Equatable {
    var kind: AgentKind
    var session: String       // already hashed by the hook client; never a raw id
    var phase: AgentPhase
    var sentAt: Double        // sender's clock (ms since 1970): orders delayed or duplicated deliveries
}

struct AgentConfig: Equatable {
    var grace: TimeInterval = 180            // after the last task finishes, wait this long before allowing sleep
    var waitMax: TimeInterval = 1800         // waiting for approval keeps the Mac awake at most this long
    var respondingLease: TimeInterval = 1200 // silent this long while "responding" → state unknown
    var toolLease: TimeInterval = 3600       // long builds/tests run inside a single tool call
    var backgroundLease: TimeInterval = 1800
    var unknownGrace: TimeInterval = 600     // an unknown session still counts this long, then expires
    var maxSessions = 32                     // hard cap on the session table
}

struct AgentSession: Equatable {
    var kind: AgentKind
    var phase: AgentPhase
    var phaseSince: Date
    var lastEvent: Date       // arrival time of the newest accepted event
    var lastSentAt: Double
}

/// Tracks agent sessions from hook events only — no process scanning, no CPU heuristics.
/// Lost events are covered by leases: a silent running session first becomes "unknown"
/// (still counted), then expires; brief silence is never read as "finished".
struct AgentTracker {
    var config = AgentConfig()
    private(set) var sessions: [String: AgentSession] = [:]
    private(set) var idleSince: Date? = nil          // when the last running task finished: start of the buffer
    private(set) var wasAwake = false                // only a drop from "running" to "none" starts a buffer

    enum Liveness: Equatable { case active, unknown, inactive, expired }

    private func lease(_ p: AgentPhase) -> TimeInterval {
        p == .tool ? config.toolLease : p == .background ? config.backgroundLease : config.respondingLease
    }

    func liveness(_ s: AgentSession, now: Date) -> Liveness {
        switch s.phase {
        case .responding, .tool, .background:
            let quiet = now.timeIntervalSince(s.lastEvent), l = lease(s.phase)
            if quiet < l { return .active }
            if quiet < l + config.unknownGrace { return .unknown }
            return .expired
        case .waiting:
            return now.timeIntervalSince(s.phaseSince) < config.waitMax ? .active : .inactive
        case .started, .turnDone, .interrupted:
            return .inactive
        case .ended:
            return .expired
        }
    }

    func counts(now: Date) -> (active: Int, unknown: Int, waiting: Int) {
        var a = 0, u = 0, w = 0
        for s in sessions.values {
            switch liveness(s, now: now) {
            case .active: a += 1; if s.phase == .waiting { w += 1 }
            case .unknown: u += 1
            default: break
            }
        }
        return (a, u, w)
    }

    func keepsAwake(now: Date) -> Bool { let c = counts(now: now); return c.active + c.unknown > 0 }

    /// Per agent, for the submenu: what each one is doing right now.
    func countsByKind(now: Date) -> [AgentKind: AgentCount] {
        var out: [AgentKind: AgentCount] = [:]
        for s in sessions.values {
            var c = out[s.kind] ?? AgentCount()
            switch liveness(s, now: now) {
            case .active:
                switch s.phase {
                case .waiting: c.waiting += 1
                case .background: c.background += 1
                default: c.running += 1
                }
            case .unknown: c.unknown += 1
            case .inactive, .expired: continue
            }
            out[s.kind] = c
        }
        return out
    }

    /// Applies one event. Late (older than known) events and exact duplicates are ignored.
    mutating func apply(_ e: AgentEvent, now: Date) {
        let key = e.kind.rawValue + ":" + e.session
        if var s = sessions[key] {
            if e.sentAt < s.lastSentAt { return }                       // delayed: a newer state already arrived
            if e.sentAt == s.lastSentAt && e.phase == s.phase { return } // duplicate delivery
            if e.phase == .ended { sessions[key] = nil }
            else {
                if e.phase != s.phase { s.phase = e.phase; s.phaseSince = now }
                s.lastEvent = now; s.lastSentAt = e.sentAt
                sessions[key] = s
            }
        } else if e.phase != .ended {
            makeRoom(now: now)
            sessions[key] = AgentSession(kind: e.kind, phase: e.phase, phaseSince: now, lastEvent: now, lastSentAt: e.sentAt)
        }
        settle(now: now)
    }

    /// Drops expired sessions; called when a deadline passes.
    mutating func prune(now: Date) {
        sessions = sessions.filter { liveness($0.value, now: now) != .expired }
        settle(now: now)
    }

    private mutating func settle(now: Date) {
        if keepsAwake(now: now) { idleSince = nil; wasAwake = true }
        else if wasAwake { idleSince = now; wasAwake = false }
    }

    /// After a relaunch while keep-awake was held: give running agents one buffer to report again.
    mutating func beginGrace(now: Date) { if !keepsAwake(now: now) { idleSince = now } }

    /// Ends a pending buffer at once (the user switched keep-awake off).
    mutating func clearIdle() { idleSince = nil }

    /// Keeps the table bounded: expired first, then the stalest inactive session, then the stalest of all.
    private mutating func makeRoom(now: Date) {
        guard sessions.count >= config.maxSessions else { return }
        sessions = sessions.filter { liveness($0.value, now: now) != .expired }
        while sessions.count >= config.maxSessions {
            let inactive = sessions.filter { liveness($0.value, now: now) == .inactive }
            let pool = inactive.isEmpty ? sessions : inactive
            guard let victim = pool.min(by: { $0.value.lastEvent < $1.value.lastEvent })?.key else { break }
            sessions[victim] = nil
        }
    }

    /// Next instant a session's liveness changes (lease end, unknown end, approval timeout).
    func nextDeadline(now: Date) -> Date? {
        var best: Date? = nil
        for s in sessions.values {
            var marks: [Date] = []
            switch s.phase {
            case .responding, .tool, .background:
                let l = lease(s.phase)
                marks = [s.lastEvent.addingTimeInterval(l), s.lastEvent.addingTimeInterval(l + config.unknownGrace)]
            case .waiting:
                marks = [s.phaseSince.addingTimeInterval(config.waitMax)]
            default: break
            }
            for d in marks where d > now { if best == nil || d < best! { best = d } }
        }
        return best
    }

    mutating func reset() { sessions = [:]; idleSince = nil; wasAwake = false }
}

/// What one agent is doing, for the submenu.
struct AgentCount: Equatable {
    var running = 0, waiting = 0, background = 0, unknown = 0
    var total: Int { running + waiting + background + unknown }
}

/// One line per agent that has something going on, e.g. "Codex（ChatGPT）：1 个任务进行中".
func agentTaskLines(_ counts: [AgentKind: AgentCount]) -> [String] {
    AgentKind.allCases.compactMap { (kind) -> String? in
        guard let c = counts[kind], c.total > 0 else { return nil }
        var parts: [String] = []
        if c.running > 0 { parts.append("\(c.running) 个进行中") }
        if c.background > 0 { parts.append("\(c.background) 个后台") }
        if c.waiting > 0 { parts.append("\(c.waiting) 个待确认") }
        if c.unknown > 0 { parts.append("\(c.unknown) 个未知") }
        return kind.label + "：" + parts.joined(separator: "，")
    }
}

// MARK: - The single power decision

/// Why keep-awake is off while AI smart mode is on.
enum Hold: Equatable {
    case smartIdle      // no agent task is running and the buffer has elapsed
    case smartPaused    // the user switched it off; no automatic re-enable until this batch ends
    var text: String {
        switch self {
        case .smartIdle: return "AI 智能模式待命"
        case .smartPaused: return "AI 已暂停"
        }
    }
}

struct Decision: Equatable {
    var want: Bool?     // nil: no saved choice yet (upgrade) and smart mode off — report, never write
    var hold: Hold? = nil
    var auto = false    // true: AI smart mode is the reason keep-awake is on
}

/// The one place that decides whether keep-awake should be on. Priority, highest first:
///   1. the manual switch turned on (classic one-click mode, exactly as 1.4.1)
///   2. AI smart mode: on while any agent task runs (or waits for approval / is unknown),
///      then for the 3-minute buffer after the last one; off when the user switched it off
///      during this batch
///   3. otherwise the saved choice (off, or nil = report only)
/// Battery and thermal pressure are deliberately not inputs.
func decidePower(intent: Bool?, smart: Bool, agentsAwake: Bool, idleSince: Date?, suppressed: Bool,
                 now: Date, config: AgentConfig) -> Decision {
    if intent == true { return Decision(want: true) }
    guard smart else { return Decision(want: intent) }
    if suppressed { return Decision(want: false, hold: .smartPaused) }
    if agentsAwake { return Decision(want: true, hold: nil, auto: true) }
    if let until = smartDeadline(idleSince: idleSince, config: config), now < until {
        return Decision(want: true, hold: nil, auto: true)
    }
    return Decision(want: false, hold: .smartIdle)
}

/// End of the smart-mode buffer after the last task finished.
func smartDeadline(idleSince: Date?, config: AgentConfig) -> Date? {
    idleSince.map { $0.addingTimeInterval(config.grace) }
}

// MARK: - Keep-awake lease (ownership of `pmset disablesleep 1`)

/// Exists exactly while SleepDisabled=1 was set by this assistant and not yet released.
/// Written before `pmset -a disablesleep 1`, removed after a successful `disablesleep 0`.
/// If sleep was already disabled by someone else, the assistant never writes 1 and so
/// never holds a lease — quit, crash guard and launch recovery then leave it alone.
struct KeepAwakeLease: Codable, Equatable {
    var version = 1
    var pid: Int32
    var processStart: Int64     // owner's start time (µs): a reused PID is not mistaken for the owner
    var bootSession: String     // kern.bootsessionuuid when written
    var since: Date
}

enum LeaseVerdict: Equatable {
    case none          // nothing of ours is left
    case liveOwner     // a live process (same boot, same PID and start time) holds it — do not touch
    case stale         // the owner ended without releasing (crash, kill, power loss, reboot)
}

func judgeLease(_ lease: KeepAwakeLease?, ownerStart: (Int32) -> Int64?, currentBoot: String) -> LeaseVerdict {
    guard let l = lease else { return .none }
    if l.bootSession == currentBoot, let start = ownerStart(l.pid), start == l.processStart { return .liveOwner }
    return .stale
}

// MARK: - Hook event mapping (shared by the hook client and the tests)

/// Maps an agent's official hook event to a phase. `details` carries the few non-content
/// fields that matter: Gemini `notification_type`, Antigravity `fullyIdle` / `error`.
func phaseFor(agent: AgentKind, event: String, details: [String: Any]) -> AgentPhase? {
    switch (agent, event) {
    case (_, "SessionStart"): return .started
    case (_, "SessionEnd"): return .ended
    // Codex CLI / Codex app (same ~/.codex/hooks.json) and Grok Build
    case (.codex, "UserPromptSubmit"), (.grok, "UserPromptSubmit"): return .responding
    case (.codex, "PreToolUse"), (.grok, "PreToolUse"): return .tool
    case (.codex, "PostToolUse"), (.grok, "PostToolUse"), (.grok, "PostToolUseFailure"), (.grok, "PermissionDenied"): return .responding
    case (.codex, "PermissionRequest"): return .waiting
    case (.codex, "Stop"), (.grok, "Stop"): return .turnDone
    case (.codex, "Interrupt"), (.grok, "StopFailure"): return .interrupted
    // Kiro (CLI 3 and IDE share the standalone ~/.kiro/hooks/*.json files)
    case (.kiro, "UserPromptSubmit"), (.kiro, "PostToolUse"): return .responding
    case (.kiro, "Stop"): return .turnDone
    // Gemini CLI
    case (.gemini, "BeforeAgent"), (.gemini, "AfterTool"): return .responding
    case (.gemini, "BeforeTool"): return .tool
    case (.gemini, "Notification"): return (details["notification_type"] as? String) == "ToolPermission" ? .waiting : nil
    case (.gemini, "AfterAgent"): return .turnDone
    // Antigravity (App, CLI and IDE share ~/.gemini/config/hooks.json)
    case (.antigravity, "PreInvocation"), (.antigravity, "PostToolUse"): return .responding
    case (.antigravity, "Stop"):
        if let err = details["error"] as? String, !err.isEmpty { return .interrupted }
        return (details["fullyIdle"] as? Bool) == false ? .background : .turnDone
    default: return nil
    }
}

/// FNV-1a 64-bit: the hook client stores only this hash of a session id, never the id itself.
func hashSession(_ s: String) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
    return String(format: "%016llx", h)
}

/// Fixed choices for the optional timed stop (hours); 0 = off.
let autoStopChoices = [0, 1, 2, 4, 8]
