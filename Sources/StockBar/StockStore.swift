import Foundation
import AppKit
import Combine

@MainActor
final class StockStore: ObservableObject {
    @Published var stocks: [Stock] = []
    @Published var rotationInterval: TimeInterval = 5
    @Published var updateInterval: TimeInterval = 60
    @Published var focusMode: Bool = false
    @Published private(set) var currentIndex: Int = 0
    @Published private(set) var lastError: String?

    var onUpdate: (() -> Void)?

    private var rotationTimer: Timer?
    private var updateTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private let stocksKey = "StockBar.stocks.v1"
    private let prefsKey = "StockBar.prefs.v1"

    init() {
        load()

        $rotationInterval
            .dropFirst()
            .sink { [weak self] _ in
                self?.startRotationTimer()
                self?.savePrefs()
            }
            .store(in: &cancellables)

        $updateInterval
            .dropFirst()
            .sink { [weak self] _ in
                self?.startUpdateTimer()
                self?.savePrefs()
            }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    func start() {
        Task { await refreshAll() }
        startRotationTimer()
        startUpdateTimer()
        onUpdate?()
    }

    private func startRotationTimer() {
        rotationTimer?.invalidate()
        rotationTimer = Timer.scheduledTimer(withTimeInterval: rotationInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceRotation() }
        }
    }

    private func startUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            Task { await self?.refreshAll() }
        }
    }

    private func advanceRotation() {
        let vis = visibleStocks
        guard !vis.isEmpty else { onUpdate?(); return }
        currentIndex = (currentIndex + 1) % vis.count
        onUpdate?()
    }

    // MARK: - Derived

    var visibleStocks: [Stock] {
        stocks.filter { $0.visible }
    }

    // MARK: - CRUD

    func add(symbol raw: String) {
        let s = Self.normalizeSymbol(raw)
        guard !s.isEmpty, !stocks.contains(where: { $0.symbol == s }) else { return }
        stocks.append(Stock(symbol: s))
        save()
        onUpdate?()
        Task { await refreshOne(symbol: s) }
    }

    /// 入力を Yahoo Finance のシンボル形式に正規化する。
    /// 4桁数字のみ（例: "7203"）は東証扱いとして ".T" を補う。
    static func normalizeSymbol(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).uppercased()
        if trimmed.range(of: "^[0-9]{4}$", options: .regularExpression) != nil {
            return "\(trimmed).T"
        }
        return trimmed
    }

    func remove(_ stock: Stock) {
        stocks.removeAll { $0.id == stock.id }
        if currentIndex >= max(visibleStocks.count, 1) { currentIndex = 0 }
        save()
        onUpdate?()
    }

    func toggleVisible(_ stock: Stock) {
        guard let i = stocks.firstIndex(where: { $0.id == stock.id }) else { return }
        stocks[i].visible.toggle()
        if currentIndex >= max(visibleStocks.count, 1) { currentIndex = 0 }
        save()
        onUpdate?()
    }

    func move(from: IndexSet, to: Int) {
        stocks.move(fromOffsets: from, toOffset: to)
        save()
        onUpdate?()
    }

    func toggleFocus() {
        focusMode.toggle()
        onUpdate?()
    }

    // MARK: - Fetch

    func refreshAll() async {
        for stock in stocks {
            await refreshOne(symbol: stock.symbol)
        }
        onUpdate?()
    }

    func refreshOne(symbol: String) async {
        guard !isMarketGloballyClosedForAll() || quoteAge(symbol: symbol) > 60 * 60 else {
            return
        }
        do {
            let q = try await YahooFinance.fetch(symbol: symbol)
            if let idx = stocks.firstIndex(where: { $0.symbol == symbol }) {
                stocks[idx].quote = q
            }
            lastError = nil
            onUpdate?()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func quoteAge(symbol: String) -> TimeInterval {
        // unused: placeholder for future incremental update logic
        return .infinity
    }

    /// 雑な判定：日本市場 or 米国市場のどちらかが開いていれば true。
    private func isMarketGloballyClosedForAll() -> Bool {
        let now = Date()
        var jp = Calendar(identifier: .gregorian)
        jp.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var us = Calendar(identifier: .gregorian)
        us.timeZone = TimeZone(identifier: "America/New_York")!

        func isOpen(_ cal: Calendar, openH: Int, openM: Int, closeH: Int, closeM: Int) -> Bool {
            let comps = cal.dateComponents([.weekday, .hour, .minute], from: now)
            guard let wd = comps.weekday, wd >= 2 && wd <= 6 else { return false }
            let h = comps.hour ?? 0, m = comps.minute ?? 0
            let cur = h * 60 + m
            return cur >= openH * 60 + openM && cur <= closeH * 60 + closeM
        }
        let jpOpen = isOpen(jp, openH: 9, openM: 0, closeH: 15, closeM: 0)
        let usOpen = isOpen(us, openH: 9, openM: 30, closeH: 16, closeM: 0)
        return !(jpOpen || usOpen)
    }

    // MARK: - Menu bar title

    func menuBarAttributedTitle() -> NSAttributedString {
        let font = NSFont.menuBarFont(ofSize: 0)

        if focusMode {
            return NSAttributedString(string: "📊", attributes: [.font: font])
        }
        let vis = visibleStocks
        guard !vis.isEmpty else {
            return NSAttributedString(string: "📊 StockBar", attributes: [.font: font])
        }
        let stock = vis[currentIndex % vis.count]
        let name = stock.displayName
        guard let q = stock.quote else {
            return NSAttributedString(
                string: "\(name) …",
                attributes: [.font: font, .foregroundColor: NSColor.labelColor]
            )
        }

        let priceStr = Self.formatPrice(q.price)
        let changeStr = String(format: "%+.2f (%+.2f%%)", q.change, q.changePercent)
        let color: NSColor = q.change >= 0 ? .systemRed : .systemGreen

        let result = NSMutableAttributedString()
        result.append(NSAttributedString(
            string: "\(name) \(priceStr) ",
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]
        ))
        result.append(NSAttributedString(
            string: changeStr,
            attributes: [.font: font, .foregroundColor: color]
        ))
        return result
    }

    static func formatPrice(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = (v >= 1000) ? 0 : 2
        f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(stocks) {
            UserDefaults.standard.set(data, forKey: stocksKey)
        }
        savePrefs()
    }

    private func savePrefs() {
        let prefs: [String: Any] = [
            "rotationInterval": rotationInterval,
            "updateInterval": updateInterval
        ]
        UserDefaults.standard.set(prefs, forKey: prefsKey)
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: stocksKey),
           let arr = try? JSONDecoder().decode([Stock].self, from: data) {
            stocks = arr
        } else {
            stocks = [
                Stock(symbol: "ACWI",     nickname: "ACWI"),
                Stock(symbol: "^N225",    nickname: "NI225"),
                Stock(symbol: "^IXIC",    nickname: "NASDAQ"),
                Stock(symbol: "GC=F",     nickname: "GOLD"),
                Stock(symbol: "USDJPY=X", nickname: "USD/JPY"),
                Stock(symbol: "BTC-USD",  nickname: "BTC/USD")
            ]
        }
        if let prefs = UserDefaults.standard.dictionary(forKey: prefsKey) {
            if let r = prefs["rotationInterval"] as? TimeInterval { rotationInterval = r }
            if let u = prefs["updateInterval"] as? TimeInterval { updateInterval = u }
        }
    }
}
