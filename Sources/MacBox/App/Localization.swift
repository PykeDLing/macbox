import Foundation

// 界面文字用 String Catalog（Resources/Localizable.xcstrings）：代码里写简体中文原文，它就是键，
// 视图里直接写 Text("添加应用")，别处写 String(localized: "添加应用")；英文译文、单复数都在 catalog 里。
// ./build.sh 编译时由 swiftc 提取用到的文字、同步进 catalog，再编译进 App 的 en.lproj。
// 开发语言（Info.plist 的 CFBundleDevelopmentRegion）是英文：偏好语言里中英文都没有时显示英文。
// 简体中文那边是一张张空表（见 build.sh），查不到就用键本身，不会退回英文

/// 设置里可选的界面语言。选择存在本 App 域的 AppleLanguages 里：系统菜单按它显示，
/// 系统设置 › 通用 › 语言与地区 › 应用程序 改的也是它，两边始终一致。和 Apple 自己的 App 一样，重新打开 MacBox 后生效
nonisolated enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case chinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: String(localized: "跟随系统")
        case .chinese: "简体中文"
        case .english: "English"
        }
    }

    /// 存着的选择（下次打开 MacBox 时用的语言），没有单独选过时是 .system
    static var selected: AppLanguage {
        get {
            let languages = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesCurrentApplication,
                                                   kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
            guard !languages.isEmpty else { return .system }
            // 和系统给本 App 挑选本地化的规则一致：繁体中文、其他语言按系统的规则落到简体中文或英文
            return Bundle.preferredLocalizations(from: [chinese.rawValue, english.rawValue], forPreferences: languages).first
                == english.rawValue ? .english : .chinese
        }
        set {
            if newValue == .system {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([newValue.rawValue], forKey: "AppleLanguages")
            }
        }
    }
}

nonisolated extension Locale {
    /// 界面文字实际用的语言，地区照系统的。列表、日期要和界面文字同一种语言：偏好语言排第一的可能是 MacBox 没有的语言，
    /// Locale.current 会跟着它。语言代码本身也在 catalog 里翻译，所以总和取到的文字一致（测试里没有译文，就是简体中文）
    static let interface: Locale = {
        var components = Locale.Components(locale: .current)
        components.languageComponents = Locale.Language.Components(
            identifier: String(localized: "zh-Hans", comment: "界面语言的代码：译文填那种语言自己的代码，英文填 en"))
        return Locale(components: components)
    }()
}

nonisolated extension Bundle {
    /// 只查简体中文的 bundle（App 里的 zh-Hans.lproj，里面是空表）：中文是源语言，查不到就用键本身，所以取出来的总是中文，
    /// 不随界面语言变化。box.json 里给旧版 MacBox 读的字段用它。测试里没有这个目录，Bundle.main 也没有译文，同样是中文
    static let simplifiedChinese = Bundle.main.url(forResource: "zh-Hans", withExtension: "lproj").flatMap(Bundle.init(url:)) ?? .main
}

/// 名字按界面语言加上引号：「夸克」/“Quark”
nonisolated func quoted(_ name: String) -> String {
    String(localized: "「\(name)」", comment: "一个名字加上引号")
}

/// 按界面语言连成一句：甲、乙和丙 / A, B, and C
nonisolated func listed(_ items: [String]) -> String {
    items.formatted(.list(type: .and).locale(.interface))
}

/// 一组名字，每个加上引号再连起来。more 为 true 时说明还有没列出来的
nonisolated func quotedList(_ names: [String], more: Bool = false) -> String {
    listed(names.map(quoted) + (more ? [String(localized: "其他几项", comment: "列表末尾：还有没列出来的")] : []))
}
