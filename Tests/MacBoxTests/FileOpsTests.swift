import Darwin
import Foundation
import Testing
@testable import MacBox

/// 删除、替换盒子里的数据：App 留下的只读目录、chflags 标志、指向盒子外的符号链接，以及替换中途崩溃后的收拾。
/// 全部在临时目录里进行；“盒子外”的东西也放在同一个临时目录里，用来确认没有被碰到
@Suite("删除与替换盒子数据")
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
    }

    /// 不依赖被测代码的清理：清掉标志、补上权限再删
    func cleanUp() {
        for (tool, arguments) in [("/usr/bin/chflags", ["-R", "nouchg,nouappnd", root.path]),
                                  ("/bin/chmod", ["-R", "u+rwx", root.path]),
                                  ("/bin/rm", ["-rf", root.path])] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
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
    /// 没有任何权限的目录，外加一堆普通文件和指向盒子外的链接
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
        // 前提：FileManager 删不掉这样的目录（这正是要修的问题）
        #expect(throws: (any Error).self) { try FileManager.default.removeItem(at: module) }
    }

    func outsideUntouched() {
        #expect((try? String(contentsOf: canary, encoding: .utf8)) == "keep")
        #expect(mode(outside) == 0o755, "不能顺着链接去改盒子外目录的权限")
        #expect(mode(canary) & 0o200 != 0)
    }

    @Test("删除只读目录、带 uchg / uappnd 标志的东西；符号链接只删链接本身")
    func removeStubbornTree() throws {
        defer { cleanUp() }
        let tree = root.appending(path: "Home")
        try makeStubbornTree(at: tree)

        try FileOps.removeTree(tree)

        #expect(!exists(tree))
        outsideUntouched()
    }

    @Test("删除符号链接本身、单个带标志的文件；不存在的东西什么也不做")
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
        #expect(chflags(file.path, UInt32(UF_IMMUTABLE)) == 0)
        try FileOps.removeTree(file)
        #expect(!exists(file))

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

    @Test("替换中途崩溃后的收拾：缺了原件就把 .old 改回来；其余 .old、.restoring、.deleting-… 删除")
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
}
