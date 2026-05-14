import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let store = StockStore()
    private let tickerView = TickerView()
    private static let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static var monoCellWidth: CGFloat {
        ("0" as NSString).size(withAttributes: [.font: monoFont]).width
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        statusItem.button?.title = "StockBar"

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 520, height: 620)
        popover.contentViewController = NSHostingController(
            rootView: ContentView().environmentObject(store)
        )

        store.onUpdate = { [weak self] in
            self?.refreshTitle()
        }
        store.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        UserDefaults.standard.synchronize()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            store.refreshOnOpen()
            // ボタン右端を基準にする。バー幅が変わってもステータスバー上の右端は動かないので位置が安定する。
            let anchor = NSRect(x: button.bounds.maxX - 1, y: 0, width: 1, height: button.bounds.height)
            popover.show(relativeTo: anchor, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func refreshTitle() {
        guard let button = statusItem.button else { return }
        if store.displayMode == .ticker && !store.focusMode && !store.visibleStocks.isEmpty {
            applyTickerMode(button: button)
        } else {
            applyRotationMode(button: button)
        }
    }

    private func applyRotationMode(button: NSStatusBarButton) {
        tickerView.stopAnimation()
        tickerView.removeFromSuperview()
        statusItem.length = NSStatusItem.variableLength
        let content = store.menuBarContent()
        button.attributedTitle = content.title
        button.image = content.image
        button.imagePosition = (content.image != nil && content.title.length == 0)
            ? .imageOnly : .imageLeft
    }

    private func applyTickerMode(button: NSStatusBarButton) {
        button.attributedTitle = NSAttributedString()
        button.title = ""
        button.image = nil

        let chW = Self.monoCellWidth
        let width = CGFloat(store.tickerWidth) * chW + 8
        statusItem.length = width
        let frame = NSRect(x: 0, y: 0, width: width, height: button.bounds.height)
        tickerView.frame = frame
        if tickerView.superview !== button {
            button.addSubview(tickerView)
        }
        tickerView.pixelsPerSecond = chW / max(store.tickerStepInterval, 0.001)
        tickerView.gapPixels = max(CGFloat(store.tickerWidth) * chW / 2, 40)
        tickerView.setAttributedString(store.tickerStrip())
        tickerView.startAnimation()
    }
}
