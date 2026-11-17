// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Harshal Gajjar
// Modified 2026 for Clamshell Assistant: closed-lid-only build of
// reminal-capture. Kept verbatim from Reminal v3.19.4: the `liddim` (dim the
// built-in screen while the lid is shut, restore on open) and `vdisplay`
// (software display while headless) subcommands. Removed: window/desktop
// capture and streaming, input injection, permission prompts and `serve`.

import CoreGraphics
import Foundation
import IOKit

let args = CommandLine.arguments
// liddimCheck is how the IOKit interest callback, a C function pointer that
// cannot capture, reaches the liddim subcommand's check.
var liddimCheck: (() -> Void)?

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

// Lid dimmer subcommand: `reminal-capture liddim <state-file>`, run by the
// agent while closed-lid mode is on. With sleep disabled, a shut MacBook keeps
// its built-in screen online, lit at whatever brightness it had, behind the
// lid. This watches the lid and turns that screen's brightness to 0 when it
// shuts, and back to what it was when it opens. Brightness rather than display
// sleep: display sleep is all-or-nothing on macOS (the virtual display too),
// stops the compositor, so mirroring freezes, and can lock the Mac.
//
// The brightness it took away is written to <state-file> before the screen is
// dimmed, so it is never lost: a helper killed while the lid is shut puts it
// back the next time it runs with the lid open. On open it is restored if the
// screen is below it, dark or at the low level macOS's auto-brightness picks
// after a long time in the dark; once the lid is open the record is gone, so a
// brightness someone sets afterwards stands. Each event is a line on stdout,
// which the agent logs.
// Stdin is the agent's lifeline: EOF (closed-lid mode off, agent gone) and
// SIGTERM restore before exiting. A "handoff" line first ends it without
// restoring, the record left as it is: the agent sends it when it stops
// standing in for another process whose own dimmer is running, which keeps
// the screen dark behind a shut lid and puts the record back when it opens.
//
// The lid is the root power domain's AppleClamshellState, re-read on every
// power-management interest message and every 2s as a backstop. Brightness is
// the private DisplayServices framework (what the brightness keys use), loaded
// at runtime: a macOS without it, or a Mac with no built-in screen, makes this
// exit(1) and the agent stops asking.
//
// REMINAL_LIDDIM_FAKE=<dir> replaces the lid with <dir>/lid ("1" shut) and the
// screen with <dir>/brightness (a float), so the logic runs on a machine with
// neither (a VM). Honoured only by a helper compiled with -D REMINAL_TEST_HOOKS;
// a release helper ignores it.
if args.count >= 2, args[1] == "liddim" {
    guard args.count >= 3 else {
        FileHandle.standardError.write(Data("usage: reminal-capture liddim <state-file>\n".utf8))
        exit(2)
    }
    let statePath = args[2]
    #if REMINAL_TEST_HOOKS
    let fake = ProcessInfo.processInfo.environment["REMINAL_LIDDIM_FAKE"].flatMap { $0.isEmpty ? nil : $0 }
    #else
    let fake: String? = nil
    #endif
    // fflush, not synchronizeFile: the latter throws when stdout is a pipe.
    // Each line goes to the agent, which logs it (the daemon's log): what the
    // dimmer saw and did, so a report from real hardware has evidence.
    let stamp = ISO8601DateFormatter()
    stamp.formatOptions = [.withInternetDateTime]
    stamp.timeZone = .current
    func say(_ s: String) {
        print("\(stamp.string(from: Date())) \(s)")
        fflush(stdout)
    }

    // ---- the lid ----
    let rootDomain = fake == nil
        ? IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain")) : 0
    func lidShut() -> Bool? {
        if let fake {
            guard let s = try? String(contentsOfFile: fake + "/lid", encoding: .utf8) else { return nil }
            return s.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        }
        guard rootDomain != 0,
              let v = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
                  .takeRetainedValue() as? Bool
        else { return nil }
        return v
    }
    if fake == nil && lidShut() == nil { die("liddim: this Mac reports no lid") }

    // ---- the built-in screen's brightness ----
    typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    var getB: GetFn?, setB: SetFn?
    if fake == nil {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let g = dlsym(h, "DisplayServicesGetBrightness"), let st = dlsym(h, "DisplayServicesSetBrightness")
        else { die("liddim: DisplayServices unavailable") }
        getB = unsafeBitCast(g, to: GetFn.self)
        setB = unsafeBitCast(st, to: SetFn.self)
    }
    // The built-in screen, while it is online. With the lid shut and an
    // external monitor attached macOS takes it offline itself: nothing to dim.
    func builtin() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &n) == .success else { return nil }
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 }
    }
    func brightness() -> Float? {
        if let fake {
            return (try? String(contentsOfFile: fake + "/brightness", encoding: .utf8))
                .flatMap { Float($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        guard let d = builtin(), let getB else { return nil }
        var v: Float = 0
        return getB(d, &v) == 0 ? v : nil
    }
    func setBrightness(_ v: Float) -> Bool {
        if let fake {
            return (try? String(v).write(toFile: fake + "/brightness", atomically: true, encoding: .utf8)) != nil
        }
        guard let d = builtin(), let setB else { return false }
        return setB(d, v) == 0
    }

    // ---- what was taken away ----
    let dark: Float = 0.001
    // fallback is what a dark screen gets on open when the record cannot be
    // trusted: lit and readable, rather than left dark.
    let fallback: Float = 0.5
    // recorded: nil with no record, else the record's brightness, or nil
    // inside when it is not one this helper could have written (not a
    // number, not finite, not in (dark, 1]).
    func recorded() -> Float?? {
        guard let s = try? String(contentsOfFile: statePath, encoding: .utf8) else { return nil }
        guard let v = Float(s.trimmingCharacters(in: .whitespacesAndNewlines)),
              v.isFinite, v > dark, v <= 1 else { return .some(nil) }
        return .some(v)
    }
    func saved() -> Float? { recorded() ?? nil }

    // restore puts the saved brightness back if the screen is below it. The
    // record goes either way: once the lid is open, a brightness someone
    // chooses is theirs.
    //
    // below: how far under the record the screen must be to count as not
    // put back. Readings round-trip through a float; this is not a choice.
    let below: Float = 0.01
    var offlineSaid = false
    func restore() {
        guard let rec = recorded() else { return }
        // No reading (the screen is offline: lid shut with a monitor attached,
        // or not yet back after a long sleep) says nothing about what someone
        // chose; keep the record for the next look.
        guard let now = brightness() else {
            if !offlineSaid { say("screen not readable; keeping \(rec.map { String($0) } ?? "an unusable record")") }
            offlineSaid = true
            return
        }
        offlineSaid = false
        // Put back whenever the screen is below what was taken: macOS's own
        // auto-brightness sets a low level on open after the sensor sat in the
        // dark under the lid, and that is not a choice anyone made. Nobody can
        // lower it on purpose with the lid shut, and once it is open the record
        // is gone, so a level set after this is left alone.
        let was = rec ?? fallback
        if now <= dark || now < was - below {
            if setBrightness(was) { say("restored \(was) (screen was at \(now))") } else { return } // keep the record; try again
        } else {
            say("left as set: \(now) (had saved \(rec.map { String($0) } ?? "an unusable record"))")
        }
        try? FileManager.default.removeItem(atPath: statePath)
    }
    // redims: -1 until this shut's first dim, then how many more it took.
    var redims = -1
    func dim() {
        guard let now = brightness() else { return }
        if now > dark {
            // The record first: a dark screen with no record is a brightness
            // lost. An existing one stands: the screen lit again while the lid
            // stayed shut (auto-brightness) is not what to put back.
            if saved() == nil { // none, or one that cannot be trusted
                guard (try? String(now).write(toFile: statePath, atomically: true, encoding: .utf8)) != nil else { return }
            }
            // Logged once a shut: auto-brightness can light the screen again
            // every few seconds under the lid, and a line each time would be
            // tens of thousands a night. The rest are counted, and said at open.
            if setBrightness(0) {
                if redims < 0 { say("dimmed from \(now) (saved \(saved().map { String($0) } ?? "nothing"))") }
                redims += 1
            }
        }
    }
    var wasShut: Bool?
    func check() {
        guard let shut = lidShut() else { return }
        if shut != wasShut {
            say(shut ? "lid shut" : "lid open")
            if !shut && redims > 0 { say("re-dimmed \(redims) times while shut") }
            redims = -1
        }
        wasShut = shut
        if shut { dim() } else { restore() }
    }

    let q = DispatchQueue(label: "reminal.liddim")
    func finish() -> Never {
        q.sync { restore() }
        exit(0)
    }
    // SIGTERM, SIGINT and SIGHUP all end it the same way: brightness first.
    var enders: [DispatchSourceSignal] = []
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: q)
        src.setEventHandler { restore(); exit(0) }
        src.resume()
        enders.append(src)
    }
    DispatchQueue.global(qos: .utility).async {
        var pending = Data()
        while true {
            let d = FileHandle.standardInput.availableData
            if d.isEmpty { finish() } // EOF: the agent is gone or closed-lid mode is off
            pending.append(d)
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...nl)
                if line == "handoff" {
                    q.sync { say("handed off: the record kept for the dimmer that runs now") }
                    exit(0)
                }
            }
            if pending.count > 256 { pending.removeAll() } // no line we know is that long
        }
    }

    if fake == nil, let port = IONotificationPortCreate(kIOMainPortDefault) {
        IONotificationPortSetDispatchQueue(port, q)
        var note: io_object_t = 0
        IOServiceAddInterestNotification(port, rootDomain, kIOGeneralInterest, { _, _, _, _ in
            liddimCheck?()
        }, nil, &note)
    }
    liddimCheck = { check() }
    let tick = DispatchSource.makeTimerSource(queue: q)
    tick.schedule(deadline: .now(), repeating: .seconds(2))
    tick.setEventHandler { check() }
    tick.resume()
    say("liddim up")
    withExtendedLifetime(enders) { dispatchMain() }
}

