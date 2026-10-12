import XCTest
@testable import Relisten

final class SubtitleParserTests: XCTestCase {
    func testSRT() {
        let srt = """
        1
        00:00:01,000 --> 00:00:02,500
        <i>Hello</i> there.

        2
        00:00:03,000 --> 00:00:04,000
        How are
        you doing?
        """
        let cues = SubtitleParser.parse(srt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "Hello there.")
        XCTAssertEqual(cues[0].start, 1.0, accuracy: 0.001)
        XCTAssertEqual(cues[0].end, 2.5, accuracy: 0.001)
        XCTAssertEqual(cues[1].text, "How are\nyou doing?")
    }

    func testVTTWithSettingsAndCRLF() {
        let vtt = "WEBVTT\r\n\r\n00:01.000 --> 00:02.000 align:start position:0%\r\n<c.yellow>Short</c> form &amp; tags\r\n\r\n01:00:00.500 --> 01:00:01.000\r\nLate\r\n"
        let cues = SubtitleParser.parse(vtt)
        XCTAssertEqual(cues.map(\.text), ["Short form & tags", "Late"])
        XCTAssertEqual(cues[1].start, 3600.5, accuracy: 0.001)
    }

    func testRollingDuplicatesAndOverlapClamp() {
        let cues = SubtitleParser.normalize([
            (0, 2, "first line"),
            (1.5, 4, "first line\nsecond line"),
            (4, 4.01, "flash"),
        ])
        XCTAssertEqual(cues.map(\.text), ["first line", "second line"])
        XCTAssertEqual(cues[0].end, 1.5, accuracy: 0.001)   // clamped to next start
    }

    func testLastIndex() {
        let cues = SubtitleParser.normalize([(1, 2, "a"), (3, 4, "b"), (5, 6, "c")])
        XCTAssertNil(cues.lastIndex(startingAtOrBefore: 0.5))
        XCTAssertEqual(cues.lastIndex(startingAtOrBefore: 3), 1)
        XCTAssertEqual(cues.lastIndex(startingAtOrBefore: 4.5), 1)
        XCTAssertEqual(cues.lastIndex(startingAtOrBefore: 99), 2)
    }
}

final class TranslationTests: XCTestCase {
    func src(_ name: String) -> SubtitleSource {
        SubtitleSource(kind: .file(URL(fileURLWithPath: "/tmp/\(name)")), name: name, isEnglish: false)
    }

    func testChineseRank() {
        XCTAssertEqual(SubtitleLoader.chineseRank("内封 #6 · chi · Chinese Simplified"), 2)
        XCTAssertEqual(SubtitleLoader.chineseRank("内封 #7 · chi · Chinese Traditional"), 1)
        XCTAssertEqual(SubtitleLoader.chineseRank("内封 #8 · chi · Chinese Yue"), 1)
        XCTAssertEqual(SubtitleLoader.chineseRank("外挂 · Movie.zh-Hans.srt"), 2)
        XCTAssertEqual(SubtitleLoader.chineseRank("外挂 · Movie.简体.srt"), 2)
        XCTAssertEqual(SubtitleLoader.chineseRank("内封 #2 · eng · English"), 0)
        XCTAssertEqual(SubtitleLoader.chineseRank("内封 #3 · eng · English [SDH]"), 0)
    }

    func testDefaultTranslationPrefersSimplified() {
        let sources = [src("eng English"), src("chi Chinese Traditional"), src("chi Chinese Simplified")]
        XCTAssertEqual(SubtitleLoader.defaultTranslation(in: sources, excluding: sources[0].id)?.name, "chi Chinese Simplified")
        XCTAssertEqual(SubtitleLoader.defaultTranslation(in: Array(sources.prefix(2)), excluding: sources[0].id)?.name,
                       "chi Chinese Traditional")
        XCTAssertNil(SubtitleLoader.defaultTranslation(in: [sources[0]], excluding: sources[0].id))
    }

    func testAlignByOverlap() {
        let main = SubtitleParser.normalize([(1, 3, "Hello there."), (4, 6, "Second."), (10, 11, "Lonely.")])
        let zh = SubtitleParser.normalize([(1.1, 2, "你好"), (2, 3.1, "那边"), (3.0, 4.1, "边界"), (4.2, 6, "第二句")])
        XCTAssertEqual(SubtitleLoader.align(main, with: zh), ["你好 那边", "第二句", ""])
    }
}

final class SentenceTrackerTests: XCTestCase {
    let cues = SubtitleParser.normalize([(1, 2, "a"), (2, 3, "b"), (4, 5, "c")])

    func testFocusAdvancesNaturally() {
        var t = SentenceTracker(cues: cues)
        t.jump(to: 0)
        XCTAssertEqual(t.advance(from: 1.5, to: 2.02, loop: false, loopCount: 0, pauseEach: false, leadIn: 0.15), .none)
        XCTAssertEqual(t.focus, 1)
    }

