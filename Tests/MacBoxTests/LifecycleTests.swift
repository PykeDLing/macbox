import Foundation
import Testing
@testable import MacBox

/// 一个测试用的 BoxStore 和它的盒子。结束时（cleanup）：强制结束还在运行的应用、等它们收尾完，
/// 停掉这个 BoxStore 启动的守卫（守卫是全进程共用的，下一个测试的 BoxStore 会重新启动它），删掉盒子
@MainActor
final class LifecycleFixture {
    private(set) var boxURLs: [URL] = []
    private(set) var store: BoxStore?

    init() {
        // 只登记在内存里（不写任何偏好设置文件）：询问而不是自动改用虚拟 Mac；新添加的不放启动器
        UserDefaults.standard.register(defaults: [CompatibilityPolicy.key: CompatibilityPolicy.ask.rawValue,
                                                  "defaultShowInLaunchpad": false])
    }

    /// 偏好设置前缀只用测试专用的；盒子里没有设置，借出、收回都不会动真实的偏好设置。App 平时是锁着的
    func makeBox(_ name: String = "Fake", script: String, prefix: String? = nil,
                 configure: (inout BoxConfig) -> Void = { _ in }) async throws -> BoxPaths {
        let id = UUID()
        let paths = BoxPaths.new(id: id)
        boxURLs.append(paths.url)
        let prefix = prefix ?? "dev.macboxtest.lifecycle-\(id.uuidString.prefix(8).lowercased())"
        var config = BoxConfig(id: id, name: name, bundleIdentifier: prefix + ".app", appFolderName: "\(name).app")
        config.preferencePrefixes = [prefix]
        config.shareDownloads = false
        config.showInLaunchpad = false
        configure(&config)
        try makeFakeApp(at: paths.app(config), identifier: config.bundleIdentifier, script: "#!/bin/sh\n" + script)
        try paths.save(config)
        try await TestKeychain.install(into: paths)
        try AppLock.lock(paths.app(config))
        return paths
    }

    /// 新的 BoxStore：读取盒子、做启动时的收尾、启动守卫
    func start() async -> BoxStore {
        let store = BoxStore()
        self.store = store
        store.start()
        await store.ready()
        return store
    }

    func track(_ url: URL) { boxURLs.append(url) }

    func cleanup() async {
        if let store {
            for box in store.boxes where box.isRunning { await box.forceQuit() }
            _ = await eventually(.seconds(15)) { store.boxes.allSatisfy { $0.activity == .idle } }
            store.stop()
        }
        for pid in EscapeGuard.boxProcessesNow() { kill(pid, SIGKILL) }
        for url in boxURLs { try? FileOps.removeTree(url) }
    }
}

/// 读出盒子主目录里 runs 文件的行数：测试用的 App 每启动一次往里写一行
@MainActor
func runs(_ box: Box) -> Int {
    ((try? String(contentsOf: box.paths.home.appending(path: "runs"), encoding: .utf8)) ?? "")
        .split(separator: "\n").count
}

