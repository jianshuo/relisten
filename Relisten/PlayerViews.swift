import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var engine: PlayerEngine
    @State private var showList = true

    var body: some View {
        Group {
            if engine.mediaURL == nil {
                EmptyStateView()
            } else {
                HSplitView {
                    VStack(spacing: 0) {
                        MediaArea()
                        SubtitlePanel()
                        Divider()
                        ControlBar(showList: $showList)
                    }
                    .frame(minWidth: 520)
                    if showList {
                        CueListView().frame(minWidth: 260, idealWidth: 340, maxWidth: 520)
                    }
                }
            }
        }
        .frame(minWidth: 820, minHeight: 540)
        .background(WindowAccessor { engine.mainWindow = $0 })
        .overlay(alignment: .top) {
            if let toast = engine.toast {
                Text(toast)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 12)
                    .transition(.opacity)
            }
        }
        .overlay {
            if let loading = engine.loading {
                ProgressView(loading).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .animation(.easeOut(duration: 0.15), value: engine.toast)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { engine.open(url) } }
            }
            return true
        }
    }
}

// MARK: - Video / audio area

struct MediaArea: View {
    @EnvironmentObject var engine: PlayerEngine

    var body: some View {
        ZStack {
            Color.black
            if engine.hasVideo {
                VideoView(player: engine.player)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "waveform").font(.system(size: 54, weight: .light))
                    Text(engine.mediaURL?.lastPathComponent ?? "").font(.callout)
                }
                .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(minHeight: engine.hasVideo ? 220 : 120)
        .layoutPriority(1)
        .onTapGesture { engine.perform(.playPause) }
    }
}

struct VideoView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        return v
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}

// MARK: - Big current sentence

struct SubtitlePanel: View {
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var shortcuts: ShortcutStore

