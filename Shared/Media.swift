import AVFoundation
import Foundation

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

#if os(iOS)
/// iOS can't spawn helper processes, so only formats AVFoundation plays natively are supported.
enum MediaPreparer {
    static func playableURL(for url: URL, progress: @escaping (String) -> Void) async throws -> URL {
        if (try? await AVURLAsset(url: url).load(.isPlayable)) == true { return url }
        throw AppError("iPhone / iPad 版暂不支持这个格式（如 mkv），请使用 mp4、mov、m4v、mp3 或 m4a")
    }
}
#endif

/// Last position per file + recent files list.
enum ResumeStore {
    private static let positionsKey = "resumePositions"
    private static let recentsKey = "recentFiles"

    static func position(for path: String) -> Double? {
        (UserDefaults.standard.dictionary(forKey: positionsKey) as? [String: Double])?[path]
    }

    static func save(_ seconds: Double, for path: String) {
        var d = (UserDefaults.standard.dictionary(forKey: positionsKey) as? [String: Double]) ?? [:]
        d[path] = seconds
        UserDefaults.standard.set(d, forKey: positionsKey)
    }

    static var recents: [String] {
        (UserDefaults.standard.stringArray(forKey: recentsKey) ?? []).filter {
            BookmarkStore.has($0) || FileManager.default.fileExists(atPath: $0)
        }
    }

    static func touch(_ path: String) {
        var r = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
        r.removeAll { $0 == path }
        r.insert(path, at: 0)
        UserDefaults.standard.set(Array(r.prefix(12)), forKey: recentsKey)
    }
}

/// App Sandbox: we may only touch files the user picked. Security-scoped bookmarks keep that access
/// across launches (recent files, favorites) and for folders the user granted (sibling subtitle files).
enum BookmarkStore {
    private static let key = "securityBookmarks"
    private static var active: [String: URL] = [:]

    static func has(_ path: String) -> Bool { all[path] != nil }

    #if os(macOS)
    private static let bookmarkCreation: URL.BookmarkCreationOptions = .withSecurityScope
    private static let bookmarkResolution: URL.BookmarkResolutionOptions = .withSecurityScope
    #else
    private static let bookmarkCreation: URL.BookmarkCreationOptions = []
    private static let bookmarkResolution: URL.BookmarkResolutionOptions = []
    #endif

    private static var all: [String: Data] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Data]) ?? [:]
    }

    /// Call while we hold access (right after an open panel, drop or Finder open).
    static func remember(_ url: URL) {
        guard let data = try? url.bookmarkData(options: bookmarkCreation, includingResourceValuesForKeys: nil,
                                               relativeTo: nil) else { return }
        var d = all
        d[url.path] = data
        UserDefaults.standard.set(d, forKey: key)
    }

    /// Resolves and starts accessing a remembered file or folder; returns its URL.
    @discardableResult
    static func access(_ path: String) -> URL? {
        if let url = active[path] { return url }
        guard let data = all[path] else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: bookmarkResolution, relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        active[path] = url
        if stale { remember(url) }
        return url
    }

    /// Starts accessing the nearest granted ancestor folder of `url`, if any.
    @discardableResult
    static func accessFolder(containing url: URL) -> Bool {
        var dir = url.deletingLastPathComponent()
        while dir.path != "/" {
            if access(dir.path) != nil { return true }
            dir = dir.deletingLastPathComponent()
        }
        return false
    }
}
