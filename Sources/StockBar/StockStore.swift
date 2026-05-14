import Foundation
import AppKit
import Combine

enum DisplayMode: String, Codable, CaseIterable, Identifiable {
    case rotation
    case ticker
    var id: String { rawValue }
    var label: String {
        switch self {
        case .rotation: return "切替表示"
        case .ticker:   return "右→左に流す"
        }
    }
}

@MainActor
final class StockStore: ObservableObject {
    @Published var stocks: [Stock] = []
    @Published var rotationInterval: TimeInterval = 5
    @Published var simultaneousCount: Int = 1
    @Published var includeExtendedHours: Bool = false
    @Published var displayMode: DisplayMode = .rotation
    @Published var focusMode: Bool = false
    @Published private(set) var chunkIndex: Int = 0
    @Published private(set) var lastError: String?

    var onUpdate: (() -> Void)?

    private var rotationTimer: Timer?
    private var tickerAnimTimer: Timer?
    private var tickerRefreshTimer: Timer?
    private var tickerOffset: Int = 0
    /// 流れる表示の文字幅（半角セル数）
    private let tickerWindowCells = 60
    /// 流れる表示のアニメ間隔
    private let tickerStepInterval: TimeInterval = 0.08
    /// 流れる表示の API 再取得間隔
    private let tickerRefreshInterval: TimeInterval = 60
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

        $includeExtendedHours
            .dropFirst()
            .sink { [weak self] _ in
                self?.savePrefs()
                Task { @MainActor in await self?.refreshAll() }
            }
            .store(in: &cancellables)

        $displayMode
            .dropFirst()
            .sink { [weak self] _ in
                self?.tickerOffset = 0
                self?.chunkIndex = 0
                self?.savePrefs()
                self?.restartTimersForMode()
                self?.onUpdate?()
            }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    func start() {
        Task {
            await refreshAll()
            onUpdate?()
        }
        restartTimersForMode()
        onUpdate?()
    }

    private func restartTimersForMode() {
        rotationTimer?.invalidate(); rotationTimer = nil
        tickerAnimTimer?.invalidate(); tickerAnimTimer = nil
        tickerRefreshTimer?.invalidate(); tickerRefreshTimer = nil
        switch displayMode {
        case .rotation:
            startRotationTimer()
        case .ticker:
            startTickerTimers()
        }
    }

    private func startRotationTimer() {
        rotationTimer?.invalidate()
        rotationTimer = Timer.scheduledTimer(withTimeInterval: rotationInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func startTickerTimers() {
        tickerAnimTimer = Timer.scheduledTimer(withTimeInterval: tickerStepInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.tickerOffset &+= 1
                self.onUpdate?()
            }
        }
        tickerRefreshTimer = Timer.scheduledTimer(withTimeInterval: tickerRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll() }
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

    func setNickname(_ stock: Stock, to raw: String) {
        guard let i = stocks.firstIndex(where: { $0.id == stock.id }) else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        stocks[i].nickname = trimmed.isEmpty ? nil : trimmed
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
        guard shouldRefresh(symbol: symbol) else { return }
        do {
            let q = try await YahooFinance.fetch(symbol: symbol, includeExtendedHours: includeExtendedHours)
            if let idx = stocks.firstIndex(where: { $0.symbol == symbol }) {
                stocks[idx].quote = q
                stocks[idx].lastError = nil
                stocks[idx].lastFetched = Date()
            }
            lastError = nil
            onUpdate?()
        } catch {
            if let idx = stocks.firstIndex(where: { $0.symbol == symbol }) {
                stocks[idx].lastError = error.localizedDescription
                stocks[idx].lastFetched = Date()
            }
            lastError = error.localizedDescription
            onUpdate?()
        }
    }

    enum MarketRegion { case jp, us, alwaysOn }

    static func marketRegion(for symbol: String) -> MarketRegion {
        let s = symbol.uppercased()
        if s.hasSuffix(".T") { return .jp }
        if s == "^N225" || s == "^TPX" || s.hasPrefix("^N3") || s.hasPrefix("^TPX") { return .jp }
        if s.hasSuffix("=X") || s.hasSuffix("-USD") || s.hasSuffix("=F") { return .alwaysOn }
        return .us
    }

    /// 各銘柄を再取得すべきかどうか。市場時間外は最大 6 時間に 1 回まで（クローズ直後のスナップショット取得用）。
    func shouldRefresh(symbol: String) -> Bool {
        let region = Self.marketRegion(for: symbol)
        if region == .alwaysOn { return true }
        if isMarketOpen(region: region) { return true }
        guard let stock = stocks.first(where: { $0.symbol == symbol }),
              let last = stock.lastFetched else {
            return true
        }
        return Date().timeIntervalSince(last) > 6 * 3600
    }

    private func isMarketOpen(region: MarketRegion) -> Bool {
        let now = Date()
        switch region {
        case .alwaysOn:
            return true
        case .jp:
            return isWithin(now, tz: "Asia/Tokyo", openH: 9, openM: 0, closeH: 15, closeM: 0)
        case .us:
            if includeExtendedHours {
                // pre 4:00 〜 after 20:00 ET
                return isWithin(now, tz: "America/New_York", openH: 4, openM: 0, closeH: 20, closeM: 0)
            }
            return isWithin(now, tz: "America/New_York", openH: 9, openM: 30, closeH: 16, closeM: 0)
        }
    }

    private func isWithin(_ date: Date, tz: String, openH: Int, openM: Int, closeH: Int, closeM: Int) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tz)!
        let comps = cal.dateComponents([.weekday, .hour, .minute], from: date)
        guard let wd = comps.weekday, wd >= 2 && wd <= 6 else { return false }
        let cur = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        return cur >= openH * 60 + openM && cur <= closeH * 60 + closeM
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
        switch displayMode {
        case .rotation:
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
        case .ticker:
            return MenuBarContent(title: tickerTitle(font: mono, stocks: vis), image: nil)
        }
    }

