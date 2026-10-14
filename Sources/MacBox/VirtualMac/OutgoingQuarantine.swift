import CoreServices
import Foundation

/// 「传出」里的东西来自虚拟 Mac，按下载来的文件对待：逐项打上 Gatekeeper 隔离标记，第一次打开时系统会检查。
///
/// 虚拟机进程（com.apple.Virtualization.VirtualMachine.xpc）不在沙盒里，也没有开启 LSFileQuarantineEnabled，
/// 客体写进共享目录的文件不会自动带标记；只给最外层打标记也不够，文件夹里的 .app 和脚本照样能直接运行。
/// 所以要递归处理，并且不能依赖 FileOps.markQuarantined（它只标一层、还会跟随符号链接）
nonisolated enum OutgoingQuarantine {
    static let attribute = "com.apple.quarantine"
    static let agent = "MacBox"

    /// 给 root 下面的 url 以及它里面的全部内容打标记（root 本身不标）。不跟随符号链接，也不会碰 root 以外的任何文件
    static func markTree(_ url: URL, root: URL) {
        guard let rootPath = canonicalPath(of: root) else { return }
        mark(url.path, rootPath: rootPath)
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return }
        // 不跳过隐藏文件和包内容：.app 里面的可执行文件正是要标的
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [],
                                                        errorHandler: { _, _ in true })
        while let item = enumerator?.nextObject() as? URL {
            mark(item.path, rootPath: rootPath)
        }
    }

    /// 标记一项。先不跟随符号链接地打开它，再用 F_GETPATH 确认打开的确实在 root 里面：
    /// 客体可以把路径中间的某一级换成指向本机其他位置的符号链接，按路径直接 setxattr 会标到本机自己的文件上
    static func mark(_ path: String, rootPath: String) {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return } // 符号链接本身（ELOOP）、已经不存在的项等直接跳过
        defer { close(fd) }
        guard let actual = openedPath(fd), actual.hasPrefix(rootPath + "/") else { return }
        guard !isMarkedByMacBox(fd) else { return }
        let value = "0081;\(String(format: "%08x", UInt32(Date().timeIntervalSince1970)));\(agent);"
        _ = value.withCString { fsetxattr(fd, attribute, $0, strlen($0), 0, 0) }
    }

    /// 已经是 MacBox 打的标记就不再改：用户在本机放行后系统会在原值上加「已批准」，覆盖掉会让它每次都重新询问；
    /// 也避免监视器被自己写 xattr 产生的事件反复触发。客体自带的其他标记一律换成 MacBox 的
    /// （客体可以伪造「已批准」之类的标志位，不能照单全收）
    static func isMarkedByMacBox(_ fd: Int32) -> Bool {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = fgetxattr(fd, attribute, &buffer, buffer.count - 1, 0, 0)
        guard length > 0 else { return false }
        let value = String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let fields = value.split(separator: ";", omittingEmptySubsequences: false)
        return fields.count > 2 && fields[2] == agent
    }

    static func canonicalPath(of url: URL) -> String? {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return openedPath(fd)
    }

    private static func openedPath(_ fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// FSEvents 回调（在 Watcher 的队列上）：逐项标记变动的路径，文件夹连同里面的内容一起标
    fileprivate static let callback: FSEventStreamCallback = { stream, _, count, paths, _, _ in
        let roots = FSEventStreamCopyPathsBeingWatched(stream) as? [String] ?? []
        guard let root = roots.first.map({ URL(fileURLWithPath: $0, isDirectory: true) }) else { return }
        let changed = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
        for path in changed.prefix(count) {
            markTree(URL(fileURLWithPath: path), root: root)
        }
    }

    /// 虚拟 Mac 运行期间盯住「传出」：客体新写入或改动的每一项随即打上标记，
    /// 这样用户在已经打开的访达窗口里双击新出现的文件时，它也已经带着标记
    final class Watcher {
        private var stream: FSEventStreamRef?
        private let queue = DispatchQueue(label: "MacBox.OutgoingQuarantine")

        var isRunning: Bool { stream != nil }

        func start(_ folder: URL) {
            guard stream == nil else { return }
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                                                 | kFSEventStreamCreateFlagNoDefer)
            guard let stream = FSEventStreamCreate(nil, OutgoingQuarantine.callback, nil, [folder.path] as CFArray,
                                                   FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags)
            else { return }
            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                return
            }
            self.stream = stream
        }

        func stop() {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }
}
