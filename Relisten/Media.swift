import AVFoundation
import CryptoKit
import Foundation

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// External command-line tools (found even when launched from Finder, where PATH is minimal).
enum Tools {
    static let ffmpeg = find("ffmpeg")
    static let ffprobe = find("ffprobe")

    static func find(_ name: String) -> String? {
        // The App Store build ships its own LGPL ffmpeg/ffprobe inside the bundle (sandbox-inherited helpers).
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        let envPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"] + envPaths {
            let p = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    struct Result { let status: Int32; let out: Data; let err: Data }

    /// Runs a process, draining stdout and stderr concurrently so a full pipe can never deadlock it.
    static func run(_ exe: String, _ args: [String]) async throws -> Result {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(throwing: error); return }
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                cont.resume(returning: Result(status: p.terminationStatus, out: outData, err: errData))
            }
        }
    }
}

/// AVPlayer can't open mkv/webm/ogg…; remux (or transcode) those into a cached mp4.
enum MediaPreparer {
    static func playableURL(for url: URL, progress: @escaping (String) -> Void) async throws -> URL {
        if (try? await AVURLAsset(url: url).load(.isPlayable)) == true { return url }
        guard let ffmpeg = Tools.ffmpeg else {
            throw AppError("系统播放器不支持这个格式，安装 ffmpeg 后可自动转换：brew install ffmpeg")
        }
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Relisten", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = "v2|\(url.path)|\(attrs?[.size] ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let target = cacheDir.appendingPathComponent("\(hash).mp4")
        if FileManager.default.fileExists(atPath: target.path) { return target }

        var videoCodec = ""
        if let ffprobe = Tools.ffprobe,
           let r = try? await Tools.run(ffprobe, ["-v", "error", "-select_streams", "v:0",
                                                  "-show_entries", "stream=codec_name", "-of", "csv=p=0", url.path]) {
            videoCodec = String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Unique temp name: two conversions of the same file must never write into one partial file.
        let tmp = cacheDir.appendingPathComponent("\(hash).\(UUID().uuidString).partial.mp4")
        let common = ["-nostdin", "-y", "-v", "error", "-i", url.path, "-map", "0:v:0?", "-map", "0:a:0?", "-sn", "-dn"]
        // Downmix to stereo: 5.1 dialogue lives in the center channel, and a 6-channel AAC with an
        // unknown layout plays silent (or voiceless) on Mac speakers/headphones.
        let audio = ["-c:a", "aac", "-ac", "2", "-b:a", "192k", "-movflags", "+faststart", tmp.path]

        progress("正在转换格式（只需一次）…")
        var r = try await Tools.run(ffmpeg, common + ["-c:v", "copy"] + (videoCodec == "hevc" ? ["-tag:v", "hvc1"] : []) + audio)
        let remuxPlayable = r.status == 0 ? (try? await AVURLAsset(url: tmp).load(.isPlayable)) == true : false
        if !remuxPlayable {
            progress("正在重新编码视频（较慢，只需一次）…")
            r = try await Tools.run(ffmpeg, common + ["-c:v", "h264_videotoolbox", "-b:v", "6M"] + audio)
        }
        guard r.status == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw AppError("格式转换失败：" + String(decoding: r.err.suffix(400), as: UTF8.self))
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: tmp, to: target)
        return target
    }
}

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

    private static var all: [String: Data] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Data]) ?? [:]
    }

    /// Call while we hold access (right after an open panel, drop or Finder open).
    static func remember(_ url: URL) {
        guard let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
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
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
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
