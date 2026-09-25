// 生成 App 图标：深色圆角底 + 三道圆环（Claude 橙 / Codex 青绿 / Cursor 蓝）
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let bg = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(bg)
ctx.setFillColor(NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1).cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bg); ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
    NSColor(srgbRed: 0.20, green: 0.20, blue: 0.22, alpha: 1).cgColor,
    NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size - inset), end: CGPoint(x: 0, y: inset), options: [])
ctx.restoreGState()

let center = CGPoint(x: size / 2, y: size / 2)
let rings: [(UInt32, CGFloat, CGFloat)] = [(0xEB6834, 300, 0.78), (0x1BAF7A, 222, 0.55), (0x2A78D6, 144, 0.9)]
for (hex, r, frac) in rings {
    let c = NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    ctx.setLineWidth(56); ctx.setLineCap(.round)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
    ctx.addArc(center: center, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false); ctx.strokePath()
    ctx.setStrokeColor(c.cgColor)
    let start = CGFloat.pi / 2
    ctx.addArc(center: center, radius: r, startAngle: start, endAngle: start - frac * 2 * .pi, clockwise: true)
    ctx.strokePath()
}
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
