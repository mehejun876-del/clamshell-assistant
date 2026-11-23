import Foundation
import Darwin

// Reminal closed-lid settings plus the system sleep switch. Whether the bundled
// closed-lid service runs is known locally and combined by the controller.
struct ModeState: Equatable {
    let closed: Bool, unlocked: Bool, power: Bool
    var allOn: Bool { closed && unlocked && power }
    var configured: Bool { closed || unlocked || power }
    func matches(_ on: Bool) -> Bool { on ? allOn : !configured }
}

// One interpretation of a successfully read settings + power snapshot.
// `intent` is the user's saved on/off choice; without one (first launch after an
// upgrade) the two Reminal settings decide and nothing is written automatically.
// There is no "partial" state: it is either on, off, or a named failure.
// V2: `intent` is the *effective* choice from decidePower(). `hold` says why it is off
// while AI smart mode is on, `auto` is set while AI smart mode keeps the Mac awake (a short
// summary for the header). Both default to nil, so every 1.4.1 construction keeps its exact
// behaviour and wording.
struct ModePresentation {
    let state: ModeState
    let serviceUp: Bool
    var intent: Bool? = nil
    var note: String? = nil
    var hold: Hold? = nil
    var auto: String? = nil
    var wantsOn: Bool { intent ?? (state.closed && state.unlocked) }
    var isReady: Bool { wantsOn && state.allOn && serviceUp }
    var isOff: Bool { !wantsOn && !state.configured }
    var consistent: Bool { isReady || isOff }
    var look: Look { Look(lidClosed: isReady, lit: isReady) }
    // One button that follows the effective choice: while AI keeps the Mac awake it switches
    // keep-awake off for this batch; otherwise it is the classic manual on/off.
    var toggleEnables: Bool { !wantsOn }
    var toggleTitle: String { toggleEnables ? "开启合盖运行" : "关闭合盖运行" }
    var faulty: [String] {
        let parts = [("合盖模式", state.closed), ("保持解锁", state.unlocked), ("系统禁止睡眠", state.power)]
        if wantsOn { return parts.filter { !$0.1 }.map(\.0) + (state.allOn && !serviceUp ? ["合盖服务"] : []) }
        return parts.filter { $0.1 }.map(\.0)
    }
    var header: String {
        if isReady { return auto == nil ? "合盖运行中" : "AI 合盖运行中" }     // 任务数在 toolTip 和「高级选项」里
        if isOff { return hold?.text ?? "正常模式" }
        let text = wantsOn ? "开启失败：" + faulty.joined(separator: "、") + "未生效"
                           : "未完全关闭：" + faulty.joined(separator: "、") + "仍开着"
        let named = note.map { text + "（\($0)）" } ?? text
        if let h = hold, !wantsOn { return h.text + " · " + named }
        return named
    }
}

// Device shape and light both follow full readiness: ready = Studio + lit, otherwise MacBook.
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
