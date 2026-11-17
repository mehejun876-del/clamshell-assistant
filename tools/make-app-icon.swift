import AppKit

// Render the same SF Symbol used by the menu-bar Studio pose into a standard
// multi-resolution macOS app icon: monochrome chassis on a rounded square.
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns")
let work = FileManager.default.temporaryDirectory.appendingPathComponent("clamshell-appicon-\(UUID().uuidString)")
let iconset = work.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func squircle(_ size: CGFloat) -> NSBezierPath {
    // Continuous-ish rounded square inset to the macOS icon safe area.
    let inset = size * 0.08
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let r = rect.width * 0.223
    return NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
}

func render(_ pixel: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixel, pixelsHigh: pixel, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixel, height: pixel)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixel)
    NSColor(white: 0.91, alpha: 1).setFill()
    squircle(s).fill()
    // The menu-bar Studio glyph is wider than it is tall (front view).
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.52, weight: .regular)
    let symbol = NSImage(systemSymbolName: "macstudio", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    let aspect = symbol.size.width / max(symbol.size.height, 1)
    let width = s * 0.62
    let height = width / aspect
    let rect = NSRect(x: (s - width) / 2, y: (s - height) / 2, width: width, height: height)
    symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let names: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
for (name, px) in names {
    let png = render(px).representation(using: .png, properties: [:])!
    try png.write(to: iconset.appendingPathComponent(name))
}
// Also emit a preview next to the icns for visual checks.
if let preview = render(256).representation(using: .png, properties: [:]) {
    try preview.write(to: output.deletingLastPathComponent().appendingPathComponent("AppIcon-preview.png"))
}
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", "-o", output.path, iconset.path]
try proc.run(); proc.waitUntilExit()
guard proc.terminationStatus == 0 else { fputs("iconutil failed\n", stderr); exit(1) }
try? FileManager.default.removeItem(at: work)
print("wrote \(output.path)")
