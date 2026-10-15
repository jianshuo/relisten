import AVFoundation
import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject var favorites: FavoritesStore
    @EnvironmentObject var engine: PlayerEngine
    @State private var selection = Set<UUID>()

    var body: some View {
        Group {
            if favorites.items.isEmpty {
                Text("还没有收藏。播放时按 \(ShortcutStore.shared.label(.favorite)) 收藏听不懂的句子。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(groups, id: \.0) { file, items in
                        Section(file) {
                            ForEach(items) { fav in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(formatTime(fav.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Text(fav.text).frame(maxWidth: .infinity, alignment: .leading)
                                    Button { engine.playFavorite(fav) } label: { Image(systemName: "play.fill") }
                                        .buttonStyle(.borderless)
                                        .help("跳到这句播放")
                                }
                                .tag(fav.id)
                                .contextMenu {
                                    Button("播放") { engine.playFavorite(fav) }
                                    Button("删除") { favorites.remove([fav.id]) }
                                }
                            }
                        }
                    }
                }
                .onDeleteCommand { favorites.remove(selection) }
                .contextMenu(forSelectionType: UUID.self) { _ in } primaryAction: { ids in
                    if let id = ids.first, let fav = favorites.items.first(where: { $0.id == id }) { engine.playFavorite(fav) }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .navigationTitle("收藏的句子（\(favorites.items.count)）")
    }

    private var groups: [(String, [Favorite])] {
        var order: [String] = []
        var map: [String: [Favorite]] = [:]
        for f in favorites.items {
            if map[f.fileName] == nil { order.append(f.fileName) }
            map[f.fileName, default: []].append(f)
        }
        return order.map { ($0, map[$0]!.sorted { $0.start < $1.start }) }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("通用", systemImage: "gearshape") }
            ShortcutSettings().tabItem { Label("快捷键", systemImage: "keyboard") }
        }
        .frame(width: 480)
    }
}

struct GeneralSettings: View {
    @AppStorage(Prefs.rewindSecondsKey) private var rewind = 3.0
    @AppStorage(Prefs.loopCountKey) private var loopCount = 0
    @AppStorage(Prefs.leadInKey) private var leadIn = 0.15
    @AppStorage(Prefs.blindByDefaultKey) private var blind = true

    var body: some View {
        Form {
            Picker("后退 / 前进", selection: $rewind) {
                ForEach([1.0, 2.0, 3.0, 5.0, 10.0], id: \.self) { Text("\(Int($0)) 秒").tag($0) }
            }
            Picker("单句循环次数", selection: $loopCount) {
                Text("无限（直到关闭）").tag(0)
                ForEach([2, 3, 5, 10], id: \.self) { Text("\($0) 遍").tag($0) }
            }
            Picker("句首提前量", selection: $leadIn) {
                ForEach([0.0, 0.1, 0.15, 0.25, 0.4], id: \.self) { Text(String(format: "%.2f 秒", $0)).tag($0) }
            }
            .help("跳到一句时稍微提前一点开始，避免吞掉第一个词")
            Toggle("打开文件时默认盲听（隐藏字幕）", isOn: $blind)
            Section {
                Picker("转换缓存上限", selection: $cacheLimit) {
                    ForEach([5, 10, 20, 50, 100], id: \.self) { Text("\($0) GB").tag($0) }
                    Text("不限").tag(0)
                }
                .onChange(of: cacheLimit) { _, _ in
                    DispatchQueue.global(qos: .utility).async {
                        ConversionCache.enforceLimit(keeping: nil)
                        DispatchQueue.main.async { refreshCacheSize() }
                    }
                }
                LabeledContent("已用") {
                    HStack {
                        Text(cacheSize)
                        Button("清空…") { confirmClear = true }
                    }
                }
            } header: {
                Text("转换缓存")
            } footer: {
                Text("mkv 等格式第一次打开时会转换一份 mp4 存在这里，下次秒开；原文件删了也能继续播。超出上限时先删最久没看的。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 420)
        .onAppear(perform: refreshCacheSize)
        .confirmationDialog("清空转换缓存？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) {
                let playing = (PlayerEngine.shared.player.currentItem?.asset as? AVURLAsset)?.url
                ConversionCache.clear(keepingFile: playing)
                refreshCacheSize()
            }
        } message: {
            Text("正在播放的那份会保留。以后再打开这些 mkv 需要重新转换。")
        }
    }

    @AppStorage(Prefs.cacheLimitKey) private var cacheLimit = 20
    @State private var cacheSize = "…"
    @State private var confirmClear = false

    private func refreshCacheSize() {
        cacheSize = ByteCountFormatter.string(fromByteCount: ConversionCache.totalBytes, countStyle: .file)
    }
}

struct ShortcutSettings: View {
    @EnvironmentObject var store: ShortcutStore

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ForEach(PlayerAction.allCases) { action in
                    LabeledContent(action.title) {
                        HStack {
                            Button {
                                store.recording = store.recording == action ? nil : action
                            } label: {
                                Text(store.recording == action ? "请按键…（Esc 取消）" : store.label(action))
                                    .frame(minWidth: 110)
                                    .monospaced()
                            }
                            .tint(store.recording == action ? .accentColor : nil)
                            Button { store.clear(action) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("清除")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Text("点按钮后直接按新的键；被别的功能占用的键会自动转过来。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("恢复默认") { store.resetAll() }
            }
            .padding()
        }
        .frame(height: 560)
        .onDisappear { store.recording = nil }
    }
}
