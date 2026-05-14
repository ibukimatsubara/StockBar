import Foundation

enum YahooFinanceError: Error, LocalizedError {
    case notFound(String)
    case decoding

    var errorDescription: String? {
        switch self {
        case .notFound(let s): return "銘柄が見つかりません: \(s)"
        case .decoding: return "レスポンスを解析できませんでした"
        }
    }
}

enum YahooFinance {
    private struct Response: Decodable {
        struct Chart: Decodable {
            struct Result: Decodable {
                struct Meta: Decodable {
                    let regularMarketPrice: Double?
                    let chartPreviousClose: Double?
                    let previousClose: Double?
                    let shortName: String?
                    let longName: String?
                    let currency: String?
                    let symbol: String?
                    let currentTradingPeriod: TradingPeriods?
                }
                struct TradingPeriods: Decodable {
                    let pre: Period?
                    let regular: Period?
                    let post: Period?
                }
                struct Period: Decodable {
                    let start: Int
                    let end: Int
                }
                struct Indicators: Decodable {
                    let quote: [QuoteSeries]
                }
                struct QuoteSeries: Decodable {
                    let close: [Double?]?
                }
                let meta: Meta
                let timestamp: [Int]?
                let indicators: Indicators?
            }
            struct ErrorBody: Decodable {
                let code: String?
                let description: String?
            }
            let result: [Result]?
            let error: ErrorBody?
        }
        let chart: Chart
    }

    static func fetch(symbol: String, includeExtendedHours: Bool = true) async throws -> Quote {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        let prePost = includeExtendedHours ? "true" : "false"
        let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=1m&range=1d&includePrePost=\(prePost)")!
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw YahooFinanceError.decoding
        }
        guard let result = decoded.chart.result?.first else {
            throw YahooFinanceError.notFound(symbol)
        }
        let meta = result.meta
        let regularPrice = meta.regularMarketPrice ?? 0
        let prevDayClose = meta.chartPreviousClose ?? meta.previousClose ?? regularPrice

        // 最新の非nilバーを後ろから探し、そのセッションを判定
        var session: MarketSession = .regular
        var latestPrice: Double = regularPrice

        if let timestamps = result.timestamp,
           let closes = result.indicators?.quote.first?.close ?? nil,
           !timestamps.isEmpty {
            for i in stride(from: timestamps.count - 1, through: 0, by: -1) {
                guard i < closes.count, let c = closes[i] else { continue }
                let t = timestamps[i]
                if let p = meta.currentTradingPeriod?.pre, t >= p.start && t < p.end {
                    session = .pre
                } else if let p = meta.currentTradingPeriod?.regular, t >= p.start && t < p.end {
                    session = .regular
                } else if let p = meta.currentTradingPeriod?.post, t >= p.start && t < p.end {
                    session = .post
                } else {
                    session = .closed
                }
                latestPrice = c
                break
            }
        }

        // 比較ベースライン:
        //  - pre / regular: 前営業日の終値
        //  - post (AH): 本日の通常セッション終値（= regularMarketPrice）
        //  - closed: 最後の通常終値があればそれ、なければ前日終値
        let baseline: Double
        switch session {
        case .pre, .regular:
            baseline = prevDayClose
        case .post:
            baseline = regularPrice != 0 ? regularPrice : prevDayClose
        case .closed:
            baseline = regularPrice != 0 ? regularPrice : prevDayClose
        }

        let name = meta.shortName ?? meta.longName
        return Quote(
            price: latestPrice,
            previousClose: baseline,
            name: name,
            currency: meta.currency,
            session: session
        )
    }
}
