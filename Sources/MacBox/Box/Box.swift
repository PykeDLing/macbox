import AppKit
import Foundation
import Observation

/// 一个装进 MacBox 的应用
@Observable
final class Box: Identifiable {
    let id: UUID
    let paths: BoxPaths
    @ObservationIgnored weak var store: BoxStore?

    /// 修改后自动保存到 box.json（值没变时不写盘）
    var config: BoxConfig {
        didSet { configChanged(from: oldValue) }
    }
    private(set) var icon: NSImage
    /// 盒子当前在做什么。所有“能不能做某事”的判断都从这里推出，不再散落在多个标志里
    private(set) var activity: Activity = .idle
    private(set) var blocks: [BlockEvent] = []
    private(set) var restorePointDate: Date?
    var lastError: String?
    var notice: String?

    enum Activity: Equatable {
        case idle
        /// 准备环境、借出设置、启动中
        case launching
        /// App 在运行
        case running(IsolatedSession)
        /// App 已退出，正在收尾（收回设置、接管安装包、自动还原）
        case finishing
        /// 还原点、清除数据、完成安装等维护操作
        case maintenance

        static func == (a: Activity, b: Activity) -> Bool {
            switch (a, b) {
            case (.idle, .idle), (.launching, .launching), (.finishing, .finishing), (.maintenance, .maintenance): true
            case (.running(let x), .running(let y)): x === y
            default: false
            }
        }
    }

    /// 启动器的同步操作依次执行，后一次总是基于当时最新的配置
    @ObservationIgnored private var launcherTask: Task<Void, Never>?
    /// 盒子已删除：之后的启动器同步只做删除
    @ObservationIgnored private var retired = false
    /// 已开始接手安装器下载的安装包（避免重复的拦截记录反复触发）
    @ObservationIgnored private var handingOver = false
    /// 启动期间就收到了退出请求
    @ObservationIgnored private var quitRequested = false

    init(paths: BoxPaths, config: BoxConfig) {
        self.id = config.id
        self.paths = paths
        self.config = config
        self.icon = NSWorkspace.shared.icon(forFile: paths.app(config).path)
        refreshRestorePoint()
    }

    var session: IsolatedSession? {
        if case .running(let session) = activity { session } else { nil }
    }
    var isRunning: Bool { session != nil }
    /// 正在启动、收尾或维护，期间不接受其他操作
    var isBusy: Bool { activity == .launching || activity == .finishing || activity == .maintenance }
    /// 运行生命周期尚未结束（含启动和收尾）；退出 MacBox 前要等它们结束
    var isLive: Bool { activity == .launching || isRunning || activity == .finishing }
    var appURL: URL { paths.app(config) }
    var worstIssue: CompatibilityIssue.Severity? { config.issues.map(\.severity).max() }

    // MARK: - 打开 / 退出

    /// 打开应用；本机隔离时 App 启动后即返回，生命周期在后台继续
    func open() async {
        // 上次异常退出的收尾（收回设置等）完成后才能启动
        await store?.ready()
        lastError = nil
        switch config.runtime {
        case .isolated: startIsolated()
        case .virtualMac: await store?.openInVirtualMac(self)
        }
    }

    func quit() {
        if let session { session.terminate() } else if activity == .launching { quitRequested = true }
    }

    private func startIsolated() {
        if let session {
            session.activate()
            return
        }
        guard activity == .idle else { return }
        activity = .launching
        blocks.removeAll()
        handingOver = false
        quitRequested = false
        Task { await runIsolated() }
    }

    /// 一次完整的运行：启动 → 运行 → 收尾。状态只在这里推进
    private func runIsolated() async {
        let outcome: IsolatedSession.Outcome
        do {
            outcome = try await IsolatedSession.run(paths: paths, config: config, onStart: { [weak self] session in
                guard let self else { return }
                activity = .running(session)
                if quitRequested { session.terminate() }
            }, onBlock: { [weak self] event in
                self?.record(event)
            })
        } catch {
            activity = .idle
            lastError = L("启动失败：\(error.localizedDescription)", "Couldn’t open the app: \(error.localizedDescription)")
            return
        }
        activity = .finishing
        await finish(outcome)
        if activity == .finishing { activity = .idle }
    }

