import Foundation
import Testing
@testable import MacBox

/// 完整的隔离会话（IsolatedSession.run）：盒子在 MACBOX_DATA_ROOT 下，App 是主程序为 shell 脚本的假 App，
/// 偏好设置前缀只用测试专用的（盒子里没有设置，借出、收回都不会动真实的偏好设置）
@Suite("隔离会话", .enabled(if: AppPaths.override != nil, "需要 MACBOX_DATA_ROOT"))
struct SessionTests {
    final class Holder {
        var session: IsolatedSession?
    }

    /// 平时 App 是锁着的（见 AppLock），这里也先锁上
    func makeBox(script: String, installer: Bool = false, rawExecutable: String? = nil) async throws -> (BoxPaths, BoxConfig) {
        let id = UUID()
        let paths = BoxPaths.new(id: id)
        let prefix = "dev.macboxtest.session-\(id.uuidString.prefix(8).lowercased())"
        var config = BoxConfig(id: id, name: "Fake", bundleIdentifier: prefix + ".app", appFolderName: "Fake.app")
        config.preferencePrefixes = [prefix]
        config.shareDownloads = false
        config.showInLaunchpad = false
        config.isInstaller = installer
        let app = paths.app(config)
        try makeFakeApp(at: app, identifier: config.bundleIdentifier, script: "#!/bin/sh\n" + script)
        if let rawExecutable {
            try rawExecutable.write(to: app.appending(path: "Contents/MacOS/main"), atomically: true, encoding: .utf8)
        }
        try paths.save(config)
        try await TestKeychain.install(into: paths)
        try AppLock.lock(app)
        return (paths, config)
    }

    func start(_ paths: BoxPaths, _ config: BoxConfig) -> (Holder, Task<IsolatedSession.Outcome, Error>) {
        let holder = Holder()
        let task = Task {
            try await IsolatedSession.run(paths: paths, config: config, onStart: { holder.session = $0 }, onActivity: { _ in })
        }
        return (holder, task)
    }

    /// 测试中途失败时不留下还在运行的进程：结束会话进程组里在沙盒中的进程，以及可执行文件在盒子里的
    func killLeftovers(_ holder: Holder, box: BoxPaths? = nil) {
        if let group = holder.session?.mainPID {
            for pid in ProcessTable.pids(inGroup: group) where ProcessTable.isSandboxed(pid) { kill(pid, SIGKILL) }
        }
        if let box {
            for pid in ProcessTable.processes(under: FileOps.realPath(box.url) + "/") { kill(pid, SIGKILL) }
        }
    }

    func lease(_ paths: BoxPaths, _ config: BoxConfig) -> PreferenceLease {
        PreferenceLease(box: paths, prefixes: config.preferencePrefixes)
    }

    @Test("主进程退出后它启动的系统程序还在：会话不结束、偏好设置不收回；退出请求能送到它", .timeLimit(.minutes(1)))
    func leftoverAfterMainExit() async throws {
        let (paths, config) = try await makeBox(script: """
        ( trap 'echo got > "$TMPDIR/helper-term"; exit 0' TERM; while :; do sleep 0.1; done ) &
        exit 0
        """)
        defer { try? FileManager.default.removeItem(at: paths.url) }
        let (holder, task) = start(paths, config)
        defer { killLeftovers(holder) }
        #expect(await eventually(.seconds(10)) { holder.session?.mainHasExited == true })
        let session = try #require(holder.session)
        try await Task.sleep(for: .seconds(2.5)) // 旧版此时已认为会话结束、收回了偏好设置
        #expect(lease(paths, config).isOutstanding, "会话里还有进程在运行，偏好设置就被收回了")

        session.terminate()
        let outcome = try await task.value
        #expect(FileManager.default.fileExists(atPath: paths.tmp.appending(path: "helper-term").path), "没收到退出请求")
        #expect(outcome.mainExitStatus == 0)
        #expect(outcome.mainRanFor < 2)
        #expect(!lease(paths, config).isOutstanding)
        #expect(AppLock.isLocked(paths.app(config)))
    }

