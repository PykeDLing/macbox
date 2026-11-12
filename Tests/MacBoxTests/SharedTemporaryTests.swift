import Foundation
import Testing
@testable import MacBox

/// 应用留在系统共用的临时、缓存目录里的东西由 MacBox 清理（见 SharedTemporary）。
/// 单元测试只在自己建的临时文件夹里删东西，把它当作“清理范围”传进去；完整会话的那一条才真的写 /private/tmp
@Suite("盒子外的临时文件")
struct SharedTemporaryTests {
    /// 当作清理范围的文件夹（真实路径，带结尾的 /）
    let root: String
    let started = Date()

    init() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MacBoxTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        root = FileOps.realPath(folder) + "/"
    }

    func cleanUp() { try? FileManager.default.removeItem(atPath: root) }

    func write(_ relative: String, _ content: String = "x") throws {
        let path = root + relative
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try content.write(toFile: path, atomically: false, encoding: .utf8)
    }

    func exists(_ relative: String) -> Bool {
        var info = stat()
        return lstat(root + relative, &info) == 0
    }

    func remove(_ relatives: [String], since: Date? = nil, protecting: [String] = []) async -> SharedTemporary.Cleanup {
        await SharedTemporary.remove(relatives.map { $0.hasPrefix("/") ? $0 : root + $0 }, since: since ?? started,
                                     roots: [root], protecting: protecting)
    }

    @Test("记下的文件删掉，文件夹空了才删；里面还有别人的东西就留着、记进没删掉的")
    func removesWhatWasCreated() async throws {
        defer { cleanUp() }
        try write("boost_interprocess/queue", String(repeating: "x", count: 5000))
        try write("shared/mine")
        try write("shared/theirs") // 别的程序放的：日志里没有
        try write("single.lock")
        try FileManager.default.createSymbolicLink(atPath: root + "link", withDestinationPath: "/etc/hosts")
        let cleanup = await remove(["boost_interprocess", "boost_interprocess/queue", "shared", "shared/mine", "single.lock", "link",
                                    "already-gone"])
        #expect(!exists("boost_interprocess") && !exists("single.lock") && !exists("link") && !exists("shared/mine"))
        #expect(exists("shared/theirs"), "没记下的不动")
        #expect(FileManager.default.fileExists(atPath: "/etc/hosts"), "链接只删它自己")
        #expect(cleanup.removed == 4)
        #expect(cleanup.bytes >= 5000)
        #expect(Set(cleanup.places) == Set(["boost_interprocess", "shared", "single.lock", "link"].map { "/var/folders/…/T/" + $0 }))
        #expect(cleanup.remaining == ["/var/folders/…/T/shared"])
        #expect(!cleanup.isEmpty)
        #expect(await remove([]).isEmpty)
    }

    @Test("不在清理范围里的、MacBox 自己的数据目录里的、这次运行之前就有的，都不动")
    func leavesWhatIsNotItsOwn() async throws {
        defer { cleanUp() }
        let outside = FileManager.default.temporaryDirectory.appending(path: "MacBoxTests-\(UUID().uuidString)")
        try "x".write(to: outside, atomically: false, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        try write("old")
        try write("data/box/file")
        try write("a/b")
        let later = Date().addingTimeInterval(60)
        #expect(await remove([FileOps.realPath(outside)]).isEmpty, "不在清理范围里")
        #expect(await remove(["old"], since: later).isEmpty, "这次运行开始之前就有的")
        #expect(await remove(["data/box/file"], protecting: [root + "data/"]).isEmpty, "MacBox 的数据目录")
        #expect(await remove(["a/../old", "a//b", "a/"]).isEmpty, "不规矩的路径")
        #expect(FileManager.default.fileExists(atPath: outside.path) && exists("old") && exists("data/box/file") && exists("a/b"))
    }

    @Test("上级目录被换成了指向别处的链接：不顺着链接去删别处的同名文件")
    func doesNotFollowSwappedFolder() async throws {
        defer { cleanUp() }
        // 应用先建了 cache/report.txt（记进了日志），再把 cache 换成指向“文稿”的链接，那里正好有一个 report.txt
        try write("documents/report.txt", "precious")
        try FileManager.default.createSymbolicLink(atPath: root + "cache", withDestinationPath: root + "documents")
        let cleanup = await remove(["cache/report.txt", "cache"])
        #expect((try? String(contentsOfFile: root + "documents/report.txt", encoding: .utf8)) == "precious")
        #expect(!exists("cache"), "链接本身是它建的，删掉")
        #expect(cleanup.removed == 1)
    }

    @Test("只记清理范围里的新建，重复的只记一次，记得太多就不再记")
    func notesOnlyCleanedRoots() {
        defer { cleanUp() }
        let created = SharedTemporary.Created()
        created.note(root + "a", roots: [root])
        created.note(root + "a", roots: [root])
        created.note("/private/var/folders/xx/yy/C/com.example/cache", roots: [root])
        #expect(created.paths == [root + "a"])
        for index in 0..<(SharedTemporary.Created.limit + 10) { created.note(root + "f\(index)", roots: [root]) }
        #expect(created.paths.count == SharedTemporary.Created.limit)
    }

    @Test("这个用户的临时目录、缓存目录认得出来；显示的位置不带那串随机的名字")
    func userDirectories() throws {
        let temporary = try #require(SharedTemporary.userTemporary), cache = try #require(SharedTemporary.userCache)
        #expect(temporary.hasPrefix("/private/var/folders/") && temporary.hasSuffix("/T/"))
        #expect(cache.hasPrefix("/private/var/folders/") && cache.hasSuffix("/C/"))
        #expect(SharedTemporary.cleanedRoots == ["/private/tmp/", temporary], "缓存目录里的退出后不清理")
        #expect(SharedTemporary.display("/private/tmp/boost_interprocess/queue", root: "/private/tmp/") == "/private/tmp/boost_interprocess")
        #expect(SharedTemporary.display(temporary + "TemporaryItems/x/y", root: temporary) == "/var/folders/…/T/TemporaryItems")
    }

    @Test("删除盒子、清除数据时：按标识符起名的文件夹只删这个盒子的，和别的盒子、本机装着的 App 重叠的不动")
    func removesNamedFolders() async throws {
        defer { cleanUp() }
        for name in ["com.example.pan", "com.example.pan.helper.GPU", "com.example.panorama", "com.example.other",
                     "com.example.pan.shared", "com.example.pan.native"] {
            try write("C/\(name)/com.apple.metal/functions.data")
        }
        try write("T/com.example.pan/tmp")
        try write("C/com.example.pan.file") // 不是文件夹
        try write("victim/keep")
        try FileManager.default.createSymbolicLink(atPath: root + "C/com.example.pan.link", withDestinationPath: root + "victim")
        let removed = await SharedTemporary.removeNamedFolders(
            prefixes: ["com.example.pan"], others: [["com.example.pan.shared"]], installed: ["com.example.pan.native", "com.apple.Safari"],
            in: [root + "C/", root + "T/"])
        #expect(removed == 3)
        #expect(!exists("C/com.example.pan") && !exists("C/com.example.pan.helper.GPU") && !exists("T/com.example.pan"))
        for kept in ["C/com.example.panorama", "C/com.example.other", "C/com.example.pan.shared", "C/com.example.pan.native",
                     "C/com.example.pan.file", "C/com.example.pan.link", "victim/keep"] {
            #expect(exists(kept), "\(kept)")
        }
        // 本机装着同一个 App：缓存是共用的，不动
        try write("C/com.example.pan/x")
        #expect(await SharedTemporary.removeNamedFolders(prefixes: ["com.example.pan"], others: [], installed: ["com.example.pan"],
                                                         in: [root + "C/"]) == 0)
    }

    @Test("沙盒规则：系统共用的临时、缓存目录里新建时记一笔，盒子里的不记")
    func profileReportsCreations() throws {
        defer { cleanUp() }
        let paths = BoxPaths(url: URL(fileURLWithPath: root + "box.box", isDirectory: true))
        try AppPaths.ensure(paths.url)
        let config = BoxConfig(id: UUID(), name: "Fake", bundleIdentifier: "dev.macboxtest.tmp", appFolderName: "Fake.app")
        let profile = SandboxProfile.make(box: paths, config: config)
        let compact = profile.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(compact.contains("""
        (allow file-write-create (require-all (require-any (subpath "/private/tmp") (subpath "/private/var/folders")) \
        (require-not (subpath "\(root)box.box"))) (with report))
        """))
    }

    @Test("App Group 的共享文件夹：不让找到替它建文件夹的系统服务，被挡住时记成写入个人文件夹")
    func groupContainerIsBlocked() throws {
        defer { cleanUp() }
        let paths = BoxPaths(url: URL(fileURLWithPath: root + "box.box", isDirectory: true))
        try AppPaths.ensure(paths.url)
        let config = BoxConfig(id: UUID(), name: "Fake", bundleIdentifier: "dev.macboxtest.tmp", appFolderName: "Fake.app")
        #expect(SandboxProfile.make(box: paths, config: config).contains("(global-name \"com.apple.containermanagerd\")"))
        let parser = ViolationMonitor.Parser(boxPrefix: "/box/", processNames: [], installer: false, home: "/Users/x", session: SessionPID())
        let event = try #require(parser.categorize(operation: "mach-lookup", target: "com.apple.containermanagerd"))
        #expect(event.kind == .personalFiles && event.target == "group-container")
        #expect(event.subject == .groupContainer && event.targetText.contains("Group Containers"))
        #expect(WritableFolders.folder(forBlockedWrite: event.target) == nil, "不是路径，不会提议允许写入")
        let decoded = try JSONDecoder().decode(BlockEvent.self, from: JSONEncoder().encode(event))
        #expect(decoded == event)
    }

    @Test("照着去删东西的只认按进程身份认出来的：已经退出、只按名字认的不算")
    func nameOnlyIsNotCertain() {
        let parser = ViolationMonitor.Parser(boxPrefix: "/box/", processNames: ["Helper"], installer: false, home: "/Users/x",
                                             session: SessionPID())
        // 一个不存在的 pid：进程已经退出，只能按名字认
        var message = ViolationMonitor.Parser.Message(process: "Helper", pid: 99_999_999, operation: "file-write-create",
                                                      target: "/private/tmp/x")
        message.allowed = true
        guard case .wroteOutside(_, _, let certain) = parser.activity(from: message) else {
            Issue.record("按名字认的也要报告（共享的「下载」用它来显示）")
            return
        }
        #expect(!certain)
    }

    @Test("运行报告：有这一栏，旧报告没有这个字段照常读取")
    func report() throws {
        var report = RunReport(config: BoxConfig(id: UUID(), name: "Pan", bundleIdentifier: "x", appFolderName: "P.app"))
        report.endedAt = report.startedAt.addingTimeInterval(60)
        #expect(report.markdown().contains(RunReport.temporaryTitle))
        #expect(!report.summaryLine.contains("临时") && !report.summaryLine.contains("temporary"))
        report.temporaryCleanup = SharedTemporary.Cleanup(removed: 2, bytes: 20 << 20, places: ["/private/tmp/boost_interprocess"],
                                                          remaining: ["/private/tmp/shared"])
        let text = report.markdown()
        for expected in ["`/private/tmp/boost_interprocess`", "`/private/tmp/shared`", "20"] { #expect(text.contains(expected), "\(expected)") }
        let decoded = try JSONDecoder().decode(RunReport.self, from: JSONEncoder().encode(report))
        #expect(decoded.temporaryCleanup == report.temporaryCleanup)
        let old = """
        {"id":"\(UUID().uuidString)","appName":"Old","bundleIdentifier":"x","startedAt":0,"networkBlocked":false,
         "sharesDownloads":true,"servers":[],"programs":[],"blocks":[]}
        """
        #expect(try JSONDecoder().decode(RunReport.self, from: Data(old.utf8)).temporaryCleanup == nil)
    }
}

