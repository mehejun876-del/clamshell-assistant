import AppKit

// 菜单栏图标：每次只显示一台设备。关闭态 = MacBook（SF Symbol macbook），开启态 = Mac Studio（SF Symbol macstudio，状态灯点亮）。
// 切换时 MacBook 合盖，压成的扁平机身经形状插值升起、收窄成 Mac Studio 的圆角机身，前面板细节随后淡入；反向亦然。
let W: CGFloat = 26, H: CGFloat = 18
let fps = 24.0                       // 仅用于换算每段动画时长（帧数 / 24）；播放按显示器刷新率(60Hz)连续采样
let macbookSym = NSImage(systemSymbolName: "macbook", accessibilityDescription: nil)!.withSymbolConfiguration(.init(pointSize: 17, weight: .regular))!   // 28×17
let studioSym = NSImage(systemSymbolName: "macstudio", accessibilityDescription: nil)!.withSymbolConfiguration(.init(pointSize: 17 * 13.875 / 11.5, weight: .regular))!  // 30×18，再缩放到与 MacBook 墨迹等高
let mbRect = NSRect(x: -1, y: 0.375, width: 28, height: 17), stRect = NSRect(x: -1.4878, y: 0.0332, width: 29.4690, height: 17.6814)
let lidSplit: CGFloat = 3.5, mbCX: CGFloat = 13, lidVec: CGFloat = 0.4          // 底座顶边（盖板与底座的分界）与水平中心
let ledC = NSPoint(x: 20.814, y: 6.609)                   // macstudio 符号右下角那颗圆点 = 状态灯
let stroke: CGFloat = 1.5                                 // 放大后的 macstudio 描边宽度
let closedRect = NSRect(x: 1.6, y: 1.435, width: 22.8, height: 4.215)       // 合上的 MacBook 外轮廓
let studioRect = NSRect(x: 0.9375, y: 1.875, width: 24.125, height: 13.875)  // 与 MacBook 墨迹等高、水平居中的外轮廓
let studioInner = NSRect(x: 2.4375, y: 3.375, width: 21.125, height: 10.875) // 其内部（放前面板细节）

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
func seg(_ t: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat { min(1, max(0, (t - a) / (b - a))) }
func smooth(_ x: CGFloat) -> CGFloat { let t = min(1, max(0, x)); return t * t * (3 - 2 * t) }

// cubic-bezier(0.4, 0, 0.2, 1) 标准缓动。仅在预渲染帧时计算。
func ease(_ x: CGFloat) -> CGFloat {
    let x = min(1, max(0, Double(x)))
    func b(_ t: Double, _ a: Double, _ c: Double) -> Double { 3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * c + t * t * t }
    var lo = 0.0, hi = 1.0
    for _ in 0..<24 { let m = (lo + hi) / 2; if b(m, 0.4, 0.2) < x { lo = m } else { hi = m } }
    return CGFloat(b((lo + hi) / 2, 0, 1))
}
// 欠阻尼弹簧（ζ=0.7，约 4.6% 过冲后回落）。
func spring(_ x: CGFloat) -> CGFloat {
    guard x > 0 else { return 0 }
    let z = 0.7, w = 10.0, wd = w * (1 - z * z).squareRoot(), t = Double(x)
    return CGFloat(1 - exp(-z * w * t) * (cos(wd * t) + z * w / wd * sin(wd * t)))
}
func bump(_ x: CGFloat) -> CGFloat { sin(.pi * x) * (1 - x) }                                   // 先起后落的小脉冲
func ring(_ x: CGFloat) -> CGFloat { x <= 0 ? 0 : CGFloat(exp(-6 * Double(x)) * sin(10 * Double(x))) }   // 衰减振荡（“弹一下”）

// 一帧里所有可动元素的状态。
struct Pose {
    var lid: CGFloat = 1, stretch: CGFloat = 0, lapAlpha: CGFloat = 1     // MacBook：盖板开合(1 开 0 合)、横向拉伸
    var mw: CGFloat = 0, mh: CGFloat = 0, detail: CGFloat = 0              // 形变：宽度进度、高度进度（可弹簧过冲）、前面板细节透明度
    var led: CGFloat = 0                                                   // 状态灯：0 暗，1 亮
    var halo: (r: CGFloat, a: CGFloat) = (0, 0)                            // 灯周围扩散的光环
    var alpha: CGFloat = 1, dy: CGFloat = 0                                // 整体透明度/垂直偏移（启动动画）
    static func still(_ active: Bool) -> Pose {
        var p = Pose()
        if active { p.lid = 0; p.mw = 1; p.mh = 1; p.detail = 1; p.led = 1 }
        return p
    }
}

func ink(_ alpha: CGFloat) { NSColor.black.withAlphaComponent(alpha).set() }

func drawLaptop(_ p: Pose) {
    let a = p.lapAlpha; guard a > 0 else { return }
    if p.lid == 1 && p.stretch == 0 { macbookSym.draw(in: mbRect, from: .zero, operation: .sourceOver, fraction: a); return }
    let g = NSGraphicsContext.current!.cgContext
    // 底座：符号下半部分（裁剪到底座顶边以下，保持不动）
    g.saveGState(); g.clip(to: CGRect(x: -20, y: -20, width: 120, height: 20 + lidSplit))
    macbookSym.draw(in: mbRect, from: .zero, operation: .sourceOver, fraction: a); g.restoreGState()
    // 盖板：L ≥ lidVec 时用符号上半部分绕底座顶边纵向压缩（并横向拉伸）；更扁时换成同形状的矢量盖板，
    // 逐渐收成与底座平行的薄板——两种画法在切换点几何重合，不做透明度交叉淡入，因此没有重影发糊。
    let L = max(p.lid, 0), st = 1 + p.stretch
    if L >= lidVec {
        g.saveGState(); g.clip(to: CGRect(x: 2.8, y: lidSplit, width: 20, height: 40))
        g.translateBy(x: mbCX, y: lidSplit); g.scaleBy(x: st, y: L); g.translateBy(x: -mbCX, y: -lidSplit)
        macbookSym.draw(in: mbRect, from: .zero, operation: .sourceOver, fraction: a); g.restoreGState()
    } else {
        let s = smooth(L / lidVec), h = max(1.5, 12.25 * L), yb = lidSplit + 0.65 * (1 - s)
        let x0 = mbCX + (3.75 - mbCX) * st, x1 = mbCX + (22.25 - mbCX) * st
        let outer = NSRect(x: x0, y: yb, width: x1 - x0, height: h)
        let r = min(1.1, h / 2)
        if L <= 0.12 { ink(a); NSBezierPath(roundedRect: outer, xRadius: r, yRadius: r).fill() }   // 薄板：纯实心
        else {
            let inner = outer.insetBy(dx: 1.35, dy: min(1.35 * L, (h - 0.1) / 2))
            let path = NSBezierPath(roundedRect: outer, xRadius: r, yRadius: r)
            path.windingRule = .evenOdd; path.append(NSBezierPath(rect: inner))
            ink(a); path.fill()
            ink(a * (1 - 0.69 * smooth((L - 0.12) / 0.14))); NSBezierPath(rect: inner).fill()
        }
    }
}

// 状态灯：擦掉符号自带的圆点，换成可调亮度/大小的灯，并带向外扩散的光环。
func drawLED(_ p: Pose, _ a: CGFloat) {
    let ctx = NSGraphicsContext.current!
    ctx.compositingOperation = .clear
    NSBezierPath(ovalIn: NSRect(x: ledC.x - 1.9, y: ledC.y - 1.9, width: 3.8, height: 3.8)).fill()
    ctx.compositingOperation = .sourceOver
    let on = min(1.1, max(0, p.led)), lr = lerp(0.95, 1.45, on)
    ink(a * lerp(0.45, 1, min(1, on)))
    NSBezierPath(ovalIn: NSRect(x: ledC.x - lr, y: ledC.y - lr, width: 2 * lr, height: 2 * lr)).fill()
}
func drawHalo(_ p: Pose) {
    guard p.halo.a > 0 else { return }
    ink(p.halo.a)
    let h = NSBezierPath(ovalIn: NSRect(x: ledC.x - p.halo.r, y: ledC.y - p.halo.r, width: 2 * p.halo.r, height: 2 * p.halo.r))
    h.lineWidth = 0.8; h.stroke()
}

// Mac Studio：原样使用 SF Symbol。
func drawStudio(_ p: Pose) {
    studioSym.draw(in: stRect, from: .zero, operation: .sourceOver, fraction: 1)
    drawLED(p, 1); drawHalo(p)
}

// 形变：合上的 MacBook（底座 + 薄板）→ 一圈圆角描边，宽度先收窄、高度以弹簧升起 → 前面板细节（接口、状态灯）淡入。
func drawMorph(_ p: Pose) {
    let g = NSGraphicsContext.current!.cgContext
    let k = max(p.mw, p.mh)
    var bars = Pose(); bars.lid = 0; bars.lapAlpha = 1 - smooth(k / 0.25)
    drawLaptop(bars)
    let x0 = lerp(closedRect.minX, studioRect.minX, p.mw), x1 = lerp(closedRect.maxX, studioRect.maxX, p.mw)
    let y0 = lerp(closedRect.minY, studioRect.minY, p.mh), y1 = lerp(closedRect.maxY, studioRect.maxY, p.mh)
    let r = lerp(1.1, 3.2, min(1, max(0, p.mh)))
    let outer = NSRect(x: x0, y: y0, width: x1 - x0, height: max(y1 - y0, 0.5))
    ink(smooth(k / 0.2))
    let o = NSBezierPath(roundedRect: outer.insetBy(dx: stroke / 2, dy: stroke / 2), xRadius: r - stroke / 2, yRadius: r - stroke / 2)
    o.lineWidth = stroke; o.stroke()
    guard p.detail > 0 else { return }
    // 前面板细节：把符号裁剪到“当前机身内部 ∩ 最终内部”，只露出接口与状态灯，不带符号自己的外轮廓
    g.saveGState()
    let inner = outer.insetBy(dx: stroke, dy: stroke)
    if inner.height > 0.5 { NSBezierPath(roundedRect: inner, xRadius: max(0.1, r - stroke), yRadius: max(0.1, r - stroke)).addClip() }
    NSBezierPath(roundedRect: studioInner, xRadius: 1.4, yRadius: 1.4).addClip()
    studioSym.draw(in: stRect, from: .zero, operation: .sourceOver, fraction: p.detail)
    drawLED(p, p.detail)
    g.restoreGState()
    drawHalo(p)
}

func drawScene(_ p: Pose) {
    let g = NSGraphicsContext.current!.cgContext
    g.saveGState(); g.setAlpha(p.alpha); g.translateBy(x: 0, y: p.dy)
    if abs(p.mw - 1) < 0.01 && abs(p.mh - 1) < 0.01 && p.detail > 0.99 { drawStudio(p) }
    else if max(p.mw, p.mh) > 1e-4 { drawMorph(p) }
    else { drawLaptop(p) }
    g.restoreGState()
}

// 同一幅图按给定倍率栅格化；模板图像，由系统按菜单栏明暗着色。
func bitmapImage(scales: [Int], _ pose: Pose) -> NSImage {
    let image = NSImage(size: NSSize(width: W, height: H))
    for s in scales {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W) * s, pixelsHigh: Int(H) * s, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        drawScene(pose)
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)
    }
    image.isTemplate = true
    return image
}