// Multi-stream server subcommand: `reminal-capture serve` hosts EVERY capture
// in this one process — see runServeMode below for the protocol and for why
// (replayd kills concurrent streams from same-identity sibling processes).

if args.count >= 2, args[1] == "vdisplay" {
    let vw = args.count >= 3 ? (UInt(args[2]) ?? 1920) : 1920
    let vh = args.count >= 4 ? (UInt(args[3]) ?? 1080) : 1080

    func objcNew(_ className: String) -> NSObject? {
        guard let cls = NSClassFromString(className) as? NSObject.Type else { return nil }
        return cls.init()
    }
    // KVC with an existence check so a renamed property in a future macOS makes
    // us fail cleanly instead of throwing setValue:forUndefinedKey:.
    func setIfPossible(_ obj: NSObject, _ key: String, _ value: Any?) -> Bool {
        let cap = key.prefix(1).uppercased() + key.dropFirst()
        guard obj.responds(to: NSSelectorFromString("set\(cap):")) else { return false }
        obj.setValue(value, forKey: key)
        return true
    }

    guard let desc = objcNew("CGVirtualDisplayDescriptor") else { die("vdisplay: CGVirtualDisplayDescriptor unavailable") }
    _ = setIfPossible(desc, "name", "reminal")
    guard setIfPossible(desc, "maxPixelsWide", vw), setIfPossible(desc, "maxPixelsHigh", vh) else {
        die("vdisplay: descriptor interface changed (maxPixels)")
    }
    // Physical size drives the assumed DPI; ~24" at this resolution reads sanely.
    _ = setIfPossible(desc, "sizeInMillimeters", NSValue(size: NSSize(width: 530, height: Double(vh) / Double(vw) * 530)))
    _ = setIfPossible(desc, "productID", 0x7265)
    _ = setIfPossible(desc, "vendorID", 0x6d69)
    _ = setIfPossible(desc, "serialNum", 0x0001)
    _ = setIfPossible(desc, "queue", DispatchQueue.main)

    guard let displayCls: AnyClass = NSClassFromString("CGVirtualDisplay") else { die("vdisplay: CGVirtualDisplay unavailable") }
    let initSel = NSSelectorFromString("initWithDescriptor:")
    guard class_getInstanceMethod(displayCls, initSel) != nil,
          let rawAlloc = (displayCls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
          let display = (rawAlloc as? NSObject)?.perform(initSel, with: desc)?.takeUnretainedValue() as? NSObject
    else { die("vdisplay: CGVirtualDisplay init failed") }

    guard let modeCls: AnyClass = NSClassFromString("CGVirtualDisplayMode") else { die("vdisplay: CGVirtualDisplayMode unavailable") }
    let modeSel = NSSelectorFromString("initWithWidth:height:refreshRate:")
    guard let modeMethod = class_getInstanceMethod(modeCls, modeSel),
          let rawMode = (modeCls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject
    else { die("vdisplay: mode interface changed") }
    typealias ModeInit = @convention(c) (NSObject, Selector, UInt, UInt, Double) -> NSObject
    let modeInit = unsafeBitCast(method_getImplementation(modeMethod), to: ModeInit.self)
    let mode = modeInit(rawMode, modeSel, vw, vh, 60.0)

    guard let settings = objcNew("CGVirtualDisplaySettings") else { die("vdisplay: CGVirtualDisplaySettings unavailable") }
    _ = setIfPossible(settings, "hiDPI", 0)
    guard setIfPossible(settings, "modes", [mode]) else { die("vdisplay: settings interface changed (modes)") }

    let applySel = NSSelectorFromString("applySettings:")
    guard let applyMethod = class_getInstanceMethod(type(of: display), applySel) else { die("vdisplay: applySettings unavailable") }
    typealias ApplyFn = @convention(c) (NSObject, Selector, NSObject) -> Bool
    let apply = unsafeBitCast(method_getImplementation(applyMethod), to: ApplyFn.self)
    guard apply(display, applySel, settings) else { die("vdisplay: applySettings failed") }

    let did = (display.value(forKey: "displayID") as? NSNumber)?.uint32Value ?? 0
    // One line to stdout so the agent can log/inspect; then hold forever. The
    // display lives exactly as long as this process (`display` is kept alive by
    // the closure reference below).
    print("vdisplay up id=\(did) \(vw)x\(vh)")
    FileHandle.standardOutput.synchronizeFile()
    withExtendedLifetime(display) { CFRunLoopRun() }
    exit(0)
}


// Target: a CGWindowID for one window, or "display:<CGDirectDisplayID>" for a
// whole desktop (the agent lists displays as pseudo-windows with that id form).
// Validated here so a typo'd invocation gets usage instead of "window 0 not
// found"; the actual lookup happens in resolveCaptureTarget.

FileHandle.standardError.write(Data("usage: reminal-capture liddim <state-file> | vdisplay <width> <height>\n".utf8))
exit(2)
