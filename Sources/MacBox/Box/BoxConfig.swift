import Foundation

/// 应用在哪里运行
nonisolated enum Runtime: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 在本机原生运行，文件、设置、钥匙串都收在盒子里
    case isolated
    /// 在一台独立的虚拟 Mac 中运行
    case virtualMac

    var id: String { rawValue }
    var title: String { self == .isolated ? L("本机隔离", "Native Isolation") : L("虚拟 Mac", "Virtual Mac") }
    var summary: String {
        switch self {
        case .isolated: L("像普通 App 一样运行，写下的文件、设置和钥匙串都收在 MacBox 里，删除即清空。",
                          "Runs like a regular app. Files, settings and keychain items it writes stay inside MacBox and are gone when you delete it.")
        case .virtualMac: L("在一台独立的虚拟 Mac 里运行，与本机完全隔开。兼容性最好，但占用约 30 GB、启动较慢。",
                            "Runs in a separate virtual Mac, fully walled off from this Mac. Best compatibility, but takes about 30 GB and starts more slowly.")
        }
    }
}

nonisolated struct CompatibilityIssue: Codable, Hashable, Identifiable, Sendable {
    nonisolated enum Severity: String, Codable, Comparable, Sendable {
        case info, limited, needsVirtualMac
        static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
        private var rank: Int { [.info: 0, .limited: 1, .needsVirtualMac: 2][self]! }
    }

    var severity: Severity
    /// 中文原文，存进 box.json，同时作为识别是哪一类问题的键；显示时用 localizedTitle
    var title: String
    var detail: String
    var id: String { title }

    var localizedTitle: String { Localization.shared.isEnglish ? Self.english[title]?.title ?? title : title }

    var localizedDetail: String {
        guard Localization.shared.isEnglish else { return detail }
        switch title {
        // 这两条的说明带有 spctl 的输出，只翻译固定部分
        case "已通过 Apple 公证检查":
            return detail == "来源已验证" ? "Source verified" : detail
        case "未通过 Apple 公证检查":
            let source = detail.components(separatedBy: "。打开时").first ?? detail
            return "\(source == "签名无效" ? "Invalid signature" : source). macOS will ask whether you trust it when you open it; make sure it comes from a source you trust."
        default:
            return Self.english[title]?.detail ?? detail
        }
    }

    /// 以中文标题为键的英文版本。AppInspector、PackageExtractor 里新增问题时要在这里补上
    private static let english: [String: (title: String, detail: String)] = [
        "需要管理员权限的辅助程序": ("Privileged helper tool",
                             "Installs a resident service that runs as root, which Native Isolation can’t contain."),
        "系统级后台服务": ("System-wide background service", "Registers a system service that runs at startup."),
        "系统扩展或内核扩展": ("System or kernel extension",
                      "Needs to be loaded into the kernel or the system extensions framework."),
        "硬件或音频驱动": ("Hardware or audio driver", "Drivers must be installed into system folders."),
        "开机自启动": ("Launch at login", "Login items are blocked; it only runs when you open it."),
        "访达集成": ("Finder integration", "Finder extensions such as sync status badges and context menu items won’t work."),
        "网络扩展": ("Network extension", "Network extensions such as VPNs and proxies require a system-wide install."),
        "自带苹果沙盒": ("Uses the App Sandbox",
                   "In MacBox it’s confined by MacBox’s sandbox instead and its data goes into the box. Always open it through MacBox."),
        "已通过 Apple 公证检查": ("Passed Apple notarization check", ""),
        "未通过 Apple 公证检查": ("Failed Apple notarization check", ""),
        "安装脚本已跳过": ("Installer scripts skipped",
                     "The package contains installer scripts (usually for installing background services or drivers), which MacBox didn’t run. If something doesn’t work, switch to Virtual Mac."),
    ]
}

/// box.json 的内容。字段只增不改；新增字段必须是可选类型，旧文件才能照常读取
nonisolated struct BoxConfig: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var bundleIdentifier: String
    var version: String?
    /// App/ 下的 .app 名称
    var appFolderName: String
    /// Source/ 下保存的原始文件（dmg/pkg/app），改用虚拟 Mac 时送进去安装
    var sourceName: String?
    var runtime: Runtime = .isolated
    var shareDownloads = true
    var showInLaunchpad = true
    var resetOnQuit = false
    /// 需要收回的偏好设置域前缀（App 及其安装器）
    var preferencePrefixes: [String] = []
    var issues: [CompatibilityIssue] = []
    /// 拖进来的是在线安装器：运行后会下载完整安装包，MacBox 负责接管
    var isInstaller = false
    var createdAt = Date()
    /// 运行时被挡住、问过要不要改用虚拟 Mac，用户选了“继续使用本机隔离”的拦截（BlockEvent.id）。
    /// 同样的拦截以后不再问：每次运行都写系统目录的 App，否则每次退出都会弹一次。
    /// 只记具体的拦截而不是一个“别再问”：出现新的一类拦截时仍然要问。换了运行环境、换了 App 时清空
    var acknowledgedBlocks: [String]?
}

