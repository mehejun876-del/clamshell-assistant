import AppKit
import ServiceManagement
import UserNotifications

// ============================================================================
// 合盖助手（ClamshellAssistant）独立动画核心模块
// 来源：作者的「MacBook-to-MacStudio」动画包（独立可预览版本，已合回本文件）
//
// 静态造型：
//   - 关闭合盖模式（progress = 0）：苹果官方 SF macbook 轮廓的纯矢量复刻
//     （25.5pt 胶囊圆头底座 + 19.5×12.5pt 宽屏 + 0.30 半透明屏幕填充 + 4.30×1.32 刘海）
//   - 开启合盖模式（progress = 1）：等高 Mac Studio 轮廓
//     （22.56×14.43pt 圆角机身 + 底部内嵌散热底座 + 2 竖向 USB-C + 1 横向 SDXC + 右侧状态灯）
// 动画节奏：
//   - 总帧数 frames = 22，换算基准 fps = 24.0 -> 单次切换时长 22/24 ≈ 0.917s
//   - 运行时由 CADisplayLink 按显示器刷新率（60Hz）连续采样 t ∈ 0...1
// ============================================================================

// MARK: - 全局尺寸与时间基准

let W: CGFloat = 27, H: CGFloat = 18
let statusBarLength: CGFloat = 35    // 状态栏按钮固定宽度，居中包裹 25.5pt 底座，左右各留 ~4.75pt
let fps = 24.0                       // 用于换算动画时长（22/24 ≈ 0.917s）；播放按显示器刷新率(60Hz)连续采样
let mbCX: CGFloat = W * 0.5
let ledC = NSPoint(x: 20.65, y: 7.05)

// MARK: - 数学工具与苹果风格缓动曲线

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
func clamp01(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }
func seg(_ t: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat { clamp01((t - a) / (b - a)) }
func smooth(_ x: CGFloat) -> CGFloat { let t = clamp01(x); return t * t * (3 - 2 * t) }

func cubicBezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: CGFloat) -> CGFloat {
    let target = Double(clamp01(x))
    if target <= 0 { return 0 }
    if target >= 1 { return 1 }
    let cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx
    let cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by
    func sampleX(_ u: Double) -> Double { ((ax * u + bx) * u + cx) * u }
    func sampleDX(_ u: Double) -> Double { (3 * ax * u + 2 * bx) * u + cx }
    func sampleY(_ u: Double) -> Double { ((ay * u + by) * u + cy) * u }
    var u = target
    for _ in 0..<6 {
        let err = sampleX(u) - target
        if abs(err) < 1e-6 { return CGFloat(sampleY(u)) }
        let d = sampleDX(u)
        if abs(d) < 1e-6 { break }
        u -= err / d
    }
    var lo = 0.0, hi = 1.0
    u = target
    while hi - lo > 1e-6 {
        let val = sampleX(u)
        if abs(val - target) < 1e-6 { break }
        if target > val { lo = u } else { hi = u }
        u = 0.5 * (lo + hi)
    }
    return CGFloat(sampleY(u))
}

func ease(_ x: CGFloat) -> CGFloat { cubicBezier(0.4, 0.0, 0.2, 1.0, x) }
func easeAppleFluid(_ x: CGFloat) -> CGFloat { cubicBezier(0.22, 1.0, 0.36, 1.0, x) }
func easeAppleSymmetric(_ x: CGFloat) -> CGFloat { cubicBezier(0.42, 0.0, 0.18, 1.0, x) }
func easeAppleSettle(_ x: CGFloat) -> CGFloat { cubicBezier(0.30, 0.0, 0.16, 1.055, x) }
func easeLidDrop(_ x: CGFloat) -> CGFloat { cubicBezier(0.45, 0.0, 0.35, 1.0, x) }
func easePortPop(_ x: CGFloat) -> CGFloat { cubicBezier(0.32, 0.0, 0.22, 1.0, x) }

func spring(_ x: CGFloat) -> CGFloat {
    guard x > 0 else { return 0 }
    let z = 0.7, w = 10.0, wd = w * (1 - z * z).squareRoot(), t = Double(x)
    return CGFloat(1 - exp(-z * w * t) * (cos(wd * t) + z * w / wd * sin(wd * t)))
}

// MARK: - 帧状态数据结构（保持与主工程 Tests.swift / Controller 接口一致）

struct Pose {
    var progress: CGFloat = 0                                             // 归一化变形进度：0 = MacBook Pro，1 = Mac Studio
    var lid: CGFloat = 1                                                  // 1 展开，0 合盖
    var mw: CGFloat = 0, mh: CGFloat = 0                                  // 兼容自测：宽/高变形进度
    var led: CGFloat = 0                                                  // Mac Studio 状态灯亮度：0 暗，1 亮
    var halo: (r: CGFloat, a: CGFloat) = (0, 0)                           // 灯周围扩散的光环
    var alpha: CGFloat = 1, dy: CGFloat = 0                               // 整体透明度/垂直偏移（启动动画）
    var lapLed: CGFloat = 0                                               // 开盖时屏幕右下角的状态灯
    static func still(_ look: Look) -> Pose {
        var p = Pose()
        if look.lidClosed {
            p.progress = 1; p.lid = 0; p.mw = 1; p.mh = 1
            p.led = look.lit ? 1 : 0
        } else {
            p.lapLed = look.lit ? 1 : 0
        }
        return p
    }
}

// MARK: - 矢量绘制辅助

func ink(_ alpha: CGFloat) { NSColor.black.withAlphaComponent(alpha).set() }

// AppKit 非翻转坐标系 (y=0 在底，y=18 在顶) 的平滑圆角梯形（用于 2.5D 合盖屏）。
func buildTrapezoidPath(cx: CGFloat, botY: CGFloat, topY: CGFloat, botHalfW: CGFloat, topHalfW: CGFloat, rBot: CGFloat, rTop: CGFloat) -> NSBezierPath {
    let h = max(0.05, topY - botY)
    let blX = cx - botHalfW, brX = cx + botHalfW
    let tlX = cx - topHalfW, trX = cx + topHalfW
    let rt = min(rTop, h * 0.46, topHalfW * 0.45)
    let rb = min(rBot, h * 0.46, botHalfW * 0.45)
    let sideDX = trX - brX, sideDY = topY - botY
    let sideLen = hypot(sideDX, sideDY)
    let ux = sideLen > 0 ? sideDX / sideLen : 0
    let uy = sideLen > 0 ? sideDY / sideLen : 1

    let path = NSBezierPath()
    path.move(to: NSPoint(x: blX + rb, y: botY))
    path.line(to: NSPoint(x: brX - rb, y: botY))
    if rb >= 0.02 {
        path.curve(to: NSPoint(x: brX + ux * rb, y: botY + uy * rb),
                   controlPoint1: NSPoint(x: brX, y: botY),
                   controlPoint2: NSPoint(x: brX, y: botY))
    } else {
        path.line(to: NSPoint(x: brX, y: botY))
    }
    path.line(to: NSPoint(x: trX - ux * rt, y: topY - uy * rt))
    path.curve(to: NSPoint(x: trX - rt, y: topY),
               controlPoint1: NSPoint(x: trX, y: topY),
               controlPoint2: NSPoint(x: trX, y: topY))
    path.line(to: NSPoint(x: tlX + rt, y: topY))
    path.curve(to: NSPoint(x: tlX + ux * rt, y: topY - uy * rt),
               controlPoint1: NSPoint(x: tlX, y: topY),
               controlPoint2: NSPoint(x: tlX, y: topY))
    if rb >= 0.02 {
        path.line(to: NSPoint(x: blX - ux * rb, y: botY + uy * rb))
        path.curve(to: NSPoint(x: blX + rb, y: botY),
                   controlPoint1: NSPoint(x: blX, y: botY),
                   controlPoint2: NSPoint(x: blX, y: botY))
    } else {
        path.line(to: NSPoint(x: blX, y: botY))
    }
    path.close()
    return path
}

func drawLapLED(_ p: Pose) {
    guard p.lapLed > 0.01, p.lid > 0.9 else { return }
    let on = min(1.1, p.lapLed), lr = lerp(0.60, 0.90, on)
    let pt = NSPoint(x: 20.0, y: 6.1)
    ink(min(1, on))
    NSBezierPath(ovalIn: NSRect(x: pt.x - lr, y: pt.y - lr, width: 2 * lr, height: 2 * lr)).fill()
}