/// Box / BoxStore 的生命周期：打开、退出、收尾、维护、删除、启动时的收尾、兼容性询问、启动器。
/// 要启动真实的隔离会话、用 MacBox 的数据目录、启动守卫，只在设置了 MACBOX_DATA_ROOT 时运行
@Suite("生命周期", .serialized, .enabled(if: AppPaths.override != nil, "需要 MACBOX_DATA_ROOT"))
@MainActor
struct LifecycleTests {
    @Test("打开 → 运行 → 收尾 → 空闲，运行期间解锁、之后锁上；启动期间请求退出，启动后立即转达；很快以非 0 退出的说明原因",
          .timeLimit(.minutes(2)))
    func activityTransitions() async throws {
        let fixture = LifecycleFixture()
        defer { await fixture.cleanup() }
        let normalPaths = try await fixture.makeBox(script: "sleep 1\nexit 0\n")
        let failingPaths = try await fixture.makeBox("Failing", script: "exit 3\n")
        let quittingPaths = try await fixture.makeBox("Quitting", script: "trap 'exit 5' TERM\nwhile :; do sleep 0.1; done\n")
        let store = await fixture.start()
        let normal = try #require(store.box(id: try normalPaths.loadConfig().id))
        let failing = try #require(store.box(id: try failingPaths.loadConfig().id))
        let quitting = try #require(store.box(id: try quittingPaths.loadConfig().id))

        await normal.open()
        #expect(normal.activity == .launching)
        #expect(await eventually(.seconds(10)) { normal.isRunning })
        #expect(!AppLock.isLocked(normal.appURL), "运行期间 App 要解锁")
        #expect(await eventually(.seconds(10)) { normal.activity == .idle })
        #expect(normal.lastError == nil)
        #expect(AppLock.isLocked(normal.appURL), "运行结束后 App 要重新锁上")

        await failing.open()
        #expect(await eventually(.seconds(10)) { failing.activity == .idle && failing.lastError != nil })
        #expect(failing.lastError?.contains("3") == true, "要说出退出码")
        #expect(store.selection == failing.id, "失败了要让人看到")

        await quitting.open()
        #expect(quitting.activity == .launching)
        quitting.quit()
        #expect(await eventually(.seconds(10)) { quitting.activity == .idle }, "启动期间的退出请求没有转达")
        #expect(quitting.lastError == nil, "请求过退出的，很快退出不算启动失败")
    }

    @Test("维护期间的打开记下来，维护完再打开；主程序已退出、只剩后台程序时，打开会请它们退出再重新打开",
          .timeLimit(.minutes(2)))
    func pendingOpen() async throws {
        let fixture = LifecycleFixture()
        defer { await fixture.cleanup() }
        let plainPaths = try await fixture.makeBox(script: "echo run >> \"$HOME/runs\"\nexit 0\n")
        let helperPaths = try await fixture.makeBox("Helper", script: """
        echo run >> "$HOME/runs"
        ( trap 'exit 0' TERM; while :; do sleep 0.1; done ) &
        exit 0
        """)
        let store = await fixture.start()
        let plain = try #require(store.box(id: try plainPaths.loadConfig().id))
        let helper = try #require(store.box(id: try helperPaths.loadConfig().id))

        // 维护一直进行到放行为止
        let (gate, release) = AsyncStream<Void>.makeStream()
        let maintenance = Task { try await plain.performMaintenance { for await _ in gate {} } }
        #expect(await eventually { plain.activity == .maintenance })
        await plain.open()
        #expect(plain.activity == .maintenance && runs(plain) == 0, "维护期间不能打开")
        release.finish()
        try await maintenance.value
        #expect(await eventually(.seconds(10)) { runs(plain) == 1 }, "维护期间的打开被丢掉了")

        await helper.open()
        #expect(await eventually(.seconds(10)) { helper.session?.mainHasExited == true })
        try await Task.sleep(for: .seconds(0.5))
        #expect(helper.isRunning, "后台程序还在，这次运行还没结束")
        await helper.open() // 切换过去：没有可以切过去的，请后台程序退出，之后重新打开
        #expect(helper.notice != nil)
        #expect(await eventually(.seconds(15)) { runs(helper) == 2 }, "没有重新打开")
    }

    @Test("共用偏好设置的两个盒子不能同时运行；另一个盒子借出的设置没收回时也不能打开", .timeLimit(.minutes(2)))
    func overlappingPreferencesRefused() async throws {
        let fixture = LifecycleFixture()
        defer { await fixture.cleanup() }
        let shared = "dev.macboxtest.lifecycle-shared-\(UUID().uuidString.prefix(8).lowercased())"
        let script = "trap 'exit 0' TERM\nwhile :; do sleep 0.1; done\n"
        let firstPaths = try await fixture.makeBox("First", script: script, prefix: shared)
        let secondPaths = try await fixture.makeBox("Second", script: script, prefix: shared)
        let store = await fixture.start()
        let first = try #require(store.box(id: try firstPaths.loadConfig().id))
        let second = try #require(store.box(id: try secondPaths.loadConfig().id))

        await first.open()
        #expect(await eventually(.seconds(10)) { first.isRunning })
        await second.open()
        #expect(second.activity == .idle)
        #expect(second.lastError?.contains("First") == true)
        first.quit()
        #expect(await eventually(.seconds(10)) { first.activity == .idle })

        // 「First」借出的设置没收回（上次收回失败）
        let lease = PreferenceLease(box: first.paths, prefixes: first.config.preferencePrefixes)
        try await lease.checkIn()
        defer { try? await lease.checkOut() }
        await second.open()
        #expect(second.activity == .idle)
        #expect(second.lastError?.contains("First") == true)
        try await lease.checkOut()
        await second.open()
        #expect(await eventually(.seconds(10)) { second.isRunning })
    }

