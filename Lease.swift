import Foundation
import Darwin

// Clamshell Assistant V2 — small system adapters shared by the app and `clamshell-helper`.
// Foundation + Darwin only, no third-party code. Nothing here runs on a timer.

/// Per-user locations. The directory is created 0700, so other users cannot reach the
/// agent socket or read/replace the lease.
enum AppPaths {
    /// Set by the self-tests so they never write into the user's real support directory.
    static var overrideDir: String? = nil
    static var supportDir: String {
        overrideDir ?? (NSHomeDirectory() + "/Library/Application Support/ClamshellAssistant")
    }
    static var lease: String { supportDir + "/keepawake-lease.json" }
    static var log: String { supportDir + "/events.log" }
    /// sun_path holds 104 bytes; fall back to the per-user, 0700 $TMPDIR when the home path is too long.
    static var socket: String {
        let preferred = supportDir + "/agent.sock"
        if preferred.utf8.count < 100 { return preferred }
        return NSTemporaryDirectory() + "clamshell-agent.sock"
    }
    @discardableResult
    static func ensureSupportDir() -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: supportDir) {
            do { try fm.createDirectory(atPath: supportDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { return false }
        }
        _ = chmod(supportDir, 0o700)
        return true
    }
}

/// Start time of a process in microseconds since 1970, or nil when it does not exist.
/// Used with the PID so a recycled PID is never mistaken for the original owner.
func processStartTime(_ pid: Int32) -> Int64? {
    guard pid > 0 else { return nil }
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let tv = info.kp_proc.p_un.__p_starttime
    return Int64(tv.tv_sec) * 1_000_000 + Int64(tv.tv_usec)
}

/// Changes on every boot, so a lease from before a reboot or power loss is recognised as stale.
func bootSessionUUID() -> String {
    var size = 0
    guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0) == 0 else { return "unknown" }
    return String(cString: buf)
}

/// The lease file. All writes are atomic (temp + rename) and 0600.
struct LeaseStore {
    var path = AppPaths.lease
    func read() -> KeepAwakeLease? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(KeepAwakeLease.self, from: data)
    }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
    @discardableResult
    func write(_ lease: KeepAwakeLease) -> Bool {
        guard let data = try? JSONEncoder().encode(lease) else { return false }
        let dir = (path as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let tmp = path + ".tmp"
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
        return rename(tmp, path) == 0
    }
    func remove() { try? FileManager.default.removeItem(atPath: path) }
    /// A lease for the current process.
    static func forSelf() -> KeepAwakeLease {
        let pid = getpid()
        return KeepAwakeLease(pid: pid, processStart: processStartTime(pid) ?? 0, bootSession: bootSessionUUID(), since: Date())
    }
}

/// Append-only event log with a hard size cap (64 KB, one rotation). It records only what
/// the assistant itself did (safety pause, recovery, hook install) — never agent content.
enum EventLog {
    static var limit = 64 * 1024
    static func write(_ line: String, path: String = AppPaths.log) {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > limit {
            try? fm.removeItem(atPath: path + ".1")
            try? fm.moveItem(atPath: path, toPath: path + ".1")
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data((stamp + " " + line.replacingOccurrences(of: "\n", with: " ") + "\n").utf8)
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(data); h.closeFile()
        } else {
            _ = fm.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }
}

/// The two pmset commands covered by the existing minimal sudoers rule. Nothing else is
/// ever run as root by the app or the helper.
let pmsetOff = ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"]
let pmsetOn = ["-n", "/usr/bin/pmset", "-a", "disablesleep", "1"]

/// SleepDisabled from `pmset -g live` output, or nil when the field is missing.
func parseSleepDisabled(_ text: String) -> Bool? {
    guard let r = text.range(of: "(?m)^\\s*SleepDisabled\\s+([01])\\s*$", options: .regularExpression) else { return nil }
    return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("1")
}
