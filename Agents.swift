import Foundation
import Darwin
import IOKit
import IOKit.ps
import SQLite3
import AppKit

// Clamshell Assistant V2.1 — system reads and event sources used by the app (not by the helper).
//
// Nothing here polls: the battery, lid and idle reads happen once, at the moment they are
// needed (the submenu opens / AI smart mode just released keep-awake); agent events arrive on
// a listening Unix domain socket (GCD read source); hook files are edited only when AI smart
// mode is switched on or the app launches with it on.

// MARK: - Battery (IOKit power sources), read only when the submenu opens

/// Reads the internal battery. Returns nil when IOKit gives no snapshot at all (a read failure).
func readBattery() -> BatteryReading? {
    guard let snapshotRef = IOPSCopyPowerSourcesInfo() else { return nil }
    let snapshot = snapshotRef.takeRetainedValue()
    guard let listRef = IOPSCopyPowerSourcesList(snapshot) else { return nil }
    let list = listRef.takeRetainedValue() as Array
    for ps in list {
        guard let descRef = IOPSGetPowerSourceDescription(snapshot, ps as CFTypeRef),
              let d = descRef.takeUnretainedValue() as? [String: Any] else { continue }
        guard (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
        var percent: Int? = nil
        if let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
            percent = min(100, Swift.max(0, Int((Double(cur) * 100 / Double(max)).rounded())))
        }
        let state = d[kIOPSPowerSourceStateKey] as? String
        let onAC: Bool? = state == kIOPSACPowerValue ? true : (state == kIOPSBatteryPowerValue ? false : nil)
        return BatteryReading(present: true, percent: percent, onAC: onAC)
    }
    return BatteryReading(present: false, percent: nil, onAC: nil)
}

// MARK: - Lid and user idle time (read once, when AI smart mode releases keep-awake)

/// AppleClamshellState of IOPMrootDomain: true = the lid is closed. nil when unavailable.
func lidIsClosed() -> Bool? {
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard root != 0 else { return nil }
    defer { IOObjectRelease(root) }
    guard let ref = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0) else { return nil }
    return ref.takeRetainedValue() as? Bool
}

/// Seconds since the last keyboard/mouse/trackpad input (HIDIdleTime). nil when unavailable.
func userIdleSeconds() -> Double? {
    let hid = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    guard hid != 0 else { return nil }
    defer { IOObjectRelease(hid) }
    guard let ref = IORegistryEntryCreateCFProperty(hid, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0) else { return nil }
    guard let n = ref.takeRetainedValue() as? NSNumber else { return nil }
    return n.doubleValue / 1_000_000_000
}

// MARK: - Agent event socket

/// Validates one line from the hook client. Accepts only the minimal schema; anything
/// else (oversized, unknown agent/phase, malformed id) is dropped.
func parseAgentMessage(_ data: Data, now: Date) -> AgentEvent? {
    guard data.count <= 512,
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          (obj["v"] as? Int) == 1,
          let a = obj["a"] as? String, let kind = AgentKind(rawValue: a),
          let s = obj["s"] as? String, s.count == 16, s.allSatisfy({ $0.isHexDigit }),
          let p = obj["p"] as? String, let phase = AgentPhase(rawValue: p) else { return nil }
    var t = (obj["t"] as? Double) ?? now.timeIntervalSince1970 * 1000
    // A clock far off (or a forged far-future stamp) must not pin a session: clamp to ±1 day.
    if abs(t - now.timeIntervalSince1970 * 1000) > 86_400_000 { t = now.timeIntervalSince1970 * 1000 }
    return AgentEvent(kind: kind, session: s, phase: phase, sentAt: t)
}

/// Listens on a 0600 Unix domain socket inside the 0700 support directory.
/// Each connection must come from the same user (getpeereid) AND from the bundled
/// `clamshell-helper` executable (LOCAL_PEERPID + proc_pidpath), checked while the
/// client is still waiting for its acknowledgement byte. A same-user process can still
/// run the helper with made-up input; the impact is bounded by design — events can only
/// keep the Mac awake within the session caps and can never override the user's explicit off.
final class AgentListener {
    private let path: String
    private let helperPath: String
    private let queue = DispatchQueue(label: "local.reminal.clamshellassistant.agents", qos: .utility)
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let deliver: (AgentEvent) -> Void
    private(set) var rejected = 0