    @Test("退出只是请求：不会到时间就强制结束，可以再次请求；强制结束要单独调用", .timeLimit(.minutes(1)))
    func terminateIsOnlyARequest() async throws {
        // 像弹出“是否存储”的 App：收到退出请求后不退出
        let (paths, config) = try await makeBox(script: """
        trap 'echo t >> "$TMPDIR/terms"' TERM
        touch "$TMPDIR/ready"
        while :; do sleep 0.2; done
        """)
        defer { try? FileManager.default.removeItem(at: paths.url) }
        let (holder, task) = start(paths, config)
        defer { killLeftovers(holder) }
        #expect(await eventually(.seconds(10)) {
            holder.session != nil && FileManager.default.fileExists(atPath: paths.tmp.appending(path: "ready").path)
        })
        let session = try #require(holder.session)

        session.terminate()
        try await Task.sleep(for: .seconds(1))
        session.terminate()
        try await Task.sleep(for: .seconds(4.6)) // 第一次请求 5.6 秒后：旧版此时已强制结束
        #expect(!session.mainHasExited, "退出请求自动变成了强制结束")
        let terms = (try? String(contentsOf: paths.tmp.appending(path: "terms"), encoding: .utf8)) ?? ""
        #expect(terms.split(separator: "\n").count == 2, "第二次请求没有发出")

        await session.forceQuit()
        let outcome = try await task.value
        #expect(outcome.mainExitStatus == 128 + SIGKILL)
        #expect(AppLock.isLocked(paths.app(config)))
    }

    @Test("主进程不是带界面的 App 时，退出请求也送到离开了进程组的盒子程序", .timeLimit(.minutes(1)))
    func terminateReachesDetachedHelpers() async throws {
        let (paths, config) = try await makeBox(script: """
        "$(dirname "$0")/detached"
        trap 'exit 0' TERM
        touch "$TMPDIR/ready"
        while :; do sleep 0.2; done
        """)
        defer { try? FileManager.default.removeItem(at: paths.url) }
        let app = paths.app(config)
        try await TestDetachedHelper.install(at: app.appending(path: "Contents/MacOS/detached"))
        try AppLock.lock(app)
        let (holder, task) = start(paths, config)
        defer { killLeftovers(holder, box: paths) }
        #expect(await eventually(.seconds(10)) {
            holder.session != nil && FileManager.default.fileExists(atPath: paths.tmp.appending(path: "ready").path)
        })
        let session = try #require(holder.session)
        #expect(await eventually {
            ProcessTable.processes(under: FileOps.realPath(app) + "/").contains { ProcessTable.lineage(of: $0)?.group != session.mainPID }
        }, "辅助程序应该已经离开会话的进程组")

        session.terminate()
        let marker = paths.tmp.appending(path: "detached-term")
        let reached = await eventually(.seconds(5)) { FileManager.default.fileExists(atPath: marker.path) }
        #expect(reached, "离开了进程组的盒子程序没收到退出请求")
        if !reached { await session.forceQuit() }
        let outcome = try await task.value
        #expect(outcome.mainExitStatus == 0)
        #expect(AppLock.isLocked(app))
    }

    @Test("盒子里的文件夹（旧版规则下）被换成指向别处的链接：不打开，也不改动链接指向的文件",
          .timeLimit(.minutes(1)), arguments: ["App", "Home/Library/Keychains"])
    func replacedFolderIsRefused(folder: String) async throws {
        let (paths, config) = try await makeBox(script: "exit 0\n")
        let victim = AppPaths.root.appending(path: "victim-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: paths.url)
            try? FileManager.default.removeItem(at: victim)
        }
        // 把盒子里的文件夹搬到盒子外（代表你自己的文件），原处换成指向它的符号链接
        let original = paths.url.appending(path: folder)
        try FileManager.default.moveItem(at: original, to: victim)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: victim)
        let victimMain = victim.appending(path: "\(config.appFolderName)/Contents/MacOS/main")
        let victimLogin = victim.appending(path: "login.keychain-db")
        if folder == "App" {
            try AppLock.unlock(victim.appending(path: config.appFolderName)) // 你自己装的 App：能运行
        } else {
            try "precious".write(to: victimLogin, atomically: true, encoding: .utf8) // 你自己的「登录」钥匙串
        }

        let error = await #expect(throws: MacBoxError.self) {
            try await IsolatedSession.run(paths: paths, config: config, onStart: { _ in }, onActivity: { _ in })
        }
        #expect(error?.message.contains("link") == true || error?.message.contains("链接") == true)
        if folder == "App" {
            #expect(access(victimMain.path, X_OK) == 0, "顺着链接去掉了盒子外 App 的执行权限")
        } else {
            #expect((try? String(contentsOf: victimLogin, encoding: .utf8)) == "precious", "顺着链接替换了盒子外的钥匙串")
        }
        #expect(!lease(paths, config).isOutstanding)
    }

    @Test("退出码和运行时长；只有在线安装器才找下载的安装包；偏好设置已收回", .timeLimit(.minutes(1)), arguments: [false, true])
    func outcome(installer: Bool) async throws {
        let (paths, config) = try await makeBox(script: """
        dd if=/dev/zero of="$HOME/Documents/big.dmg" bs=1048576 count=2 2>/dev/null
        exit 3
        """, installer: installer)
        defer { try? FileManager.default.removeItem(at: paths.url) }
        let outcome = try await IsolatedSession.run(paths: paths, config: config, onStart: { _ in }, onActivity: { _ in })
        #expect(outcome.mainExitStatus == 3)
        #expect(outcome.mainRanFor < 3)
        #expect(outcome.downloadedPackages.map(\.lastPathComponent) == (installer ? ["big.dmg"] : []))
        #expect(outcome.preferencesReturnError == nil)
        #expect(!lease(paths, config).isOutstanding)
        #expect(AppLock.isLocked(paths.app(config)), "运行结束后 App 要重新锁上")
    }

    @Test("运行报告：对比出这次写下的文件、改了的设置；MacBox 自己的准备不算", .timeLimit(.minutes(1)))
    func reportChanges() async throws {
        // 偏好设置域就是 App 的标识符（从 Info.plist 读，测试专用的前缀）：写进系统里借出的域，收回时进盒子
        let (paths, config) = try await makeBox(script: """
        mkdir -p "$HOME/Library/Application Support/Fake"
        echo data > "$HOME/Library/Application Support/Fake/state.db"
        domain=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$(dirname "$0")/../Info.plist")
        /usr/bin/defaults write "$domain" reportKey -string yes
        exit 0
        """)
        defer { try? FileManager.default.removeItem(at: paths.url) }
        let outcome = try await IsolatedSession.run(paths: paths, config: config, onStart: { _ in }, onActivity: { _ in })
        let changes = try #require(outcome.changes)
        let fake = try #require(changes.files.first { $0.path == "~/Library/Application Support/Fake" })
        #expect(fake.totals.created == 1 && fake.examples == ["state.db"])
        #expect(!changes.files.contains { $0.path.hasPrefix("~/Library/Keychains") || $0.path.hasPrefix("~/Downloads") },
                "MacBox 启动前准备的钥匙串、「下载」算到了应用头上：\(changes.files.map(\.path))")
        #expect(changes.preferences == [PreferenceChange(domain: config.bundleIdentifier, isNew: true, added: ["reportKey"],
                                                         changed: [], removed: [])])
        #expect(!lease(paths, config).isOutstanding)
    }

    @Test("运行报告：运行期间看得到会话里的进程连了哪里", .timeLimit(.minutes(1)))
    func reportConnections() async throws {
        var options = ChildProcess.Options()
        options.output = .pipe
        let listener = try ChildProcess.spawn("/usr/bin/python3", ["-I", "-c", """
        import socket, time
        s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(8)
        print(s.getsockname()[1], flush=True)
        time.sleep(60)
        """], options: options)
        defer { listener.signal(SIGKILL) }
        var lines = listener.standardOutput.lines().makeAsyncIterator()
        let port = try #require(await lines.next().flatMap { Int($0) })
        // 主程序启动的系统程序连上去，连着不放一会儿（采样每秒一次）
        let (paths, config) = try await makeBox(script: """
        /usr/bin/python3 -I -c 'import socket, time; c = socket.create_connection(("127.0.0.1", \(port))); time.sleep(2.5)'
        exit 0
        """)
        defer { try? FileManager.default.removeItem(at: paths.url) }
        var contacts: [ServerContact] = []
        _ = try await IsolatedSession.run(paths: paths, config: config, onStart: { _ in }, onActivity: { activity in
            if case .connected(let contact) = activity { contacts.append(contact) }
        })
        let contact = try #require(contacts.first { $0.port == port }, "\(contacts.map(\.endpoint))")
        #expect(contact.address == "127.0.0.1" && contact.transport == "tcp")
        #expect(contacts.filter { $0.id == contact.id }.count == 1, "同一个连接只报一次")
    }

    @Test("主程序启动不了时给出原因，而不是“点了没反应”", arguments: [
        ("#!/nonexistent/interp\nexit 0\n", "/nonexistent/interp"),
        ("not a program", "main"),
    ])
    func preflight(executable: String, mentions: String) async throws {
        let (paths, config) = try await makeBox(script: "", rawExecutable: executable)
        defer { try? FileManager.default.removeItem(at: paths.url) }
        let error = await #expect(throws: MacBoxError.self) {
            try await IsolatedSession.run(paths: paths, config: config, onStart: { _ in }, onActivity: { _ in })
        }
        #expect(error?.message.contains(mentions) == true)
        #expect(!lease(paths, config).isOutstanding)
    }

    @Test("「共享下载」开了又关：盒子自己的下载收在主目录里，关掉后放回原处")
    func downloadsRoundTrip() throws {
        let paths = BoxPaths.new(id: UUID())
        defer { try? FileManager.default.removeItem(at: paths.url) }
        var config = BoxConfig(id: UUID(), name: "T", bundleIdentifier: "dev.macboxtest.downloads", appFolderName: "T.app")
        config.shareDownloads = false
        try IsolatedSession.prepareHome(paths, config: config)
        let invoice = paths.downloads.appending(path: "invoice.pdf")
        try "pdf".write(to: invoice, atomically: true, encoding: .utf8)

        config.shareDownloads = true
        try IsolatedSession.prepareHome(paths, config: config)
        #expect(FileOps.isSymlink(paths.downloads))
        let kept = IsolatedSession.keptDownloadsNames.map { paths.home.appending(path: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        #expect(kept.map { FileManager.default.fileExists(atPath: $0.appending(path: "invoice.pdf").path) } == true,
                "下载文件应该收在主目录里")
        #expect(!FileOps.contents(of: paths.url).contains { $0.lastPathComponent.hasPrefix("Downloads") })

        config.shareDownloads = false
        try IsolatedSession.prepareHome(paths, config: config)
        #expect(!FileOps.isSymlink(paths.downloads))
        #expect(try String(contentsOf: invoice, encoding: .utf8) == "pdf")
        #expect(IsolatedSession.keptDownloadsNames.allSatisfy { !FileManager.default.fileExists(atPath: paths.home.appending(path: $0).path) })
    }

    @Test("旧版移到盒子根目录的下载文件找回到主目录")
    func legacyDownloadsAreAdopted() throws {
        let paths = BoxPaths.new(id: UUID())
        defer { try? FileManager.default.removeItem(at: paths.url) }
        let legacy = paths.url.appending(path: "Downloads/old.pdf")
        try AppPaths.ensure(legacy.deletingLastPathComponent())
        try "old".write(to: legacy, atomically: true, encoding: .utf8)
        var config = BoxConfig(id: UUID(), name: "T", bundleIdentifier: "dev.macboxtest.downloads", appFolderName: "T.app")
        config.shareDownloads = false
        try IsolatedSession.prepareHome(paths, config: config)
        #expect(try String(contentsOf: paths.downloads.appending(path: "old.pdf"), encoding: .utf8) == "old")
        #expect(!FileManager.default.fileExists(atPath: paths.url.appending(path: "Downloads").path))
    }
}