/// 完整的会话：假 App 在 /private/tmp 和这个用户的临时目录里留下文件，退出后被删掉、记进结果
@Suite("盒子外的临时文件（完整会话）", .enabled(if: AppPaths.override != nil, "需要 MACBOX_DATA_ROOT"))
struct SharedTemporarySessionTests {
    @Test("应用在系统临时目录里留下的文件，退出后被删掉；它没碰的不动", .timeLimit(.minutes(2)))
    func cleanedAfterQuit() async throws {
        let temporary = try #require(SharedTemporary.userTemporary)
        // 内核会合并、丢弃一部分沙盒报告：每次用不同的名字，多试几次
        var cleaned: SharedTemporary.Cleanup?
        for _ in 0..<3 {
            let tag = "macboxtest-\(UUID().uuidString.prefix(8).lowercased())"
            let inTmp = "/private/tmp/\(tag)", inUser = temporary + tag
            let bystander = "/private/tmp/\(tag)-bystander"
            try "x".write(toFile: bystander, atomically: false, encoding: .utf8) // 别的程序的
            defer { for path in [inTmp, inUser, bystander] { try? FileManager.default.removeItem(atPath: path) } }
            let (paths, config) = try await SessionTests().makeBox(script: """
            mkdir '\(inTmp)'
            dd if=/dev/zero of='\(inTmp)/queue' bs=1024 count=64 2>/dev/null
            echo x > '\(inUser)'
            echo x > "$TMPDIR/in-box"
            sleep 1.5
            """)
            defer { try? FileManager.default.removeItem(at: paths.url) }
            let outcome = try await IsolatedSession.run(paths: paths, config: config, onStart: { _ in }, onActivity: { _ in })
            #expect(FileManager.default.fileExists(atPath: bystander))
            #expect(FileManager.default.fileExists(atPath: paths.tmp.appending(path: "in-box").path), "盒子里的临时文件夹不归它管")
            guard let cleanup = outcome.temporaryCleanup, cleanup.removed == 2 else { continue }
            #expect(!FileManager.default.fileExists(atPath: inTmp) && !FileManager.default.fileExists(atPath: inUser))
            #expect(cleanup.bytes >= 64 * 1024)
            #expect(Set(cleanup.places) == [inTmp, "/var/folders/…/T/\(tag)"])
            #expect(cleanup.remaining.isEmpty)
            cleaned = cleanup
            break
        }
        #expect(cleaned != nil, "三次都没有清理干净")
    }
}