    init(path: String, helperPath: String, deliver: @escaping (AgentEvent) -> Void) {
        self.path = path; self.helperPath = (helperPath as NSString).resolvingSymlinksInPath; self.deliver = deliver
    }

    @discardableResult
    func start() -> Bool {
        guard fd < 0, AppPaths.ensureSupportDir() else { return fd >= 0 }
        unlink(path)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(s); return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let old = umask(0o077)
        let bound: Int32 = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, len) } }
        umask(old)
        guard bound == 0, chmod(path, 0o600) == 0, listen(s, 16) == 0 else { close(s); unlink(path); return false }
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        fd = s
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptAll() }
        src.setCancelHandler { close(s) }
        source = src
        src.resume()
        return true
    }

    func stop() {
        source?.cancel(); source = nil; fd = -1
        unlink(path)
    }

    private func acceptAll() {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { return }
            handle(c)
        }
    }

    private func handle(_ c: Int32) {
        defer { close(c) }
        _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) & ~O_NONBLOCK)
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        _ = setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        _ = setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        guard peerIsOurHelper(c) else { rejected += 1; return }
        var buf = [UInt8](repeating: 0, count: 513)
        var total = 0
        while total < 513 {
            let n = buf.withUnsafeMutableBytes { read(c, $0.baseAddress! + total, 513 - total) }
            if n <= 0 { break }
            total += n
            if buf[..<total].contains(10) { break }
        }
        guard total > 0, total <= 512 else { rejected += 1; return }
        var line = Data(buf[..<total])
        if let nl = line.firstIndex(of: 10) { line = line.prefix(upTo: nl) }
        guard let event = parseAgentMessage(line, now: Date()) else { rejected += 1; return }
        var ack: UInt8 = 107 // "k"
        _ = write(c, &ack, 1)
        DispatchQueue.main.async { [deliver] in deliver(event) }
    }

    private func peerIsOurHelper(_ c: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(c, &uid, &gid) == 0, uid == getuid() else { return false }
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        let solLocal: Int32 = 0, localPeerPID: Int32 = 0x002   // <sys/un.h>: SOL_LOCAL, LOCAL_PEERPID
        guard getsockopt(c, solLocal, localPeerPID, &pid, &size) == 0, pid > 0 else { return false }
        var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 else { return false }
        let peer = (String(cString: pathBuf) as NSString).resolvingSymlinksInPath
        return peer == helperPath
    }
}

// MARK: - Invisible, reversible hook installation (done automatically while AI smart mode is on)

/// One agent's official hook configuration file and the events we register.
/// Install only ADDS handlers whose command runs our helper; uninstall removes only those.
/// Every write is preceded by a timestamped backup, keeps the file's permissions, and is
/// refused when the existing file is not plain JSON (e.g. JSON with comments).
struct HookTarget {
    let kind: AgentKind
    let file: String            // absolute path
    let marker = "clamshell-helper"

    static func all(home: String = NSHomeDirectory()) -> [HookTarget] {
        [HookTarget(kind: .codex, file: home + "/.codex/hooks.json"),
         HookTarget(kind: .gemini, file: home + "/.gemini/settings.json"),
         HookTarget(kind: .antigravity, file: home + "/.gemini/config/hooks.json"),
         HookTarget(kind: .grok, file: home + "/.grok/hooks/clamshell-assistant.json"),
         HookTarget(kind: .kiro, file: home + "/.kiro/hooks/clamshell-assistant.json")]
    }

    /// The agent's own directories: at least one must already exist — we never configure an
    /// agent that is not installed. (Antigravity shares ~/.gemini with Gemini CLI, so it is
    /// recognised by its own subdirectory, not by ~/.gemini alone.)
    var presenceDirs: [String] {
        func up(_ n: Int) -> String { var s = file; for _ in 0..<n { s = (s as NSString).deletingLastPathComponent }; return s }
        switch kind {
        case .codex, .gemini: return [up(1)]
        case .antigravity: return [up(2) + "/antigravity", up(1)]
        case .grok, .kiro, .quick, .other: return [up(2)]
        }
    }
    var agentPresent: Bool { presenceDirs.contains { FileManager.default.fileExists(atPath: $0) } }