    func record(_ event: BlockEvent) {
        // 安装器下载完了、正尝试挂载安装包：不必等它报错，直接结束它，由 MacBox 完成安装
        if event.kind == .diskMount, config.isInstaller, let session, !handingOver {
            handingOver = true
            Task {
                guard !(await session.downloadedPackages()).isEmpty else {
                    handingOver = false
                    return
                }
                notice = L("安装包已下载完成，MacBox 正在接手安装…",
                           "The installer package has finished downloading. MacBox is taking over the installation…")
                try? await Task.sleep(for: .seconds(1))
                session.terminate()
            }
        }
        if let index = blocks.firstIndex(where: { $0.id == event.id }) {
            blocks[index].count += 1
            blocks[index].lastSeen = event.lastSeen
        } else {
            blocks.insert(event, at: 0)
        }
    }

    /// App 已退出、系统资源已归还之后的处理
    private func finish(_ outcome: IsolatedSession.Outcome) async {
        // MacBox 正在退出：只做必要的收尾，不再接手安装、不再弹建议
        let terminating = store?.isTerminating == true
        if config.isInstaller, let package = outcome.downloadedPackages.first, !terminating {
            await adoptDownloadedPackage(package)
            return
        }
        if config.resetOnQuit, restorePointDate != nil {
            do {
                try await rollBack()
                notice = L("已按设置还原到还原点，本次运行的改动已清除。",
                           "Restored to the restore point as set. Changes from this session were discarded.")
            } catch {
                lastError = L("自动还原失败：\(error.localizedDescription)", "Automatic restore failed: \(error.localizedDescription)")
            }
        }
        guard !terminating else { return }
        let severe = blocks.filter(\.kind.suggestsVirtualMac)
        if !severe.isEmpty {
            store?.suggestVirtualMac(for: self, reasons: severe.map {
                L("\($0.kind.title)：\($0.target)", "\($0.kind.title): \($0.target)")
            })
        }
    }

    /// 在线安装器下载完整安装包后，由 MacBox 取出真正的 App 替换安装器，然后直接打开
    private func adoptDownloadedPackage(_ package: URL) async {
        activity = .maintenance
        notice = L("安装器已下载「\(package.lastPathComponent)」，正在完成安装…",
                   "The installer downloaded “\(package.lastPathComponent)”. Finishing the installation…")
        do {
            let paths = paths
            let staging = paths.url.appending(path: "App.new", directoryHint: .isDirectory)
            try await Background.run { try FileOps.removeIfExists(staging) }
            let extracted = try await PackageExtractor.extractApp(from: package, into: staging)
            let info = try AppInspector.info(of: extracted.app)
            var issues = extracted.issues
            issues += await AppInspector.scan(extracted.app)
            issues.insert(await AppInspector.verifyAndTrust(extracted.app), at: 0)

            try await Background.run {
                // 先换下旧的，新的就位后再删除，任何一步失败都不会让盒子里没有 App
                let old = paths.url.appending(path: "App.old", directoryHint: .isDirectory)
                try FileOps.removeIfExists(old)
                try FileManager.default.moveItem(at: paths.appDirectory, to: old)
                do {
                    try FileManager.default.moveItem(at: staging, to: paths.appDirectory)
                } catch {
                    try? FileManager.default.moveItem(at: old, to: paths.appDirectory)
                    throw error
                }
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.removeItem(at: package) // 安装包已用完，不再占空间
            }

            var updated = config
            updated.name = info.name
            updated.bundleIdentifier = info.bundleIdentifier
            updated.version = info.version
            updated.appFolderName = extracted.app.lastPathComponent
            updated.isInstaller = false
            updated.issues = issues
            let prefix = AppInspector.preferencePrefix(for: info.bundleIdentifier)
            if !updated.preferencePrefixes.contains(prefix) { updated.preferencePrefixes.append(prefix) }
            config = updated // 名称、安装器标记变化会自动重建启动器
            icon = NSWorkspace.shared.icon(forFile: appURL.path)
            // 安装器尝试写入「应用程序」被拦截是预期内的，安装已由 MacBox 完成
            blocks.removeAll { [.systemInstall, .escapedLaunch, .diskMount].contains($0.kind) }
            notice = L("「\(info.name)」已安装到 MacBox。", "“\(info.name)” was installed in MacBox.")
            activity = .idle
            await open()
        } catch {
            activity = .idle
            lastError = L("完成安装失败：\(error.localizedDescription)", "Couldn’t finish the installation: \(error.localizedDescription)")
        }
    }

