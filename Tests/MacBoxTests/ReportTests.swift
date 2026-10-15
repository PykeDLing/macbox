import AppKit
import Foundation
import Testing
@testable import MacBox

/// 运行报告：运行前后的对比、路径的写法、存取、导出，以及系统日志、nettop 输出的解析。
/// 只用临时目录，不碰真实的盒子、「下载」和偏好设置
@Suite("运行报告")
struct ReportTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "MacBoxTests-\(UUID().uuidString)")

    func makeBox() throws -> (BoxPaths, BoxConfig) {
        let paths = BoxPaths(url: root.appending(path: "\(UUID().uuidString).box"))
        for folder in [paths.keychains, paths.tmp, paths.prefs, paths.appDirectory.appending(path: "T.app/Contents/MacOS")] {
            try AppPaths.ensure(folder)
        }
        var config = BoxConfig(id: UUID(), name: "T", bundleIdentifier: "dev.macboxtest.report.app", appFolderName: "T.app")
        config.preferencePrefixes = ["dev.macboxtest.report"]
        config.shareDownloads = false // 共享时会去看你真实的「下载」
        return (paths, config)
    }

    func write(_ text: String, to url: URL) throws {
        try AppPaths.ensure(url.deletingLastPathComponent())
        try text.write(to: url, atomically: false, encoding: .utf8)
    }

    func writePlist(_ content: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: content, format: .binary, options: 0).write(to: url)
    }

    @Test("对比运行前后：新建、修改、删除的文件按位置汇总；改了的设置只记键名")
    func changes() async throws {
        let (paths, config) = try makeBox()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = paths.home.appending(path: "Library/Application Support/Vendor")
        try write("old", to: support.appending(path: "keep.txt"))
        try write("old", to: support.appending(path: "change.txt"))
        try write("old", to: support.appending(path: "gone.txt"))
        try write("v1", to: paths.appDirectory.appending(path: "T.app/Contents/Resources/update.bin"))
        let prefs = paths.prefs
        try writePlist(["kept": 1, "changed": "a", "removed": true, "nested": ["x": 1]], to: prefs.appending(path: "dev.macboxtest.report.app.plist"))
        try writePlist(["other": 1], to: prefs.appending(path: "dev.macboxtest.unrelated.plist")) // 不属于这个盒子的前缀
        let before = await RunSnapshot.take(paths, config: config)

        try await Task.sleep(for: .milliseconds(20)) // 修改时间要变
        try write("new content", to: support.appending(path: "change.txt"))
        try FileManager.default.removeItem(at: support.appending(path: "gone.txt"))
        try write("x", to: support.appending(path: "Cache/a/b.db"))
        try write("x", to: paths.home.appending(path: "Library/LaunchAgents/dev.macboxtest.plist"))
        try write("x", to: paths.home.appending(path: "Documents/Notes/n.txt"))
        try write("x", to: paths.home.appending(path: ".vendorrc"))
        try write("v2 longer", to: paths.appDirectory.appending(path: "T.app/Contents/Resources/update.bin"))
        try writePlist(["kept": 1, "changed": "b", "added": Date(timeIntervalSince1970: 0), "nested": ["x": 1]],
                       to: prefs.appending(path: "dev.macboxtest.report.app.plist"))
        try writePlist(["fresh": 1], to: prefs.appending(path: "dev.macboxtest.report.helper.plist"))
        try writePlist(["other": 2], to: prefs.appending(path: "dev.macboxtest.unrelated.plist"))
        try writePlist(["x": 1], to: prefs.appending(path: ".native.plist")) // MacBox 自己的

        let downloaded = FileArea(location: .downloads, path: "~/Downloads/setup.dmg", totals: FileTotals(created: 1))
        let changes = await before.changes(paths, config: config, preferencesReturned: true, downloads: [downloaded])
        let areas = Dictionary(uniqueKeysWithValues: changes.files.map { ($0.path, $0) })
        let vendor = try #require(areas["~/Library/Application Support/Vendor"])
        #expect(vendor.totals.created == 1 && vendor.totals.modified == 1 && vendor.totals.deleted == 1)
        #expect(vendor.examples.sorted() == ["Cache/a/b.db", "change.txt"])
        #expect(areas["~/Library/LaunchAgents/dev.macboxtest.plist"]?.totals.created == 1, "Library 下的文件本身就是一处")
        #expect(areas["~/Documents/Notes"]?.totals.created == 1)
        #expect(areas["~/.vendorrc"]?.totals.created == 1)
        #expect(areas["T.app/Contents/Resources/update.bin"]?.totals.modified == 1)
        #expect(areas["T.app/Contents/Resources/update.bin"]?.location == .app)
        #expect(areas["~/Downloads/setup.dmg"] == downloaded, "「下载」里的改动一起汇总")
        #expect(changes.fileTotals == FileTotals(created: 5, modified: 2, deleted: 1, bytes: changes.fileTotals.bytes))
        #expect(changes.fileTotals.bytes > 0)

        let preferences = try #require(changes.preferences)
        #expect(preferences.map(\.domain) == ["dev.macboxtest.report.app", "dev.macboxtest.report.helper"])
        #expect(preferences[0] == PreferenceChange(domain: "dev.macboxtest.report.app", isNew: false,
                                                   added: ["added"], changed: ["changed"], removed: ["removed"]))
        #expect(preferences[1].isNew && preferences[1].added == ["fresh"])

        // 没能收回：盒子里的还是运行前的，比不出来
        #expect(await before.changes(paths, config: config, preferencesReturned: false).preferences == nil)
        // 什么都没动
        let again = await RunSnapshot.take(paths, config: config)
        let none = await again.changes(paths, config: config, preferencesReturned: true)
        #expect(none.files.isEmpty && none.fileTotals.count == 0 && none.preferences == [])
    }

    @Test("对比不跟随符号链接：共享时主目录里的「下载」是指向别处的链接")
    func snapshotDoesNotFollowLinks() throws {
        let (paths, _) = try makeBox()
        defer { try? FileManager.default.removeItem(at: root) }
        let elsewhere = root.appending(path: "elsewhere")
        try write("x", to: elsewhere.appending(path: "big.dmg"))
        try FileManager.default.createSymbolicLink(at: paths.downloads, withDestinationURL: elsewhere)
        let files = RunSnapshot.entries(under: paths.home)
        #expect(files["Downloads"] != nil, "链接本身算一项")
        #expect(!files.keys.contains { $0.hasPrefix("Downloads/") })
    }

    @Test("共享的「下载」按日志里的写入推断：新建又删掉的临时文件不算，按顶层项目汇总")
    func downloadWrites() {
        let downloads = FileOps.realPath(AppPaths.realHome) + "/Downloads/"
        let writes = DownloadWrites()
        // 浏览器式的下载：写临时文件，再改名成正式的名字、打上下载标记
        writes.note(downloads + "pan.dmg.part", operation: "file-write-create")
        writes.note(downloads + "pan.dmg.part", operation: "file-write-data")
        writes.note(downloads + "pan.dmg.part", operation: "file-write-unlink")
        writes.note(downloads + "pan.dmg", operation: "file-write-create")
        writes.note(downloads + "pan.dmg", operation: "file-write-xattr")
        // 解压出一个文件夹
        writes.note(downloads + "Pan", operation: "file-write-create")
        writes.note(downloads + "Pan/a.txt", operation: "file-write-create")
        // 改了、删了你原来就有的
        writes.note(downloads + "notes.txt", operation: "file-write-data")
        writes.note(downloads + "old.zip", operation: "file-write-unlink")
        writes.note("/private/tmp/x", operation: "file-write-create") // 不在「下载」里
        let areas = Dictionary(uniqueKeysWithValues: writes.areas.map { ($0.path, $0) })
        #expect(Set(areas.keys) == ["~/Downloads/pan.dmg", "~/Downloads/Pan", "~/Downloads/notes.txt", "~/Downloads/old.zip"])
        #expect(areas["~/Downloads/pan.dmg"]?.totals == FileTotals(created: 1))
        #expect(areas["~/Downloads/Pan"]?.totals == FileTotals(created: 2))
        #expect(areas["~/Downloads/Pan"]?.examples == ["a.txt"])
        #expect(areas["~/Downloads/notes.txt"]?.totals == FileTotals(modified: 1))
        #expect(areas["~/Downloads/old.zip"]?.totals == FileTotals(deleted: 1))
        #expect(areas.values.allSatisfy { $0.location == .downloads })
    }

    @Test("共享「下载」时写入照常放行，并且要求记进系统日志；不共享时没有这条规则")
    func downloadsRule() throws {
        var (paths, config) = try makeBox()
        defer { try? FileManager.default.removeItem(at: root) }
        let rule = "(allow file-write* (subpath \"\(FileOps.realPath(AppPaths.realHome))/Downloads\") (with report))"
        #expect(!SandboxProfile.make(box: paths, config: config).contains("/Downloads\""))
        config.shareDownloads = true
        #expect(SandboxProfile.make(box: paths, config: config).contains(rule))
    }

    @Test("改动归到哪一处")
    func areaKeys() {
        #expect(RunSnapshot.areaKey("Library/Application Support/Q/a/b", location: .home) == ("~/Library/Application Support/Q", "a/b"))
        #expect(RunSnapshot.areaKey("Library/Keychains/box.keychain-db", location: .home) == ("~/Library/Keychains", "box.keychain-db"))
        #expect(RunSnapshot.areaKey("Library/Preferences/x.plist", location: .home) == ("~/Library/Preferences/x.plist", nil))
        #expect(RunSnapshot.areaKey("Desktop/a.txt", location: .home) == ("~/Desktop/a.txt", nil))
        #expect(RunSnapshot.areaKey("Q.app/Contents/Frameworks/E.framework/E", location: .app)
                == ("Q.app/Contents/Frameworks/E.framework", "E"))
        #expect(RunSnapshot.areaKey("setup.dmg", location: .downloads) == ("~/Downloads/setup.dmg", nil))
    }

    @Test("路径写成应用眼里的样子，不带用户名和盒子的位置")
    func tidyPaths() throws {
        let (paths, _) = try makeBox()
        defer { try? FileManager.default.removeItem(at: root) }
        let tidy = PathTidier(paths: paths)
        let box = FileOps.realPath(paths.url)
        let home = FileOps.realPath(AppPaths.realHome)
        #expect(tidy("\(box)/Home/Library/Caches/x") == "~/Library/Caches/x")
        #expect(tidy("\(box)/App/T.app/Contents/MacOS/T") == "T.app/Contents/MacOS/T")
        #expect(tidy("\(box)/tmp/x.sock") == "$TMPDIR/x.sock")
        #expect(tidy("\(home)/Library/LaunchAgents/a.plist") == "~/Library/LaunchAgents/a.plist")
        #expect(tidy("/usr/sbin/ioreg") == "/usr/sbin/ioreg")
        #expect(tidy(BlockEvent(kind: .autostart, target: "\(home)/Library/LaunchAgents/a.plist", count: 3)).target
                == "~/Library/LaunchAgents/a.plist")
    }

    @Test("存进盒子只留最近的几份，读出来最近的在前；旧报告没有的字段照常读取")
    func persistence() async throws {
        let (paths, config) = try makeBox()
        defer { try? FileManager.default.removeItem(at: root) }
        for offset in 0..<(RunReport.kept + 2) {
            var report = RunReport(config: config)
            report.startedAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(offset) * 60)
            report.endedAt = report.startedAt.addingTimeInterval(30)
            try await RunReport.save(report, in: paths)
        }
        let loaded = await RunReport.load(from: paths)
        #expect(loaded.count == RunReport.kept)
        #expect(loaded.first?.startedAt == Date(timeIntervalSince1970: 1_700_000_000 + Double(RunReport.kept + 1) * 60))
        #expect(loaded.map(\.startedAt) == loaded.map(\.startedAt).sorted(by: >))

        // 只有必有字段的报告（以后加的字段都是可选的）
        let minimal = """
        {"id":"\(UUID().uuidString)","appName":"Old","bundleIdentifier":"x","startedAt":0,"networkBlocked":false,
         "sharesDownloads":true,"servers":[],"programs":[],"blocks":[]}
        """
        try minimal.write(to: paths.reports.appending(path: "0000000000-old.json"), atomically: true, encoding: .utf8)
        #expect(await RunReport.load(from: paths).contains { $0.appName == "Old" && $0.files == nil })
    }

    @Test("导出的文字包括每一类，表格里的竖线不破坏表格")
    func markdown() {
        var config = BoxConfig(id: UUID(), name: "Pan|Drive", bundleIdentifier: "x", appFolderName: "P.app")
        config.version = "1.0"
        var report = RunReport(config: config)
        report.endedAt = report.startedAt.addingTimeInterval(125)
        report.files = [FileArea(location: .home, path: "~/Library/Caches/p", totals: FileTotals(created: 3, bytes: 2048)),
                        FileArea(location: .home, path: "~/odd|name", totals: FileTotals(modified: 1))]
        report.fileTotals = FileTotals(created: 3, bytes: 2048)
        report.preferences = [PreferenceChange(domain: "x", isNew: true, added: ["deviceId"], changed: [], removed: [])]
        report.note(ServerContact(address: "203.0.113.9", port: 443, transport: "tcp", name: "edge.example.net"))
        report.noteLaunch("/usr/sbin/ioreg")
        report.noteLaunch("/usr/sbin/ioreg")
        report.blocks = [BlockEvent(kind: .autostart, target: "~/Library/LaunchAgents/p.plist")]
        let text = report.markdown()
        for expected in ["Pan|Drive", "~/Library/Caches/p", "`deviceId`", "edge.example.net", "203.0.113.9:443", "/usr/sbin/ioreg | 2",
                         "p.plist", "~/odd\\|name"] {
            #expect(text.contains(expected), "\(expected)")
        }
        #expect(report.programs.count == 1 && report.programs[0].count == 2)
        #expect(report.preferenceKeyCount == 1 && report.blockCount == 1)
    }

    @Test("分享用的图片：固定宽度、2 倍分辨率的 PNG")
    @MainActor
    func shareImage() throws {
        var config = BoxConfig(id: UUID(), name: "网盘", bundleIdentifier: "x", appFolderName: "P.app")
        config.version = "6.6"
        var report = RunReport(config: config)
        report.endedAt = report.startedAt.addingTimeInterval(600)
        report.files = (0..<8).map { FileArea(location: .home, path: "~/Library/Caches/p\($0)", totals: FileTotals(created: 10 - $0, bytes: 1 << 20)) }
        report.fileTotals = FileTotals(created: 52, bytes: 8 << 20)
        report.preferences = [PreferenceChange(domain: "com.example.pan", isNew: true, added: ["deviceId", "uid"], changed: [], removed: [])]
        for i in 0..<9 { report.note(ServerContact(address: "203.0.113.\(i)", port: 443, transport: "tcp", name: i % 2 == 0 ? "edge\(i).example.net" : nil)) }
        report.noteLaunch("/usr/sbin/ioreg")
        report.noteLaunch("P.app/Contents/MacOS/P")
        report.blocks = [BlockEvent(kind: .autostart, target: "~/Library/LaunchAgents/com.example.pan.plist"),
                         BlockEvent(kind: .notification, target: "通知中心", count: 4)]
        let data = try #require(ReportImage.png(report, icon: NSWorkspace.shared.icon(for: .applicationBundle)))
        let image = try #require(NSBitmapImageRep(data: data))
        #expect(image.pixelsWide == 1280)
        #expect(image.pixelsHigh > 800)
        // 想看看图的样子：MACBOX_REPORT_PNG=路径 swift test --filter shareImage
        if let path = ProcessInfo.processInfo.environment["MACBOX_REPORT_PNG"] { try data.write(to: URL(fileURLWithPath: path)) }
        #expect(ReportImage.fileName(report).hasSuffix(".png") && !ReportImage.fileName(report).contains("/"))
    }

    @Test("服务器地址的类别：本机、局域网、组播、代理的虚拟地址、公网")
    func serverScopes() {
        func scope(_ address: String) -> ServerContact.Scope {
            ServerContact(address: address, port: 1, transport: "tcp").scope
        }
        #expect(scope("127.0.0.1") == .loopback)
        #expect(scope("::1") == .loopback)
        #expect(scope("192.168.1.8") == .localNetwork)
        #expect(scope("172.20.0.1") == .localNetwork)
        #expect(scope("172.32.0.1") == .internet)
        #expect(scope("fe80::1") == .localNetwork)
        #expect(scope("224.0.0.251") == .multicast)
        #expect(scope("ff02::fb") == .multicast)
        #expect(scope("198.18.0.7") == .proxyMapped)
        #expect(scope("::ffff:10.0.0.1") == .localNetwork)
        #expect(scope("2606:4700::1") == .internet)
        #expect(scope("8.8.8.8") == .internet)
    }

    @Test("解析 nettop 的输出：进程名带点、IPv6 的端口用点隔开、监听和没连上的不算")
    func parseNettop() {
        // 默认的列：time 在前；用 -J 选列时没有 time（见下面）
        let csv = """
        time,,state,
        22:19:32.567595,urlstest.30806,,
        22:19:32.543951,tcp4 192.168.18.4:61189<->141.95.207.211:443,Established,
        22:19:32.543951,tcp4 127.0.0.1:8021<->*:*,Listen,
        22:19:33.000000,com.apple.WebKit.Networking.4321,,
        22:19:33.000001,tcp6 2001:db8::5.50000<->2606:4700::6810:84e5.443,Established,
        22:19:33.000002,udp6 fe80::1%en0.5353<->ff02::fb.5353,,
        22:19:33.000003,udp4 *:*<->*:*,,
        22:19:33.000004,quic4 192.168.18.4:62828<->104.20.23.154:443,,
        """
        let contacts = ConnectionMonitor.parse(csv)
        #expect(contacts.map(\.endpoint) == ["141.95.207.211:443", "[2606:4700::6810:84e5]:443", "[ff02::fb]:5353", "104.20.23.154:443"])
        #expect(contacts.map(\.process) == ["urlstest", "com.apple.WebKit.Networking", "com.apple.WebKit.Networking",
                                             "com.apple.WebKit.Networking"])
        #expect(contacts.map(\.transport) == ["tcp", "tcp", "udp", "quic"])
        let selected = ConnectionMonitor.parse(",state,\nPython.32512,,\ntcp4 127.0.0.1:54433<->127.0.0.1:54432,Established,\n")
        #expect(selected.map(\.endpoint) == ["127.0.0.1:54432"] && selected.first?.process == "Python")
        // nettop 截断的进程名按 pid 换成完整的
        let named = ConnectionMonitor.parse(",state,\ncom.apple.WebKi.4321,,\nquic4 10.0.0.2:5<->104.20.23.154:443,,\n") {
            $0 == 4321 ? "com.apple.WebKit.Networking" : nil
        }
        #expect(named.first?.process == "com.apple.WebKit.Networking")
        #expect(ConnectionMonitor.parse("").isEmpty)
    }

    @Test("nettop 看得到进程此刻的连接")
    func liveConnections() async throws {
        // 本机上一个监听的端口和一个连着它不放的进程
        var options = ChildProcess.Options()
        options.output = .pipe
        let server = try ChildProcess.spawn("/usr/bin/python3", ["-I", "-c", """
        import socket, time
        s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(4)
        print(s.getsockname()[1], flush=True)
        conns = []
        while True:
            c, _ = s.accept(); conns.append(c)
        """], options: options)
        defer { server.signal(SIGKILL) }
        var lines = server.standardOutput.lines().makeAsyncIterator()
        let port = try #require(await lines.next().flatMap { Int($0) })
        let client = try ChildProcess.spawn("/usr/bin/python3", ["-I", "-c", """
        import socket, time
        c = socket.create_connection(("127.0.0.1", \(port))); time.sleep(20)
        """])
        defer { client.signal(SIGKILL) }
        var seen: [ServerContact] = []
        for _ in 0..<20 where !seen.contains(where: { $0.port == port }) {
            try await Task.sleep(for: .milliseconds(200))
            seen = await ConnectionMonitor.connections(of: [client.pid])
        }
        let contact = try #require(seen.first { $0.port == port })
        #expect(contact.address == "127.0.0.1" && contact.transport == "tcp" && contact.scope == .loopback)
        #expect(await ConnectionMonitor.connections(of: []).isEmpty)
    }

    @Test("系统日志：放行的启动程序、不联网时被挡的连接")
    func parseLog() {
        func line(_ message: String) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: ["eventMessage": message]), as: UTF8.self)
        }
        let launch = ViolationMonitor.Parser.message(fromLine: line("Sandbox: bash(30453) allow process-exec* /usr/sbin/ioreg"))
        #expect(launch?.allowed == true && launch?.operation == "process-exec*" && launch?.target == "/usr/sbin/ioreg")
        let denied = ViolationMonitor.Parser.message(fromLine: line("Sandbox: curl(30450) deny(1) network-outbound remote:*:443"))
        #expect(denied?.allowed == false && denied?.process == "curl" && denied?.pid == 30450)
        // sandboxd 的完整报告：只看第一行
        let report = ViolationMonitor.Parser.message(fromLine: line("""
        Sandbox: QuarkCloudDrive Helper (Alerts)(29782) deny(1) mach-lookup com.apple.usernoted.client

        Process:         QuarkCloudDrive Helper (Alerts) [29782]
        Thread 0 Crashed:
        """))
        #expect(report?.process == "QuarkCloudDrive Helper (Alerts)" && report?.pid == 29782 && report?.target == "com.apple.usernoted.client")

        typealias Parser = ViolationMonitor.Parser
        #expect(Parser.networkEvent(operation: "network-outbound", target: "remote:*:443")?.kind == .network)
        #expect(Parser.networkEvent(operation: "network-outbound", target: "remote:*:443")?.target.contains("443") == true)
        #expect(Parser.networkEvent(operation: "network-outbound", target: "remote:203.0.113.9:80")?.target == "203.0.113.9:80")
        #expect(Parser.networkEvent(operation: "network-outbound", target: "/private/var/run/mDNSResponder")?.kind == .network)
        #expect(Parser.networkEvent(operation: "network-inbound", target: "local:*:8080")?.target.contains("8080") == true)
        #expect(Parser.networkEvent(operation: "network-outbound", target: "/private/var/run/syslog") == nil, "规则没挡别的本地套接字")
    }
}
