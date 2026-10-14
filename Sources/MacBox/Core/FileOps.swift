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
    /// 跨卷复制可能很慢，在主线程调用时请包在 Background.run 里。
    ///
    /// source 本身是符号链接时，默认克隆它指向的东西（拖进来的替身要的是 App 本身）；followingSymlink 为 false
    /// 时只复制链接本身。盒子里的东西（还原点、Home、Prefs）一律用 false：App 改得到它们，把一项换成指向
    /// ~/Documents 的链接，跟随克隆就成了不在沙盒里的 MacBox 替它把盒子外的东西复制进盒子
    static func clone(_ source: URL, to destination: URL, followingSymlink: Bool = true) throws {
        if clonefile(fileSystemPath(source), fileSystemPath(destination), followingSymlink ? 0 : UInt32(CLONE_NOFOLLOW)) != 0 {
            try FileManager.default.copyItem(at: source, to: destination) // 退化为复制时，链接只复制链接本身
        }
    }

    /// 读取一个普通文件的内容；不存在、是符号链接、FIFO 等其他东西时返回 nil。
    /// 用来读盒子里 App 改得到的文件（偏好设置、借出日志、钥匙串密码）：不在沙盒里的 MacBox 不能顺着 App
    /// 放的链接去读盒子外的文件（再经由偏好设置交还给 App），也不能被一个永远等不到数据的 FIFO 卡住
    static func regularFileContents(_ url: URL) -> Data? {
        let descriptor = open(fileSystemPath(url), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        do { return try handle.readToEnd() ?? Data() } catch { return nil }
    }

    static func removeIfExists(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) || isSymlink(url) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    // MARK: - 删除、替换盒子里的数据

    /// 删除一个文件或整棵目录树；不存在时什么也不做。
    ///
    /// 盒子里的数据是 App 自己写的，FileManager.removeItem 常常删不动：Go 的模块缓存（~/go/pkg/mod，
    /// 主目录重定向后就在盒子里）这类目录没有属主写权限，里面的东西删不掉；带 uchg / uappnd 标志（chflags）的
    /// 文件和目录、带「拒绝删除」ACL 的东西（~/Library 默认就有一条 everyone deny delete，App 照抄一份或者自己
    /// chmod +a 都很容易）也删不掉。而且 removeItem 失败时已经删掉了一部分，留下半个目录。这里先序遍历时给目录
    /// 清掉这两个用户标志和 ACL（ACL 的拒绝项对属主同样有效，chmod 补不回来）、补上属主的读写执行权限，
    /// 再自底向上删除；文件被 ACL 挡住时清掉它的 ACL 再删一次。这些属主都能自己做到，即使 ACL 拒绝了所有人改权限。
    ///
    /// 从不跟随符号链接：链接只删链接本身，指向的东西（比如共享时的 Home/Downloads → ~/Downloads）
    /// 既不会被删，也不会被改权限、清 ACL。不用按完整路径工作的 fts / removeItem：删除时盒子里要是还有进程，
    /// 它可以把删到一半的目录换成指向盒子外的链接，按路径删下去就删到了外面。这里每一层都用目录的
    /// 文件描述符加 *at 调用（fstatat/unlinkat/setattrlistat 不跟随链接，openat 加 O_NOFOLLOW），换了也只会失败。
    /// 不进入其他卷（挂载点删除失败，而不是删卷上的东西）。只有系统标志（schg 等，只有 root 能清）照常抛错。
    ///
    /// 不递归，同时只开着两三个文件描述符，和目录树有多深无关：MacBox 作为 GUI App 的描述符上限只有 256，
    /// 每层占一个的话，App 随手建一棵几百层深的目录树，就能让清除数据、还原永远失败（递归还可能耗尽栈）
    static func removeTree(_ url: URL) throws {
        let path = fileSystemPath(url)
        let name = (path as NSString).lastPathComponent
        guard path.hasPrefix("/"), path != "/", name != ".", name != ".." else { throw removalFailure(path, EINVAL) }
        let parentPath = (path as NSString).deletingLastPathComponent
        let parent = open(parentPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else {
            if errno == ENOENT { return } // 上级目录都不存在
            throw removalFailure(path, errno)
        }
        defer { close(parent) }
        // 要删的本身就是挂载点时也不碰：从上级目录所在的卷开始算
        var parentInfo = stat()
        guard fstat(parent, &parentInfo) == 0 else { throw removalFailure(path, errno) }
        try removeEntry(Array(name.utf8CString), in: parent, path: path, device: parentInfo.st_dev)
    }

    /// 用 source 的克隆替换 target；source 为 nil 时只删除 target。任何时刻崩溃都不会留下半新半旧的 target：
    /// 1. 克隆到旁边的「<名字>.restoring」，这时 target 还原封不动；
    /// 2. target 改名为「<名字>.old」，「.restoring」改名为 target。两次改名之间崩溃时 target 缺失、
    ///    .old 是完整的原件，recoverReplacements 把它改回来，等于没换；
    /// 3. 删除换下来的 .old。它先改名为「<名字>.deleting-<UUID>」再删（名字按 target 起，不是「<名字>.old.deleting-…」）：
    ///    删到一半崩溃时，残骸不会被当成原件改回来。
    ///    这一步失败不算替换失败（target 已经是新内容），残留的由 recoverReplacements 下次再删。
    /// 只删除时（source 为 nil）同样先挪开再删（相当于直接走到第 3 步），而不是挪成 .old：删到一半崩溃的话，
    /// .old 会被当成原件改回来，留下一个“看起来还在”的半截 target。挪不开时原地删除，删不掉就抛错。
    ///
    /// 克隆不跟随 source 本身的符号链接：还原点在盒子目录里，App 改得到，把 RestorePoint/Home 换成指向
    /// ~/Documents 的链接的话，跟随克隆就等于不在沙盒里的 MacBox 替它把文稿复制进了盒子。
    /// 开始前先收拾 target 上次留下的残局（同 recoverReplacements）
    static func replace(_ target: URL, withCloneOf source: URL?) throws {
        try recoverReplacement(of: target)
        let old = sibling(of: target, suffix: "old")
        let restoring = sibling(of: target, suffix: "restoring")
        guard let source else {
            if exists(target) { try discard(target, as: target) }
            return
        }
        do {
            try clone(source, to: restoring, followingSymlink: false)
        } catch {
            try? removeTree(restoring) // 克隆、复制失败时可能已经做了一半
            throw error
        }
        let hadTarget = exists(target)
        do {
            if hadTarget { try move(target, to: old) }
            try move(restoring, to: target)
        } catch {
            if hadTarget, !exists(target) { try? move(old, to: target) }
            try? removeTree(restoring)
            throw error
        }
        if hadTarget { try? discard(old, as: target) }
    }

    /// 启动时收拾 replace 中途崩溃留下的残局（items 是 directory 里的名字，如 "Home"、"Prefs"）：
    /// target 缺失而「.old」还在，说明崩溃在两次改名之间，.old 是完整的原件，改回去；
    /// 其余的「.restoring」「.old」「.deleting-…」都是残留，删除。
    /// 每一项都会处理，最后抛出遇到的第一个错误
    static func recoverReplacements(in directory: URL, items: [String]) throws {
        var firstError: Error?
        let names = (try? FileManager.default.contentsOfDirectory(atPath: fileSystemPath(directory))) ?? []
        for item in items {
            let target = directory.appending(path: item)
            do {
                try recoverReplacement(of: target)
            } catch {
                firstError = firstError ?? error
            }
            // 挪开后没删完的（见 discard）。早先的写法按挪开前的名字起名，留下的是「.old.deleting-…」
            // 「.restoring.deleting-…」，也一并认出来：漏掉的话，删到一半的整个旧 Home 就永远留在盒子里
            let trash = [".deleting-", ".old.deleting-", ".restoring.deleting-"].map { item + $0 }
            for name in names where trash.contains(where: name.hasPrefix) {
                do { try removeTree(directory.appending(path: name)) } catch { firstError = firstError ?? error }
            }
        }
        if let firstError { throw firstError }
    }

    /// 残留同样先挪开再删（discard）：哪个删不掉，也只留在一个不挡路的名字下，不会让之后每次替换都失败
    private static func recoverReplacement(of target: URL) throws {
        let old = sibling(of: target, suffix: "old")
        let restoring = sibling(of: target, suffix: "restoring")
        if !exists(target), exists(old) { try move(old, to: target) }
        if exists(restoring) { try discard(restoring, as: target) }
        if exists(old) { try discard(old, as: target) } // target 在：.old 是换下来还没删完的旧内容
    }

    /// 把 url（target 本身，或者它的 .old、.restoring）挪到一个不会被当成原件的名字「<target 的名字>.deleting-<UUID>」下再删。
    /// 名字按 target 起，而不是按 url：recoverReplacements 按 target 的名字认残骸，「Home.old.deleting-…」它就认不出来了。
    /// 挪开之后删除失败不抛错（原位置已经空了），残骸由 recoverReplacements 下次再删；挪不开就原地删除，失败照常抛错
    private static func discard(_ url: URL, as target: URL) throws {
        let trash = sibling(of: target, suffix: "deleting-\(UUID().uuidString)")
        guard (try? move(url, to: trash)) != nil else { return try removeTree(url) }
        do { try removeTree(trash) } catch {
            NSLog("MacBox: 删除 \(trash.path) 失败，下次启动时再试：\(error.localizedDescription)")
        }
    }

    /// 同一目录下的「<名字>.<后缀>」
    private static func sibling(of url: URL, suffix: String) -> URL {
        url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent).\(suffix)")
    }

    /// 按 lstat 判断：悬空的符号链接也算存在
    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(fileSystemPath(url), &info) == 0
    }

    /// 同一目录内改名（原子操作）。不覆盖已存在的目标：那说明状态和预想的不一样，宁可失败
    private static func move(_ source: URL, to destination: URL) throws {
        let from = fileSystemPath(source), to = fileSystemPath(destination)
        if renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 { return }
        var code = errno
        if code == ENOTSUP { // 不支持 RENAME_EXCL 的文件系统（比如数据放在别的卷上时）
            if exists(destination) {
                code = EEXIST
            } else if rename(from, to) == 0 {
                return
            } else {
                code = errno
            }
        }
        throw MacBoxError(L("无法把「\(from)」改名为「\(to)」：\(String(cString: strerror(code)))",
                            "Couldn’t rename “\(from)” to “\(to)”: \(String(cString: strerror(code)))"))
    }

    /// 正在删除的一层目录
    private struct Level {
        /// 在上一层目录里的名字（以 0 结尾）
        let name: [CChar]
        /// 从下一层经由 ".." 回到这一层时，用来核对还是不是当初进来的那个目录
        let device: dev_t
        let inode: ino_t
        /// 还没删的子项
        var children: [[CChar]]
    }

    /// 删除 top 目录里名为 name（以 0 结尾）的一项：文件、链接，或整棵目录树。path 是它的完整路径，只用来报错。
    /// device 是开始删除的那一层所在的卷，遇到挂在里面的别的卷就停下。
    ///
    /// 深度优先，但不递归：levels 记着从外到里正在删的各层目录，只有最里面那层（current）开着描述符。
    /// 进入子目录时关掉当前目录的描述符；子目录删空后经由 ".." 重新打开上一层，核对设备号和 inode 还是原来那个
    /// 目录才接着删——删除过程中 App 把正在删的目录挪到了别处的话，".." 就成了别的目录，这时宁可失败
    private static func removeEntry(_ name: [CChar], in top: Int32, path: String, device: dev_t) throws {
        var levels: [Level] = []
        var current = top
        defer { if current != top { close(current) } }
        /// 最里面那层（再接上 child）的完整路径。只在出错时才拼：每一项都拼的话，很深的目录树光拼路径就是平方级的开销
        func location(_ child: [CChar]? = nil) -> String {
            (levels.dropFirst().map(\.name) + (child.map { [$0] } ?? [])).reduce(path) { $0 + "/" + displayName($1) }
        }

        guard let root = try beginRemoving(name, in: top, path: path, device: device) else { return }
        current = root.descriptor
        levels.append(root.level)
        while let innermost = levels.indices.last {
            if let child = levels[innermost].children.popLast() {
                guard let next = try beginRemoving(child, in: current, path: location(child), device: device) else { continue }
                close(current)
                current = next.descriptor
                levels.append(next.level)
                continue
            }
            // 这一层删空了：回到上一层，删掉它
            let finished = levels.removeLast()
            var parent = top
            if let above = levels.last { parent = try parentDirectory(of: current, expected: above, path: location()) }
            close(current)
            current = parent
            try unlinkEntry(finished.name, in: current, flags: AT_REMOVEDIR, path: levels.isEmpty ? path : location(finished.name))
        }
    }

    /// 删除 directory 里名为 name 的一项的第一步：先清掉挡路的 uchg / uappnd 标志；不是目录的（文件、链接…）
    /// 这就删掉，返回 nil；是目录的再清掉 ACL、补上属主权限，打开它并读出里面的名字，交给调用方逐项删除
    private static func beginRemoving(_ name: [CChar], in directory: Int32, path: @autoclosure () -> String,
                                      device: dev_t) throws -> (descriptor: Int32, level: Level)? {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            var code = errno
            // 连 stat 都被拒绝：ACL 拒绝了读取属性或权限（readattr / readsecurity），属主也不例外。清掉再试
            if code == EACCES || code == EPERM, removeACL(name, in: directory) {
                code = fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 ? 0 : errno
            }
            if code == ENOENT { return nil }
            guard code == 0 else { throw removalFailure(path(), code) }
        }
        let isDirectory = info.st_mode & S_IFMT == S_IFDIR
        if isDirectory, info.st_dev != device { throw removalFailure(path(), EXDEV) }
        // uchg / uappnd：带着它们的文件删不掉，带着它们的目录里删不掉东西。属主可以自己清掉（不需要读写权限）
        let userFlags = UInt32(UF_IMMUTABLE | UF_APPEND)
        if info.st_flags & userFlags != 0 {
            var attributes = attrlist()
            attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            attributes.commonattr = attrgroup_t(ATTR_CMN_FLAGS)
            var flags = info.st_flags & ~userFlags
            guard setattrlistat(directory, name, &attributes, &flags, MemoryLayout<UInt32>.size, UInt32(FSOPT_NOFOLLOW)) == 0 else {
                throw removalFailure(path(), errno)
            }
        }
        guard isDirectory else {
            try unlinkEntry(name, in: directory, flags: 0, path: path())
            return nil
        }
        // 目录的 ACL 可以拒绝列出、进入它，拒绝删除它和里面的东西，属主也不例外：先清掉（失败的话，下面该出错的地方照常出错）
        removeACL(name, in: directory)
        // 没有属主读写执行权限的目录（Go 的模块缓存是 0555）：补上，才能列出、删除里面的东西
        if info.st_mode & S_IRWXU != S_IRWXU,
           fchmodat(directory, name, (info.st_mode & 0o7777) | S_IRWXU, AT_SYMLINK_NOFOLLOW) != 0 {
            throw removalFailure(path(), errno)
        }
        // O_NOFOLLOW：刚才看到的目录这时被换成了链接，就打不开，而不是跟着它进到别处
        let descriptor = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw removalFailure(path(), errno) }
        do {
            var opened = stat()
            guard fstat(descriptor, &opened) == 0 else { throw removalFailure(path(), errno) }
            guard opened.st_dev == device else { throw removalFailure(path(), EXDEV) }
            let children = try entries(of: descriptor, path: path())
            return (descriptor, Level(name: name, device: opened.st_dev, inode: opened.st_ino, children: children))
        } catch {
            close(descriptor)
            throw error
        }
    }

    /// 经由 ".." 打开 directory 的上一层，并核对它就是 expected 那个目录
    private static func parentDirectory(of directory: Int32, expected: Level, path: @autoclosure () -> String) throws -> Int32 {
        let parent = openat(directory, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw removalFailure(path(), errno) }
        var info = stat()
        guard fstat(parent, &info) == 0 else {
            let code = errno
            close(parent)
            throw removalFailure(path(), code)
        }
        guard info.st_dev == expected.device, info.st_ino == expected.inode else {
            close(parent)
            throw removalFailure(path(), reason: L("删除过程中文件夹被移到了别处", "The folder was moved while it was being deleted"))
        }
        return parent
    }

    /// unlinkat。被 ACL 挡住时（App 可以给自己的文件加上「拒绝删除」）清掉这一项的 ACL 再试一次
    private static func unlinkEntry(_ name: [CChar], in directory: Int32, flags: Int32, path: @autoclosure () -> String) throws {
        var code = unlinkat(directory, name, flags) == 0 ? 0 : errno
        if code == EACCES || code == EPERM, removeACL(name, in: directory) {
            code = unlinkat(directory, name, flags) == 0 ? 0 : errno
        }
        guard code == 0 || code == ENOENT else { throw removalFailure(path(), code) }
    }

    /// 清掉 directory 里 name 这一项的 ACL（不跟随链接）。属主总能做到，即使 ACL 里拒绝了所有人改权限（writesecurity）。
    /// 不用先打开它再 acl_set_fd_np：没有读权限的文件、拒绝读取的 ACL 都会让打开失败。
    /// 做法是 setattrlist 设置 ATTR_CMN_EXTENDED_SECURITY：一个 attrreference，指向紧跟在后面、只有头部的
    /// kauth_filesec，条目数为 KAUTH_FILESEC_NOACL（-1）表示删除整个 ACL。不支持 ACL 的文件系统上返回 false
    @discardableResult
    private static func removeACL(_ name: [CChar], in directory: Int32) -> Bool {
        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_EXTENDED_SECURITY)
        let referenceSize = MemoryLayout<attrreference_t>.size
        let securitySize = MemoryLayout<kauth_filesec>.size - MemoryLayout<kauth_ace>.size // KAUTH_FILESEC_SIZE(0)
        var security = kauth_filesec()
        security.fsec_magic = UInt32(KAUTH_FILESEC_MAGIC)
        security.fsec_acl.acl_entrycount = UInt32.max // KAUTH_FILESEC_NOACL
        var buffer = [UInt8](repeating: 0, count: referenceSize + MemoryLayout<kauth_filesec>.size)
        return buffer.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: attrreference_t(attr_dataoffset: Int32(referenceSize), attr_length: UInt32(securitySize)),
                             as: attrreference_t.self)
            bytes.storeBytes(of: security, toByteOffset: referenceSize, as: kauth_filesec.self)
            return setattrlistat(directory, name, &attributes, bytes.baseAddress, referenceSize + securitySize,
                                 UInt32(FSOPT_NOFOLLOW)) == 0
        }
    }

    /// 目录里的全部名字（原样的字节，以 0 结尾，不含 . 和 ..）。先全部读出来再删：边读边删时 readdir 的结果没有保证
    private static func entries(of directory: Int32, path: @autoclosure () -> String) throws -> [[CChar]] {
        let copy = dup(directory) // closedir 会关掉交给它的描述符，directory 还要留着做 unlinkat
        guard copy >= 0 else { throw removalFailure(path(), errno) }
        guard let stream = fdopendir(copy) else {
            let code = errno
            close(copy)
            throw removalFailure(path(), code)
        }
        defer { closedir(stream) }
        var names: [[CChar]] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw removalFailure(path(), errno) }
                return names
            }
            var name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                bytes.prefix(Int(entry.pointee.d_namlen)).map { CChar(bitPattern: $0) }
            }
            if name == [46] || name == [46, 46] { continue } // "." ".."
            name.append(0)
            names.append(name)
        }
    }

    /// 以 0 结尾的名字，用来拼报错时的路径
    private static func displayName(_ name: [CChar]) -> String {
        String(decoding: name.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func removalFailure(_ path: String, _ code: Int32) -> MacBoxError {
        removalFailure(path, reason: String(cString: strerror(code)))
    }

    private static func removalFailure(_ path: String, reason: String) -> MacBoxError {
        MacBoxError(L("无法删除「\(path)」：\(reason)", "Couldn’t delete “\(path)”: \(reason)"))
    }

    /// 给系统调用用的路径：去掉结尾的 /（否则 lstat、rename 会跟随指向目录的符号链接）
    private static func fileSystemPath(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
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
