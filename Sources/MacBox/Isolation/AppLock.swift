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
        try forEachExecutable(in: app) { _, _, mode in
            mode & 0o111 == 0 ? nil : mode & ~0o111
        }
    }

    /// 解锁：给程序文件加回执行权限（有读权限的身份都可以执行）。可重复调用
    static func unlock(_ app: URL) throws {
        try forEachExecutable(in: app) { folder, name, mode in
            let wanted = mode | ((mode & 0o444) >> 2)
            guard wanted != mode else { return nil }
            let file = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard file >= 0 else { return nil }
            defer { close(file) }
            return looksExecutable(file: file) ? wanted : nil
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
        let file = open(path, O_RDONLY | O_CLOEXEC)
        guard file >= 0 else { return false }
        defer { close(file) }
        return looksExecutable(file: file)
    }

    private static func looksExecutable(file: Int32) -> Bool {
        var head = [UInt8](repeating: 0, count: 4)
        let count = read(file, &head, head.count)
        guard count >= 2 else { return false }
        if head.starts(with: [0x23, 0x21]) { return true } // "#!"
        guard count == 4 else { return false }
        // 两种字节序的 MH_MAGIC、MH_MAGIC_64、FAT_MAGIC、FAT_MAGIC_64
        let magic = head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let machO: Set<UInt32> = [0xfeedface, 0xcefaedfe, 0xfeedfacf, 0xcffaedfe, 0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca]
        return machO.contains(magic)
    }

    /// 对每个包的 Contents/MacOS 里的普通文件按 change 给出的新权限修改
    /// （change 的参数：所在文件夹的描述符、文件名、原来的权限；返回 nil 表示不改）。
    ///
    /// 逐级用文件描述符往下走（openat + O_NOFOLLOW），不按路径字符串：App 包在盒子里，盒子里的进程改得到它，
    /// 可能在 MacBox 遍历的同时把其中一级换成指向别处的符号链接（比如 /Applications 里你自己装的同名 App），
    /// 按路径改权限就会顺着链接改到别处。App 包本身是符号链接时一个文件也不改，抛出错误。
    /// App 包以上的各级（盒子的 App 文件夹）由调用方确认不是链接（见 IsolatedSession.checkLayout）
    private static func forEachExecutable(in app: URL, _ change: (_ folder: Int32, _ name: String, _ mode: mode_t) -> mode_t?) throws {
        let root = open(app.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else {
            if errno == ENOENT { return } // 还没有 App（比如在线安装器的盒子）
            throw failure(app.lastPathComponent)
        }
        var firstError: Error?
        walk(root, names: [app.lastPathComponent], change, firstError: &firstError)
        if let firstError { throw firstError }
    }

    /// 遍历 folder（用完关闭）。names 是从 App 包起的各级名字，用来认出 Contents/MacOS
    private static func walk(_ folder: Int32, names: [String], _ change: (Int32, String, mode_t) -> mode_t?,
                             firstError: inout Error?) {
        guard let stream = fdopendir(folder) else {
            close(folder)
            return
        }
        defer { closedir(stream) } // 同时关闭 folder
        let inMacOS = names.count >= 2 && names.suffix(2) == ["Contents", "MacOS"]
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            guard name != ".", name != ".." else { continue }
            var info = stat()
            guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                let child = openat(folder, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if child >= 0 { walk(child, names: names + [name], change, firstError: &firstError) }
            case S_IFREG where inMacOS:
                // 相对于这个文件夹的描述符改、不跟随最后一级的符号链接：改到的一定是这个文件夹里的这一项
                guard let mode = change(folder, name, info.st_mode & 0o7777) else { continue }
                if fchmodat(folder, name, mode, AT_SYMLINK_NOFOLLOW) != 0, firstError == nil { firstError = failure(name) }
            default:
                continue // 符号链接、其他类型的文件都不碰
            }
        }
    }

    private static func failure(_ name: String) -> Error {
        let reason = String(cString: strerror(errno))
        return MacBoxError(String(localized: "无法修改「\(name)」的执行权限：\(reason)"))
    }
}