func drawHalo(_ p: Pose, center: NSPoint) {
    guard p.halo.a > 0 else { return }
    ink(p.halo.a)
    let h = NSBezierPath(ovalIn: NSRect(x: center.x - p.halo.r, y: center.y - p.halo.r, width: 2 * p.halo.r, height: 2 * p.halo.r))
    h.lineWidth = 0.85; h.stroke()
}

// MARK: - 核心矢量形变渲染

func drawVectorMorph(_ p: Pose) {
    let g = NSGraphicsContext.current!.cgContext
    let t = clamp01(p.progress)

    // 支持 .refresh 轻微点头（progress=0 时 lid 可微摆）
    let foldFromT = easeLidDrop(seg(t, 0.02, 0.33))
    let fold = max(foldFromT, clamp01(1 - p.lid))

    // 1. 屏幕盖板（对齐苹果官方 macbook pt=18：25.5pt 胶囊圆头底座 × 14.44pt 总高；19.5×12.5pt 宽屏；0.30 半透明屏幕填充）
    //    注意：lidTargetHalfW 严格以底座外缘 12.75 减去半描边计算，防止合盖 26%-36% 时盖板外扩超框
    let lidStrokeW = lerp(1.28, 0.28, smooth(seg(fold, 0.45, 0.96)))
    let lidTargetHalfW = 12.75 - lidStrokeW * 0.5
    let lidBotHalfW = lerp(9.11, lidTargetHalfW, smooth(seg(fold, 0.20, 0.85)))
    let lidTopHalfW = lerp(9.11, lidTargetHalfW, smooth(seg(fold, 0.04, 0.85)))
    let lidBotY = lerp(2.70, 3.70, smooth(seg(fold, 0.30, 0.90)))
    let lidTopClosed: CGFloat = 4.55
    let lidTopY = lidTopClosed + (15.55 - lidTopClosed) * (1 - fold)
    let lidTopR = lerp(1.30, 0.45, smooth(seg(fold, 0.55, 0.95)))
    let notchScaleY = clamp01(1 - fold * 1.75)

    // 2. 主机身收缩与垂直塑形（28% -> 73%，带微收腰与苹果轻量级弹性落位）
    let mW = easeAppleSymmetric(seg(t, 0.28, 0.66))
    let mH = easeAppleSettle(seg(t, 0.30, 0.73))
    let lidToChassis = smooth(seg(t, 0.30, 0.34))
    let baseCapFade = smooth(seg(t, 0.24, 0.34))
    let preMorphTop = lerp(3.70, 4.55, lidToChassis)

    let waist = 0.85 * sin(.pi * clamp01(mW))
    let chassisHalfW = lerp(12.61, 10.60, mW) - waist
    let chassisBotY = lerp(1.75, 3.40, mH)
    let chassisTopY = lerp(preMorphTop, 15.50, mH)
    let clampedMH = clamp01(mH)
    let closedCornerR = lerp(0.97, 0.45, baseCapFade)
    let chassisTopR = lerp(closedCornerR, 2.20, clampedMH)
    let chassisBotR = lerp(closedCornerR, 2.20, clampedMH)

    // 3. Mac Studio 底部内嵌散热底座（40% -> 72%）
    let footReveal = easeAppleFluid(seg(t, 0.40, 0.72))
    let footHalfW = lerp(chassisHalfW * 0.88, 9.05, footReveal)
    let footTopY = chassisBotY + 0.36
    let footBotY = lerp(chassisBotY, 1.75, footReveal)

    // 4. 前置接口与状态灯唤醒（58% -> 91%）
    let tb1 = easePortPop(seg(t, 0.58, 0.77))
    let tb2 = easePortPop(seg(t, 0.63, 0.82))
    let sdxc = easePortPop(seg(t, 0.68, 0.87))
    let ledAppear = easePortPop(seg(t, 0.73, 0.91))

    let lidVisible = t < 0.355
    let lidOpacity = 1 - smooth(seg(t, 0.335, 0.355))
    let symbolBaseToOutline = smooth(seg(t, 0.33, 0.62))

    // A. Mac Studio 底部内嵌底座
    if footReveal > 0.01 {
        let fx = mbCX - footHalfW
        let fw = footHalfW * 2
        let fh = max(0.2, footTopY - footBotY)
        let footRect = NSRect(x: fx, y: footBotY, width: fw, height: fh)
        ink(0.88 * footReveal)
        NSBezierPath(roundedRect: footRect, xRadius: 0.64, yRadius: 0.64).fill()
    }

    // B. 展开与合拢中的屏幕盖板（置于底座后方绘制；静态开盖保留苹果官方 0.30 半透明屏幕填充）
    if lidVisible && lidOpacity > 0.01 {
        g.saveGState()
        g.setAlpha(lidOpacity)
        let lidPath = buildTrapezoidPath(
            cx: mbCX,
            botY: lidBotY,
            topY: lidTopY,
            botHalfW: lidBotHalfW,
            topHalfW: lidTopHalfW,
            rBot: 0,
            rTop: lidTopR
        )
        lidPath.lineJoinStyle = .round
        lidPath.lineCapStyle = .round

        let lidFillAlpha = lerp(0.30, 1.0, smooth(seg(fold, 0.35, 0.92)))
        ink(lidFillAlpha)
        lidPath.fill()

        ink(1)
        lidPath.lineWidth = lidStrokeW
        lidPath.stroke()

        let visibleBot = max(lidBotY, chassisTopY - 0.15)
        let lidH = lidTopY - visibleBot
        if notchScaleY > 0.05 && lidH > 2.8 {
            let nw: CGFloat = 4.30
            let nh = 1.32 * notchScaleY
            let notchTop = lidTopY - 0.15
            let notchRect = NSRect(x: mbCX - nw * 0.5, y: notchTop - nh, width: nw, height: nh)
            ink(notchScaleY)
            NSBezierPath(roundedRect: notchRect, xRadius: 0.45, yRadius: 0.45).fill()
        }
        g.restoreGState()
    }

    // C. 主机身轮廓（胶囊圆头平直底座 -> 收腰塑形 -> 均衡饱满 Mac Studio 外框）
    let chLeft = mbCX - chassisHalfW
    let chW = chassisHalfW * 2
    let chH = max(0.3, chassisTopY - chassisBotY)

    let rt = min(chassisTopR, chH * 0.495, chW * 0.45)
    let rb = min(chassisBotR, chH * 0.495, chW * 0.45)
    let chassisPath = NSBezierPath()
    chassisPath.move(to: NSPoint(x: chLeft + rb, y: chassisBotY))
    chassisPath.line(to: NSPoint(x: chLeft + chW - rb, y: chassisBotY))
    chassisPath.curve(to: NSPoint(x: chLeft + chW, y: chassisBotY + rb), controlPoint1: NSPoint(x: chLeft + chW, y: chassisBotY), controlPoint2: NSPoint(x: chLeft + chW, y: chassisBotY))
    chassisPath.line(to: NSPoint(x: chLeft + chW, y: chassisTopY - rt))
    chassisPath.curve(to: NSPoint(x: chLeft + chW - rt, y: chassisTopY), controlPoint1: NSPoint(x: chLeft + chW, y: chassisTopY), controlPoint2: NSPoint(x: chLeft + chW, y: chassisTopY))
    chassisPath.line(to: NSPoint(x: chLeft + rt, y: chassisTopY))
    chassisPath.curve(to: NSPoint(x: chLeft, y: chassisTopY - rt), controlPoint1: NSPoint(x: chLeft, y: chassisTopY), controlPoint2: NSPoint(x: chLeft, y: chassisTopY))
    chassisPath.line(to: NSPoint(x: chLeft, y: chassisBotY + rb))
    chassisPath.curve(to: NSPoint(x: chLeft + rb, y: chassisBotY), controlPoint1: NSPoint(x: chLeft, y: chassisBotY), controlPoint2: NSPoint(x: chLeft, y: chassisBotY))
    chassisPath.close()
    chassisPath.lineJoinStyle = .round
    chassisPath.lineCapStyle = .round

    let fillAlpha = lerp(1.0, 0.04, symbolBaseToOutline)
    let strokeW = lerp(0.28, 1.36, symbolBaseToOutline)
    ink(fillAlpha)
    chassisPath.fill()
    ink(1)
    chassisPath.lineWidth = strokeW
    chassisPath.stroke()

    // D. Mac Studio 前面板：2 个竖向 USB-C + 1 个横向 SDXC + 右侧状态灯
    let portCY = chassisBotY + 3.65

    func drawPort(cx: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat, prog: CGFloat) {
        guard prog > 0.01 else { return }
        let curH = max(0.18, h * prog)
        let curW = w * (0.65 + 0.35 * prog)
        let curR = min(r * prog, curW * 0.5, curH * 0.5)
        let rect = NSRect(x: cx - curW * 0.5, y: portCY - curH * 0.5, width: curW, height: curH)
        ink(prog)
        NSBezierPath(roundedRect: rect, xRadius: curR, yRadius: curR).fill()
    }

    drawPort(cx: 6.05, w: 1.12, h: 2.90, r: 0.56, prog: tb1)
    drawPort(cx: 8.25, w: 1.12, h: 2.90, r: 0.56, prog: tb2)
    drawPort(cx: 12.45, w: 4.10, h: 1.04, r: 0.52, prog: sdxc)

    if ledAppear > 0.01 {
        let on = clamp01(p.led)
        let r = lerp(0.80, 1.10, on) * ledAppear
        let ledAlpha = ledAppear * lerp(0.45, 1.0, on)
        ink(ledAlpha)
        NSBezierPath(ovalIn: NSRect(x: ledC.x - r, y: portCY - r, width: 2 * r, height: 2 * r)).fill()
    }

    drawLapLED(p)
    drawHalo(p, center: p.lid > 0.9 ? NSPoint(x: 20.0, y: 6.1) : NSPoint(x: ledC.x, y: portCY))
}

