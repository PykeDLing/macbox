import AppKit
import Foundation
import Observation
import Virtualization

enum InstallSource: Hashable {
    case latest
    case file(URL)
}

/// 虚拟 Mac：本机隔离容纳不了的应用的去处。全部这类应用共用一台，按需设置，不默认安装。
@Observable
final class VirtualMac: NSObject {
    static let shared = VirtualMac(bundle: .shared)

    enum Status: Equatable {
        case notSetUp, installing, stopped, starting, running, paused, saving, stopping
        /// config.json 存在却读不出来：保持原样，不允许任何会改动虚拟 Mac 的操作
        case unreadable(String)
        var title: String {
            switch self {
            case .notSetUp: L("未设置", "Not Set Up")
            case .installing: L("正在设置", "Setting Up")
            case .stopped: L("已关机", "Shut Down")
            case .starting: L("正在启动", "Starting")
            case .running: L("运行中", "Running")
            case .paused: L("已暂停", "Paused")
            case .saving: L("正在进入睡眠", "Going to Sleep")
            case .stopping: L("正在关机", "Shutting Down")
            case .unreadable: L("无法读取", "Unreadable")
            }
        }
    }

    let bundle: VirtualMacBundle
    /// 修改后自动保存到 config.json（值没变、配置读不出来或刚删除虚拟 Mac 时不写盘）
    var config: VirtualMacConfig {
        didSet { configChanged(from: oldValue) }
    }
    private(set) var status: Status
    private(set) var virtualMachine: VZVirtualMachine?
    private(set) var installPhase = ""
    private(set) var installProgress: Double?
    var lastError: String?
    var notice: String?
    private(set) var isAsleep = false
    private(set) var restorePointDate: Date?
    private(set) var outgoingItems: [URL] = []

    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var persistsConfig = true

    /// 只读取 config.json，不写任何东西
    private init(bundle: VirtualMacBundle) {
        self.bundle = bundle
        do {
            let config = try bundle.loadConfig()
            self.config = config ?? VirtualMacConfig()
            self.status = config?.installed == true ? .stopped : .notSetUp
        } catch {
            self.config = VirtualMacConfig()
            self.status = .unreadable(error.localizedDescription)
        }
        super.init()
        refreshFlags()
    }

    var isActive: Bool { virtualMachine != nil || status == .starting }

    private var isUnreadable: Bool {
        if case .unreadable = status { return true }
        return false
    }

    private func configChanged(from old: VirtualMacConfig) {
        guard config != old, persistsConfig, !isUnreadable else { return }
        do {
            try bundle.save(config)
        } catch {
            lastError = L("无法保存虚拟 Mac 设置：\(error.localizedDescription)",
                          "Couldn’t save Virtual Mac settings: \(error.localizedDescription)")
        }
    }

    // MARK: - 设置（下载并安装 macOS）

    func beginSetup(from source: InstallSource) {
        guard status == .notSetUp else { return }
        lastError = nil
        status = .installing
        installTask = Task { await performSetup(source) }
    }

    func cancelSetup() {
        installTask?.cancel()
    }

