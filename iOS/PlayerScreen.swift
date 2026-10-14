import AVFoundation
import SwiftUI
import UIKit

struct PlayerScreen: View {
    @EnvironmentObject var engine: PlayerEngine
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var pickingFolder = false
    @State private var showFavorites = false
    @State private var showSettings = false
    @FocusState private var keyboardFocus: Bool

    var body: some View {
        Group {
            GeometryReader { geo in
                if sizeClass == .regular {
                    HStack(spacing: 0) {
                        ScrollView { mainColumn(width: geo.size.width - 380) }
                        Divider()
                        CueList().frame(width: 380)
                    }
                } else {
                    VStack(spacing: 0) {
                        mainColumn(width: geo.size.width)
                        Divider()
                        CueList()
                    }
                }
            }
        }
        .navigationTitle(engine.mediaURL?.deletingPathExtension().lastPathComponent ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { engine.closeMedia() } label: { Label("资料库", systemImage: "chevron.left") }
            }
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
        }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let folder) = result { engine.folderGranted(folder) }
        }
        .sheet(isPresented: $showFavorites) { FavoritesSheet() }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        // iPad with a hardware keyboard: the Mac's core keys.
        .focusable()
        .focused($keyboardFocus)
        .onAppear { keyboardFocus = true }
        .onKeyPress(keys: [.space, .leftArrow, .rightArrow, .downArrow]) { press in
            switch press.key {
            case .space: engine.perform(.playPause)
            case .leftArrow: engine.perform(press.modifiers.contains(.shift) ? .rewind : .prevSentence)
            case .rightArrow: engine.perform(press.modifiers.contains(.shift) ? .forward : .nextSentence)
            default: engine.perform(.replaySentence)
            }
            return .handled
        }
        .onKeyPress(characters: .letters) { press in
            let map: [String: PlayerAction] = ["l": .toggleLoop, "r": .loopRecent, "a": .markFragment,
                                               "p": .togglePauseMode, "t": .toggleBlind, "f": .favorite]
            guard let action = map[press.characters.lowercased()] else { return .ignored }
            engine.perform(action)
            return .handled
        }
        .onChange(of: engine.focusIndex) { _, _ in
            RemoteCommands.updateNowPlaying(title: engine.mediaURL?.lastPathComponent,
                                            sentence: engine.subtitleVisible ? engine.focusCue?.text : nil)
        }
    }

    /// The video gets a fixed 16:9 height from the available width; the sentence list takes what's left.
    private func mainColumn(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            MediaSurface().frame(height: engine.hasVideo ? width * 9 / 16 : 72)
            SubtitleCard()
            HoldButtons()
            ControlsArea()
        }
    }

    private var moreMenu: some View {
        Menu {
            if engine.sources.count > 0 {
                Picker("字幕轨道", selection: Binding(
                    get: { engine.sourceID ?? "" },
                    set: { id in if let s = engine.sources.first(where: { $0.id == id }) { Task { await engine.selectSource(s) } } }
                )) {
                    ForEach(engine.sources) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.menu)
                Picker("翻译轨道", selection: Binding(
                    get: { engine.translationSourceID ?? "" },
                    set: { id in Task { await engine.selectTranslation(engine.sources.first { $0.id == id }) } }
                )) {
                    Text("无翻译").tag("")
                    ForEach(engine.sources) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.menu)
            }
            if engine.needsFolderAccess {
                Button { pickingFolder = true } label: { Label("读取同目录的字幕文件…", systemImage: "folder.badge.plus") }
            }
            Divider()
            Button { engine.perform(.markFragment) } label: { Label("标记片段起点 / 终点", systemImage: "scissors") }
            Button { showFavorites = true } label: { Label("收藏的句子", systemImage: "star") }
            Button { showSettings = true } label: { Label("设置", systemImage: "gearshape") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
}

// MARK: - Video

struct MediaSurface: View {
    @EnvironmentObject var engine: PlayerEngine

    var body: some View {
        ZStack {
            Color.black
            if engine.hasVideo {
                PlayerLayerView(player: engine.player)
            } else {
                Image(systemName: "waveform").font(.system(size: 44, weight: .light)).foregroundStyle(.white.opacity(0.6))
            }
        }
        .onTapGesture { engine.perform(.playPause) }
    }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ uiView: LayerView, context: Context) {}
}

// MARK: - Sentence card: tap = replay, swipe = previous / next

struct SubtitleCard: View {
    @EnvironmentObject var engine: PlayerEngine

    var body: some View {
        VStack(spacing: 8) {
            if let cue = engine.focusCue {
                Text(cue.text)
                    .font(.system(size: 22, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .minimumScaleFactor(0.6)
                    .blur(radius: engine.subtitleVisible ? 0 : 8)
                    .animation(.easeOut(duration: 0.12), value: engine.subtitleVisible)
                if engine.translationVisible {
                    Text(engine.focusTranslation ?? "（这句没有对应的翻译）")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                }
            } else {
                Text(engine.notice ?? "点 ▶︎ 开始播放").font(.body).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            statusLine
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 130)
        .contentShape(Rectangle())
        .onTapGesture { engine.perform(.replaySentence); haptic() }
        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) else { return }
            engine.perform(value.translation.width < 0 ? .nextSentence : .prevSentence)
            haptic()
        })
    }

    private var statusLine: some View {
        HStack(spacing: 10) {
            if let i = engine.focusIndex, !engine.cues.isEmpty { Text("\(i + 1) / \(engine.cues.count)") }
            if let fr = engine.fragment {
                Label(String(format: "片段 %.1f 秒 · 第 %d 遍", fr.upperBound - fr.lowerBound, engine.fragmentPass),
                      systemImage: "scissors").foregroundStyle(Color.accentColor)
            } else if engine.fragmentStart != nil {
                Label("已标记起点", systemImage: "scissors").foregroundStyle(Color.accentColor)
            }
            if engine.loopEnabled {
                Label("循环 \(engine.loopPass)/\(Prefs.loopCount == 0 ? "∞" : "\(Prefs.loopCount)")", systemImage: "repeat.1")
                    .foregroundStyle(Color.accentColor)
            }
            if engine.pauseAfterEach { Label("逐句停", systemImage: "pause.circle").foregroundStyle(Color.accentColor) }
            if engine.speed != 1 { Text(String(format: "%.2gx", engine.speed)) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

func haptic() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }

// MARK: - Press-and-hold peeks

struct HoldButtons: View {
    @EnvironmentObject var engine: PlayerEngine

    var body: some View {
        HStack(spacing: 10) {
            HoldButton(title: "按住看字幕", systemImage: "eye", isOn: $engine.revealHeld)
                .opacity(engine.blindMode ? 1 : 0.45)
            HoldButton(title: "按住看翻译", systemImage: "character.bubble", isOn: $engine.translationHeld)
                .opacity(engine.translationSourceID == nil ? 0.35 : 1)
        }
        .padding(.horizontal, 16)
    }
}

struct HoldButton: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isOn ? Color.accentColor.opacity(0.22) : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(isOn ? Color.accentColor : Color.primary)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !isOn { isOn = true; haptic() } }
                .onEnded { _ in isOn = false })
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Transport + toggles

struct ControlsArea: View {
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var favorites: FavoritesStore

    var body: some View {
        VStack(spacing: 10) {
            TimelineBar(clock: engine.clock)
            HStack {
                transport("backward.end.fill", .prevSentence)
                transport("gobackward", .rewind)
                Button { engine.perform(.playPause) } label: {
                    Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 52))
                }
                .frame(maxWidth: .infinity)
                transport("arrow.counterclockwise", .replaySentence)
                transport("forward.end.fill", .nextSentence)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    toggle("repeat.1", .toggleLoop, on: engine.loopEnabled)
                    toggle("gobackward.minus", .loopRecent, on: engine.fragment != nil)
                    toggle("scissors", .markFragment, on: engine.fragmentStart != nil)
                    toggle("pause.circle", .togglePauseMode, on: engine.pauseAfterEach)
                    toggle(engine.blindMode ? "eye.slash" : "eye", .toggleBlind, on: engine.blindMode)
                    toggle("character.bubble", .toggleTranslation, on: engine.showTranslation)
                    toggle(isFavorite ? "star.fill" : "star", .favorite, on: isFavorite)
                    speedMenu
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 12)
    }

    private var isFavorite: Bool {
        guard let url = engine.mediaURL, let cue = engine.focusCue else { return false }
        return favorites.contains(path: url.path, cue: cue)
    }

    private func transport(_ icon: String, _ action: PlayerAction) -> some View {
        Button { engine.perform(action); haptic() } label: {
            Image(systemName: icon).font(.system(size: 22)).frame(maxWidth: .infinity, minHeight: 44)
        }
        .accessibilityLabel(action.title)
    }

    private func toggle(_ icon: String, _ action: PlayerAction, on: Bool) -> some View {
        Button { engine.perform(action); haptic() } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 18))
                Text(action.buttonLabel).font(.caption2)
            }
            .frame(width: 58, height: 50)
            .foregroundStyle(on ? Color.accentColor : Color.primary)
            .background(on ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityLabel(action.title)
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.5, 0.6, 0.7, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0], id: \.self) { v in
                Button(String(format: "%.2gx", v)) { engine.setSpeed(Float(v)) }
            }
        } label: {
            VStack(spacing: 3) {
                Text(String(format: "%.2gx", engine.speed)).font(.system(size: 16, weight: .semibold)).monospacedDigit()
                Text("速度").font(.caption2)
            }
            .frame(width: 58, height: 50)
            .foregroundStyle(engine.speed == 1 ? Color.primary : Color.accentColor)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct TimelineBar: View {
    @EnvironmentObject var engine: PlayerEngine
    @ObservedObject var clock: PlaybackClock
    @State private var dragValue: Double?

    var body: some View {
        HStack(spacing: 8) {
            Text(formatTime(dragValue ?? clock.time)).monospacedDigit()
            Slider(value: Binding(get: { dragValue ?? clock.time }, set: { dragValue = $0 }),
                   in: 0 ... max(engine.duration, 0.1)) { editing in
                if !editing, let v = dragValue {
                    engine.jump(to: v)
                    dragValue = nil
                }
            }
            Text(formatTime(engine.duration)).monospacedDigit()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
    }
}

// MARK: - Sentence list

struct CueList: View {
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var favorites: FavoritesStore

    var body: some View {
        ScrollViewReader { proxy in
            List(engine.cues) { cue in
                let isCurrent = cue.id == engine.focusIndex
                let translation = engine.translationVisible && engine.translationLines.indices.contains(cue.id)
                    ? engine.translationLines[cue.id] : ""
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(formatTime(cue.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cue.text)
                            .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                            .blur(radius: engine.subtitleVisible ? 0 : 5)
                        if !translation.isEmpty { Text(translation).font(.footnote).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                    if isFavorite(cue) { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                }
                .id(cue.id)
                .listRowBackground(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { engine.goToSentence(cue.id) }
                .swipeActions(edge: .trailing) {
                    Button { if let url = engine.mediaURL { favorites.toggle(path: url.path, cue: cue) } } label: {
                        Label(isFavorite(cue) ? "取消收藏" : "收藏", systemImage: "star")
                    }
                    .tint(.yellow)
                }
            }
            .listStyle(.plain)
            .onChange(of: engine.focusIndex) { _, index in
                guard let index else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(index, anchor: .center) }
            }
        }
    }

    private func isFavorite(_ cue: Cue) -> Bool {
        guard let url = engine.mediaURL else { return false }
        return favorites.contains(path: url.path, cue: cue)
    }
}