func drawScene(_ p: Pose) {
    let g = NSGraphicsContext.current!.cgContext
    g.saveGState(); g.setAlpha(p.alpha); g.translateBy(x: 0, y: p.dy)
    drawVectorMorph(p)
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

// MARK: - 动画编排（Kind）

enum Kind {
    // close/open：模式启用/关闭时的形变；led：模式不变、就绪状态变化。
    case close(Bool, Bool), open(Bool, Bool), led(Bool, Bool), refresh(Look), launch(Look)
    static let on = Kind.close(false, true), off = Kind.open(true, false)
    var frames: Int {
        switch self {
        case .close, .open: return 22
        case .launch(let look): return look.lit ? 22 : 16
        case .refresh, .led: return 17
        }
    }
    var duration: Double { Double(frames) / fps }
    func pose(_ t: CGFloat) -> Pose {
        switch self {
        case .close(let from, let to):
            var p = Pose()
            p.progress = clamp01(t)
            p.lapLed = from ? 1 - smooth(seg(t, 0, 0.10)) : 0
            p.lid = 1 - easeLidDrop(seg(t, 0.02, 0.33))
            p.mw = easeAppleSymmetric(seg(t, 0.28, 0.66))
            p.mh = easeAppleSettle(seg(t, 0.30, 0.73))
            if to {
                p.led = easePortPop(seg(t, 0.74, 0.94))
                let k = seg(t, 0.75, 1.0)
                if k > 0 { p.halo = (lerp(1.0, 3.9, ease(k)), 0.80 * (1 - k) * min(1, k * 8)) }
            }
            return p
        case .open(let from, let to):
            let rt = clamp01(1 - t)
            var p = Pose()
            p.progress = rt
            p.lid = 1 - easeLidDrop(seg(rt, 0.02, 0.33))
            p.mw = easeAppleSymmetric(seg(rt, 0.28, 0.66))
            p.mh = easeAppleSettle(seg(rt, 0.30, 0.73))
            if from {
                p.led = 1 - ease(seg(t, 0.02, 0.22))
                let hk = seg(t, 0.0, 0.22)
                if hk > 0 { p.halo = (lerp(3.3, 1.0, ease(hk)), 0.55 * sin(.pi * hk)) }
            }
            if to {
                let k = seg(t, 0.80, 1.0)
                p.lapLed = easePortPop(k)
                if k > 0 { p.halo = (lerp(1.0, 3.7, ease(k)), 0.75 * (1 - k) * min(1, k * 8)) }
            }
            return p
        case .led(let closed, let on):
            var p = Pose.still(Look(lidClosed: closed, lit: false))
            let v = on ? spring(seg(t, 0.05, 0.6)) : 1 - ease(seg(t, 0.05, 0.5))
            if closed { p.led = v } else { p.lapLed = v }
            if on { let k = seg(t, 0.15, 0.9); p.halo = (lerp(1.0, 3.6, ease(k)), 0.75 * (1 - k) * min(1, k * 8)) }
            else { let k = seg(t, 0.0, 0.5); p.halo = (lerp(2.8, 1.0, ease(k)), 0.45 * sin(.pi * k)) }
            return p
        case .refresh(let look):
            var p = Pose.still(look)
            if look.lit {
                let v = 1 - 0.5 * sin(.pi * seg(t, 0.15, 0.55))
                if look.lidClosed { p.led = v } else { p.lapLed = v }
            }
            if look.lit || look.lidClosed {
                let k = seg(t, 0.30, 0.90)
                p.halo = (lerp(1.0, 3.6, ease(k)), (look.lit ? 0.75 : 0.42) * (1 - k) * min(1, k * 8))
            } else {
                p.lid = 1 - 0.10 * sin(.pi * seg(t, 0.05, 0.80))
            }
            return p
        case .launch(let look):
            var p = Pose.still(look)
            let u = look.lit ? t : t * 0.72
            p.dy = lerp(-12, 0, spring(seg(u, 0.0, 0.55))); p.alpha = smooth(seg(u, 0, 0.25))
            if look.lit {
                let v = spring(seg(t, 0.62, 0.95))
                if look.lidClosed { p.led = v } else { p.lapLed = v }
                let k = seg(t, 0.62, 0.95)
                p.halo = (lerp(1.0, 3.6, ease(k)), 0.80 * (1 - k) * min(1, k * 8))
            }
            return p
        }
    }
}

final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let status = NSStatusBar.system.statusItem(withLength: statusBarLength)   // 动画包规格：固定 35pt
    // 始终使用随包附带、只保留合盖功能的 Reminal 精简版（不再用全局 ~/.local/bin/reminal）。
    let reminal = Bundle.main.resourcePath! + "/reminal/reminal"
    var service: Process?               // 精简版 `reminal service`：防睡眠 / 保持解锁 / 内屏调暗与虚拟显示器
    var serviceInput: Pipe?             // 生命线：关闭即让服务恢复亮度、释放防睡眠后退出
    var serviceUp = false
    var busy = false
    var checking = false
    #if SELFTEST
    var testCommand: ((String, [String]) -> (Int32, String))!
    var renderedCloseFrames = 0, renderedOpenFrames = 0, renderedHaloFrames = 0
    #endif
    let worker = DispatchQueue(label: "local.reminal.clamshellassistant.commands", qos: .utility)
    var generation = 0
    var refreshPending = false
    var recoveryReads = 3
    var lastError: String?
    var current: ModeState?
    var settingsWatch: DispatchSourceFileSystemObject?
    var powerWatch: DispatchSourceFileSystemObject?
    // The user's last on/off choice, restored whenever something else changes a part.
    #if SELFTEST
    // Per-process suite: a previous build that exited without cleaning up can otherwise leak
    // SmartMode into the next test run. Each run gets a fresh, empty domain of its own, so a
    // leftover from any run (or the real app's own domain) can never be read here.
    static let selftestSuite = "local.reminal.clamshellassistant.selftest-\(getpid())"
    let defaults = UserDefaults(suiteName: Controller.selftestSuite)!
    #else
    let defaults = UserDefaults.standard
    #endif
    let intentKey = "ModeIntent"
    var intent: Bool? {
        get { defaults.object(forKey: intentKey) as? Bool }
        set { if let v = newValue { defaults.set(v, forKey: intentKey) } else { defaults.removeObject(forKey: intentKey) } }
    }
    var note: String?                    // why the last restore failed, shown next to the named parts
    var autoFixes: [Date] = []           // automatic restores in the last two minutes
    var refreshWork: DispatchWorkItem?
    var observers: [NSObjectProtocol] = []
    var shown: Look?
    var pingPending = false
    var link: CADisplayLink?            // 仅动画期间存在
    var overlay: NSView?                // 仅动画期间存在：盖在状态栏按钮上的图层，逐帧换 contents
    var maskLayer: CALayer?
    var ctx: CGContext?                 // 复用的绘制缓冲，结束即释放
    var started = 0.0, ticks = 0
    var pending: (Kind, Double, NSImage, (() -> Void)?)?
    var images: [Look: NSImage] = [:]
    func image(_ look: Look) -> NSImage {
        if let i = images[look] { return i }
        let i = bitmapImage(scales: [1, 2], .still(look))
        i.accessibilityDescription = look.lidClosed ? "合盖运行已就绪" : "正常模式"
        images[look] = i; return i
    }
    let menu = NSMenu()
    lazy var header = item("", nil)
    lazy var toggle = item("开启合盖运行", #selector(toggleMode))
    lazy var refreshItem = item("刷新状态", #selector(refreshMenu))
    lazy var quit = item("退出助手", #selector(quitApp), "q")

    // MARK: V2.1 — lease, crash guard, fully automatic AI smart mode. Event-driven only: agents
    // report through a Unix socket (only while smart mode is on). Battery and thermal pressure are
    // display-only: read once each time the submenu opens, never watched, never part of a decision.
    // The only timer is `policyTimer`: one-shot, armed only while a deadline is pending, with
    // tolerance so macOS can coalesce the wake-up.
    // The one native submenu, rebuilt when it is about to open (menuNeedsUpdate) and, while it is
    // open, when an agent event arrives.
    let advancedMenu = NSMenu()
    lazy var advancedItem: NSMenuItem = {
        let i = NSMenuItem(title: "高级选项", action: nil, keyEquivalent: "")
        i.submenu = self.advancedMenu
        return i
    }()
    var advancedOpen = false
    var tracker = AgentTracker()
    var clock: () -> Date = { Date() }                                          // injectable for the self-tests
    var batteryReader: () -> BatteryReading? = { readBattery() }                 // display only
    var thermalReader: () -> ThermalLevel = { ThermalLevel(ProcessInfo.processInfo.thermalState) }   // display only
    var lidReader: () -> Bool? = { lidIsClosed() }
    var idleReader: () -> Double? = { userIdleSeconds() }
    var agentListener: AgentListener?
    var policyTimer: DispatchSourceTimer?
    var suppressed = false          // the user switched AI keep-awake off: no automatic re-enable until this batch ends
    var wasAutoAwake = false        // AI smart mode was the reason keep-awake was on at the last evaluation
    var sleepCheckPending = false   // AI just released keep-awake: sleep now if the lid is closed and nobody is there
    var lastWant: Bool?             // a new target gets a fresh automatic-restore budget
    var guardProcess: Process?, guardInput: Pipe?
    #if SELFTEST
    var guardRunning = false
    var sudoRuleInstalled = true
    let leaseStore = LeaseStore(path: NSTemporaryDirectory() + "clamshell-selftest-lease-\(getpid()).json")
    #else
    let leaseStore = LeaseStore()
    #endif
    var helperPath = Bundle.main.bundlePath + "/Contents/MacOS/clamshell-helper"   // the self-tests point this at a stub
    var hookHome = NSHomeDirectory()                                                // the self-tests point this at a temp dir
    #if SELFTEST
    var codexSystemPath = NSTemporaryDirectory() + "clamshell-selftest-etc-codex-\(getpid())/hooks.json"
    #else
    var codexSystemPath = CodexSystemHooks.path                                  // written by the installer (one admin prompt)
    #endif
    /// AI smart mode: off unless the user turns it on.
    var smartMode: Bool {
        get { defaults.bool(forKey: "SmartMode") }
        set { defaults.set(newValue, forKey: "SmartMode") }
    }
    var autoStopHours: Int {
        get { autoStopChoices.contains(defaults.integer(forKey: "AutoStopHours")) ? defaults.integer(forKey: "AutoStopHours") : 0 }
        set { defaults.set(newValue, forKey: "AutoStopHours") }
    }
    var autoStopAt: Date? {
        get { defaults.object(forKey: "AutoStopAt") as? Date }
        set { if let v = newValue { defaults.set(v, forKey: "AutoStopAt") } else { defaults.removeObject(forKey: "AutoStopAt") } }
    }
    /// The single power decision (see decidePower in Policy.swift): manual on > AI smart mode > saved choice.
    var decision: Decision {
        let n = clock()
        return decidePower(intent: intent, smart: smartMode, agentsAwake: tracker.keepsAwake(now: n),
                           idleSince: tracker.idleSince, suppressed: suppressed, now: n, config: tracker.config)
    }

    func item(_ title: String, _ action: Selector?, _ key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if action == nil { i.isEnabled = false } else { i.target = self }
        return i
    }

    // 固定菜单宽度（用户要求：宽度不随状态变化，并且和以前一样窄）。主菜单的宽度由 1.4.1 原有的几项短文字
    // 决定；子菜单由第一行电池/热压力状态决定（和以前一样）。启动时各量一次原生宽度设为 minimumWidth，
    // 之后所有状态行都限制在同一宽度内：放不下就截断成“…”，全文放进 toolTip，所以宽度永远不变。
    let menuTextFont = NSFont.menuFont(ofSize: 0)
    static let mainSamples = ["正在读取状态…", "状态暂不可用", "正常模式", "合盖运行中", "AI 合盖运行中", "AI 智能模式待命", "AI 已暂停",
                              "开启合盖运行", "关闭合盖运行", "刷新状态", "高级选项", "退出助手"]
    static let advancedSamples = ["电池 100% · 散热正常", "电池未知 · 散热危急", "Antigravity：9 个后台", "Codex：9 个进行中", "AWS Quick：9 个进行中", "Gemini：9 个待确认",
                                  "AI 智能模式", "定时停止", "开机启动", "移除免密授权…"]
    lazy var mainTextBudget: CGFloat = widestText(Controller.mainSamples)
    lazy var advancedTextBudget: CGFloat = widestText(Controller.advancedSamples)
    /// 启动时只做一次：按固定项量出两个菜单的原生宽度并锁定。
    func lockMenuWidths() {
        menu.minimumWidth = 0
        let shownHeader = header.title, shownTip = header.toolTip
        header.title = Controller.mainSamples.max { textWidth($0) < textWidth($1) } ?? shownHeader
        menu.minimumWidth = ceil(menu.size.width)
        header.title = shownHeader; header.toolTip = shownTip
        advancedMenu.minimumWidth = 0
        advancedMenu.removeAllItems()
        let widest = Controller.advancedSamples.max { textWidth($0) < textWidth($1) } ?? ""
        advancedMenu.addItem(item(widest, nil)); advancedMenu.addItem(.separator())
        let smart = item("AI 智能模式", #selector(toggleSmart)); smart.state = .on; advancedMenu.addItem(smart)
        let stops = NSMenuItem(title: "定时停止", action: nil, keyEquivalent: ""); stops.submenu = NSMenu(); advancedMenu.addItem(stops)
        advancedMenu.addItem(item("开机启动", #selector(toggleLoginItem)))
        advancedMenu.minimumWidth = ceil(advancedMenu.size.width)
        advancedMenu.removeAllItems()                                      // rebuilt for real when it opens
    }
    func textWidth(_ s: String) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: menuTextFont]).width) }
    func widestText(_ list: [String]) -> CGFloat { list.map { textWidth($0) }.max() ?? 0 }
    /// 菜单里显示的文字：放得下就原样显示，否则截断并加“…”。
    func fitted(_ s: String, _ budget: CGFloat) -> String {
        guard textWidth(s) > budget else { return s }
        var chars = Array(s)
        while !chars.isEmpty && textWidth(String(chars) + "…") > budget { chars.removeLast() }
        return String(chars) + "…"
    }
    func setHeader(_ s: String, tip: String? = nil) {
        header.title = fitted(s, mainTextBudget)
        header.toolTip = tip ?? s
    }
    /// 子菜单里的只读状态行：宽度受限，被截断时全文在 toolTip。
    func infoItem(_ s: String) -> NSMenuItem {
        let i = item(fitted(s, advancedTextBudget), nil)
        i.toolTip = i.title == s ? nil : s
        return i
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        status.button?.imagePosition = .imageOnly
        menu.delegate = self
        menu.autoenablesItems = false
        advancedMenu.delegate = self
        advancedMenu.autoenablesItems = false
        signal(SIGPIPE, SIG_IGN)   // a vanished guard must surface as a write error, never kill the app
        toggle.isEnabled = false
        // Leftover preference from a removed feature; never applied again.
        UserDefaults.standard.removeObject(forKey: "ExternalDisplayWhenLidClosed")
        status.button?.image = image(Look(lidClosed: false, lit: false))
        setHeader("正在读取状态…")
        // 1.4.1 layout unchanged; V2 adds exactly one submenu item and one separator above「退出助手」.
        [header, .separator(), toggle, refreshItem, .separator(), advancedItem, .separator(), quit].forEach { menu.addItem($0) }
        lockMenuWidths()                                                   // 只在启动时定一次，之后不再变化
        status.menu = menu
        #if SELFTEST
        runSelfTests(self)
        #elseif DUMP
        dumpFrames(); NSApp.terminate(nil)
        #elseif BENCH
        status.button?.image = image(Look(lidClosed: false, lit: false))
        benchmark(remaining: Int(ProcessInfo.processInfo.environment["BENCH_N"] ?? "12")!, target: true)
        #else
        startV2()
        observeChanges()
        refresh()
        #endif
    }
    func applicationWillTerminate(_ notification: Notification) {
        stopPlayback(); settingsWatch?.cancel(); powerWatch?.cancel(); syncService(false)
        #if !SELFTEST
        policyTimer?.cancel(); policyTimer = nil
        agentListener?.stop()
        // V2: a normal quit releases what this app holds. The saved choice is kept, so the next
        // launch restores the mode exactly as 1.4.1 did.
        releaseOwnedSleep()
        if !leaseStore.exists { releaseGuard() }   // otherwise the guard retries once we are gone
        #endif
    }
    #if BENCH
    func benchmark(remaining: Int, target: Bool) {
        guard remaining > 0 else { NSApp.terminate(nil); return }
        play(target ? .on : .off, final: image(Look(lidClosed: target, lit: !target))) { [weak self] in self?.benchmark(remaining: remaining - 1, target: !target) }
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
        let kinds: [(String, Kind)] = [("on", .on), ("off", .off), ("close-lit", .close(true, true)), ("open-lit", .open(true, true)), ("led-open", .led(false, true)), ("led-closed", .led(true, true)),
                                       ("refresh-off", .refresh(Look(lidClosed: false, lit: false))), ("refresh-on", .refresh(Look(lidClosed: true, lit: true))), ("launch-off", .launch(Look(lidClosed: false, lit: false))), ("launch-on", .launch(Look(lidClosed: true, lit: true)))]
        for (name, kind) in kinds { for i in 0..<kind.frames { save(kind.pose(CGFloat(i) / CGFloat(kind.frames - 1)), String(format: "\(name)-%02d", i)) } }
        for i in 0..<20 { save(Kind.on.pose(0.03 + 0.0165 * CGFloat(i)), String(format: "lid-%02d", i)) }
        for c in [false, true] { for l in [false, true] { save(.still(Look(lidClosed: c, lit: l)), "static-\(c ? "closed" : "open")-\(l ? "lit" : "dark")") } }
    }
    #endif
    func run(_ path: String, _ args: [String]) -> (Int32, String) {
        #if SELFTEST
        return testCommand(path, args)
        #else
        return runCommand(path, args, timeout: path == "/usr/bin/osascript" ? 120 : 20)
        #endif
    }
    var presentation: ModePresentation? {
        let d = decision
        return current.map { ModePresentation(state: $0, serviceUp: serviceUp, intent: d.want, note: note, hold: d.hold, auto: d.auto ? autoSummary() : nil) }
    }
    var ready: Bool { lastError == nil && presentation?.isReady == true }
    func syncService(_ want: Bool) {
        #if SELFTEST
        serviceUp = want
        #else
        if want, service == nil {
            let p = Process(), input = Pipe()
            p.executableURL = URL(fileURLWithPath: reminal); p.arguments = ["service"]
            p.standardInput = input; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            p.terminationHandler = { [weak self] ended in
                DispatchQueue.main.async {
                    guard let self = self, self.service === ended else { return }
                    self.service = nil; self.serviceInput = nil; self.serviceUp = false; self.updateMenu()
                }
            }
            do { try p.run(); service = p; serviceInput = input; serviceUp = true } catch { serviceUp = false }
        } else if !want, let running = service {
            try? serviceInput?.fileHandleForWriting.close(); serviceInput = nil
            let deadline = Date().addingTimeInterval(1)
            while running.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if running.isRunning { running.terminate() }
            service = nil; serviceUp = false
        }
        #endif
    }
    func state() -> Result<ModeState, Error> {
        Result { try readState(reminal: reminal, run: run) }
    }
    func observeChanges() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self = self else { return }
                // A display link may have been suspended with a blank button underneath it.
                self.settleAnimation()
                self.scheduleRefresh()
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.settleAnimation(); self?.scheduleRefresh()
        })
        watchSettings()
        watchPower()
    }
    // `pmset -a disablesleep` (ours or another program's) rewrites this file.
    func watchPower() {
        powerWatch?.cancel(); powerWatch = nil
        let fd = open("/Library/Preferences/com.apple.PowerManagement.plist", O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .rename, .delete], queue: .main)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self, weak source] in
            guard let self = self else { return }
            if let data = source?.data, !data.isDisjoint(with: [.rename, .delete]) {
                // Atomic replace: re-arm on the new file.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.watchPower() }
            }
            self.scheduleRefresh()
        }
        powerWatch = source; source.resume()
    }
    func watchSettings() {
        settingsWatch?.cancel(); settingsWatch = nil
        // Watch the directory (shared with a full Reminal install) so an atomic
        // rewrite or a file that appears later still triggers a refresh.
        let fd = open(NSHomeDirectory() + "/.reminal", O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete], queue: .main)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in self?.scheduleRefresh() }
        settingsWatch = source; source.resume()
    }
    func scheduleRefresh() {
        recoveryReads = 3
        enqueueRefresh(after: 0.3)
    }
    func enqueueRefresh(after delay: Double) {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    func settleAnimation() {
        let final = pending?.2
        stopPlayback()
        if let final = final { status.button?.image = final }
    }
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
        let t = (max(CACurrentMediaTime(), link.targetTimestamp) - started) / duration
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
            let pose = kind.pose(CGFloat(max(0, t)))
            drawScene(pose)
            #if SELFTEST
            if case .close = kind { renderedCloseFrames += 1 }
            if case .open = kind { renderedOpenFrames += 1 }
            if pose.halo.1 > 0 { renderedHaloFrames += 1 }
            #endif
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
        guard !busy, !checking else { refreshPending = true; return }
        checking = true; refreshPending = false
        let revision = generation
        worker.async {
            let result = self.state()
            DispatchQueue.main.async {
                self.checking = false
                // A pre-toggle read must never overwrite the post-toggle state.
                if revision == self.generation && !self.busy { self.accept(result) }
                if self.refreshPending && !self.busy { self.refresh() }
            }
        }
    }
    func accept(_ result: Result<ModeState, Error>) {
        switch result {
        case .success(let value):
            current = value; lastError = nil; syncService(value.closed || value.unlocked)
            if value.matches(decision.want ?? (value.closed && value.unlocked)) { note = nil }
            reconcileIfNeeded()
            sleepIfDone()
        case .failure(let error): lastError = error.localizedDescription
        }
        syncGuard()
        updateMenu()
        // A bounded recovery burst after a failed read (login/wake), never an idle polling timer.
        if lastError != nil {
            if recoveryReads > 0 { recoveryReads -= 1; enqueueRefresh(after: 1) }
        } else { recoveryReads = 0 }
    }
    func updateIcon(_ snapshot: ModePresentation? = nil) {
        guard current != nil || lastError != nil else { return }
        // 外形表示 closed-lid 模式，不把物理盖子或全部就绪条件当作变形前提。
        // 读取失败时外形和灯均保留上次结果，菜单明确报错。
        let target = lastError == nil
            ? ((snapshot ?? presentation)?.look ?? Look(lidClosed: false, lit: false))
            : (shown ?? Look(lidClosed: false, lit: false))
        guard let from = shown else { play(.launch(target), final: image(target)); shown = target; pingPending = false; return }
        if from == target {
            if pingPending && link == nil { play(.refresh(target), final: image(target)) }
            pingPending = false; return
        }
        // Finish the current single-device morph, then play the latest target.
        if link != nil { pending?.3 = { [weak self] in self?.updateIcon() }; return }
        let kind: Kind = from.lidClosed != target.lidClosed
            ? (target.lidClosed ? .close(from.lit, target.lit) : .open(from.lit, target.lit))
            : .led(target.lidClosed, target.lit)
        play(kind, final: image(target)); shown = target; pingPending = false
    }
    func updateMenu() {
        let snapshot = presentation
        let actionable = !busy && snapshot != nil && lastError == nil
        toggle.isEnabled = actionable
        if let snapshot = snapshot { toggle.title = snapshot.toggleTitle }
        refreshItem.isEnabled = !busy
        updateIcon(snapshot)
        if let error = lastError {
            setHeader("状态暂不可用", tip: error)
            status.button?.toolTip = "合盖助手：" + error
            return
        }
        if busy { return }
        guard let snapshot = snapshot else { return }
        // 菜单里只写短状态；AI 运行时的任务数/睡眠时间放在 toolTip，详细任务在「高级选项」里。
        let full = snapshot.auto.flatMap { $0.isEmpty ? nil : snapshot.header + " · " + $0 } ?? snapshot.header
        setHeader(snapshot.header, tip: full)
        status.button?.toolTip = "合盖助手：" + full
    }
    func menuWillOpen(_ menu: NSMenu) { if menu === self.menu { refresh() } else if menu === advancedMenu { advancedOpen = true } }
    func menuDidClose(_ menu: NSMenu) { if menu === advancedMenu { advancedOpen = false } }
    func menuNeedsUpdate(_ menu: NSMenu) { if menu === advancedMenu { rebuildAdvancedMenu() } }
    @objc func refreshMenu() {
        // An explicit refresh adopts the shown choice (if none was saved yet) and retries a failed restore.
        // What AI smart mode turned on is not a manual choice and is never adopted as one.
        if intent == nil, !decision.auto, let shownChoice = presentation?.wantsOn { intent = shownChoice }
        autoFixes = []; note = nil
        pingPending = !busy && !checking; refresh()
    }
    // Bring every part back to the saved choice. Never prompts; at most 3 tries per 2 minutes.
    // V2: the target is the unified decision, so AI smart mode switches keep-awake on and off here.
    func reconcileIfNeeded() {
        guard let want = decision.want, let state = current, !state.matches(want), !busy, lastError == nil else { return }
        let now = Date()
        autoFixes = autoFixes.filter { now.timeIntervalSince($0) < 120 }
        guard autoFixes.count < 3 else { if note == nil { note = "被其他程序反复改回" }; return }
        autoFixes.append(now)
        setMode(want, interactive: false)
    }
    @objc func quitApp() { NSApp.terminate(nil) }

    // MARK: - V2 lifecycle

    func startV2() {
        AppPaths.ensureSupportDir()
        defaults.removeObject(forKey: "SafetyLatch")      // 2.0.0's battery/thermal pause no longer exists
        if !defaults.bool(forKey: "Migrated210") {
            defaults.set(true, forKey: "Migrated210")
            // 2.0.0 needed the manual switch on for smart mode. In 2.1 AI smart mode decides on its
            // own, and a leftover manual "on" would keep the Mac awake for good.
            if smartMode && intent == true { intent = false }
        }
        recoverLeaseAtLaunch()
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
            self?.policyChanged()      // the clock jumped during sleep: re-evaluate every deadline
        })
        if smartMode {
            startAgentListener()
            // Keep-awake was held when the app last ended: running agents get one buffer to report again.
            if leaseStore.exists { tracker.beginGrace(now: clock()) }
            ensureHooks()
        }
        wasAutoAwake = decision.want == true && decision.auto
        scheduleDeadline()
    }

    /// Launch-time recovery: a lease left by an instance that ended without releasing is adopted.
    /// Whether SleepDisabled then stays on is decided by the normal decision/reconcile path —
    /// kept when the saved choice is on and nothing blocks it, turned off otherwise. A lease held
    /// by a live instance is never touched; nothing is changed when no lease exists.
    func recoverLeaseAtLaunch() {
        let stored = leaseStore.read()
        if stored == nil && leaseStore.exists { leaseStore.remove(); return }   // unreadable leftovers carry no ownership
        switch judgeLease(stored, ownerStart: { processStartTime($0) }, currentBoot: bootSessionUUID()) {
        case .none, .liveOwner: return
        case .stale:
            leaseStore.write(LeaseStore.forSelf())
            EventLog.write("launch: adopted a keep-awake lease left by an instance that did not release it")
        }
    }

    /// Turns SleepDisabled back off on quit, but only while this app holds the lease.
    func releaseOwnedSleep() {
        guard leaseStore.exists else { return }
        let live = run("/usr/bin/pmset", ["-g", "live"])
        guard live.0 == 0, let disabled = parseSleepDisabled(live.1) else { return }
        if !disabled { leaseStore.remove(); return }
        if run("/usr/bin/sudo", pmsetOff).0 == 0 { leaseStore.remove(); EventLog.write("quit: SleepDisabled restored to 0") }
    }

    /// Keeps the lease and the crash guard in step with what was just read.
    func syncGuard() {
        // Upgrade from 1.4.1 (no leases yet): the saved choice is on and sleep is disabled,
        // so this app is the one keeping it disabled — take ownership.
        if decision.want == true, current?.power == true, !busy, !leaseStore.exists { leaseStore.write(LeaseStore.forSelf()) }
        #if SELFTEST
        guardRunning = leaseStore.exists
        #else
        if leaseStore.exists, guardProcess == nil {
            let p = Process(), input = Pipe()
            p.executableURL = URL(fileURLWithPath: helperPath); p.arguments = ["guard", String(getpid())]
            p.standardInput = input; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            p.terminationHandler = { [weak self] ended in
                DispatchQueue.main.async { if self?.guardProcess === ended { self?.guardProcess = nil; self?.guardInput = nil } }
            }
            do { try p.run(); guardProcess = p; guardInput = input }
            catch { EventLog.write("guard: could not start (\(error.localizedDescription)); recovery falls back to next launch") }
        } else if !leaseStore.exists, guardProcess != nil {
            releaseGuard()
        }
        #endif
    }

    func releaseGuard() {
        #if SELFTEST
        guardRunning = false
        #else
        if let h = guardInput?.fileHandleForWriting {
            try? h.write(contentsOf: Data("release\n".utf8))
            try? h.close()
        }
        guardInput = nil; guardProcess = nil
        #endif
    }

    // MARK: - V2 agents

    func startAgentListener() {
        startStateMonitors()
        #if !SELFTEST
        guard agentListener == nil else { return }
        let l = AgentListener(path: AppPaths.socket, helperPath: helperPath) { [weak self] e in self?.agentEvent(e) }
        if l.start() { agentListener = l } else { EventLog.write("agents: socket unavailable") }
        #endif
    }
    func stopAgentListener() { agentListener?.stop(); agentListener = nil; stopStateMonitors() }

    // MARK: - Agents without hooks (Codex's own state, AWS Quick's desktop log)

    var quickMonitor: QuickLogMonitor?
    var codexMonitor: CodexStateMonitor?
    var codexLocalIDs: Set<String> = []          // turns Codex's database says are running
    var codexKeyboardIDs: Set<String> = []       // turns Codex Keyboard shows as working (local and remote)

    func startStateMonitors() {
        #if !SELFTEST
        if quickMonitor == nil {
            let q = QuickLogMonitor { [weak self] activity in self?.quickActivity(activity) }
            q.start(); quickMonitor = q
        }
        if codexMonitor == nil {
            let c = CodexStateMonitor(home: hookHome) { [weak self] l, k in self?.codexSnapshot(local: l, keyboard: k) }
            c.start(); codexMonitor = c
        }
        #endif
    }
    func stopStateMonitors() {
        quickMonitor?.stop(); quickMonitor = nil
        codexMonitor?.stop(); codexMonitor = nil
        codexLocalIDs = []; codexKeyboardIDs = []
    }

    func quickActivity(_ activity: QuickLogActivity) {
        agentEvent(AgentEvent(kind: .quick, session: hashSession(activity.session), phase: activity.phase, sentAt: (clock().timeIntervalSince1970 * 1000).rounded()))
    }

    /// nil = that source cannot be read right now: keep what it said last.
    func codexSnapshot(local: Set<String>?, keyboard: Set<String>?) {
        guard smartMode else { return }
        let before = codexLocalIDs.union(codexKeyboardIDs)
        if let l = local { codexLocalIDs = l }
        if let k = keyboard { codexKeyboardIDs = k }
        let after = codexLocalIDs.union(codexKeyboardIDs)
        let n = clock()
        let events = codexStateEvents(before: before, after: after, sentAt: (n.timeIntervalSince1970 * 1000).rounded())
        for e in events { tracker.apply(e, now: n) }
        if !events.isEmpty { policyChanged() }
    }

    func agentEvent(_ e: AgentEvent) {
        guard smartMode else { return }
        tracker.apply(e, now: clock())
        policyChanged()
    }

    /// AI smart mode is on: every detected agent reports to us. Invisible to the user — it reuses
    /// the add-only, backed-up, never-overwrite edit, and rewrites a file only when our entries are
    /// missing or point at another copy of the helper. Agents that are not installed, or whose
    /// config is not plain JSON, are left alone. Hooks stay when smart mode is switched off (the
    /// helper then finds no socket and exits at once); rollback.sh removes them.
    func ensureHooks() {
        var codexConnected = false
        for target in HookTarget.all(home: hookHome) {
            // Codex already has this app's hooks at system level (trusted by policy, no review needed):
            // the user-level copy would only make Codex run every hook twice, so ours is taken out of it.
            if target.kind == .codex, CodexSystemHooks.isActive(helper: helperPath, path: codexSystemPath) {
                if target.status() == .installed, case .success = target.uninstall() { EventLog.write("hook moved to system level: codex") }
                continue
            }
            switch target.status() {
            case .agentMissing, .unreadable: continue
            case .installed where target.isCurrent(helper: helperPath): break
            case .installed, .notInstalled:
                switch target.install(helper: helperPath) {
                case .success: EventLog.write("hook installed: " + target.kind.rawValue)
                case .failure: continue
                }
            }
            if target.kind == .codex { codexConnected = true }
        }
        // Codex runs a new hook only after the user trusts it once (its own safety rule; never bypassed).
        if codexConnected && !defaults.bool(forKey: "CodexTrustNotice") {
            defaults.set(true, forKey: "CodexTrustNotice")
            notify("合盖助手已连接 Codex（ChatGPT）",
                   "请在 ChatGPT / Codex 的「设置 › Hooks」中信任一次合盖助手的 Hook（命令行里输入 /hooks）。只需这一次。")
        }
    }

    func notify(_ title: String, _ body: String) {
        #if !SELFTEST
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            if granted {
                let content = UNMutableNotificationContent()
                content.title = title; content.body = body
                center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            } else {
                DispatchQueue.main.async { self.inform(title, body) }
            }
        }
        #endif
    }

    // MARK: - V2 decision plumbing

    /// Re-evaluates after any input. Cheap: no I/O unless the decision differs from the state.
    func policyChanged() {
        let n = clock()
        if let at = autoStopAt, n >= at {
            autoStopAt = nil
            if intent == true { intent = false; autoFixes = []; note = nil; EventLog.write("timed stop") }
        }
        tracker.prune(now: n)
        // A batch the user switched off is over once no task is left; its buffer is skipped too.
        if suppressed && !tracker.keepsAwake(now: n) { suppressed = false; tracker.clearIdle() }
        let d = decision
        if d.want != lastWant { lastWant = d.want; autoFixes = []; note = nil }
        if d.want == true { sleepCheckPending = false }
        else if wasAutoAwake && d.hold == .smartIdle { sleepCheckPending = true }
        wasAutoAwake = d.want == true && d.auto
        reconcileIfNeeded()
        sleepIfDone()
        updateMenu()
        if advancedOpen { rebuildAdvancedMenu() }
        scheduleDeadline()
    }

    /// AI smart mode has just released keep-awake after the last task. With the lid closed and
    /// nobody at the Mac, put it to sleep now. Both are read once, here; nothing is polled.
    func sleepIfDone() {
        guard sleepCheckPending, !busy, lastError == nil, let s = current, s.matches(false) else { return }
        sleepCheckPending = false
        guard lidReader() == true, (idleReader() ?? 0) >= 60 else { return }
        EventLog.write("smart: all agent tasks finished with the lid closed; sleeping now")
        worker.async { _ = self.run("/usr/bin/pmset", ["sleepnow"]) }
    }

    /// Arms at most one one-shot timer for the earliest pending deadline, with tolerance so the
    /// system can coalesce the wake-up. With nothing pending there is no timer.
    func scheduleDeadline() {
        let n = clock()
        var marks: [Date] = []
        if intent == true, let d = autoStopAt { marks.append(d) }
        if smartMode {
            if let d = tracker.nextDeadline(now: n) { marks.append(d) }
            if !tracker.keepsAwake(now: n), let d = smartDeadline(idleSince: tracker.idleSince, config: tracker.config), d > n { marks.append(d) }
        }
        policyTimer?.cancel(); policyTimer = nil
        guard let next = marks.min() else { return }
        let delay = max(0, next.timeIntervalSince(n))
        let leeway = min(30, max(1, delay * 0.05))
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + delay + 0.05, repeating: .never, leeway: .milliseconds(Int(leeway * 1000)))
        t.setEventHandler { [weak self] in self?.deadlineFired() }
        policyTimer = t
        t.resume()
    }

    func deadlineFired() {
        policyTimer?.cancel(); policyTimer = nil
        policyChanged()
    }

    // MARK: - V2 advanced submenu (native items, rebuilt when it opens or, while open, on an agent event)

    func rebuildAdvancedMenu() {
        let m = advancedMenu
        m.removeAllItems()
        m.addItem(infoItem(powerStatusLine(battery: batteryReader(), thermal: thermalReader())))
        m.addItem(.separator())
        let smart = item("AI 智能模式", #selector(toggleSmart))
        smart.state = smartMode ? .on : .off
        m.addItem(smart)
        for line in smartStatusLines() { m.addItem(infoItem(line)) }
        m.addItem(.separator())
        let stops = NSMenu(); stops.autoenablesItems = false
        for h in autoStopChoices {
            let i = item(h == 0 ? "关闭" : "\(h) 小时", #selector(setAutoStop(_:)))
            i.tag = h; i.state = autoStopHours == h ? .on : .off
            stops.addItem(i)
        }
        let stopItem = NSMenuItem(title: "定时停止", action: nil, keyEquivalent: "")
        stopItem.submenu = stops
        m.addItem(stopItem)
        let login = item("开机启动", #selector(toggleLoginItem))
        #if SELFTEST
        login.state = .off                      // never query the real login-item database from tests
        #else
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        #endif
        m.addItem(login)
        if FileManager.default.fileExists(atPath: sudoersPath) {
            m.addItem(item("移除免密授权…", #selector(removeSudoersRule)))
        }
    }

    /// The background-task lines under「AI 智能模式」: one per agent with something going on.
    func smartStatusLines() -> [String] {
        guard smartMode else { return [] }
        let n = clock()
        var lines = agentTaskLines(tracker.countsByKind(now: n))
        if lines.isEmpty {
            if !suppressed, intent != true, let d = smartDeadline(idleSince: tracker.idleSince, config: tracker.config), d > n {
                lines.append("约 " + hhmm(d) + " 睡眠")
            } else {
                lines.append("无任务")
            }
        }
        if suppressed { lines.append("已暂停") }
        if intent == true { lines.append("手动常开") }
        return lines
    }

    /// Short summary for the main header while AI smart mode keeps the Mac awake.
    func autoSummary() -> String {
        let n = clock(), c = tracker.counts(now: n)
        if c.active + c.unknown > 0 { return "\(c.active + c.unknown) 个任务" }
        if let d = smartDeadline(idleSince: tracker.idleSince, config: tracker.config), d > n { return "约 " + hhmm(d) + " 睡眠" }
        return ""
    }

    func hhmm(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) }

    @objc func toggleSmart() {
        if smartMode {
            smartMode = false; suppressed = false
            stopAgentListener(); tracker.reset()
            EventLog.write("smart mode off")
            policyChanged()
            return
        }
        ensureSudoRule { [weak self] ok in
            guard let self = self, ok else { return }
            self.smartMode = true; self.suppressed = false
            self.startAgentListener()
            self.ensureHooks()
            EventLog.write("smart mode on")
            self.policyChanged()
        }
    }

    /// AI smart mode switches keep-awake on and off in the background, which needs the same minimal
    /// passwordless rule 1.4.1 installs on the first manual toggle. Ask for it once, now, while the
    /// user is clicking — never later from the background.
    func ensureSudoRule(_ done: @escaping (Bool) -> Void) {
        #if SELFTEST
        done(sudoRuleInstalled)
        #else
        if FileManager.default.fileExists(atPath: sudoersPath) { done(true); return }
        worker.async {
            let r = self.run("/usr/bin/osascript", ["-e", self.sudoRuleScript()])
            DispatchQueue.main.async {
                let canceled = r.1.contains("User canceled") || r.1.contains("用户取消")
                if r.0 != 0 && !canceled { self.inform("AI 智能模式未开启", "需要一次管理员授权，才能在后台自动阻止和恢复睡眠。") }
                done(r.0 == 0)
            }
        }
        #endif
    }

    @objc func setAutoStop(_ sender: NSMenuItem) {
        autoStopHours = sender.tag
        autoStopAt = (sender.tag > 0 && intent == true) ? clock().addingTimeInterval(Double(sender.tag) * 3600) : nil
        policyChanged()
    }

    @objc func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            inform("登录项设置未完成", error.localizedDescription)
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    var sudoersPath: String { "/private/etc/sudoers.d/reminal-clamshell-\(getuid())" }

    /// The one-time authorization (unchanged from 1.4.1): installs a rule limited to the two pmset commands.
    func sudoRuleScript() -> String {
        let path = sudoersPath
        let user = NSUserName()
        let command = "umask 077; t=\(path).tmp; printf '%s\\n' '\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1' > \"$t\" && chmod 0440 \"$t\" && /usr/sbin/visudo -cf \"$t\" >/dev/null && mv -f \"$t\" \(path)"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges with prompt \"合盖助手需要一次管理员授权，以后切换时无需重复输入密码。\""
    }

    /// Revokes the passwordless rule — only when the file still holds exactly the rule this
    /// app wrote. Afterwards the next toggle asks for the password again.
    @objc func removeSudoersRule() {
        let rule = "\(NSUserName()) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        let command = "f=\(sudoersPath); [ -f \"$f\" ] && [ \"$(cat \"$f\")\" = '\(rule)' ] && rm -f \"$f\""
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges with prompt \"移除合盖助手的免密规则后，下次切换需要重新输入密码。\""
        worker.async {
            let r = self.run("/usr/bin/osascript", ["-e", script])
            DispatchQueue.main.async {
                if r.0 == 0 { EventLog.write("sudoers rule removed by the user") }
                else if !(r.1.contains("User canceled") || r.1.contains("用户取消")) { self.inform("免密规则未移除", "规则文件已被修改或不属于本应用。") }
            }
        }
    }

    func inform(_ title: String, _ text: String) {
        #if !SELFTEST
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        a.runModal()
        #endif
    }
    @objc func toggleMode() {
        guard !busy, let snapshot = presentation, lastError == nil else { return }
        if snapshot.toggleEnables {
            suppressed = false
            autoStopAt = autoStopHours > 0 ? clock().addingTimeInterval(Double(autoStopHours) * 3600) : nil
        } else {
            autoStopAt = nil
            // Switched off while AI smart mode keeps the Mac awake: no automatic re-enable until this
            // batch of tasks is over; if only the buffer was left, it ends now.
            if smartMode {
                if tracker.keepsAwake(now: clock()) { suppressed = true } else { tracker.clearIdle() }
                wasAutoAwake = false; sleepCheckPending = false
            }
        }
        let previous = intent
        intent = snapshot.toggleEnables; autoFixes = []; note = nil
        lastWant = snapshot.toggleEnables
        setMode(snapshot.toggleEnables, previous: previous)
        scheduleDeadline()
    }
    func setMode(_ enable: Bool, interactive: Bool = true, previous: Bool? = nil) {
        guard !busy, let before = current, lastError == nil else { return }
        generation += 1
        busy = true; updateMenu()
        worker.async {
            var note: String? = nil, canceled = false, detail = ""
            if before.power != enable {
                let value = enable ? "1" : "0"
                // V2 ownership: the lease is written BEFORE sleep is disabled, so a crash at any
                // later point is recoverable by the guard or the next launch.
                if enable { self.leaseStore.write(LeaseStore.forSelf()) }
                var auth = self.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", value])
                if auth.0 != 0 && interactive {
                    // The first authorization installs a rule limited to these two pmset commands.
                    auth = self.run("/usr/bin/osascript", ["-e", self.sudoRuleScript()])
                    canceled = auth.1.contains("User canceled") || auth.1.contains("用户取消")
                    if auth.0 == 0 { auth = self.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", value]) }
                }
                if auth.0 != 0 { note = interactive ? "无法更改系统睡眠设置" : "需要管理员授权，请点开关重试"; detail = auth.1 }
                // Sleep is ours only while we set it to 1; a successful 0 (or a failed 1) ends the lease.
                if auth.0 == 0 && !enable { self.leaseStore.remove() }
                if auth.0 != 0 && enable { self.leaseStore.remove() }
            }
            if !canceled {
                // Only rewrite what differs, so a restore never touches parts that are already right.
                let mode = enable ? "on" : "off"
                if before.closed != enable, self.run(self.reminal, ["settings", "closed-lid", mode]).0 != 0 { note = note ?? "Reminal 设置未能保存" }
                if before.unlocked != enable, self.run(self.reminal, ["settings", "always-unlocked", mode]).0 != 0 { note = note ?? "Reminal 设置未能保存" }
            }
            // powerd applies pmset asynchronously: re-read briefly before calling it a failure.
            var result = self.state()
            for _ in 0..<8 {
                if canceled { break }
                if case .success(let actual) = result, actual.matches(enable) { break }
                Thread.sleep(forTimeInterval: 0.25); result = self.state()
            }
            DispatchQueue.main.async {
                self.busy = false
                if canceled { self.intent = previous }
                var failed = false
                if case .success(let actual) = result { failed = !canceled && !actual.matches(enable) } else { failed = true }
                self.note = failed ? note : nil
                // A failure that needs the user (authorization, a broken install) is not retried automatically.
                if failed && note != nil { self.autoFixes = Array(repeating: Date(), count: 3) }
                self.accept(result)
                if self.refreshPending { self.refresh() }
                if failed && interactive && !canceled {
                    let a = NSAlert(); a.messageText = "切换未完成"
                    a.informativeText = (self.presentation?.header ?? self.lastError ?? "状态读取失败") + (detail.isEmpty ? "" : "\n" + detail)
                    a.runModal()
                }
            }
        }
    }
}
// Installer / rollback helper: prints the Codex system-level hook file and exits. Never writes /etc itself.
//   --codex-system-hooks <helper> [path]       exit 0 = new content on stdout, 3 = already up to date, 4 = not plain JSON
//   --codex-system-hooks-remove - [path]       exit 0 = content without ours,  3 = nothing of ours,   5 = delete the file
let cliArgs = CommandLine.arguments
if cliArgs.count >= 3, cliArgs[1] == "--codex-system-hooks" || cliArgs[1] == "--codex-system-hooks-remove" {
    let path = cliArgs.count >= 4 ? cliArgs[3] : CodexSystemHooks.path
    switch CodexSystemHooks.plan(install: cliArgs[1] == "--codex-system-hooks", helper: cliArgs[2], path: path) {
    case .upToDate: exit(3)
    case .unreadable: exit(4)
    case .remove: exit(5)
    case .write(let data): FileHandle.standardOutput.write(data); exit(0)
    }
}
let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
