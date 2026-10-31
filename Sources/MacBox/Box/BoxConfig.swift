import Foundation

/// 应用在哪里运行
nonisolated enum Runtime: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 在本机原生运行，文件、设置、钥匙串都收在盒子里
    case isolated
    /// 在一台独立的虚拟 Mac 中运行
    case virtualMac

    var id: String { rawValue }
    var title: String { self == .isolated ? String(localized: "本机隔离") : String(localized: "虚拟 Mac") }
    var summary: String {
        switch self {
        case .isolated: String(localized: "像普通 App 一样运行，写下的文件、设置和钥匙串都收在 MacBox 里，删除即清空。")
        case .virtualMac: String(localized: "在一台独立的虚拟 Mac 里运行，与本机完全隔开。兼容性最好，但占用约 30 GB、启动较慢。")
        }
    }
}

nonisolated struct CompatibilityIssue: Codable, Hashable, Identifiable, Sendable {
    nonisolated enum Severity: String, Codable, Comparable, Sendable {
        case info, limited, needsVirtualMac
        static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
        private var rank: Int { [.info: 0, .limited: 1, .needsVirtualMac: 2][self]! }
    }

    /// 哪一类问题。存进 box.json 的是 rawValue，显示的标题、说明按当前语言生成
    nonisolated enum Code: String, Codable, Sendable {
        case privilegedHelper, systemService, systemExtension, driver, loginItem, finderIntegration, networkExtension,
             appSandbox, notarized, notNotarized, installerScriptsSkipped
    }

    var severity: Severity
    /// 哪一类问题。0.4.0 及以前的 box.json 没有，读的时候按 title 对照出来（见 init(from:)）；
    /// 更新的版本加的、这一版认不出的为 nil，显示 title、detail 原文
    var code: Code?
    /// 公证检查时 spctl 给出的来源（开发者证书名、“Notarized Developer ID”），原样；没有时为 nil
    var source: String?
    /// 中文的标题、说明，不随界面语言变化。box.json 的字段只增不改：旧版 MacBox 要读它们，标题还是旧版识别问题的键。
    /// 这一版只在认不出 code 时显示它们
    var title: String
    var detail: String
    var id: String { code?.rawValue ?? title }

    init(_ code: Code, source: String? = nil) {
        severity = code.severity
        self.code = code
        self.source = source
        title = code.title(bundle: .simplifiedChinese)
        detail = code.detail(source: source, bundle: .simplifiedChinese)
    }

    var localizedTitle: String { code?.title() ?? title }

    var localizedDetail: String { code?.detail(source: source) ?? detail }
}

nonisolated extension CompatibilityIssue.Code {
    var severity: CompatibilityIssue.Severity {
        switch self {
        case .privilegedHelper, .systemService, .systemExtension, .driver, .networkExtension, .appSandbox: .needsVirtualMac
        case .loginItem, .finderIntegration, .notNotarized, .installerScriptsSkipped: .limited
        case .notarized: .info
        }
    }

    /// 标题。bundle 是取译文的地方：界面上用 .main，存进 box.json 的中文用 .simplifiedChinese
    func title(bundle: Bundle = .main) -> String {
        switch self {
        case .privilegedHelper: String(localized: "需要管理员权限的辅助程序", bundle: bundle)
        case .systemService: String(localized: "系统级后台服务", bundle: bundle)
        case .systemExtension: String(localized: "系统扩展或内核扩展", bundle: bundle)
        case .driver: String(localized: "硬件或音频驱动", bundle: bundle)
        case .loginItem: String(localized: "开机自启动", bundle: bundle)
        case .finderIntegration: String(localized: "访达集成", bundle: bundle)
        case .networkExtension: String(localized: "网络扩展", bundle: bundle)
        case .appSandbox: String(localized: "自带苹果沙盒", bundle: bundle)
        case .notarized: String(localized: "已通过 Apple 公证检查", bundle: bundle)
        case .notNotarized: String(localized: "未通过 Apple 公证检查", bundle: bundle)
        case .installerScriptsSkipped: String(localized: "安装脚本已跳过", bundle: bundle)
        }
    }

    /// 说明。公证检查的两条带上 spctl 给出的来源：认得出的固定说法换成界面语言（见 spctlSource）；
    /// 通过时的来源多半是开发者证书名（origin），专有名词，原样显示；没通过、又认不出的不显示英文原文
    func detail(source: String?, bundle: Bundle = .main) -> String {
        let known = source.flatMap { Self.spctlSource($0, bundle: bundle) }
        let rejection = known ?? String(localized: "签名没有通过检查", bundle: bundle)
        return switch self {
        case .privilegedHelper: String(localized: "会以 root 身份在系统里安装常驻服务，本机隔离无法容纳。", bundle: bundle)
        case .systemService: String(localized: "会注册开机即运行的系统服务。", bundle: bundle)
        case .systemExtension: String(localized: "需要加载到系统内核或系统扩展框架中。", bundle: bundle)
        case .driver: String(localized: "驱动需要安装到系统目录。", bundle: bundle)
        case .loginItem: String(localized: "自启动项会被阻止，只有你打开时它才运行。", bundle: bundle)
        case .finderIntegration: String(localized: "同步状态图标、右键菜单等访达扩展不可用。", bundle: bundle)
        case .networkExtension: String(localized: "VPN、代理等网络扩展需要系统级安装。", bundle: bundle)
        case .appSandbox: String(localized: "它已经被苹果的沙盒关在自己的容器里，读不到你的文稿和其他 App 的数据。本机隔离装不下它：套上 MacBox 的沙盒后，它一启动就会被系统结束。要完全隔开，请改用虚拟 Mac。", bundle: bundle)
        case .notarized: known ?? source ?? String(localized: "来源已验证", bundle: bundle)
        case .notNotarized: String(localized: "\(rejection)。打开时 macOS 会询问你是否信任它，请确认来源可靠。", bundle: bundle)
        case .installerScriptsSkipped: String(localized: "安装包带有安装脚本（通常用于安装后台服务或驱动），MacBox 没有执行它们。功能异常时请改用虚拟 Mac。", bundle: bundle)
        }
    }

    /// spctl 给出的来源（source=…）是英文的固定说法，换成界面语言；认不出的为 nil
    static func spctlSource(_ source: String, bundle: Bundle = .main) -> String? {
        switch source.lowercased() {
        case "no usable signature": String(localized: "没有可用的签名", bundle: bundle)
        case "unnotarized developer id": String(localized: "有开发者签名，但没有经过公证", bundle: bundle)
        case "notarized developer id": String(localized: "已公证的开发者签名", bundle: bundle)
        case "developer id": String(localized: "开发者签名", bundle: bundle)
        case "apple system": String(localized: "苹果系统软件", bundle: bundle)
        case "mac app store": String(localized: "来自 Mac App Store", bundle: bundle)
        case "explicit preference": String(localized: "你在系统设置里允许过", bundle: bundle)
        case "obsolete resource envelope": String(localized: "签名格式过旧", bundle: bundle)
        default: nil
        }
    }
}

