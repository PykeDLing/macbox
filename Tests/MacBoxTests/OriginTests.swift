import Foundation
import Testing
@testable import MacBox

/// 操作的发起方（见 Origin）：界面发起的切页面、弹询问、显示进度和出错；命令行发起的不动界面，结果交回给它。
/// 要启动真实的隔离会话、用 MacBox 的数据目录，只在设置了 MACBOX_DATA_ROOT 时运行
@Suite("发起方", .serialized, .enabled(if: AppPaths.override != nil, "需要 MACBOX_DATA_ROOT"))
@MainActor
struct OriginTests {
    /// 界面上能看到的变化：切了页面、选了应用、要打开窗口
    private func moved(_ store: BoxStore) -> Bool {
        store.destination != .settings || store.selection != nil || store.windowRequest != nil
    }

    private func resetInterface(_ store: BoxStore) {
        store.destination = .settings
        store.selection = nil
        store.windowRequest = nil
    }

    @Test("添加：命令行添加的返回每个文件的结果，不显示进度、出错，不提议放进虚拟 Mac，不问兼容性，不选中；界面添加的照旧",
          .timeLimit(.minutes(3)))
    func importOutcomes() async throws {
        let fixture = LifecycleFixture()
        defer { await fixture.cleanup() }
        let root = FileManager.default.temporaryDirectory.appending(path: "MacBoxTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let tag = UUID().uuidString.prefix(8).lowercased()
        // 普通的 App；带特权辅助程序的 App（需要虚拟 Mac）；不是安装包的文件；只有驱动的安装包
        let plain = root.appending(path: "Plain.app")
        try makeFakeApp(at: plain, identifier: "dev.macboxtest.origin-plain-\(tag)", script: "#!/bin/sh\nexit 0\n")
        let helper = root.appending(path: "Helper.app")
        try makeFakeApp(at: helper, identifier: "dev.macboxtest.origin-helper-\(tag)", script: "#!/bin/sh\nexit 0\n")
        try writeText("helper", helper.appending(path: "Contents/Library/LaunchServices/dev.macboxtest.helper"))
        let text = root.appending(path: "notes.txt")
        try writeText("not an installer", text)
        let payload = root.appending(path: "payload/Library/Audio/Plug-Ins/HAL/MacBoxTestDriver.driver/Contents")
        try AppPaths.ensure(payload)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.macboxtest.driver"], format: .xml, options: 0)
            .write(to: payload.appending(path: "Info.plist"))
        let driver = root.appending(path: "Driver.pkg")
        try await Shell.run("/usr/bin/pkgbuild", ["--quiet", "--identifier", "dev.macboxtest.origin.driver", "--version", "1",
                                                  "--root", root.appending(path: "payload").path, "--install-location", "/", driver.path])
        let store = await fixture.start()

        func check(_ outcomes: [ImportOutcome]) throws -> (plain: Box, helper: Box) {
            try #require(outcomes.count == 4)
            guard case .added(let plainBox) = outcomes[0], case .added(let helperBox) = outcomes[1] else {
                Issue.record("两个 App 都应该添加好：\(outcomes)")
                throw CancellationError()
            }
            fixture.track(plainBox.paths.url)
            fixture.track(helperBox.paths.url)
            guard case .failed(let file, let reason) = outcomes[2] else {
                Issue.record("不是安装包的文件应该添加失败：\(outcomes[2])")
                throw CancellationError()
            }
            #expect(file == text && reason.contains(".txt"), "原因里不带文件名：文件名在 file 里，由呈现的一方拼进句子")
            guard case .needsVirtualMac(let offered, _) = outcomes[3] else {
                Issue.record("只有驱动的安装包应该建议放进虚拟 Mac：\(outcomes[3])")
                throw CancellationError()
            }
            #expect(offered == driver)
            #expect(helperBox.config.issues.contains { $0.severity == .needsVirtualMac })
            #expect(helperBox.config.runtime == .isolated, "按设置是询问，不该自动改用虚拟 Mac")
            return (plainBox, helperBox)
        }

        // 命令行
        resetInterface(store)
        var stages: [String: [ImportStage]] = [:]
        var shownStatus: [String?] = []
        let fromCommandLine = await store.importItems([plain, helper, text, driver], from: .commandLine) { file, stage in
            stages[file.lastPathComponent, default: []].append(stage)
            shownStatus.append(store.importStatus)
        }
        _ = try check(fromCommandLine)
        #expect(stages["Plain.app"] == [.reading, .extracting, .checking, .preparingKeychain])
        #expect(stages["notes.txt"] == [.reading])
        #expect(shownStatus.allSatisfy { $0 == nil }, "命令行添加的进度不该显示在界面上")
        #expect(store.importError == nil)
        #expect(store.virtualMacOffers.isEmpty)
        #expect(store.prompt == nil && store.prompts.isEmpty, "命令行添加的不该弹兼容性询问")
        #expect(!moved(store), "命令行添加的不该切页面、选中")

        // 界面：照旧
        resetInterface(store)
        shownStatus = []
        let fromInterface = await store.importItems([plain, helper, text, driver]) { _, _ in
            shownStatus.append(store.importStatus)
        }
        let added = try check(fromInterface)
        #expect(shownStatus.allSatisfy { $0 != nil }, "界面添加的进度要显示")
        #expect(store.importError?.contains("notes.txt") == true)
        #expect(store.virtualMacOffers.map(\.file) == [driver])
        #expect(store.prompt?.boxID == added.helper.id, "界面添加的需要虚拟 Mac 的要问")
        #expect(store.selection == added.helper.id, "界面添加的要选中最后添加好的")
    }

    @Test("打开：命令行打开的打不开时只返回原因，不切页面（包括维护后才打开、很快退出的）；界面打开的照旧切过去",
          .timeLimit(.minutes(2)))
    func openFailures() async throws {
        let fixture = LifecycleFixture()
        defer { await fixture.cleanup() }
        let shared = "dev.macboxtest.origin-shared-\(UUID().uuidString.prefix(8).lowercased())"
        let script = "trap 'exit 0' TERM\nwhile :; do sleep 0.1; done\n"
        let firstPaths = try await fixture.makeBox("First", script: script, prefix: shared)
        let secondPaths = try await fixture.makeBox("Second", script: script, prefix: shared)
        let failingPaths = try await fixture.makeBox("Failing", script: "exit 3\n")
        let store = await fixture.start()
        let first = try #require(store.box(id: try firstPaths.loadConfig().id))
        let second = try #require(store.box(id: try secondPaths.loadConfig().id))
        let failing = try #require(store.box(id: try failingPaths.loadConfig().id))

        #expect(await first.open(from: .commandLine) == .launching)
        #expect(await eventually(.seconds(10)) { first.isRunning })
        #expect(await first.open(from: .commandLine) == .alreadyOpen)

        // 偏好设置冲突
        resetInterface(store)
        guard case .failed(let reason) = await second.open(from: .commandLine) else {
            Issue.record("和正在运行的「First」共用设置，不该打开")
            return
        }
        #expect(reason.contains("First") && second.lastError == reason)
        #expect(!moved(store), "命令行打开的打不开时不该切页面")
        guard case .failed = await second.open() else {
            Issue.record("界面打开也不该打开")
            return
        }
        #expect(store.destination == .allApps && store.selection == second.id, "界面打开的打不开时要切过去让人看到")

        // 维护期间要打开：记下是命令行要打开的，维护完打开、很快以非 0 退出，也不切页面
        resetInterface(store)
        let (gate, release) = AsyncStream<Void>.makeStream()
        let maintenance = Task { try await failing.performMaintenance { for await _ in gate {} } }
        #expect(await eventually { failing.activity == .maintenance })
        #expect(await failing.open(from: .commandLine) == .willOpenWhenIdle)
        release.finish()
        try await maintenance.value
        #expect(await eventually(.seconds(10)) { failing.activity == .idle && failing.lastError?.contains("3") == true })
        #expect(!moved(store), "命令行打开的很快退出时不该切页面")

        // 同一个应用，界面打开的照旧切过去
        await failing.open()
        #expect(await eventually(.seconds(10)) { failing.activity == .idle && failing.lastError != nil })
        #expect(store.selection == failing.id, "界面打开的很快退出时要切过去让人看到")

        // 维护期间界面和命令行都要打开：按界面的来，后到的命令行不能把它盖掉
        resetInterface(store)
        let (secondGate, secondRelease) = AsyncStream<Void>.makeStream()
        let secondMaintenance = Task { try await failing.performMaintenance { for await _ in secondGate {} } }
        #expect(await eventually { failing.activity == .maintenance })
        #expect(await failing.open() == .willOpenWhenIdle)
        #expect(await failing.open(from: .commandLine) == .willOpenWhenIdle)
        secondRelease.finish()
        try await secondMaintenance.value
        #expect(await eventually(.seconds(10)) { failing.activity == .idle && store.selection == failing.id },
                "界面也要打开，很快退出时要切过去")
    }

