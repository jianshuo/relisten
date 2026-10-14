import Foundation

struct Favorite: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    var start: Double
    var end: Double
    var text: String
    var added = Date()

    var fileName: String { (path as NSString).lastPathComponent }
    var key: String { Self.key(path: path, start: start) }
    static func key(path: String, start: Double) -> String { "\(path)#\(Int((start * 1000).rounded()))" }
}

@MainActor
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    @Published private(set) var items: [Favorite] = []
    @Published private(set) var keys: Set<String> = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Relisten", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("favorites.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Favorite].self, from: data) {
            items = saved
        }
        keys = Set(items.map(\.key))
    }

    func contains(path: String, cue: Cue) -> Bool { keys.contains(Favorite.key(path: path, start: cue.start)) }

    /// Returns true if the cue is now a favorite.
    @discardableResult
    func toggle(path: String, cue: Cue) -> Bool {
        let key = Favorite.key(path: path, start: cue.start)
        if keys.contains(key) {
            items.removeAll { $0.key == key }
        } else {
            items.insert(Favorite(path: path, start: cue.start, end: cue.end, text: cue.text), at: 0)
        }
        save()
        return keys.contains(key)
    }

    func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        save()
    }

    private func save() {
        keys = Set(items.map(\.key))
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: fileURL, options: .atomic) }
    }
}
