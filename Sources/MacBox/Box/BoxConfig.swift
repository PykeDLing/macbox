import Foundation

/// 应用在哪里运行
nonisolated enum Runtime: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 在本机原生运行，文件、设置、钥匙串都收在盒子里
    case isolated
    /// 在一台独立的虚拟 Mac 中运行
    case virtualMac

    var id: String { rawValue }
    var title: String { self == .isolated ? "本机隔离" : "虚拟 Mac" }
    var summary: String {
        switch self {
        case .isolated: "像普通 App 一样运行，写下的文件、设置和钥匙串都收在 MacBox 里，删除即清空。"
        case .virtualMac: "在一台独立的虚拟 Mac 里运行，与本机完全隔开。兼容性最好，但占用约 30 GB、启动较慢。"
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
    var title: String
    var detail: String
    var id: String { title }
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
    var nativePrefsBackup: URL { url.appending(path: "Prefs/.native", directoryHint: .isDirectory) }
    var restorePoint: URL { url.appending(path: "RestorePoint", directoryHint: .isDirectory) }
    var tmp: URL { url.appending(path: "tmp", directoryHint: .isDirectory) }
    var keychainPassword: URL { url.appending(path: ".keychain-password") }

    var keychains: URL { home.appending(path: "Library/Keychains", directoryHint: .isDirectory) }
    var boxKeychain: URL { keychains.appending(path: "box.keychain-db") }
    /// 系统按“主目录/Library/Keychains/login.keychain-db”找默认钥匙串，指向盒子钥匙串
    var loginKeychainLink: URL { keychains.appending(path: "login.keychain-db") }
    var downloads: URL { home.appending(path: "Downloads") }

    func app(_ config: BoxConfig) -> URL { appDirectory.appending(path: config.appFolderName) }
    func source(_ config: BoxConfig) -> URL? { config.sourceName.map { sourceDirectory.appending(path: $0) } }

    /// 还原点包含的内容
    var restorableItems: [String] { ["Home", "Prefs"] }

    static func new(id: UUID) -> BoxPaths {
        BoxPaths(url: AppPaths.boxes.appending(path: "\(id.uuidString).box", directoryHint: .isDirectory))
    }

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