// 动画：单台设备之间的切换。τ ∈ 0...1。
enum Kind {
    case on, off, refresh(Bool), launch(Bool)
    var frames: Int { switch self { case .on, .off, .launch(true): return 22; case .launch(false): return 16; case .refresh: return 17 } }
    var duration: Double { Double(frames) / fps }
    func pose(_ t: CGFloat) -> Pose {
        switch self {
        case .on:
            // MacBook 合盖（缓动 + 横向拉伸）→ 扁平机身收窄、以弹簧升起为 Mac Studio → 前面板细节淡入 → 状态灯点亮并扩散光环
            var p = Pose()
            p.lid = 1 - ease(seg(t, 0.03, 0.34))
            p.stretch = 0.08 * sin(.pi * seg(t, 0.03, 0.42))
            p.mw = ease(seg(t, 0.34, 0.62)); p.mh = spring(seg(t, 0.34, 0.78))
            p.detail = smooth(seg(t, 0.58, 0.78))
            p.led = spring(seg(t, 0.72, 1.0))
            let k = seg(t, 0.72, 0.98)
            p.halo = (lerp(1.0, 3.5, ease(k)), 0.85 * (1 - k) * min(1, k * 8))
            return p
        case .off:
            // 状态灯收光 → 前面板细节淡出，机身压扁并展宽回 MacBook → 盖板以弹簧打开并微微拉伸后松弛
            var p = Pose()
            p.led = 1 - ease(seg(t, 0.03, 0.30))
            let hk = seg(t, 0.0, 0.28)
            p.halo = (lerp(3.0, 1.0, ease(hk)), 0.6 * sin(.pi * hk))
            p.detail = 1 - smooth(seg(t, 0.28, 0.46))
            p.mw = 1 - ease(seg(t, 0.34, 0.62)); p.mh = 1 - ease(seg(t, 0.30, 0.64))
            p.lid = spring(seg(t, 0.58, 0.98))
            p.stretch = 0.06 * sin(.pi * seg(t, 0.58, 0.88))
            return p
        case .refresh(let active):
            // 轻微提示：Studio 状态灯闪一下并荡出一圈涟漪；MacBook 则盖板轻轻点一下头
            var p = Pose.still(active)
            if active {
                p.led = 1 - 0.5 * sin(.pi * seg(t, 0.15, 0.55))
                let k = seg(t, 0.30, 0.90)
                p.halo = (lerp(1.0, 3.4, ease(k)), 0.7 * (1 - k) * min(1, k * 8))
            } else {
                p.lid = 1 - 0.10 * sin(.pi * seg(t, 0.05, 0.80))
            }
            return p
        case .launch(let active):
            // 开场：设备带弹簧从桌面线升起；开启态最后点亮状态灯
            var p = Pose.still(active)
            let u = active ? t : t * 0.72
            p.dy = lerp(-12, 0, spring(seg(u, 0.0, 0.55))); p.alpha = smooth(seg(u, 0, 0.25))
            if active {
                p.led = spring(seg(t, 0.62, 0.95))
                let k = seg(t, 0.62, 0.95)
                p.halo = (lerp(1.0, 3.5, ease(k)), 0.8 * (1 - k) * min(1, k * 8))
            }
            return p
        }
    }
}

