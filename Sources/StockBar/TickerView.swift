import AppKit

@MainActor
final class TickerView: NSView {
    /// 流れる速度（px/sec）。
    var pixelsPerSecond: CGFloat = 90
    /// 帯の終わりと次の先頭の間の余白（px）。
    var gapPixels: CGFloat = 40

    private(set) var attributedString: NSAttributedString = NSAttributedString()
    private var stringSize: NSSize = .zero
    private var pixelOffset: CGFloat = 0
    private var animTimer: Timer?

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
        needsDisplay = true
    }

    override var isFlipped: Bool { false }
    /// クリックは下のステータスバーボタンに透過させる。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard stringSize.width > 0 else { return }
        let trackWidth = stringSize.width + gapPixels
        let offset = pixelOffset.truncatingRemainder(dividingBy: trackWidth)
        let y = (bounds.height - stringSize.height) / 2
        attributedString.draw(at: NSPoint(x: -offset, y: y))
        // 2 周目を後ろに継ぎ足してシームレスにラップ
        attributedString.draw(at: NSPoint(x: -offset + trackWidth, y: y))
    }

    func startAnimation() {
        if animTimer != nil { return }
        let interval: TimeInterval = 1.0 / 60.0
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pixelOffset += self.pixelsPerSecond * CGFloat(interval)
            self.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        animTimer = t
    }

    func stopAnimation() {
        animTimer?.invalidate()
        animTimer = nil
    }
}
