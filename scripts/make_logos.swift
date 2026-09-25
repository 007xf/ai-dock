// 从本机已安装的官方 App 中提取三个品牌标志，处理成透明背景 PNG（输出到 Resources/Logos）
import AppKit

func bitmap(_ image: NSImage, size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: size * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// 裁掉透明边，居中放进正方形并留少量边距
func trimmed(_ rep: NSBitmapImageRep, out: Int, padding: Double = 0.04) -> NSBitmapImageRep {
    let w = rep.pixelsWide, h = rep.pixelsHigh, p = rep.bitmapData!
    var minX = w, minY = h, maxX = 0, maxY = 0
    for y in 0..<h { for x in 0..<w where p[(y * w + x) * 4 + 3] > 8 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
    let side = Double(max(maxX - minX, maxY - minY) + 1)
    let img = NSImage(size: NSSize(width: w, height: h)); img.addRepresentation(rep)
    let dst = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: out, pixelsHigh: out, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: out * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: dst)
    NSGraphicsContext.current?.imageInterpolation = .high
    let inner = Double(out) * (1 - 2 * padding)
    let scale = inner / side
    let cw = Double(maxX - minX + 1) * scale, ch = Double(maxY - minY + 1) * scale
    // NSBitmapImageRep 的行 0 在顶部，draw 的坐标原点在底部
    let src = NSRect(x: Double(minX), y: Double(h - 1 - maxY), width: Double(maxX - minX + 1), height: Double(maxY - minY + 1))
    img.draw(in: NSRect(x: (Double(out) - cw) / 2, y: (Double(out) - ch) / 2, width: cw, height: ch),
             from: src, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return dst
}

/// 去掉 App 图标的浅色底板：从边缘开始洪水填充低饱和度像素，彩色的标志本身会挡住填充
func removeBackplate(_ rep: NSBitmapImageRep) {
    let w = rep.pixelsWide, h = rep.pixelsHigh, p = rep.bitmapData!
    func chroma(_ i: Int) -> Int { let r = Int(p[i]), g = Int(p[i+1]), b = Int(p[i+2]); return max(r, g, b) - min(r, g, b) }
    func isBG(_ i: Int) -> Bool { p[i + 3] < 128 || chroma(i) < 38 }
    var seen = [Bool](repeating: false, count: w * h)
    var stack: [Int] = []
    for x in 0..<w { stack.append(x); stack.append((h - 1) * w + x) }
    for y in 0..<h { stack.append(y * w); stack.append(y * w + w - 1) }
    while let k = stack.popLast() {
        if seen[k] { continue }
        let i = k * 4
        guard isBG(i) else { continue }
        seen[k] = true
        p[i] = 0; p[i+1] = 0; p[i+2] = 0; p[i+3] = 0
        let x = k % w, y = k / w
        if x > 0 { stack.append(k - 1) }; if x < w - 1 { stack.append(k + 1) }
        if y > 0 { stack.append(k - w) }; if y < h - 1 { stack.append(k + w) }
    }
    // 边缘柔化：紧挨着被移除区域、偏白的过渡像素按饱和度降低不透明度
    for y in 1..<(h - 1) { for x in 1..<(w - 1) {
        let k = y * w + x, i = k * 4
        guard p[i + 3] > 0, seen[k - 1] || seen[k + 1] || seen[k - w] || seen[k + w] else { continue }
        let a = min(1.0, Double(chroma(i)) / 120.0)
        for c in 0..<4 { p[i + c] = UInt8(Double(p[i + c]) * a) } // 预乘 alpha
    } }
}

func save(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("saved", path)
}

let out = CommandLine.arguments[1]
// Claude：官方矢量星芒
if let svg = NSImage(contentsOfFile: "/Applications/Claude.app/Contents/Resources/ion-dist/assets/v1/cd02a42d9-Vq_H3mgS.svg") {
    save(trimmed(bitmap(svg, size: 1024), out: 256), out + "/claude.png")
} else { print("claude svg failed") }
// ChatGPT（与 Codex 合并）：ChatGPT App 资源包里的官方花结标志，浅色 / 深色两个版本
if let app = Bundle(path: "/Applications/ChatGPT.app") {
    for (name, file) in [("Icon_Assets/Blossom", "codex.png"), ("Icon_Assets/Blossom dark", "codex-dark.png")] {
        if let img = app.image(forResource: name) { save(trimmed(bitmap(img, size: 1024), out: 256, padding: 0.03), out + "/" + file) }
    }
}
// Gemini：Gemini App 图标里的彩色星芒，去掉白色底板
if let icon = NSImage(contentsOfFile: "/Applications/Gemini.app/Contents/Resources/AppIcon.icns") {
    let rep = bitmap(icon, size: 1024)
    removeBackplate(rep)
    save(trimmed(rep, out: 256, padding: 0.03), out + "/gemini.png")
}
// Cursor：官方透明立方体
if let cube = NSImage(contentsOfFile: "/Applications/Cursor.app/Contents/Resources/app/out/media/logo.png") {
    save(trimmed(bitmap(cube, size: 1000), out: 256), out + "/cursor.png")
}
