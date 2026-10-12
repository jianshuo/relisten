import AppKit
import SwiftUI

enum Prefs {
    static let rewindSecondsKey = "rewindSeconds"
    static let loopCountKey = "loopCount"          // 0 = forever
    static let leadInKey = "leadIn"                // start a sentence slightly early
    static let blindByDefaultKey = "blindByDefault"

    static func register() {
        UserDefaults.standard.register(defaults: [
            rewindSecondsKey: 3.0, loopCountKey: 0, leadInKey: 0.15, blindByDefaultKey: true,
        ])
    }

    static var rewindSeconds: Double { UserDefaults.standard.double(forKey: rewindSecondsKey) }
    static var loopCount: Int { UserDefaults.standard.integer(forKey: loopCountKey) }
    static var leadIn: Double { UserDefaults.standard.double(forKey: leadInKey) }
    static var blindByDefault: Bool { UserDefaults.standard.bool(forKey: blindByDefaultKey) }
}

enum PlayerAction: String, CaseIterable, Codable, Identifiable {
    case playPause, prevSentence, nextSentence, replaySentence
    case rewind, forward
    case toggleLoop, togglePauseMode
    case revealHold, toggleBlind
    case translationHold, toggleTranslation
    case loopRecent, markFragment, clearFragment
    case slower, faster, resetSpeed
    case favorite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playPause: "播放 / 暂停"
        case .prevSentence: "上一句"
        case .nextSentence: "下一句"
        case .replaySentence: "重听本句"
        case .rewind: "后退几秒"
        case .forward: "前进几秒"
        case .toggleLoop: "单句循环 开/关"
        case .togglePauseMode: "逐句暂停 开/关"
        case .revealHold: "按住显示字幕"
        case .toggleBlind: "盲听 / 常显字幕"
        case .translationHold: "按住看翻译"
        case .toggleTranslation: "翻译常显 开/关"
        case .loopRecent: "循环刚才几秒"
        case .markFragment: "标记片段起点 / 终点"
        case .clearFragment: "退出片段循环"
        case .slower: "减速"
        case .faster: "加速"
        case .resetSpeed: "恢复 1.0x"
        case .favorite: "收藏本句"
        }
    }

    /// Actions that make sense to auto-repeat while the key is held.
    /// Press-and-hold actions: active while the key is down.
    static let holds: [PlayerAction] = [.revealHold, .translationHold]

    var repeats: Bool { [.prevSentence, .nextSentence, .rewind, .forward, .slower, .faster].contains(self) }
}

struct KeyCombo: Codable, Hashable {
    var keyCode: UInt16
    var modifiers: UInt
    var label: String

    static let modifierMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.modifierMask).rawValue
        self.label = label
    }

    init(event: NSEvent) {
        let special: [UInt16: String] = [49: "空格", 123: "←", 124: "→", 125: "↓", 126: "↑",
                                         36: "↩", 48: "⇥", 53: "⎋", 51: "⌫", 117: "⌦"]
        let label = special[event.keyCode]
            ?? event.characters(byApplyingModifiers: [])?.uppercased()
            ?? "#\(event.keyCode)"
        self.init(keyCode: event.keyCode, modifiers: event.modifierFlags, label: label)
    }

    var display: String {
        let m = NSEvent.ModifierFlags(rawValue: modifiers)
        var s = ""
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        return s + label
    }

    func matches(_ other: KeyCombo) -> Bool { keyCode == other.keyCode && modifiers == other.modifiers }
}

@MainActor
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()
    private static let defaultsKey = "shortcuts.v1"

    @Published private(set) var bindings: [PlayerAction: KeyCombo]
    @Published var recording: PlayerAction?

    static let defaults: [PlayerAction: KeyCombo] = [
        .playPause: KeyCombo(keyCode: 49, label: "空格"),
        .prevSentence: KeyCombo(keyCode: 123, label: "←"),
        .nextSentence: KeyCombo(keyCode: 124, label: "→"),
        .replaySentence: KeyCombo(keyCode: 125, label: "↓"),
        .revealHold: KeyCombo(keyCode: 126, label: "↑"),
        .rewind: KeyCombo(keyCode: 123, modifiers: .shift, label: "←"),
        .forward: KeyCombo(keyCode: 124, modifiers: .shift, label: "→"),
        .toggleLoop: KeyCombo(keyCode: 37, label: "L"),
        .togglePauseMode: KeyCombo(keyCode: 35, label: "P"),
        .toggleBlind: KeyCombo(keyCode: 17, label: "T"),
        .translationHold: KeyCombo(keyCode: 8, label: "C"),
        .toggleTranslation: KeyCombo(keyCode: 8, modifiers: .shift, label: "C"),
        .loopRecent: KeyCombo(keyCode: 15, label: "R"),
        .markFragment: KeyCombo(keyCode: 0, label: "A"),
        .clearFragment: KeyCombo(keyCode: 53, label: "⎋"),
        .slower: KeyCombo(keyCode: 33, label: "["),
        .faster: KeyCombo(keyCode: 30, label: "]"),
        .resetSpeed: KeyCombo(keyCode: 42, label: "\\"),
        .favorite: KeyCombo(keyCode: 3, label: "F"),
    ]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([String: KeyCombo].self, from: data) {
            var b: [PlayerAction: KeyCombo] = [:]
            for (k, v) in saved { if let a = PlayerAction(rawValue: k) { b[a] = v } }
            for a in PlayerAction.allCases where saved[a.rawValue] == nil { b[a] = Self.defaults[a] }  // newly added actions
            bindings = b
        } else {
            bindings = Self.defaults
        }
    }

    func action(for combo: KeyCombo) -> PlayerAction? {
        bindings.first { $0.value.matches(combo) }?.key
    }

    func label(_ action: PlayerAction) -> String { bindings[action]?.display ?? "未设置" }

    /// Assigning a key that another action already uses steals it from that action.
    func set(_ combo: KeyCombo, for action: PlayerAction) {
        for (a, c) in bindings where a != action && c.matches(combo) { bindings[a] = nil }
        bindings[action] = combo
        persist()
    }

    func clear(_ action: PlayerAction) { bindings[action] = nil; persist() }
    func resetAll() { bindings = Self.defaults; persist() }

    private func persist() {
        let dict = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(dict) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }
}

/// Routes key presses in the player window to PlayerEngine actions (and to the shortcut recorder).
enum KeyMonitor {
    static func install() {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            MainActor.assumeIsolated { handle(event) }
        }
    }

    @MainActor
    private static func handle(_ event: NSEvent) -> NSEvent? {
        let store = ShortcutStore.shared
        let engine = PlayerEngine.shared

        if let action = store.recording {
            guard event.type == .keyDown else { return nil }
            let combo = KeyCombo(event: event)
            if event.keyCode == 53, combo.modifiers == 0 { store.recording = nil; return nil }  // Esc cancels
            store.set(combo, for: action)
            store.recording = nil
            return nil
        }

        guard let window = engine.mainWindow, event.window === window else { return event }
        if window.firstResponder is NSText { return event }   // typing in a text field

        if event.type == .keyUp {
            var released = false
            for action in PlayerAction.holds where engine.isHolding(action) && event.keyCode == store.bindings[action]?.keyCode {
                engine.release(action)
                released = true
            }
            return released ? nil : event
        }

        guard let action = store.action(for: KeyCombo(event: event)) else { return event }
        if event.isARepeat && !action.repeats { return nil }
        engine.perform(action)
        return nil
    }
}
