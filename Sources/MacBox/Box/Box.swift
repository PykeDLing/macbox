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
    private(set) var activity: Activity = .idle {
        didSet { if activity == .idle, oldValue != .idle { becameIdle() } }
    }
    private(set) var blocks: [BlockEvent] = []
    /// 这次运行的报告（运行中陆续记下），或者最近一次运行的（见 loadLatestReport）。拦截记录运行中在 blocks 里，
    /// 收尾时才抄进来；界面用 currentReport
    private(set) var report: RunReport?
    private(set) var restorePointDate: Date?
    var lastError: String?
    var notice: String?
    /// 请求退出几秒后应用还在运行（在等你存储、你点了取消、没有响应）：界面上在「退出」旁边提供「强制退出」
    private(set) var offersForceQuit = false
    /// 刚请求过退出、还没到提供「强制退出」的时候：界面显示“正在退出…”，「退出」暂时不能再点
    /// （重复请求会让在问要不要存储的 App 再问一次）
    private(set) var isQuitting = false

    enum Activity: Equatable {
        case idle
        /// 准备环境、借出设置、启动中
        case launching
        /// App 在运行
        case running(IsolatedSession)
        /// App 已退出，正在收尾（收回设置、接管安装包、自动还原）
        case finishing
        /// 还原点、清除数据、完成安装、删除等维护操作
        case maintenance

        static func == (a: Activity, b: Activity) -> Bool {
            switch (a, b) {
            case (.idle, .idle), (.launching, .launching), (.finishing, .finishing), (.maintenance, .maintenance): true
            case (.running(let x), .running(let y)): x === y
            default: false
            }
        }
    }

    /// open 的结果。.launching 之后启动成没成看 activity：成了变成 running，没成回到 idle、设好 lastError
    enum OpenResult: Equatable {
        /// 开始在本机隔离中启动
        case launching
        /// 已经在启动或运行：切过去（启动中的，启动完成后切过去）
        case alreadyOpen
        /// 正在收尾、维护，或者只剩后台程序在运行（先请它们退出）：空闲后再打开
        case willOpenWhenIdle
        /// 设成在虚拟 Mac 中运行：交给虚拟 Mac（还没设置的，界面切到虚拟 Mac 页）
        case virtualMac
        /// MacBox 正在退出，不再打开应用
        case terminating
        /// 盒子已经删除
        case removed
        /// 打不开：原因（也在 lastError 里）
        case failed(String)
    }

    /// 空闲下来之后要做的打开
    private enum PendingOpen {
        /// 用户在收尾、维护期间要打开；或者主进程已退出、只剩后台程序时要打开（先请它们退出）。带着是谁要打开的
        case user(Origin)
        /// App 经由系统重新启动自己（“重启以生效”、更新后重启），沙盒外的新实例被守卫结束（见 BoxStore.handleEscape）：
        /// 这次运行结束后在隔离中重新打开，并补上那条拦截记录
        case relaunch(requestedAt: Date, event: BlockEvent)
    }

    /// 请求退出多久之后提供「强制退出」
    static let forceQuitDelay: Duration = .seconds(4)
    /// 启动后这么快就以非 0 退出的，算启动失败（见 finish）
    static let quickExit: TimeInterval = 3

    /// 启动器的同步操作依次执行，后一次总是基于当时最新的配置
    @ObservationIgnored private var launcherTask: Task<Void, Never>?
    /// 盒子已删除：之后的启动器同步只做删除
    @ObservationIgnored private var retired = false
    /// 已开始接手安装器下载的安装包（避免重复的拦截记录反复触发）
    @ObservationIgnored private var handingOver = false
    /// 这次运行里 MacBox 请求过退出（退出按钮、强制退出、退出 MacBox、接手安装）。启动期间收到的，启动后立即转达；
    /// 请求过退出的，很快退出不算启动失败，“重启以生效”也不再重新打开
    @ObservationIgnored private var quitRequested = false
    @ObservationIgnored private var pendingOpen: PendingOpen?
    /// 这次运行是谁打开的：启动失败、很快退出、运行中被拦截时，界面打开的才切页面、弹询问（见 Origin）
    @ObservationIgnored private var runOrigin = Origin.interface
    /// 这次启动完成后把它切到前台（见 bringToFront）
    @ObservationIgnored private var activateOnStart = false
    /// 这次运行里最近一次强制退出的时间（见 BoxStore.quitAll）
    @ObservationIgnored private(set) var forceQuitAt: ContinuousClock.Instant?
    /// 第几次退出请求：只有最近一次请求的计时到了才提供「强制退出」
    @ObservationIgnored private var quitGeneration = 0
    /// “主程序已退出、正在让后台程序退出”的说明：重新打开时清掉，不留着一条已经过去的事
    @ObservationIgnored private var reopenNotice: String?
    @ObservationIgnored private var cachedTidier: PathTidier?

    init(paths: BoxPaths, config: BoxConfig) {
        self.id = config.id
        self.paths = paths
        self.config = config
        // 不用 NSWorkspace.icon(forFile:)：它会把 App 登记进 LaunchServices（见 AppIcon）
        self.icon = AppIcon.load(paths.app(config))
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

    /// 打开应用；本机隔离时开始启动就返回，生命周期在后台继续。
    /// 正在收尾、维护时记下来，空闲后再打开，而不是什么也不做；MacBox 正在退出时不再打开任何应用（只切换过去）：
    /// 退出流程只会等、只会请求退出它开始等的那些，这时打开的会在 MacBox 退出后带着借出的偏好设置继续运行。
    /// 打不开时界面打开的切到这个应用让人看到原因，命令行打开的只返回原因（见 Origin）
    @discardableResult
    func open(from origin: Origin = .interface) async -> OpenResult {
        // 上次异常退出的收尾（收回设置等）完成后才能启动
        await store?.ready()
        guard !retired else { return .removed }
        if store?.isTerminating == true {
            // 不再打开，但可以切到还在运行的应用：比如去回答它“是否存储”，它才退得了
            session?.activate()
            return .terminating
        }
        lastError = nil
        switch config.runtime {
        case .isolated:
            guard await finishUnfinishedWork(origin) else { return .failed(lastError ?? "") }
            guard store?.isTerminating != true else { return .terminating }
            return startIsolated(origin)
        case .virtualMac:
            await store?.openInVirtualMac(self)
            return .virtualMac
        }
    }

    /// 上次的还原、清除数据没做完（做到一半失败了，或者 MacBox 中途退出、启动时又没能重做）：打开前先做完，
    /// 不在一半新一半旧的数据上运行——否则下次启动 MacBox 重做时，会把这之后的改动全部丢掉。
    /// 返回 false 表示没做完，这次不打开（原因在 lastError 里）
    private func finishUnfinishedWork(_ origin: Origin) async -> Bool {
        guard activity == .idle, let work = Self.unfinishedWork(paths) else { return true }
        let paths = paths
        do {
            try await performMaintenance { try await Background.run { try Self.redo(work, paths) } }
            notice = work.redoneNotice
            return true
        } catch {
            lastError = error is PartialRestore ? error.localizedDescription : work.refusedMessage(error.localizedDescription)
            if origin == .interface { store?.reveal(self) } // 从聚焦打开时主窗口可能关着
            return false
        }
    }

    /// 请求退出，像 ⌘Q 一样：App 可以先问要不要存储，也可以拒绝。几秒后还在运行时界面在「退出」旁边提供「强制退出」
    func quit() {
        switch activity {
        case .running(let session):
            quitRequested = true
            session.terminate()
            isQuitting = true
            quitGeneration += 1
            let generation = quitGeneration
            Task {
                try? await Task.sleep(for: Self.forceQuitDelay)
                guard self.session === session, quitGeneration == generation else { return }
                isQuitting = false
                offersForceQuit = true
            }
        case .launching:
            quitRequested = true // 启动后立即转达（见 runIsolated）
        default:
            break
        }
    }

    /// 强制结束会话里的所有进程（用户确认过：没有存储的内容会丢失）
    func forceQuit() async {
        guard let session else { return }
        quitRequested = true
        forceQuitAt = .now
        await session.forceQuit()
    }

    private func startIsolated(_ origin: Origin) -> OpenResult {
        switch activity {
        case .running(let session):
            // 主进程还在，或者盒子里有带界面的 App 可以切过去：切过去
            if session.activate() || !session.mainHasExited { return .alreadyOpen }
            // 主进程已退出，只剩没有界面的后台程序撑着这次运行，“切换过去”什么也不会发生。
            // 请它们退出，这次运行结束后重新打开
            openWhenIdle(from: origin)
            let message = L("「\(config.name)」的主程序已经退出，还有后台程序在运行。正在让它们退出，之后重新打开。",
                            "“\(config.name)” has quit, but some of its background processes are still running. MacBox is asking them to quit and will then open the app again.")
            notice = message
            reopenNotice = message
            quit()
            return .willOpenWhenIdle
        case .launching:
            activateOnStart = true // 已经在启动：启动完成后切到前台
            return .alreadyOpen
        case .finishing, .maintenance:
            openWhenIdle(from: origin)
            return .willOpenWhenIdle
        case .idle:
            break
        }
        if let conflict = preferenceConflict() {
            lastError = conflict
            if origin == .interface { store?.reveal(self) }
            return .failed(conflict)
        }
        runOrigin = origin
        activity = .launching
        blocks.removeAll()
        report = RunReport(config: config)
        handingOver = false
        quitRequested = false
        pendingOpen = nil
        offersForceQuit = false
        isQuitting = false
        forceQuitAt = nil
        activateOnStart = true
        Task { await runIsolated() }
        return .launching
    }

    /// 和正在运行的其他程序共用偏好设置时不能打开（见 PreferenceLease.overlaps）：另一个盒子里的同一应用，
    /// 或者本机直接安装的同一应用——它会读到盒子的登录状态，它写的设置也会被收进盒子。
    /// 另一个盒子上次借出的设置没收回时也不能打开：这次借出会把它借出的内容当成本机设置备份起来，收回时互相覆盖。
    /// 自带苹果沙盒的本机 App 用的是自己容器里的设置，不冲突
    private func preferenceConflict() -> String? {
        let prefixes = config.preferencePrefixes
        let others = (store?.boxes ?? []).filter { $0 !== self && PreferenceLease.overlaps($0.config.preferencePrefixes, prefixes) }
        if let other = others.first(where: \.isLive) {
            let name = other.config.name
            return L("「\(name)」正在运行，它和这个应用使用同一组偏好设置，不能同时打开。请先退出「\(name)」。",
                     "“\(name)” is running and shares preferences with this app, so they can’t be open at the same time. Quit “\(name)” first.")
        }
        if let other = others.first(where: { PreferenceLease(box: $0.paths, prefixes: $0.config.preferencePrefixes).isOutstanding }) {
            let name = other.config.name
            return L("「\(name)」上次运行时借出的偏好设置还没有收回，它和这个应用使用同一组偏好设置。请先打开再退出一次「\(name)」，或者重新打开 MacBox，让 MacBox 收回它的设置。",
                     "The preferences “\(name)” used last time haven’t been returned yet, and it shares preferences with this app. Open and quit “\(name)” once, or reopen MacBox, so MacBox can return them.")
        }
        let boxes = FileOps.realPath(AppPaths.boxes) + "/"
        let native = NSWorkspace.shared.runningApplications.first { app in
            guard let id = app.bundleIdentifier, PreferenceLease.domain(id, isCoveredBy: prefixes) else { return false }
            let inBox = app.bundleURL.map { FileOps.realPath($0).hasPrefix(boxes) } ?? false
            return !inBox && !ProcessTable.isSandboxed(app.processIdentifier)
        }
        if let native {
            let name = native.localizedName ?? native.bundleIdentifier ?? ""
            return L("这台 Mac 上直接安装的「\(name)」正在运行，它和盒子里的应用使用同一组偏好设置。请先退出它（没有窗口的后台程序可以在「活动监视器」里退出），再打开盒子里的应用。",
                     "“\(name)”, installed directly on this Mac, is running and shares preferences with the app in the box. Quit it first (background processes without a window can be quit in Activity Monitor), then open the app in the box.")
        }
        return nil
    }

    /// 一次完整的运行：启动 → 运行 → 收尾。状态只在这里推进
    private func runIsolated() async {
        let outcome: IsolatedSession.Outcome
        do {
            outcome = try await IsolatedSession.run(paths: paths, config: config, onStart: { [weak self] session in
                guard let self else { return }
                activity = .running(session)
                if quitRequested {
                    quit()
                } else if activateOnStart {
                    bringToFront(session)
                }
            }, onActivity: { [weak self] activity in
                self?.record(activity)
            })
        } catch {
            pendingOpen = nil // 启动不了：不再重试
            report = nil // 没有运行，没有报告：换回最近一次的
            Task { await loadLatestReport() }
            activity = .idle
            lastError = L("启动失败：\(error.localizedDescription)", "Couldn’t open the app: \(error.localizedDescription)")
            if runOrigin == .interface { store?.reveal(self) } // 从聚焦打开时主窗口可能关着，失败了要让人看到
            return
        }
        activity = .finishing
        await finish(outcome)
        if activity == .finishing { activity = .idle }
    }

    /// App 是 MacBox 用 posix_spawn 启动的，不经由 LaunchServices，继承不到“用户要打开它”的激活许可：
    /// 协作式激活下它启动时自己请求的激活常被拒绝，窗口留在原来的 App 后面。
    /// 先按标识符让出前台（它启动时的请求就能被接受），等它启动完成后再切过去一次（自己不请求激活的 App 也能到前台）。
    /// 只有 MacBox 自己在前台时让出才有效：在 MacBox 里点的打开，或者聚焦里的启动器把 MacBox 叫到了前台
    private func bringToFront(_ session: IsolatedSession) {
        NSApp?.yieldActivation(toApplicationWithBundleIdentifier: config.bundleIdentifier)
        Task {
            for _ in 0..<60 { // 最多等 15 秒
                try? await Task.sleep(for: .milliseconds(250))
                guard self.session === session, !quitRequested else { return }
                if let target = session.activationTarget(), target.isFinishedLaunching {
                    session.activate()
                    return
                }
            }
        }
    }

    func record(_ event: BlockEvent) {
        // 安装器下载完了、正尝试挂载安装包：不必等它报错，请它退出，由 MacBox 完成安装
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
                if self.session === session { quit() } // 不肯退出时，界面上照样提供「强制退出」
            }
        }
        if let index = blocks.firstIndex(where: { $0.id == event.id }) {
            blocks[index].count += 1
            blocks[index].lastSeen = event.lastSeen
        } else {
            blocks.insert(event, at: 0)
        }
    }

    /// 运行期间的记录。运行已经结束（晚到的连接、名字）的不再改动存好的报告
    func record(_ activity: RunActivity) {
        if case .blocked(let event) = activity {
            record(event)
            return
        }
        guard report?.isRunning == true else { return }
        switch activity {
        case .blocked: break
        case .launched(let path): report?.noteLaunch(tidier(path))
        case .connected(let contact): report?.note(contact)
        case .named(let address, let name): report?.name(address, name)
        case .wroteDownload: break // 会话自己汇总（见 IsolatedSession.run）
        }
    }

    /// 详情、报告页显示的报告：运行中的，随时抄上拦截记录
    var currentReport: RunReport? {
        guard var report else { return nil }
        if report.isRunning { report.blocks = blocks.map(tidier.callAsFunction) }
        return report
    }

    /// 打开详情时读出最近一次运行的报告（重新打开 MacBox 后内存里没有）
    func loadLatestReport() async {
        guard report == nil else { return }
        let latest = await RunReport.load(from: paths).first
        if report == nil { report = latest }
    }

    /// 盒子里存着的报告，最近的在前
    func savedReports() async -> [RunReport] {
        await RunReport.load(from: paths)
    }

    /// 运行结束：补上文件和设置的改动，抄上拦截记录，存进盒子。等存好再往下：MacBox 可能正在退出
    private func finishReport(_ outcome: IsolatedSession.Outcome) async {
        guard var report, report.isRunning else { return }
        report.endedAt = Date()
        report.files = outcome.changes?.files
        report.fileTotals = outcome.changes?.fileTotals
        report.preferences = outcome.changes?.preferences
        // 和其他盒子的前缀重叠的不算：另一个盒子运行中借出的域，在这段时间里也是新出现的，收进来就把它的设置拿走了
        let others = otherBoxPrefixes
        report.strayPreferences = outcome.changes?.strayPreferences.filter { stray in
            !others.contains { PreferenceLease.overlaps([stray.domain], $0) }
        }
        report.blocks = blocks.map(tidier.callAsFunction)
        self.report = report
        do {
            try await RunReport.save(report, in: paths)
        } catch {
            NSLog("MacBox: 无法保存运行报告：\(error.localizedDescription)")
        }
    }

    /// 其他盒子的偏好设置前缀
    private var otherBoxPrefixes: [[String]] {
        (store?.boxes ?? []).filter { $0 !== self }.map(\.config.preferencePrefixes)
    }

    /// 报告里列出的写在盒子外的设置，现在怎么样了（报告页用）
    enum StrayStatus: Equatable {
        /// 可以收进盒子
        case adoptable
        /// 已经在借出范围里了：收进来过，或者收了它的上级域。也可能是在线安装器那次运行写下的、接手安装时前缀变宽才盖住的
        /// （少见：安装器的前缀通常已经盖住真正的 App）——那样系统里的那份借出时会被当作本机原有的设置，见 adoptDownloadedPackage
        case adopted
        /// 收不进来，只列出：仅限本机的、整个厂商的名字
        case listedOnly(String)
    }

    /// 只看名字和现在的前缀，不读磁盘（报告页每次刷新都调用）；别的拒绝理由点「收进盒子」时才查（见 PreferenceLease.adopt）
    func status(of stray: StrayPreference) -> StrayStatus {
        if stray.byHost {
            return .listedOnly(L("仅限本机的设置，MacBox 收不进盒子。", "A this-Mac-only setting. MacBox can’t move these into the box."))
        }
        if PreferenceLease.domain(stray.domain, isCoveredBy: config.preferencePrefixes) { return .adopted }
        if StrayPreference.isVendorWide(stray.domain) {
            return .listedOnly(L("这是整个厂商的名字，收进来会把这个厂商以后所有 App 的设置都算进这个盒子。",
                                 "It’s a whole vendor’s name, so every app from this vendor would have its settings put in this box."))
        }
        return .adoptable
    }

    /// 把报告里列出的一个写在盒子外的设置域收进盒子（用户在报告页确认过）：现在的内容存进盒子，从这台 Mac 上删除，
    /// 再把它加进借出范围，以后只在应用运行时借给系统。不在运行、不在忙时才做；借出没收回的先收回，收不回就不做
    /// （改前缀必须在收回之后，见 adoptDownloadedPackage）。拒绝的理由见 PreferenceLease.adopt
    func adoptStrayPreference(_ domain: String, listedIn report: RunReport) async throws {
        let strays = Set((report.strayPreferences ?? []).filter { !$0.byHost }.map(\.domain))
        let others = otherBoxPrefixes
        try await performMaintenance {
            let lease = PreferenceLease(box: paths, prefixes: config.preferencePrefixes)
            let identifier = config.bundleIdentifier
            let installed = await Background.run { AppInspector.installedApplicationIdentifiers() }
            let prefixes = try await lease.adopt(domain, strays: strays, installed: installed, ownIdentifier: identifier,
                                                 otherBoxes: others)
            guard prefixes != config.preferencePrefixes else { return }
            var updated = config
            updated.preferencePrefixes = prefixes
            // 先存好再改内存里的：存不了要告诉用户（config 的 didSet 只把错误放进 lastError）。系统里的已经删了、内容在盒子里，
            // 前缀没加上时报告里照样显示「收进盒子」，再点一次就补上
            try paths.save(updated)
            config = updated
        }
    }

    private var tidier: PathTidier {
        if let cachedTidier { return cachedTidier }
        let tidier = PathTidier(paths: paths)
        cachedTidier = tidier
        return tidier
    }

    /// 空闲后再打开。界面和命令行都要打开时按界面的来：有人看着界面，打不开时要切过去让人看到
    private func openWhenIdle(from origin: Origin) {
        if case .user(.interface) = pendingOpen { return }
        pendingOpen = .user(origin)
    }

    /// 守卫在这次运行期间结束了一个沙盒外的主程序实例（见 BoxStore.handleEscape）：这次运行结束后在隔离中重新打开
    func relaunchWhenIdle(_ event: BlockEvent) {
        if case .user = pendingOpen { return } // 已经要重新打开了
        pendingOpen = .relaunch(requestedAt: Date(), event: event)
    }

    /// 空闲下来：做之前记下的打开
    private func becameIdle() {
        offersForceQuit = false
        isQuitting = false
        guard let pending = pendingOpen else { return }
        pendingOpen = nil
        guard let store, !store.isTerminating else { return }
        switch pending {
        case .user(let origin):
            // 后台程序已经退出，这就重新打开：“正在让它们退出”说的事已经过去了
            if let reopenNotice, notice == reopenNotice { notice = nil }
            reopenNotice = nil
            Task { await open(from: origin) }
        case .relaunch(let requestedAt, let event):
            // 用户这次请求过退出（退出前它自己重启的不算数）、等得太久（多半是你后来自己退出的）、短时间内反复重启：
            // 不再打开，只补上拦截记录
            guard !quitRequested, Date().timeIntervalSince(requestedAt) < 10, store.mayRelaunch(self) else {
                record(event)
                return
            }
            store.noteRelaunch(self)
            Task {
                await open()
                record(event) // 新的运行会清空拦截记录，所以等它开始后再记
            }
        }
    }

    /// App 已退出、系统资源已归还之后的处理
    private func finish(_ outcome: IsolatedSession.Outcome) async {
        // MacBox 正在退出：只做必要的收尾，不再接手安装、不再弹建议
        let terminating = store?.isTerminating == true
        offersForceQuit = false
        await finishReport(outcome)
        var errors: [String] = []
        if let reason = outcome.preferencesReturnError {
            errors.append(L("无法收回偏好设置，这台 Mac 上这个应用的设置暂时还是盒子里的内容。下次打开它或重新打开 MacBox 时会再试。原因：\(reason)",
                            "Couldn’t return the app’s preferences to the box, so this Mac’s settings for the app are still the box’s for now. MacBox will try again the next time you open the app or MacBox. \(reason)"))
        }
        // 接手安装失败等途中设置的错误也保留，一起显示
        defer { if !errors.isEmpty { lastError = ([lastError].compactMap { $0 } + errors).joined(separator: "\n") } }

        if config.isInstaller, let package = outcome.downloadedPackages.first, !terminating {
            await adoptDownloadedPackage(package)
            // 接手前会先收回（见 adoptDownloadedPackage）：收回了，“无法收回”就不用再说；没收回时不接手，两条一起显示
            if !PreferenceLease(box: paths, prefixes: config.preferencePrefixes).isOutstanding { errors.removeAll() }
            return
        }
        if handingOver {
            // 说了“正在接手安装”，安装包却已经不见了：不留着一条什么也不会发生的说明
            handingOver = false
            notice = nil
        }
        if config.resetOnQuit, restorePointDate != nil {
            if outcome.preferencesReturnError != nil {
                // 借出的日志和本机设置的备份在 Prefs 里，还原会整个替换 Prefs，本机原来的设置就再也恢复不了
                errors.append(L("这次没有自动还原。", "The automatic restore was skipped."))
            } else {
                do {
                    try await rollBack()
                    notice = L("已按设置还原到还原点，本次运行的改动已清除。",
                               "Restored to the restore point as set. Changes from this session were discarded.")
                } catch {
                    errors.append(L("自动还原失败：\(error.localizedDescription)", "Automatic restore failed: \(error.localizedDescription)"))
                }
            }
        }
        if !quitRequested, let status = outcome.mainExitStatus, status != 0, outcome.mainRanFor < Self.quickExit {
            errors.append(Self.quickExitMessage(name: config.name, status: status))
            if !terminating, runOrigin == .interface { store?.reveal(self) } // 从聚焦打开时主窗口可能关着
        }
        guard !terminating else { return }
        let acknowledged = Set(config.acknowledgedBlocks ?? [])
        let severe = blocks.filter { $0.kind.suggestsVirtualMac && !acknowledged.contains($0.id) }
        if !severe.isEmpty {
            store?.suggestVirtualMac(for: self, reasons: severe.map {
                L("\($0.kind.title)：\($0.targetText)", "\($0.kind.title): \($0.targetText)")
            }, blocks: severe.map(\.id), origin: runOrigin)
        }
    }

    /// 启动后很快就以非 0 退出：多半是缺少系统里没有的组件、在沙盒里无法运行。不说的话用户看到的是“点了没反应”
    nonisolated static func quickExitMessage(name: String, status: Int32) -> String {
        let advice = L("它可能需要这台 Mac 上没有的组件，或者在沙盒里无法运行；可以试试改用虚拟 Mac。",
                       "It may need components this Mac doesn’t have, or it may not run in the sandbox. Try running it in Virtual Mac.")
        // 被信号结束时退出码是 128 + 信号
        if status > 128, status < 128 + 32 {
            let signal = status - 128
            // 不用 strsignal：它只有英文，还会带上编号（“Killed: 9”）
            if let (chinese, english) = signalNames[signal] {
                return L("「\(name)」启动后很快就被信号 \(signal)（\(chinese)）结束了。",
                         "“\(name)” was ended by signal \(signal) (\(english)) right after opening. ") + advice
            }
            return L("「\(name)」启动后很快就被信号 \(signal) 结束了。", "“\(name)” was ended by signal \(signal) right after opening. ") + advice
        }
        return L("「\(name)」启动后很快就退出了（退出码 \(status)）。", "“\(name)” quit right after opening (exit code \(status)). ") + advice
    }

    /// 常见信号的说法（中文、英文）
    nonisolated private static let signalNames: [Int32: (String, String)] = [
        SIGKILL: ("强制结束", "killed"),
        SIGTERM: ("终止", "terminated"),
        SIGSEGV: ("内存访问错误", "segmentation fault"),
        SIGBUS: ("总线错误", "bus error"),
        SIGABRT: ("异常中止", "abort"),
        SIGILL: ("非法指令", "illegal instruction"),
        SIGTRAP: ("运行时错误", "trace trap"),
    ]

    /// 在线安装器下载完整安装包后，由 MacBox 取出真正的 App 替换安装器，然后打开（和导入时一样，需要虚拟 Mac 的先问）
    private func adoptDownloadedPackage(_ package: URL) async {
        activity = .maintenance
        notice = L("安装器已下载「\(package.lastPathComponent)」，正在完成安装…",
                   "The installer downloaded “\(package.lastPathComponent)”. Finishing the installation…")
        let paths = paths
        let staging = paths.appStaging
        do {
            // 先收回这次借出的偏好设置，收不回就不接手：接手会把前缀放宽到真正的 App（见 merging），借出没收回时
            // 下次就要按新前缀收回，会把这台 Mac 上从没借出、也没备份过的域（本机直接安装的同一个 App 的登录状态）
            // 收进盒子、再从本机删掉。安装包留在盒子里
            try await settlePreferences()
            try await Background.run { try FileOps.removeTree(staging) }
            let extracted = try await PackageExtractor.extractApp(from: package, into: staging)
            let info = try AppInspector.info(of: extracted.app)
            var issues = extracted.issues
            issues += await AppInspector.scan(extracted.app)
            issues.insert(await AppInspector.verifyAndTrust(extracted.app), at: 0)
            let prefixes = await Background.run { AppInspector.preferencePrefixes(for: extracted.app, identifier: info.bundleIdentifier) }

            try await Background.run {
                // 先锁好再换上去（见 AppLock）；换的过程任何时刻崩溃，盒子里都是完整的旧 App 或新 App（见 FileOps.replace）
                try AppLock.lock(extracted.app)
                try FileOps.replace(paths.appDirectory, withStaged: staging)
                try? FileOps.removeTree(package) // 安装包已用完，不再占空间。在盒子里，App 改得到：不跟随链接
            }

            var updated = config
            updated.name = store?.uniqueName(info.name, excluding: self) ?? info.name
            updated.bundleIdentifier = info.bundleIdentifier
            updated.version = info.version
            updated.appFolderName = extracted.app.lastPathComponent
            updated.isInstaller = false
            updated.issues = issues
            // 安装器自己的前缀保留（它写下的设置还在盒子里），加上真正的 App 的
            updated.preferencePrefixes = Self.merging(updated.preferencePrefixes, prefixes)
            updated.acknowledgedBlocks = nil // 换了 App，之前“继续使用本机隔离”的选择不再算数
            config = updated // 名称、安装器标记变化会自动重建启动器
            icon = AppIcon.load(appURL)
            // 安装器尝试写入「应用程序」被拦截是预期内的，安装已由 MacBox 完成
            blocks.removeAll { [.systemInstall, .escapedLaunch, .diskMount].contains($0.kind) }
            notice = L("「\(config.name)」已安装到 MacBox。", "“\(config.name)” was installed in MacBox.")
            // 和导入时一样：需要虚拟 Mac 的先问，不直接在本机隔离里打开（命令行打开的安装器不问，见 Origin）
            if store?.reviewCompatibility(of: self, origin: runOrigin) ?? true { openWhenIdle(from: runOrigin) }
            activity = .idle // 空闲后打开（见 becameIdle）
        } catch {
            try? await Background.run { try FileOps.removeTree(staging) }
            activity = .idle
            notice = nil
            lastError = L("完成安装失败：\(error.localizedDescription)", "Couldn’t finish the installation: \(error.localizedDescription)")
        }
    }

    /// 合并偏好设置前缀：已经被覆盖的不加；新的覆盖了旧的就换掉旧的。借出范围只会变大，不会漏掉之前借出过的域
    nonisolated static func merging(_ existing: [String], _ added: [String]) -> [String] {
        var result = existing
        for prefix in added where !PreferenceLease.domain(prefix, isCoveredBy: result) {
            result.removeAll { PreferenceLease.domain($0, isCoveredBy: [prefix]) }
            result.append(prefix)
        }
        return result
    }

    // MARK: - 还原点与数据

    func createRestorePoint() async throws {
        try await performMaintenance {
            let paths = paths
            try await Background.run {
                // 上次的还原、清除数据没做完：先做完，还原点不收进一半新一半旧的数据
                if let work = Box.unfinishedWork(paths) { try Box.redo(work, paths) }
                // 先在旁边建好，完整之后再整体换上去：中途退出、崩溃都不会留下半个还原点（旧的那个照样完整）
                let staging = paths.restorePointStaging
                try FileOps.removeTree(staging)
                try AppPaths.ensure(staging)
                for item in paths.restorableItems {
                    let source = paths.url.appending(path: item)
                    // 不跟随链接：App 改得到这些，换成指向盒子外的链接时只复制链接本身
                    if FileOps.exists(source) { try FileOps.clone(source, to: staging.appending(path: item), followingSymlink: false) }
                }
                try FileOps.replace(paths.restorePoint, withStaged: staging)
            }
            refreshRestorePoint()
        }
    }

    func restoreRestorePoint() async throws {
        guard restorePointDate != nil else { throw MacBoxError(L("还没有还原点", "There’s no restore point yet")) }
        try await performMaintenance { try await rollBack() }
    }

    func deleteRestorePoint() async throws {
        try beginMaintenance()
        defer { activity = .idle }
        // 启动时的收尾可能正在用还原点重做没做完的还原：等它做完再删（偏好设置不用收回，删还原点不动 Prefs）
        await store?.ready()
        let paths = paths
        let abandoned = try await Background.run {
            try FileOps.replace(paths.restorePoint, withCloneOf: nil)
            // 没做完的还原再也没法重做了：去掉标记（留着的话打开、启动时只会再报一次），告诉用户数据可能只还原了一部分
            guard Box.unfinishedWork(paths) == .restore else { return false }
            try FileOps.removeTree(paths.unfinishedMarker)
            return true
        }
        config.resetOnQuit = false
        refreshRestorePoint()
        if abandoned { lastError = PartialRestore().localizedDescription }
    }

    /// 清除应用数据：主目录、设置、钥匙串全部重置，相当于刚安装。
    /// 钥匙串密码保留：盒子一辈子只用一个密码（见 BoxKeychain），清除之前、之后做的还原点都还原得了
    func clearData() async throws {
        try await performMaintenance {
            let paths = paths
            try await Background.run { try Self.clear(paths) }
        }
    }

    /// 清除数据。每一项先挪开再删（见 FileOps.replace）：删到一半退出、崩溃时，留下的只是启动时会删掉的残骸，不是半个主目录。
    /// 开始前放下标记、全部删完才去掉：中途失败、崩溃时，下次打开应用前、下次启动 MacBox 时重做一遍，
    /// 不会留下主目录清空了、设置还是登录状态的盒子
    nonisolated static func clear(_ paths: BoxPaths) throws {
        try mark(.clear, paths)
        for item in [paths.home, paths.prefs, paths.tmp] { try FileOps.replace(item, withCloneOf: nil) }
        try FileOps.removeTree(paths.unfinishedMarker)
    }

    /// 应用数据占用的空间（要遍历整个主目录，在后台计算）
    func measureDataSize() async -> Int64 {
        let paths = paths
        return await Background.run {
            FileOps.allocatedSize(of: paths.home) + FileOps.allocatedSize(of: paths.prefs)
        }
    }

    /// 维护操作：期间不能打开、不能做别的维护。先收回上次没收回的偏好设置：借出的日志和本机设置的备份在 Prefs 里，
    /// 还原、清除数据会整个替换 Prefs，删除会连盒子一起移走，跟着没了的话本机原来的设置就再也恢复不了；收不回就不做
    func performMaintenance<T>(_ work: () async throws -> T) async throws -> T {
        try beginMaintenance()
        defer { activity = .idle }
        try await settlePreferences()
        return try await work()
    }

    private func beginMaintenance() throws {
        guard !isRunning else { throw MacBoxError(L("请先退出应用", "Quit the app first")) }
        guard activity == .idle else { throw MacBoxError(L("「\(config.name)」正在处理其他操作，请稍候",
                                                            "“\(config.name)” is busy with another operation. Try again in a moment.")) }
        activity = .maintenance
    }

    /// 用还原点替换当前数据（调用方负责确认应用未在运行）
    private func rollBack() async throws {
        try await settlePreferences()
        let paths = paths
        try await Background.run { try Self.rollBack(paths) }
    }

    /// 用还原点替换当前数据。每一项都整体替换（见 FileOps.replace），开始前放下标记、全部换完才删：
    /// 中途失败、崩溃时，下次打开应用前、下次启动 MacBox 时看到标记就重做一遍，不会留下有的项新、有的项旧
    nonisolated static func rollBack(_ paths: BoxPaths) throws {
        try mark(.restore, paths)
        let password = paths.keychainPassword.lastPathComponent
        for item in paths.restorableItems {
            let source = paths.restorePoint.appending(path: item)
            let saved = FileOps.exists(source)
            // 旧版的还原点没有保存钥匙串密码：保留现有的（和钥匙串对不上时 BoxKeychain 会换一个新钥匙串）
            if !saved && item == password { continue }
            try FileOps.replace(paths.url.appending(path: item), withCloneOf: saved ? source : nil)
        }
        // 旧版可能在借出没收回时创建过还原点：那时的日志和本机设置备份已经过时，不能跟着还原回来
        try FileOps.removeTree(paths.leaseJournal)
        try FileOps.removeTree(paths.nativePrefsBackup)
        try FileOps.removeTree(paths.unfinishedMarker)
    }

    // MARK: - 没做完的维护

    /// 做到一半的还原、清除数据（见 BoxPaths.unfinishedMarker）
    nonisolated enum UnfinishedWork: String, Sendable {
        case restore, clear

        /// 重做完成后的说明。不说“MacBox 没有正常退出”：也可能是上次做到一半失败了
        var redoneNotice: String {
            switch self {
            case .restore: L("上次的还原没有做完，已从还原点重新还原应用的数据。",
                             "The last restore didn’t finish, so the app’s data was restored from the restore point again.")
            case .clear: L("上次的清除数据没有做完，已重新清除。", "The last data clearing didn’t finish, so the app’s data was cleared again.")
            }
        }

        /// 打开前重做失败，这次不打开
        func refusedMessage(_ reason: String) -> String {
            switch self {
            case .restore: L("上次的还原没有做完，这次也没能完成。为了不在只还原了一部分的数据上运行，先不打开。请再试一次「还原…」，或者删除还原点。原因：\(reason)",
                             "The last restore didn’t finish and still couldn’t be completed, so MacBox won’t open the app on partly restored data. Try Restore again, or delete the restore point. \(reason)")
            case .clear: L("上次的清除数据没有做完，这次也没能完成。为了不在只清除了一部分的数据上运行，先不打开。请再试一次「清除数据…」。原因：\(reason)",
                           "The last data clearing didn’t finish and still couldn’t be completed, so MacBox won’t open the app on partly cleared data. Try Clear Data again. \(reason)")
            }
        }

        /// 启动 MacBox 时重做失败
        func failedMessage(_ reason: String) -> String {
            switch self {
            case .restore: L("上次没有做完的还原无法完成：\(reason)", "Couldn’t finish the restore that was interrupted last time: \(reason)")
            case .clear: L("上次没有做完的清除数据无法完成：\(reason)", "Couldn’t finish clearing the data, which was interrupted last time: \(reason)")
            }
        }
    }

    /// 没做完的还原，还原点却已经不在了：没法重做
    nonisolated struct PartialRestore: LocalizedError {
        var errorDescription: String? {
            L("上次的还原没有做完，而还原点已经不在了，应用的数据可能只还原了一部分。",
              "The last restore didn’t finish and the restore point is gone, so the app’s data may be only partly restored.")
        }
    }

    /// 标记里没写是哪一种的（读不出来）当作还原
    nonisolated static func unfinishedWork(_ paths: BoxPaths) -> UnfinishedWork? {
        guard FileOps.exists(paths.unfinishedMarker) else { return nil }
        let text = FileOps.regularFileContents(paths.unfinishedMarker).flatMap { String(data: $0, encoding: .utf8) }
        return text.flatMap(UnfinishedWork.init(rawValue:)) ?? .restore
    }

    /// 重做没做完的维护。还原点已经不在、没法重做还原时去掉标记，抛出 PartialRestore。调用方负责先收回偏好设置
    nonisolated static func redo(_ work: UnfinishedWork, _ paths: BoxPaths) throws {
        switch work {
        case .clear:
            try clear(paths)
        case .restore:
            guard FileOps.exists(paths.restorePoint) else {
                try FileOps.removeTree(paths.unfinishedMarker)
                throw PartialRestore()
            }
            try rollBack(paths)
        }
    }

    /// 放下标记，内容是哪一种（整体写入：之前留下的另一种标记被换掉，以最后开始的为准）
    nonisolated private static func mark(_ work: UnfinishedWork, _ paths: BoxPaths) throws {
        do {
            try Data(work.rawValue.utf8).write(to: paths.unfinishedMarker, options: .atomic)
        } catch {
            throw MacBoxError(work == .restore
                ? L("无法开始还原：写不了盒子文件夹（\(error.localizedDescription)）", "Couldn’t start the restore: the box folder isn’t writable (\(error.localizedDescription))")
                : L("无法开始清除数据：写不了盒子文件夹（\(error.localizedDescription)）", "Couldn’t start clearing the data: the box folder isn’t writable (\(error.localizedDescription))"))
        }
    }

    /// 上次异常结束时没收回的偏好设置，先收回再动 Prefs、再改前缀。先等启动时的收尾完成，免得和它同时收回。
    /// 收不回时说清楚为什么不做：不然用户只看到一句“无法把某个域存回盒子”
    private func settlePreferences() async throws {
        await store?.ready()
        let lease = PreferenceLease(box: paths, prefixes: config.preferencePrefixes)
        guard lease.isOutstanding else { return }
        do {
            try await lease.checkOut()
        } catch {
            throw MacBoxError(L("这个应用上次借出的偏好设置还没收回，为了不丢掉这台 Mac 原来的设置，先不做这个操作。重新打开 MacBox，或者打开再退出一次这个应用后再试。原因：\(error.localizedDescription)",
                                "The preferences this app borrowed last time haven’t been returned yet. To keep this Mac’s original settings safe, MacBox won’t do this until they are. Reopen MacBox, or open and quit the app once, then try again. \(error.localizedDescription)"))
        }
    }

    private func refreshRestorePoint() {
        restorePointDate = FileManager.default.fileExists(atPath: paths.restorePoint.path)
            ? FileOps.creationDate(of: paths.restorePoint) : nil
    }

    // MARK: - 配置

    private func configChanged(from old: BoxConfig) {
        guard config != old, !retired else { return }
        // 换了运行环境：之前“继续使用本机隔离”的选择不再算数，回到本机隔离后同样的拦截会再问一次
        if old.runtime != config.runtime, config.acknowledgedBlocks != nil {
            config.acknowledgedBlocks = nil // 会再次进来，保存这次的改动
        }
        do {
            try paths.save(config)
        } catch {
            lastError = L("无法保存设置：\(error.localizedDescription)", "Couldn’t save settings: \(error.localizedDescription)")
        }
        if old.name != config.name || old.wantsLauncher != config.wantsLauncher || old.appFolderName != config.appFolderName {
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
            if retired || !config.wantsLauncher {
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
