import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let store = StockStore()

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
        let content = store.menuBarContent()
        button.attributedTitle = content.title
        button.image = content.image
        button.imagePosition = (content.image != nil && content.title.length == 0)
            ? .imageOnly : .imageLeft
    }
}
