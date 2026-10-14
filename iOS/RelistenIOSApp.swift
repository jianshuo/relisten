import AVFoundation
import MediaPlayer
import SwiftUI

@main
struct RelistenIOSApp: App {
    @StateObject private var engine = PlayerEngine.shared
    @StateObject private var favorites = FavoritesStore.shared
    @Environment(\.scenePhase) private var scenePhase

    init() { RemoteCommands.install() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .environmentObject(favorites)
                .onOpenURL { url in engine.open(url) }   // "Open in Relisten" from Files / share sheet
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { engine.savePosition() }
        }
    }
}

/// How iOS tells the user to trigger an action: tap its button.
@MainActor
func actionHint(_ action: PlayerAction) -> String { "点一次「\(action.buttonLabel)」" }

extension PlayerAction {
    /// Short labels under the iOS control buttons.
    var buttonLabel: String {
        switch self {
        case .toggleLoop: "循环"
        case .loopRecent: "刚才"
        case .markFragment: "标记"
        case .togglePauseMode: "逐句停"
        case .toggleBlind: "盲听"
        case .toggleTranslation: "翻译"
        case .favorite: "收藏"
        default: title
        }
    }
}

/// Lock screen, Control Center and AirPods: next / previous "track" = next / previous sentence.
enum RemoteCommands {
    @MainActor
    static func install() {
        let center = MPRemoteCommandCenter.shared()
        let engine = PlayerEngine.shared
        func bind(_ command: MPRemoteCommand, _ action: PlayerAction) {
            command.isEnabled = true
            command.addTarget { _ in
                MainActor.assumeIsolated { engine.perform(action) }
                return .success
            }
        }
        bind(center.togglePlayPauseCommand, .playPause)
        bind(center.playCommand, .playPause)
        bind(center.pauseCommand, .playPause)
        bind(center.nextTrackCommand, .nextSentence)
        bind(center.previousTrackCommand, .prevSentence)
        center.skipBackwardCommand.preferredIntervals = [3]
        bind(center.skipBackwardCommand, .rewind)
    }

    @MainActor
    static func updateNowPlaying(title: String?, sentence: String?) {
        guard let title else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: sentence ?? "Relisten",
        ]
    }
}
