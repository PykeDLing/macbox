import Foundation

/// 从 dmg / pkg / zip / app 中取出可运行的 .app，不执行任何安装脚本
nonisolated enum PackageExtractor {
    struct Extracted: Sendable {
        /// 取出的 App（在 destination 下）
        let app: URL
        var issues: [CompatibilityIssue] = []
    }

    /// 安装包里只有驱动、插件、系统组件，没有能单独运行的 App，只能装进虚拟 Mac。
    /// 单独一种错误类型，导入时可以据此提供“放进虚拟 Mac”，而不是只报个错就把用户晾在那里。
    /// 文字和 MacBoxError 一样在生成时定下语言
    nonisolated struct NeedsVirtualMac: LocalizedError, Sendable {
        let message = L("这个安装包里没有可以直接运行的 App，它需要在系统里安装组件。请改用虚拟 Mac。",
                        "This installer package has no app that can run on its own; it needs to install components into the system. Use Virtual Mac instead.")
        var errorDescription: String? { message }
    }

    static let supportedExtensions: Set<String> = ["dmg", "app", "pkg", "mpkg", "zip"]

    /// 导入前的快速检查，不读文件内容：不支持的东西不必先整个复制进盒子才报错。
    /// 东西存在时还要类型对得上：.app 是文件夹（App 包），.dmg / .zip 是普通文件，
    /// .pkg / .mpkg 两种都行（旧式的安装包是文件夹）；符号链接按它指向的东西判断。
    /// 不存在时（还没下载完、测试里的路径）只看扩展名，之后复制时自然会报错
    static func checkSupported(_ package: URL) throws {
        let ext = package.pathExtension.lowercased()
        let name = package.lastPathComponent
        let values = try? package.resolvingSymlinksInPath()
            .resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isReadableKey])
        if values?.isDirectory == true, !["app", "pkg", "mpkg"].contains(ext) {
            throw MacBoxError(L("「\(name)」是文件夹，不是安装包。请拖入 .dmg、.app、.pkg 或 .zip。",
                                "“\(name)” is a folder, not an installer. Drag in a .dmg, .app, .pkg or .zip file."))
        }
        guard supportedExtensions.contains(ext) else { throw unsupported(package) }
        guard let values else { return }
        if ext == "app", values.isDirectory != true { throw notAnApp(name) }
        if ["dmg", "zip"].contains(ext), values.isRegularFile != true {
            throw MacBoxError(L("「\(name)」不是有效的 .\(ext) 文件。", "“\(name)” isn’t a valid .\(ext) file."))
        }
        if values.isReadable == false {
            throw MacBoxError(L("没有权限读取「\(name)」。", "You don’t have permission to read “\(name)”."))
        }
    }

    private static func unsupported(_ package: URL) -> MacBoxError {
        let ext = package.pathExtension
        return MacBoxError(ext.isEmpty
            ? L("不支持这种文件。请拖入 .dmg、.app、.pkg 或 .zip。",
                "This kind of file isn’t supported. Drag in a .dmg, .app, .pkg or .zip file.")
            : L("不支持的文件类型：.\(ext)。请拖入 .dmg、.app、.pkg 或 .zip。",
                "Unsupported file type: .\(ext). Drag in a .dmg, .app, .pkg or .zip file."))
    }

    private static func notAnApp(_ name: String) -> MacBoxError {
        MacBoxError(L("「\(name)」不是有效的 App", "“\(name)” is not a valid app"))
    }

    /// 复制、展开都很耗时，整个过程在后台执行
    @concurrent
    static func extractApp(from package: URL, into destination: URL) async throws -> Extracted {
        try AppPaths.ensure(destination)
        let result = try await extract(package, into: destination, nesting: 0)
        inheritQuarantine(from: package, to: result.app)
        return result
    }

    /// 套在 dmg / zip 里的容器最多再往里走两层：正常的下载最多套两层（Foo.dmg.zip、zip 里的 dmg 里的 pkg），
    /// 更深的多半是压缩炸弹或互相包含，不跟进去
    private static let maxNesting = 2

    private static func extract(_ package: URL, into destination: URL, nesting: Int) async throws -> Extracted {
        switch package.pathExtension.lowercased() {
        case "app":
            // 直接拖进来的 App 可能是指向别处的符号链接：复制它指向的真实 App，名字沿用看到的
            guard let app = resolved(package, inside: nil, directory: true) else { throw notAnApp(package.lastPathComponent) }
            return Extracted(app: try copyApp(app, named: package.lastPathComponent, into: destination))
        case "dmg":
            return try await fromDiskImage(package, into: destination, nesting: nesting)
        case "pkg", "mpkg":
            return try await fromInstallerPackage(package, into: destination)
        case "zip":
            return try await fromZip(package, into: destination, nesting: nesting)
        default:
            throw unsupported(package)
        }
    }

    private static func fromDiskImage(_ image: URL, into destination: URL, nesting: Int) async throws -> Extracted {
        let mount = try await DiskImage.attach(image)
        do {
            // 有的 dmg 把 App 放在子文件夹里，所以往下找三层
            let result = try await fromFolder(mount.mountPoint, appDepth: 3, into: destination, nesting: nesting,
                                              notFound: L("磁盘映像里没有找到 App 或安装包",
                                                          "No app or installer package was found in the disk image"))
            await DiskImage.detach(mount.device)
            return result
        } catch {
            await DiskImage.detach(mount.device)
            throw error
        }
    }

    private static func fromZip(_ zip: URL, into destination: URL, nesting: Int) async throws -> Extracted {
        let work = FileManager.default.temporaryDirectory.appending(path: "MacBox-zip-\(UUID().uuidString)")
        // 里面套着的 dmg / pkg 在递归里就已经复制进 destination 了，返回后再删展开的目录
        defer { try? FileManager.default.removeItem(at: work) }
        try await Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        return try await fromFolder(work, appDepth: .max, into: destination, nesting: nesting,
                                    notFound: L("压缩包里没有找到 App 或安装包", "No app or installer package was found in the archive"))
    }

    /// 在挂载的 dmg 或展开的 zip 里找：先找 App（顶层的优先，再往下找），
    /// 没有再找里面套着的安装包、磁盘映像、压缩包，逐个试到取出 App 为止
    private static func fromFolder(_ root: URL, appDepth: Int, into destination: URL, nesting: Int,
                                   notFound: String) async throws -> Extracted {
        if let app = pickApp(FileOps.contents(of: root), inside: root)
            ?? pickApp(findItems(in: root, extensions: ["app"], maxDepth: appDepth), inside: root) {
            return Extracted(app: try copyApp(app.url, named: app.name, into: destination))
        }
        let containers = nesting < maxNesting ? nestedContainers(in: root) : []
        var failures: [(container: URL, error: any Error)] = []
        for container in containers {
            do {
                return try await extract(container, into: destination, nesting: nesting + 1)
            } catch {
                failures.append((container, error))
            }
        }
        // 都失败时，“只能用虚拟 Mac”比“没找到”更有用（例如 dmg 里只有一个驱动安装包）
        if let needsVirtualMac = failures.lazy.map(\.error).first(where: { $0 is NeedsVirtualMac }) { throw needsVirtualMac }
        // 否则报用户拖进来的这个容器里没找到：里面附带的压缩包（Documentation.zip、坏的压缩包）各自的错误
        // 会把人引到不相干的文件上。只有安装包、磁盘映像出错的原因附在后面（排在最前的那个，通常是主安装包，
        // 或 Foo.dmg.zip 里的 dmg）：这时里面确实有它，光说“没找到”说不清
        guard let failed = failures.first(where: { ["pkg", "mpkg", "dmg"].contains($0.container.pathExtension.lowercased()) }) else {
            throw MacBoxError(notFound)
        }
        let name = failed.container.lastPathComponent, detail = failed.error.localizedDescription
        throw MacBoxError(L("\(notFound)。「\(name)」：\(detail)", "\(notFound). “\(name)”: \(detail)"))
    }

    /// 展开 pkg，只取出其中的 .app；安装脚本不执行
    private static func fromInstallerPackage(_ pkg: URL, into destination: URL) async throws -> Extracted {
        let work = FileManager.default.temporaryDirectory.appending(path: "MacBox-pkg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        try await Shell.run("/usr/sbin/pkgutil", ["--expand-full", pkg.path, work.path])

        let hasScripts = FileManager.default.enumerator(atPath: work.path)?
            .contains { ["preinstall", "postinstall"].contains(($0 as? NSString)?.lastPathComponent) } == true
        guard let app = pickApp(findItems(in: work, extensions: ["app"], maxDepth: .max), inside: work) else {
            throw NeedsVirtualMac()
        }
        var result = Extracted(app: try copyApp(app.url, named: app.name, into: destination))
        if hasScripts {
            result.issues.append(.init(severity: .limited, title: "安装脚本已跳过",
                                       detail: "安装包带有安装脚本（通常用于安装后台服务或驱动），MacBox 没有执行它们。功能异常时请改用虚拟 Mac。"))
        }
        return result
    }

    /// 目录下扩展名符合的项目，最多往下 maxDepth 层；不进入 App 包和找到的项目内部，不跟随指向文件夹的符号链接。
    /// 文件夹形式的 .pkg 要进去：产品归档（productbuild 做的，厂商安装包多半是这种）展开后
    /// App 在 <组件>.pkg/Payload 下。找套着的安装包时 pkg 本身就是要找的，自然不会再往里走
    private static func findItems(in directory: URL, extensions: Set<String>, maxDepth: Int) -> [URL] {
        var found: [URL] = []
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles])
        while let item = enumerator?.nextObject() as? URL {
            let ext = item.pathExtension.lowercased()
            if extensions.contains(ext) { found.append(item) }
            if ext == "app" || extensions.contains(ext) || (enumerator?.level ?? 0) >= maxDepth {
                enumerator?.skipDescendants()
            }
        }
        return found
    }

    /// dmg / zip 里套着的安装包、磁盘映像、压缩包，卸载程序不要，符号链接的规则同 App。
    /// 安装包优先（dmg 里常见 Installer/Foo.pkg），其次磁盘映像、压缩包；同一类里顶层的优先，
    /// 再按体积从大到小：主安装包通常比附带的组件包、卸载脚本包大
    private static func nestedContainers(in root: URL) -> [URL] {
        let rank = ["pkg": 0, "mpkg": 0, "dmg": 1, "zip": 2]
        let rootDepth = root.standardizedFileURL.pathComponents.count
        return findItems(in: root, extensions: Set(rank.keys), maxDepth: 3)
            .filter { !isUninstaller($0.lastPathComponent) }
            .compactMap { item -> (url: URL, rank: Int, depth: Int, size: Int64)? in
                guard let real = resolved(item, inside: root, directory: nil) else { return nil }
                return (item, rank[item.pathExtension.lowercased()] ?? rank.count,
                        item.standardizedFileURL.pathComponents.count - rootDepth, FileOps.allocatedSize(of: real))
            }
            .sorted { ($0.rank, $0.depth, -$0.size) < ($1.rank, $1.depth, -$1.size) }
            .map(\.url)
    }

    static func isUninstaller(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains("uninstall") || name.contains("卸载") || name.contains("卸載")
    }

    /// 多个 App 时跳过卸载程序，优先体积最大的那个。符号链接按它指向的真实 App 算（Foo.app → .payload/Foo.app），
    /// 但必须指向容器（挂载的卷、展开的目录）里面：指到外面的（/Applications/…）会把本机的 App 当成盒子里的
    private static func pickApp(_ items: [URL], inside root: URL) -> (url: URL, name: String)? {
        items.filter { $0.pathExtension.lowercased() == "app" && !isUninstaller($0.lastPathComponent) }
            .compactMap { item in resolved(item, inside: root, directory: true).map { (url: $0, name: item.lastPathComponent) } }
            .map { ($0, FileOps.allocatedSize(of: $0.url)) }
            .max { $0.1 < $1.1 }?.0
    }

    /// 解析符号链接后的真实位置；必须真实存在、（给了 root 时）在 root 之内，directory 不为 nil 时还要类型对得上
    private static func resolved(_ item: URL, inside root: URL?, directory: Bool?) -> URL? {
        guard let real = realpath(item.path, nil) else { return nil }
        let path = String(cString: real)
        free(real)
        if let root {
            let base = FileOps.realPath(root)
            guard path.hasPrefix(base.hasSuffix("/") ? base : base + "/") else { return nil }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        if let directory, isDirectory.boolValue != directory { return nil }
        return URL(fileURLWithPath: path, isDirectory: isDirectory.boolValue)
    }

    /// 复制真实的 App 包，放到 destination 下的 name。复制完再确认一遍：盒子里的 App 不能是指向别处的链接
    private static func copyApp(_ app: URL, named name: String, into destination: URL) throws -> URL {
        let target = destination.appending(path: name)
        try FileOps.removeIfExists(target)
        try FileOps.clone(app, to: target)
        guard !FileOps.isSymlink(target), (try? target.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            try? FileOps.removeIfExists(target)
            throw notAnApp(name)
        }
        return target
    }

    // MARK: - 隔离标记

    private static let quarantineAttribute = "com.apple.quarantine"

    /// 下载来的安装包带着“来自互联网”标记。从 dmg、zip 取出的 App 自然带着它，pkgutil 展开的却没有：
    /// pkg 本该由安装器交给 Gatekeeper 检查，MacBox 跳过了安装器，标记再一丢就没人检查了。
    /// 取出的 App 缺这个标记时，把安装包上的原样补到整个 App 包（文件和文件夹，不碰符号链接）。
    /// 之后 verifyAndTrust 照旧：通过公证的去掉标记，没通过的保留，由系统在打开时拦下
    private static func inheritQuarantine(from package: URL, to app: URL) {
        guard let value = quarantine(of: package, followLinks: true), quarantine(of: app, followLinks: false) == nil else { return }
        setQuarantine(value, on: app)
        let enumerator = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
        while let item = enumerator?.nextObject() as? URL { setQuarantine(value, on: item) }
    }

    static func quarantine(of url: URL, followLinks: Bool = false) -> Data? {
        let options = followLinks ? 0 : XATTR_NOFOLLOW
        let size = getxattr(url.path, quarantineAttribute, nil, 0, 0, options)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, quarantineAttribute, $0.baseAddress, size, 0, options) }
        return read > 0 ? data.prefix(read) : nil
    }

    /// 只给普通文件和文件夹打标记
    private static func setQuarantine(_ value: Data, on url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0, [S_IFREG, S_IFDIR].contains(info.st_mode & S_IFMT) else { return }
        changeAttribute(of: url) {
            value.withUnsafeBytes { setxattr(url.path, quarantineAttribute, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) } == 0
        }
    }

    /// 去掉整个 App 包上的隔离标记：verifyAndTrust 确认通过公证之后调用。和补标记一样逐项处理、不跟随符号链接
    /// （链接自己的标记也去掉，它指向的东西不碰，可能在包外）。不用 `xattr -dr`：它碰到只读的项目
    /// 会报权限不足，标记就一直留着，而 inheritQuarantine 连只读的项目也会补上标记
    static func clearQuarantine(_ app: URL) {
        func clear(_ url: URL) {
            guard quarantine(of: url) != nil else { return }
            changeAttribute(of: url) { removexattr(url.path, quarantineAttribute, XATTR_NOFOLLOW) == 0 }
        }
        clear(app)
        let enumerator = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
        while let item = enumerator?.nextObject() as? URL { clear(item) }
    }

    /// 写或删扩展属性：先直接试；只读的普通文件和文件夹（安装包里常见 0444 / 0555）要临时给属主加上写权限
    /// 再试一次，完了恢复原来的权限。符号链接不改权限（chmod 会改到它指向的东西）
    private static func changeAttribute(of url: URL, _ change: () -> Bool) {
        var info = stat()
        guard lstat(url.path, &info) == 0, !change(),
              [S_IFREG, S_IFDIR].contains(info.st_mode & S_IFMT), info.st_mode & S_IWUSR == 0,
              chmod(url.path, info.st_mode | S_IWUSR) == 0 else { return }
        _ = change()
        chmod(url.path, info.st_mode & 0o7777)
    }
}
