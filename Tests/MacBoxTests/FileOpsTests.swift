import Darwin
import Foundation
import Synchronization
import Testing
@testable import MacBox

/// 删除、替换盒子里的数据：App 留下的只读目录、chflags 标志、拒绝删除的 ACL、很深的目录树、指向盒子外的符号链接，
/// 以及替换中途崩溃后的收拾。全部在临时目录里进行；“盒子外”的东西也放在同一个临时目录里，用来确认没有被碰到
// 串行：清理和加 ACL 用同步的 Process.waitUntilExit，会占住并发线程池的线程；并行跑时整个测试进程会卡住好几秒，
// 其他按时间判断的测试（子进程、守卫）因此失败
@Suite("删除与替换盒子数据", .serialized)
struct FileOpsTests {
    let root: URL
    /// 代表盒子外面（~/Downloads、~/Documents）的目录，里面放着不能被碰的文件
    let outside: URL
    let canary: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "MacBoxTests-FileOps-\(UUID().uuidString)")
        outside = root.appending(path: "outside")
        canary = outside.appending(path: "canary.txt")
        try AppPaths.ensure(outside)
        try "keep".write(to: canary, atomically: true, encoding: .utf8)
        _ = chmod(outside.path, 0o755)
        // 盒子外的东西也带着 ACL（~/Library 就是这样）：顺着链接去清 ACL 的话，删完就看得出来
        Self.run("/bin/chmod", ["+a", "group:everyone deny delete", outside.path, canary.path])
    }

    /// 不依赖被测代码的清理：清掉 ACL 和标志、补上权限再删
    func cleanUp() {
        for (tool, arguments) in [("/bin/chmod", ["-R", "-N", root.path]),
                                  ("/usr/bin/chflags", ["-R", "nouchg,nouappnd", root.path]),
                                  ("/bin/chmod", ["-R", "u+rwx", root.path]),
                                  ("/bin/rm", ["-rf", root.path])] {
            Self.run(tool, arguments)
        }
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// 加一条 ACL；noFollow 时加在符号链接本身上
    func addACL(_ entry: String, to url: URL, noFollow: Bool = false) {
        #expect(Self.run("/bin/chmod", (noFollow ? ["-h"] : []) + ["+a", entry, url.path]) == 0, "chmod +a \(entry) \(url.path)")
    }

    func hasACL(_ url: URL) -> Bool {
        guard let acl = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else { return false }
        acl_free(UnsafeMutableRawPointer(acl))
        return true
    }

    func write(_ text: String, _ url: URL) throws {
        try AppPaths.ensure(url.deletingLastPathComponent())
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    func mode(_ url: URL) -> mode_t {
        var info = stat()
        _ = lstat(url.path, &info)
        return info.st_mode & 0o7777
    }

    /// 盒子 Home 里常见的“删不动”的东西：Go 模块缓存（0555 目录、0444 文件）、uchg 文件、uappnd 目录、
    /// 没有任何权限的目录、拒绝删除（以及拒绝列出、进入、改权限）的 ACL，外加一堆普通文件和指向盒子外的链接
    func makeStubbornTree(at tree: URL) throws {
        let module = tree.appending(path: "go/pkg/mod/example.com/m@v1.0.0")
        try write("package m", module.appending(path: "m.go"))
        try write("module m", module.appending(path: "sub/go.mod"))
        for index in 0..<200 { try write("\(index)", tree.appending(path: "Library/Caches/file-\(index)")) }
        try write("locked", tree.appending(path: "Library/locked.txt"))
        try write("inside", tree.appending(path: "Library/AppendOnly/inside.txt"))
        try write("hidden", tree.appending(path: "Library/NoAccess/secret.txt"))
        // 链接：指向盒子外的目录（共享下载时的 Downloads）、盒子外的文件、不存在的东西
        try FileManager.default.createSymbolicLink(at: tree.appending(path: "Downloads"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: tree.appending(path: "Library/canary-link"), withDestinationURL: canary)
        try FileManager.default.createSymbolicLink(atPath: tree.appending(path: "dangling").path, withDestinationPath: "/nonexistent/x")

        for file in [module.appending(path: "m.go"), module.appending(path: "sub/go.mod")] { _ = chmod(file.path, 0o444) }
        for directory in ["go/pkg/mod/example.com/m@v1.0.0/sub", "go/pkg/mod/example.com/m@v1.0.0", "go/pkg/mod/example.com", "go/pkg/mod"] {
            #expect(chmod(tree.appending(path: directory).path, 0o555) == 0)
        }
        #expect(chflags(tree.appending(path: "Library/locked.txt").path, UInt32(UF_IMMUTABLE)) == 0)
        #expect(chflags(tree.appending(path: "Library/AppendOnly").path, UInt32(UF_APPEND)) == 0)
        #expect(chmod(tree.appending(path: "Library/NoAccess").path, 0) == 0)
        // ACL：~/Library 默认的 everyone deny delete；拒绝列出、进入、删除里面东西的目录，里面一个没有任何权限、
        // 连属主改权限都拒绝了的文件；带着自己 ACL 的链接（指向的盒子外文件也有 ACL，不能被清掉）
        let aclFile = tree.appending(path: "Library/acl-deny-delete.txt")
        try write("acl", aclFile)
        addACL("group:everyone deny delete", to: aclFile)
        let locked = tree.appending(path: "Library/ACLLocked")
        try write("inner", locked.appending(path: "inner.txt"))
        try write("nested", locked.appending(path: "Nested/deep.txt"))
        #expect(chmod(locked.appending(path: "inner.txt").path, 0) == 0)
        addACL("group:everyone deny delete,read,write,readsecurity,writesecurity", to: locked.appending(path: "inner.txt"))
        addACL("group:everyone deny delete,delete_child", to: locked.appending(path: "Nested"))
        addACL("group:everyone deny list,search,delete,delete_child,add_file,add_subdirectory", to: locked)
        let aclLink = tree.appending(path: "Library/acl-link")
        try FileManager.default.createSymbolicLink(at: aclLink, withDestinationURL: canary)
        addACL("group:everyone deny delete", to: aclLink, noFollow: true)
        // 前提：FileManager 删不掉这样的目录、文件（这正是要修的问题）
        #expect(throws: (any Error).self) { try FileManager.default.removeItem(at: module) }
        #expect(throws: (any Error).self) { try FileManager.default.removeItem(at: aclFile) }
        #expect(throws: (any Error).self) { try FileManager.default.removeItem(at: aclLink) }
    }

    func outsideUntouched() {
        #expect((try? String(contentsOf: canary, encoding: .utf8)) == "keep")
        #expect(mode(outside) == 0o755, "不能顺着链接去改盒子外目录的权限")
        #expect(mode(canary) & 0o200 != 0)
        #expect(hasACL(outside) && hasACL(canary), "不能顺着链接去清盒子外的 ACL")
    }

    @Test("删除只读目录、带 uchg / uappnd 标志或拒绝删除 ACL 的东西；符号链接只删链接本身")
    func removeStubbornTree() throws {
        defer { cleanUp() }
        let tree = root.appending(path: "Home")
        try makeStubbornTree(at: tree)

        try FileOps.removeTree(tree)

        #expect(!exists(tree))
        outsideUntouched()
    }

    @Test("几百层深、路径超过 PATH_MAX 的目录树也删得掉，同时开着的描述符不随深度增长（GUI App 的默认上限只有 256）")
    func removeDeepTree() throws {
        defer { cleanUp() }
        let tree = root.appending(path: "Home")
        try AppPaths.ensure(tree)
        // 用 mkdirat 逐层往下建，同时只开着一个目录：完整路径早就超过了 PATH_MAX，按路径建不出来
        // 300 层 × 10 字节的名字，完整路径约 3000 字节，超过 PATH_MAX（1024）。不用上千层：建、删上千层目录会让
        // 文件系统忙上好几秒，并行运行的其他测试启动进程跟着变慢，按时间判断的测试就失败了
        let depth = 300, name = "level-dir"
        var directory = open(tree.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try #require(directory >= 0)
        for level in 0..<depth {
            let next = mkdirat(directory, name, 0o755) == 0 ? openat(directory, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC) : -1
            close(directory)
            directory = next
            try #require(directory >= 0, "第 \(level) 层")
        }
        let leaf = openat(directory, "leaf.txt", O_CREAT | O_WRONLY | O_CLOEXEC, 0o444)
        #expect(leaf >= 0)
        close(leaf)
        #expect(fchmod(directory, 0o555) == 0) // 最深处还是只读目录
        close(directory)

        // 每层占一个描述符的话会同时开着几百个（GUI App 的默认上限只有 256）。不调低整个测试进程的上限：
        // 那会让并行的其他测试打不开管道、启动不了进程。改为删除期间在另一个线程里采样打开的描述符数
        let before = Self.openDescriptors()
        let sampler = DescriptorSampler(start: before)
        Thread { sampler.run() }.start()
        let result = Result { try FileOps.removeTree(tree) }
        sampler.stop()
        #expect(sampler.peak - before < 150, "删除时同时开着的描述符随目录深度增长")
        try result.get()
        #expect(!exists(tree))
    }

    @Test("删除符号链接本身、单个带标志或 ACL 的文件；不存在的东西什么也不做")
    func removeSingleItems() throws {
        defer { cleanUp() }
        let link = root.appending(path: "Home")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try FileOps.removeTree(link)
        #expect(!exists(link))
        outsideUntouched()
        #expect(FileManager.default.fileExists(atPath: canary.path))

        let file = root.appending(path: "locked.txt")
        try write("x", file)
        _ = chmod(file.path, 0o444)
        addACL("group:everyone deny delete,writesecurity", to: file)
        #expect(chflags(file.path, UInt32(UF_IMMUTABLE)) == 0)
        try FileOps.removeTree(file)
        #expect(!exists(file))

        // 带着自己 ACL 的链接：删链接本身，指向的文件的 ACL 不动
        let aclLink = root.appending(path: "acl-link")
        try FileManager.default.createSymbolicLink(at: aclLink, withDestinationURL: canary)
        addACL("group:everyone deny delete", to: aclLink, noFollow: true)
        try FileOps.removeTree(aclLink)
        #expect(!exists(aclLink))
        outsideUntouched()

        try FileOps.removeTree(root.appending(path: "missing"))
        try FileOps.removeTree(root.appending(path: "missing-parent/missing"))
        // 带结尾斜杠的目录 URL：删的是链接本身，不是链接指向的目录
        let directoryLink = root.appending(path: "Prefs")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: outside)
        try FileOps.removeTree(URL(fileURLWithPath: directoryLink.path + "/", isDirectory: true))
        #expect(!exists(directoryLink))
        outsideUntouched()
    }

    @Test("替换：用克隆换掉只读的旧内容，不留 .old / .restoring；source 为 nil 时删除")
    func replaceStubbornTarget() throws {
        defer { cleanUp() }
        let target = root.appending(path: "Home")
        try makeStubbornTree(at: target)
        let source = root.appending(path: "RestorePoint/Home")
        try write("restored", source.appending(path: "Documents/note.txt"))

        try FileOps.replace(target, withCloneOf: source)

        #expect((try? String(contentsOf: target.appending(path: "Documents/note.txt"), encoding: .utf8)) == "restored")
        #expect(!exists(target.appending(path: "go")))
        #expect(FileOps.contents(of: root).map(\.lastPathComponent).sorted() == ["Home", "outside", "RestorePoint"].sorted())
        #expect(FileManager.default.fileExists(atPath: source.appending(path: "Documents/note.txt").path), "还原点本身不变")

        // 目标不存在时直接放进去
        let prefs = root.appending(path: "Prefs")
        try write("p", root.appending(path: "RestorePoint/Prefs/a.plist"))
        try FileOps.replace(prefs, withCloneOf: root.appending(path: "RestorePoint/Prefs"))
        #expect(FileManager.default.fileExists(atPath: prefs.appending(path: "a.plist").path))

        try makeStubbornTree(at: root.appending(path: "tmp"))
        try FileOps.replace(root.appending(path: "tmp"), withCloneOf: nil)
        try FileOps.replace(root.appending(path: "missing"), withCloneOf: nil)
        #expect(FileOps.contents(of: root).map(\.lastPathComponent).sorted() == ["Home", "outside", "Prefs", "RestorePoint"].sorted())
        outsideUntouched()
    }

    @Test("替换时不跟随还原点里的符号链接：不会把盒子外的东西克隆进盒子")
    func replaceDoesNotFollowSourceLink() throws {
        defer { cleanUp() }
        let source = root.appending(path: "RestorePoint/Home")
        try AppPaths.ensure(source.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
        let target = root.appending(path: "Home")
        try write("old", target.appending(path: "note.txt"))

        try FileOps.replace(target, withCloneOf: source)

        // 跟随的话，Home 会是 outside 的一份副本（canary.txt 就进了盒子）
        #expect(FileOps.isSymlink(target), "换进来的是链接本身，不是它指向的目录的副本")
        #expect(FileOps.contents(of: root).map(\.lastPathComponent).sorted() == ["Home", "outside", "RestorePoint"].sorted())
        outsideUntouched()
    }

    @Test("替换中途崩溃后的收拾：缺了原件就把 .old 改回来；其余 .old、.restoring、各种 .deleting-… 删除")
    func recoverInterruptedReplacements() throws {
        defer { cleanUp() }
        let box = root.appending(path: "T.box")
        // Home：两次改名之间崩溃，Home 不在，.old 是完整的原件（含只读目录），.restoring 是新内容
        try makeStubbornTree(at: box.appending(path: "Home.old"))
        try write("original", box.appending(path: "Home.old/Documents/note.txt"))
        try makeStubbornTree(at: box.appending(path: "Home.restoring"))
        // Prefs：换完了、删 .old 时崩溃
        try write("new", box.appending(path: "Prefs/a.plist"))
        try makeStubbornTree(at: box.appending(path: "Prefs.old"))
        // tmp：只删除（source 为 nil），删到一半崩溃
        try makeStubbornTree(at: box.appending(path: "tmp.deleting-5A3F"))
        // 早先的写法按挪开前的名字起名：删换下来的 .old、残留的 .restoring 到一半时崩溃，留下的是这样的名字
        try makeStubbornTree(at: box.appending(path: "Home.old.deleting-AAAA"))
        try makeStubbornTree(at: box.appending(path: "Home.restoring.deleting-BBBB"))
        // 不在 items 里的不碰
        try write("other", box.appending(path: "Other.old/x"))

        try FileOps.recoverReplacements(in: box, items: ["Home", "Prefs", "tmp"])

        #expect((try? String(contentsOf: box.appending(path: "Home/Documents/note.txt"), encoding: .utf8)) == "original")
        #expect((try? String(contentsOf: box.appending(path: "Prefs/a.plist"), encoding: .utf8)) == "new")
        #expect(FileOps.contents(of: box).map(\.lastPathComponent).sorted() == ["Home", "Other.old", "Prefs"])
        outsideUntouched()

        // 收拾过后再替换一次也正常
        try FileOps.replace(box.appending(path: "Home"), withCloneOf: box.appending(path: "Prefs"))
        #expect(FileManager.default.fileExists(atPath: box.appending(path: "Home/a.plist").path))
    }

    @Test("只读普通文件：符号链接、FIFO 当作没有（不会卡住），空文件读出空内容")
    func regularFileContents() throws {
        defer { cleanUp() }
        let file = root.appending(path: "a.plist")
        try write("data", file)
        #expect(FileOps.regularFileContents(file) == Data("data".utf8))

        let empty = root.appending(path: "empty")
        try Data().write(to: empty)
        #expect(FileOps.regularFileContents(empty) == Data())

        let link = root.appending(path: "link.plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: canary)
        #expect(FileOps.regularFileContents(link) == nil)

        let fifo = root.appending(path: "fifo.plist")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(FileOps.regularFileContents(fifo) == nil)

        #expect(FileOps.regularFileContents(outside) == nil)
        #expect(FileOps.regularFileContents(root.appending(path: "missing")) == nil)
    }

    @Test("只克隆 App 里的普通文件：最后一级、中间一级是指到外面的链接，或者是目录、FIFO 时都不克隆")
    func cloneRegularFile() throws {
        defer { cleanUp() }
        let app = root.appending(path: "Box/App/Fake.app")
        let resources = app.appending(path: "Contents/Resources")
        try AppPaths.ensure(resources)
        let icon = resources.appending(path: "AppIcon.icns")
        try write("icon", icon)
        let copies = root.appending(path: "Launcher")
        try AppPaths.ensure(copies)
        func copy(_ source: URL) -> URL? {
            let destination = copies.appending(path: UUID().uuidString)
            do {
                try FileOps.cloneRegularFile(source, inside: root.appending(path: "Box/App"), to: destination)
                return destination
            } catch {
                #expect(!FileManager.default.fileExists(atPath: destination.path), "失败时不留下目标")
                return nil
            }
        }

        let copied = try #require(copy(icon))
        #expect(FileOps.regularFileContents(copied) == Data("icon".utf8))

        // App 把图标换成指向盒子外的链接：文件（~/.zsh_history）、文件夹（~/.ssh）
        let fileLink = resources.appending(path: "File.icns"), folderLink = resources.appending(path: "Folder.icns")
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: canary)
        try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: outside)
        #expect(copy(fileLink) == nil)
        #expect(copy(folderLink) == nil)
        // 中间一级是链接：Resources 换成指向盒子外的文件夹
        let linkedResources = app.appending(path: "Contents/Linked")
        try FileManager.default.createSymbolicLink(at: linkedResources, withDestinationURL: outside)
        #expect(copy(linkedResources.appending(path: "canary.txt")) == nil)
        // 指向 App 里另一个文件的链接也不跟：只要普通文件
        let inside = resources.appending(path: "Inside.icns")
        try FileManager.default.createSymbolicLink(at: inside, withDestinationURL: icon)
        #expect(copy(inside) == nil)

        #expect(copy(resources) == nil, "目录不克隆")
        let fifo = resources.appending(path: "Fifo.icns")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(copy(fifo) == nil, "FIFO 不克隆、不卡住")
        #expect(copy(resources.appending(path: "Missing.icns")) == nil)
        #expect(FileOps.contents(of: copies).count == 1, "只有那一份真图标")
    }
}

extension FileOpsTests {
    /// 测试进程当前打开的描述符个数
    nonisolated static func openDescriptors() -> Int {
        Int(proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)) / MemoryLayout<proc_fdinfo>.stride
    }
}

/// 在另一个线程里反复采样打开的描述符数，记下最大值
nonisolated final class DescriptorSampler: Sendable {
    private let state: Mutex<(peak: Int, done: Bool)>
    init(start: Int) { state = Mutex((start, false)) }
    var peak: Int { state.withLock { $0.peak } }
    func stop() { state.withLock { $0.done = true } }
    func run() {
        while true {
            let count = FileOpsTests.openDescriptors()
            let done = state.withLock { state in
                state.peak = max(state.peak, count)
                return state.done
            }
            if done { return }
            usleep(200)
        }
    }
}
