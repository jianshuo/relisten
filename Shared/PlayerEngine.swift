#if os(macOS)
import AppKit
#else
import UIKit
#endif
import AVFoundation
import Combine

/// Pure sentence state machine: which cue we're "on", and what to do when it ends.
/// Kept free of AVPlayer so it can be unit-tested.
struct SentenceTracker {
    enum Decision: Equatable { case none, loopBack(Int), pause }

    var cues: [Cue]
    private(set) var focus: Int?
    private(set) var pass = 1

    init(cues: [Cue]) { self.cues = cues }

    /// Manual navigation (jump, replay, scrub) starts a fresh pass on that cue.
    mutating func jump(to index: Int?) {
        focus = index
        pass = 1
    }

    mutating func countLoop() { pass += 1 }

    /// Called on every tick while playing, with the previous and current playhead.
    mutating func advance(from last: Double, to t: Double, loop: Bool, loopCount: Int, pauseEach: Bool, leadIn: Double) -> Decision {
        if let f = focus, cues.indices.contains(f) {
            let end = cues[f].end
            if last < end && t >= end {
                if loop && (loopCount == 0 || pass < loopCount) { return .loopBack(f) }
                if pauseEach { return .pause }
            }
        }
        if let idx = cues.lastIndex(startingAtOrBefore: t), idx != focus {
            // Still in the lead-in just before the focused cue: don't fall back to the previous one.
            if let f = focus, idx < f, cues.indices.contains(f), t >= cues[f].start - leadIn - 0.3 { return .none }
            focus = idx
            pass = 1
        }
        return .none
    }
}

@MainActor
final class PlaybackClock: ObservableObject {
    @Published var time: Double = 0
}

@MainActor
final class PlayerEngine: ObservableObject {
    static let shared = PlayerEngine()

    let player = AVPlayer()
    let clock = PlaybackClock()
    #if os(macOS)
    weak var mainWindow: NSWindow?
    #endif

    @Published private(set) var mediaURL: URL?
    @Published private(set) var hasVideo = false
    @Published private(set) var duration: Double = 0
    @Published private(set) var cues: [Cue] = []
    @Published private(set) var sources: [SubtitleSource] = []
    @Published private(set) var sourceID: String?
    @Published private(set) var focusIndex: Int?
    @Published private(set) var loopPass = 1
    @Published private(set) var isPlaying = false
    @Published private(set) var speed: Float = 1.0
    @Published private(set) var loading: String?
    @Published private(set) var notice: String?
    @Published private(set) var toast: String?
    /// Sandbox hasn't been granted the media's folder, so sibling .srt files are invisible.
    @Published private(set) var needsFolderAccess = false
    @Published var loopEnabled = false
    @Published var pauseAfterEach = false
    @Published var blindMode: Bool
    @Published var revealHeld = false
    /// Fragment loop inside a sentence: `fragment` is the active A–B range, `fragmentStart` a pending A mark.
    @Published private(set) var fragment: ClosedRange<Double>?
    @Published private(set) var fragmentStart: Double?
    @Published private(set) var fragmentPass = 1
    @Published private(set) var translationSourceID: String?
    @Published private(set) var translationLines: [String] = []   // aligned 1:1 with cues
    @Published var translationHeld = false
    @Published var showTranslation = false

    var subtitleVisible: Bool { !blindMode || revealHeld }
    var translationVisible: Bool { (showTranslation || translationHeld) && translationSourceID != nil }
    var focusTranslation: String? {
        focusIndex.flatMap { translationLines.indices.contains($0) ? translationLines[$0] : nil }.flatMap { $0.isEmpty ? nil : $0 }
    }
    private var translationCues: [Cue] = []
    /// Embedded subtitles are read from here: the original, or its converted copy once the original is deleted.
    private var subtitleMedia: URL?
    var focusCue: Cue? { focusIndex.flatMap { cues.indices.contains($0) ? cues[$0] : nil } }

    private var tracker = SentenceTracker(cues: [])
    private var lastTick = 0.0
    private var seekGeneration = 0
    private var seeking = false
    private var lastSaved = 0.0
    private var toastTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?

