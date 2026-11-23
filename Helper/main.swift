import Foundation
import Darwin

// clamshell-helper — the only extra executable in Clamshell Assistant V2 (2.1).
//
//   clamshell-helper hook <agent> <event>
//       Run by an agent's official hook system (Codex, Gemini CLI, Antigravity, Grok Build);
//       the assistant registers it by itself while AI smart mode is on.
//       Reads the hook JSON from stdin, keeps ONLY a hash of the session id plus the event
//       phase, sends one line to the assistant's Unix socket and prints the minimal stdout
//       each agent expects. Always exits 0 within about a second: it can never block,
//       slow down or change the agent's behaviour, and it does nothing if the assistant is
//       not running.
//
//   clamshell-helper guard <owner-pid>
//       Started by the assistant only while it holds the keep-awake lease. It sleeps in a
//       blocking read on a pipe from the assistant (no timer, no CPU). A clean release writes
//       "release" first; end-of-file without it means the assistant crashed or was killed,
//       and the guard then turns `disablesleep` back off — but only if the lease still names
//       that same owner and SleepDisabled is still 1 — using the existing minimal sudoers rule
//       (`sudo -n`, never a prompt). Without that rule, recovery falls back to the next launch.

let args = CommandLine.arguments

func emit(_ s: String) { FileHandle.standardOutput.write(Data(s.utf8)) }

/// What each agent expects on stdout (see the official hook references).
func reply(agent: AgentKind, event: String) -> String {
    switch agent {
    case .codex: return ["Stop", "SubagentStop", "Interrupt"].contains(event) ? "{}" : ""   // plain text would become model context
    case .gemini: return "{}"                                                              // stdout must be JSON
    case .antigravity: return event == "Stop" ? "{\"decision\":\"stop\"}" : "{}"            // Stop requires a decision; anything but "continue" allows stopping
    case .grok, .kiro, .quick, .other: return ""   // Kiro: SessionStart/UserPromptSubmit stdout becomes model context, so stay silent;                                                          // passive events ignore stdout; empty PreToolUse + exit 0 = allow
    }
}

func runHook(agent: AgentKind, event: String) {
    // Drain stdin (bounded) so the agent never sees a broken pipe.
    var input = Data()
    let limit = 8 * 1024 * 1024
    while true {
        let chunk = FileHandle.standardInput.availableData
        if chunk.isEmpty { break }
        if input.count < limit { input.append(chunk.prefix(limit - input.count)) }
    }
    defer { emit(reply(agent: agent, event: event)) }
    let obj = ((try? JSONSerialization.jsonObject(with: input)) as? [String: Any]) ?? [:]
    let env = ProcessInfo.processInfo.environment
    let rawSession = (obj["session_id"] as? String) ?? (obj["sessionId"] as? String) ?? (obj["conversationId"] as? String)
        ?? env["GEMINI_SESSION_ID"] ?? env["GROK_SESSION_ID"] ?? "ppid-\(getppid())"
    var details: [String: Any] = [:]
    if let v = obj["notification_type"] as? String { details["notification_type"] = v }
    if let v = obj["fullyIdle"] as? Bool { details["fullyIdle"] = v }
    if let v = obj["error"] as? String { details["error"] = v.isEmpty ? "" : "x" }   // only "was there an error"
    guard let phase = phaseFor(agent: agent, event: event, details: details) else { return }
    let msg: [String: Any] = ["v": 1, "a": agent.rawValue, "s": hashSession(rawSession), "p": phase.rawValue,
                              "t": (Date().timeIntervalSince1970 * 1000).rounded()]
    guard var line = try? JSONSerialization.data(withJSONObject: msg) else { return }
    line.append(10)
    deliver(line)
}

/// Connects with a short timeout, writes one line, waits briefly for the 1-byte ack.
func deliver(_ line: Data) {
    let path = AppPaths.socket
    let s = socket(AF_UNIX, SOCK_STREAM, 0)
    guard s >= 0 else { return }
    defer { close(s) }
    var on: Int32 = 1
    _ = setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var tv = timeval(tv_sec: 0, tv_usec: 500_000)
    _ = setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, b) in bytes.enumerated() { raw[i] = b }
        raw[bytes.count] = 0
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let rc: Int32 = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, len) } }
    guard rc == 0 else { return }       // assistant not running: nothing to do
    _ = line.withUnsafeBytes { write(s, $0.baseAddress!, line.count) }
    var ack: UInt8 = 0
    _ = read(s, &ack, 1)
}

func runGuard(owner: Int32) {
    _ = setsid()                         // survive the owner's process group being signalled
    signal(SIGHUP, SIG_IGN); signal(SIGINT, SIG_IGN); signal(SIGPIPE, SIG_IGN)
    var received = Data()
    while true {
        let chunk = FileHandle.standardInput.availableData   // blocks; zero CPU while the assistant lives
        if chunk.isEmpty { break }
        if received.count < 64 { received.append(chunk) }
    }
    if String(decoding: received, as: UTF8.self).contains("release") { exit(0) }
    // The owner went away without releasing. Act only on a lease that is provably its own.
    usleep(300_000)
    let store = LeaseStore()
    guard let lease = store.read(), lease.pid == owner, lease.bootSession == bootSessionUUID() else { exit(0) }
    let live = runCommand("/usr/bin/pmset", ["-g", "live"], timeout: 10)
    guard live.0 == 0, parseSleepDisabled(live.1) == true else { store.remove(); exit(0) }
    let off = runCommand("/usr/bin/sudo", pmsetOff, timeout: 10)
    if off.0 == 0 {
        store.remove()
        EventLog.write("guard: owner \(owner) ended without releasing; SleepDisabled restored to 0")
    } else {
        EventLog.write("guard: owner \(owner) ended without releasing; sudo -n failed, recovery deferred to next launch")
    }
    exit(0)
}

if args.count >= 4, args[1] == "hook" {
    runHook(agent: AgentKind(rawValue: args[2]) ?? .other, event: args[3])
    exit(0)
} else if args.count >= 3, args[1] == "guard", let pid = Int32(args[2]) {
    runGuard(owner: pid)
} else if args.count >= 2, args[1] == "version" {
    print("clamshell-helper 2.1.0")
    exit(0)
}
// Unknown usage: stay silent and successful so a mis-typed hook never breaks an agent.
exit(0)
