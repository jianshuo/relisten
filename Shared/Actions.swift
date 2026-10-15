import Foundation

enum Prefs {
    static let rewindSecondsKey = "rewindSeconds"
    static let loopCountKey = "loopCount"          // 0 = forever
    static let leadInKey = "leadIn"                // start a sentence slightly early
    static let blindByDefaultKey = "blindByDefault"
    static let cacheLimitKey = "cacheLimitGB"           // Mac conversion cache, 0 = unlimited

    static func register() {
        UserDefaults.standard.register(defaults: [
            rewindSecondsKey: 3.0, loopCountKey: 0, leadInKey: 0.15, blindByDefaultKey: true, cacheLimitKey: 20,
        ])
    }

    static var rewindSeconds: Double { UserDefaults.standard.double(forKey: rewindSecondsKey) }
    static var loopCount: Int { UserDefaults.standard.integer(forKey: loopCountKey) }
    static var leadIn: Double { UserDefaults.standard.double(forKey: leadInKey) }
    static var blindByDefault: Bool { UserDefaults.standard.bool(forKey: blindByDefaultKey) }
    static var cacheLimitGB: Int { UserDefaults.standard.integer(forKey: cacheLimitKey) }
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
