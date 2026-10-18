import AppKit
import Foundation

nonisolated struct AppInfo: Sendable {
    let url: URL
    let name: String
    let bundleIdentifier: String
    let version: String?
    let executable: URL
}

/// 读取 App 信息，并在运行前静态检查它会不会做本机隔离挡不住的事
nonisolated enum AppInspector {
    /// 一律直接读 Contents/Info.plist，不用 Bundle(url:)：NSBundle（CFBundle 也一样）按路径缓存实例，
    /// 同一路径上的 App 被换掉之后（在线安装器被换成真正的 App、App 自我更新改了可执行文件名）
    /// 仍然返回旧内容，拿旧的可执行文件路径去启动只会让 sandbox-exec 报 execvp 失败
    static func info(of app: URL) throws -> AppInfo {
        guard let info = infoDictionary(of: app) else {
            throw MacBoxError(L("「\(app.lastPathComponent)」不是有效的 App", "“\(app.lastPathComponent)” is not a valid app"))
        }
        // 可执行文件只能是 Contents/MacOS 里的一个文件名，带路径分隔符的不认；
        // 和 Bundle 一样：没写 CFBundleExecutable 时用包名，并要求文件真实存在
        let executableName = (info["CFBundleExecutable"] as? String) ?? app.deletingPathExtension().lastPathComponent
        let executable = executableName.isEmpty || executableName.contains("/")
            ? nil : app.appending(path: "Contents/MacOS/\(executableName)")
        guard let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty,
              let executable, FileManager.default.fileExists(atPath: executable.path) else {
            throw MacBoxError(L("「\(app.lastPathComponent)」缺少标识符或可执行文件",
                                  "“\(app.lastPathComponent)” is missing a bundle identifier or executable"))
        }
        let localized = localizedInfoStrings(of: app)
        let name = [localized["CFBundleDisplayName"], localized["CFBundleName"], info["CFBundleDisplayName"], info["CFBundleName"]]
            .lazy.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        return AppInfo(url: app,
                       name: name ?? app.deletingPathExtension().lastPathComponent,
                       bundleIdentifier: identifier,
                       version: info["CFBundleShortVersionString"] as? String,
                       executable: executable)
    }

    /// 包（.app / .appex / .xpc）的 Info.plist，直接读文件，理由见 info(of:)
    static func infoDictionary(of bundle: URL) -> [String: Any]? {
        NSDictionary(contentsOf: bundle.appending(path: "Contents/Info.plist")) as? [String: Any]
    }

    /// 按用户的语言偏好挑出的 InfoPlist 本地化（显示名）。传统格式是各 .lproj/InfoPlist.strings；
    /// 新格式（String Catalog 的编译产物）是 Resources/InfoPlist.loctable，一个文件里按语言分组。
    /// 只在真有 InfoPlist 本地化的语言里挑：最匹配的 .lproj 可能只有别的 .strings。
    /// 语言偏好显式传入 Locale.preferredLanguages（含 MacBox 自己的界面语言设置），
    /// 不传时还会受测试进程等主程序自身支持哪些语言的影响
    private static func localizedInfoStrings(of app: URL) -> [String: Any] {
        let resources = app.appending(path: "Contents/Resources")
        let table = NSDictionary(contentsOf: resources.appending(path: "InfoPlist.loctable")) as? [String: Any] ?? [:]
        var available = table.keys.filter { table[$0] is [String: Any] && $0 != "LocProvenance" }
        available += FileOps.contents(of: resources)
            .filter { $0.pathExtension == "lproj" && FileManager.default.fileExists(atPath: $0.appending(path: "InfoPlist.strings").path) }
            .map { $0.deletingPathExtension().lastPathComponent }
        guard !available.isEmpty else { return [:] }
        for language in Bundle.preferredLocalizations(from: available, forPreferences: Locale.preferredLanguages) {
            if let strings = table[language] as? [String: Any] { return strings }
            if let strings = NSDictionary(contentsOf: resources.appending(path: "\(language).lproj/InfoPlist.strings")) as? [String: Any] {
                return strings
            }
        }
        return [:]
    }

    /// Chromium / Electron 系 App：自带的子进程沙盒无法在 MacBox 的沙盒里再次建立
    static func isChromium(_ app: URL) -> Bool {
        let frameworks = app.appending(path: "Contents/Frameworks")
        let enumerator = FileManager.default.enumerator(at: frameworks, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles])
        while let item = enumerator?.nextObject() as? URL {
            if item.lastPathComponent == "chrome_crashpad_handler" || item.lastPathComponent == "Electron Framework.framework" {
                return true
            }
            if enumerator?.level ?? 0 > 6 { enumerator?.skipDescendants() }
        }
        return false
    }

    /// 启动参数：Chromium 系 App 关闭它自己的子进程沙盒（否则会反复崩溃），由 MacBox 的沙盒统一约束。
    /// 要遍历 App 包，在后台调用
    static func launchArguments(for app: URL) -> [String] { isChromium(app) ? ["--no-sandbox"] : [] }

    // MARK: - 在线安装器

    /// 在线安装器：名字、文件名或标识符里有完整的 install / installer / setup 一词，或中文名里有“安装”。
    /// 按词而不是按子串匹配：Uninstaller、App Cleaner & Uninstaller、卸载工具都不算。
    /// 误判的代价很大（导入后立即当安装器运行、不建启动器、禁止挂载磁盘映像、退出时把它新建的
    /// 安装包当成“下载好的完整安装包”接手），而且没有界面能改回来，所以宁可漏判。
    /// downloader 本身是一类普通软件（4K Video Downloader+、JDownloader），
    /// 只有同时像个安装器“桩程序”（没有 Frameworks、整个包很小）时才算
    static func looksLikeInstaller(_ info: AppInfo) -> Bool {
        let texts = [info.name, info.url.deletingPathExtension().lastPathComponent]
            + info.bundleIdentifier.split(separator: ".").map(String.init)
        var downloader = false
        for text in texts {
            let words = words(in: text)
            for (index, word) in words.enumerated() {
                switch word {
                case "install", "installer":
                    // “Un Install”“Un-Installer”拆开后仍是卸载
                    if index == 0 || words[index - 1] != "un" { return true }
                case "setup":
                    return true
                case "downloader":
                    downloader = true
                default:
                    // 中文没有空格，一段连续的汉字算一个词：夸克网盘安装器、微信安装助手
                    if (word.contains("安装") || word.contains("安裝")) && !word.contains("卸载") && !word.contains("卸載") {
                        return true
                    }
                }
            }
        }
        return downloader && looksLikeStub(info.url)
    }

    /// 把名字拆成小写的词：按非字母数字分隔，再在驼峰（WeChatSetup → we chat setup，
    /// WPSInstaller → wps installer）、字母与数字、拉丁字母与汉字的交界处拆开
    static func words(in text: String) -> [String] {
        var words: [String] = []
        var current: [Character] = []
        func flush() {
            if !current.isEmpty { words.append(String(current).lowercased()) }
            current = []
        }
        func isHan(_ c: Character) -> Bool { c.unicodeScalars.first?.properties.isIdeographic == true }
        let characters = Array(text)
        for (index, c) in characters.enumerated() {
            guard c.isLetter || c.isNumber else {
                flush()
                continue
            }
            if let last = current.last {
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                if (last.isLowercase && c.isUppercase)
                    || (last.isUppercase && c.isUppercase && next?.isLowercase == true)
                    || last.isNumber != c.isNumber
                    || isHan(last) != isHan(c) {
                    flush()
                }
            }
            current.append(c)
        }
        flush()
        return words
    }

    /// 安装器桩程序：确实是个 App 包，没有 Frameworks 和 PlugIns，整个包不到 30 MB（只数到超过为止，大 App 不必遍历完）
    private static func looksLikeStub(_ app: URL) -> Bool {
        let contents = app.appending(path: "Contents")
        guard FileManager.default.fileExists(atPath: contents.appending(path: "Info.plist").path),
              FileOps.contents(of: contents.appending(path: "Frameworks")).isEmpty,
              FileOps.contents(of: contents.appending(path: "PlugIns")).isEmpty else { return false }
        let limit: Int64 = 30 << 20
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        while let item = enumerator?.nextObject() as? URL {
            total += Int64((try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
            if total > limit { return false }
        }
        return true
    }

    // MARK: - 偏好设置域

    /// 旧规则：一律取标识符前三段。com.google.Chrome.canary 会借走正式版 Chrome 的设置，
    /// com.jetbrains.intellij.ce 会借走 Ultimate 的。新建盒子请用 preferencePrefixes(for:identifier:)
    static func preferencePrefix(for identifier: String) -> String {
        identifier.split(separator: ".").prefix(3).joined(separator: ".")
    }

    /// 多个产品共用前三段标识符的厂商（com.google.Chrome / .canary / .beta、com.apple.dt.Xcode、
    /// com.microsoft.edgemac.Beta），这些标识符不往上放宽。jp.co.canon：打印、扫描工具（jp.co.canon.ij.*）
    /// 装在 /Library/Printers、/Library/Image Capture 和「应用程序」的深层文件夹里，查本机 App 时看不到
    private static let sharedVendors: Set<String> = [
        "com.apple", "com.google", "com.microsoft", "com.adobe", "org.mozilla", "com.jetbrains",
        "com.brave", "com.operasoftware", "com.vivaldi", "org.chromium", "com.github", "com.amazon",
        "jp.co.canon",
    ]

    /// 国家顶级域下惯用的二级域（jp.co、cn.com、uk.co、au.com、kr.or、jp.ac…）：和 com 一样是公共后缀，
    /// 再下一段才是厂商
    private static let secondLevelDomains: Set<String> = [
        "co", "com", "net", "org", "ac", "gov", "edu", "ne", "or", "go", "gob", "gen", "ltd", "plc", "nom", "mil", "sch",
    ]

    /// 反写时顺序搞反的写法（foo.com.cn → com.cn.foo、foo.co.uk → co.uk.foo）里的国家顶级域。
    /// 只收惯用二级域注册的这些，com.jd、com.qq、com.hp 这类两个字母的厂商名不能当成后缀
    private static let secondLevelCountries: Set<String> = [
        "cn", "uk", "jp", "kr", "tw", "hk", "au", "nz", "br", "sg", "za", "il", "in", "mx", "ar", "tr",
    ]

    /// 标识符里表示厂商的段数：通常是两段（com.foo），公共后缀是两段时是三段（jp.co.canon、cn.com.foo、com.cn.foo）
    static func vendorLength(of components: [Substring]) -> Int {
        guard components.count >= 3 else { return 2 }
        let first = components[0].lowercased(), second = components[1].lowercased()
        let isCountry = first.count == 2 && first.allSatisfy { $0.isASCII && $0.isLetter }
        if isCountry && secondLevelDomains.contains(second) { return 3 }
        if ["com", "net", "org", "co", "ac", "edu", "gov"].contains(first) && secondLevelCountries.contains(second) { return 3 }
        return 2
    }

    /// 借出的偏好设置域前缀，每个前缀覆盖 <前缀> 和 <前缀>.*：
    /// - App 自己的完整标识符；
    /// - 包里的登录项、Helpers、XPC 服务、扩展、内嵌 App 各自的标识符：只收同一厂商（厂商段相同，见 vendorLength）、
    ///   比厂商段长、不比 App 自己的更宽、也不与本机安装的其他 App 重叠的。Sparkle、Electron 这类第三方组件的
    ///   标识符所有用它的 App 都一样，借走会把本机其他 App 的设置一起换掉；
    /// - 标识符比厂商段多两段以上时放宽到厂商段加一段，覆盖同系列的安装器和 helper
    ///   （com.quark.clouddrive.installer → com.quark.clouddrive；jp.co.、cn.com. 这类两段后缀下是五段以上
    ///   放宽到前四段，jp.co.foo.bar 放宽成 jp.co.foo 就盖住了整个厂商），但放宽后的前缀不能属于共用前缀的厂商，
    ///   也不能等于、覆盖或落在本机安装的其他 App 的标识符之下。
    /// 不足三段的标识符（com.foo）只能原样返回，借出时仍会覆盖 com.foo.*。
    /// 会读本机「应用程序」文件夹里各 App 的 Info.plist，在后台调用
    static func preferencePrefixes(for app: URL, identifier: String) -> [String] {
        preferencePrefixes(for: app, identifier: identifier, installed: installedApplicationIdentifiers())
    }

    /// installed：本机安装的 App 的标识符（测试时可以指定）
    static func preferencePrefixes(for app: URL, identifier: String, installed: Set<String>) -> [String] {
        let others = otherApps(in: installed, excluding: identifier)
        func overlapsOthers(_ prefix: String) -> Bool { otherApp(overlapping: prefix, in: others) != nil }
        func vendor(_ id: String) -> String {
            let components = id.lowercased().split(separator: ".")
            return components.prefix(vendorLength(of: components)).joined(separator: ".")
        }
        func covers(_ prefix: String, _ domain: String) -> Bool { domain == prefix || domain.hasPrefix(prefix + ".") }

        var main = identifier
        let components = identifier.split(separator: ".", omittingEmptySubsequences: false)
        let vendorCount = vendorLength(of: components)
        if components.count >= vendorCount + 2, !components.contains(where: \.isEmpty), !sharedVendors.contains(vendor(identifier)) {
            let widened = components.prefix(vendorCount + 1).joined(separator: ".")
            if !overlapsOthers(widened) { main = widened }
        }

        let nested = nestedBundleIdentifiers(in: app).filter { id in
            let components = id.split(separator: ".")
            return isWellFormed(id) && components.count > vendorLength(of: components)
                && vendor(id) == vendor(identifier) && !sharedVendors.contains(vendor(id))
                && !covers(id, main) && !overlapsOthers(id)
        }
        // 去掉被其他前缀覆盖的，保持“App 自己的在前”
        var result: [String] = []
        for prefix in [main] + nested where !result.contains(where: { covers($0, prefix) }) {
            result.removeAll { covers(prefix, $0) }
            result.append(prefix)
        }
        return result
    }

    /// 本机安装的 App 里和这个前缀（或域）重叠的那个：标识符相等、在它之下、或者覆盖它。不区分大小写。
    /// own 自己的本机副本、以及本来就在 <own>.* 之下的，借出范围本来就包含，不算“其他 App”
    static func installedApp(overlapping prefix: String, installed: Set<String>, excluding own: String) -> String? {
        otherApp(overlapping: prefix, in: otherApps(in: installed, excluding: own))
    }

    /// 去掉 own 和 <own>.*，按名字排序（找到的总是同一个）
    private static func otherApps(in installed: Set<String>, excluding own: String) -> [String] {
        let own = own.lowercased()
        return installed.filter { id in
            let id = id.lowercased()
            return id != own && !id.hasPrefix(own + ".")
        }.sorted()
    }

    private static func otherApp(overlapping prefix: String, in others: [String]) -> String? {
        let prefix = prefix.lowercased()
        return others.first { id in
            let id = id.lowercased()
            return id == prefix || id.hasPrefix(prefix + ".") || prefix.hasPrefix(id + ".")
        }
    }

    private static func isWellFormed(_ id: String) -> Bool {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.contains(where: \.isEmpty)
            && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_" }
    }

    /// 包里会以独立进程运行、有自己偏好设置域的部件：登录项、Helpers、XPC 服务、扩展、内嵌的 App，
    /// 以及 Frameworks 里各框架自带的 Helpers / XPC 服务。往下最多三层（内嵌 App 里的登录项等）
    static func nestedBundleIdentifiers(in app: URL) -> [String] {
        var identifiers: [String] = []
        let kinds: Set<String> = ["app", "appex", "xpc"]
        func visit(_ bundle: URL, depth: Int) {
            let contents = bundle.appending(path: "Contents")
            var places = ["Library/LoginItems", "Helpers", "XPCServices", "PlugIns", "Frameworks", "Resources",
                          "MacOS", "SharedSupport"].map { contents.appending(path: $0) }
            for framework in FileOps.contents(of: contents.appending(path: "Frameworks")) where framework.pathExtension == "framework" {
                let current = framework.appending(path: "Versions/Current")
                places += [current, current.appending(path: "Helpers"), current.appending(path: "XPCServices"),
                           current.appending(path: "Resources")]
            }
            for place in places {
                for item in FileOps.contents(of: place) where kinds.contains(item.pathExtension.lowercased()) && !FileOps.isSymlink(item) {
                    if let id = infoDictionary(of: item)?["CFBundleIdentifier"] as? String, !identifiers.contains(id) {
                        identifiers.append(id)
                    }
                    if depth < 3 { visit(item, depth: depth + 1) }
                }
            }
        }
        visit(app, depth: 1)
        return identifiers
    }

    /// 本机安装的 App 的标识符：/Applications、/System/Applications、~/Applications 顶层，
    /// 以及其中普通文件夹里的一层（Utilities、厂商文件夹）。直接读 Info.plist：不经过 Bundle 缓存，也不碰 LaunchServices
    static func installedApplicationIdentifiers(in directories: [URL]? = nil) -> Set<String> {
        let directories = directories ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory),
        ]
        var identifiers: Set<String> = []
        func add(_ app: URL) {
            if let id = infoDictionary(of: app)?["CFBundleIdentifier"] as? String, !id.isEmpty { identifiers.insert(id) }
        }
        for directory in directories {
            for item in FileOps.contents(of: directory) {
                if item.pathExtension == "app" {
                    add(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    FileOps.contents(of: item).filter { $0.pathExtension == "app" }.forEach(add)
                }
            }
        }
        return identifiers
    }

    // MARK: - 兼容性

    /// box.json 里存问题的代码，标题和说明在显示时生成（见 CompatibilityIssue.Code）
    @concurrent
    static func scan(_ app: URL) async -> [CompatibilityIssue] {
        var issues: [CompatibilityIssue] = []
        let contents = app.appending(path: "Contents")
        func has(_ relative: String) -> Bool {
            !FileOps.contents(of: contents.appending(path: relative)).isEmpty
        }

        if has("Library/LaunchServices") || infoDictionary(of: app)?["SMPrivilegedExecutables"] != nil {
            issues.append(CompatibilityIssue(.privilegedHelper))
        }
        if has("Library/LaunchDaemons") {
            issues.append(CompatibilityIssue(.systemService))
        }
        if has("Library/SystemExtensions") || containsItem(in: contents, withExtensions: ["kext", "systemextension"]) {
            issues.append(CompatibilityIssue(.systemExtension))
        }
        if FileOps.contents(of: contents.appending(path: "PlugIns")).contains(where: { $0.pathExtension == "driver" }) {
            issues.append(CompatibilityIssue(.driver))
        }
        if has("Library/LoginItems") || has("Library/LaunchAgents") {
            issues.append(CompatibilityIssue(.loginItem))
        }
        for appex in FileOps.contents(of: contents.appending(path: "PlugIns")) where appex.pathExtension == "appex" {
            let point = (infoDictionary(of: appex)?["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String ?? ""
            if point.contains("FinderSync") || point.contains("fileprovider") {
                issues.append(CompatibilityIssue(.finderIntegration))
                break
            }
        }

        let entitlements = (try? await Shell.run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", app.path]))?.output ?? ""
        if entitlements.contains("com.apple.developer.networking.networkextension") {
            issues.append(CompatibilityIssue(.networkExtension))
        }
        if entitlements.contains("com.apple.security.app-sandbox") {
            issues.append(CompatibilityIssue(.appSandbox))
        }
        return issues
    }

    /// 用 Gatekeeper 同样的规则检查 App：通过公证的，去掉盒子里副本的“来自互联网”标记，
    /// 免得系统在 MacBox 已经确认过之后再弹一次“确定要打开吗”；没通过的保留标记，由系统拦下。
    /// 去标记要遍历整个 App 包，在后台执行
    @concurrent
    static func verifyAndTrust(_ app: URL) async -> CompatibilityIssue {
        let result = try? await Shell.execute("/usr/sbin/spctl", ["--assess", "--type", "execute", "-vv", app.path])
        let text = (result?.output ?? "") + (result?.error ?? "")
        func field(_ key: String) -> String? {
            text.split(separator: "\n").first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
        }
        if result?.status == 0 {
            // 只读的文件也要去掉（xattr -dr 做不到），见 clearQuarantine
            PackageExtractor.clearQuarantine(app)
            return CompatibilityIssue(.notarized, source: field("origin") ?? field("source"))
        }
        return CompatibilityIssue(.notNotarized, source: field("source"))
    }

    private static func containsItem(in directory: URL, withExtensions extensions: Set<String>) -> Bool {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles])
        while let item = enumerator?.nextObject() as? URL {
            if extensions.contains(item.pathExtension) { return true }
            if item.pathExtension == "framework" { enumerator?.skipDescendants() }
        }
        return false
    }
}