nonisolated extension CompatibilityIssue {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        severity = try container.decode(Severity.self, forKey: .severity)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decode(String.self, forKey: .detail)
        if container.contains(.code) {
            code = try? container.decode(Code.self, forKey: .code) // 认不出的不让整个 box.json 读不出
            source = try container.decodeIfPresent(String.self, forKey: .source)
            return
        }
        // 0.4.0 及以前：按中文标题认，公证检查的来源夹在说明里
        code = Self.legacyCodes[title]
        switch code {
        case .notarized:
            source = detail == "来源已验证" ? nil : detail
        case .notNotarized:
            let source = detail.components(separatedBy: "。打开时").first ?? detail
            self.source = source == "签名无效" ? nil : source
        default:
            source = nil
        }
    }

    /// 0.1.0～0.4.0 写下的中文标题，旧文件靠它认出是哪一类问题。不要改，改措辞请改 Code.title
    private static let legacyCodes: [String: Code] = [
        "需要管理员权限的辅助程序": .privilegedHelper,
        "系统级后台服务": .systemService,
        "系统扩展或内核扩展": .systemExtension,
        "硬件或音频驱动": .driver,
        "开机自启动": .loginItem,
        "访达集成": .finderIntegration,
        "网络扩展": .networkExtension,
        "自带苹果沙盒": .appSandbox,
        "已通过 Apple 公证检查": .notarized,
        "未通过 Apple 公证检查": .notNotarized,
        "安装脚本已跳过": .installerScriptsSkipped,
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
    /// 不让应用联网（见 SandboxProfile.offlineRules）。没有这个字段（旧文件）、nil 都是允许
    var blockNetwork: Bool?
    /// 应用可以写入的盒子外的文件夹：选的时候解析出的真实路径，按添加的先后（见 WritableFolders）。没有时为 nil
    var writableFolders: [String]?
}

extension BoxConfig {
    /// 要不要在聚焦里放启动器。在线安装器在本机隔离里运行时没有：安装由 MacBox 接手，完成后换成真正的 App 才有。
    /// 在虚拟 Mac 里运行时 MacBox 不接手安装，“在线安装器”不起作用，照常按设置放
    var wantsLauncher: Bool { showInLaunchpad && !(isInstaller && runtime == .isolated) }

    /// 详情面板里「允许联网」开关的值。允许时不写这个字段，box.json 和旧版一样
    nonisolated var allowsNetwork: Bool {
        get { blockNetwork != true }
        set { blockNetwork = newValue ? nil : true }
    }