    private init() {
        Prefs.register()
        blindMode = Prefs.blindByDefault
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 50), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] p, _ in
            let playing = p.timeControlStatus != .paused
            DispatchQueue.main.async { self?.isPlaying = playing }
        }
        #if os(macOS)
        let resign = NSWindow.didResignKeyNotification
        #else
        let resign = UIApplication.willResignActiveNotification
        configureAudioSession()
        #endif
        NotificationCenter.default.addObserver(forName: resign, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.revealHeld = false; self?.translationHeld = false }   // never get stuck "revealed" if the key-up is lost
        }
    }

    #if os(iOS)
    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
    }
    #endif

    // MARK: Tick

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        clock.time = t
        if seeking { return }
        defer { lastTick = t }
        guard player.rate != 0 else { return }
        if let fr = fragment {
            if t >= fr.upperBound {
                fragmentPass += 1
                seek(to: fr.lowerBound) { [weak self] in self?.play() }
            }
            return
        }
        guard !cues.isEmpty else { return }
        let decision = tracker.advance(from: lastTick, to: t, loop: loopEnabled, loopCount: Prefs.loopCount,
                                       pauseEach: pauseAfterEach, leadIn: Prefs.leadIn)
        switch decision {
        case .none: break
        case .loopBack(let i):
            tracker.countLoop()
            seekToStart(of: i, play: true)
        case .pause:
            player.pause()
        }
        syncFromTracker()
        if abs(t - lastSaved) > 2 { savePosition() }
    }

    private func syncFromTracker() {
        if focusIndex != tracker.focus { focusIndex = tracker.focus }
        if loopPass != tracker.pass { loopPass = tracker.pass }
    }

    // MARK: Actions

    func perform(_ action: PlayerAction) {
        guard mediaURL != nil else { return }
        switch action {
        case .playPause: isPlaying ? player.pause() : play()
        case .prevSentence: goToSentence((focusIndex ?? 1) - 1)
        case .nextSentence: goToSentence((focusIndex ?? -1) + 1)
        case .replaySentence: goToSentence(focusIndex ?? 0)
        case .rewind: jump(to: clock.time - Prefs.rewindSeconds)
        case .forward: jump(to: clock.time + Prefs.rewindSeconds)
        case .toggleLoop:
            loopEnabled.toggle()
            tracker.jump(to: tracker.focus)
            syncFromTracker()
            showToast(loopEnabled ? "单句循环：开（\(Prefs.loopCount == 0 ? "无限" : "\(Prefs.loopCount) 遍")）" : "单句循环：关")
        case .togglePauseMode:
            pauseAfterEach.toggle()
            showToast(pauseAfterEach ? "逐句暂停：开" : "逐句暂停：关")
        case .revealHold: revealHeld = true
        case .loopRecent: loopRecent()
        case .markFragment: markFragment()
        case .clearFragment: clearFragment()
        case .translationHold:
            translationHeld = true
            if translationSourceID == nil { showToast("没有可用的翻译字幕") }
        case .toggleTranslation:
            showTranslation.toggle()
            showToast(translationSourceID == nil ? "没有可用的翻译字幕" : (showTranslation ? "翻译常显：开" : "翻译常显：关"))
        case .toggleBlind:
            blindMode.toggle()
            showToast(blindMode ? "盲听模式" : "字幕常显")
        case .slower: setSpeed(speed - 0.1)
        case .faster: setSpeed(speed + 0.1)
        case .resetSpeed: setSpeed(1.0)
        case .favorite: toggleFavorite()
        }
    }

    /// Launch-argument-only screenshot states (`-RelistenDemo a|b|c`); never reachable from the UI.
    private func applyDemo(_ mode: String) {
        func park(on index: Int) {
            guard cues.indices.contains(index) else { return }
            tracker.jump(to: index)
            syncFromTracker()
            seek(to: cues[index].start + 0.4)
            player.pause()
        }
        #if os(macOS)
        mainWindow?.setFrame(NSRect(x: 80, y: 120, width: 1440, height: 860), display: true)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
        #endif
        switch mode {
        case "a":
            blindMode = false; showTranslation = true; loopEnabled = true
            park(on: 8); tracker.countLoop(); syncFromTracker()
        case "b":
            blindMode = true; showTranslation = false; pauseAfterEach = true
            park(on: 4)
        case "c":
            blindMode = false; showTranslation = true; setSpeed(0.75)
            park(on: 11)
            let start = cues[11].start
            fragment = (start + 0.6) ... (start + 2.4)
            fragmentPass = 4
            toast = nil
        default: break
        }
    }

    // MARK: Fragment loop

    /// "Didn't catch that": loop the last few seconds, over and over.
    func loopRecent() {
        if fragment != nil || fragmentStart != nil { clearFragment(); return }
        let end = clock.time
        startFragment(max(0, end - Prefs.rewindSeconds) ... end)
    }

    /// First press marks A, second press marks B and starts looping, third press stops.
    func markFragment() {
        if fragment != nil { clearFragment(); return }
        guard let a = fragmentStart else {
            fragmentStart = clock.time
            showToast("已标记起点，播放到终点时再\(actionHint(.markFragment))")
            return
        }
        let b = clock.time
        guard abs(b - a) >= 0.3 else { showToast("片段太短了"); return }
        startFragment(min(a, b) ... max(a, b))
    }

    func clearFragment() {
        guard fragment != nil || fragmentStart != nil else { return }
        let wasLooping = fragment != nil
        fragment = nil
        fragmentStart = nil
        if wasLooping { showToast("片段循环已结束") }
    }

    private func startFragment(_ range: ClosedRange<Double>) {
        fragmentStart = nil
        fragment = range
        fragmentPass = 1
        showToast(String(format: "片段循环 %.1f 秒", range.upperBound - range.lowerBound))
        seek(to: range.lowerBound) { [weak self] in self?.play() }
    }

    func isHolding(_ action: PlayerAction) -> Bool {
        action == .revealHold ? revealHeld : action == .translationHold ? translationHeld : false
    }

    func release(_ action: PlayerAction) {
        if action == .revealHold { revealHeld = false }
        if action == .translationHold { translationHeld = false }
    }

    func play() {
        if duration > 0, clock.time >= duration - 0.1 { seek(to: 0) }
        player.playImmediately(atRate: speed)
    }

    func goToSentence(_ index: Int) {
        guard cues.indices.contains(index) else { return }
        clearFragment()
        tracker.jump(to: index)
        syncFromTracker()
        seekToStart(of: index, play: true)
    }

    /// Absolute seek (rewind/forward keys, timeline scrub). Keeps play/pause state.
    func jump(to seconds: Double) {
        clearFragment()
        let target = min(max(0, seconds), max(0, duration - 0.05))
        tracker.jump(to: cues.lastIndex(startingAtOrBefore: target) ?? (cues.isEmpty ? nil : 0))
        syncFromTracker()
        seek(to: target)
    }

    func setSpeed(_ value: Float) {
        let v = min(2.0, max(0.5, (value * 20).rounded() / 20))
        speed = v
        player.defaultRate = v
        if player.rate != 0 { player.rate = v }
        showToast(String(format: "速度 %.2gx", v))
    }

    func toggleFavorite() {
        guard let url = mediaURL, let cue = focusCue else { return }
        let on = FavoritesStore.shared.toggle(path: url.path, cue: cue)
        showToast(on ? "★ 已收藏这句" : "已取消收藏")
    }

    private func seekToStart(of index: Int, play: Bool) {
        seek(to: max(0, cues[index].start - Prefs.leadIn)) { [weak self] in
            if play { self?.play() }
        }
    }

    private func seek(to seconds: Double, then: (() -> Void)? = nil) {
        seekGeneration += 1
        let generation = seekGeneration
        seeking = true
        lastTick = seconds
        clock.time = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, generation == self.seekGeneration else { return }
                self.seeking = false
                self.lastTick = seconds
                then?()
            }
        }
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // MARK: Opening media & subtitles

    /// Reopen a file by path (recents, favorites) through its security-scoped bookmark.
    func open(path: String, then: (() -> Void)? = nil) {
        open(BookmarkStore.access(path) ?? URL(fileURLWithPath: path), then: then)
    }

    #if os(macOS)
    /// Ask the user to grant the media's folder so sibling subtitle files can be read.
    func grantFolderAccess() {
        guard let url = mediaURL else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = url.deletingLastPathComponent()
        panel.prompt = "允许读取"
        panel.message = "允许 Relisten 读取这个文件夹，就能自动加载视频旁边的字幕文件（.srt / .vtt / .ass）"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        folderGranted(folder)
    }
    #endif

    /// The user picked the media's folder (Mac open panel / iOS folder picker): load sibling subtitles.
    func folderGranted(_ folder: URL) {
        guard let url = mediaURL else { return }
        _ = folder.startAccessingSecurityScopedResource()
        BookmarkStore.remember(folder)
        Task {
            let found = await SubtitleLoader.discover(for: url)
            for s in found where !sources.contains(s) { sources.append(s) }
            needsFolderAccess = !SubtitleLoader.canReadFolder(of: url)
            if sourceID == nil, let first = sources.first(where: \.isEnglish) ?? sources.first {
                await selectSource(first)
                notice = nil
            }
            if translationSourceID == nil {
                await selectTranslation(SubtitleLoader.defaultTranslation(in: sources, excluding: sourceID))
            }
        }
    }

    func open(_ url: URL, then: (() -> Void)? = nil) {
        #if os(iOS)
        _ = url.startAccessingSecurityScopedResource()   // Files app / share sheet hand us scoped URLs
        #endif
        BookmarkStore.remember(url)
        if SubtitleLoader.fileExtensions.contains(url.pathExtension.lowercased()) {
            loadExternalSubtitle(url)
            return
        }
        Task {
            await load(url)
            then?()
        }
    }

    private func load(_ url: URL) async {
        savePosition()
        player.pause()
        loading = "正在打开 \(url.lastPathComponent)…"
        defer { loading = nil }
        do {
            let playURL = try await MediaPreparer.playableURL(for: url) { [weak self] message in
                Task { @MainActor in self?.loading = message }
            }
            let asset = AVURLAsset(url: playURL)
            let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            let length = (try? await asset.load(.duration))?.seconds ?? 0
            let originalGone = !FileManager.default.fileExists(atPath: url.path)
            subtitleMedia = originalGone ? playURL : url
            var found = await SubtitleLoader.discover(for: url)
            if originalGone {   // embedded tracks now come from the converted copy
                found += await SubtitleLoader.discover(for: playURL).filter { if case .file = $0.kind { false } else { true } }
            }
            needsFolderAccess = !originalGone && !SubtitleLoader.canReadFolder(of: url)

            let item = AVPlayerItem(asset: asset)
            item.audioTimePitchAlgorithm = .timeDomain   // speed changes keep the voice's pitch
            // Never let AVPlayer burn embedded subtitles onto the video: that would defeat blind mode.
            player.appliesMediaSelectionCriteriaAutomatically = false
            if let legible = try? await asset.loadMediaSelectionGroup(for: .legible) {
                item.select(nil, in: legible)
            }
            player.replaceCurrentItem(with: item)
            player.defaultRate = speed
            mediaURL = url
            hasVideo = !videoTracks.isEmpty
            duration = length.isFinite ? length : 0
            sources = found
            notice = nil
            ResumeStore.touch(url.path)
            #if os(macOS)
            mainWindow?.title = url.lastPathComponent
            #endif

            translationCues = []
            translationSourceID = nil
            if let preferred = found.first(where: \.isEnglish) ?? found.first {
                await selectSource(preferred)
                await selectTranslation(SubtitleLoader.defaultTranslation(in: found, excluding: preferred.id))
            } else {
                setCues([], sourceID: nil)
                notice = needsFolderAccess
                    ? "没有内封字幕。点右侧「允许读取同目录的字幕文件」，或直接把字幕文件拖进窗口"
                    : "没找到字幕：把同名的 .srt / .vtt 放在文件旁边，或直接把字幕文件拖进窗口"
            }

            let saved = ResumeStore.position(for: url.path) ?? 0
            let start = (saved > 1 && saved < duration - 3) ? saved : 0
            jump(to: start)
            if start > 0 { showToast("从上次的 \(formatTime(start)) 继续") }
            if originalGone { showToast("原文件已删除，正在播放转换好的副本") }
            if let demo = UserDefaults.standard.string(forKey: "RelistenDemo") { applyDemo(demo) }
        } catch {
            notice = error.localizedDescription
        }
    }

    func selectSource(_ source: SubtitleSource) async {
        guard let url = subtitleMedia ?? mediaURL else { return }
        do {
            let loaded = try await SubtitleLoader.load(source, media: url)
            setCues(loaded, sourceID: source.id)
            notice = loaded.isEmpty ? "这条字幕里没有可用的文字" : nil
        } catch {
            notice = error.localizedDescription
        }
    }

    /// nil turns the translation off.
    func selectTranslation(_ source: SubtitleSource?) async {
        guard let url = subtitleMedia ?? mediaURL, let source else {
            translationCues = []
            translationSourceID = nil
            realignTranslation()
            return
        }
        do {
            translationCues = try await SubtitleLoader.load(source, media: url)
            translationSourceID = source.id
        } catch {
            translationCues = []
            translationSourceID = nil
            showToast("翻译字幕读取失败")
        }
        realignTranslation()
    }

    private func realignTranslation() {
        translationLines = SubtitleLoader.align(cues, with: translationCues)
    }

    func loadExternalSubtitle(_ file: URL) {
        guard mediaURL != nil else { notice = "先打开视频或音频，再载入字幕"; return }
        let source = SubtitleSource(kind: .file(file), name: "外挂 · \(file.lastPathComponent)",
                                    isEnglish: SubtitleLoader.looksEnglish(file.lastPathComponent))
        if !sources.contains(source) { sources.append(source) }
        Task {
            // A dropped Chinese file becomes the translation; anything else becomes the main track.
            if SubtitleLoader.chineseRank(file.lastPathComponent) > 0, sourceID != nil {
                await selectTranslation(source)
                showTranslation = true
            } else {
                await selectSource(source)
            }
        }
    }

    private func setCues(_ newCues: [Cue], sourceID: String?) {
        cues = newCues
        self.sourceID = sourceID
        tracker = SentenceTracker(cues: newCues)
        realignTranslation()
        tracker.jump(to: newCues.lastIndex(startingAtOrBefore: clock.time) ?? (newCues.isEmpty ? nil : 0))
        syncFromTracker()
    }

    func playFavorite(_ fav: Favorite) {
        #if os(macOS)
        mainWindow?.makeKeyAndOrderFront(nil)
        #endif
        let go = { [weak self] in
            guard let self else { return }
            let index = self.cues.firstIndex { abs($0.start - fav.start) < 0.01 }
                ?? self.cues.lastIndex(startingAtOrBefore: fav.start)
            if let index { self.goToSentence(index) }
        }
        if mediaURL?.path == fav.path { go() } else { open(path: fav.path, then: go) }
    }

    /// Back to the library (iOS): stop playback and forget the current file's state.
    func closeMedia() {
        savePosition()
        player.pause()
        player.replaceCurrentItem(with: nil)
        mediaURL = nil
        subtitleMedia = nil
        hasVideo = false
        sources = []
        translationCues = []
        translationSourceID = nil
        fragment = nil
        fragmentStart = nil
        notice = nil
        needsFolderAccess = false
        setCues([], sourceID: nil)
    }

    func savePosition() {
        guard let url = mediaURL else { return }
        ResumeStore.save(clock.time, for: url.path)
        lastSaved = clock.time
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "--:--" }
    let s = Int(max(0, seconds))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                     : String(format: "%02d:%02d", s / 60, s % 60)
}
