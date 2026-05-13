import Foundation
import AppKit
import Combine

@MainActor
final class StockStore: ObservableObject {
    @Published var stocks: [Stock] = []
    @Published var rotationInterval: TimeInterval = 5
    @Published var simultaneousCount: Int = 1
    @Published var focusMode: Bool = false
    @Published private(set) var chunkIndex: Int = 0
    @Published private(set) var lastError: String?

    var onUpdate: (() -> Void)?

    private var rotationTimer: Timer?
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

        $simultaneousCount
            .dropFirst()
            .sink { [weak self] _ in
                self?.chunkIndex = 0
                self?.savePrefs()
                self?.onUpdate?()
            }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    func start() {
        Task {
            await refreshChunk(at: 0)
            onUpdate?()
            await prefetchNext()
        }
        startRotationTimer()
        onUpdate?()
    }

    private func startRotationTimer() {
        rotationTimer?.invalidate()
        rotationTimer = Timer.scheduledTimer(withTimeInterval: rotationInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// 既にフェッチ済みの次グループを即座に表示し、さらに次のグループをバックグラウンドで先読みする。
    private func tick() {
        let groups = chunks
        guard !groups.isEmpty else { onUpdate?(); return }
        chunkIndex = (chunkIndex + 1) % groups.count
        onUpdate?()
        Task { await prefetchNext() }
    }

    private func prefetchNext() async {
        let groups = chunks
        guard !groups.isEmpty else { return }
        let next = (chunkIndex + 1) % groups.count
        await refreshChunk(at: next)
    }

    private func refreshChunk(at index: Int) async {
        let groups = chunks
        guard groups.indices.contains(index) else { return }
        for s in groups[index] {
            await refreshOne(symbol: s.symbol)
        }
    }

    /// 表示中銘柄を simultaneousCount 個ずつ固定的にグループ化したもの。
    /// ラップアラウンドはせず、末尾が余ったらそのまま少ない数で表示する。
    var chunks: [[Stock]] {
        let vis = visibleStocks
        let size = max(simultaneousCount, 1)
        guard !vis.isEmpty else { return [] }
        return stride(from: 0, to: vis.count, by: size).map {
            Array(vis[$0..<min($0 + size, vis.count)])
        }
    }

    /// ポップオーバーを開いたときに呼ぶ：全銘柄を一括で再取得。
    func refreshOnOpen() {
        Task { await refreshAll() }
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
        chunkIndex = 0
        save()
        onUpdate?()
    }

    func toggleVisible(_ stock: Stock) {
        guard let i = stocks.firstIndex(where: { $0.id == stock.id }) else { return }
        stocks[i].visible.toggle()
        chunkIndex = 0
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

    struct MenuBarContent {
        let title: NSAttributedString
        let image: NSImage?
    }

    /// 各列の幅（半角セル数）
    private static let columnWidth = 10

    func menuBarContent() -> MenuBarContent {
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        if focusMode {
            return MenuBarContent(
                title: NSAttributedString(string: ""),
                image: Self.risingChartIcon()
            )
        }
        let vis = visibleStocks
        guard !vis.isEmpty else {
            return MenuBarContent(
                title: NSAttributedString(string: ""),
                image: Self.risingChartIcon()
            )
        }
        let groups = chunks
        guard !groups.isEmpty else {
            return MenuBarContent(title: NSAttributedString(string: ""), image: Self.risingChartIcon())
        }
        let group = groups[chunkIndex % groups.count]
        let result = NSMutableAttributedString()
        for (i, stock) in group.enumerated() {
            if i > 0 {
                result.append(NSAttributedString(
                    string: "  |  ",
                    attributes: [.font: mono, .foregroundColor: NSColor.tertiaryLabelColor]
                ))
            }
            append(stock: stock, to: result, font: mono)
        }
        return MenuBarContent(title: result, image: nil)
    }

    private func append(stock: Stock, to result: NSMutableAttributedString, font mono: NSFont) {
        let name = stock.displayName
        guard let q = stock.quote else {
            let s = Self.pad(name, width: Self.columnWidth, alignRight: false) + " …"
            result.append(NSAttributedString(
                string: s,
                attributes: [.font: mono, .foregroundColor: NSColor.labelColor]
            ))
            return
        }
        let nameCol    = Self.pad(name,                              width: Self.columnWidth, alignRight: false)
        let priceCol   = Self.pad(Self.formatPrice(q.price),         width: Self.columnWidth, alignRight: true)
        let changeCol  = Self.pad(Self.formatSigned(q.change),       width: Self.columnWidth, alignRight: true)
        let percentCol = Self.pad(String(format: "%+.2f%%", q.changePercent),
                                                                     width: Self.columnWidth, alignRight: true)
        let color: NSColor = q.change >= 0 ? .systemRed : .systemGreen
        result.append(NSAttributedString(
            string: "\(nameCol) \(priceCol) ",
            attributes: [.font: mono, .foregroundColor: NSColor.labelColor]
        ))
        result.append(NSAttributedString(
            string: "\(changeCol) \(percentCol)",
            attributes: [.font: mono, .foregroundColor: color]
        ))
    }

    static func formatSigned(_ v: Double) -> String {
        let abs = formatPrice(Swift.abs(v))
        return v >= 0 ? "+\(abs)" : "-\(abs)"
    }

    /// 文字列を「半角セル数」で計った固定幅に整形（CJK は 2 セル換算）。
    /// 短ければスペースで埋め、長ければ切り詰める。
    static func pad(_ s: String, width: Int, alignRight: Bool) -> String {
        let w = visualWidth(s)
        if w == width { return s }
        if w < width {
            let padding = String(repeating: " ", count: width - w)
            return alignRight ? padding + s : s + padding
        }
        // truncate
        var acc = ""
        var used = 0
        for ch in s {
            let cw = visualWidth(String(ch))
            if used + cw > width { break }
            acc.append(ch)
            used += cw
        }
        while visualWidth(acc) < width { acc += " " }
        return acc
    }

    static func visualWidth(_ s: String) -> Int {
        var w = 0
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if (0x1100...0x115F).contains(v)
                || (0x2E80...0x303E).contains(v)
                || (0x3041...0x33FF).contains(v)
                || (0x3400...0x4DBF).contains(v)
                || (0x4E00...0x9FFF).contains(v)
                || (0xA000...0xA4CF).contains(v)
                || (0xAC00...0xD7A3).contains(v)
                || (0xF900...0xFAFF).contains(v)
                || (0xFE30...0xFE4F).contains(v)
                || (0xFF00...0xFF60).contains(v)
                || (0xFFE0...0xFFE6).contains(v) {
                w += 2
            } else {
                w += 1
            }
        }
        return w
    }

    private static let risingChartSVG: String = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" \
    stroke="black" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <polyline points="3,17 9,11 13,14 20,6"/>
      <polyline points="15,6 20,6 20,11"/>
    </svg>
    """

    private static func risingChartIcon() -> NSImage? {
        guard let data = risingChartSVG.data(using: .utf8),
              let img = NSImage(data: data) else { return nil }
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = true
        return img
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
            "simultaneousCount": simultaneousCount
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
            if let s = prefs["simultaneousCount"] as? Int { simultaneousCount = min(max(s, 1), 6) }
        }
    }
}
