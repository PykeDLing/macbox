import AppKit
import Foundation
import UniformTypeIdentifiers

/// 在 ~/Applications/MacBox 里放一个和原 App 同名同图标的启动器，
/// 从聚焦、程序坞打开它时，由 MacBox 在隔离中启动真正的 App。
/// 启动器还替应用向系统声明它能打开的链接和文件类型（见 claims）：盒子里的 App 本身不登记到系统（见 AppRegistration），
/// 不声明的话，在浏览器里点 magnet: 链接、在访达里双击 .torrent 都到不了它。
/// 所有改动经由这个 actor 串行执行：并发安装时“找空闲名字”会互相踩到，产生重复的启动器
actor Launcher {
    static let shared = Launcher()

    /// 启动器的写法，记在它的 Info.plist（MacBoxLauncherVersion，没有的是 1）。写法变了就加一，
    /// MacBox 启动时把旧的重写一遍（见 BoxStore.reload）：
    /// - 2：脚本不再用 `open -g`。-g 让 MacBox 留在后台，协作式激活下后台的 MacBox 让不出前台，
    ///   从聚焦打开的 App 窗口留在原来的 App 后面，已经在运行的也切不过去
    /// - 3：启动器里不再是脚本，而是一个能收系统事件的小程序（Sources/MacBoxLauncher），并且声明应用能打开的
    ///   链接和文件类型。脚本收不了事件：系统把启动器打开了，链接却丢了
    static let version = 3

    /// 没有小程序可用时（swift test、没经过 build.sh 的构建）照旧写脚本，版本记 2：
    /// 换成带着小程序的 MacBox 之后会被重写
    static let scriptVersion = 2

    /// MacBox.app 里带着的小程序（build.sh 放进去的）
    nonisolated static let bundledProgram: URL? = Bundle.main.url(forResource: "MacBoxLauncher", withExtension: nil)

    /// 这个 MacBox 写出来的启动器是哪一版
    private nonisolated static var written: Int { bundledProgram == nil ? scriptVersion : version }

    /// 启动器替应用向系统声明了什么，界面上的说明用
    nonisolated struct Claims: Equatable, Sendable {
        /// 链接的 scheme（magnet、thunder……）
        var schemes: [String] = []
        /// 文件的扩展名，不带点
        var extensions: [String] = []
        var isEmpty: Bool { schemes.isEmpty && extensions.isEmpty }
    }

    /// 启动器所属的盒子。直接读 Info.plist：Bundle(url:) 会缓存同一路径的旧内容
    nonisolated static func boxID(of launcher: URL) -> String? {
        info(of: launcher)?["MacBoxBoxID"] as? String
    }

    nonisolated static func version(of launcher: URL) -> Int {
        info(of: launcher)?["MacBoxLauncherVersion"] as? Int ?? 1
    }

    private nonisolated static func info(of launcher: URL) -> NSDictionary? {
        NSDictionary(contentsOf: launcher.appending(path: "Contents/Info.plist"))
    }

    private func all() -> [URL] {
        FileOps.contents(of: AppPaths.launchers).filter { $0.pathExtension == "app" && Self.boxID(of: $0) != nil }
    }

    /// 这个盒子是否已有启动器
    func hasLauncher(for id: UUID) -> Bool {
        all().contains { Self.boxID(of: $0) == id.uuidString }
    }

    /// 这个盒子的启动器要不要（重新）安装：还没有，或者是旧写法的
    func needsInstall(for id: UUID) -> Bool {
        let mine = all().filter { Self.boxID(of: $0) == id.uuidString }
        return mine.isEmpty || mine.contains { Self.version(of: $0) < Self.written }
    }

    /// 这个盒子的启动器声明了什么（安装时记在它的 Info.plist 里）。没有启动器时为 nil
    func claims(for id: UUID) -> Claims? {
        guard let launcher = all().first(where: { Self.boxID(of: $0) == id.uuidString }), let info = Self.info(of: launcher) else { return nil }
        return Claims(schemes: info["MacBoxClaimedSchemes"] as? [String] ?? [],
                      extensions: info["MacBoxClaimedExtensions"] as? [String] ?? [])
    }

    /// 删除不属于任何现存盒子的启动器，以及旧版留下的、all() 看不到的启动器（见 removeHiddenAndNested）
    func removeOrphans(keeping ids: Set<UUID>) async {
        for launcher in all() where !ids.contains(where: { $0.uuidString == Self.boxID(of: launcher) }) {
            await delete(launcher)
        }
        await removeHiddenAndNested()
    }

    /// 旧版没有处理名称里的“/”和开头的“.”：启动器建在了子文件夹里（「夸克网盘/工作」→ 夸克网盘/工作.app），
    /// 或者成了隐藏文件。all() 只看顶层、不看隐藏文件，找不到它们，每次启动都再建一个新的，删除盒子时也删不掉。
    /// 按 MacBoxBoxID 认出这些启动器，不管主人在不在都删掉：主人还在的，同步时会在顶层用处理过的名字重建。
    /// 只扫启动器文件夹，代价很小，每次启动都扫一遍
    private func removeHiddenAndNested() async {
        let root = AppPaths.launchers.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(at: AppPaths.launchers, includingPropertiesForKeys: nil) else { return }
        var stale: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            guard item.pathExtension == "app" else { continue }
            enumerator.skipDescendants() // 不进启动器包里面
            let parent = item.deletingLastPathComponent().standardizedFileURL.path
            let visible = parent == root && !item.lastPathComponent.hasPrefix(".")
            if !visible, Self.boxID(of: item) != nil { stale.append(item) }
        }
        for launcher in stale {
            await delete(launcher)
            // 删空了的子文件夹也删掉（rmdir 只删空文件夹）
            var folder = launcher.deletingLastPathComponent().standardizedFileURL
            while folder.path.hasPrefix(root + "/"), rmdir(folder.path) == 0 {
                folder = folder.deletingLastPathComponent().standardizedFileURL
            }
        }
    }

    /// 应用名称（可以在详情里随意改）转成能直接作为文件名的样子：
    /// - “/”在访达里显示的名字对应文件系统里的“:”，换过去显示出来仍是原名；否则会建出一层子文件夹
    /// - 去掉开头的“.”，否则成了隐藏文件。两种情况 all() 都找不到它，启动器会越积越多
    /// - 留出“ 99.app”的位置，不超过文件名长度上限（255 字节），不截断半个字
    nonisolated static func fileName(for name: String) -> String {
        var result = name.replacingOccurrences(of: "/", with: ":")
        while result.hasPrefix(".") { result.removeFirst() }
        result = result.trimmingCharacters(in: .whitespaces)
        while result.utf8.count > 200 { result.removeLast() }
        return result.isEmpty ? "App" : result
    }

    /// 同名应用装了多份（比如两个网盘账号）时，启动器依次叫「夸克网盘」「夸克网盘 2」
    private func freeURL(for config: BoxConfig) -> URL {
        let base = Self.fileName(for: config.name)
        var index = 1
        while true {
            let name = index == 1 ? base : "\(base) \(index)"
            let candidate = AppPaths.launchers.appending(path: "\(name).app", directoryHint: .isDirectory)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    /// 没有小程序可用时的脚本：经由 URL 交给 MacBox。不加 -g：MacBox 要先到前台，才能把前台让给盒子里的 App（见 version）
    nonisolated static func script(for id: UUID) -> String {
        "#!/bin/sh\nexec /usr/bin/open \"macbox://open/\(id.uuidString)\"\n"
    }

    // MARK: - 链接和文件类型

    /// 能打开“任何文件”的声明不照抄：照抄的话，每个文件的「打开方式」里都有它，没有别的 App 能开的文件双击还会进盒子
    private nonisolated static let wildcardTypes: Set<String> = ["public.item", "public.data", "public.content"]
    /// 类型声明里的图标不照抄（启动器里没有那些图标文件）
    private nonisolated static let iconKeys = ["UTTypeIconFile", "UTTypeIconFiles", "UTTypeIcons"]

    /// 像不像一个 URL scheme（RFC 3986）。file 是本机文件，不算链接
    nonisolated static func isScheme(_ text: String) -> Bool {
        text != "file" && text.wholeMatch(of: /[a-z][a-z0-9+.\-]*/) != nil
    }

    /// 启动器要替应用声明的链接和文件类型，按应用自己的 Info.plist 来，写进启动器的 Info.plist（keys）：
    /// - 链接（CFBundleURLTypes）：照抄，但这台 Mac 上已经有别的 App 处理的不声明（handledElsewhere，见 handler）。
    ///   scheme 没有“谁优先”的设置，两个 App 都声明时交给谁说不准；http、mailto 也因此不会被盒子里的浏览器占用；
    /// - 文件（CFBundleDocumentTypes）：照抄，级别一律降为 Alternate。实测：只有它能开的类型，双击照样交给它；
    ///   别的 App 以默认级别声明了同一种类型时，别的 App 优先，它只出现在「打开方式」里。不抢你现在的默认打开方式；
    /// - 类型声明：应用自己导出、导入的类型一起抄成“导入的类型”，否则它私有的扩展名系统认不出是哪种类型。
    /// 内容都来自盒子里 App 的 Info.plist，App 改得到：只取认识的键，值的类型不对的整条不要
    nonisolated static func claims(of appInfo: [String: Any], handledElsewhere: (String) -> Bool) -> (keys: [String: Any], summary: Claims) {
        var summary = Claims()
        var urlTypes: [[String: Any]] = []
        for type in appInfo["CFBundleURLTypes"] as? [[String: Any]] ?? [] {
            var schemes: [String] = []
            for scheme in (type["CFBundleURLSchemes"] as? [String] ?? []).map({ $0.lowercased() })
            where isScheme(scheme) && !summary.schemes.contains(scheme) && !schemes.contains(scheme) && !handledElsewhere(scheme) {
                schemes.append(scheme)
            }
            guard !schemes.isEmpty else { continue }
            summary.schemes += schemes
            var entry: [String: Any] = ["CFBundleURLSchemes": schemes, "CFBundleTypeRole": "Viewer"]
            if let name = type["CFBundleURLName"] as? String { entry["CFBundleURLName"] = name }
            urlTypes.append(entry)
        }

        // 类型标识符 → 扩展名，说明里用；应用自己声明的类型系统里查不到（它没有登记）
        var declarations: [[String: Any]] = []
        var extensionsOfType: [String: [String]] = [:]
        for key in ["UTExportedTypeDeclarations", "UTImportedTypeDeclarations"] {
            for var declaration in appInfo[key] as? [[String: Any]] ?? [] {
                guard let identifier = (declaration["UTTypeIdentifier"] as? String)?.lowercased(), !identifier.isEmpty,
                      extensionsOfType[identifier] == nil else { continue }
                let tags = (declaration["UTTypeTagSpecification"] as? [String: Any])?["public.filename-extension"]
                extensionsOfType[identifier] = ((tags as? [String]) ?? (tags as? String).map { [$0] } ?? []).map { $0.lowercased() }
                for icon in iconKeys { declaration[icon] = nil }
                declarations.append(declaration)
            }
        }

        var documentTypes: [[String: Any]] = []
        func note(_ extensions: [String]) {
            for item in extensions where !item.isEmpty && !summary.extensions.contains(item) { summary.extensions.append(item) }
        }
        for type in appInfo["CFBundleDocumentTypes"] as? [[String: Any]] ?? [] {
            var entry: [String: Any] = ["CFBundleTypeRole": type["CFBundleTypeRole"] as? String ?? "Viewer",
                                        "LSHandlerRank": type["LSHandlerRank"] as? String == "None" ? "None" : "Alternate"]
            // 写了类型标识符时，系统只看标识符、不看扩展名
            if let contentTypes = type["LSItemContentTypes"] as? [String] {
                let kept = contentTypes.filter { !wildcardTypes.contains($0.lowercased()) }
                guard !kept.isEmpty else { continue }
                entry["LSItemContentTypes"] = kept
                for identifier in kept {
                    note(extensionsOfType[identifier.lowercased()] ?? UTType(identifier)?.tags[.filenameExtension] ?? [])
                }
            } else {
                let extensions = (type["CFBundleTypeExtensions"] as? [String] ?? []).map { $0.lowercased() }
                    .filter { !$0.isEmpty && $0 != "*" && !$0.contains("/") }
                guard !extensions.isEmpty else { continue }
                entry["CFBundleTypeExtensions"] = extensions
                note(extensions)
            }
            if let name = type["CFBundleTypeName"] as? String { entry["CFBundleTypeName"] = name }
            if let package = type["LSTypeIsPackage"] as? Bool { entry["LSTypeIsPackage"] = package }
            documentTypes.append(entry)
        }

        var keys: [String: Any] = [:]
        if !urlTypes.isEmpty { keys["CFBundleURLTypes"] = urlTypes }
        if !documentTypes.isEmpty {
            keys["CFBundleDocumentTypes"] = documentTypes
            if !declarations.isEmpty { keys["UTImportedTypeDeclarations"] = declarations }
        }
        return (keys, summary)
    }

    /// 一种链接现在由谁处理
    nonisolated enum SchemeHandler: Sendable {
        /// 没有人
        case nobody
        /// 这个应用留在盒子外的另一份：拖进 MacBox 的那份原件（还在「下载」里、在挂着的磁盘映像上）。
        /// 你已经把它装进了盒子，链接该交给盒子里的这份
        case strayCopy
        /// 别的应用，或者装在「应用程序」里的同一个应用：不改到盒子里来
        case another
    }

    /// 问系统这种链接现在由谁处理（identifier：盒子里这个应用的标识符）。只问系统的登记，不碰那个 App 的文件：
    /// 它可能在「下载」里，MacBox 去读会弹窗问权限。
    /// - 盒子里的 App 不算别人：它运行的时候系统会自己把它登记上，退出后 MacBox 才撤销；
    /// - 别的盒子的启动器算别人（标识符不同）：同一个应用装了两个盒子时，先装的那个声明，点链接打开哪一份是确定的；
    /// - 「应用程序」里已经不在了的 App 留下的登记不算
    nonisolated static func handler(of scheme: String, identifier: String) -> SchemeHandler {
        guard let url = URL(string: "\(scheme):"), let handler = NSWorkspace.shared.urlForApplication(toOpen: url) else { return .nobody }
        let path = handler.standardizedFileURL.path
        let boxes = Set([AppPaths.boxes.standardizedFileURL.path, FileOps.realPath(AppPaths.boxes)])
        if boxes.contains(where: { path.hasPrefix($0 + "/") }) { return .nobody }
        let installed = ["/Applications/", "/System/", AppPaths.realHome.appending(path: "Applications").path + "/"]
        if installed.contains(where: { path.hasPrefix($0) }) {
            return FileManager.default.fileExists(atPath: path) ? .another : .nobody
        }
        let copies = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: identifier).map(\.standardizedFileURL.path)
        return copies.contains(path) ? .strayCopy : .another
    }

    /// 让启动器明确接管一种链接（原来交给盒子外的那份原件的）：两个 App 声明同一种链接时系统选谁说不准，实测和登记的先后无关。
    /// 链接可以这样接管，系统不会问；文件类型不行，改默认打开方式系统一定弹窗问你，所以文件类型只声明、不接管
    nonisolated static func takeOver(_ scheme: String, launcher: URL) async {
        try? await NSWorkspace.shared.setDefaultApplication(at: launcher, toOpenURLsWithScheme: scheme)
    }

    /// program：启动器里的小程序，nil 时写脚本（不声明链接和文件类型：脚本收不到它们）。返回声明了什么。
    /// handler、takeOver 是为了测试时不去问、不去改系统的登记
    @discardableResult
    func install(paths: BoxPaths, config: BoxConfig, program: URL? = Launcher.bundledProgram,
                 handler: @Sendable (_ scheme: String, _ identifier: String) -> SchemeHandler = Launcher.handler,
                 takeOver: @Sendable (_ scheme: String, _ launcher: URL) async -> Void = Launcher.takeOver) async throws -> Claims {
        await remove(boxID: config.id)
        let launcher = freeURL(for: config)
        let contents = launcher.appending(path: "Contents")
        let macOS = contents.appending(path: "MacOS")
        let resources = contents.appending(path: "Resources")
        try AppPaths.ensure(macOS)
        try AppPaths.ensure(resources)

        var info: [String: Any] = [
            "CFBundleIdentifier": "dev.pyke.MacBox.launcher.\(config.id.uuidString)",
            "CFBundleName": config.name,
            "CFBundleDisplayName": config.name,
            "CFBundleExecutable": "launch",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": config.version ?? "1.0",
            "LSUIElement": true,
            "MacBoxBoxID": config.id.uuidString,
            "MacBoxLauncherVersion": program == nil ? Self.scriptVersion : Self.version,
        ]
        // 沿用原 App 的图标（.icns 或 Assets.car）。App 改得到它们：把图标换成指向 ~/.ssh 的链接的话，
        // 跟随着克隆就是不在沙盒里的 MacBox 把盒子外的东西复制到了启动器里，而沙盒不挡读 ~/Applications。
        // 所以只克隆盒子里的 App 目录下的普通文件，文件名里不许有 /（同 AppIcon.load）
        let app = paths.app(config)
        let appResources = app.appending(path: "Contents/Resources")
        let appInfo = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")) as? [String: Any] ?? [:]
        if var iconFile = appInfo["CFBundleIconFile"] as? String, !iconFile.isEmpty, !iconFile.contains("/") {
            if !iconFile.hasSuffix(".icns") { iconFile += ".icns" }
            if (try? FileOps.cloneRegularFile(appResources.appending(path: iconFile), inside: paths.appDirectory,
                                              to: resources.appending(path: "AppIcon.icns"))) != nil {
                info["CFBundleIconFile"] = "AppIcon"
            }
        }
        if let iconName = appInfo["CFBundleIconName"] as? String,
           (try? FileOps.cloneRegularFile(appResources.appending(path: "Assets.car"), inside: paths.appDirectory,
                                          to: resources.appending(path: "Assets.car"))) != nil {
            info["CFBundleIconName"] = iconName
        }
        var claims = Claims()
        // 原来交给盒子外那份原件的链接：登记好之后明确接管
        var strays: [String] = []
        if program != nil {
            // 小程序按路径认盒子里的 App：它在隔离中启动好了，才把链接、文件交给它
            info["MacBoxAppPath"] = FileOps.realPath(app)
            // 试用、测试用的 MacBox 建的启动器只找建它的这个 MacBox：macbox:// 的默认处理者是你平时用的那个，
            // 它不认识测试数据里的盒子
            if AppPaths.override != nil, Bundle.main.bundleURL.pathExtension == "app" {
                info["MacBoxHost"] = Bundle.main.bundleURL.path
            }
            // 在虚拟 Mac 里运行的应用收不到：链接、文件进不了虚拟 Mac
            if config.acceptsLinks, config.runtime == .isolated {
                let identifier = config.bundleIdentifier
                let declared = Self.claims(of: appInfo) { handler($0, identifier) == .another }
                strays = declared.summary.schemes.filter { handler($0, identifier) == .strayCopy }
                info.merge(declared.keys) { _, new in new }
                claims = declared.summary
                info["MacBoxClaimedSchemes"] = claims.schemes
                info["MacBoxClaimedExtensions"] = claims.extensions
            }
        }
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appending(path: "Info.plist"))

        let executable = macOS.appending(path: "launch")
        if let program {
            // 小程序是 MacBox 自己带的，不是 App 改得到的东西。读出来再写，不克隆：克隆会把扩展属性一起带过去，
            // 下载来的 MacBox.app 里的文件带着隔离标记，带着它的启动器第一次打开会被系统拦下检查
            try Data(contentsOf: program).write(to: executable)
        } else {
            try Self.script(for: config.id).write(to: executable, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        _ = try? await Shell.run(Shell.lsregister, ["-f", launcher.path])
        for scheme in strays { await takeOver(scheme, launcher) }
        return claims
    }

    /// 只删除属于这个盒子的启动器
    func remove(boxID id: UUID) async {
        for item in all() where Self.boxID(of: item) == id.uuidString {
            await delete(item)
        }
    }

    /// 先撤销登记再删：聚焦、「打开方式」里不留指向已删除启动器的记录
    private func delete(_ launcher: URL) async {
        _ = try? await Shell.run(Shell.lsregister, ["-u", launcher.path])
        try? FileOps.removeTree(launcher)
    }
}