    var body: some View {
        VStack(spacing: 8) {
            if let cue = engine.focusCue {
                Text(cue.text)
                    .font(.system(size: 26, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .minimumScaleFactor(0.6)
                    .textSelection(.enabled)
                    .blur(radius: engine.subtitleVisible ? 0 : 9)
                    .animation(.easeOut(duration: 0.12), value: engine.subtitleVisible)
                if engine.translationVisible {
                    Text(engine.focusTranslation ?? "（这句没有对应的翻译）")
                        .font(.system(size: 19))
                        .foregroundStyle(engine.focusTranslation == nil ? .tertiary : .secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                        .textSelection(.enabled)
                }
            } else {
                Text(engine.notice ?? "按 \(shortcuts.label(.playPause)) 开始播放")
                    .font(.title3).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 14) {
                if let i = engine.focusIndex, !engine.cues.isEmpty {
                    Text("第 \(i + 1) / \(engine.cues.count) 句")
                }
                if engine.blindMode {
                    Label(engine.revealHeld ? "字幕已显示" : "盲听中 · 按住 \(shortcuts.label(.revealHold)) 看字幕",
                          systemImage: engine.revealHeld ? "eye" : "eye.slash")
                }
                if engine.translationSourceID != nil && !engine.showTranslation {
                    Label("按住 \(shortcuts.label(.translationHold)) 看翻译", systemImage: "character.bubble")
                }
                if let fr = engine.fragment {
                    Label(String(format: "片段循环 %.1f 秒 · 第 %d 遍 · %@ 退出", fr.upperBound - fr.lowerBound,
                                 engine.fragmentPass, shortcuts.label(.clearFragment)), systemImage: "scissors")
                        .foregroundStyle(Color.accentColor)
                } else if engine.fragmentStart != nil {
                    Label("已标记起点 · 再按 \(shortcuts.label(.markFragment)) 设终点", systemImage: "scissors")
                        .foregroundStyle(Color.accentColor)
                }
                if engine.loopEnabled {
                    Label("循环 \(engine.loopPass)/\(Prefs.loopCount == 0 ? "∞" : "\(Prefs.loopCount)")", systemImage: "repeat.1")
                        .foregroundStyle(Color.accentColor)
                }
                if engine.pauseAfterEach {
                    Label("逐句暂停", systemImage: "pause.circle").foregroundStyle(Color.accentColor)
                }
                if engine.speed != 1 { Text(String(format: "%.2gx", engine.speed)) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 230)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - Controls

struct ControlBar: View {
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var shortcuts: ShortcutStore
    @EnvironmentObject var favorites: FavoritesStore
    @Binding var showList: Bool

    var body: some View {
        VStack(spacing: 8) {
            TimelineSlider(clock: engine.clock)
            HStack(spacing: 6) {
                button("backward.end.fill", .prevSentence)
                button("gobackward", .rewind, label: "后退 \(Int(Prefs.rewindSeconds)) 秒")
                Button { engine.perform(.playPause) } label: {
                    Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 30))
                }
                .buttonStyle(.borderless)
                .help("播放 / 暂停（\(shortcuts.label(.playPause))）")
                button("arrow.counterclockwise", .replaySentence)
                button("forward.end.fill", .nextSentence)

                Divider().frame(height: 20).padding(.horizontal, 6)

                toggle("repeat.1", .toggleLoop, on: engine.loopEnabled)
                toggle("scissors", .loopRecent, on: engine.fragment != nil || engine.fragmentStart != nil)
                toggle("pause.circle", .togglePauseMode, on: engine.pauseAfterEach)
                toggle(engine.blindMode ? "eye.slash" : "eye", .toggleBlind, on: engine.blindMode)
                toggle("character.bubble", .toggleTranslation, on: engine.showTranslation)
                    .disabled(engine.translationSourceID == nil)
                toggle(isFavorite ? "star.fill" : "star", .favorite, on: isFavorite)

                Spacer()

                Menu {
                    ForEach([0.5, 0.6, 0.7, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0], id: \.self) { v in
                        Button(String(format: "%.2gx", v)) { engine.setSpeed(Float(v)) }
                    }
                } label: {
                    Text(String(format: "%.2gx", engine.speed)).monospacedDigit()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("速度（\(shortcuts.label(.slower)) 减速 / \(shortcuts.label(.faster)) 加速 / \(shortcuts.label(.resetSpeed)) 复原）")

                Button { showList.toggle() } label: { Image(systemName: "sidebar.right") }
                    .buttonStyle(.borderless)
                    .help("显示 / 隐藏句子列表")
            }
            .font(.system(size: 16))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .focusable(false)
    }

    private var isFavorite: Bool {
        guard let url = engine.mediaURL, let cue = engine.focusCue else { return false }
        return favorites.contains(path: url.path, cue: cue)
    }

    private func button(_ icon: String, _ action: PlayerAction, label: String? = nil) -> some View {
        Button { engine.perform(action) } label: { Image(systemName: icon).frame(width: 26, height: 24) }
            .buttonStyle(.borderless)
            .help("\(label ?? action.title)（\(shortcuts.label(action))）")
    }

    private func toggle(_ icon: String, _ action: PlayerAction, on: Bool) -> some View {
        Button { engine.perform(action) } label: {
            Image(systemName: icon)
                .frame(width: 28, height: 24)
                .foregroundStyle(on ? Color.accentColor : Color.primary)
                .background(on ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.borderless)
        .help("\(action.title)（\(shortcuts.label(action))）")
    }
}

struct TimelineSlider: View {
    @EnvironmentObject var engine: PlayerEngine
    @ObservedObject var clock: PlaybackClock
    @State private var dragValue: Double?

    var body: some View {
        HStack(spacing: 10) {
            Text(formatTime(dragValue ?? clock.time)).monospacedDigit()
            Slider(value: Binding(get: { dragValue ?? clock.time }, set: { dragValue = $0 }),
                   in: 0 ... max(engine.duration, 0.1)) { editing in
                if !editing, let v = dragValue {
                    engine.jump(to: v)
                    dragValue = nil
                }
            }
            .controlSize(.small)
            Text(formatTime(engine.duration)).monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Sentence list

struct CueListView: View {
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var favorites: FavoritesStore
    @State private var onlyFavorites = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $onlyFavorites) {
                    Text("全部 \(engine.cues.count)").tag(false)
                    Text("收藏").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if engine.sources.count > 1 {
                    Picker("", selection: Binding(
                        get: { engine.translationSourceID ?? "" },
                        set: { id in Task { await engine.selectTranslation(engine.sources.first { $0.id == id }) } }
                    )) {
                        Text("无翻译").tag("")
                        ForEach(engine.sources) { Text("译：" + $0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 150)
                    .help("翻译轨道")
                    Picker("", selection: Binding(
                        get: { engine.sourceID ?? "" },
                        set: { id in if let s = engine.sources.first(where: { $0.id == id }) { Task { await engine.selectSource(s) } } }
                    )) {
                        ForEach(engine.sources) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 170)
                    .help("字幕轨道")
                }
            }
            .padding(8)
            Divider()
            ScrollViewReader { proxy in
                List(visibleCues) { cue in
                    CueRow(cue: cue,
                           translation: engine.translationVisible && engine.translationLines.indices.contains(cue.id)
                               ? engine.translationLines[cue.id] : "",
                           isCurrent: cue.id == engine.focusIndex,
                           isFavorite: isFavorite(cue),
                           visible: engine.subtitleVisible)
                        .id(cue.id)
                        .contentShape(Rectangle())
                        .onTapGesture { engine.goToSentence(cue.id) }
                        .contextMenu {
                            Button(isFavorite(cue) ? "取消收藏" : "收藏这句") {
                                if let url = engine.mediaURL { favorites.toggle(path: url.path, cue: cue) }
                            }
                            Button("复制文字") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(cue.text, forType: .string)
                            }
                        }
                }
                .listStyle(.plain)
                .onChange(of: engine.focusIndex) { _, index in
                    guard let index else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(index, anchor: .center) }
                }
            }
        }
        .focusable(false)
    }

    private var visibleCues: [Cue] {
        onlyFavorites ? engine.cues.filter(isFavorite) : engine.cues
    }

    private func isFavorite(_ cue: Cue) -> Bool {
        guard let url = engine.mediaURL else { return false }
        return favorites.contains(path: url.path, cue: cue)
    }
}

struct CueRow: View {
    let cue: Cue
    let translation: String
    let isCurrent: Bool
    let isFavorite: Bool
    let visible: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(formatTime(cue.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(cue.text)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .blur(radius: visible ? 0 : 5)
                if !translation.isEmpty {
                    Text(translation).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isFavorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(isCurrent ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var shortcuts: ShortcutStore

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "ear.and.waveform").font(.system(size: 56, weight: .light)).foregroundStyle(Color.accentColor)
            Text("把带字幕的视频或音频拖进来").font(.title2.weight(.semibold))
            Text("支持内封字幕和同名外挂 .srt / .vtt / .ass；也可以按 ⌘O 打开").foregroundStyle(.secondary)
            if let notice = engine.notice { Text(notice).foregroundStyle(.red) }
            Button("打开文件…") { openPanel(engine) }.keyboardShortcut(.defaultAction)

            let recents = ResumeStore.recents
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("最近打开").font(.caption).foregroundStyle(.secondary)
                    ForEach(recents.prefix(6), id: \.self) { path in
                        Button((path as NSString).lastPathComponent) { engine.open(URL(fileURLWithPath: path)) }
                            .buttonStyle(.link)
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                ForEach([PlayerAction.playPause, .prevSentence, .nextSentence, .replaySentence, .rewind,
                         .toggleLoop, .loopRecent, .markFragment, .togglePauseMode, .revealHold, .translationHold, .slower, .faster, .favorite]) { a in
                    GridRow {
                        Text(shortcuts.label(a)).font(.callout.monospaced()).foregroundStyle(Color.accentColor)
                        Text(a.title).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
func openPanel(_ engine: PlayerEngine) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.movie, .audio, .audiovisualContent] +
        ["mkv", "webm", "srt", "vtt", "ass"].compactMap { UTType(filenameExtension: $0) }
    panel.allowsOtherFileTypes = true
    if panel.runModal() == .OK, let url = panel.url { engine.open(url) }
}

@MainActor
func openSubtitlePanel(_ engine: PlayerEngine) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = ["srt", "vtt", "ass", "ssa"].compactMap { UTType(filenameExtension: $0) }
    if panel.runModal() == .OK, let url = panel.url { engine.loadExternalSubtitle(url) }
}

struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { if let w = nsView.window { onWindow(w) } }
    }
}
