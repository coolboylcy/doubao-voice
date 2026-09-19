import Combine
import Foundation

/// Voice Doggo 的本地偏好。
///
/// 所有设置都只写入 UserDefaults，不需要账号、云端配置或第三方 API。
///
/// 这里没有「识别语言」：SenseVoice 是多语言自动识别的，打包进来的
/// llama-funasr-sensevoice 也不接受语言参数，存了也没人读得懂。
@MainActor
final class AppPreferences: ObservableObject {
    enum Hotkey: String, CaseIterable, Identifiable {
        case rightOption
        case leftOption

        var id: String { rawValue }
        var title: String { self == .rightOption ? "右 Option" : "左 Option" }
        var keyCode: Int64 { self == .rightOption ? 61 : 58 }
        var deviceMask: UInt64 { self == .rightOption ? 0x40 : 0x20 }
    }

    enum MenuIconStyle: String, CaseIterable, Identifiable {
        case dogAndMic
        case dog
        case waveform

        var id: String { rawValue }
        var title: String {
            switch self {
            case .dogAndMic: return "狗子 + 麦克风"
            case .dog: return "极简狗子"
            case .waveform: return "语音波形"
            }
        }
    }

    private enum Key {
        static let hotkey = "preferences.hotkey"
        static let automaticInsertion = "preferences.automaticInsertion"
        static let startupHint = "preferences.startupHint"
        static let systemNotifications = "preferences.systemNotifications"
        static let menuIconStyle = "preferences.menuIconStyle"
        static let showHUD = "preferences.showHUD"
    }

    private let defaults: UserDefaults

    @Published var hotkey: Hotkey { didSet { defaults.set(hotkey.rawValue, forKey: Key.hotkey) } }
    @Published var automaticInsertion: Bool {
        didSet { defaults.set(automaticInsertion, forKey: Key.automaticInsertion) }
    }
    @Published var startupHint: Bool {
        didSet { defaults.set(startupHint, forKey: Key.startupHint) }
    }
    @Published var systemNotifications: Bool {
        didSet { defaults.set(systemNotifications, forKey: Key.systemNotifications) }
    }
    @Published var menuIconStyle: MenuIconStyle {
        didSet { defaults.set(menuIconStyle.rawValue, forKey: Key.menuIconStyle) }
    }
    @Published var showHUD: Bool { didSet { defaults.set(showHUD, forKey: Key.showHUD) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hotkey = Hotkey(rawValue: defaults.string(forKey: Key.hotkey) ?? "") ?? .rightOption
        automaticInsertion = defaults.object(forKey: Key.automaticInsertion) as? Bool ?? true
        startupHint = defaults.object(forKey: Key.startupHint) as? Bool ?? true
        systemNotifications = defaults.object(forKey: Key.systemNotifications) as? Bool ?? true
        menuIconStyle = MenuIconStyle(rawValue: defaults.string(forKey: Key.menuIconStyle) ?? "") ?? .dogAndMic
        showHUD = defaults.object(forKey: Key.showHUD) as? Bool ?? true
    }
}