    var events: [String] {
        switch kind {
        case .codex: return ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "Interrupt", "SessionEnd"]
        case .gemini: return ["SessionStart", "BeforeAgent", "BeforeTool", "AfterTool", "Notification", "AfterAgent", "SessionEnd"]
        case .antigravity: return ["SessionStart", "PreInvocation", "PostToolUse", "Stop"]
        case .grok: return ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "Stop", "StopFailure", "SessionEnd"]
        // Kiro: only passive events. PreToolUse / PermissionRequest gate the agent, so they are never registered.
        case .kiro: return ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "SessionEnd"]
        case .quick, .other: return []
        }
    }

    func command(helper: String, event: String) -> String {
        "'" + helper.replacingOccurrences(of: "'", with: "'\\''") + "' hook " + kind.rawValue + " " + event
    }

    /// Our handler object. Timeouts are short; the helper itself gives up after ~1 s.
    func handler(helper: String, event: String) -> [String: Any] {
        let cmd = command(helper: helper, event: event)
        switch kind {
        case .codex: return ["type": "command", "command": cmd, "timeout": (event == "SessionEnd" || event == "Interrupt") ? 2 : 5]
        case .gemini: return ["type": "command", "name": "clamshell-assistant", "command": cmd, "timeout": 3000]   // milliseconds
        case .antigravity: return ["type": "command", "command": cmd, "timeout": 5]
        case .grok, .kiro, .quick, .other: return ["type": "command", "command": cmd, "timeout": 5]
        }
    }

    func isOurs(_ h: Any) -> Bool { ((h as? [String: Any])?["command"] as? String)?.contains(marker) == true }

    /// Installed AND every one of our handlers runs this copy of the helper (the app may have moved).
    func isCurrent(helper: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: file),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        let wanted = Set(events.map { command(helper: helper, event: $0) })
        var found = Set<String>()
        func scan(_ v: Any) {
            if let d = v as? [String: Any] {
                if let c = d["command"] as? String, wanted.contains(c) { found.insert(c) }
                for x in d.values { scan(x) }
            } else if let a = v as? [Any] {
                for x in a { scan(x) }
            }
        }
        scan(root)
        return !wanted.isEmpty && found == wanted
    }

    enum Status: Equatable { case agentMissing, notInstalled, installed, unreadable }

    func status() -> Status {
        let fm = FileManager.default
        guard agentPresent else { return .agentMissing }
        guard let data = fm.contents(atPath: file) else { return .notInstalled }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unreadable }
        return containsOurs(root) ? .installed : .notInstalled
    }

    func containsOurs(_ root: [String: Any]) -> Bool {
        func scan(_ v: Any) -> Bool {
            if isOurs(v) { return true }
            if let d = v as? [String: Any] { return d.values.contains(where: scan) }
            if let a = v as? [Any] { return a.contains(where: scan) }
            return false
        }
        return scan(root)
    }

    /// Pure transformation used by install and by the tests.
    func adding(to root: [String: Any], helper: String) -> [String: Any] {
        var root = removing(from: root)
        switch kind {
        case .antigravity:
            // hooks.json maps hook *names* to events; ours lives under its own name.
            var mine: [String: Any] = [:]
            for e in events {
                let h: [String: Any] = handler(helper: helper, event: e)
                if e == "PostToolUse" {
                    let group: [String: Any] = ["matcher": "", "hooks": [h]]
                    mine[e] = [group]
                } else { mine[e] = [h] }
            }
            root["clamshell-assistant"] = mine
        case .kiro:
            // Standalone Kiro hook document (our own file): {"version":"v1","hooks":[{name, trigger, action}]}
            root["version"] = "v1"
            var list = root["hooks"] as? [Any] ?? []
            for e in events {
                let action: [String: Any] = ["type": "command", "command": command(helper: helper, event: e)]
                let h: [String: Any] = ["name": "clamshell-assistant-" + e, "trigger": e, "action": action, "timeout": 5, "enabled": true]
                list.append(h)
            }
            root["hooks"] = list
        default:
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            for e in events {
                var groups = hooks[e] as? [Any] ?? []
                let group: [String: Any] = ["hooks": [handler(helper: helper, event: e)]]
                groups.append(group)
                hooks[e] = groups
            }
            root["hooks"] = hooks
        }
        return root
    }

    /// Removes our handlers only; drops groups/events/keys that become empty because of it.
    func removing(from root: [String: Any]) -> [String: Any] {
        var root = root
        if kind == .antigravity {
            if let mine = root["clamshell-assistant"], containsOurs(["x": mine]) { root["clamshell-assistant"] = nil }
            return root
        }
        if kind == .kiro {
            let list = (root["hooks"] as? [Any] ?? []).filter { !containsOurs(["x": $0]) }
            if list.isEmpty { return [:] }                                  // nothing but ours: the file goes away
            root["hooks"] = list
            return root
        }
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            var kept: [Any] = []
            for g in groups {
                guard var group = g as? [String: Any], let handlers = group["hooks"] as? [Any] else { kept.append(g); continue }
                let others = handlers.filter { !isOurs($0) }
                if others.count == handlers.count { kept.append(g); continue }
                if others.isEmpty { continue }
                group["hooks"] = others; kept.append(group)
            }
            if kept.isEmpty { hooks[event] = nil } else { hooks[event] = kept }
        }
        if hooks.isEmpty { root["hooks"] = nil } else { root["hooks"] = hooks }
        return root
    }

    enum Failure: Error, Equatable { case agentMissing, helperMissing, unreadable, writeFailed }

    func install(helper: String) -> Result<Void, Failure> { edit(helper: helper, add: true) }
    func uninstall() -> Result<Void, Failure> { edit(helper: "", add: false) }

    private func edit(helper: String, add: Bool) -> Result<Void, Failure> {
        let fm = FileManager.default
        guard agentPresent else { return .failure(.agentMissing) }
        if add && !fm.isExecutableFile(atPath: helper) { return .failure(.helperMissing) }
        var root: [String: Any] = [:]
        var mode: Int = 0o600
        let existed = fm.fileExists(atPath: file)
        if existed {
            guard let data = fm.contents(atPath: file) else { return .failure(.unreadable) }
            if !data.isEmpty {
                guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .failure(.unreadable) }
                root = parsed
            }
            if let p = (try? fm.attributesOfItem(atPath: file))?[.posixPermissions] as? Int { mode = p }
        } else if !add { return .success(()) }
        let updated = add ? adding(to: root, helper: helper) : removing(from: root)
        if existed && kind != .grok && kind != .kiro {   // the Grok and Kiro files are our own; everything else is backed up first
            let base = file + ".clamshell-backup-" + String(Int(Date().timeIntervalSince1970 * 1000))
            var backup = base, n = 1
            while fm.fileExists(atPath: backup) { backup = base + "-\(n)"; n += 1 }
            guard (try? fm.copyItem(atPath: file, toPath: backup)) != nil else { return .failure(.writeFailed) }
        }
        // Our own Grok file holds nothing but our hooks: remove it instead of leaving an empty shell.
        if !add && (kind == .grok || kind == .kiro) && updated.isEmpty { try? fm.removeItem(atPath: file); return .success(()) }
        guard let out = try? JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted]) else { return .failure(.writeFailed) }
        let dir = (file as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dir) { try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let tmp = file + ".clamshell-tmp"
        guard fm.createFile(atPath: tmp, contents: out, attributes: [.posixPermissions: mode]), rename(tmp, file) == 0 else {
            try? fm.removeItem(atPath: tmp); return .failure(.writeFailed)
        }
        return .success(())
    }
}