final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let reminal = FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.local/bin/reminal") ? NSHomeDirectory() + "/.local/bin/reminal" : Bundle.main.resourcePath! + "/reminal.app/Contents/MacOS/reminal"
    var busy = false
    var checking = false
    var current = (false, false, false, false)
    var shownActive: Bool?
    var pingPending = false
    var link: CADisplayLink?            // 仅动画期间存在
    var overlay: NSView?                // 仅动画期间存在：盖在状态栏按钮上的图层，逐帧换 contents
    var maskLayer: CALayer?
    var ctx: CGContext?                 // 复用的绘制缓冲，结束即释放
    var started = 0.0, ticks = 0
    var pending: (Kind, Double, NSImage, (() -> Void)?)?
    lazy var offImage: NSImage = { let i = bitmapImage(scales: [1, 2], .still(false)); i.accessibilityDescription = "正常模式"; return i }()
    lazy var onImage: NSImage = { let i = bitmapImage(scales: [1, 2], .still(true)); i.accessibilityDescription = "合盖运行已开启"; return i }()
    let menu = NSMenu()
    lazy var header = item("", nil)
    lazy var detail = item("", nil)
    lazy var toggle = item("", #selector(toggleMode))
    lazy var refreshItem = item("刷新状态", #selector(refreshMenu))
    lazy var quit = item("退出菜单栏助手", #selector(quitApp), "q")

    func item(_ title: String, _ action: Selector?, _ key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if action == nil { i.isEnabled = false } else { i.target = self }
        return i
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        status.button?.imagePosition = .imageOnly
        menu.delegate = self
        [header, detail, .separator(), toggle, refreshItem, .separator(), quit].forEach { menu.addItem($0) }
        status.menu = menu
        #if DUMP
        dumpFrames(); NSApp.terminate(nil)
        #elseif BENCH
        status.button?.image = offImage
        benchmark(remaining: Int(ProcessInfo.processInfo.environment["BENCH_N"] ?? "12")!, target: true)
        #else
        refresh()
        #endif
    }
    #if BENCH
    func benchmark(remaining: Int, target: Bool) {
        guard remaining > 0 else { NSApp.terminate(nil); return }
        play(target ? .on : .off, final: target ? onImage : offImage) { [weak self] in self?.benchmark(remaining: remaining - 1, target: !target) }
    }
    #endif
    #if DUMP
    func dumpFrames() {
        let dir = ProcessInfo.processInfo.environment["DUMP_DIR"] ?? "/tmp/lidhelper_frames"
        let scale = Int(ProcessInfo.processInfo.environment["DUMP_SCALE"] ?? "2")!
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func save(_ pose: Pose, _ name: String) {
            let rep = bitmapImage(scales: [scale], pose).representations[0] as! NSBitmapImageRep
            try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
        let kinds: [(String, Kind)] = [("on", .on), ("off", .off), ("refresh-off", .refresh(false)), ("refresh-on", .refresh(true)), ("launch-off", .launch(false)), ("launch-on", .launch(true))]
        for (name, kind) in kinds { for i in 0..<kind.frames { save(kind.pose(CGFloat(i) / CGFloat(kind.frames - 1)), String(format: "\(name)-%02d", i)) } }
        for i in 0..<20 { save(Kind.on.pose(0.03 + 0.0165 * CGFloat(i)), String(format: "lid-%02d", i)) }
        save(.still(false), "static-off"); save(.still(true), "static-on")
    }
    #endif
    func run(_ path: String, _ args: [String]) -> (Int32, String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let output = Pipe(); p.standardOutput = output; p.standardError = output
        p.standardInput = FileHandle.nullDevice
        do { try p.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); return (p.terminationStatus, String(decoding: data, as: UTF8.self)) }
        catch { return (1, error.localizedDescription) }
    }
    func state() -> (Bool, Bool, Bool, Bool) {
        let s = run(reminal, ["settings"]).1
        let power = run("/usr/bin/pmset", ["-g", "live"]).1
        let sessions = run(reminal, ["list", "lid-agent"]).1
        return (s.contains("closed-lid           on"), s.contains("always-unlocked      on"), power.contains("SleepDisabled\t\t1"), sessions.range(of: #"(?m)^\s*lid-agent\s+\S+\s+"#, options: .regularExpression) != nil)
    }
    func image(_ active: Bool) -> NSImage { active ? onImage : offImage }
    // 播放：按显示器刷新率(60Hz)的 CADisplayLink 逐帧采样 pose(t)——缓动/弹簧曲线与时长不变——
    // 画进同一块复用的位图，再换给覆盖在按钮上的图层的 contents（不再每帧设置 NSStatusBarButton.image）。
    // 图层用位图作遮罩、按菜单栏明暗取黑/白，与模板图像着色一致。结束即停 DisplayLink、拆图层、释放缓冲，空闲零开销。
    func play(_ kind: Kind, final: NSImage, completion: (() -> Void)? = nil) {
        stopPlayback()
        guard let button = status.button, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { status.button?.image = final; completion?(); return }
        let scale = max(2, button.window?.backingScaleFactor ?? 2)
        let px = Int(CGFloat(W) * scale)
        let c = CGContext(data: nil, width: px, height: Int(CGFloat(H) * scale), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.scaleBy(x: scale, y: scale); ctx = c
        var white = false
        button.effectiveAppearance.performAsCurrentDrawingAppearance { white = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
        let tint = CALayer(), mask = CALayer(), view = NSView(frame: NSRect(x: (button.bounds.width - W) / 2, y: (button.bounds.height - H) / 2, width: W, height: H))
        view.wantsLayer = true
        tint.frame = view.bounds; mask.frame = view.bounds; mask.contentsScale = scale
        tint.backgroundColor = white ? .white : .black; tint.mask = mask
        view.layer!.addSublayer(tint)
        let blank = NSImage(size: NSSize(width: W, height: H)); blank.isTemplate = true
        button.image = blank
        button.addSubview(view); overlay = view; maskLayer = mask
        let duration = kind.duration
        started = CACurrentMediaTime(); ticks = 0
        let link = button.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        self.link = link
        pending = (kind, duration, final, completion)
        tick(link)
        link.add(to: .main, forMode: .common)
    }
    @objc func tick(_ link: CADisplayLink) {
        guard let (kind, duration, final, completion) = pending, let c = ctx, let mask = maskLayer else { return }
        let t = (link.targetTimestamp - started) / duration
        if t >= 1 {
            stopPlayback(); status.button?.image = final
            #if BENCH
            print(String(format: "ticks %d in %.3fs = %.1f fps", ticks, duration, Double(ticks) / duration))
            #endif
            completion?(); return
        }
        autoreleasepool {
            ticks += 1
            c.clear(CGRect(x: 0, y: 0, width: CGFloat(c.width), height: CGFloat(c.height)))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
            drawScene(kind.pose(CGFloat(max(0, t))))
            NSGraphicsContext.restoreGraphicsState()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            mask.contents = c.makeImage()
            CATransaction.commit()
        }
    }
    func stopPlayback() {
        link?.invalidate(); link = nil
        overlay?.removeFromSuperview(); overlay = nil; maskLayer = nil; ctx = nil; pending = nil
    }
    func refresh() {
        guard !busy, !checking else { return }
        checking = true
        DispatchQueue.global(qos: .utility).async {
            let result = self.state()
            DispatchQueue.main.async {
                self.checking = false
                guard !self.busy else { return }
                self.current = result
                self.updateMenu()
            }
        }
    }
    func updateMenu() {
        let (closed, unlocked, power, session) = current
        let active = closed && unlocked && power && session
        if let previous = shownActive {
            if previous != active { play(active ? .on : .off, final: image(active)) }
            else if pingPending && link == nil { play(.refresh(active), final: image(active)) }
        } else {
            play(.launch(active), final: image(active))
        }
        pingPending = false
        shownActive = active
        status.button?.toolTip = active ? "合盖助手：允许合盖运行" : "合盖助手：正常模式或合盖运行未就绪"
        header.title = active ? "允许合盖运行" : "正常模式"
        detail.title = active ? "Agent 可继续工作" : "合上盖子可能会睡眠"
        toggle.title = active || closed || power ? "关闭合盖运行" : "开启合盖运行"
    }
    func menuWillOpen(_ menu: NSMenu) { refresh() }
    @objc func refreshMenu() { pingPending = !busy && !checking; refresh() }
    @objc func quitApp() { NSApp.terminate(nil) }
    @objc func toggleMode() {
        let (closed, _, power, _) = current; let enable = !(closed || power)
        busy = true; status.button?.toolTip = "正在切换…"
        DispatchQueue.global(qos: .userInitiated).async {
            let value = enable ? "1" : "0"
            // The first authorization installs a rule limited to these two pmset commands.
            var auth = self.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", value])
            if auth.0 != 0 {
                let uid = getuid()
                let path = "/private/etc/sudoers.d/reminal-clamshell-\(uid)"
                let user = NSUserName()
                let command = "umask 077; t=\(path).tmp; printf '%s\\n' '\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1' > \"$t\" && chmod 0440 \"$t\" && /usr/sbin/visudo -cf \"$t\" >/dev/null && mv -f \"$t\" \(path)"
                let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                let script = "do shell script \"\(escaped)\" with administrator privileges with prompt \"合盖助手需要一次管理员授权，以后切换时无需重复输入密码。\""
                auth = self.run("/usr/bin/osascript", ["-e", script])
                if auth.0 == 0 { auth = self.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", value]) }
            }
            var error: String? = nil
            if auth.0 == 0 {
                let mode = enable ? "on" : "off"
                let closedResult = self.run(self.reminal, ["settings", "closed-lid", mode])
                let unlockResult = self.run(self.reminal, ["settings", "always-unlocked", mode])
                if closedResult.0 != 0 || unlockResult.0 != 0 { error = "Reminal 设置未能保存，请刷新状态后重试。" }
                if enable && self.run(self.reminal, ["list", "lid-agent"]).1.range(of: #"(?m)^\s*lid-agent\s+\S+\s+"#, options: .regularExpression) == nil {
                    if self.run(self.reminal, ["new", "lid-agent"]).0 != 0 { error = "后台会话启动失败，请检查网络后重试。" }
                }
                let actual = self.state()
                if enable && !(actual.0 && actual.1 && actual.2 && actual.3) { error = "部分设置未生效，请刷新状态后重试。" }
                if !enable && (actual.0 || actual.1 || actual.2) { error = "部分设置未能关闭，请刷新状态后重试。" }
            } else if !auth.1.contains("User canceled") && !auth.1.contains("用户取消") { error = "无法更改系统睡眠设置：\n" + auth.1 }
            DispatchQueue.main.async {
                self.busy = false; self.refresh()
                if let error = error { let a = NSAlert(); a.messageText = "切换未完成"; a.informativeText = error; a.runModal() }
            }
        }
    }
}
let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