    private func performSetup(_ source: InstallSource) async {
        defer {
            installTask = nil
            installProgress = nil
        }
        do {
            let ipsw: URL
            switch source {
            case .file(let url):
                ipsw = url
            case .latest:
                ipsw = try await RestoreImageStore.obtainLatest { phase, progress in
                    installPhase = phase
                    installProgress = progress
                }
            }
            try Task.checkCancellation()

            installPhase = L("正在读取系统镜像…", "Reading restore image…")
            installProgress = nil
            let image = try await RestoreImageStore.load(ipsw)
            guard let requirements = image.mostFeaturefulSupportedConfiguration,
                  requirements.hardwareModel.isSupported else {
                throw MacBoxError(L("这台 Mac 不支持该 macOS 镜像（\(image.buildVersion)），请换一个版本。",
                                    "This Mac doesn’t support this macOS image (\(image.buildVersion)). Choose a different version."))
            }
            config.cpuCount = max(config.cpuCount, requirements.minimumSupportedCPUCount)
            config.memoryGB = max(config.memoryGB, Int((requirements.minimumSupportedMemorySize + (1 << 30) - 1) >> 30))

            installPhase = L("正在创建虚拟硬件…", "Creating virtual hardware…")
            try bundle.createPlatformFiles(hardwareModel: requirements.hardwareModel)
            try bundle.createDisk(sizeGB: config.diskGB)
            try bundle.ensureExchangeFolders()
            try Task.checkCancellation()

            let vm = VZVirtualMachine(configuration: try VMConfigurationFactory.make(bundle: bundle, config: config))
            let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)
            let version = image.operatingSystemVersion.displayString
            installPhase = L("正在安装 macOS \(version)…", "Installing macOS \(version)…")
            try await install(installer)

            config.osVersion = "macOS \(version) (\(image.buildVersion))"
            config.installed = true
            status = .stopped
            notice = L("设置完成。首次启动请走完 macOS 设置向导（可以不登录 Apple 账户），然后关机并创建还原点。安装镜像缓存已不再需要，可以在下方删除。",
                       "Setup complete. On first startup, go through the macOS Setup Assistant (signing in with an Apple Account is optional), then shut down and create a restore point. The cached restore image is no longer needed and can be deleted below.")
        } catch {
            status = .notSetUp
            lastError = Self.isCancellation(error)
                ? L("已取消设置", "Setup canceled")
                : L("设置失败：\(error.localizedDescription)", "Setup failed: \(error.localizedDescription)")
        }
    }

    /// 运行安装器并跟踪进度；任务取消时取消安装。进度更新全部在返回前处理完
    private func install(_ installer: VZMacOSInstaller) async throws {
        let progress = installer.progress
        let (updates, continuation) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
        let observation = progress.observe(\.fractionCompleted, options: [.initial, .new]) { @Sendable progress, _ in
            continuation.yield(progress.fractionCompleted)
        }
        let reporter = Task {
            for await value in updates { installProgress = value }
        }
        defer {
            observation.invalidate()
            continuation.finish()
        }
        do {
            try await withTaskCancellationHandler {
                try await installer.install()
            } onCancel: {
                progress.cancel()
            }
        } catch {
            continuation.finish()
            await reporter.value
            throw error
        }
        continuation.finish()
        await reporter.value
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        return (ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled)
            || (ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError)
    }

    // MARK: - 运行控制

    func start() async {
        guard status == .stopped else { return }
        lastError = nil
        status = .starting
        do {
            try bundle.ensureExchangeFolders()
            if isAsleep, try await wakeFromSavedState() { return }
            let vm = try makeVirtualMachine()
            virtualMachine = vm
            try await vm.start()
            status = .running
        } catch {
            virtualMachine = nil
            status = .stopped
            lastError = L("启动失败：\(error.localizedDescription)", "Couldn’t start: \(error.localizedDescription)")
        }
    }

    private func wakeFromSavedState() async throws -> Bool {
        let vm = try makeVirtualMachine()
        do {
            try await vm.restoreMachineStateFrom(url: bundle.saveStateURL)
            try? FileOps.removeIfExists(bundle.saveStateURL)
            refreshFlags()
            virtualMachine = vm
            try await vm.resume()
            status = .running
            return true
        } catch {
            try? FileOps.removeIfExists(bundle.saveStateURL)
            refreshFlags()
            virtualMachine = nil
            notice = L("无法从睡眠中唤醒（\(error.localizedDescription)），已改为正常开机。",
                       "Couldn’t wake from sleep (\(error.localizedDescription)). Starting up normally instead.")
            return false
        }
    }

    private func makeVirtualMachine() throws -> VZVirtualMachine {
        let vm = VZVirtualMachine(configuration: try VMConfigurationFactory.make(bundle: bundle, config: config))
        vm.delegate = self
        return vm
    }

    /// 让虚拟 Mac 里的系统正常关机
    func requestShutdown() {
        guard let vm = virtualMachine, vm.canRequestStop else { return }
        do {
            try vm.requestStop()
        } catch {
            lastError = L("关机请求失败：\(error.localizedDescription)", "Shutdown request failed: \(error.localizedDescription)")
        }
    }

    func forceStop() async {
        guard let vm = virtualMachine else { return }
        let previous = status
        status = .stopping
        do {
            try await vm.stop()
            didStop(vm)
        } catch {
            // 没停下来：保留虚拟机，恢复原来的状态
            lastError = L("强制关机失败：\(error.localizedDescription)", "Force shutdown failed: \(error.localizedDescription)")
            status = Self.status(of: vm) ?? previous
        }
    }

    func togglePause() async {
        guard let vm = virtualMachine else { return }
        do {
            if status == .running {
                try await vm.pause()
                status = .paused
            } else if status == .paused {
                try await vm.resume()
                status = .running
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 睡眠：保存运行状态后关闭，下次几秒内恢复原样
    func sleep() async {
        guard let vm = virtualMachine, status == .running || status == .paused else { return }
        status = .saving
        do {
            if vm.state == .running { try await vm.pause() }
            try await vm.saveMachineStateTo(url: bundle.saveStateURL)
            try await vm.stop()
            didStop(vm)
        } catch {
            try? FileOps.removeIfExists(bundle.saveStateURL)
            lastError = L("进入睡眠失败：\(error.localizedDescription)", "Couldn’t go to sleep: \(error.localizedDescription)")
            if vm.state == .paused { try? await vm.resume() }
            status = Self.status(of: vm) ?? .running
        }
    }

    private static func status(of vm: VZVirtualMachine) -> Status? {
        switch vm.state {
        case .running: .running
        case .paused: .paused
        case .stopped, .error: nil
        default: nil
        }
    }

    /// 只处理当前这台虚拟机的停止（旧实例迟到的回调忽略）
    private func didStop(_ vm: VZVirtualMachine) {
        guard vm === virtualMachine else { return }
        virtualMachine = nil
        status = .stopped
        refreshFlags()
    }

    // MARK: - 还原点

    func createRestorePoint() throws {
        guard status == .stopped else { throw MacBoxError(L("请先关闭虚拟 Mac", "Shut down the Virtual Mac first")) }
        let temp = bundle.url.appending(path: "RestorePoint.tmp", directoryHint: .isDirectory)
        try FileOps.removeIfExists(temp)
        try AppPaths.ensure(temp)
        for file in bundle.restorableFiles where FileManager.default.fileExists(atPath: file.path) {
            try FileOps.clone(file, to: temp.appending(path: file.lastPathComponent))
        }
        try FileOps.removeIfExists(bundle.restorePointURL)
        try FileManager.default.moveItem(at: temp, to: bundle.restorePointURL)
        refreshFlags()
    }

    func restoreRestorePoint() throws {
        guard status == .stopped else { throw MacBoxError(L("请先关闭虚拟 Mac", "Shut down the Virtual Mac first")) }
        guard restorePointDate != nil else { throw MacBoxError(L("还没有还原点", "There’s no restore point yet")) }
        for file in bundle.restorableFiles {
            try FileOps.removeIfExists(file)
            let source = bundle.restorePointURL.appending(path: file.lastPathComponent)
            if FileManager.default.fileExists(atPath: source.path) { try FileOps.clone(source, to: file) }
        }
        refreshFlags()
    }

    func deleteRestorePoint() throws {
        guard !isUnreadable else { throw MacBoxError(L("虚拟 Mac 的配置无法读取，暂不能修改",
                                                       "The Virtual Mac’s configuration can’t be read, so it can’t be changed right now")) }
        try FileOps.removeIfExists(bundle.restorePointURL)
        refreshFlags()
    }

    /// 删除整台虚拟 Mac（移到废纸篓）
    func remove() throws {
        guard !isUnreadable else { throw MacBoxError(L("虚拟 Mac 的配置无法读取，请在访达中检查后手动处理",
                                                       "The Virtual Mac’s configuration can’t be read. Check it in Finder and resolve it manually")) }
        guard !isActive, status != .installing else { throw MacBoxError(L("请先关闭虚拟 Mac", "Shut down the Virtual Mac first")) }
        if FileManager.default.fileExists(atPath: bundle.url.path) {
            try FileManager.default.trashItem(at: bundle.url, resultingItemURL: nil)
        }
        // 恢复默认配置，但不写盘：否则会立刻重建刚移走的文件夹
        persistsConfig = false
        config = VirtualMacConfig()
        persistsConfig = true
        status = .notSetUp
        refreshFlags()
    }

    // MARK: - 文件交换

    /// 把文件放进「传入」，在虚拟 Mac 里打开 My Shared Files › 传入 即可安装
    func sendToGuest(_ urls: [URL]) {
        do {
            try bundle.ensureExchangeFolders()
            for url in urls {
                let existing = bundle.incomingURL.appending(path: url.lastPathComponent)
                if FileManager.default.fileExists(atPath: existing.path) { continue }
                try FileOps.clone(url, to: existing)
            }
            notice = L("已放入虚拟 Mac：在虚拟 Mac 的访达中打开 位置 › My Shared Files › 传入，即可安装。",
                       "Added to the Virtual Mac. To install, open Locations › My Shared Files › 传入 in the Virtual Mac’s Finder.")
        } catch {
            lastError = L("放入虚拟 Mac 失败：\(error.localizedDescription)", "Couldn’t add to the Virtual Mac: \(error.localizedDescription)")
        }
    }

    /// 把「传出」里的文件复制到本机「下载」并加隔离标记
    func exportToDownloads(_ url: URL) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let destination = FileOps.uniqueURL(in: downloads, name: url.lastPathComponent)
        do {
            try FileOps.clone(url, to: destination)
            FileOps.markQuarantined(destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            lastError = L("导出失败：\(error.localizedDescription)", "Export failed: \(error.localizedDescription)")
        }
    }

    func refreshFlags() {
        let fm = FileManager.default
        isAsleep = fm.fileExists(atPath: bundle.saveStateURL.path)
        let snapshotDisk = bundle.restorePointURL.appending(path: bundle.diskURL.lastPathComponent)
        restorePointDate = fm.fileExists(atPath: snapshotDisk.path) ? FileOps.creationDate(of: bundle.restorePointURL) : nil
        let outgoing = FileOps.contents(of: bundle.outgoingURL)
        if outgoing != outgoingItems { outgoingItems = outgoing }
    }

    // MARK: - 空间

    struct StorageItem: Identifiable {
        let id: String
        let title: String
        let bytes: Int64
    }

    func storageBreakdown() -> [StorageItem] {
        [
            StorageItem(id: "disk", title: L("系统和应用（虚拟硬盘）", "System and Apps (Virtual Disk)"),
                        bytes: FileOps.allocatedSize(of: bundle.diskURL)),
            StorageItem(id: "sleep", title: L("睡眠状态", "Sleep State"), bytes: FileOps.allocatedSize(of: bundle.saveStateURL)),
            StorageItem(id: "restore", title: L("还原点（与硬盘共享未改动的数据）", "Restore Point (shares unchanged data with the disk)"),
                        bytes: FileOps.allocatedSize(of: bundle.restorePointURL)),
            StorageItem(id: "ipsw", title: L("macOS 安装镜像缓存", "Cached macOS Restore Image"),
                        bytes: FileOps.allocatedSize(of: AppPaths.restoreImages)),
        ].filter { $0.bytes > 0 }
    }

    /// 安装镜像只在设置时用一次，随时可以重新下载，所以直接删除（界面上会先确认）
    func deleteInstallerCache() throws {
        try FileOps.removeIfExists(AppPaths.restoreImages)
    }
}

/// 虚拟机的回调在主线程送达（虚拟机建在主队列上）
extension VirtualMac: VZVirtualMachineDelegate {
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        didStop(virtualMachine)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        guard virtualMachine === self.virtualMachine else { return }
        lastError = L("虚拟 Mac 异常停止：\(error.localizedDescription)", "The Virtual Mac stopped unexpectedly: \(error.localizedDescription)")
        didStop(virtualMachine)
    }
}