// MARK: - Codex system-level hooks

/// Codex also loads hooks from /etc/codex/hooks.json and treats that source as managed:
/// trusted by policy, so the user never has to review them one by one in「设置 › Hooks」.
/// Writing /etc needs root, so the app only computes the file (pure, testable); the installer
/// writes it after one administrator prompt, and rollback removes only our entries.
enum CodexSystemHooks {
    static let path = "/etc/codex/hooks.json"
    enum Plan: Equatable { case upToDate, write(Data), remove, unreadable }

    static func isActive(helper: String, path: String = CodexSystemHooks.path) -> Bool {
        HookTarget(kind: .codex, file: path).isCurrent(helper: helper)
    }

    /// install: our hooks merged into whatever is there (an administrator's own hooks are kept).
    /// uninstall: only our entries removed; `.remove` when nothing else is left.
    static func plan(install: Bool, helper: String, path: String = CodexSystemHooks.path) -> Plan {
        let target = HookTarget(kind: .codex, file: path)
        var root: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: path), !data.isEmpty {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .unreadable }
            root = parsed
        }
        let updated: [String: Any]
        if install {
            if target.isCurrent(helper: helper) { return .upToDate }
            updated = target.adding(to: root, helper: helper)
        } else {
            guard target.containsOurs(root) else { return .upToDate }
            updated = target.removing(from: root)
            if updated.isEmpty { return .remove }
        }
        // Sorted keys: the same input always gives the same bytes, so the installer can tell "no change".
        guard let out = try? JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys]) else { return .unreadable }
        return .write(out)
    }
}

