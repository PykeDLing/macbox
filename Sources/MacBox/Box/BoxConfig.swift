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
        title = code.title.0
        detail = code.detail(source: source).0
    }

    var localizedTitle: String { code.map { L($0.title.0, $0.title.1) } ?? title }

    var localizedDetail: String {
        guard let text = code?.detail(source: source) else { return detail }
        return L(text.0, text.1)
    }
}

nonisolated extension CompatibilityIssue.Code {
    var severity: CompatibilityIssue.Severity {
        switch self {
        case .privilegedHelper, .systemService, .systemExtension, .driver, .networkExtension: .needsVirtualMac
        case .loginItem, .finderIntegration, .notNotarized, .installerScriptsSkipped: .limited
        case .appSandbox, .notarized: .info
        }
    }

    /// 标题的中文和英文
    var title: (String, String) {
        switch self {
        case .privilegedHelper: ("需要管理员权限的辅助程序", "Privileged helper tool")
        case .systemService: ("系统级后台服务", "System-wide background service")
        case .systemExtension: ("系统扩展或内核扩展", "System or kernel extension")
        case .driver: ("硬件或音频驱动", "Hardware or audio driver")
        case .loginItem: ("开机自启动", "Launch at login")
        case .finderIntegration: ("访达集成", "Finder integration")
        case .networkExtension: ("网络扩展", "Network extension")
        case .appSandbox: ("自带苹果沙盒", "Uses the App Sandbox")
        case .notarized: ("已通过 Apple 公证检查", "Passed Apple notarization check")
        case .notNotarized: ("未通过 Apple 公证检查", "Failed Apple notarization check")
        case .installerScriptsSkipped: ("安装脚本已跳过", "Installer scripts skipped")
        }
    }

    /// 说明的中文和英文。公证检查的两条带上 spctl 给出的来源
    func detail(source: String?) -> (String, String) {
        switch self {
        case .privilegedHelper: ("会以 root 身份在系统里安装常驻服务，本机隔离无法容纳。",
                                 "Installs a resident service that runs as root, which Native Isolation can’t contain.")
        case .systemService: ("会注册开机即运行的系统服务。", "Registers a system service that runs at startup.")
        case .systemExtension: ("需要加载到系统内核或系统扩展框架中。",
                                "Needs to be loaded into the kernel or the system extensions framework.")
        case .driver: ("驱动需要安装到系统目录。", "Drivers must be installed into system folders.")
        case .loginItem: ("自启动项会被阻止，只有你打开时它才运行。", "Login items are blocked; it only runs when you open it.")
        case .finderIntegration: ("同步状态图标、右键菜单等访达扩展不可用。",
                                  "Finder extensions such as sync status badges and context menu items won’t work.")
        case .networkExtension: ("VPN、代理等网络扩展需要系统级安装。",
                                 "Network extensions such as VPNs and proxies require a system-wide install.")
        case .appSandbox: ("在 MacBox 中它改由 MacBox 的沙盒约束，数据存进盒子；请经由 MacBox 打开它。",
                           "In MacBox it’s confined by MacBox’s sandbox instead and its data goes into the box. Always open it through MacBox.")
        case .notarized: (source ?? "来源已验证", source ?? "Source verified")
        case .notNotarized: ("\(source ?? "签名无效")。打开时 macOS 会询问你是否信任它，请确认来源可靠。",
                             "\(source ?? "Invalid signature"). macOS will ask whether you trust it when you open it; make sure it comes from a source you trust.")
        case .installerScriptsSkipped: ("安装包带有安装脚本（通常用于安装后台服务或驱动），MacBox 没有执行它们。功能异常时请改用虚拟 Mac。",
                                        "The package contains installer scripts (usually for installing background services or drivers), which MacBox didn’t run. If something doesn’t work, switch to Virtual Mac.")
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
