import AppKit

// 生成原生矢量构造的 App Icon；脚本参数 1 为输出 PNG 绝对路径；副作用仅写入该文件。
let destination = CommandLine.arguments[1]
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
NSGradient(colors: [NSColor(red: 0.025, green: 0.19, blue: 0.23, alpha: 1), NSColor(red: 0.025, green: 0.62, blue: 0.64, alpha: 1)])!.draw(in: NSBezierPath(rect: NSRect(origin: .zero, size: size)), angle: 55)
// 错位的三张卡片代表任务、财务与助手；以简单几何保持小尺寸可辨认性。
for offset in stride(from: 2, through: 0, by: -1) {
    let d = CGFloat(offset)
    let rectangle = NSRect(x: 258 + d * 42, y: 220 + d * 61, width: 440, height: 470)
    let path = NSBezierPath(roundedRect: rectangle, xRadius: 90, yRadius: 90)
    NSColor.white.withAlphaComponent(offset == 0 ? 0.92 : 0.16).setFill()
    path.fill()
    NSColor.white.withAlphaComponent(0.4).setStroke(); path.lineWidth = 3; path.stroke()
}
let check = NSBezierPath()
check.move(to: NSPoint(x: 361, y: 442)); check.line(to: NSPoint(x: 443, y: 363)); check.line(to: NSPoint(x: 595, y: 536))
check.lineWidth = 48; check.lineCapStyle = .round; check.lineJoinStyle = .round
NSColor(red: 0.02, green: 0.49, blue: 0.51, alpha: 1).setStroke(); check.stroke()
image.unlockFocus()
// 输出不含 Alpha 通道的 1024px RGB PNG，满足应用商店图标格式要求。
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
image.draw(in: NSRect(origin: .zero, size: size))
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
