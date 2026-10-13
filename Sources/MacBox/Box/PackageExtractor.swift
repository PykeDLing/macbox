import Foundation

/// 从 dmg / pkg / zip / app 中取出可运行的 .app，不执行任何安装脚本
nonisolated enum PackageExtractor {
    struct Extracted: Sendable {
        /// 取出的 App（在 destination 下）
        let app: URL
        var issues: [CompatibilityIssue] = []
    }

    static let supportedExtensions: Set<String> = ["dmg", "app", "pkg", "mpkg", "zip"]

    /// 复制、展开都很耗时，整个过程在后台执行
    @concurrent
    static func extractApp(from package: URL, into destination: URL) async throws -> Extracted {
        try AppPaths.ensure(destination)
        switch package.pathExtension.lowercased() {
        case "app":
            return Extracted(app: try copyApp(package, into: destination))
        case "dmg":
            return try await fromDiskImage(package, into: destination)
        case "pkg", "mpkg":
            return try await fromInstallerPackage(package, into: destination)
        case "zip":
            return try await fromZip(package, into: destination)
        default:
            throw MacBoxError("不支持的文件类型：.\(package.pathExtension)。请拖入 .dmg、.app、.pkg 或 .zip。")
        }
    }

    private static func fromDiskImage(_ image: URL, into destination: URL) async throws -> Extracted {
        let mount = try await DiskImage.attach(image)
        do {
            // 有的 dmg 把 App 放在子文件夹里
            let items = FileOps.contents(of: mount.mountPoint)
            if let app = pickApp(items) ?? pickApp(findApps(in: mount.mountPoint, maxDepth: 3)) {
                let copied = try copyApp(app, into: destination)
                await DiskImage.detach(mount.device)
                return Extracted(app: copied)
            }
            if let pkg = items.first(where: { ["pkg", "mpkg"].contains($0.pathExtension.lowercased()) }) {
                let result = try await fromInstallerPackage(pkg, into: destination)
                await DiskImage.detach(mount.device)
                return result
            }
            throw MacBoxError("磁盘映像里没有找到 App 或安装包")
        } catch {
            await DiskImage.detach(mount.device)
            throw error
        }
    }

    /// 展开 pkg，只取出其中的 .app；安装脚本不执行
    private static func fromInstallerPackage(_ pkg: URL, into destination: URL) async throws -> Extracted {
        let work = FileManager.default.temporaryDirectory.appending(path: "MacBox-pkg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        try await Shell.run("/usr/sbin/pkgutil", ["--expand-full", pkg.path, work.path])

        let hasScripts = FileManager.default.enumerator(atPath: work.path)?
            .contains { ["preinstall", "postinstall"].contains(($0 as? NSString)?.lastPathComponent) } == true
        guard let app = pickApp(findApps(in: work)) else {
            throw MacBoxError("这个安装包里没有可以直接运行的 App，它需要在系统里安装组件。请改用虚拟 Mac。")
        }
        var result = Extracted(app: try copyApp(app, into: destination))
        if hasScripts {
            result.issues.append(.init(severity: .limited, title: "安装脚本已跳过",
                                       detail: "安装包带有安装脚本（通常用于安装后台服务或驱动），MacBox 没有执行它们。功能异常时请改用虚拟 Mac。"))
        }
        return result
    }

    private static func fromZip(_ zip: URL, into destination: URL) async throws -> Extracted {
        let work = FileManager.default.temporaryDirectory.appending(path: "MacBox-zip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        try await Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        guard let app = pickApp(findApps(in: work)) else { throw MacBoxError("压缩包里没有找到 App") }
        return Extracted(app: try copyApp(app, into: destination))
    }

    /// 目录下的 .app（不进入 App 包内部）
    private static func findApps(in directory: URL, maxDepth: Int = .max) -> [URL] {
        var apps: [URL] = []
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles])
        while let item = enumerator?.nextObject() as? URL {
            if item.pathExtension == "app" {
                apps.append(item)
                enumerator?.skipDescendants()
            } else if (enumerator?.level ?? 0) >= maxDepth {
                enumerator?.skipDescendants()
            }
        }
        return apps
    }

    /// 多个 App 时跳过卸载程序，优先体积最大的那个
    private static func pickApp(_ items: [URL]) -> URL? {
        items.filter {
            $0.pathExtension == "app" && !$0.lastPathComponent.localizedCaseInsensitiveContains("uninstall")
                && !$0.lastPathComponent.contains("卸载")
        }
        .map { ($0, FileOps.allocatedSize(of: $0)) }
        .max { $0.1 < $1.1 }?.0
    }

    private static func copyApp(_ app: URL, into destination: URL) throws -> URL {
        let target = destination.appending(path: app.lastPathComponent)
        try FileOps.removeIfExists(target)
        try FileOps.clone(app, to: target)
        return target
    }
}
