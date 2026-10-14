import CoreServices
import CryptoKit
import Foundation

/// 「传出」里的东西来自虚拟 Mac，按下载来的文件对待：逐项打上 Gatekeeper 隔离标记，打开时系统会检查。
///
/// 虚拟机进程（com.apple.Virtualization.VirtualMachine.xpc）不在沙盒里，也没有开启 LSFileQuarantineEnabled，
/// 客体写进共享目录的文件不会自动带标记；只给最外层打标记也不够，文件夹里的 .app 和脚本照样能直接运行。
/// 所以要递归处理，并且不能依赖 FileOps.markQuarantined（它只标一层、还会跟随符号链接）。
///
/// 客体能控制「传出」里的一切：路径（把中间某一级换成符号链接）、权限（chmod 555 让属主也写不了扩展属性，
/// 111、311 让属主读不了内容、列不了目录）、用户标志（uchg），还可能经 virtiofs 直接写扩展属性、伪造标记。所以：
/// 全程用文件描述符逐级 openat、不跟随符号链接；标不上时临时放宽属主权限、清掉 uchg，标完恢复原样；
/// MacBox 的标记带本机密钥的签名，签名对不上的一律重写
nonisolated enum OutgoingQuarantine {
    static let attribute = "com.apple.quarantine"
    static let agent = "MacBox"
    /// 最多往下走的层数：每一层占一个文件描述符。更深的项目不标，报告为没能标记
    static let maxDepth = 64
    /// 监视器的回调和完整扫描可能同时进行：一次只走一棵，免得两边交错地放宽、恢复同一项的权限，最后恢复错
    private static let lock = NSLock()

    /// 给 root 下面的 url 以及它里面的全部内容打标记（url 是 root 本身时只标里面的内容，root 不标）。
    /// 不跟随符号链接，也不会碰 root 以外的任何文件。返回没能标上的项目（相对 root 的路径）
    @discardableResult
    static func markTree(_ url: URL, root: URL, key: SymmetricKey) -> [String] {
        lock.withLock {
            var walk = Walk(key: key)
            walk.run(url, root: root)
            return walk.failures
        }
    }

    // MARK: - 标记的值

    /// MacBox 的标记：「0081;时间;MacBox;签名」。0081 = 已下载、未经用户批准，打开时 Gatekeeper 会检查
    static func markValue(inode: UInt64, key: SymmetricKey, date: Date = Date()) -> String {
        let prefix = "0081;\(String(format: "%08x", UInt32(clamping: Int(date.timeIntervalSince1970))));\(agent)"
        return prefix + ";" + signature(inode: inode, prefix: prefix, key: key)
    }

    /// 只认签名对得上的 MacBox 标记，其余（没有标记、客体自带的、来源写成 MacBox 的伪造值）一律重写。
    /// 签名覆盖 inode 和前三段（标志、时间、来源）：客体照抄别的文件上的标记，或者在 MacBox 的标记上加「已批准」，
    /// 签名都对不上，会被改回未批准。代价是用户在「传出」里放行过的项目，下次检查时又会恢复成未放行——
    /// 系统放行时同样只是改标志位，和客体伪造分不出来。要长期使用的应用，先移出「传出」再打开
    static func isValidMark(_ value: String, inode: UInt64, key: SymmetricKey) -> Bool {
        let fields = value.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count == 4, fields[2] == agent else { return false }
        return fields[3] == signature(inode: inode, prefix: fields[0...2].joined(separator: ";"), key: key)
    }

    /// 第 4 段原本是隔离事件的 UUID：这里放 HMAC 的前 16 字节，排成 UUID 的样子，系统照常解析。
    /// 不用 st_dev：「传出」里的东西都在同一个卷上，而设备号重启、重新挂载后可能变，变了所有标记都要重写
    static func signature(inode: UInt64, prefix: String, key: SymmetricKey) -> String {
        var message = Data("MacBox outgoing quarantine\0".utf8)
        withUnsafeBytes(of: inode.littleEndian) { message.append(contentsOf: $0) }
        message.append(contentsOf: prefix.utf8)
        let code = Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
        return code.prefix(16).withUnsafeBytes { NSUUID(uuidBytes: $0.bindMemory(to: UInt8.self).baseAddress).uuidString }
    }

    /// O_NONBLOCK：客体放进来的命名管道不会把这里卡住
    static func canonicalPath(of url: URL) -> String? {
        let fd = open(url.path, O_SEARCH | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return openedPath(fd)
    }

    fileprivate static func openedPath(_ fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    // MARK: - 遍历

    private struct Walk {
        let key: SymmetricKey
        var failures: [String] = []

        mutating func run(_ url: URL, root: URL) {
            guard FileManager.default.fileExists(atPath: root.path) else { return }
            guard let rootFD = openRoot(root) else {
                failures.append(root.lastPathComponent)
                return
            }
            defer { close(rootFD) }
            guard let rootPath = openedPath(rootFD) else { return }
            // url 就是 root（完整扫描，或者 FSEvents 报告共享目录本身有变动）：只处理里面的内容
            if canonicalPath(of: url) == rootPath {
                children(of: rootFD, relative: "", depth: 0)
                return
            }
            // 先打开上一级，用 F_GETPATH 确认它确实在 root 里面：客体可以把路径中间的某一级换成指向本机其他位置的符号链接。
            // 之后全部相对这个描述符操作，路径再怎么变也出不去
            let parentFD = open(url.deletingLastPathComponent().path, O_SEARCH | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard parentFD >= 0 else { return }
            defer { close(parentFD) }
            guard let parentPath = openedPath(parentFD) else { return }
            let parentRelative: String
            if parentPath == rootPath {
                parentRelative = ""
            } else if parentPath.hasPrefix(rootPath + "/") {
                parentRelative = String(parentPath.dropFirst(rootPath.count + 1))
            } else {
                return
            }
            let name = url.lastPathComponent
            let depth = parentRelative.isEmpty ? 0 : parentRelative.split(separator: "/").count
            entry(parentFD, Array(name.utf8CString), relative: join(parentRelative, name), depth: depth)
        }

        /// root 是 MacBox 自己的文件夹（在虚拟机里是挂载点，客体没法把它换成符号链接），但客体也许能 chmod 它：
        /// 读不了就补上属主权限，不再改回去
        func openRoot(_ root: URL) -> Int32? {
            var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            var info = stat()
            if fd < 0, errno == EACCES, stat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
               chmod(root.path, (info.st_mode & 0o7777) | S_IRWXU) == 0 {
                fd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            }
            return fd >= 0 ? fd : nil
        }

        mutating func entry(_ parent: Int32, _ name: [CChar], relative: String, depth: Int) {
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return } // 已经不在了
            let type = info.st_mode & S_IFMT
            // 符号链接不跟随（指向的东西要么在 root 里另有一项，要么根本不归这里管）；管道、套接字之类没法运行
            guard type == S_IFREG || type == S_IFDIR else { return }
            guard depth < OutgoingQuarantine.maxDepth, var item = Item(parent: parent, name: name, info: info) else {
                // 刚好被删掉、改名的不算（客体正在整理「传出」时常见）
                if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { failures.append(relative) }
                return
            }
            defer { item.close() }
            if !item.hasValidMark(key), !item.mark(key) {
                failures.append(relative)
                // 实在标不上（文件系统不支持扩展属性、不归当前用户所有等）：能去掉执行权限就去掉，双击不会直接运行
                if !item.isDirectory { item.removeExecutePermission() }
            }
            guard item.isDirectory else { return }
            // 先补上属主的读和执行权限（0311 之类的目录列不出来，0644 之类的进不去），处理完里面的内容再恢复
            guard item.grant(S_IRUSR | S_IXUSR) else {
                if failures.last != relative { failures.append(relative) }
                return
            }
            children(of: item.fd, relative: relative, depth: depth + 1)
        }

        /// 列出目录里的项目逐个处理
        mutating func children(of fd: Int32, relative: String, depth: Int) {
            // 用 O_SEARCH 打开的目录不能直接读：相对它重新打开「.」
            let listFD = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard listFD >= 0, let dir = fdopendir(listFD) else {
                if listFD >= 0 { close(listFD) }
                if failures.last != relative { failures.append(relative) }
                return
            }
            var names: [[CChar]] = []
            while let item = readdir(dir) {
                // 名字按原始字节保存，原样交给 openat：不经过 String，不会因为编码问题对不上
                let name = withUnsafePointer(to: &item.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) {
                        Array(UnsafeBufferPointer(start: $0, count: Int(item.pointee.d_namlen) + 1))
                    }
                }
                if name == [46, 0] || name == [46, 46, 0] { continue } // . 和 ..
                names.append(name)
            }
            closedir(dir)
            for name in names {
                let display = String(decoding: name.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
                entry(fd, name, relative: join(relative, display), depth: depth)
            }
        }

        func join(_ relative: String, _ name: String) -> String {
            relative.isEmpty ? name : relative + "/" + name
        }
    }

    /// 打开的一项。为了读写扩展属性、列出内容而临时放宽的属主权限和用户标志，在 close() 时恢复原样
    private struct Item {
        let fd: Int32
        let isDirectory: Bool
        let inode: UInt64
        private var mode: mode_t
        private var flags: UInt32
        /// close() 时要恢复成的权限和标志
        private var finalMode: mode_t
        private let originalFlags: UInt32

        /// uchg、uappnd：设了就改不了权限、写不了扩展属性，但属主自己可以清掉
        private static let userLocks = UInt32(UF_IMMUTABLE | UF_APPEND)

        init?(parent: Int32, name: [CChar], info: stat) {
            let wantsDirectory = info.st_mode & S_IFMT == S_IFDIR
            let base = O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
            let readable = wantsDirectory ? O_RDONLY | O_DIRECTORY : O_RDONLY
            var fd = openat(parent, name, readable | base)
            // 属主没有读权限：能执行（目录能进入）就先这样打开，读写之前再用 fchmod 补
            if fd < 0, errno == EACCES {
                fd = openat(parent, name, (wantsDirectory ? O_SEARCH : O_EXEC) | base)
            }
            // 读和执行都没有（0200、0000 之类）：只能按名字补上读权限。parent 已经确认在 root 里面，
            // AT_SYMLINK_NOFOLLOW 保证改不到链接指向的东西
            let original = info.st_mode & 0o7777
            var grantedByName = false
            if fd < 0, errno == EACCES, fchmodat(parent, name, original | S_IRUSR, AT_SYMLINK_NOFOLLOW) == 0 {
                fd = openat(parent, name, readable | base)
                if fd >= 0 { grantedByName = true } else { fchmodat(parent, name, original, AT_SYMLINK_NOFOLLOW) }
            }
            guard fd >= 0 else { return nil }
            // 以实际打开的这一项为准（客体可能刚好把它换掉了，换上来的同样在 root 里面）
            var opened = stat()
            guard fstat(fd, &opened) == 0 else {
                Darwin.close(fd)
                return nil
            }
            self.fd = fd
            isDirectory = opened.st_mode & S_IFMT == S_IFDIR
            inode = opened.st_ino
            mode = opened.st_mode & 0o7777
            flags = opened.st_flags
            originalFlags = opened.st_flags
            finalMode = grantedByName && opened.st_ino == info.st_ino ? original : mode
        }

        /// 补上属主的权限位（必要时先清掉 uchg/uappnd）
        mutating func grant(_ bits: mode_t) -> Bool {
            guard mode & bits != bits else { return true }
            guard unlock(), fchmod(fd, mode | bits) == 0 else { return false }
            mode |= bits
            return true
        }

        mutating func unlock() -> Bool {
            guard flags & Self.userLocks != 0 else { return true }
            guard fchflags(fd, flags & ~Self.userLocks) == 0 else { return false }
            flags &= ~Self.userLocks
            return true
        }

        /// 读扩展属性要有读权限（0111 的文件属主也读不了）
        mutating func hasValidMark(_ key: SymmetricKey) -> Bool {
            _ = grant(S_IRUSR)
            var buffer = [UInt8](repeating: 0, count: 256)
            let length = fgetxattr(fd, OutgoingQuarantine.attribute, &buffer, buffer.count, 0, 0)
            guard length > 0 else { return false }
            return OutgoingQuarantine.isValidMark(String(decoding: buffer.prefix(length), as: UTF8.self), inode: inode, key: key)
        }

        /// 写扩展属性要有写权限（0555 的文件属主也写不了），设了 uchg 也写不了
        mutating func mark(_ key: SymmetricKey) -> Bool {
            let value = OutgoingQuarantine.markValue(inode: inode, key: key)
            func write() -> Bool {
                value.withCString { fsetxattr(fd, OutgoingQuarantine.attribute, $0, strlen($0), 0, 0) } == 0
            }
            if write() { return true }
            guard errno == EACCES || errno == EPERM, unlock(), grant(S_IWUSR) else { return false }
            return write()
        }

        mutating func removeExecutePermission() {
            _ = unlock()
            finalMode &= ~(S_IXUSR | S_IXGRP | S_IXOTH)
        }

        /// 恢复权限，再恢复标志（设了 uchg 就改不了权限了），然后关闭
        mutating func close() {
            if mode != finalMode, fchmod(fd, finalMode) == 0 { mode = finalMode }
            if flags != originalFlags { fchflags(fd, originalFlags) }
            Darwin.close(fd)
        }
    }

    // MARK: - 监视

    /// 虚拟 Mac 运行期间盯住「传出」：客体新写入或改动的每一项随即打上标记，
    /// 这样用户在已经打开的访达窗口里双击新出现的文件时，它也已经带着标记
    final class Watcher {
        private var stream: FSEventStreamRef?
        private let queue = DispatchQueue(label: "MacBox.OutgoingQuarantine")

        /// 回调要用的东西。由事件流通过 retain/release 持有，回调运行期间不会被释放
        fileprivate final class Target: Sendable {
            let root: URL
            let key: SymmetricKey
            init(root: URL, key: SymmetricKey) {
                self.root = root
                self.key = key
            }
        }

        var isRunning: Bool { stream != nil }

        func start(_ folder: URL, key: SymmetricKey) {
            guard stream == nil else { return }
            // IgnoreSelf：不理会 MacBox 自己的改动（打标记、临时放宽再恢复权限），否则每次检查都会引出下一次，没完没了。
            // 客体的写入来自虚拟机进程，不受影响
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                                                 | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagIgnoreSelf)
            let target = Unmanaged.passRetained(Target(root: folder, key: key))
            var context = FSEventStreamContext(version: 0, info: target.toOpaque(), retain: Self.retainTarget,
                                               release: Self.releaseTarget, copyDescription: nil)
            let created = FSEventStreamCreate(nil, Self.callback, &context, [folder.path] as CFArray,
                                              FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags)
            target.release() // 事件流已经通过 retain 持有它；创建失败时这里就释放掉
            guard let stream = created else { return }
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

        private static let retainTarget: CFAllocatorRetainCallBack = { info in
            guard let info else { return nil }
            _ = Unmanaged<Target>.fromOpaque(info).retain()
            return info
        }

        private static let releaseTarget: CFAllocatorReleaseCallBack = { info in
            guard let info else { return }
            Unmanaged<Target>.fromOpaque(info).release()
        }

        /// FSEvents 回调（在 queue 上）：逐项标记变动的路径，文件夹连同里面的内容一起标
        private static let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let target = Unmanaged<Target>.fromOpaque(info).takeUnretainedValue()
            let changed = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            for path in changed.prefix(count) {
                markTree(URL(fileURLWithPath: path), root: target.root, key: target.key)
            }
        }
    }
}
