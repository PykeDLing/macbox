import CryptoKit
import Foundation
import Testing
import Virtualization
@testable import MacBox

/// 虚拟 Mac 的文件和状态逻辑。全部用临时目录里的 VirtualMacBundle，不碰 VirtualMac.shared 和真实的数据目录，
/// 也不需要虚拟化权限（不创建、不启动虚拟机）
@Suite("虚拟 Mac")
@MainActor
final class VirtualMacTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "MacBoxTests-VM-\(UUID().uuidString)")

    deinit {
        // 有的测试会留下只读的文件夹（0555、0311），普通删除删不掉
        try? VirtualMac.removeTree(root)
    }

    func makeBundle() throws -> VirtualMacBundle {
        let bundle = VirtualMacBundle(url: root.appending(path: "VirtualMac", directoryHint: .isDirectory))
        try AppPaths.ensure(bundle.url)
        return bundle
    }

    /// 装好、关着的虚拟 Mac（虚拟硬件用占位文件代替）
    func installedBundle(asleep: Bool = false) throws -> VirtualMacBundle {
        let bundle = try makeBundle()
        var config = VirtualMacConfig()
        config.installed = true
        try bundle.save(config)
        try write("disk v1", to: bundle.diskURL)
        try write("aux v1", to: bundle.auxiliaryStorageURL)
        if asleep { try write("state 1", to: bundle.saveStateURL) }
        return bundle
    }

    func write(_ text: String, to url: URL) throws {
        try AppPaths.ensure(url.deletingLastPathComponent())
        try text.write(to: url, atomically: false, encoding: .utf8)
    }

    func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func savedConfig(_ bundle: VirtualMacBundle) throws -> VirtualMacConfig? {
        try bundle.loadConfig()
    }

    /// 「传入」里用户看得到的项目（不含隐藏的临时项）
    func visibleItems(_ folder: URL) -> [String] {
        FileOps.contents(of: folder).map(\.lastPathComponent)
    }

    func allItems(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    func lstatInfo(_ url: URL) -> stat? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info : nil
    }

    func mode(_ url: URL) -> mode_t? { lstatInfo(url).map { $0.st_mode & 0o7777 } }

    /// 读隔离标记。属主没有读权限（0111、0311）时读不了扩展属性：临时补上读权限再读
    func quarantine(_ url: URL) -> String? {
        guard let info = lstatInfo(url) else { return nil }
        let original = info.st_mode & 0o7777
        let grant = info.st_mode & S_IFMT != S_IFLNK && original & S_IRUSR == 0
        if grant { chmod(url.path, original | S_IRUSR) }
        defer { if grant { chmod(url.path, original) } }
        var buffer = [UInt8](repeating: 0, count: 256)
        let length = getxattr(url.path, OutgoingQuarantine.attribute, &buffer, buffer.count, 0, XATTR_NOFOLLOW)
        return length > 0 ? String(decoding: buffer.prefix(length), as: UTF8.self) : nil
    }

    func setQuarantine(_ url: URL, _ value: String) {
        #expect(setxattr(url.path, OutgoingQuarantine.attribute, value, value.utf8.count, 0, XATTR_NOFOLLOW) == 0)
    }

    /// 带着用 key 签的、对得上这个文件的 MacBox 标记
    func hasValidMark(_ url: URL, key: SymmetricKey) -> Bool {
        guard let value = quarantine(url), let info = lstatInfo(url) else { return false }
        return OutgoingQuarantine.isValidMark(value, inode: UInt64(info.st_ino), key: key)
    }

    /// 用另一个进程执行 shell 命令（$1 = argument）。监视器不理会 MacBox 自己（这里就是测试进程）的改动，
    /// 客体的写入来自虚拟机进程
    func runShell(_ script: String, _ argument: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", argument]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    // MARK: - 读取配置

    @Test("读取配置：没有文件是未设置；只有硬盘、或 config.json 读不出来都是无法读取；旧文件缺少可选字段照常读取")
    func loadConfigDecisionTable() throws {
        let bundle = try makeBundle()
        #expect(try bundle.loadConfig() == nil)
        #expect(VirtualMac(bundle: bundle).status == .notSetUp)

        // 只有虚拟硬盘：不能当成「未设置」，否则重新设置会覆盖它
        try write("disk", to: bundle.diskURL)
        #expect(throws: (any Error).self) { try bundle.loadConfig() }
        let orphan = VirtualMac(bundle: bundle)
        guard case .unreadable = orphan.status else { Issue.record("应为无法读取：\(orphan.status)"); return }
        #expect(orphan.canTrashUnreadable && !orphan.canRemove)

        // config.json 存在但读不出来（可能来自更新版本）：不提供移到废纸篓，也不写盘
        try write("{ not json", to: bundle.configURL)
        #expect(throws: (any Error).self) { try bundle.loadConfig() }
        let damaged = VirtualMac(bundle: bundle)
        guard case .unreadable = damaged.status else { Issue.record("应为无法读取：\(damaged.status)"); return }
        #expect(!damaged.canTrashUnreadable && !damaged.canRemove)
        damaged.config.cpuCount += 2
        #expect(read(bundle.configURL) == "{ not json")
        #expect(throws: (any Error).self) { try damaged.trashUnreadable() }
        #expect(throws: (any Error).self) { try damaged.remove() }

        // 旧版本写的 config.json 没有后来新增的可选字段
        var config = VirtualMacConfig()
        config.installed = true
        config.osVersion = "macOS 26.0"
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        json.removeValue(forKey: "osVersion")
        try JSONSerialization.data(withJSONObject: json).write(to: bundle.configURL)
        let loaded = try #require(try bundle.loadConfig())
        #expect(loaded.osVersion == nil && loaded.installed && loaded.macAddress == config.macAddress)
        #expect(VirtualMac(bundle: bundle).status == .stopped)

        config.installed = false
        try bundle.save(config)
        #expect(VirtualMac(bundle: bundle).status == .notSetUp)
    }

    // MARK: - 设置

    @Test("设置中途失败或取消：先写好 config.json，再删掉半成品，重开后是「未设置」而不是无法读取")
    func interruptedSetupLeavesNotSetUp() async throws {
        let bundle = try makeBundle()
        let vm = VirtualMac(bundle: bundle)
        #expect(vm.status == .notSetUp && !exists(bundle.configURL))

        await #expect(throws: CancellationError.self) {
            try await vm.buildMachine {
                // 动手创建虚拟硬件之前 config.json 就已经在了：这时崩溃或强制退出，下次也能读成「未设置」
                #expect(self.exists(bundle.configURL))
                #expect(try self.savedConfig(bundle)?.installed == false)
                for file in bundle.setupArtifacts { try self.write("partial", to: file) }
                try bundle.ensureExchangeFolders()
                throw CancellationError()
            }
        }

        for file in bundle.setupArtifacts { #expect(!exists(file), "\(file.lastPathComponent) 应已删除") }
        #expect(try savedConfig(bundle)?.installed == false)
        #expect(exists(bundle.incomingURL) && exists(bundle.outgoingURL))
        #expect(VirtualMac(bundle: bundle).status == .notSetUp)
    }

    @Test("设置的最后一步写不了 config.json：不在内存里标记为已安装，装好的虚拟硬件删掉；写成了才改成「已关机」")
    func completeSetupSavesBeforeMarkingInstalled() async throws {
        let bundle = try makeBundle()
        let vm = VirtualMac(bundle: bundle)
        await #expect(throws: (any Error).self) {
            try await vm.buildMachine {
                for file in bundle.setupArtifacts { try self.write("installed", to: file) }
                // 模拟写盘失败：config.json 的位置被一个文件夹占着，原子写入换不过去
                try FileManager.default.removeItem(at: bundle.configURL)
                try AppPaths.ensure(bundle.configURL)
                try vm.completeSetup(osVersion: "macOS 26.0 (25A1)")
            }
        }
        #expect(vm.status == .notSetUp && !vm.config.installed && vm.config.osVersion == nil)
        for file in bundle.setupArtifacts { #expect(!exists(file), "\(file.lastPathComponent) 应已删除") }

        try FileManager.default.removeItem(at: bundle.configURL)
        try await vm.buildMachine {
            try self.write("installed", to: bundle.diskURL)
            try vm.completeSetup(osVersion: "macOS 26.0 (25A1)")
        }
        #expect(vm.status == .stopped && vm.config.installed)
        #expect(try savedConfig(bundle)?.installed == true)
        #expect(try savedConfig(bundle)?.osVersion == "macOS 26.0 (25A1)")
        #expect(exists(bundle.diskURL))
        #expect(VirtualMac(bundle: bundle).status == .stopped)
    }

    @Test("取消设置并等待：回到「未设置」，提示「已取消」而不是「设置失败」")
    func cancelSetupAndWait() async throws {
        let bundle = try makeBundle()
        let vm = VirtualMac(bundle: bundle)
        vm.beginSetup(from: .file(root.appending(path: "missing.ipsw")))
        #expect(vm.isInstalling)
        await vm.cancelSetupAndWait()
        #expect(vm.status == .notSetUp && !vm.isInstalling)
        #expect(vm.lastError == "已取消设置")
        for file in bundle.setupArtifacts { #expect(!exists(file)) }
        await vm.cancelSetupAndWait() // 没在设置时立即返回
    }

    @Test("镜像读不出来：设置失败，回到「未设置」，不留任何虚拟硬件")
    func setupWithUnreadableImageFails() async throws {
        let bundle = try makeBundle()
        let vm = VirtualMac(bundle: bundle)
        let ipsw = root.appending(path: "broken.ipsw")
        try write("not an ipsw", to: ipsw)
        vm.beginSetup(from: .file(ipsw))
        let deadline = Date().addingTimeInterval(30)
        while vm.isInstalling, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(vm.status == .notSetUp)
        #expect(vm.lastError != nil && vm.lastError != "已取消设置")
        for file in bundle.setupArtifacts { #expect(!exists(file)) }
        #expect(VirtualMac(bundle: bundle).status == .notSetUp)
    }

    @Test("各环节的取消错误都算取消，包括安装阶段的 VZErrorOperationCancelled")
    func cancellationErrors() {
        #expect(VirtualMac.isCancellation(CancellationError()))
        #expect(VirtualMac.isCancellation(NSError(domain: VZErrorDomain, code: VZError.Code.operationCancelled.rawValue)))
        #expect(VirtualMac.isCancellation(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        #expect(VirtualMac.isCancellation(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)))
        #expect(!VirtualMac.isCancellation(NSError(domain: VZErrorDomain, code: VZError.Code.restoreImageLoadFailed.rawValue)))
        #expect(!VirtualMac.isCancellation(NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)))
    }

    @Test("设置完成的提示只在镜像是 MacBox 缓存的时候才说可以删除缓存")
    func setupCompleteNotice() throws {
        let cache = root.appending(path: "RestoreImages", directoryHint: .isDirectory)
        try AppPaths.ensure(cache)
        #expect(VirtualMac.isCachedImage(cache.appending(path: "macOS-26.0-25A1.ipsw"), cache: cache))
        #expect(!VirtualMac.isCachedImage(root.appending(path: "Downloads/macOS.ipsw"), cache: cache))
        let withCache = VirtualMac.setupCompleteNotice(imageIsCached: true)
        let withoutCache = VirtualMac.setupCompleteNotice(imageIsCached: false)
        #expect(withCache.hasPrefix(withoutCache) && withCache.count > withoutCache.count)
    }

    @Test("镜像单选列表：同一个文件只出现一次；当前选中的文件即使不在列表里也会补上")
    func installSourceOptions() throws {
        let a = root.appending(path: "RestoreImages/a.ipsw")
        let b = root.appending(path: "Downloads/b.ipsw")
        let c = root.appending(path: "Downloads/c.ipsw")
        try write("a", to: a)
        try write("b", to: b)
        let sameA = URL(fileURLWithPath: root.path + "/RestoreImages/../RestoreImages/a.ipsw")
        let options = InstallSourcePicker.options(cached: [a], extra: [sameA, a, b], selected: .latest)
        #expect(options.map(\.lastPathComponent) == ["a.ipsw", "b.ipsw"])
        #expect(Set(options.map(\.path)).count == options.count)

        let selected = InstallSourcePicker.normalized(c)
        let withSelected = InstallSourcePicker.options(cached: [a], extra: [], selected: .file(selected))
        #expect(withSelected.map(\.lastPathComponent) == ["a.ipsw", "c.ipsw"])
        #expect(withSelected.contains(selected)) // 单选的 tag 和选中值一致
        #expect(InstallSourcePicker.options(cached: [a], extra: [b], selected: .file(InstallSourcePicker.normalized(b))).count == 2)
    }

    // MARK: - 状态

    @Test("状态文字：关机但留有睡眠状态显示「睡眠中」；英文的关机状态不和「Shut Down」按钮同名")
    func displayStatus() {
        #expect(VirtualMac.displayStatus(.stopped, isAsleep: true) == "睡眠中")
        #expect(VirtualMac.displayStatus(.stopped, isAsleep: false) == VirtualMac.Status.stopped.title)
        #expect(VirtualMac.displayStatus(.running, isAsleep: true) == VirtualMac.Status.running.title)
        #expect(VirtualMac.Status.stopped.title != "关机")
    }

    @Test("操作失败后的状态：迟到的失败不改状态；当前虚拟机已停止则为已停止，绝不凭空改回「运行中」")
    func failedTransitionStatus() {
        typealias S = VirtualMac.Status
        #expect(VirtualMac.statusAfterFailedTransition(state: .stopped, isCurrent: false, previous: .running) == nil)
        #expect(VirtualMac.statusAfterFailedTransition(state: .running, isCurrent: false, previous: .running) == nil)
        #expect(VirtualMac.statusAfterFailedTransition(state: .stopped, isCurrent: true, previous: .running) == S.stopped)
        #expect(VirtualMac.statusAfterFailedTransition(state: .error, isCurrent: true, previous: .paused) == S.stopped)
        #expect(VirtualMac.statusAfterFailedTransition(state: .running, isCurrent: true, previous: .paused) == S.running)
        #expect(VirtualMac.statusAfterFailedTransition(state: .paused, isCurrent: true, previous: .running) == S.paused)
        #expect(VirtualMac.statusAfterFailedTransition(state: .saving, isCurrent: true, previous: .paused) == S.paused)
    }

    @Test("唤醒失败时只有睡眠文件本身不能用（VZErrorRestore）才丢掉它；暂时性的错误保留睡眠状态")
    func saveStateDiscardRule() {
        #expect(VirtualMac.shouldDiscardSaveState(after: NSError(domain: VZErrorDomain, code: VZError.Code.restore.rawValue)))
        #expect(!VirtualMac.shouldDiscardSaveState(after: NSError(domain: VZErrorDomain, code: VZError.Code.virtualMachineLimitExceeded.rawValue)))
        #expect(!VirtualMac.shouldDiscardSaveState(after: NSError(domain: VZErrorDomain, code: VZError.Code.internalError.rawValue)))
        #expect(!VirtualMac.shouldDiscardSaveState(after: CancellationError()))
    }

    @MainActor final class Log {
        var items: [String] = []
        func add(_ item: String) { items.append(item) }
    }

    @Test("状态转换依次执行，settle() 会等排队中的全部结束")
    func transitionsRunInOrder() async throws {
        let vm = VirtualMac(bundle: try makeBundle())
        let log = Log()
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        let first = Task {
            await vm.transition {
                log.add("1 begin")
                for await _ in gate { break }
                log.add("1 end")
            }
        }
        while !log.items.contains("1 begin") { await Task.yield() }
        let second = Task { await vm.transition { log.add("2") } }
        for _ in 0..<5 { await Task.yield() }
        let settled = Task {
            await vm.settle()
            log.add("settled")
        }
        for _ in 0..<5 { await Task.yield() }
        #expect(log.items == ["1 begin"]) // 第二个在等第一个，settle 在等它们
        open.yield()
        open.finish()
        await settled.value
        await first.value
        await second.value
        #expect(log.items == ["1 begin", "1 end", "2", "settled"])
    }

    @Test("没有虚拟机在运行时：睡眠什么也不做，退出前的准备直接通过")
    func prepareForTerminationWithoutVM() async throws {
        let vm = VirtualMac(bundle: try installedBundle())
        await vm.sleep()
        await vm.forceStop()
        #expect(vm.status == .stopped && vm.lastError == nil)
        #expect(await vm.prepareForTermination())
        await vm.settle()
    }

    // MARK: - 资源与睡眠

    @Test("睡眠中不能修改资源（唤醒会失败）；丢弃睡眠状态后可以")
    func resourcesLockedWhileAsleep() throws {
        let bundle = try installedBundle(asleep: true)
        let vm = VirtualMac(bundle: bundle)
        #expect(vm.status == .stopped && vm.isAsleep && !vm.canChangeResources)

        let before = vm.config
        vm.config.memoryGB += 2
        vm.config.networkEnabled.toggle()
        #expect(vm.config.hardware == before.hardware)
        #expect(try savedConfig(bundle)?.hardware == before.hardware)
        #expect(vm.lastError != nil)

        // 硬件以外的字段照常保存
        vm.config.osVersion = "macOS 26.1"
        #expect(try savedConfig(bundle)?.osVersion == "macOS 26.1")

        try vm.discardSleepState()
        #expect(!vm.isAsleep && vm.canChangeResources && !exists(bundle.saveStateURL))
        vm.config.memoryGB = before.memoryGB + 2
        #expect(try savedConfig(bundle)?.memoryGB == before.memoryGB + 2)
    }

    @Test("还原点连同睡眠状态一起保存和还原；还原到没有睡眠状态的还原点会去掉之后的睡眠状态")
    func restorePointWithSaveState() throws {
        let bundle = try installedBundle(asleep: true)
        let vm = VirtualMac(bundle: bundle)
        try vm.createRestorePoint()
        #expect(vm.restorePointDate != nil)

        try write("disk v2", to: bundle.diskURL)
        try vm.discardSleepState()
        try vm.restoreRestorePoint()
        #expect(read(bundle.diskURL) == "disk v1")
        #expect(read(bundle.saveStateURL) == "state 1" && vm.isAsleep)

        try vm.discardSleepState()
        try vm.createRestorePoint()
        try write("state 2", to: bundle.saveStateURL)
        vm.refreshFlags()
        #expect(vm.isAsleep)
        try vm.restoreRestorePoint()
        #expect(!exists(bundle.saveStateURL) && !vm.isAsleep)
        #expect(read(bundle.diskURL) == "disk v1")

        try vm.deleteRestorePoint()
        #expect(vm.restorePointDate == nil && !exists(bundle.restorePointURL))
    }

    @Test("旧版本中断的设置留下了虚拟硬盘：「删除虚拟 Mac」可用")
    func leftoverDiskCanBeRemoved() throws {
        let bundle = try makeBundle()
        try bundle.save(VirtualMacConfig())
        #expect(!VirtualMac(bundle: bundle).canRemove)
        try write("partial", to: bundle.diskURL)
        #expect(VirtualMac(bundle: bundle).canRemove)
    }

    @Test("只有虚拟硬盘、没有 config.json：可以移到废纸篓，回到「未设置」",
          .enabled(if: AppPaths.override != nil, "需要 MACBOX_DATA_ROOT（会用到废纸篓）"))
    func trashOrphanedDisk() throws {
        let bundle = VirtualMacBundle(url: AppPaths.root.appending(path: "VirtualMacTests-\(UUID().uuidString)", directoryHint: .isDirectory))
        try write("partial", to: bundle.diskURL)
        try write("partial", to: bundle.hardwareModelURL)
        let vm = VirtualMac(bundle: bundle)
        #expect(vm.canTrashUnreadable)

        let trashed = try #require(try vm.trashUnreadable())
        #expect(exists(trashed.appending(path: "Disk.img")) && !exists(bundle.url))
        #expect(vm.status == .notSetUp && !vm.canTrashUnreadable)
        #expect(!exists(bundle.configURL)) // 恢复默认配置时不重建刚移走的文件夹
        #expect(VirtualMac(bundle: bundle).status == .notSetUp)
        // 测试自己放进废纸篓的东西，测试自己清掉
        try FileManager.default.removeItem(at: trashed)
        #expect(!exists(trashed))
    }

    // MARK: - 传入

    @Test("放入同名项目：内容没变就跳过，变了就替换；提示说明实际做了什么；不留临时文件")
    func sendReplacesChangedAndSkipsIdentical() async throws {
        let bundle = try makeBundle()
        let vm = VirtualMac(bundle: bundle)
        let incoming = bundle.incomingURL
        let first = root.appending(path: "a/Install.dmg")
        try write("APP A v1", to: first)

        await vm.sendToGuest([first])
        #expect(read(incoming.appending(path: "Install.dmg")) == "APP A v1")
        #expect(vm.notice == VirtualMac.sendNotice(.init(added: ["Install.dmg"])))
        #expect(vm.lastError == nil && !vm.isSending)

        // 同一个文件再放一次（每次从虚拟 Mac 打开应用都会这样）：不重复复制
        await vm.sendToGuest([first])
        #expect(vm.notice == VirtualMac.sendNotice(.init(unchanged: ["Install.dmg"])))
        #expect(allItems(incoming) == ["Install.dmg"])

        // 另一个同名安装包：替换掉旧的
        let other = root.appending(path: "b/Install.dmg")
        try write("APP B", to: other)
        await vm.sendToGuest([other])
        #expect(read(incoming.appending(path: "Install.dmg")) == "APP B")
        #expect(vm.notice == VirtualMac.sendNotice(.init(replaced: ["Install.dmg"])))
        #expect(allItems(incoming) == ["Install.dmg"])

        // 大小一样、修改时间不同：也算变了
        let sameSize = root.appending(path: "c/Install.dmg")
        try write("APP C", to: sameSize)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: sameSize.path)
        await vm.sendToGuest([sameSize])
        #expect(read(incoming.appending(path: "Install.dmg")) == "APP C")

        // 把「传入」里的项目本身再放进去：不会把自己删掉
        await vm.sendToGuest([incoming.appending(path: "Install.dmg")])
        #expect(read(incoming.appending(path: "Install.dmg")) == "APP C")
        #expect(allItems(incoming) == ["Install.dmg"])
    }

    @Test("放入文件夹（.app）：没变跳过；里面的文件变了整体替换")
    func sendDirectory() async throws {
        let bundle = try makeBundle()
        let vm = VirtualMac(bundle: bundle)
        let app = root.appending(path: "src/Tool.app")
        let binary = app.appending(path: "Contents/MacOS/Tool")
        try write("v1", to: binary)
        try write("plist", to: app.appending(path: "Contents/Info.plist"))

        await vm.sendToGuest([app])
        let copied = bundle.incomingURL.appending(path: "Tool.app/Contents/MacOS/Tool")
        #expect(read(copied) == "v1")

        await vm.sendToGuest([app])
        #expect(vm.notice == VirtualMac.sendNotice(.init(unchanged: ["Tool.app"])))

        try write("v2 longer", to: binary)
        try FileManager.default.removeItem(at: app.appending(path: "Contents/Info.plist"))
        await vm.sendToGuest([app])
        #expect(read(copied) == "v2 longer")
        #expect(!exists(bundle.incomingURL.appending(path: "Tool.app/Contents/Info.plist")))
        #expect(allItems(bundle.incomingURL) == ["Tool.app"])
    }

    @Test("反复替换含只读文件夹（0555 的 Contents/MacOS）的 .app：每次都成功，不留隐藏的临时项；这样的旧临时项也清得掉")
    func sendReplacesReadOnlyDirectories() async throws {
        let bundle = try makeBundle()
        let vm = VirtualMac(bundle: bundle)
        let app = root.appending(path: "src/X.app")
        let macOS = app.appending(path: "Contents/MacOS")
        let binary = macOS.appending(path: "X")
        try write("v1", to: binary)
        #expect(chmod(macOS.path, 0o555) == 0)
        let copied = bundle.incomingURL.appending(path: "X.app/Contents/MacOS/X")

        await vm.sendToGuest([app])
        #expect(read(copied) == "v1" && mode(copied.deletingLastPathComponent()) == 0o555)
        for version in ["v2 longer", "v3 even longer"] {
            try write(version, to: binary)
            await vm.sendToGuest([app])
            #expect(vm.lastError == nil)
            #expect(vm.notice == VirtualMac.sendNotice(.init(replaced: ["X.app"])))
            #expect(read(copied) == version)
            #expect(allItems(bundle.incomingURL) == ["X.app"])
        }

        // 旧版本删不掉的临时项（里面有只读文件夹）：下次放入时清掉，也不妨碍这次放入
        let stale = bundle.incomingURL.appending(path: ".X.app\(VirtualMac.partialSuffix)/Contents/MacOS")
        try write("old", to: stale.appending(path: "X"))
        #expect(chmod(stale.path, 0o555) == 0)
        try write("v4", to: binary)
        await vm.sendToGuest([app])
        #expect(vm.lastError == nil && read(copied) == "v4")
        #expect(allItems(bundle.incomingURL) == ["X.app"])
    }

    @Test("放入失败：报告失败的项目，不留下同名项目或临时文件；上次中断留下的临时文件会被清理")
    func sendFailureLeavesNothing() async throws {
        let bundle = try makeBundle()
        let vm = VirtualMac(bundle: bundle)
        try bundle.ensureExchangeFolders()
        let stale = bundle.incomingURL.appending(path: ".Old.dmg\(VirtualMac.partialSuffix)")
        try write("half", to: stale)

        let good = root.appending(path: "ok.txt")
        try write("ok", to: good)
        let missing = root.appending(path: "missing.dmg")
        await vm.sendToGuest([missing, good])

        #expect(vm.lastError?.contains("missing.dmg") == true)
        #expect(vm.notice == VirtualMac.sendNotice(.init(added: ["ok.txt"])))
        #expect(allItems(bundle.incomingURL) == ["ok.txt"])
    }

    @Test("多次放入依次执行，结果和串行一致")
    func concurrentSendsAreSerialized() async throws {
        let bundle = try makeBundle()
        let vm = VirtualMac(bundle: bundle)
        let v1 = root.appending(path: "1/Setup.pkg"), v2 = root.appending(path: "2/Setup.pkg")
        try write("first", to: v1)
        try write("second version", to: v2)
        async let a: Void = vm.sendToGuest([v1])
        async let b: Void = vm.sendToGuest([v2])
        _ = await (a, b)
        #expect(allItems(bundle.incomingURL) == ["Setup.pkg"])
        let content = read(bundle.incomingURL.appending(path: "Setup.pkg"))
        #expect(content == "first" || content == "second version")
        #expect(!vm.isSending)
    }

    // MARK: - 传出

    @Test("「传出」递归打隔离标记：.app 里的可执行文件、脚本都标上；不跟随符号链接，不碰外面的文件")
    func outgoingQuarantineIsRecursive() throws {
        let outgoing = root.appending(path: "传出", directoryHint: .isDirectory)
        let outside = root.appending(path: "outside", directoryHint: .isDirectory)
        let key = SymmetricKey(size: .bits256)
        let binary = outgoing.appending(path: "Report.app/Contents/MacOS/Report")
        let plist = outgoing.appending(path: "Report.app/Contents/Info.plist")
        let script = outgoing.appending(path: "run.command")
        let nested = outgoing.appending(path: "folder/sub/.hidden.sh")
        for file in [binary, plist, script, nested] { try write("x", to: file) }
        let secret = outside.appending(path: "secret.txt")
        let deeper = outside.appending(path: "sub/deeper.txt")
        try write("host file", to: secret)
        try write("host file", to: deeper)
        try FileManager.default.createSymbolicLink(at: outgoing.appending(path: "link.txt"), withDestinationURL: secret)
        try FileManager.default.createSymbolicLink(at: outgoing.appending(path: "linkdir"), withDestinationURL: outside)

        #expect(OutgoingQuarantine.markTree(outgoing, root: outgoing, key: key).isEmpty)
        for item in [binary, plist, script, nested, outgoing.appending(path: "Report.app"),
                     outgoing.appending(path: "folder/sub")] {
            #expect(hasValidMark(item, key: key), "\(item.path) 没有隔离标记")
        }
        #expect(quarantine(outgoing) == nil) // 共享目录本身不标
        #expect(quarantine(secret) == nil && quarantine(outside) == nil && quarantine(deeper) == nil)

        // 路径中间一级是指向外面的符号链接（FSEvents 报来的、或者客体刚换掉的）：按路径标记会标到本机文件上，必须拒绝
        OutgoingQuarantine.markTree(outgoing.appending(path: "linkdir/secret.txt"), root: outgoing, key: key)
        OutgoingQuarantine.markTree(outgoing.appending(path: "linkdir/sub/deeper.txt"), root: outgoing, key: key)
        OutgoingQuarantine.markTree(outgoing.appending(path: "linkdir/sub"), root: outgoing, key: key)
        #expect(quarantine(secret) == nil && quarantine(deeper) == nil && quarantine(outside.appending(path: "sub")) == nil)

        // 单独标记里面的一项（监视器就是这样调用的）
        let later = outgoing.appending(path: "folder/later.command")
        try write("x", to: later)
        #expect(OutgoingQuarantine.markTree(later, root: outgoing, key: key).isEmpty)
        #expect(hasValidMark(later, key: key))
    }

    @Test("只读、读不了、锁定的项目也标上，并恢复原来的权限和标志：0555 的脚本和 .app 里的可执行文件、0311 的 .app、0111/0200 的文件、uchg")
    func outgoingQuarantineHandlesPermissions() throws {
        let outgoing = root.appending(path: "传出", directoryHint: .isDirectory)
        let key = SymmetricKey(size: .bits256)
        let normal = outgoing.appending(path: "normal.command")
        let readOnly = outgoing.appending(path: "readonly.command")
        let reportMacOS = outgoing.appending(path: "Report.app/Contents/MacOS")
        let report = reportMacOS.appending(path: "Report")
        let locked = outgoing.appending(path: "Locked.app")
        let lockedBinary = locked.appending(path: "Contents/MacOS/Locked")
        let executeOnly = outgoing.appending(path: "execute-only.command")
        let writeOnly = outgoing.appending(path: "write-only.bin")
        let immutable = outgoing.appending(path: "immutable.command")
        for file in [normal, readOnly, report, lockedBinary, executeOnly, writeOnly, immutable] {
            try write("#!/bin/sh\necho hi\n", to: file)
        }
        let modes: [(URL, mode_t)] = [
            (normal, 0o755), (readOnly, 0o555), (report, 0o555), (reportMacOS, 0o555), (lockedBinary, 0o755),
            (locked, 0o311), (executeOnly, 0o111), (writeOnly, 0o200), (immutable, 0o755),
        ]
        for (url, mode) in modes { #expect(chmod(url.path, mode) == 0) }
        #expect(chflags(immutable.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(immutable.path, 0) } // 不然删不掉

        #expect(OutgoingQuarantine.markTree(outgoing, root: outgoing, key: key).isEmpty)
        for (url, mode) in modes {
            #expect(hasValidMark(url, key: key), "\(url.lastPathComponent) 没有隔离标记")
            #expect(self.mode(url) == mode, "\(url.lastPathComponent) 的权限没有恢复")
        }
        #expect((lstatInfo(immutable)?.st_flags ?? 0) & UInt32(UF_IMMUTABLE) != 0)

        // 再检查一遍：签名对得上的原样保留，权限照样恢复
        let values = modes.map { quarantine($0.0) }
        #expect(OutgoingQuarantine.markTree(outgoing, root: outgoing, key: key).isEmpty)
        #expect(modes.map { quarantine($0.0) } == values)
        for (url, mode) in modes { #expect(self.mode(url) == mode) }
    }

    @Test("只认带本机签名的 MacBox 标记：伪造来源的、照抄别的文件的、在 MacBox 标记上加「已批准」的、别的密钥签的都重写；原样的保留")
    func outgoingQuarantineValues() throws {
        let outgoing = root.appending(path: "传出", directoryHint: .isDirectory)
        let key = SymmetricKey(size: .bits256)
        let genuine = outgoing.appending(path: "genuine.command")
        let copied = outgoing.appending(path: "copied.command")
        let approved = outgoing.appending(path: "approved.app")
        let forged = outgoing.appending(path: "forged.command")
        let safari = outgoing.appending(path: "safari.command")
        let otherKey = outgoing.appending(path: "other-key.command")
        for file in [genuine, copied, forged, safari, otherKey] { try write("x", to: file) }
        try AppPaths.ensure(approved)
        #expect(OutgoingQuarantine.markTree(outgoing, root: outgoing, key: key).isEmpty)
        let genuineValue = try #require(quarantine(genuine))
        let approvedValue = try #require(quarantine(approved))
        #expect(genuineValue.hasPrefix("0081;") && genuineValue.split(separator: ";")[2] == "MacBox")

        // 客体经 virtiofs 改写扩展属性
        setQuarantine(copied, genuineValue)
        setQuarantine(approved, "00c1" + approvedValue.dropFirst(4))
        setQuarantine(forged, "00c1;00000000;MacBox;")
        setQuarantine(safari, "00c1;00000000;Safari;")
        let otherInode = UInt64(try #require(lstatInfo(otherKey)).st_ino)
        setQuarantine(otherKey, OutgoingQuarantine.markValue(inode: otherInode, key: SymmetricKey(size: .bits256)))

        #expect(OutgoingQuarantine.markTree(outgoing, root: outgoing, key: key).isEmpty)
        #expect(quarantine(genuine) == genuineValue)
        for item in [copied, approved, forged, safari, otherKey] {
            #expect(hasValidMark(item, key: key), "\(item.lastPathComponent) 没有改成有效的标记")
            #expect(quarantine(item)?.hasPrefix("0081;") == true, "\(item.lastPathComponent)：\(quarantine(item) ?? "nil")")
        }
        #expect(quarantine(copied) != genuineValue)
    }

    @Test("打开「传出」前先给已有的内容打标记；签名密钥存在包里（只有属主能读），下次还是同一个")
    func quarantineOutgoingBeforeOpening() async throws {
        let bundle = try makeBundle()
        try bundle.ensureExchangeFolders()
        let tool = bundle.outgoingURL.appending(path: "Tool.app/Contents/MacOS/Tool")
        try write("x", to: tool)
        #expect(await VirtualMac(bundle: bundle).quarantineOutgoing().isEmpty)
        let key = try bundle.quarantineKey()
        #expect(hasValidMark(tool, key: key) && hasValidMark(bundle.outgoingURL.appending(path: "Tool.app"), key: key))
        #expect(mode(bundle.quarantineKeyURL) == 0o600)
        let again = try bundle.quarantineKey()
        #expect(key.withUnsafeBytes { Data($0) } == again.withUnsafeBytes { Data($0) })
    }

    @Test("启动时开了监视器就完整检查一遍「传出」：旧版本留下的也带上标记（这里虚拟硬件是占位文件，启动本身会失败）")
    func startQuarantinesExistingOutgoingItems() async throws {
        let bundle = try installedBundle()
        try bundle.ensureExchangeFolders()
        let left = bundle.outgoingURL.appending(path: "Left.app/Contents/MacOS/Left")
        try write("x", to: left)
        let vm = VirtualMac(bundle: bundle)
        await vm.start()
        #expect(vm.status == .stopped && vm.virtualMachine == nil && vm.lastError != nil)
        let key = try bundle.quarantineKey()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !hasValidMark(left, key: key) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(hasValidMark(left, key: key))
        #expect(hasValidMark(bundle.outgoingURL.appending(path: "Left.app"), key: key))
    }

    @Test("标不上的项目会告诉用户是哪些")
    func quarantineFailureMessage() {
        // 名字要和说明文字撞不上：以前用单个字母，英文里 “couldn’t” 的 d 就让测试失败。英文的说法见 LocalizationTests.plurals
        let one = VirtualMac.quarantineFailureMessage(["a.command"])
        let many = VirtualMac.quarantineFailureMessage(["Alpha.app", "Bravo.app", "Charlie.app", "Delta.app"])
        #expect(one.contains("a.command"))
        #expect(many.contains("4") && many.contains("Charlie.app") && !many.contains("Delta.app") && many.contains("其他几项"))
    }

    @Test("虚拟 Mac 运行期间别的进程写进「传出」的新文件随即被标记，0555 的也一样，并保持原来的权限")
    func outgoingWatcherMarksNewItems() async throws {
        let outgoing = root.appending(path: "传出", directoryHint: .isDirectory)
        try AppPaths.ensure(outgoing)
        let key = SymmetricKey(size: .bits256)
        let watcher = OutgoingQuarantine.Watcher()
        watcher.start(outgoing, key: key)
        defer { watcher.stop() }
        #expect(watcher.isRunning)
        try await Task.sleep(for: .milliseconds(300))

        let file = outgoing.appending(path: "new.command")
        let inner = outgoing.appending(path: "Dropped.app/Contents/MacOS/Dropped")
        let readOnly = outgoing.appending(path: "readonly.command")
        try runShell("""
            mkdir -p "$1/Dropped.app/Contents/MacOS" && printf x > "$1/new.command" \
              && printf x > "$1/Dropped.app/Contents/MacOS/Dropped" \
              && printf x > "$1/readonly.command" && chmod 555 "$1/readonly.command"
            """, outgoing.path)
        let items = [file, inner, readOnly]
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !items.allSatisfy({ hasValidMark($0, key: key) }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        for item in items { #expect(hasValidMark(item, key: key), "\(item.lastPathComponent) 没有隔离标记") }
        #expect(mode(readOnly) == 0o555)
        watcher.stop()
        #expect(!watcher.isRunning)
    }
}