    // MARK: - 还原点与数据

    func createRestorePoint() async throws {
        try beginMaintenance()
        defer { activity = .idle }
        let paths = paths
        try await Background.run {
            let temp = paths.url.appending(path: "RestorePoint.tmp", directoryHint: .isDirectory)
            try FileOps.removeIfExists(temp)
            try AppPaths.ensure(temp)
            for item in paths.restorableItems {
                let source = paths.url.appending(path: item)
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileOps.clone(source, to: temp.appending(path: item))
                }
            }
            try FileOps.removeIfExists(paths.restorePoint)
            try FileManager.default.moveItem(at: temp, to: paths.restorePoint)
        }
        refreshRestorePoint()
    }

    func restoreRestorePoint() async throws {
        guard restorePointDate != nil else { throw MacBoxError(L("还没有还原点", "There’s no restore point yet")) }
        try beginMaintenance()
        defer { activity = .idle }
        try await rollBack()
    }

    func deleteRestorePoint() async throws {
        let restorePoint = paths.restorePoint
        try await Background.run { try FileOps.removeIfExists(restorePoint) }
        config.resetOnQuit = false
        refreshRestorePoint()
    }

    /// 清除应用数据：主目录、设置、钥匙串全部重置，相当于刚安装
    func clearData() async throws {
        try beginMaintenance()
        defer { activity = .idle }
        let paths = paths
        try await Background.run {
            try FileOps.removeIfExists(paths.home)
            try FileOps.removeIfExists(paths.prefs)
            try FileOps.removeIfExists(paths.keychainPassword)
            try FileOps.removeIfExists(paths.tmp)
        }
    }

    /// 应用数据占用的空间（要遍历整个主目录，在后台计算）
    func measureDataSize() async -> Int64 {
        let paths = paths
        return await Background.run {
            FileOps.allocatedSize(of: paths.home) + FileOps.allocatedSize(of: paths.prefs)
        }
    }

    private func beginMaintenance() throws {
        guard !isRunning else { throw MacBoxError(L("请先退出应用", "Quit the app first")) }
        guard activity == .idle else { throw MacBoxError(L("「\(config.name)」正在处理其他操作，请稍候",
                                                            "“\(config.name)” is busy with another operation. Try again in a moment.")) }
        activity = .maintenance
    }

    /// 用还原点替换当前数据（调用方负责确认应用未在运行）
    private func rollBack() async throws {
        let paths = paths
        try await Background.run {
            for item in paths.restorableItems {
                let target = paths.url.appending(path: item)
                try FileOps.removeIfExists(target)
                let source = paths.restorePoint.appending(path: item)
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileOps.clone(source, to: target)
                }
            }
        }
    }

    private func refreshRestorePoint() {
        restorePointDate = FileManager.default.fileExists(atPath: paths.restorePoint.path)
            ? FileOps.creationDate(of: paths.restorePoint) : nil
    }

    // MARK: - 配置

    private func configChanged(from old: BoxConfig) {
        guard config != old, !retired else { return }
        do {
            try paths.save(config)
        } catch {
            lastError = L("无法保存设置：\(error.localizedDescription)", "Couldn’t save settings: \(error.localizedDescription)")
        }
        if old.name != config.name || old.showInLaunchpad != config.showInLaunchpad
            || old.isInstaller != config.isInstaller || old.appFolderName != config.appFolderName {
            syncLauncher()
        }
    }

    /// 按当前配置创建、更新或删除聚焦里的启动器。返回的任务可用于等待完成
    @discardableResult
    func syncLauncher() -> Task<Void, Never> {
        let previous = launcherTask
        let task = Task {
            await previous?.value
            let config = self.config
            if retired || !config.showInLaunchpad || config.isInstaller {
                await Launcher.shared.remove(boxID: id)
                return
            }
            do {
                try await Launcher.shared.install(paths: paths, config: config)
            } catch {
                lastError = L("无法创建启动器：\(error.localizedDescription)", "Couldn’t create the launcher: \(error.localizedDescription)")
            }
        }
        launcherTask = task
        return task
    }

    /// 盒子被删除：之后不再写盘，并删除它的启动器
    func retire() {
        retired = true
        syncLauncher()
    }
}
