import AVFoundation
import CryptoKit
import Foundation

/// External command-line tools (bundled helpers first; found even when launched from Finder, where PATH is minimal).
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

    private static let lock = NSLock()
    private static var running: [ObjectIdentifier: Process] = [:]

    /// Called on quit: a conversion left running would keep writing a partial file nobody renames.
    static func terminateAll() {
        lock.lock(); let all = Array(running.values); lock.unlock()
        all.forEach { $0.terminate() }
    }

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
                lock.lock(); running[ObjectIdentifier(p)] = p; lock.unlock()
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
                lock.lock(); running[ObjectIdentifier(p)] = nil; lock.unlock()
                cont.resume(returning: Result(status: p.terminationStatus, out: outData, err: errData))
            }
        }
    }
}

/// Converted copies of files AVPlayer can't open directly (mkv, webm…), with an index for
/// content-based reuse, playback after the original is deleted, and a size limit (least recently used goes first).
enum ConversionCache {
    struct Entry: Codable {
        var file: String        // file name inside the cache directory
        var source: String      // last known path of the original
        var bytes: Int64
        var lastUsed: Date
    }

    static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Relisten", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private static var indexURL: URL { dir.appendingPathComponent("index.json") }
    private static let lock = NSLock()

    static func load() -> [String: Entry] {
        (try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: indexURL))) ?? [:]
    }

    private static func save(_ index: [String: Entry]) {
        if let data = try? JSONEncoder().encode(index) { try? data.write(to: indexURL, options: .atomic) }
    }

    private static func mutate(_ body: (inout [String: Entry]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var index = load()
        body(&index)
        save(index)
    }

    /// Same content → same key, wherever the file lives: size + SHA-256 of the first and last 4 MB.
    static func fingerprint(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return nil }
        let chunk: UInt64 = 4 << 20
        var hasher = SHA256()
        hasher.update(data: Data("v3|\(size)".utf8))
        try? h.seek(toOffset: 0)
        hasher.update(data: (try? h.read(upToCount: Int(chunk))) ?? Data())
        if size > chunk * 2 {
            try? h.seek(toOffset: size - chunk)
            hasher.update(data: (try? h.read(upToCount: Int(chunk))) ?? Data())
        }
        return hasher.finalize().prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Key scheme used by 1.0 (path + size + mtime); such files are adopted instead of converted again.
    static func legacyKey(_ url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = "v2|\(url.path)|\(attrs?[.size] ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        return SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func hit(key: String, source: URL) -> URL? {
        var found: URL?
        mutate { index in
            if index[key] == nil {   // 1.0 cache file for this exact path → adopt it under the content key
                let legacy = dir.appendingPathComponent("\(legacyKey(source)).mp4")
                let target = dir.appendingPathComponent("\(key).mp4")
                if FileManager.default.fileExists(atPath: legacy.path),
                   (try? FileManager.default.moveItem(at: legacy, to: target)) != nil {
                    index[key] = Entry(file: target.lastPathComponent, source: source.path, bytes: fileSize(target), lastUsed: Date())
                }
            }
            guard var e = index[key] else { return }
            let url = dir.appendingPathComponent(e.file)
            guard FileManager.default.fileExists(atPath: url.path) else { index[key] = nil; return }
            e.source = source.path
            e.lastUsed = Date()
            index[key] = e
            found = url
        }
        return found
    }

    /// The original is gone: find its converted copy by the path it had.
    static func lookup(source path: String) -> URL? {
        var found: URL?
        mutate { index in
            guard let (key, e) = index.filter({ $0.value.source == path }).max(by: { $0.value.lastUsed < $1.value.lastUsed })
            else { return }
            let url = dir.appendingPathComponent(e.file)
            guard FileManager.default.fileExists(atPath: url.path) else { index[key] = nil; return }
            index[key]?.lastUsed = Date()
            found = url
        }
        return found
    }

    static func record(key: String, file: URL, source: URL) {
        mutate { $0[key] = Entry(file: file.lastPathComponent, source: source.path, bytes: fileSize(file), lastUsed: Date()) }
    }

    static var totalBytes: Int64 { load().values.reduce(0) { $0 + $1.bytes } }

    /// Evict least-recently-used copies until under the limit (Prefs.cacheLimitGB, 0 = unlimited).
    static func enforceLimit(keeping keep: String? = nil, limitBytes: Int64? = nil) {
        let limit = limitBytes ?? (Int64(Prefs.cacheLimitGB) << 30)
        guard limit > 0 else { return }
        mutate { index in
            var total = index.values.reduce(0) { $0 + $1.bytes }
            for (key, e) in index.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }) where total > limit && key != keep {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(e.file))
                index[key] = nil
                total -= e.bytes
            }
        }
    }

    /// Remove everything except the copy that is playing right now.
    static func clear(keepingFile keep: URL?) {
        mutate { index in
            for (key, e) in index where dir.appendingPathComponent(e.file).path != keep?.path {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(e.file))
                index[key] = nil
            }
        }
    }

    /// At launch: delete leftover partial files (no conversion can be running yet) and index stray copies
    /// so they count toward the limit and get evicted first.
    static func housekeeping() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files where f.lastPathComponent.hasSuffix(".partial.mp4") { try? FileManager.default.removeItem(at: f) }
        mutate { index in
            let known = Set(index.values.map(\.file))
            for f in files where f.pathExtension == "mp4" && !f.lastPathComponent.hasSuffix(".partial.mp4")
                && !known.contains(f.lastPathComponent) {
                let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                index["orphan-" + f.deletingPathExtension().lastPathComponent] =
                    Entry(file: f.lastPathComponent, source: "", bytes: fileSize(f), lastUsed: date)
            }
        }
        enforceLimit()
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

