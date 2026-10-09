import Foundation

struct BroadcastRecordingStatus: Decodable {
    enum Phase: String, Decodable {
        case starting
        case recording
        case finishing
        case finished
        case failed
    }

    let id: String
    let phase: Phase
    let startedAt: TimeInterval
    let updatedAt: TimeInterval
    let message: String?

    static func load() -> BroadcastRecordingStatus? {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.miromanovsky.ChessCam"
        ) else { return nil }
        let url = groupURL.appendingPathComponent("broadcast-state.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    var isActive: Bool {
        switch phase {
        case .starting, .recording:
            return Date().timeIntervalSince1970 - updatedAt < 5
        case .finishing:
            return Date().timeIntervalSince1970 - updatedAt < 25
        case .finished, .failed:
            return false
        }
    }
}
