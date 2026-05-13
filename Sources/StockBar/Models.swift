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

enum MarketSession: String, Codable, Equatable {
    case regular
    case pre
    case post
    case closed
}

struct Quote: Equatable {
    let price: Double
    let previousClose: Double
    let name: String?
    let currency: String?
    let session: MarketSession

    var change: Double { price - previousClose }
    var changePercent: Double {
        previousClose == 0 ? 0 : change / previousClose * 100
    }

    /// メニューバー / リストに表示する短いセッションマーカー。通常時は nil。
    var sessionMarker: String? {
        switch session {
        case .pre: return "P"
        case .post: return "A"
        case .regular, .closed: return nil
        }
    }
}
