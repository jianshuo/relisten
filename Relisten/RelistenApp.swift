import SwiftUI

@main
struct RelistenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = PlayerEngine.shared
    @StateObject private var favorites = FavoritesStore.shared
    @StateObject private var shortcuts = ShortcutStore.shared

    var body: some Scene {
        Window("Relisten", id: "main") {
            ContentView()
                .environmentObject(engine)
                .environmentObject(favorites)
                .environmentObject(shortcuts)
        }
        .commands { AppCommands(engine: engine, shortcuts: shortcuts) }

        Window("收藏的句子", id: "favorites") {
            FavoritesView()
                .environmentObject(engine)
                .environmentObject(favorites)
        }
        .keyboardShortcut("2", modifiers: [.command])

        Settings {
            SettingsView().environmentObject(shortcuts)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        KeyMonitor.install()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { PlayerEngine.shared.open(url) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        PlayerEngine.shared.savePosition()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Menu items show the single-key shortcut in their title; the keys themselves go through KeyMonitor.
struct AppCommands: Commands {
    @ObservedObject var engine: PlayerEngine
    @ObservedObject var shortcuts: ShortcutStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("打开…") { openPanel(engine) }.keyboardShortcut("o")
            Button("载入字幕…") { openSubtitlePanel(engine) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(engine.mediaURL == nil)
        }
        CommandMenu("播放") {
            ForEach(PlayerAction.allCases.filter { !PlayerAction.holds.contains($0) }) { action in
                Button("\(action.title)\t\(shortcuts.label(action))") { engine.perform(action) }
                    .disabled(engine.mediaURL == nil)
            }
            if engine.sources.count > 1 {
                Divider()
                Menu("字幕轨道") {
                    ForEach(engine.sources) { source in
                        Button((source.id == engine.sourceID ? "✓ " : "   ") + source.name) {
                            Task { await engine.selectSource(source) }
                        }
                    }
                }
                Menu("翻译轨道") {
                    Button((engine.translationSourceID == nil ? "✓ " : "   ") + "无") {
                        Task { await engine.selectTranslation(nil) }
                    }
                    ForEach(engine.sources) { source in
                        Button((source.id == engine.translationSourceID ? "✓ " : "   ") + source.name) {
                            Task { await engine.selectTranslation(source) }
                        }
                    }
                }
            }
        }
    }
}
