import AVFoundation
import Foundation

/// One subtitle line = one "sentence" we can jump to, replay and loop.
struct Cue: Identifiable, Hashable {
    let id: Int
    let start: Double
    let end: Double
    let text: String
}

extension Array where Element == Cue {
    /// Index of the last cue whose start <= t (binary search).
    func lastIndex(startingAtOrBefore t: Double) -> Int? {
        var lo = 0, hi = count - 1
        var found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if self[mid].start <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }
}

// MARK: - Parsing (SRT / WebVTT)

enum SubtitleParser {
    static func parse(_ raw: String) -> [Cue] {
        let lines = raw
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var result: [(Double, Double, String)] = []
        var block: [String] = []
        func flush() {
            defer { block.removeAll() }
            guard let ti = block.firstIndex(where: { $0.contains("-->") }) else { return }
            let parts = block[ti].components(separatedBy: "-->")
            guard parts.count == 2, let s = parseTime(parts[0]), let e = parseTime(parts[1]) else { return }
            let body = block[(ti + 1)...].map(clean).filter { !$0.isEmpty }.joined(separator: "\n")
            if !body.isEmpty { result.append((s, e, body)) }
        }
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush() } else { block.append(line) }
        }
        flush()
        return normalize(result)
    }

    /// "01:02:03,456" / "01:02:03.456" / "02:03.456" (+ trailing VTT settings) → seconds
    static func parseTime(_ s: String) -> Double? {
        guard let token = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else { return nil }
        let fields = token.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(fields.count) else { return nil }
        var total = 0.0
        for f in fields {
            guard let v = Double(f) else { return nil }
            total = total * 60 + v
        }
        return total
    }

    static func clean(_ line: String) -> String {
        var s = line
        s = s.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)   // <i>, <c.x>, <00:00:01.000>
        s = s.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression) // ASS {\an8}
        s = s.replacingOccurrences(of: "\\N", with: " ").replacingOccurrences(of: "\\n", with: " ")
        for (k, v) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&quot;": "\"", "&#39;": "'"] {
            s = s.replacingOccurrences(of: k, with: v)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Sort, drop flashes, strip YouTube-style rolling duplicates, clamp overlaps, assign ids.
    static func normalize(_ raw: [(Double, Double, String)]) -> [Cue] {
        let sorted = raw.sorted { $0.0 < $1.0 }
        var out: [(Double, Double, String)] = []
        for (s, e, t) in sorted {
            var text = t
            if let prev = out.last, let lastLine = prev.2.components(separatedBy: "\n").last,
               text.hasPrefix(lastLine + "\n") {
                text = String(text.dropFirst(lastLine.count + 1))
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard e - s >= 0.05, !text.isEmpty else { continue }
            if let prev = out.last, prev.2 == text, s - prev.1 < 0.5 {
                out[out.count - 1].1 = max(prev.1, e)   // same line split in two → merge
                continue
            }
            out.append((s, e, text))
        }
        for i in out.indices.dropLast() where out[i].1 > out[i + 1].0 {
            out[i].1 = max(out[i].0 + 0.05, out[i + 1].0)
        }
        return out.enumerated().map { Cue(id: $0.offset, start: $0.element.0, end: $0.element.1, text: $0.element.2) }
    }

    /// Advanced SubStation Alpha: `Dialogue: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text`
    static func parseASS(_ raw: String) -> [Cue] {
        var out: [(Double, Double, String)] = []
        for line in raw.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        where line.hasPrefix("Dialogue:") {
            let fields = line.dropFirst("Dialogue:".count).split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false)
            guard fields.count == 10, let s = parseTime(String(fields[1])), let e = parseTime(String(fields[2])) else { continue }
            let text = clean(String(fields[9]))
            if !text.isEmpty { out.append((s, e, text)) }
        }
        return normalize(out)
    }

    static func decode(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let s = String(data: data, encoding: .utf16) { return s }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let s = String(data: data, encoding: gb) { return s }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Discovery & loading

struct SubtitleSource: Identifiable, Hashable {
    enum Kind: Hashable {
        case file(URL)
        case ffmpegStream(Int)   // absolute stream index inside the media file
        case avTrack(Int)        // index into the asset's subtitle/text tracks
    }
    let kind: Kind
    let name: String
    let isEnglish: Bool
    var id: String { "\(kind)" }
}

enum SubtitleLoader {
    static let fileExtensions: Set<String> = ["srt", "vtt", "ass", "ssa"]
    static let textCodecs: Set<String> = ["subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text"]

    /// Whether we may list the media's folder (false under App Sandbox until the user grants it).
    static func canReadFolder(of media: URL) -> Bool {
        BookmarkStore.accessFolder(containing: media)
        return (try? FileManager.default.contentsOfDirectory(at: media.deletingLastPathComponent(),
                                                             includingPropertiesForKeys: nil)) != nil
    }

    /// External files sitting next to the media (Movie.srt, Movie.en.srt …) plus embedded text tracks.
    static func discover(for media: URL) async -> [SubtitleSource] {
        var found: [SubtitleSource] = []
        let base = media.deletingPathExtension().lastPathComponent.lowercased()
        let dir = media.deletingLastPathComponent()
        BookmarkStore.accessFolder(containing: media)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where fileExtensions.contains(f.pathExtension.lowercased())
            && f.deletingPathExtension().lastPathComponent.lowercased().hasPrefix(base) {
            found.append(SubtitleSource(kind: .file(f), name: "外挂 · \(f.lastPathComponent)",
                                        isEnglish: looksEnglish(f.lastPathComponent)))
        }
        #if os(macOS)
        if let probed = await probeEmbedded(media) {
            found += probed
            return found
        }
        #endif
        found += await avEmbedded(media)
        return found
    }

    static func load(_ source: SubtitleSource, media: URL) async throws -> [Cue] {
        switch source.kind {
        case .file(let url):
            let ext = url.pathExtension.lowercased()
            let text = SubtitleParser.decode(try Data(contentsOf: url))
            return ext == "ass" || ext == "ssa" ? SubtitleParser.parseASS(text) : SubtitleParser.parse(text)
        case .ffmpegStream(let index):
            #if os(macOS)
            return try await ffmpegToCues(input: media, map: "0:\(index)")
            #else
            _ = index
            return []
            #endif
        case .avTrack(let index):
            return try await readAVTrack(media: media, trackIndex: index)
        }
    }

    /// 2 = Simplified Chinese, 1 = other Chinese (Traditional, Cantonese…), 0 = not Chinese.
    static func chineseRank(_ s: String) -> Int {
        let l = s.lowercased()
        let tokens = Set(l.split(whereSeparator: { !$0.isLetter }).map(String.init))
        let isChinese = !tokens.isDisjoint(with: ["chi", "zho", "zh", "chinese", "chs", "cht", "hans", "hant", "cn", "yue"])
            || l.contains("中") || l.contains("简") || l.contains("繁")
        guard isChinese else { return 0 }
        let simplified = l.contains("simplified") || l.contains("简") || l.contains("hans")
            || !tokens.isDisjoint(with: ["chs", "sc", "cn"])
        let traditional = l.contains("traditional") || l.contains("繁") || l.contains("hant")
            || l.contains("yue") || l.contains("cantonese") || !tokens.isDisjoint(with: ["cht", "tc", "tw", "hk"])
        return simplified || !traditional ? 2 : 1
    }

    /// Best default translation track: Simplified Chinese first, then any Chinese.
    static func defaultTranslation(in sources: [SubtitleSource], excluding mainID: String?) -> SubtitleSource? {
        let candidates = sources.filter { $0.id != mainID }
        if let s = candidates.first(where: { chineseRank($0.name) == 2 && !$0.name.lowercased().contains("yue") }) { return s }
        return candidates.first { chineseRank($0.name) > 0 }
    }

    /// For each main cue, the translation text overlapping it in time (translation tracks are cut differently).
    static func align(_ main: [Cue], with translation: [Cue]) -> [String] {
        guard !translation.isEmpty else { return Array(repeating: "", count: main.count) }
        return main.map { cue in
            guard var i = translation.lastIndex(startingAtOrBefore: cue.end - 0.05) else { return "" }
            var parts: [String] = []
            while i >= 0, translation[i].end > cue.start {
                let t = translation[i]
                let overlap = min(t.end, cue.end) - max(t.start, cue.start)
                if overlap >= min(0.25, 0.4 * (t.end - t.start)) { parts.append(t.text) }
                i -= 1
            }
            return parts.reversed().joined(separator: " ")
        }
    }

    static func looksEnglish(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.contains("eng") || l.contains(".en.") || l.contains(".en-") || l.hasSuffix(".en")
            || l.contains("english") || l == "en"
    }

    #if os(macOS)
    // ffprobe path: lists every text subtitle stream (mkv, mp4, mov …)
    private struct Probe: Decodable {
        struct Stream: Decodable { let index: Int; let codec_name: String?; let tags: [String: String]? }
        let streams: [Stream]
    }

    static func probeEmbedded(_ media: URL) async -> [SubtitleSource]? {
        guard let ffprobe = Tools.ffprobe,
              let r = try? await Tools.run(ffprobe, ["-v", "error", "-select_streams", "s",
                                                     "-show_entries", "stream=index,codec_name:stream_tags=language,title",
                                                     "-of", "json", media.path]),
              r.status == 0, let probe = try? JSONDecoder().decode(Probe.self, from: r.out) else { return nil }
        return probe.streams.compactMap { s in
            guard textCodecs.contains(s.codec_name ?? "") else { return nil }   // skip PGS/VobSub images
            let lang = s.tags?["language"] ?? ""
            let title = s.tags?["title"] ?? ""
            let label = [lang, title].filter { !$0.isEmpty }.joined(separator: " · ")
            return SubtitleSource(kind: .ffmpegStream(s.index),
                                  name: "内封 #\(s.index)" + (label.isEmpty ? "" : " · \(label)"),
                                  isEnglish: looksEnglish(lang) || looksEnglish(title))
        }
    }

    static func ffmpegToCues(input: URL, map: String?) async throws -> [Cue] {
        guard let ffmpeg = Tools.ffmpeg else { throw AppError("读取这种字幕需要 ffmpeg（brew install ffmpeg）") }
        var args = ["-nostdin", "-v", "error", "-i", input.path]
        if let map { args += ["-map", map] }
        args += ["-f", "srt", "-"]
        let r = try await Tools.run(ffmpeg, args)
        guard r.status == 0 else { throw AppError("字幕抽取失败：" + String(decoding: r.err, as: UTF8.self)) }
        return SubtitleParser.parse(SubtitleParser.decode(r.out))
    }

    #endif

    // AVFoundation path (iOS, or Mac without ffmpeg): tx3g text tracks in mp4/mov/m4v
    static func avTracks(_ asset: AVURLAsset) async -> [AVAssetTrack] {
        let a = (try? await asset.loadTracks(withMediaType: .subtitle)) ?? []
        let b = (try? await asset.loadTracks(withMediaType: .text)) ?? []
        return a + b
    }

    static func avEmbedded(_ media: URL) async -> [SubtitleSource] {
        let tracks = await avTracks(AVURLAsset(url: media))
        var out: [SubtitleSource] = []
        for (i, t) in tracks.enumerated() {
            let lang = (try? await t.load(.languageCode)) ?? ""
            out.append(SubtitleSource(kind: .avTrack(i), name: "内封 \(i + 1)" + (lang.isEmpty ? "" : " · \(lang)"),
                                      isEnglish: looksEnglish(lang)))
        }
        return out
    }

    static func readAVTrack(media: URL, trackIndex: Int) async throws -> [Cue] {
        let asset = AVURLAsset(url: media)
        let tracks = await avTracks(asset)
        guard tracks.indices.contains(trackIndex) else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[trackIndex], outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AppError("无法读取内封字幕") }
        var raw: [(Double, Double, String)] = []
        while let sb = output.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(bb)
            guard len > 2 else { continue }
            var data = Data(count: len)
            data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            let textLen = Int(data[0]) << 8 | Int(data[1])   // tx3g: UInt16 BE length + UTF-8 text
            guard textLen > 0, textLen + 2 <= len else { continue }
            let start = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            let dur = CMSampleBufferGetDuration(sb).seconds
            raw.append((start, start + dur, String(decoding: data[2 ..< 2 + textLen], as: UTF8.self)))
        }
        return SubtitleParser.normalize(raw.map { ($0.0, $0.1, SubtitleParser.clean($0.2)) })
    }
}