    func testLoopThreeTimesThenContinue() {
        var t = SentenceTracker(cues: cues)
        t.jump(to: 0)
        for _ in 0..<2 {
            XCTAssertEqual(t.advance(from: 1.99, to: 2.01, loop: true, loopCount: 3, pauseEach: false, leadIn: 0.15), .loopBack(0))
            t.countLoop()
        }
        XCTAssertEqual(t.pass, 3)
        XCTAssertEqual(t.advance(from: 1.99, to: 2.01, loop: true, loopCount: 3, pauseEach: false, leadIn: 0.15), .none)
        XCTAssertEqual(t.focus, 1)
        XCTAssertEqual(t.pass, 1)
    }

    func testInfiniteLoop() {
        var t = SentenceTracker(cues: cues)
        t.jump(to: 2)
        for _ in 0..<20 {
            XCTAssertEqual(t.advance(from: 4.99, to: 5.01, loop: true, loopCount: 0, pauseEach: false, leadIn: 0.15), .loopBack(2))
            t.countLoop()
        }
    }

    func testPauseAfterEachSentence() {
        var t = SentenceTracker(cues: cues)
        t.jump(to: 0)
        XCTAssertEqual(t.advance(from: 1.99, to: 2.01, loop: false, loopCount: 0, pauseEach: true, leadIn: 0.15), .pause)
        XCTAssertEqual(t.focus, 0, "after an auto-pause, replay should still target the sentence just heard")
        // Resuming moves on to the next sentence without pausing again immediately.
        XCTAssertEqual(t.advance(from: 2.01, to: 2.03, loop: false, loopCount: 0, pauseEach: true, leadIn: 0.15), .none)
        XCTAssertEqual(t.focus, 1)
    }

    func testLeadInDoesNotTriggerPreviousCue() {
        var t = SentenceTracker(cues: cues)
        t.jump(to: 1)
        // Seeked to 1.85 (start 2.0 - leadIn); crossing cue 0's end at 2.0 must not loop cue 0.
        XCTAssertEqual(t.advance(from: 1.85, to: 1.9, loop: true, loopCount: 0, pauseEach: false, leadIn: 0.15), .none)
        XCTAssertEqual(t.focus, 1)
    }

    func testGapKeepsPreviousFocus() {
        var t = SentenceTracker(cues: cues)
        t.jump(to: 1)
        XCTAssertEqual(t.advance(from: 3.2, to: 3.5, loop: false, loopCount: 0, pauseEach: false, leadIn: 0.15), .none)
        XCTAssertEqual(t.focus, 1)
    }
}

/// Builds real media with ffmpeg and checks embedded-subtitle extraction through both paths.
final class EmbeddedSubtitleTests: XCTestCase {
    /// Copies a bundled fixture (built once with ffmpeg: 4 s of video + sine + 2 English cues) into a fresh dir.
    func makeMedia(ext: String, codec: String) throws -> URL {
        guard Tools.ffmpeg != nil else { throw XCTSkip("ffmpeg not available") }
        let bundle = Bundle(for: EmbeddedSubtitleTests.self)
        guard let fixture = bundle.url(forResource: "clip", withExtension: ext) else {
            XCTFail("missing fixture clip.\(ext)"); throw XCTSkip("fixture")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("clip.\(ext)")
        try FileManager.default.copyItem(at: fixture, to: out)
        return out
    }

    func testFFmpegPathOnMKV() async throws {
        let mkv = try makeMedia(ext: "mkv", codec: "srt")
        let sources = await SubtitleLoader.discover(for: mkv)
        XCTAssertEqual(sources.count, 1)
        XCTAssertTrue(sources[0].isEnglish)
        let cues = try await SubtitleLoader.load(sources[0], media: mkv)
        XCTAssertEqual(cues.map(\.text), ["First sentence.", "Second one."])
    }

    func testAVFoundationPathOnMP4() async throws {
        let mp4 = try makeMedia(ext: "mp4", codec: "mov_text")
        let sources = await SubtitleLoader.avEmbedded(mp4)
        XCTAssertEqual(sources.count, 1)
        let cues = try await SubtitleLoader.load(sources[0], media: mp4)
        XCTAssertEqual(cues.map(\.text), ["First sentence.", "Second one."])
        XCTAssertEqual(cues[1].start, 2.0, accuracy: 0.05)
    }

    func testMKVRemuxedToPlayableMP4() async throws {
        let mkv = try makeMedia(ext: "mkv", codec: "srt")
        let playable = try await MediaPreparer.playableURL(for: mkv) { _ in }
        XCTAssertEqual(playable.pathExtension, "mp4")
    }
}