    @Test("启动时盒子里还在运行的程序（上次 MacBox 崩溃留下的）：结束，不记成逃逸，不重新打开", .timeLimit(.minutes(1)))
    func leftoversAreEndedSilently() async throws {
        let fixture = LifecycleFixture()
        defer { await fixture.cleanup() }
        let paths = try await fixture.makeBox(script: "exit 0\n")
        let config = try paths.loadConfig()
        // 主程序换成编译好的程序（进程的可执行文件就在盒子里，像真的 App 那样），以沙盒中、不属于任何会话的方式运行
        let app = paths.app(config)
        let main = app.appending(path: "Contents/MacOS/main")
        try await TestStub.install(at: main)
        let leftover = try ChildProcess.spawn("/usr/bin/sandbox-exec", ["-p", "(version 1)(allow default)", main.path, "leftover", "30000", "0"])
        defer { leftover.signal(SIGKILL) }
        let mainPath = FileOps.realPath(main)
        #expect(await eventually { ProcessTable.path(of: leftover.pid) == mainPath })
        #expect(ProcessTable.isSandboxed(leftover.pid))
        try AppLock.lock(app)

        let store = await fixture.start()
        #expect(await eventually(.seconds(5)) { !isRunning(leftover.pid) }, "遗留的程序没有结束")
        let box = try #require(store.box(id: config.id))
        try await Task.sleep(for: .seconds(1.5)) // 旧版此时已把它当成直接打开、在隔离中重新打开了
        #expect(box.blocks.isEmpty, "不该记成“在沙盒外启动程序”")
        #expect(box.activity == .idle && !FileOps.exists(paths.url.appending(path: "sandbox.sb")), "不该重新打开")
        #expect(AppLock.isLocked(app))
    }

    @Test("添加的 App 是锁着的；导入用的临时盒子不留下", .timeLimit(.minutes(2)))
    func importLocksApp() async throws {
        let searchListBefore = try await Shell.run("/usr/bin/security", ["list-keychains", "-d", "user"]).output
        let fixture = LifecycleFixture()
        defer { await fixture.cleanup() }
        let source = FileManager.default.temporaryDirectory.appending(path: "MacBoxTests-\(UUID().uuidString)/Imported.app")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let identifier = "dev.macboxtest.lifecycle-import-\(UUID().uuidString.prefix(8).lowercased())"
        try makeFakeApp(at: source, identifier: identifier, script: "#!/bin/sh\nexit 0\n")

        let store = await fixture.start()
        await store.importItems([source])
        #expect(store.importError == nil)
        #expect(store.importStatus == nil)
        let box = try #require(store.boxes.first { $0.config.bundleIdentifier == identifier })
        fixture.track(box.paths.url)
        #expect(AppLock.isLocked(box.appURL), "添加之后 App 要锁上")
        #expect(PreferenceLease.domain(identifier, isCoveredBy: box.config.preferencePrefixes))
        #expect(!FileOps.contents(of: AppPaths.boxes).contains { $0.pathExtension == BoxPaths.importingSuffix })
        #expect(try await Shell.run("/usr/bin/security", ["list-keychains", "-d", "user"]).output == searchListBefore)
    }

