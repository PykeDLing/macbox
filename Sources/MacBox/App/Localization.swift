import Foundation
import Observation
import Synchronization

/// 界面文字：中文原文和英文并排写在代码里，`L("添加应用", "Add App")`。
/// 在视图的 body 里调用会登记对当前语言的依赖，切换语言后界面立即刷新；
/// 模型里生成的文字（错误信息、状态说明等）保持生成时的语言
nonisolated func L(_ chinese: String, _ english: String) -> String {
    Localization.shared.isEnglish ? english : chinese
}

/// 设置里可选的界面语言
nonisolated enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case chinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: L("跟随系统", "System Default")
        case .chinese: "简体中文"
        case .english: "English"
        }
    }
}

/// 当前界面语言。手写 Observable（而不是 @Observable 宏），这样后台线程里生成文字时也能安全读取。
/// 选择保存在本 App 域的 AppleLanguages 里：系统菜单按它显示，系统设置 › 语言与地区 › 应用程序 改的也是它，
/// 两边始终一致
nonisolated final class Localization: Observable, Sendable {
    static let shared = Localization()

    private let registrar = ObservationRegistrar()
    private let stored: Mutex<AppLanguage>

    private init() {
        let appLanguages = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesCurrentApplication,
                                                  kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
        stored = Mutex(appLanguages.isEmpty ? .system : Self.match(appLanguages))
    }

    var language: AppLanguage {
        get {
            registrar.access(self, keyPath: \.language)
            return stored.withLock { $0 }
        }
        set {
            registrar.withMutation(of: self, keyPath: \.language) { stored.withLock { $0 = newValue } }
            // 系统提供的文字（菜单项、文件选择框等）按 AppleLanguages 显示，下次启动生效
            if newValue == .system {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([newValue.rawValue], forKey: "AppleLanguages")
            }
        }
    }

    var isEnglish: Bool {
        switch language {
        case .chinese: false
        case .english: true
        case .system: Self.systemLanguage == .english
        }
    }

    /// 读全局域而不是 Locale.preferredLanguages：后者会被本 App 写下的 AppleLanguages 盖住
    private static var systemLanguage: AppLanguage {
        let languages = CFPreferencesCopyAppValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication) as? [String]
            ?? Locale.preferredLanguages
        return match(languages)
    }

    /// 和系统给本 App 挑选本地化的规则一致（系统菜单因此和界面文字同一种语言）：
    /// 繁体中文不会匹配简体，都匹配不上时用开发语言英文（Info.plist 的 CFBundleDevelopmentRegion）
    private static func match(_ languages: [String]) -> AppLanguage {
        let candidates = [AppLanguage.chinese.rawValue, AppLanguage.english.rawValue]
        return Bundle.preferredLocalizations(from: candidates, forPreferences: languages).first == AppLanguage.chinese.rawValue
            ? .chinese : .english
    }
}
