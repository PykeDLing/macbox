import Foundation
import Testing
@testable import MacBox

/// 可以写入的文件夹：能不能选、规则、真实写入、运行报告。
/// 要真的写的放在 /Users/Shared 下：它不在你的主目录里，系统目录（/private 下的临时目录）又不能选
@Suite("可以写入的文件夹")
struct WritableFolderTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "MacBoxTests-\(UUID().uuidString)")
    /// 盒子外、可以选的地方
    let shared = URL(fileURLWithPath: "/Users/Shared/MacBoxTests-\(UUID().uuidString)", isDirectory: true)

    let home = "/Users/u"
    let dataRoot = "/Users/u/Library/Application Support/MacBox"

    func makeBox(folders: [String] = []) throws -> (BoxPaths, BoxConfig) {
        let paths = BoxPaths(url: root.appending(path: "\(UUID().uuidString).box"))
        for folder in [paths.keychains, paths.tmp, paths.appDirectory] { try AppPaths.ensure(folder) }
        var config = BoxConfig(id: UUID(), name: "T", bundleIdentifier: "dev.macboxtest.app", appFolderName: "T.app")
        config.shareDownloads = false
        config.writableFolderPaths = folders
        return (paths, config)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: shared)
    }

    /// 在盒子的沙盒中运行一段 shell，返回输出
    func sandboxed(_ paths: BoxPaths, _ config: BoxConfig, _ script: String) async throws -> String {
        var options = ChildProcess.Options()
        options.environment["HOME"] = paths.home.path
        options.output = .pipe
        options.error = .pipe
        let child = try ChildProcess.spawn("/usr/bin/sandbox-exec", ["-p", SandboxProfile.make(box: paths, config: config),
                                                                     "/bin/sh", "-c", script], options: options)
        async let output = child.standardOutput.collect()
        async let error = child.standardError.collect()
        _ = await (output, error)
        _ = await child.waitForExit()
        return String(decoding: await output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func check(_ path: String, volumeRoot: Bool = false) -> WritableFolders.Rejection? {
        WritableFolders.check(path, home: home, dataRoot: dataRoot, volumeRoot: volumeRoot)
    }

    // MARK: 能不能选

    @Test("太宽的、放着别人数据和配置的不能选，各有原因")
    func rejections() {
        let cases: [(String, WritableFolders.Rejection)] = [
            ("/", .disk), ("/Volumes", .disk), ("/Volumes/Backup", .disk),
            ("/Users/u", .home), ("/Users", .home),
            ("/Users/u/Library", .library), ("/Users/u/Library/CloudStorage/Dropbox", .library),
            ("/Users/u/Library/Application Support/MacBox/Boxes/x.box/Home", .library),
            ("/Users/u/Applications", .applications), ("/Users/u/Applications/MacBox", .applications),
            ("/Users/u/Downloads", .downloads),
            ("/Users/u/.config", .hidden), ("/Users/u/.ssh", .hidden), ("/Users/u/Documents/.secret/x", .hidden),
            ("/Volumes/Backup/.Trashes", .hidden),
            ("/System/Library", .system), ("/Library/LaunchDaemons", .system), ("/Applications", .system),
            ("/Applications/Safari.app", .system), ("/usr/local/bin", .system), ("/private/tmp/x", .system),
            ("/private/var/folders/x", .system), ("/tmp", .system), ("/opt/homebrew", .system), ("relative/path", .system),
        ]
        for (path, rejection) in cases {
            #expect(check(path) == rejection, "\(path)")
        }
        // 挂在别处的卷（选的时候读出来的）
        #expect(check("/Users/u/mnt/disk", volumeRoot: true) == .disk)
        // 数据目录挪到了别处（MACBOX_DATA_ROOT）：它、它的上级和下级都不能选
        #expect(WritableFolders.check("/Users/Shared/mbx", home: home, dataRoot: "/Users/Shared/mbx") == .macBoxData)
        #expect(WritableFolders.check("/Users/Shared/mbx/Boxes", home: home, dataRoot: "/Users/Shared/mbx") == .macBoxData)
        #expect(WritableFolders.check("/Users/Shared", home: home, dataRoot: "/Users/Shared/mbx") == .macBoxData)
        #expect(Set(cases.map(\.1)).allSatisfy { !$0.message.isEmpty })
    }

    @Test("你自己的文件夹、外接硬盘上的文件夹可以选")
    func allowed() {
        for path in ["/Users/u/game", "/Users/u/Documents", "/Users/u/Documents/Quark", "/Users/u/Desktop/下载",
                     "/Users/u/Downloads/Quark", "/Users/u/Library2", "/Volumes/Backup/下载", "/Volumes/Backup/a/b", "/Users/Shared/x"] {
            #expect(check(path) == nil, "\(path)")
        }
    }

    @Test("选择框选中的按真实路径记：经由链接选的记成链接指向的地方，整块磁盘不行")
    func resolving() throws {
        defer { cleanUp() }
        let real = shared.appending(path: "real", directoryHint: .isDirectory)
        try AppPaths.ensure(real)
        let link = shared.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(try WritableFolders.resolve(link).get() == real.path)
        #expect(throws: WritableFolders.Rejection.disk) { try WritableFolders.resolve(URL(fileURLWithPath: "/")).get() }
        // 启动盘在 /Volumes 下的名字是指向 / 的链接
        if let boot = WritableFolders.mountedVolumes().first(where: { $0.hasPrefix("/Volumes/") && FileOps.realPath(URL(fileURLWithPath: $0)) == "/" }) {
            #expect(throws: WritableFolders.Rejection.disk) { try WritableFolders.resolve(URL(fileURLWithPath: boot)).get() }
        }
        #expect(throws: WritableFolders.Rejection.system) { try WritableFolders.resolve(FileManager.default.temporaryDirectory).get() }
    }

    @Test("拦截记录里被挡的写入：所在的文件夹能选时才给出")
    func blockedWrites() {
        func folder(_ target: String) -> String? { WritableFolders.folder(forBlockedWrite: target, home: home, dataRoot: dataRoot) }
        // 夸克试写下载位置
        #expect(folder("~/game/test-1F2E.txt") == "/Users/u/game")
        #expect(folder("/Users/u/game/test-1F2E.txt") == "/Users/u/game")
        #expect(folder("/Volumes/Backup/下载/test-1F2E.txt") == "/Volumes/Backup/下载")
        #expect(folder("~/Documents/a.txt") == "/Users/u/Documents")
        // 所在的文件夹太宽、是盒子里 MacBox 的记录、不是路径
        #expect(folder("~/test.txt") == nil)
        #expect(folder("~/game") == nil) // 建文件夹被挡：所在的是主目录
        #expect(folder("/Volumes/Backup/test.txt") == nil)
        #expect(folder("~/Library/LaunchAgents/a.plist") == nil)
        #expect(folder("/Library/Application Support/x/y") == nil)
        #expect(folder("$TMPDIR/x") == nil)
        #expect(folder("Q.app/Contents/x") == nil)
        #expect(folder("notification-center") == nil)

        // 直接写在「下载」里的：「下载」本身不能选，建议共享「下载」；子文件夹里的可以单独允许
        func inDownloads(_ target: String) -> Bool { WritableFolders.isDirectlyInDownloads(blockedWrite: target, home: home) }
        #expect(folder("~/Downloads/a.zip") == nil)
        #expect(inDownloads("~/Downloads/a.zip") && inDownloads("/Users/u/Downloads/a.zip"))
        #expect(folder("~/Downloads/Quark/a.zip") == "/Users/u/Downloads/Quark" && !inDownloads("~/Downloads/Quark/a.zip"))
        #expect(!inDownloads("~/Downloads") && !inDownloads("~/Documents/a.zip") && !inDownloads("/Users/uu/Downloads/a.zip"))
    }

    @Test("显示的路径：主目录写成 ~；外接硬盘认出所在的卷；受保护的位置")
    func display() {
        #expect(WritableFolders.displayPath("/Users/u/game", home: home) == "~/game")
        #expect(WritableFolders.displayPath("/Users/u", home: home) == "~")
        #expect(WritableFolders.displayPath("/Users/u2/game", home: home) == "/Users/u2/game")
        #expect(WritableFolders.displayPath("/Volumes/B/x", home: home) == "/Volumes/B/x")
        #expect(WritableFolders.volume(of: "/Volumes/Backup/下载/a") == "/Volumes/Backup")
        #expect(WritableFolders.volume(of: "/Users/u/Volumes/x") == nil)
        #expect(WritableFolders.protection(of: "/Volumes/B/x", home: home) == .drive)
        #expect(WritableFolders.protection(of: "/Users/u/Documents/x", home: home) == .documents)
        #expect(WritableFolders.protection(of: "/Users/u/Desktop", home: home) == .desktop)
        #expect(WritableFolders.protection(of: "/Users/u/Downloads/Quark", home: home) == .downloads)
        #expect(WritableFolders.protection(of: "/Users/u/game", home: home) == nil)
        #expect(WritableFolders.protection(of: "/Users/u/DocumentsOld", home: home) == nil)
    }

    // MARK: box.json 和规则

    @Test("没有选时不写进 box.json，旧文件读出来是没有；选了的按先后存")
    func config() throws {
        var (paths, config) = try makeBox()
        defer { cleanUp() }
        try paths.save(config)
        #expect(try !String(contentsOf: paths.config, encoding: .utf8).contains("writableFolders"))
        #expect(try paths.loadConfig().writableFolderPaths.isEmpty)
        config.writableFolderPaths = ["/Users/u/b", "/Users/u/a"]
        try paths.save(config)
        #expect(try paths.loadConfig().writableFolders == ["/Users/u/b", "/Users/u/a"])
        config.writableFolderPaths = []
        #expect(config.writableFolders == nil)
    }

    @Test("规则：每个文件夹放行写入、要求记进系统日志；不能选的（手工改过 box.json）不放行")
    func rules() throws {
        let home = WritableFolders.realHome
        let (paths, config) = try makeBox(folders: ["\(home)/game", "/Volumes/Backup/下载", "/", "\(home)/Library", home, "\(home)/.ssh"])
        defer { cleanUp() }
        let profile = SandboxProfile.make(box: paths, config: config)
        #expect(profile.contains("(allow file-write* (subpath \"\(home)/game\") (with report))"))
        #expect(profile.contains("(allow file-write* (subpath \"/Volumes/Backup/下载\") (with report))"))
        for rejected in ["/", "\(home)/Library", home, "\(home)/.ssh"] {
            #expect(!profile.contains("(subpath \"\(rejected)\") (with report)"), "\(rejected)")
        }
        #expect(WritableFolders.granted(config) == ["\(home)/game", "/Volumes/Backup/下载"])
    }

    @Test("沙盒里：能写选定的文件夹（里面随便建、改、删），写不了旁边的；文件夹不在时照常运行，还能重新建")
    func writes() async throws {
        let chosen = shared.appending(path: "chosen", directoryHint: .isDirectory)
        let missing = shared.appending(path: "missing", directoryHint: .isDirectory)
        try AppPaths.ensure(chosen)
        let (paths, config) = try makeBox(folders: [chosen.path, missing.path])
        defer { cleanUp() }
        let output = try await sandboxed(paths, config, """
        cd '\(chosen.path)' && mkdir -p a/b && echo x > a/b/f && mv a/b/f a/g && rm a/g && echo x > test.txt && rm test.txt && echo inside
        echo x > '\(shared.path)/beside.txt' 2>/dev/null && echo leak || echo beside-denied
        mkdir '\(missing.path)' && echo x > '\(missing.path)/f' && echo recreated
        """)
        #expect(output == "inside\nbeside-denied\nrecreated")
    }

    @Test("沙盒里：应用把选定的文件夹换成指向别处的链接，写不进链接指向的地方，下次启动也不会顺着链接放行")
    func symlinkSwap() async throws {
        let chosen = shared.appending(path: "chosen", directoryHint: .isDirectory)
        let elsewhere = shared.appending(path: "elsewhere", directoryHint: .isDirectory)
        try AppPaths.ensure(chosen)
        try AppPaths.ensure(elsewhere)
        let (paths, config) = try makeBox(folders: [chosen.path])
        defer { cleanUp() }
        let swap = try await sandboxed(paths, config, """
        rmdir '\(chosen.path)' && ln -s '\(elsewhere.path)' '\(chosen.path)' && echo swapped
        echo x > '\(chosen.path)/evil.txt' 2>/dev/null && echo leak || echo denied
        """)
        #expect(swap == "swapped\ndenied")
        // 下一次运行：规则用的还是存下的路径，没有解析成链接指向的地方
        #expect(!SandboxProfile.make(box: paths, config: config).contains(elsewhere.path))
        #expect(try await sandboxed(paths, config, "echo x > '\(chosen.path)/evil.txt' 2>/dev/null && echo leak || echo denied") == "denied")
        #expect(!FileManager.default.fileExists(atPath: elsewhere.appending(path: "evil.txt").path))
    }

    // MARK: 运行报告

    @Test("报告：选的文件夹和「下载」里的写入分别汇总，路径最长的优先，试写的临时文件不算")
    func sharedWrites() {
        let home = FileOps.realPath(AppPaths.realHome)
        let game = "\(home)/game", quark = "\(home)/Downloads/Quark", drive = "/Volumes/Backup/下载"
        let writes = SharedWrites(folders: [game, quark, drive])
        // 夸克改下载位置时的试写
        writes.note("\(game)/test-1F2E.txt", operation: "file-write-create")
        writes.note("\(game)/test-1F2E.txt", operation: "file-write-unlink")
        writes.note("\(game)/电影.mp4", operation: "file-write-create")
        writes.note("\(game)/电影.mp4", operation: "file-write-data")
        writes.note("\(game)/剧集/1.mp4", operation: "file-write-create")
        writes.note("\(quark)/a.zip", operation: "file-write-create")
        writes.note("\(home)/Downloads/b.dmg", operation: "file-write-create")
        writes.note("\(drive)/c.iso", operation: "file-write-data")
        writes.note(game, operation: "file-write-create") // 文件夹本身
        writes.note("\(home)/gamer/x", operation: "file-write-create") // 不在里面，只是名字开头一样
        let areas = Dictionary(uniqueKeysWithValues: writes.areas.map { ($0.path, $0) })
        #expect(Set(areas.keys) == ["~/game/电影.mp4", "~/game/剧集", "~/Downloads/Quark/a.zip", "~/Downloads/b.dmg",
                                    "/Volumes/Backup/下载/c.iso"])
        #expect(areas["~/game/电影.mp4"]?.totals == FileTotals(created: 1))
        #expect(areas["~/game/剧集"]?.examples == ["1.mp4"])
        #expect(areas["~/game/剧集"]?.location == .folder)
        #expect(areas["~/Downloads/Quark/a.zip"]?.location == .folder)
        #expect(areas["~/Downloads/b.dmg"]?.location == .downloads)
        #expect(areas["/Volumes/Backup/下载/c.iso"]?.totals == FileTotals(modified: 1))
    }

    @Test("报告记下这次运行时可以写入的文件夹；以后版本加的文件位置认不出时，报告照样读得出")
    func reportFields() throws {
        let home = FileOps.realPath(AppPaths.realHome)
        var (_, config) = try makeBox(folders: ["\(home)/game", "/Volumes/Backup/下载", "/"])
        defer { cleanUp() }
        let report = RunReport(config: config)
        #expect(report.writableFolders == ["~/game", "/Volumes/Backup/下载"])
        #expect(report.markdown().contains("~/game、/Volumes/Backup/下载") || report.markdown().contains("~/game, /Volumes/Backup/下载"))
        #expect(report.filesSummary(FileTotals(created: 1)).contains("可以写入的文件夹除外"))
        config.writableFolderPaths = []
        #expect(RunReport(config: config).writableFolders == nil)
        #expect(!RunReport(config: config).filesSummary(FileTotals(created: 1)).contains("可以写入的文件夹"))

        let json = #"{"location":"cloud","path":"x","totals":{"created":1,"modified":0,"deleted":0,"bytes":0},"examples":[]}"#
        let area = try JSONDecoder().decode(FileArea.self, from: Data(json.utf8))
        #expect(area.path == "x" && area.totals.created == 1)
        let encoded = try JSONEncoder().encode(FileArea(location: .folder, path: "~/game/a"))
        #expect(try JSONDecoder().decode(FileArea.self, from: encoded).location == .folder)
    }

    @Test("系统日志：在选定的文件夹里写的记进运行报告", .enabled(if: AppPaths.override != nil, "需要 MACBOX_DATA_ROOT"))
    func loggedWrites() async throws {
        let chosen = shared.appending(path: "chosen", directoryHint: .isDirectory)
        try AppPaths.ensure(chosen)
        let (paths, config) = try makeBox(folders: [chosen.path])
        defer { cleanUp() }
        // 内核会合并、丢弃一部分沙盒报告：每次写不同名字的文件，多试几次
        var written: [(path: String, operation: String)] = []
        for attempt in 0..<3 {
            let name = "movie-\(attempt).mp4"
            let session = SessionPID()
            let events = await ViolationMonitor.events(boxPrefix: FileOps.realPath(paths.url), processNames: [], session: session)
            let collecting = Task { () -> [(path: String, operation: String)] in
                var written: [(path: String, operation: String)] = []
                for await activity in events {
                    guard case .wroteShared(let path, let operation) = activity else { continue }
                    written.append((path, operation))
                    if path.hasSuffix("/" + name) { break }
                }
                return written
            }
            var options = ChildProcess.Options()
            options.environment["HOME"] = paths.home.path
            options.newProcessGroup = true
            let main = try ChildProcess.spawn("/usr/bin/sandbox-exec", [
                "-p", SandboxProfile.make(box: paths, config: config),
                "/bin/sh", "-c", "sleep 0.3; echo x > '\(chosen.path)/\(name)'; sleep 1",
            ], options: options)
            EscapeGuard.shared.register(session: main.pid)
            session.set(main.pid)
            let timeout = Task {
                try await Task.sleep(for: .seconds(6))
                collecting.cancel()
            }
            written += await collecting.value
            timeout.cancel()
            main.signal(SIGKILL)
            _ = await main.waitForExit()
            EscapeGuard.shared.unregister(session: main.pid)
            if written.contains(where: { $0.path.hasSuffix("/" + name) }) { break }
        }
        let tracked = SharedWrites(folders: [chosen.path])
        for write in written { tracked.note(write.path, operation: write.operation) }
        #expect(tracked.areas.contains { $0.location == .folder && $0.path.hasPrefix(chosen.path + "/movie-") && $0.totals.created == 1 },
                "\(written)")
    }
}