    @Test("启动时收拾中途崩溃的还原、替换、导入：还原重做，残留删掉，还原点换到一半的改回来", .timeLimit(.minutes(1)))
    func interruptedWorkIsRecovered() async throws {
        let fixture = LifecycleFixture()
        defer { await fixture.cleanup() }
        func write(_ text: String, _ url: URL) throws {
            try AppPaths.ensure(url.deletingLastPathComponent())
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

        // 还原到一半：主目录已经改名成 .old、新的还没就位，Prefs 的克隆做了一半
        let rolling = try await fixture.makeBox("Rolling", script: "exit 0\n")
        try write("saved", rolling.restorePoint.appending(path: "Home/Documents/note.txt"))
        try AppPaths.ensure(rolling.restorePoint.appending(path: "Prefs"))
        try write("now", rolling.home.appending(path: "Documents/note.txt"))
        FileManager.default.createFile(atPath: rolling.rollbackMarker.path, contents: nil)
        try FileManager.default.moveItem(at: rolling.home, to: rolling.url.appending(path: "Home.old"))
        try write("half", rolling.url.appending(path: "Prefs.restoring/x.plist"))
        try write("junk", rolling.url.appending(path: "tmp.deleting-\(UUID().uuidString)/junk"))
        try write("junk", rolling.restorePointStaging.appending(path: "Home/x"))
        try write("junk", rolling.appStaging.appending(path: "New.app/x"))

        // 更新还原点到一半：旧的已改名成 .old，新的还没就位
        let updating = try await fixture.makeBox("Updating", script: "exit 0\n")
        try write("old point", updating.url.appending(path: "RestorePoint.old/Home/note.txt"))

        // 导入到一半
        let partial = BoxPaths.importing(id: UUID())
        fixture.track(partial.url)
        try write("{}", partial.url.appending(path: "Source/x.dmg"))

        let store = await fixture.start()
        #expect(read(rolling.home.appending(path: "Documents/note.txt")) == "saved", "还原没有重做")
        #expect(!FileOps.exists(rolling.rollbackMarker))
        let leftovers = FileOps.contents(of: rolling.url).map(\.lastPathComponent)
            .filter { $0.contains(".old") || $0.contains(".restoring") || $0.contains(".deleting-") || $0.hasSuffix(".tmp") || $0 == "App.new" }
        #expect(leftovers.isEmpty, "残留：\(leftovers)")
        #expect(store.box(id: try rolling.loadConfig().id)?.notice != nil)
        #expect(read(updating.restorePoint.appending(path: "Home/note.txt")) == "old point", "换到一半的还原点没有改回来")
        #expect(!FileOps.exists(partial.url), "导入到一半的盒子没有删掉")
        #expect(store.brokenBoxes.isEmpty)
    }

    @Test("删除前先收回没收回的偏好设置，收不回就不删", .timeLimit(.minutes(1)))
    func deleteSettlesLease() async throws {
        let fixture = LifecycleFixture()
        defer { await fixture.cleanup() }
        let domain = "dev.macboxtest.lifecycle-delete-\(UUID().uuidString.prefix(8).lowercased())"
        let system = AppPaths.realHome.appending(path: "Library/Preferences/\(domain)").path
        defer {
            // 只用 defaults delete 的话，cfprefsd 之后会写回一个空 plist
            _ = try? await Shell.run("/usr/bin/defaults", ["delete", system])
            try? FileManager.default.removeItem(atPath: system + ".plist")
        }
        try await Shell.run("/usr/bin/defaults", ["write", system, "who", "native"])
        let paths = try await fixture.makeBox(script: "exit 0\n", prefix: domain)
        try AppPaths.ensure(paths.prefs)
        try PropertyListSerialization.data(fromPropertyList: ["who": "box"], format: .binary, options: 0)
            .write(to: paths.prefs.appending(path: "\(domain).plist"))
        let lease = PreferenceLease(box: paths, prefixes: [domain])
        try await lease.checkIn() // 借出后 MacBox “崩溃”，启动时也没能收回（下面让 Prefs 写不进去）
        #expect(try await Shell.run("/usr/bin/defaults", ["read", system, "who"]).output == "box\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: paths.prefs.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.prefs.path) }

        let store = await fixture.start()
        let box = try #require(store.box(id: try paths.loadConfig().id))
        #expect(box.lastError != nil, "启动时收不回要告诉用户")
        #expect(store.alerts.count == 1 && store.importError == nil, "启动时的收尾出错不该显示成“无法添加”")
        await #expect(throws: (any Error).self) { try await store.delete(box) }
        #expect(FileOps.exists(paths.url) && store.box(id: box.id) != nil && box.activity == .idle)
        #expect(lease.isOutstanding)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.prefs.path)
        let trashed = try #require(try await store.delete(box))
        // 测试自己放进废纸篓的，测试自己清掉。按路径删：废纸篓本身读不了（隐私保护），FileOps.removeTree 要打开上级目录
        try FileManager.default.removeItem(at: trashed)
        #expect(!FileOps.exists(trashed), "放进废纸篓的测试盒子没有清掉：\(trashed.path)")
        #expect(try await Shell.run("/usr/bin/defaults", ["read", system, "who"]).output == "native\n", "本机原来的设置没有恢复")
        #expect(!FileOps.exists(paths.url) && store.box(id: box.id) == nil)
    }

    @Test("兼容性询问排队、同一个盒子的并成一条；“继续使用本机隔离”记住这次的拦截，同样的不再问、新的照样问",
          .timeLimit(.minutes(2)))
    func compatibilityPrompts() async throws {
        let fixture = LifecycleFixture()
        defer { await fixture.cleanup() }
        let firstPaths = try await fixture.makeBox("First", script: "exit 0\n")
        let secondPaths = try await fixture.makeBox("Second", script: "sleep 1\nexit 0\n")
        let store = await fixture.start()
        let first = try #require(store.box(id: try firstPaths.loadConfig().id))
        let second = try #require(store.box(id: try secondPaths.loadConfig().id))

        store.suggestVirtualMac(for: first, reasons: ["a"])
        store.suggestVirtualMac(for: second, reasons: ["b"])
        store.suggestVirtualMac(for: first, reasons: ["a", "c"])
        #expect(store.prompts.map(\.boxID) == [first.id, second.id], "后一条顶掉了前一条")
        #expect(store.prompt?.reasons == ["a", "c"])
        store.dismissPrompt()
        #expect(store.prompt?.boxID == second.id)
        store.dismissPrompt()
        #expect(store.prompt == nil)

        // 每次运行都写系统目录
        func run(blocking target: String) async {
            await second.open()
            _ = await eventually(.seconds(10)) { second.isRunning }
            second.record(BlockEvent(kind: .systemInstall, target: target))
            _ = await eventually(.seconds(10)) { second.activity == .idle }
        }
        await run(blocking: "/Library/Application Support/dev.macboxtest")
        let prompt = try #require(store.prompt)
        #expect(prompt.boxID == second.id && prompt.blocks.count == 1)
        store.keepNativeIsolation(prompt)
        store.dismissPrompt()
        #expect(try secondPaths.loadConfig().acknowledgedBlocks == prompt.blocks, "选择要存进 box.json")

        await run(blocking: "/Library/Application Support/dev.macboxtest")
        #expect(store.prompt == nil, "同样的拦截又问了一次")
        await run(blocking: "/Library/LaunchDaemons/dev.macboxtest.plist")
        #expect(store.prompt?.boxID == second.id, "新的拦截要问")
        store.dismissPrompt()

        second.config.runtime = .virtualMac
        #expect(second.config.acknowledgedBlocks == nil, "换了运行环境，之前的选择不再算数")
    }

    @Test("Spotlight 启动器：不用 open -g，写着版本；旧写法的、旧版留下的子文件夹里和隐藏的启动器，启动时重写、清掉",
          .timeLimit(.minutes(1)))
    func launchersAreRewritten() async throws {
        let fixture = LifecycleFixture()
        defer {
            await fixture.cleanup()
            for launcher in FileOps.contents(of: AppPaths.launchers) {
                _ = try? await Shell.run(Shell.lsregister, ["-u", launcher.path])
            }
            try? FileOps.removeTree(AppPaths.launchers)
        }
        let paths = try await fixture.makeBox("Launched", script: "exit 0\n") { $0.showInLaunchpad = true }
        let config = try paths.loadConfig()
        try await Launcher.shared.install(paths: paths, config: config)
        let launcher = try #require(FileOps.contents(of: AppPaths.launchers).first { Launcher.boxID(of: $0) == config.id.uuidString })
        let script = launchScript(of: launcher)
        #expect(try String(contentsOf: script, encoding: .utf8) == Launcher.script(for: config.id))
        #expect(!Launcher.script(for: config.id).contains("-g"), "-g 让 MacBox 留在后台，App 到不了前台")
        #expect(Launcher.version(of: launcher) == Launcher.version)
        #expect(!(await Launcher.shared.needsInstall(for: config.id)))

        // 旧写法：没有版本、脚本带 -g
        let infoURL = launcher.appending(path: "Contents/Info.plist")
        var info = try #require(NSDictionary(contentsOf: infoURL) as? [String: Any])
        info["MacBoxLauncherVersion"] = nil
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
        try "#!/bin/sh\nexec /usr/bin/open -g \"macbox://open/\(config.id.uuidString)\"\n".write(to: script, atomically: true, encoding: .utf8)
        #expect(await Launcher.shared.needsInstall(for: config.id))
        // 旧版没有处理名称里的“/”和开头的“.”时建出来的
        let nested = AppPaths.launchers.appending(path: "Legacy/Work.app")
        let hidden = AppPaths.launchers.appending(path: ".Hidden.app")
        for legacy in [nested, hidden] {
            try AppPaths.ensure(legacy.appending(path: "Contents"))
            try PropertyListSerialization.data(fromPropertyList: ["MacBoxBoxID": config.id.uuidString], format: .xml, options: 0)
                .write(to: legacy.appending(path: "Contents/Info.plist"))
        }

        let store = await fixture.start()
        #expect(await eventually(.seconds(10)) {
            !FileOps.exists(nested) && !FileOps.exists(hidden) && !FileOps.exists(nested.deletingLastPathComponent())
        }, "旧版留下的启动器没有清掉")
        #expect(await eventually(.seconds(10)) {
            let mine = FileOps.contents(of: AppPaths.launchers).filter { Launcher.boxID(of: $0) == config.id.uuidString }
            return mine.count == 1 && Launcher.version(of: mine[0]) == Launcher.version
                && (try? String(contentsOf: launchScript(of: mine[0]), encoding: .utf8)) == Launcher.script(for: config.id)
        }, "旧写法的启动器没有重写")
        // 文件写好时登记（lsregister -f）可能还没做完：等这个盒子的启动器同步全部做完，结束时撤销登记才不会被它抢在后面
        await store.box(id: config.id)?.syncLauncher().value
    }

    @Test("退出 MacBox：应用不肯退出时不强制结束，返回它们由用户决定；等待期间打开的不会启动；取消后照常", .timeLimit(.minutes(2)))
    func quitAllAsksInsteadOfKilling() async throws {
        let fixture = LifecycleFixture()
        defer { await fixture.cleanup() }
        // 像弹出“是否存储”、用户点了取消的 App：收到退出请求后不退出
        let stubbornPaths = try await fixture.makeBox("Stubborn", script: """
        trap 'echo term >> "$HOME/terms"' TERM
        touch "$HOME/ready"
        while :; do sleep 0.1; done
        """)
        let latePaths = try await fixture.makeBox("Late", script: "while :; do sleep 0.1; done\n")
        let store = await fixture.start()
        let stubborn = try #require(store.box(id: try stubbornPaths.loadConfig().id))
        let late = try #require(store.box(id: try latePaths.loadConfig().id))
        await stubborn.open()
        // 等它装好 TERM 的处理再请求退出（之前收到的话按默认处理，直接就退出了）
        #expect(await eventually(.seconds(10)) { FileOps.exists(stubborn.paths.home.appending(path: "ready")) })

        let quitting = Task { await store.quitAll(patience: .seconds(2)) }
        try await Task.sleep(for: .milliseconds(300))
        await late.open() // MacBox 正在退出：不再打开
        #expect(late.activity == .idle)
        let refusing = await quitting.value
        #expect(refusing.map(\.id) == [stubborn.id])
        #expect(stubborn.isRunning, "不能擅自强制结束")
        #expect(FileOps.exists(stubborn.paths.home.appending(path: "terms")), "退出请求没有送到")
        #expect(await eventually(.seconds(5)) { stubborn.offersForceQuit }, "要提供强制退出")

        await stubborn.forceQuit()
        #expect(await store.quitAll(patience: .seconds(2)).isEmpty)
        #expect(store.liveBoxes.isEmpty)
        #expect(!PreferenceLease(box: stubborn.paths, prefixes: stubborn.config.preferencePrefixes).isOutstanding)

        store.cancelQuit()
        await late.open()
        #expect(await eventually(.seconds(10)) { late.isRunning })
    }

    @Test("主程序退出、辅助程序还在时被直接打开（“重启以生效”）：这次运行结束后在隔离中重新打开", .timeLimit(.minutes(2)))
    func relaunchAfterSelfRestart() async throws {
        let fixture = LifecycleFixture()
        defer { await fixture.cleanup() }
        let paths = try await fixture.makeBox(script: """
        echo run >> "$HOME/runs"
        ( sleep 2 ) &
        exit 0
        """)
        let store = await fixture.start()
        let box = try #require(store.box(id: try paths.loadConfig().id))
        await box.open()
        #expect(await eventually(.seconds(10)) { box.session?.mainHasExited == true })
        let main = FileOps.realPath(try AppInspector.info(of: box.appURL).executable)
        // 守卫结束了系统在沙盒外启动的新实例
        store.handleEscape(EscapeGuard.Escape(path: main, owner: main))
        #expect(box.isRunning, "辅助程序还在，这次运行还没结束")
        #expect(await eventually(.seconds(15)) { runs(box) == 2 }, "没有在隔离中重新打开")
        #expect(await eventually(.seconds(5)) { box.blocks.contains { $0.kind == .escapedLaunch } }, "拦截记录要补上")
    }

    @Test("聚焦里的启动器对应的应用不在了：打开主窗口并说明，而不是什么也不做")
    func unknownLauncher() async throws {
        let fixture = LifecycleFixture()
        defer { await fixture.cleanup() }
        let store = await fixture.start()
        store.destination = .settings
        store.handle(try #require(URL(string: "macbox://open/\(UUID().uuidString)")))
        #expect(store.alerts.count == 1)
        #expect(store.destination == .allApps && store.windowRequest?.window == .library)
    }

    @Test("只有驱动、没有 App 的安装包：提出放进虚拟 Mac，不当作添加失败，不留下盒子", .timeLimit(.minutes(1)))
    func driverPackageOffersVirtualMac() async throws {
        let fixture = LifecycleFixture()
        defer { await fixture.cleanup() }
        let root = FileManager.default.temporaryDirectory.appending(path: "MacBoxTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = root.appending(path: "payload/Library/Audio/Plug-Ins/HAL/MacBoxTestDriver.driver/Contents")
        try AppPaths.ensure(driver)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.macboxtest.driver"], format: .xml, options: 0)
            .write(to: driver.appending(path: "Info.plist"))
        let pkg = root.appending(path: "Driver.pkg")
        try await Shell.run("/usr/bin/pkgbuild", ["--quiet", "--identifier", "dev.macboxtest.lifecycle.driver", "--version", "1",
                                                  "--root", root.appending(path: "payload").path, "--install-location", "/", pkg.path])

        let store = await fixture.start()
        let before = Set(FileOps.contents(of: AppPaths.boxes))
        await store.importItems([pkg])
        #expect(store.virtualMacOffers.map(\.file) == [pkg])
        #expect(store.importError == nil)
        #expect(Set(FileOps.contents(of: AppPaths.boxes)) == before, "不该留下盒子")
    }
}

/// 启动器的脚本文件
private func launchScript(of launcher: URL) -> URL { launcher.appending(path: "Contents/MacOS/launch") }

/// 界面文字的英文版本统一用弯撇号（’），和其余 40 多处一致
@Suite("界面文字")
struct InterfaceTextTests {
    @Test("英文文字里没有直撇号（can't → can’t）")
    func curlyApostrophes() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        // L("中文", "English")：只看第二个参数是字符串字面量的
        let call = /L\("(?:[^"\\]|\\.)*",\s*"((?:[^"\\]|\\.)*)"/
        var offending: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: call) where match.output.1.contains(/[A-Za-z]'[A-Za-z]/) {
                offending.append("\(file.lastPathComponent): \(match.output.1.prefix(60))")
            }
        }
        #expect(offending.isEmpty, "\(offending)")
    }
}
