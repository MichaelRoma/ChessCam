import Foundation

enum ChessSite: String, CaseIterable, Codable {
    case lichess = "https://lichess.org"
    case chessCom = "https://www.chess.com"

    var title: String {
        switch self {
        case .lichess: return "Lichess"
        case .chessCom: return "Chess.com"
        }
    }

    var url: URL { URL(string: rawValue)! }
}

struct AppSettings: Codable {
    var site: ChessSite = .chessCom
    var boardFraction: Double = 0.5
    var mirrorCamera: Bool = true
    var saveToPhotos: Bool = false

    private static let storageKey = "appSettings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              var settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        settings.boardFraction = min(0.8, max(0.2, settings.boardFraction))
        return settings
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
