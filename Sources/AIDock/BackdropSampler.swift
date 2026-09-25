import AppKit
import ImageIO

/// 判断透明 Dock 背后是亮还是暗，决定文字、指示灯用深色还是浅色（不需要屏幕录制权限）：
/// 有窗口压在 Dock 下面时按系统外观推断（浅色模式的窗口一般是亮的）；否则看壁纸在 Dock 那一条的亮度。
@MainActor
enum BackdropSampler {
    /// 壁纸缩成 64px 宽的灰度图，只在换壁纸时重新计算
    private static var cache: (url: URL, luma: [UInt8], w: Int, h: Int)?

    private static var systemDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// rect：Dock 条在屏幕上的区域（Cocoa 坐标）
    static func isLight(behind rect: NSRect, on screen: NSScreen) -> Bool {
        if windowCovers(rect, screen: screen) { return !systemDark }
        guard let l = wallpaperLuminance(rect, screen: screen) else { return !systemDark }
        return l > 0.55
    }

    private static func windowCovers(_ rect: NSRect, screen: NSScreen) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        // CG 坐标原点在主屏左上角
        let h = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let cgRect = CGRect(x: rect.minX, y: h - rect.maxY, width: rect.width, height: rect.height)
        let me = getpid()
        var covered: CGFloat = 0
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? pid_t) != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.5,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let bw = b["Width"], let bh = b["Height"] else { continue }
            let i = cgRect.intersection(CGRect(x: x, y: y, width: bw, height: bh))
            if !i.isNull { covered = max(covered, i.width * i.height) }
        }
        return covered > rect.width * rect.height * 0.3
    }

    /// 壁纸在 rect 这一块的平均亮度（0…1）；动态壁纸等读不到图片时返回 nil
    private static func wallpaperLuminance(_ rect: NSRect, screen: NSScreen) -> Double? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        if cache?.url != url {
            cache = nil
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 96,
                  ] as CFDictionary) else { return nil }
            let w = img.width, h = img.height
            var luma = [UInt8](repeating: 0, count: w * h)
            let ok = luma.withUnsafeMutableBytes { buf -> Bool in
                guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
                else { return false }
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { return nil }
            cache = (url, luma, w, h)
        }
        guard let c = cache else { return nil }
        // 壁纸默认「填充屏幕」：按比例放大铺满，居中裁切
        let sf = screen.frame
        let scale = max(sf.width / CGFloat(c.w), sf.height / CGFloat(c.h))
        let ox = (CGFloat(c.w) * scale - sf.width) / 2, oy = (CGFloat(c.h) * scale - sf.height) / 2
        // 屏幕坐标（左下原点）→ 图片像素（第 0 行在上）
        func px(_ x: CGFloat) -> Int { min(c.w - 1, max(0, Int((x - sf.minX + ox) / scale))) }
        func py(_ y: CGFloat) -> Int { min(c.h - 1, max(0, Int((sf.maxY - y + oy) / scale))) }
        let x0 = px(rect.minX), x1 = px(rect.maxX), y0 = py(rect.maxY), y1 = py(rect.minY)
        var sum = 0, n = 0
        for y in y0...max(y0, y1) {
            for x in x0...max(x0, x1) { sum += Int(c.luma[y * c.w + x]); n += 1 }
        }
        return n == 0 ? nil : Double(sum) / Double(n) / 255
    }
}