@Suite("App 上锁")
struct AppLockTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "MacBoxTests-\(UUID().uuidString)")

    func isExecutable(_ url: URL) -> Bool { access(url.path, X_OK) == 0 }

    @Test("上锁去掉所有包（含嵌套的 App、扩展）的 MacOS 里的执行权限；解锁只给程序加回")
    func lockAndUnlock() async throws {
        let app = root.appending(path: "X.app")
        try makeFakeApp(at: app, identifier: "dev.macboxtest.lock", script: "#!/bin/sh\nexit 0\n")
        let main = app.appending(path: "Contents/MacOS/main")
        let helper = app.appending(path: "Contents/Frameworks/F.framework/Versions/A/Helpers/H.app/Contents/MacOS/h")
        try await TestStub.install(at: helper)
        let appex = app.appending(path: "Contents/PlugIns/E.appex/Contents/MacOS/e")
        try AppPaths.ensure(appex.deletingLastPathComponent())
        try FileManager.default.copyItem(at: main, to: appex)
        let data = app.appending(path: "Contents/MacOS/data.txt")
        try "data".write(to: data, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: data.path)
        let tool = app.appending(path: "Contents/Resources/tool.sh")
        try AppPaths.ensure(tool.deletingLastPathComponent())
        try FileManager.default.copyItem(at: main, to: tool)
        let programs = [main, helper, appex]

        #expect(!AppLock.isLocked(app))
        try AppLock.lock(app)
        try AppLock.lock(app) // 可以重复
        #expect(AppLock.isLocked(app))
        #expect(programs.allSatisfy { !isExecutable($0) })
        #expect(isExecutable(tool), "MacOS 以外的不动")

        try AppLock.unlock(app)
        try AppLock.unlock(app)
        #expect(!AppLock.isLocked(app))
        #expect(programs.allSatisfy(isExecutable))
        let mode = try FileManager.default.attributesOfItem(atPath: data.path)[.posixPermissions] as? Int
        #expect(mode == 0o644, "数据文件不加执行权限")
    }

    @Test("上锁、解锁不顺着符号链接改到 App 包以外")
    func lockStaysInsideBundle() throws {
        let victim = root.appending(path: "Victim.app")
        try makeFakeApp(at: victim, identifier: "dev.macboxtest.victim", script: "#!/bin/sh\nexit 0\n")
        let victimMain = victim.appending(path: "Contents/MacOS/main")
        // App 包本身是链接：一个文件也不改，报错
        let linked = root.appending(path: "Linked.app")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: victim)
        #expect(throws: MacBoxError.self) { try AppLock.lock(linked) }
        #expect(isExecutable(victimMain))
        // 包里的 MacOS 是链接：不进去
        let app = root.appending(path: "Z.app")
        try AppPaths.ensure(app.appending(path: "Contents"))
        try FileManager.default.createSymbolicLink(at: app.appending(path: "Contents/MacOS"),
                                                   withDestinationURL: victim.appending(path: "Contents/MacOS"))
        try AppLock.lock(app)
        #expect(isExecutable(victimMain))
        // 不存在的 App：什么也不做
        try AppLock.lock(root.appending(path: "Missing.app"))
    }

    @Test("上锁的 App 也能通过启动前检查；不是程序的过不了")
    func preflightOnLockedApp() throws {
        let app = root.appending(path: "Y.app")
        try makeFakeApp(at: app, identifier: "dev.macboxtest.lock", script: "#!/bin/sh\nexit 0\n")
        let main = app.appending(path: "Contents/MacOS/main")
        try AppLock.lock(app)
        try IsolatedSession.preflight(main)
        try "plain text".write(to: main, atomically: true, encoding: .utf8)
        #expect(throws: MacBoxError.self) { try IsolatedSession.preflight(main) }
    }
}
