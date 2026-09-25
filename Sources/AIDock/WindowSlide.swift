import AppKit
import QuartzCore

/// 三次贝塞尔缓动曲线（和 CSS cubic-bezier 一样），控制点 y 可以大于 1 做出回弹
struct CubicBezier {
    let x1, y1, x2, y2: Double

    static let easeIn = CubicBezier(x1: 0.42, y1: 0, x2: 1, y2: 1)

    private static func point(_ s: Double, _ a: Double, _ b: Double) -> Double {
        let u = 1 - s
        return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s
    }

    private static func slope(_ s: Double, _ a: Double, _ b: Double) -> Double {
        let u = 1 - s
        return 3 * u * u * a + 6 * u * s * (b - a) + 3 * s * s * (1 - b)
    }

    /// 时间进度 t（0…1）对应的动画进度
    func value(_ t: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        // 先用牛顿法求曲线参数，收敛不了再二分
        var s = t
        for _ in 0..<8 {
            let dx = Self.point(s, x1, x2) - t
            if abs(dx) < 1e-5 { return Self.point(s, y1, y2) }
            let d = Self.slope(s, x1, x2)
            if abs(d) < 1e-6 { break }
            s -= dx / d
        }
        var lo = 0.0, hi = 1.0
        s = t
        for _ in 0..<30 {
            let x = Self.point(s, x1, x2)
            if abs(x - t) < 1e-5 { break }
            if x < t { lo = s } else { hi = s }
            s = (lo + hi) / 2
        }
        return Self.point(s, y1, y2)
    }
}

/// 窗口位移动画。macOS 27 上 `window.animator().setFrameOrigin` 完全不移动窗口，
/// 所以跟着屏幕刷新逐帧移动。只在动画期间运行，结束立刻停掉，空闲时不占资源。
@MainActor
final class WindowSlide: NSObject {
    private weak var window: NSWindow?
    private var link: CADisplayLink?
    private var from = NSPoint.zero
    private var to = NSPoint.zero
    private var start: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0
    private var curve = CubicBezier.easeIn
    private var completion: (() -> Void)?

    init(_ window: NSWindow) {
        self.window = window
    }

    /// 从窗口当前位置移到 target；新的移动会接管正在进行的动画（旧动画的完成回调不再执行）
    func move(to target: NSPoint, duration: CFTimeInterval, curve: CubicBezier, completion: (() -> Void)? = nil) {
        guard let window else { return }
        cancel()
        from = window.frame.origin
        to = target
        self.duration = duration
        self.curve = curve
        self.completion = completion
        guard from != to, duration > 0, let screen = NSScreen.screens.first else {
            window.setFrameOrigin(target)
            finish()
            return
        }
        start = CACurrentMediaTime()
        let l = screen.displayLink(target: self, selector: #selector(step(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    /// 停在当前位置，不执行完成回调
    func cancel() {
        link?.invalidate()
        link = nil
        completion = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let window else { cancel(); return }
        let t = (CACurrentMediaTime() - start) / duration
        if t >= 1 {
            window.setFrameOrigin(to)
            finish()
            return
        }
        let p = curve.value(t)
        window.setFrameOrigin(NSPoint(x: from.x + (to.x - from.x) * p, y: from.y + (to.y - from.y) * p))
    }

    private func finish() {
        link?.invalidate()
        link = nil
        let done = completion
        completion = nil
        done?()
    }
}