/// 盒子在磁盘上的布局：
///
///     <uuid>.box/
///       box.json
///       App/<Name>.app     被隔离运行的 App
///       Source/            拖进来的原始文件
///       Home/              App 看到的“主目录”（文档、设置、缓存、钥匙串都在这里）
///       Prefs/             收回的偏好设置（运行时临时放回系统，退出后收回）
///       RestorePoint/      还原点（APFS 克隆）
///       tmp/
nonisolated struct BoxPaths: Hashable, Sendable {
    let url: URL

    var config: URL { url.appending(path: "box.json") }
    var appDirectory: URL { url.appending(path: "App", directoryHint: .isDirectory) }
    var sourceDirectory: URL { url.appending(path: "Source", directoryHint: .isDirectory) }
    var home: URL { url.appending(path: "Home", directoryHint: .isDirectory) }
    var prefs: URL { url.appending(path: "Prefs", directoryHint: .isDirectory) }
    /// 偏好设置借出的日志和本机设置的备份（见 PreferenceLease）：借出期间放在 Prefs 里，收回后删除
    var leaseJournal: URL { url.appending(path: "Prefs/.lease.json") }
    var nativePrefsBackup: URL { url.appending(path: "Prefs/.native", directoryHint: .isDirectory) }
    var restorePoint: URL { url.appending(path: "RestorePoint", directoryHint: .isDirectory) }
    var tmp: URL { url.appending(path: "tmp", directoryHint: .isDirectory) }
    var keychainPassword: URL { url.appending(path: ".keychain-password") }
    /// 正在用还原点替换数据（见 Box.rollBack）：开始前放下、全部换完才删除。
    /// MacBox 中途崩溃、被强制退出时，下次启动看到它就把还原重做一遍
    var rollbackMarker: URL { url.appending(path: ".rollback") }
    /// 正在创建的还原点：克隆完整之后才整体换上去（见 FileOps.replace(_:withStaged:)）
    var restorePointStaging: URL { url.appending(path: "RestorePoint.tmp", directoryHint: .isDirectory) }
    /// 安装器下载的安装包里取出的 App：取出、检查完才整体换上去
    var appStaging: URL { url.appending(path: "App.new", directoryHint: .isDirectory) }

    var keychains: URL { home.appending(path: "Library/Keychains", directoryHint: .isDirectory) }
    var boxKeychain: URL { keychains.appending(path: "box.keychain-db") }
    /// 系统按“主目录/Library/Keychains/login.keychain-db”找默认钥匙串，指向盒子钥匙串
    var loginKeychainLink: URL { keychains.appending(path: "login.keychain-db") }
    var downloads: URL { home.appending(path: "Downloads") }

    func app(_ config: BoxConfig) -> URL { appDirectory.appending(path: config.appFolderName) }
    func source(_ config: BoxConfig) -> URL? { config.sourceName.map { sourceDirectory.appending(path: $0) } }

    /// 还原点包含的内容。钥匙串在 Home 里，它的密码必须一起保存、一起还原，否则还原后钥匙串打不开
    var restorableItems: [String] { ["Home", "Prefs", keychainPassword.lastPathComponent] }
    /// 会被整体替换、删除的项目（FileOps.replace）。启动时按这些名字收拾中途崩溃留下的残局
    var replaceableItems: [String] { ["App", "Home", "Prefs", "tmp", keychainPassword.lastPathComponent, "RestorePoint"] }

    static func new(id: UUID) -> BoxPaths {
        BoxPaths(url: AppPaths.boxes.appending(path: "\(id.uuidString).box", directoryHint: .isDirectory))
    }

    /// 导入中的盒子：先在这个名字下建好（复制、取出 App、检查、准备钥匙串），box.json 写好之后才改名为正式的 .box。
    /// 读取盒子时只认 .box，导入到一半退出、崩溃时留下的不会变成一张「无法读取」的卡片，启动时删除
    static func importing(id: UUID) -> BoxPaths {
        BoxPaths(url: AppPaths.boxes.appending(path: "\(id.uuidString).box.\(importingSuffix)", directoryHint: .isDirectory))
    }
    static let importingSuffix = "partial"

    func loadConfig() throws -> BoxConfig {
        let decoder = JSONDecoder()
        return try decoder.decode(BoxConfig.self, from: Data(contentsOf: config))
    }

    func save(_ value: BoxConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: config, options: .atomic)
    }
}