    /// 详情面板里「可以写入的文件夹」。没有时不写这个字段，box.json 和旧版一样
    nonisolated var writableFolderPaths: [String] {
        get { writableFolders ?? [] }
        set { writableFolders = newValue.isEmpty ? nil : newValue }
    }
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
///       Reports/           运行报告
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
    /// 运行报告（见 RunReport），每次运行一个 JSON，只留最近的几份
    var reports: URL { url.appending(path: "Reports", directoryHint: .isDirectory) }
    var tmp: URL { url.appending(path: "tmp", directoryHint: .isDirectory) }
    var keychainPassword: URL { url.appending(path: ".keychain-password") }
    /// 正在用还原点替换数据、正在清除数据（见 Box.rollBack、Box.clear）：开始前放下（内容写着是哪一种）、全部做完才删除。
    /// 做到一半失败、MacBox 中途崩溃或被强制退出时，下次打开应用前、下次启动 MacBox 时看到它就重做一遍
    var unfinishedMarker: URL { url.appending(path: ".unfinished") }
    /// 正在创建的还原点：克隆完整之后才整体换上去（见 FileOps.replace(_:withStaged:)）
    var restorePointStaging: URL { url.appending(path: "RestorePoint.tmp", directoryHint: .isDirectory) }
    /// 安装器下载的安装包里取出的 App：取出、检查完才整体换上去
    var appStaging: URL { url.appending(path: "App.new", directoryHint: .isDirectory) }
    /// 最近一次运行用的沙盒规则（见 SandboxProfile），便于排查
    var sandboxProfile: URL { url.appending(path: "sandbox.sb") }

    var keychains: URL { home.appending(path: "Library/Keychains", directoryHint: .isDirectory) }
    var boxKeychain: URL { keychains.appending(path: "box.keychain-db") }
    /// 系统按“主目录/Library/Keychains/login.keychain-db”找默认钥匙串，指向盒子钥匙串
    var loginKeychainLink: URL { keychains.appending(path: "login.keychain-db") }
    var downloads: URL { home.appending(path: "Downloads") }

    func app(_ config: BoxConfig) -> URL { appDirectory.appending(path: config.appFolderName) }
    func source(_ config: BoxConfig) -> URL? { config.sourceName.map { sourceDirectory.appending(path: $0) } }

    // 盒子根目录下的每一项按 App 在沙盒里能怎样碰它分成三类（规则见 SandboxProfile），每一项恰好属于一类：
    // App 可写的、MacBox 私有的、App 只能读的。新增一项时要放进其中一类（BoxLayoutTests 会检查）。
    // 文件夹要带 directoryHint: .isDirectory：私有的文件夹连同里面的一起挡，文件只挡它自己

    /// App 可写的：盒子里只有这几处，里面随便新建、改动、删除
    var writableItems: [URL] { [home, tmp, appDirectory] }
    /// MacBox 私有的，App 读不到：本机原来的偏好设置备份（登录状态、设备 ID）和借出的日志、还原点、钥匙串密码，
    /// 以及运行报告（记着它以前每次运行写了什么、连了哪里，不该由它来读）
    var privateItems: [URL] { [prefs, restorePoint, reports, keychainPassword] }
    /// App 只能读、不能改的：MacBox 自己的记录和拖进来的原始文件。MacBox 在沙盒外照着它们做事，
    /// App 改了它们，MacBox 就会照着改过的内容替它删改沙盒外的文件。正在建的还原点、正在取出的新 App 只在维护期间（App 没在运行）出现
    var readOnlyItems: [URL] { [config, sourceDirectory, sandboxProfile, unfinishedMarker, restorePointStaging, appStaging] }

    /// 骨架：MacBox 在沙盒外会顺着走的文件夹，文件夹本身不能删除、改名、换成符号链接（只有里面可写）。
    /// 可写的那几处的 subpath 也包括它自己：App 可以清空 App 文件夹后 rmdir，再在原处放一个指向 /Applications 的链接，
    /// MacBox 在沙盒外上锁、解锁、找安装包、准备主目录时就会顺着链接改到别处（去掉你自己装的同名 App 的执行权限、
    /// 把你真实的「下载」移走）。主目录里的 Library、Library/Keychains 同理：MacBox 每次启动前会在里面
    /// 替换 login.keychain-db，顺着链接替换的会是你自己的「登录」钥匙串
    var skeleton: [URL] { writableItems + [home.appending(path: "Library", directoryHint: .isDirectory), keychains] }

    /// 还原点包含的内容（名字）。钥匙串在 Home 里，它的密码必须一起保存、一起还原，否则还原后钥匙串打不开
    var restorableItems: [String] { [home, prefs, keychainPassword].map(\.lastPathComponent) }
    /// 会被整体替换、删除的项目（名字，见 FileOps.replace）。启动时按这些名字收拾中途崩溃留下的残局
    var replaceableItems: [String] { [appDirectory, home, prefs, tmp, keychainPassword, restorePoint].map(\.lastPathComponent) }

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
