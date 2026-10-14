import SwiftUI
import UniformTypeIdentifiers

/// Media types the iOS build can open (AVFoundation-playable) plus subtitle files.
let openableTypes: [UTType] = [.movie, .audio, .audiovisualContent, .mpeg4Movie, .quickTimeMovie, .mp3]
    + ["m4v", "m4a", "srt", "vtt", "ass"].compactMap { UTType(filenameExtension: $0) }

struct RootView: View {
    @EnvironmentObject var engine: PlayerEngine

    var body: some View {
        NavigationStack {
            if engine.mediaURL == nil { LibraryView() } else { PlayerScreen() }
        }
        .overlay(alignment: .top) {
            if let toast = engine.toast {
                Text(toast)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 6)
                    .transition(.opacity)
            }
        }
        .overlay {
            if let loading = engine.loading {
                ProgressView(loading).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .animation(.easeOut(duration: 0.15), value: engine.toast)
        .task { openDemoIfRequested() }
    }

    /// Screenshot runs: `-RelistenDemo a|b|c` opens the first video in the Relisten folder.
    private func openDemoIfRequested() {
        guard UserDefaults.standard.string(forKey: "RelistenDemo") != nil, engine.mediaURL == nil,
              let first = LibraryFiles.documents().first else { return }
        engine.open(first)
    }
}

enum LibraryFiles {
    static let mediaExtensions: Set<String> = ["mp4", "m4v", "mov", "mp3", "m4a", "aac", "wav", "caf"]

    static var documentsURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// Media the user copied into the app's own folder (Finder / Files app → "Relisten").
    static func documents() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)) ?? []
        return files.filter { mediaExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

struct LibraryView: View {
    @EnvironmentObject var engine: PlayerEngine
    @State private var importing = false
    @State private var showFavorites = false
    @State private var showSettings = false
    @State private var folderFiles: [URL] = []

    var body: some View {
        List {
            Section {
                Button { importing = true } label: {
                    Label("从「文件」打开视频或音频…", systemImage: "folder")
                }
                if let notice = engine.notice {
                    Text(notice).font(.footnote).foregroundStyle(.red)
                }
            } footer: {
                Text("需要带字幕的文件：mp4 / mov 的内封字幕，或放在同一文件夹的同名 .srt / .vtt / .ass。")
            }

            Section {
                if folderFiles.isEmpty {
                    Text("在 Mac 的「访达」或 iPhone 的「文件」App 里，把视频和字幕拷进「Relisten」文件夹，就会出现在这里。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(folderFiles, id: \.self) { url in
                    Button { engine.open(url) } label: {
                        Label(url.lastPathComponent, systemImage: "play.rectangle")
                    }
                }
            } header: {
                Text("Relisten 文件夹")
            }

            let inFolder = Set(folderFiles.map { $0.resolvingSymlinksInPath().path })
            let recents = ResumeStore.recents.filter {
                !inFolder.contains(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path)
            }
            if !recents.isEmpty {
                Section("最近打开") {
                    ForEach(recents.prefix(8), id: \.self) { path in
                        Button { engine.open(path: path) } label: {
                            Label((path as NSString).lastPathComponent, systemImage: "clock.arrow.circlepath")
                        }
                    }
                }
            }

            Section {
                Button { showFavorites = true } label: { Label("收藏的句子", systemImage: "star") }
                Button { showSettings = true } label: { Label("设置", systemImage: "gearshape") }
            }
        }
        .navigationTitle("Relisten")
        .fileImporter(isPresented: $importing, allowedContentTypes: openableTypes) { result in
            if case .success(let url) = result { engine.open(url) }
        }
        .sheet(isPresented: $showFavorites) { FavoritesSheet() }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .onAppear { folderFiles = LibraryFiles.documents() }
        .refreshable { folderFiles = LibraryFiles.documents() }
    }
}

struct FavoritesSheet: View {
    @EnvironmentObject var favorites: FavoritesStore
    @EnvironmentObject var engine: PlayerEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if favorites.items.isEmpty {
                    ContentUnavailableView("还没有收藏", systemImage: "star",
                                           description: Text("播放时点「收藏」，把听不懂的句子攒起来复习。"))
                } else {
                    List {
                        ForEach(groups, id: \.0) { file, items in
                            Section(file) {
                                ForEach(items) { fav in
                                    Button {
                                        engine.playFavorite(fav)
                                        dismiss()
                                    } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(fav.text).foregroundStyle(.primary)
                                            Text(formatTime(fav.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .onDelete { offsets in favorites.remove(Set(offsets.map { items[$0].id })) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("收藏的句子")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    private var groups: [(String, [Favorite])] {
        Dictionary(grouping: favorites.items, by: \.fileName)
            .map { ($0.key, $0.value.sorted { $0.start < $1.start }) }
            .sorted { $0.0 < $1.0 }
    }
}

struct SettingsSheet: View {
    @AppStorage(Prefs.rewindSecondsKey) private var rewind = 3.0
    @AppStorage(Prefs.loopCountKey) private var loopCount = 0
    @AppStorage(Prefs.leadInKey) private var leadIn = 0.15
    @AppStorage(Prefs.blindByDefaultKey) private var blind = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Picker("后退 / 「刚才」秒数", selection: $rewind) {
                    ForEach([1.0, 2.0, 3.0, 5.0, 10.0], id: \.self) { Text("\(Int($0)) 秒").tag($0) }
                }
                Picker("单句循环次数", selection: $loopCount) {
                    Text("无限（直到关闭）").tag(0)
                    ForEach([2, 3, 5, 10], id: \.self) { Text("\($0) 遍").tag($0) }
                }
                Picker("句首提前量", selection: $leadIn) {
                    ForEach([0.0, 0.1, 0.15, 0.25, 0.4], id: \.self) { Text(String(format: "%.2f 秒", $0)).tag($0) }
                }
                Toggle("打开文件时默认盲听", isOn: $blind)
                Section {
                    Text("耳机或锁屏上的「下一曲 / 上一曲」会跳到下一句 / 上一句。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