// MARK: - Agents without hooks: Codex's own state and AWS Quick's desktop log
//
// Both are event-driven: kqueue vnode sources fire only when one of a few files changes; the
// handler then reads just what it needs. No timer, no polling, no process scanning, and no
// prompt, reply or file content is ever kept.

/// AWS Quick runs in the cloud and needs this Mac only while it works on it (local files, local
/// code, local coding agents). Its desktop log marks those moments; only these tags are read.
func quickLogPhase(_ line: Substring) -> AgentPhase? {
    if line.contains("[ChatTurn] time_to_complete") { return .turnDone }
    if line.contains("[rlog:outpost_tool_call_started]") || line.contains("[rlog:outpost_tool_call_finished]")
        || line.contains("[OutpostACP]") || line.contains("[ChatTurn] time_to_first") || line.contains("[TTFT]") { return .responding }
    return nil
}

/// The newest relevant phase in a chunk of appended log text; nil when nothing in it matters.
func quickLogLastPhase(_ text: String) -> AgentPhase? {
    var last: AgentPhase? = nil
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        if let p = quickLogPhase(line) { last = p }
    }
    return last
}

/// Codex keeps the turns running right now in its own database (Codex app and ChatGPT's Codex,
/// Work included). Read-only. nil when it cannot be read completely (busy, locked, missing).
func codexActiveTurns(dbPath: String) -> Set<String>? {
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 200)
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "select thread_id from active_chat_turns", -1, &stmt, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }
    var ids = Set<String>()
    var rc = sqlite3_step(stmt)
    while rc == SQLITE_ROW {
        if let c = sqlite3_column_text(stmt, 0) { ids.insert(String(cString: c)) }
        rc = sqlite3_step(stmt)
    }
    return rc == SQLITE_DONE ? ids : nil
}

/// Codex Keyboard (when installed) keeps a small status file for its key lights, covering Codex on
/// this Mac and Codex Work running remotely. Only "working" entries are read. nil when the file is
/// stale or unreadable: then nothing is concluded from it (its sessions simply age out by lease).
func codexKeyboardWorking(_ data: Data, now: Date, maxAge: TimeInterval = 600) -> Set<String>? {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    let observed = (root["observedAt"] as? Double) ?? (root["lastPollAt"] as? Double) ?? 0
    guard now.timeIntervalSince1970 - observed < maxAge else { return nil }
    var ids = Set<String>()
    for s in (root["slots"] as? [[String: Any]]) ?? [] where (s["status"] as? String) == "working" {
        if let id = s["id"] as? String, !id.isEmpty { ids.insert(id) }
    }
    for (id, v) in (root["remoteStatuses"] as? [String: Any]) ?? [:] where (v as? String) == "working" { ids.insert(id) }
    return ids
}

/// Turns a change in Codex's running set into tracker events: still running → refreshed as a
/// long tool phase, gone → turn done. Ids are hashed like every other session id.
func codexStateEvents(before: Set<String>, after: Set<String>, sentAt: Double) -> [AgentEvent] {
    after.sorted().map { AgentEvent(kind: .codex, session: hashSession($0), phase: .tool, sentAt: sentAt) }
        + before.subtracting(after).sorted().map { AgentEvent(kind: .codex, session: hashSession($0), phase: .turnDone, sentAt: sentAt) }
}

/// Calls back on the main queue when any of a few files or directories changes. A file that is
/// replaced, or appears later in a watched directory, is picked up on the next directory change.
final class FileChangeWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []
    private let paths: [String]
    private let onChange: () -> Void
    private var pending = false

    init(paths: [String], onChange: @escaping () -> Void) { self.paths = paths; self.onChange = onChange }

    func start() { rearm() }
    func stop() { sources.forEach { $0.cancel() }; sources = [] }

    private func rearm() {
        stop()
        for p in paths {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir) else { continue }
            let fd = open(p, O_EVTONLY)
            guard fd >= 0 else { continue }
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
            let dir = isDir.boolValue
            s.setEventHandler { [weak self] in           // the source is released by GCD once cancelled
                guard let self = self else { return }
                let ev = s.data
                self.fire(rearm: dir || ev.contains(.delete) || ev.contains(.rename))
            }
            s.setCancelHandler { close(fd) }
            s.resume()
            sources.append(s)
        }
    }

    /// One callback per burst: a database commit or a log flush touches files several times.
    private func fire(rearm: Bool) {
        if rearm { self.rearm() }
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.pending = false
            self.onChange()
        }
    }
}

