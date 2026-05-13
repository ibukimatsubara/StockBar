import Foundation

struct Stock: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var symbol: String
    var nickname: String?
    var visible: Bool = true

    var quote: Quote?

    enum CodingKeys: String, CodingKey {
        case id, symbol, nickname, visible
    }

    var displayName: String { nickname ?? quote?.name ?? symbol }
}

struct Quote: Equatable {
    let price: Double
    let previousClose: Double
    let name: String?
    let currency: String?

    var change: Double { price - previousClose }
    var changePercent: Double {
        previousClose == 0 ? 0 : change / previousClose * 100
    }
}
