import Foundation

struct ResumeRecord: Codable, Equatable {
    var bookmark: Data
    var time: Double
    var lastPath: String
}

final class ResumeStore {
    static let defaultsKey = "hao.player.resume.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(bookmark: Data, time: Double, lastPath: String) {
        let record = ResumeRecord(bookmark: bookmark, time: time, lastPath: lastPath)
        defaults.set(try? JSONEncoder().encode(record), forKey: Self.defaultsKey)
    }

    func load() -> ResumeRecord? {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return nil }
        return try? JSONDecoder().decode(ResumeRecord.self, from: data)
    }

    func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
