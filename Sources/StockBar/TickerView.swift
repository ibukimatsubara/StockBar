import AppKit

@MainActor
final class TickerView: NSView {
    /// 流れる速度（px/sec）。
    var pixelsPerSecond: CGFloat = 90
    /// 帯の終わりと次の先頭の間の余白（px）。
    var gapPixels: CGFloat = 40

    private(set) var attributedString: NSAttributedString = NSAttributedString()
    private var stringSize: NSSize = .zero
    /// 文字列を一度だけラスタライズしたビットマップ。
    private var cachedImage: NSImage?
    private var pixelOffset: CGFloat = 0
    private var animTimer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var isPausedForSleep = false

    deinit {
        if let o = sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        if let o = wakeObserver  { NSWorkspace.shared.notificationCenter.removeObserver(o) }
    }

    func setAttributedString(_ s: NSAttributedString) {
        // 文字列幅が変わると trackWidth が変わり、pixelOffset の剰余が飛んで
        // 見た目の位置がジャンプする。更新前の trackWidth で正規化しておくと
        // 1 周目の描画位置 (-offset) が更新前後で連続する。
        if stringSize.width > 0 {
            let oldTrackWidth = stringSize.width + gapPixels
            pixelOffset = pixelOffset.truncatingRemainder(dividingBy: oldTrackWidth)
            if pixelOffset < 0 { pixelOffset += oldTrackWidth }
        }
        attributedString = s
        stringSize = s.size()
        cachedImage = renderToImage(s, size: stringSize)
        needsDisplay = true
    }

    private func renderToImage(_ s: NSAttributedString, size: NSSize) -> NSImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let img = NSImage(size: size)
        img.lockFocus()
        s.draw(at: .zero)
        img.unlockFocus()
        return img
    }

    override var isFlipped: Bool { false }
    /// クリックは下のステータスバーボタンに透過させる。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard stringSize.width > 0, let img = cachedImage else { return }
        let trackWidth = stringSize.width + gapPixels
        let offset = pixelOffset.truncatingRemainder(dividingBy: trackWidth)
        let y = (bounds.height - stringSize.height) / 2
        // デバイスピクセルにスナップしないとプリレンダ画像が補間されてボヤける。
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let snap: (CGFloat) -> CGFloat = { (round($0 * scale) / scale) }
        let ctx = NSGraphicsContext.current
        let prevInterp = ctx?.imageInterpolation
        ctx?.imageInterpolation = .none
        img.draw(at: NSPoint(x: snap(-offset), y: snap(y)),
                 from: .zero, operation: .sourceOver, fraction: 1.0)
        img.draw(at: NSPoint(x: snap(-offset + trackWidth), y: snap(y)),
                 from: .zero, operation: .sourceOver, fraction: 1.0)
        if let p = prevInterp { ctx?.imageInterpolation = p }
    }

    func startAnimation() {
        if animTimer != nil { return }
        installSleepObserversIfNeeded()
        // 60FPS → 30FPS で CPU 半減。menu bar の体感は変わらない。
        let interval: TimeInterval = 1.0 / 30.0
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isPausedForSleep else { return }
                self.pixelOffset += self.pixelsPerSecond * CGFloat(interval)
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(t, forMode: .common)
        animTimer = t
    }

    func stopAnimation() {
        animTimer?.invalidate()
        animTimer = nil
    }

    private func installSleepObserversIfNeeded() {
        let nc = NSWorkspace.shared.notificationCenter
        if sleepObserver == nil {
            sleepObserver = nc.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                           object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isPausedForSleep = true }
            }
        }
        if wakeObserver == nil {
            wakeObserver = nc.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                          object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isPausedForSleep = false }
            }
        }
    }
}
