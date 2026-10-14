import Darwin
import Foundation

/// 盒子里的 App 平时“上锁”：去掉 App 包内所有可执行文件的执行权限，只在 MacBox 启动它之前解锁。
///
/// MacBox 没在运行时守卫也不在，而盒子里的 App 是个真正的 App 包：被固定在程序坞里、被聚焦索引到、
/// 被系统在登录时“重新打开窗口”，都会经由 LaunchServices 直接启动它——不在沙盒里，用的是真实的主目录、
/// 钥匙串和偏好设置。没有执行权限时这些途径都启动不了它。
///
/// 范围：每个包（App 本身和嵌在里面的 .app、.appex、.xpc 等）的 Contents/MacOS 下的文件，
/// LaunchServices 和 launchd 只会从这里启动程序。执行权限不在代码签名的范围内，去掉、加回都不影响签名。
/// 解锁时只给看起来是程序的文件（Mach-O 或 #! 脚本）加回执行权限，放在 MacOS 里的数据文件保持原样
nonisolated enum AppLock {
    /// 上锁：去掉执行权限。可重复调用；有文件改不了时其余照常处理，最后抛出第一个错误
    static func lock(_ app: URL) throws {
        try forEachExecutable(in: app) { _, mode in
            mode & 0o111 == 0 ? nil : mode & ~0o111
        }
    }

    /// 解锁：给程序文件加回执行权限（有读权限的身份都可以执行）。可重复调用
    static func unlock(_ app: URL) throws {
        try forEachExecutable(in: app) { path, mode in
            let wanted = mode | ((mode & 0o444) >> 2)
            return wanted == mode || !looksExecutable(path) ? nil : wanted
        }
    }

    /// 已上锁：主程序没有执行权限。读不出主程序时按没上锁处理（调用方不应因此认为它安全）
    static func isLocked(_ app: URL) -> Bool {
        guard let executable = mainExecutable(of: app) else { return false }
        var info = stat()
        guard lstat(executable.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
        return info.st_mode & 0o111 == 0
    }

    /// 主程序路径：直接读 Info.plist（Bundle(url:) 会缓存同一路径的旧内容）
    static func mainExecutable(of app: URL) -> URL? {
        let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")) as? [String: Any]
        guard let name = info?["CFBundleExecutable"] as? String, !name.isEmpty else { return nil }
        return app.appending(path: "Contents/MacOS/\(name)")
    }

    /// 文件开头是 Mach-O（含通用二进制）或 #! 脚本
    static func looksExecutable(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count >= 2 else { return false }
        if head.starts(with: [0x23, 0x21]) { return true } // "#!"
        guard head.count == 4 else { return false }
        // 两种字节序的 MH_MAGIC、MH_MAGIC_64、FAT_MAGIC、FAT_MAGIC_64
        let magic = head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let machO: Set<UInt32> = [0xfeedface, 0xcefaedfe, 0xfeedfacf, 0xcffaedfe, 0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca]
        return machO.contains(magic)
    }

    /// 对每个包的 Contents/MacOS 里的普通文件（不跟随符号链接）按 change 给出的新权限修改
    private static func forEachExecutable(in app: URL, _ change: (String, mode_t) -> mode_t?) throws {
        var firstError: Error?
        let enumerator = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
        while let item = enumerator?.nextObject() as? URL {
            let folder = item.deletingLastPathComponent()
            guard folder.lastPathComponent == "MacOS", folder.deletingLastPathComponent().lastPathComponent == "Contents" else { continue }
            var info = stat()
            guard lstat(item.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  let mode = change(item.path, info.st_mode & 0o7777) else { continue }
            if chmod(item.path, mode) != 0, firstError == nil {
                let reason = String(cString: strerror(errno))
                firstError = MacBoxError(L("无法修改「\(item.lastPathComponent)」的执行权限：\(reason)",
                                           "Couldn’t change the execute permission of “\(item.lastPathComponent)”: \(reason)"))
            }
        }
        if let firstError { throw firstError }
    }
}