/// AVPlayer can't open mkv/webm/ogg…; remux (or, as a last resort, transcode) those into a cached mp4.
enum MediaPreparer {
    static func playableURL(for url: URL, progress: @escaping (String) -> Void) async throws -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else {
            if let cached = ConversionCache.lookup(source: url.path) { return cached }
            throw AppError("找不到原文件：\(url.lastPathComponent)")
        }
        if (try? await AVURLAsset(url: url).load(.isPlayable)) == true { return url }
        guard let ffmpeg = Tools.ffmpeg else {
            throw AppError("系统播放器不支持这个格式，安装 ffmpeg 后可自动转换：brew install ffmpeg")
        }
        progress("正在检查是否转换过…")
        guard let key = await Task.detached(operation: { ConversionCache.fingerprint(url) }).value else {
            throw AppError("无法读取文件：\(url.lastPathComponent)")
        }
        if let hit = ConversionCache.hit(key: key, source: url) { return hit }

        let probe = await probe(url)
        let target = ConversionCache.dir.appendingPathComponent("\(key).mp4")
        // Unique temp name: two conversions of the same file must never write into one partial file.
        let tmp = ConversionCache.dir.appendingPathComponent("\(key).\(UUID().uuidString).partial.mp4")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var maps = ["-map", "0:v:0?", "-map", "0:a:0?"]
        var subMeta: [String] = []
        for (n, s) in probe.textSubtitles.enumerated() {   // keep text subtitles so the copy works without the original
            maps += ["-map", "0:\(s.index)"]
            if !s.language.isEmpty { subMeta += ["-metadata:s:s:\(n)", "language=\(s.language)"] }
            if !s.title.isEmpty { subMeta += ["-metadata:s:s:\(n)", "handler_name=\(s.title)", "-metadata:s:s:\(n)", "title=\(s.title)"] }
        }
        let head = ["-nostdin", "-y", "-v", "error", "-i", url.path] + maps + ["-dn"]
        // Downmix to stereo: 5.1 dialogue lives in the center channel, and a 6-channel AAC with an
        // unknown layout plays silent (or voiceless) on Mac speakers/headphones.
        let tail = ["-c:a", "aac", "-ac", "2", "-b:a", "192k"] + (probe.textSubtitles.isEmpty ? [] : ["-c:s", "mov_text"])
            + subMeta + ["-movflags", "+faststart", tmp.path]

        // HEVC (incl. Dolby Vision): strip the DV layer, tag hvc1 → plain HDR10 that AVFoundation plays.
        let hevc = probe.videoCodec == "hevc"
        let copyVideo = ["-c:v", "copy"] + (hevc ? ["-tag:v", "hvc1", "-bsf:v", "dovi_rpu=strip=1"] : [])
        progress("正在转换格式（只需一次）…")
        var r = try await Tools.run(ffmpeg, head + copyVideo + tail)
        let remuxPlayable = r.status == 0 ? (try? await AVURLAsset(url: tmp).load(.isPlayable)) == true : false
        if !remuxPlayable {
            // Last resort: hardware re-encode, capped at 1080p — plenty for listening practice, and fast.
            progress("正在重新编码视频（较慢，只需一次）…")
            r = try await Tools.run(ffmpeg, head + ["-vf", "scale='min(1920,iw)':-2", "-c:v", "h264_videotoolbox",
                                                    "-b:v", "5M", "-pix_fmt", "yuv420p"] + tail)
        }
        guard r.status == 0 else {
            throw AppError("格式转换失败：" + String(decoding: r.err.suffix(400), as: UTF8.self))
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: tmp, to: target)
        ConversionCache.record(key: key, file: target, source: url)
        ConversionCache.enforceLimit(keeping: key)
        return target
    }

    struct Probe {
        struct Sub { let index: Int; let language: String; let title: String }
        var videoCodec = ""
        var textSubtitles: [Sub] = []
    }

    private struct ProbeJSON: Decodable {
        struct Stream: Decodable { let index: Int; let codec_type: String?; let codec_name: String?; let tags: [String: String]? }
        let streams: [Stream]
    }

    static func probe(_ url: URL) async -> Probe {
        var p = Probe()
        guard let ffprobe = Tools.ffprobe,
              let r = try? await Tools.run(ffprobe, ["-v", "error", "-show_entries",
                                                     "stream=index,codec_type,codec_name:stream_tags=language,title",
                                                     "-of", "json", url.path]),
              let json = try? JSONDecoder().decode(ProbeJSON.self, from: r.out) else { return p }
        p.videoCodec = json.streams.first { $0.codec_type == "video" }?.codec_name ?? ""
        p.textSubtitles = json.streams.compactMap { s in
            guard s.codec_type == "subtitle", SubtitleLoader.textCodecs.contains(s.codec_name ?? "") else { return nil }
            return Probe.Sub(index: s.index, language: s.tags?["language"] ?? "", title: s.tags?["title"] ?? "")
        }
        return p
    }
}