    @Test("运行中被拦截：命令行打开的这次运行不问要不要改用虚拟 Mac（拦截照样记进报告）；界面打开的照旧问",
          .timeLimit(.minutes(2)))
    func runtimeBlocks() async throws {
        let fixture = LifecycleFixture()
        defer { await fixture.cleanup() }
        let paths = try await fixture.makeBox("Blocked", script: "sleep 1\nexit 0\n")
        let store = await fixture.start()
        let box = try #require(store.box(id: try paths.loadConfig().id))
        let target = "/Library/LaunchDaemons/dev.macboxtest.origin.plist"

        func run(from origin: Origin) async {
            #expect(await box.open(from: origin) == .launching)
            #expect(await eventually(.seconds(10)) { box.isRunning })
            box.record(BlockEvent(kind: .systemInstall, target: target))
            #expect(await eventually(.seconds(10)) { box.activity == .idle })
        }

        await run(from: .commandLine)
        #expect(store.prompt == nil && store.prompts.isEmpty, "命令行打开的不该弹询问")
        #expect(box.config.runtime == .isolated)
        #expect(box.report?.blocks.contains { $0.kind == .systemInstall } == true, "拦截要记进报告，命令行从这里说给用户")

        await run(from: .interface)
        #expect(store.prompt?.boxID == box.id, "界面打开的要问")
        if let prompt = store.prompt { store.dismissPrompt(id: prompt.id) }
    }
}