/// Reads only what AWS Quick's desktop log appended since the last change (one file per UTC hour).
final class QuickLogMonitor {
    let dir: String
    private(set) var file: String?
    private var offset: UInt64 = 0
    private var watcher: FileChangeWatcher?
    private let onPhase: (AgentPhase) -> Void

    init(dir: String = NSHomeDirectory() + "/Library/Logs/quickwork", onPhase: @escaping (AgentPhase) -> Void) {
        self.dir = dir; self.onPhase = onPhase
    }

    /// File names carry the date and hour, so the largest name is the newest file.
    static func newestLog(in dir: String) -> String? {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("quickwork-") && $0.hasSuffix(".log") }
        return names.max().map { dir + "/" + $0 }
    }

    func start() {
        guard FileManager.default.fileExists(atPath: dir) else { return }
        attach(fromStart: false)                 // history before launch is never replayed
    }
    func stop() { watcher?.stop(); watcher = nil }

    private func size(_ p: String) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func attach(fromStart: Bool) {
        file = Self.newestLog(in: dir)
        offset = fromStart ? 0 : (file.map { size($0) } ?? 0)
        watcher?.stop()
        let w = FileChangeWatcher(paths: [dir] + (file.map { [$0] } ?? [])) { [weak self] in self?.changed() }
        w.start(); watcher = w
    }

    func changed() {
        if Self.newestLog(in: dir) != file { attach(fromStart: true) }      // a new hour began: read it from its start
        guard let f = file, let h = FileHandle(forReadingAtPath: f) else { return }
        defer { try? h.close() }
        let end = h.seekToEndOfFile()
        if end < offset { offset = 0 }
        let start = max(offset, end > 512 * 1024 ? end - 512 * 1024 : 0)
        h.seek(toFileOffset: start)
        let data = h.readData(ofLength: Int(end - start))
        offset = end
        if let p = quickLogLastPhase(String(decoding: data, as: UTF8.self)) { onPhase(p) }
    }
}

/// Watches Codex's state database and Codex Keyboard's status file; reads them only on a change.
final class CodexStateMonitor {
    let home: String
    private var watcher: FileChangeWatcher?
    private let onSnapshot: (_ local: Set<String>?, _ keyboard: Set<String>?) -> Void
    var dbPath: String { home + "/.codex/sqlite/codex.db" }
    var keyboardPath: String { home + "/Library/Application Support/CodexKeyboardMG75PRO/lighting-status.json" }

    init(home: String = NSHomeDirectory(), onSnapshot: @escaping (_ local: Set<String>?, _ keyboard: Set<String>?) -> Void) {
        self.home = home; self.onSnapshot = onSnapshot
    }

    func start() {
        // Only Codex's own database decides. Codex Keyboard's light status was dropped in 2.1.7: its
        // "remote" entries can stay "working" long after a task ended, which kept the Mac awake.
        let paths = [home + "/.codex/sqlite", dbPath, dbPath + "-wal"]
        guard paths.contains(where: { FileManager.default.fileExists(atPath: $0) }) else { return }
        let w = FileChangeWatcher(paths: paths) { [weak self] in self?.read() }
        w.start(); watcher = w
        read()
    }
    func stop() { watcher?.stop(); watcher = nil }

    /// Rows left behind by a Codex app that is no longer running never count.
    static func codexAppRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            let p = app.bundleURL?.path ?? ""
            return p.hasSuffix("/ChatGPT.app") || p.hasSuffix("/Codex.app")
        }
    }

    func read() {
        var local: Set<String>? = nil
        if FileManager.default.fileExists(atPath: dbPath) {
            local = Self.codexAppRunning() ? codexActiveTurns(dbPath: dbPath) : []
        }
        onSnapshot(local, nil)
    }
}
