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
                }
                let meta: Meta
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

    static func fetch(symbol: String) async throws -> Quote {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=1d&range=1d")!
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
        let price = meta.regularMarketPrice ?? 0
        let prev = meta.chartPreviousClose ?? meta.previousClose ?? price
        let name = meta.shortName ?? meta.longName
        return Quote(price: price, previousClose: prev, name: name, currency: meta.currency)
    }
}