    /// 全銘柄を 1 本の長い帯に連結し、tickerOffset セル分だけ右→左にスライドした窓を返す。
    private func tickerTitle(font mono: NSFont, stocks vis: [Stock]) -> NSAttributedString {
        let track = NSMutableAttributedString()
        var cellWidths: [Int] = []  // UTF-16 unit ごとの可視セル幅
        let sep = "   •   "
        func appendStr(_ s: String, color: NSColor) {
            let start = track.length
            track.append(NSAttributedString(string: s, attributes: [.font: mono, .foregroundColor: color]))
            // UTF-16 単位で 1 文字ずつ可視幅を割り当て
            var idx = s.startIndex
            while idx < s.endIndex {
                let ch = s[idx]
                let w = Self.visualWidth(String(ch))
                let units = String(ch).utf16.count
                cellWidths.append(w)
                for _ in 1..<units { cellWidths.append(0) }
                idx = s.index(after: idx)
            }
            assert(cellWidths.count == track.length)
            _ = start
        }
        for (i, stock) in vis.enumerated() {
            if i > 0 {
                appendStr(sep, color: NSColor.tertiaryLabelColor)
            }
            let name = stock.displayName
            if let q = stock.quote {
                let priceStr: String
                if let m = q.sessionMarker { priceStr = "\(m) \(Self.formatPrice(q.price))" }
                else { priceStr = Self.formatPrice(q.price) }
                appendStr("\(name) \(priceStr) ", color: NSColor.labelColor)
                let chg = "\(Self.formatSigned(q.change)) \(String(format: "%+.2f%%", q.changePercent))"
                appendStr(chg, color: q.change >= 0 ? .systemRed : .systemGreen)
            } else {
                appendStr("\(name) …", color: NSColor.secondaryLabelColor)
            }
        }
        let totalCells = cellWidths.reduce(0, +)
        guard totalCells > 0 else { return NSAttributedString(string: "") }

        // 帯が窓より短ければそのまま表示
        if totalCells <= tickerWindowCells {
            return track
        }

        // 帯を 2 連結してラップアラウンド対応
        let doubled = NSMutableAttributedString(attributedString: track)
        doubled.append(track)
        let doubledWidths = cellWidths + cellWidths

        // セル空間で [c0, c0 + window) を UTF-16 範囲に対応付け
        let c0 = ((tickerOffset % totalCells) + totalCells) % totalCells
        let cEnd = c0 + tickerWindowCells
        var cellsSeen = 0
        var startU = 0
        var endU = doubled.length
        var foundStart = false
        for i in 0..<doubledWidths.count {
            let next = cellsSeen + doubledWidths[i]
            if !foundStart, next > c0 {
                // i 番目の文字が境界をまたぐ → 1 つ進めて綺麗な位置にする
                startU = (doubledWidths[i] > 1 && cellsSeen < c0) ? i + 1 : i
                foundStart = true
            }
            if foundStart, next >= cEnd {
                endU = (doubledWidths[i] > 1 && next > cEnd) ? i : i + 1
                break
            }
            cellsSeen = next
        }
        if endU < startU { endU = startU }
        let window = doubled.attributedSubstring(from: NSRange(location: startU, length: endU - startU))
        let mut = NSMutableAttributedString(attributedString: window)
        // 右側に足りない分はスペース埋め
        let cur = Self.visualWidth(mut.string)
        if cur < tickerWindowCells {
            mut.append(NSAttributedString(
                string: String(repeating: " ", count: tickerWindowCells - cur),
                attributes: [.font: mono]
            ))
        }
        return mut
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
        let nameCol = Self.pad(name, width: Self.columnWidth, alignRight: false)
        let priceCol: String
        if let m = q.sessionMarker {
            let inner = Self.pad(Self.formatPrice(q.price), width: Self.columnWidth - 2, alignRight: true)
            priceCol = "\(m) \(inner)"
        } else {
            priceCol = Self.pad(Self.formatPrice(q.price), width: Self.columnWidth, alignRight: true)
        }
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
            "simultaneousCount": simultaneousCount,
            "includeExtendedHours": includeExtendedHours,
            "displayMode": displayMode.rawValue
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
            if let e = prefs["includeExtendedHours"] as? Bool { includeExtendedHours = e }
            if let m = prefs["displayMode"] as? String, let mode = DisplayMode(rawValue: m) { displayMode = mode }
        }
    }
}
