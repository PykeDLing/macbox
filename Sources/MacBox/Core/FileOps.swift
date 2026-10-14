import Foundation

nonisolated struct MacBoxError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

nonisolated enum AppPaths {
    /// 环境变量 MACBOX_DATA_ROOT 可以把全部数据（含启动器）放到别处，用于测试，不碰真实的盒子
    static let override = ProcessInfo.processInfo.environment["MACBOX_DATA_ROOT"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    }

    static let root: URL = override ?? FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "MacBox", directoryHint: .isDirectory)

    static var boxes: URL { root.appending(path: "Boxes", directoryHint: .isDirectory) }
    static var virtualMac: URL { root.appending(path: "VirtualMac", directoryHint: .isDirectory) }
    static var restoreImages: URL { root.appending(path: "RestoreImages", directoryHint: .isDirectory) }
    /// 聚焦里的启动器（真正的 App 藏在 Boxes 里，只能经由 MacBox 在隔离中启动）
    static var launchers: URL {
        if let override { return override.appending(path: "Launchers", directoryHint: .isDirectory) }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/MacBox", directoryHint: .isDirectory)
    }
    static var realHome: URL { FileManager.default.homeDirectoryForCurrentUser }

    @discardableResult
    static func ensure(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// 把同步的磁盘操作放到后台线程执行，避免卡住主线程
nonisolated enum Background {
    @concurrent
    static func run<T: Sendable>(_ work: @Sendable () throws -> T) async rethrows -> T {
        try work()
    }
}

nonisolated enum FileOps {
    /// APFS 写时复制克隆（文件或目录，瞬间完成），非 APFS 或跨卷时退化为普通复制。目标必须不存在。
    /// 跨卷复制可能很慢，在主线程调用时请包在 Background.run 里
    static func clone(_ source: URL, to destination: URL) throws {
        if clonefile(source.path, destination.path, 0) != 0 {
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    static func removeIfExists(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) || isSymlink(url) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    /// 在目录中为文件名找一个不冲突的位置："a.dmg" → "a 2.dmg"
    static func uniqueURL(in directory: URL, name: String) -> URL {
        var candidate = directory.appending(path: name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)")
            index += 1
        }
        return candidate
    }

    static func contents(of directory: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return items.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// 解析符号链接后的真实路径（Seatbelt 按真实路径匹配规则）
    static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// 实际占用的磁盘空间（稀疏文件、APFS 克隆按实际分配计算）。目录会逐项遍历，可能较慢
    static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        while let item = enumerator?.nextObject() as? URL {
            total += Int64((try? item.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// 给从虚拟 Mac 带出来的文件打上 Gatekeeper 隔离标记
    static func markQuarantined(_ url: URL) {
        let value = String(format: "0081;%08x;MacBox;", UInt32(Date().timeIntervalSince1970))
        _ = value.withCString { setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func creationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }
}

nonisolated extension OperatingSystemVersion {
    var displayString: String {
        patchVersion == 0 ? "\(majorVersion).\(minorVersion)" : "\(majorVersion).\(minorVersion).\(patchVersion)"
    }
}
