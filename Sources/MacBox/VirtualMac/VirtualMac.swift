import AppKit
import CryptoKit
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
        /// config.json 读不出来，或者只剩虚拟硬盘、没有 config.json：保持原样，不允许任何会改动虚拟 Mac 的操作
        case unreadable(String)
        var title: String {
            switch self {
            case .notSetUp: String(localized: "未设置")
            case .installing: String(localized: "正在设置")
            // 英文不用 “Shut Down”：和「关机」按钮同名，作为状态读起来像一条命令
            case .stopped: String(localized: "已关机")
            case .starting: String(localized: "正在启动")
            case .running: String(localized: "运行中")
            case .paused: String(localized: "已暂停")
            case .saving: String(localized: "正在进入睡眠")
            case .stopping: String(localized: "正在关机")
            case .unreadable: String(localized: "无法读取")
            }
        }
    }

    let bundle: VirtualMacBundle
    /// 修改后自动保存到 config.json（值没变、配置读不出来或刚删除虚拟 Mac 时不写盘）。
    /// 虚拟硬件（CPU、内存、网络、声音等）只在 canChangeResources 时能改，其余时候保持原值。
    /// 写成计算属性而不是 didSet：在 @Observable 属性的 didSet 里给自己赋值会无限递归
    var config: VirtualMacConfig {
        get { storedConfig }
        set { setConfig(newValue) }
    }
    private var storedConfig: VirtualMacConfig
    private(set) var status: Status
    private(set) var virtualMachine: VZVirtualMachine?
    private(set) var installPhase = ""
    private(set) var installProgress: Double?
    var lastError: String?
    var notice: String?
    private(set) var isAsleep = false
    private(set) var restorePointDate: Date?
    /// 正在复制或排队等待复制到「传入」的批次数
    private(set) var pendingSends = 0

    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var persistsConfig = true
    /// 最后一个排队的状态转换（启动、睡眠、暂停/继续、强制关机），见 transition(_:)
    @ObservationIgnored private var transitionTask: Task<Void, Never>?
    /// 最后一批排队的「放入」，见 sendToGuest(_:)
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private let outgoingWatcher = OutgoingQuarantine.Watcher()
    /// QuarantineKey 读不出来、也存不下时用的一次性密钥：只是下次启动 MacBox 时会把标记重写一遍
    @ObservationIgnored private let fallbackQuarantineKey = SymmetricKey(size: .bits256)

    /// 只读取 config.json，不写任何东西。测试可以传入临时目录里的 bundle
    init(bundle: VirtualMacBundle) {
        self.bundle = bundle
        do {
            let config = try bundle.loadConfig()
            self.storedConfig = config ?? VirtualMacConfig()
            self.status = config?.installed == true ? .stopped : .notSetUp
        } catch {
            self.storedConfig = VirtualMacConfig()
            self.status = .unreadable(error.localizedDescription)
        }
        super.init()
        refreshFlags()
    }

    var isActive: Bool { virtualMachine != nil || status == .starting }
    var isInstalling: Bool { status == .installing }
    var isSending: Bool { pendingSends > 0 }

    private var isUnreadable: Bool {
        if case .unreadable = status { return true }
        return false
    }

    /// 界面上显示的状态：关机但留有睡眠状态时显示「睡眠中」，页面、窗口标题和侧边栏保持一致
    var displayStatus: String { Self.displayStatus(status, isAsleep: isAsleep) }

    static func displayStatus(_ status: Status, isAsleep: Bool) -> String {
        status == .stopped && isAsleep ? String(localized: "睡眠中") : status.title
    }

    /// 能不能修改虚拟硬件。运行中（含启动、暂停、进入睡眠、关机途中）不行：改动要下次开机才生效，
    /// 中途睡眠时保存的却是旧硬件的状态。睡眠中也不行：睡眠状态只能用保存时的硬件唤醒，改了必然唤醒失败，
    /// 里面没保存的内容就丢了。设置过程中由设置流程自己按镜像的要求调整
    var canChangeResources: Bool {
        switch status {
        case .notSetUp, .installing, .unreadable: true
        case .stopped: !isAsleep
        case .starting, .running, .paused, .saving, .stopping: false
        }
    }

    private func setConfig(_ newValue: VirtualMacConfig) {
        let old = storedConfig
        var new = newValue
        if new.hardware != old.hardware, !canChangeResources {
            // 界面上这时资源设置是禁用的；这里兜底，别的调用方也绕不过去
            new.hardware = old.hardware
            lastError = isAsleep && status == .stopped
                ? String(localized: "虚拟 Mac 正在睡眠，不能修改资源。请先唤醒再关机，或者丢弃睡眠状态。")
                : String(localized: "修改资源需要先关闭虚拟 Mac。")
        }
        guard new != old else { return }
        storedConfig = new
        configChanged(from: old)
    }

    private func configChanged(from old: VirtualMacConfig) {
        guard config != old, persistsConfig, !isUnreadable else { return }
        do {
            try bundle.save(config)
        } catch {
            lastError = String(localized: "无法保存虚拟 Mac 设置：\(error.localizedDescription)")
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

    /// 取消设置，并等它收尾完（删掉已经创建的虚拟硬件）。退出 MacBox 前调用；没在设置时立即返回
    func cancelSetupAndWait() async {
        guard let task = installTask else { return }
        task.cancel()
        await task.value
    }

    private func performSetup(_ source: InstallSource) async {
        // 整个设置要 20–40 分钟，用户多半会走开：期间不让系统闲置睡眠，也不让 App Nap 拖慢下载
        // （下载断了只能从头再来，安装器虚拟机睡过去也会失败）
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: "Setting up the Virtual Mac")
        defer {
            ProcessInfo.processInfo.endActivity(activity)
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

            installPhase = String(localized: "正在读取系统镜像…")
            installProgress = nil
            let image = try await RestoreImageStore.load(ipsw)
            guard let requirements = image.mostFeaturefulSupportedConfiguration,
                  requirements.hardwareModel.isSupported else {
                throw MacBoxError(String(localized: "这台 Mac 不支持该 macOS 镜像（\(image.buildVersion)），请换一个版本。"))
            }
            config.cpuCount = max(config.cpuCount, requirements.minimumSupportedCPUCount)
            config.memoryGB = max(config.memoryGB, Int((requirements.minimumSupportedMemorySize + (1 << 30) - 1) >> 30))

            let version = image.operatingSystemVersion.displayString
            try await buildMachine {
                installPhase = String(localized: "正在创建虚拟硬件…")
                try bundle.createPlatformFiles(hardwareModel: requirements.hardwareModel)
                try bundle.createDisk(sizeGB: config.diskGB)
                try bundle.ensureExchangeFolders()
                try Task.checkCancellation()

                let vm = VZVirtualMachine(configuration: try VMConfigurationFactory.make(bundle: bundle, config: config))
                let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)
                installPhase = String(localized: "正在安装 macOS \(version)…")
                // 检查取消和开始安装之间不能有 await：安装开始前就取消它的进度，框架会抛出异常
                try await install(installer)
                // 放在 buildMachine 里：最后这次写盘失败也算设置失败，装好的虚拟硬件随之删掉。之后不能再有会抛错的步骤
                try completeSetup(osVersion: "macOS \(version) (\(image.buildVersion))")
            }
            notice = Self.setupCompleteNotice(imageIsCached: source == .latest || Self.isCachedImage(ipsw))
        } catch {
            status = .notSetUp
            // 取消时各阶段报的错不一样（下载是 NSURLErrorCancelled，安装是 VZErrorOperationCancelled，
            // 之后读镜像还可能报别的）：任务本身已经取消，就一律当作取消
            lastError = Task.isCancelled || Self.isCancellation(error)
                ? String(localized: "已取消设置")
                : String(localized: "设置失败：\(error.localizedDescription)")
        }
    }

    /// 创建虚拟硬件并安装。动手之前先把 config.json（installed 仍为 false）写盘：之后无论中途失败、取消、
    /// 退出还是崩溃，下次读到的都是「未设置」，而不是「有虚拟硬盘却没有配置」的无法读取状态，
    /// 下次设置会直接覆盖留下的文件。失败或取消时删掉已创建的虚拟硬件（可能有几十 GB），
    /// config.json（用户选的资源）和交换文件夹保留
    func buildMachine(_ build: () async throws -> Void) async throws {
        try bundle.save(config)
        do {
            try await build()
        } catch {
            bundle.removeSetupArtifacts()
            throw error
        }
    }

    /// 设置的最后一步：先把 installed = true 的配置写盘，写成了才在内存里改成「已关机」。
    /// 反过来的话写盘失败（装完 30 GB 后磁盘满了很常见）只会在界面上报个错，这次看着已经装好，
    /// 重开 MacBox 却读成「未设置」，用户再点「开始设置」就会把可能已经用过的虚拟硬盘覆盖掉
    func completeSetup(osVersion: String) throws {
        var done = config
        done.osVersion = osVersion
        done.installed = true
        try bundle.save(done)
        persistsConfig = false
        config = done
        persistsConfig = true
        status = .stopped
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

    /// 用户取消时各个环节报的错误
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        return (ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled)
            || (ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError)
            || (ns.domain == VZErrorDomain && ns.code == VZError.Code.operationCancelled.rawValue)
    }

    /// 镜像是否在 MacBox 的缓存里：只有那里的才能在「占用空间」里删除
    static func isCachedImage(_ ipsw: URL, cache: URL = AppPaths.restoreImages) -> Bool {
        ipsw.deletingLastPathComponent().resolvingSymlinksInPath().path == cache.resolvingSymlinksInPath().path
    }

    static func setupCompleteNotice(imageIsCached: Bool) -> String {
        let done = String(localized: "设置完成。首次启动请走完 macOS 设置向导（可以不登录 Apple 账户），然后关机并创建还原点。")
        guard imageIsCached else { return done }
        return done + String(localized: "安装镜像缓存已不再需要，可以在下方「占用空间」里删除。")
    }

    // MARK: - 运行控制

    /// 启动、睡眠、暂停/继续、强制关机都是状态转换，依次执行：后一个总在前一个结束之后，按那时的状态决定做不做。
    /// 例如正在进入睡眠时退出 MacBox，退出流程里的睡眠会等这次睡眠完成，而不是看到「正在进入睡眠」就去强制关机
    func transition(_ body: @escaping @MainActor () async -> Void) async {
        let previous = transitionTask
        let task = Task { @MainActor in
            await previous?.value
            await body()
        }
        transitionTask = task
        await task.value
        if transitionTask == task { transitionTask = nil }
    }

    /// 等进行中和排队中的状态转换全部结束
    func settle() async {
        while let task = transitionTask {
            await task.value
            if transitionTask == task { transitionTask = nil }
        }
    }

    /// 退出 MacBox 前调用：等进行中的操作结束，把运行中或暂停的虚拟 Mac 送去睡眠。
    /// 返回 true 表示已经没有在运行的虚拟机；false 表示睡眠失败、虚拟机还在运行——这里绝不擅自强制关机，
    /// 由调用方询问用户（强制关机还是取消退出）。正在设置的情况另见 isInstalling / cancelSetupAndWait()
    func prepareForTermination() async -> Bool {
        await settle()
        if status == .running || status == .paused { await sleep() }
        await settle()
        return virtualMachine == nil
    }

    func start() async {
        await transition { [self] in await performStart() }
    }

    private func performStart() async {
        guard status == .stopped else { return }
        lastError = nil
        status = .starting
        do {
            try bundle.ensureExchangeFolders()
            outgoingWatcher.start(bundle.outgoingURL, key: quarantineKey())
            // 监视器先开、再完整检查一遍，中间不会漏：旧版本留下的、上次退出或崩溃前监视器没来得及处理的都补上标记。
            // 用户不一定经由 MacBox 的按钮打开「传出」（访达侧边栏、最近使用、早就开着的窗口）
            Task { await quarantineOutgoing() }
            if isAsleep, try await wakeFromSavedState() { return }
            let vm = try makeVirtualMachine()
            virtualMachine = vm
            try await vm.start()
            // 刚启动就停了的话 didStop 已经处理过，不能再改回「运行中」
            if vm === virtualMachine { status = .running }
        } catch {
            // 唤醒时已经读回状态、却没能继续运行的虚拟机：停掉，别让它占着虚拟硬盘
            if let vm = virtualMachine, vm.canStop { try? await vm.stop() }
            virtualMachine = nil
            status = .stopped
            outgoingWatcher.stop()
            lastError = isAsleep
                ? String(localized: "无法唤醒，睡眠状态已保留：可以稍后再试，也可以在下方「资源」里丢弃睡眠状态，改为正常开机。（\(error.localizedDescription)）")
                : String(localized: "启动失败：\(error.localizedDescription)")
        }
    }

    /// 从睡眠状态恢复。睡眠文件本身用不了（VZErrorRestore：与当前配置不兼容或已损坏）时删掉它，改为正常开机（返回 false）；
    /// 其他错误（同时运行的虚拟机太多、内部错误等）多半是暂时的：原样抛出、保留睡眠状态，下次还能唤醒
    private func wakeFromSavedState() async throws -> Bool {
        let vm = try makeVirtualMachine()
        do {
            try await vm.restoreMachineStateFrom(url: bundle.saveStateURL)
        } catch where Self.shouldDiscardSaveState(after: error) {
            try? FileOps.removeIfExists(bundle.saveStateURL)
            refreshFlags()
            notice = String(localized: "无法从睡眠中唤醒（\(error.localizedDescription)），已改为正常开机。")
            return false
        }
        // 状态已经读回内存，睡眠文件随即作废：之后虚拟硬盘会被改动，再用它唤醒会损坏数据
        try? FileOps.removeIfExists(bundle.saveStateURL)
        refreshFlags()
        virtualMachine = vm
        try await vm.resume()
        if vm === virtualMachine { status = .running }
        return true
    }

    static func shouldDiscardSaveState(after error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == VZErrorDomain && ns.code == VZError.Code.restore.rawValue
    }

    private func makeVirtualMachine() throws -> VZVirtualMachine {
        let vm = VZVirtualMachine(configuration: try VMConfigurationFactory.make(bundle: bundle, config: config))
        vm.delegate = self
        return vm
    }

    /// 让虚拟 Mac 里的系统正常关机。只有运行中才能请求；其他时候说明原因，不默默忽略
    func requestShutdown() {
        guard let vm = virtualMachine else { return }
        guard vm.canRequestStop else {
            notice = String(localized: "虚拟 Mac 只有在运行时才能正常关机。暂停时请先继续，或者使用「强制关机」。")
            return
        }
        do {
            try vm.requestStop()
        } catch {
            lastError = String(localized: "关机请求失败：\(error.localizedDescription)")
        }
    }

    /// 强制关机（相当于拔电源）。排在进行中的操作之后
    func forceStop() async {
        await transition { [self] in await performForceStop() }
    }

    private func performForceStop() async {
        guard let vm = virtualMachine else { return }
        let previous = status
        status = .stopping
        do {
            try await vm.stop()
            didStop(vm)
        } catch {
            // 没停下来：保留虚拟机，按它的实际状态恢复
            if vm === virtualMachine {
                lastError = String(localized: "强制关机失败：\(error.localizedDescription)")
            }
            recover(after: vm, previous: previous)
        }
    }

    func togglePause() async {
        await transition { [self] in await performTogglePause() }
    }

    private func performTogglePause() async {
        guard let vm = virtualMachine else { return }
        let previous = status
        do {
            if status == .running {
                try await vm.pause()
                if vm === virtualMachine { status = .paused }
            } else if status == .paused {
                try await vm.resume()
                if vm === virtualMachine { status = .running }
            }
        } catch {
            if vm === virtualMachine { lastError = error.localizedDescription }
            recover(after: vm, previous: previous)
        }
    }

    /// 睡眠：保存运行状态后关闭，下次几秒内恢复原样。
    /// 正在进入睡眠（或启动、暂停途中）时调用，会等那次操作结束、再按当时的状态处理，而不是直接返回
    func sleep() async {
        await transition { [self] in await performSleep() }
    }

    private func performSleep() async {
        guard let vm = virtualMachine, status == .running || status == .paused else { return }
        let previous = status
        status = .saving
        do {
            if vm.state == .running { try await vm.pause() }
            try await vm.saveMachineStateTo(url: bundle.saveStateURL)
            try await vm.stop()
            didStop(vm)
        } catch {
            // 没完成的睡眠文件不能留：下次会被当成睡眠状态去唤醒
            try? FileOps.removeIfExists(bundle.saveStateURL)
            refreshFlags()
            if vm === virtualMachine {
                lastError = String(localized: "进入睡眠失败：\(error.localizedDescription)")
                // 是这里暂停的就恢复运行；用户自己暂停的保持暂停
                if previous == .running, vm.state == .paused { try? await vm.resume() }
            }
            recover(after: vm, previous: previous)
        }
    }

    /// 操作失败后按虚拟机的实际状态恢复
    private func recover(after vm: VZVirtualMachine, previous: Status) {
        switch Self.statusAfterFailedTransition(state: vm.state, isCurrent: vm === virtualMachine, previous: previous) {
        case .stopped?: didStop(vm)
        case let status?: self.status = status
        case nil: break
        }
    }

    /// 操作失败后应当显示的状态，nil 表示保持现状。
    /// 已经不是当前虚拟机（didStop 处理过它）的迟到失败一律忽略：否则会把已停止的状态改回「运行中」，
    /// 而虚拟机已经没了，界面上的按钮全都失效，只能重开 MacBox
    static func statusAfterFailedTransition(state: VZVirtualMachine.State, isCurrent: Bool, previous: Status) -> Status? {
        guard isCurrent else { return nil }
        switch state {
        case .stopped, .error: return .stopped
        case .running: return .running
        case .paused: return .paused
        // 还在途中（启动、暂停、继续、关机、保存、恢复）：先回到操作前的状态，之后的变化由回调处理
        default: return previous
        }
    }

    /// 只处理当前这台虚拟机的停止（旧实例迟到的回调忽略）
    private func didStop(_ vm: VZVirtualMachine) {
        guard vm === virtualMachine else { return }
        virtualMachine = nil
        status = .stopped
        refreshFlags()
        // 停下来之后客体不会再写「传出」：停止监视，再完整检查一遍（监视期间可能有被合并、丢弃的事件）
        outgoingWatcher.stop()
        Task { await quarantineOutgoing() }
    }

    // MARK: - 还原点

    func createRestorePoint() throws {
        guard status == .stopped else { throw MacBoxError(String(localized: "请先关闭虚拟 Mac")) }
        let temp = bundle.url.appending(path: "RestorePoint.tmp", directoryHint: .isDirectory)
        try FileOps.removeIfExists(temp)
        try AppPaths.ensure(temp)
        for file in bundle.restorableFiles where FileManager.default.fileExists(atPath: file.path) {
            try FileOps.clone(file, to: temp.appending(path: file.lastPathComponent), followingSymlink: false)
        }
        try FileOps.removeIfExists(bundle.restorePointURL)
        try FileManager.default.moveItem(at: temp, to: bundle.restorePointURL)
        refreshFlags()
    }

    func restoreRestorePoint() throws {
        guard status == .stopped else { throw MacBoxError(String(localized: "请先关闭虚拟 Mac")) }
        guard restorePointDate != nil else { throw MacBoxError(String(localized: "还没有还原点")) }
        for file in bundle.restorableFiles {
            try FileOps.removeIfExists(file)
            let source = bundle.restorePointURL.appending(path: file.lastPathComponent)
            if FileManager.default.fileExists(atPath: source.path) { try FileOps.clone(source, to: file, followingSymlink: false) }
        }
        refreshFlags()
    }

    func deleteRestorePoint() throws {
        guard !isUnreadable else { throw MacBoxError(String(localized: "虚拟 Mac 的配置无法读取，暂不能修改")) }
        try FileOps.removeIfExists(bundle.restorePointURL)
        refreshFlags()
    }

    /// 丢弃睡眠状态，下次正常开机。虚拟 Mac 里没保存的内容会丢失（界面上会先确认）
    func discardSleepState() throws {
        guard status == .stopped else { throw MacBoxError(String(localized: "请先关闭虚拟 Mac")) }
        try FileOps.removeIfExists(bundle.saveStateURL)
        refreshFlags()
    }

    /// 能否「删除虚拟 Mac」：装好的虚拟 Mac，或者旧版本没完成的设置留下了虚拟硬盘（现在设置失败时会自己清理）
    var canRemove: Bool {
        switch status {
        case .installing, .unreadable: false
        default: config.installed || FileManager.default.fileExists(atPath: bundle.diskURL.path)
        }
    }

    /// 删除整台虚拟 Mac（移到废纸篓）
    func remove() throws {
        guard !isUnreadable else { throw MacBoxError(String(localized: "虚拟 Mac 的配置无法读取，请在访达中检查后手动处理")) }
        guard !isActive, status != .installing else { throw MacBoxError(String(localized: "请先关闭虚拟 Mac")) }
        try moveBundleToTrash()
    }

    /// 只剩虚拟硬盘、没有 config.json 时（旧版本中断的设置会留下这种状态）可以整个移到废纸篓，重新设置。
    /// config.json 还在却读不出来时不提供：那可能是更新版本的 MacBox 写的，里面是装好的虚拟 Mac
    var canTrashUnreadable: Bool { isUnreadable && bundle.isMissingConfig }

    /// 返回它在废纸篓里的位置
    @discardableResult
    func trashUnreadable() throws -> URL? {
        guard canTrashUnreadable else {
            throw MacBoxError(String(localized: "虚拟 Mac 的配置无法读取，请在访达中检查后手动处理"))
        }
        return try moveBundleToTrash()
    }

    @discardableResult
    private func moveBundleToTrash() throws -> URL? {
        var trashed: NSURL?
        if FileManager.default.fileExists(atPath: bundle.url.path) {
            try FileManager.default.trashItem(at: bundle.url, resultingItemURL: &trashed)
        }
        // 先回到「未设置」再恢复默认配置（睡眠中的硬件锁不再适用）；默认配置不写盘，否则会立刻重建刚移走的文件夹
        status = .notSetUp
        refreshFlags()
        persistsConfig = false
        config = VirtualMacConfig()
        persistsConfig = true
        return trashed as URL?
    }

    // MARK: - 文件交换

    /// 把文件放进「传入」，在虚拟 Mac 里打开 My Shared Files › 传入 即可安装。
    /// 复制在后台线程进行（跨卷时可能要很久）；多次调用依次执行，同名项目不会互相踩
    func sendToGuest(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        let previous = sendTask
        let incoming = bundle.incomingURL
        pendingSends += 1
        let task = Task { @MainActor [self] in
            await previous?.value
            defer { pendingSends -= 1 }
            do {
                try bundle.ensureExchangeFolders()
            } catch {
                lastError = String(localized: "放入虚拟 Mac 失败：\(error.localizedDescription)")
                return
            }
            let result = await Background.run { Self.copyIntoIncoming(urls, incoming: incoming) }
            if let notice = Self.sendNotice(result) { self.notice = notice }
            if let message = result.firstError {
                lastError = String(localized: "\(quotedList(result.failedNames))放入虚拟 Mac 失败：\(message)")
            }
        }
        sendTask = task
        await task.value
        if sendTask == task { sendTask = nil }
    }

    /// 一次「放入」实际做了什么
    nonisolated struct SendResult: Equatable, Sendable {
        var added: [String] = []
        var replaced: [String] = []
        var unchanged: [String] = []
        var failedNames: [String] = []
        var firstError: String?
    }

    /// 「传入」里复制到一半的临时项（隐藏文件，客体平时看不到）
    nonisolated static let partialSuffix = ".macbox-partial"

    /// 把文件复制进 incoming。同名项目内容没变（结构、大小、修改时间一致）就跳过，变了就整体替换：
    /// 先复制成隐藏的临时项，完整之后再和旧的原子交换。失败时不留半个文件，客体也看不到复制到一半的 .app
    nonisolated static func copyIntoIncoming(_ urls: [URL], incoming: URL) -> SendResult {
        let fm = FileManager.default
        var result = SendResult()
        // 调用是串行的，开始时还在的临时项都是上次被打断（退出、崩溃）留下的。删不掉也不要紧：临时项每次都用新名字
        for item in (try? fm.contentsOfDirectory(at: incoming, includingPropertiesForKeys: nil)) ?? []
        where item.lastPathComponent.hasSuffix(partialSuffix) {
            try? removeTree(item)
        }
        for url in urls {
            let name = url.lastPathComponent
            let destination = incoming.appending(path: name)
            do {
                let exists = fm.fileExists(atPath: destination.path) || FileOps.isSymlink(destination)
                if exists, sameContents(url, destination) {
                    result.unchanged.append(name)
                    continue
                }
                // 名字里不带原名：原名接近 255 字节的上限时再加后缀会超长
                let temp = incoming.appending(path: ".\(UUID().uuidString)\(partialSuffix)")
                do {
                    try FileOps.clone(url, to: temp, followingSymlink: true) // 你选的文件；拖进来的替身要的是它指向的东西
                    if exists {
                        try swapItems(temp, destination)
                        try? removeTree(temp) // 交换之后这里是旧的那份
                    } else {
                        try fm.moveItem(at: temp, to: destination)
                    }
                } catch {
                    try? removeTree(temp)
                    throw error
                }
                if exists { result.replaced.append(name) } else { result.added.append(name) }
            } catch {
                result.failedNames.append(name)
                if result.firstError == nil { result.firstError = error.localizedDescription }
            }
        }
        return result
    }

    /// 原子交换两个位置上的项目（APFS 支持）；不支持时退化为先删后移
    nonisolated private static func swapItems(_ new: URL, _ old: URL) throws {
        if renamex_np(new.path, old.path, UInt32(RENAME_SWAP)) == 0 { return }
        try removeTree(old)
        try FileManager.default.moveItem(at: new, to: old)
    }

    /// 删除「传入」里的一项。普通删除遇到只读的文件夹（例如 .app 里 0555 的 Contents/MacOS）会删到一半失败，
    /// 留下删不掉、用户在访达里又看不见的隐藏项：这时先把里面的文件夹逐个加上属主的读写执行权限，再删一次。
    /// 「传入」对虚拟 Mac 只读，没有别人会在中途改动它
    nonisolated static func removeTree(_ url: URL) throws {
        do {
            try FileOps.removeIfExists(url)
        } catch {
            makeDirectoriesWritable(url)
            try FileOps.removeIfExists(url)
        }
    }

    /// 不跟随符号链接：先 lstat 确认是真的文件夹，再改它、进去
    nonisolated private static func makeDirectoriesWritable(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return }
        if info.st_mode & S_IRWXU != S_IRWXU { chmod(url.path, (info.st_mode & 0o7777) | S_IRWXU) }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] {
            makeDirectoriesWritable(url.appending(path: name))
        }
    }

    /// 粗略判断两个项目内容是否相同：结构一致，每个文件的大小和修改时间（精确到秒）一致。
    /// 克隆和复制都会保留修改时间，所以同一个文件再放一次会被认出来，不会重复复制
    nonisolated static func sameContents(_ a: URL, _ b: URL) -> Bool {
        guard let left = signature(of: a), let right = signature(of: b) else { return false }
        return left == right
    }

    nonisolated private static func signature(of url: URL) -> [String: String]? {
        func describe(_ item: URL) -> String? {
            let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            guard let values = try? item.resourceValues(forKeys: keys) else { return nil }
            if values.isSymbolicLink == true {
                return "link:" + ((try? FileManager.default.destinationOfSymbolicLink(atPath: item.path)) ?? "")
            }
            if values.isDirectory == true { return "dir" }
            let seconds = Int(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
            return "file:\(values.fileSize ?? -1):\(seconds)"
        }
        guard let root = describe(url) else { return nil }
        var result = ["": root]
        guard root == "dir" else { return result }
        let enumerator = FileManager.default.enumerator(atPath: url.path)
        while let relative = enumerator?.nextObject() as? String {
            guard let item = describe(url.appending(path: relative)) else { return nil }
            result[relative] = item
        }
        return result
    }

    /// 告诉用户「放入」实际做了什么；一项都没成功时返回 nil（错误另外显示）。
    /// 几句直接连起来：中文句子之间不空格，英文译文在句末带着空格
    static func sendNotice(_ result: SendResult) -> String? {
        var parts: [String] = []
        if !result.added.isEmpty || !result.replaced.isEmpty {
            parts.append(String(localized: "已放入虚拟 Mac。"))
        }
        if !result.replaced.isEmpty {
            parts.append(String(localized: "替换了「传入」里 \(result.replaced.count) 个同名的旧版本：\(quotedList(result.replaced))。"))
        }
        if !result.unchanged.isEmpty {
            parts.append(String(localized: "「传入」里已有且没有变化，未重新复制：\(quotedList(result.unchanged))。"))
        }
        guard !parts.isEmpty else { return nil }
        parts.append(String(localized: "在虚拟 Mac 的访达中打开 位置 › My Shared Files › 传入，即可安装。"))
        return parts.joined()
    }

    /// 给「传出」里现有的全部内容打上隔离标记（后台线程）。有标不上的项目时提醒用户，并返回它们（相对「传出」的路径）
    @discardableResult
    func quarantineOutgoing() async -> [String] {
        let outgoing = bundle.outgoingURL
        let key = quarantineKey()
        let failed = await Background.run { OutgoingQuarantine.markTree(outgoing, root: outgoing, key: key) }
        if !failed.isEmpty { lastError = Self.quarantineFailureMessage(failed) }
        return failed
    }

    static func quarantineFailureMessage(_ failed: [String]) -> String {
        let shown = Array(failed.prefix(3))
        let more = failed.count > shown.count
        return String(localized: "「传出」里有 \(failed.count) 项无法加上隔离标记：\(quotedList(shown, more: more))。打开之前请确认它们可信。")
    }

    private func quarantineKey() -> SymmetricKey {
        (try? bundle.quarantineKey()) ?? fallbackQuarantineKey
    }

    /// 打开「传出」文件夹：先把里面的东西全部打上隔离标记，再交给访达。
    /// 虚拟 Mac 运行期间新写进来的由监视器随时标记
    func openOutgoingFolder() async {
        do {
            try bundle.ensureExchangeFolders()
        } catch {
            lastError = error.localizedDescription
            return
        }
        await quarantineOutgoing()
        NSWorkspace.shared.open(bundle.outgoingURL)
    }

    func refreshFlags() {
        let fm = FileManager.default
        isAsleep = fm.fileExists(atPath: bundle.saveStateURL.path)
        let snapshotDisk = bundle.restorePointURL.appending(path: bundle.diskURL.lastPathComponent)
        restorePointDate = fm.fileExists(atPath: snapshotDisk.path) ? FileOps.creationDate(of: bundle.restorePointURL) : nil
    }

    // MARK: - 空间

    struct StorageItem: Identifiable {
        let id: String
        let title: String
        let bytes: Int64
    }

    func storageBreakdown() -> [StorageItem] {
        [
            StorageItem(id: "disk", title: String(localized: "系统和应用（虚拟硬盘）"),
                        bytes: FileOps.allocatedSize(of: bundle.diskURL)),
            StorageItem(id: "sleep", title: String(localized: "睡眠状态"), bytes: FileOps.allocatedSize(of: bundle.saveStateURL)),
            StorageItem(id: "restore", title: String(localized: "还原点（与硬盘共享未改动的数据）"),
                        bytes: FileOps.allocatedSize(of: bundle.restorePointURL)),
            StorageItem(id: "ipsw", title: String(localized: "macOS 安装镜像缓存"),
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
        lastError = String(localized: "虚拟 Mac 异常停止：\(error.localizedDescription)")
        didStop(virtualMachine)
    }
}
