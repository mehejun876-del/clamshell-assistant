import Foundation
import Darwin
import IOKit

// Reminal closed-lid settings plus the system sleep switch. Whether the bundled
// closed-lid service runs is known locally and combined by the controller.
struct ModeState: Equatable {
    let closed: Bool, unlocked: Bool, power: Bool
    var allOn: Bool { closed && unlocked && power }
    var configured: Bool { closed || unlocked || power }
}
// One interpretation of a successfully read settings + power snapshot. A partial
// configuration is NOT an enabled mode; it offers both repair and an explicit off.
struct ModePresentation {
    enum Phase { case off, partial, ready }
    let state: ModeState
    let serviceUp: Bool
    var phase: Phase { state.allOn && serviceUp ? .ready : (state.configured ? .partial : .off) }
    var isReady: Bool { phase == .ready }
    var look: Look { Look(lidClosed: state.closed, lit: isReady) }
    var primaryEnables: Bool { !isReady }
    var primaryTitle: String { phase == .ready ? "关闭合盖运行" : (phase == .partial ? "完成开启／修复合盖运行" : "开启合盖运行") }
    var offersDisable: Bool { phase == .partial }
    var missing: [String] {
        var result: [String] = []
        if !state.power { result.append("系统禁睡眠") }
        if !state.closed { result.append("closed-lid") }
        if !state.unlocked { result.append("保持解锁") }
        if !serviceUp { result.append("合盖服务") }
        return result
    }
    var header: String { phase == .ready ? "合盖运行已就绪" : (phase == .partial ? "合盖运行仅部分开启（未就绪）" : "正常模式（合盖会睡眠）") }
    var detail: String { phase == .ready ? "合盖后 Mac 继续工作；已开启保持解锁" : (phase == .partial ? "未就绪：" + missing.joined(separator: "、") : "合上盖子恢复系统默认行为") }
}
// Device shape = closed-lid setting; light = all required parts ready.
struct Look: Hashable {
    let lidClosed: Bool, lit: Bool
}
struct StatusError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// File-backed output cannot deadlock on a full pipe, or an inherited pipe left open by a child.
func runCommand(_ path: String, _ args: [String], timeout: TimeInterval = 15) -> (Int32, String) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("clamshell-" + UUID().uuidString)
    guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
          let output = try? FileHandle(forWritingTo: url) else { return (1, "无法创建命令输出缓冲") }
    defer { try? output.close(); try? FileManager.default.removeItem(at: url) }
    let p = Process(), done = DispatchSemaphore(value: 0)
    p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    p.standardInput = FileHandle.nullDevice; p.standardOutput = output; p.standardError = output
    p.terminationHandler = { _ in done.signal() }
    do { try p.run() } catch { return (1, error.localizedDescription) }
    if done.wait(timeout: .now() + timeout) == .timedOut {
        p.terminate()
        if done.wait(timeout: .now() + 1) == .timedOut { kill(p.processIdentifier, SIGKILL); done.wait() }
        return (124, "命令超时：" + URL(fileURLWithPath: path).lastPathComponent)
    }
    let data = (try? Data(contentsOf: url)) ?? Data()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

func parseState(settings: String, power: String) throws -> ModeState {
    func flag(_ key: String, in text: String, values: String) throws -> String {
        let pattern = "(?m)^\\s*" + NSRegularExpression.escapedPattern(for: key) + "\\s+(" + values + ")\\s*$"
        guard let range = text.range(of: pattern, options: .regularExpression) else {
            throw StatusError(message: "无法识别状态字段：" + key)
        }
        return String(text[range]).split(whereSeparator: { $0.isWhitespace }).last.map(String.init)!
    }
    return try ModeState(closed: flag("closed-lid", in: settings, values: "on|off") == "on",
                         unlocked: flag("always-unlocked", in: settings, values: "on|off") == "on",
                         power: flag("SleepDisabled", in: power, values: "0|1") == "1")
}

func readState(reminal: String, run: (String, [String]) -> (Int32, String)) throws -> ModeState {
    let settings = run(reminal, ["settings"])
    let power = run("/usr/bin/pmset", ["-g", "live"])
    for (name, result) in [("Reminal 设置", settings), ("系统睡眠状态", power)] {
        guard result.0 == 0 else { throw StatusError(message: name + "读取失败：" + result.1) }
    }
    return try parseState(settings: settings.1, power: power.1)
}

// AppleClamshellState on IOPMrootDomain: the physical lid. A Mac without a lid reads as open.
func readLidClosed() -> Bool {
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard root != 0 else { return false }
    defer { IOObjectRelease(root) }
    return (IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? Bool) ?? false
}
