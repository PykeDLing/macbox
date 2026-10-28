import AppKit
import Foundation
import Observation

/// 兼容性问题出现时的处理方式（设置 › 兼容性）
enum CompatibilityPolicy: String, CaseIterable, Identifiable {
    case ask, switchAutomatically
    var id: String { rawValue }
    var title: String { self == .ask ? L("询问我", "Ask Me") : L("自动改用虚拟 Mac", "Switch to Virtual Mac Automatically") }
    static let key = "compatibilityPolicy"
    static var current: CompatibilityPolicy {
        CompatibilityPolicy(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .ask
    }
}

/// 主窗口侧边栏的页面
enum Destination: Hashable {
    case allApps, running, virtualMac, settings
}

/// 询问要不要改用虚拟 Mac。排队中的同一个盒子只有一条，新的理由并进去；正在显示的不再改动
struct CompatibilityPrompt: Identifiable {
    let id = UUID()
    let boxID: UUID
    let appName: String
    var reasons: [String]
    /// 运行时被挡住的拦截（BlockEvent.id）。用户选“继续使用本机隔离”时记进盒子，同样的拦截以后不再问；
    /// 导入时静态检查出的问题只问这一次，不用记
    var blocks: [String] = []
}

/// 安装包里只有驱动、插件这类系统组件，没有能单独运行的 App：建议把它放进虚拟 Mac 安装
struct VirtualMacOffer: Identifiable {
    let id = UUID()
    /// 用户拖进来的原始文件（盒子没建成，里面的副本已经删了）
    let file: URL
    let message: String
}

/// 需要告诉用户、又不属于某次添加的事（启动时的收尾出了问题、启动器对应的应用不在了）
struct StoreAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// App 的窗口
enum WindowID: String {
    case library
    case virtualMac = "virtual-mac"
}

/// 请求界面打开某个窗口（每次请求都是新值，重复请求同一窗口也会触发）
struct WindowRequest: Equatable {
    let window: WindowID
    let id = UUID()
}

/// box.json 读不出来的盒子：照原样保留，不覆盖、不删除它的启动器，由用户决定怎么处理
struct BrokenBox: Identifiable {
    let id: UUID
    let url: URL
    let message: String
}

/// 操作是谁发起的，决定结果怎么呈现。界面（窗口、聚焦里的启动器、程序坞）发起的，照旧切页面、弹询问；
/// 命令行发起的不动界面：结果和错误交回给它（见 docs/cli-design.md）
enum Origin: Equatable {
    case interface
    case commandLine
}

/// 添加一个文件进行到了哪一步（界面上的进度卡片，命令行的进度）
enum ImportStage: Equatable {
    case reading, extracting, checking, preparingKeychain

    func text(for file: URL) -> String {
        switch self {
        case .reading: L("正在读取「\(file.lastPathComponent)」…", "Reading “\(file.lastPathComponent)”…")
        case .extracting: L("正在取出 App…", "Extracting the app…")
        case .checking: L("正在检查兼容性…", "Checking compatibility…")
        case .preparingKeychain: L("正在准备独立的钥匙串…", "Preparing a separate keychain…")
        }
    }
}

/// 添加一个文件的结果
enum ImportOutcome {
    /// 添加好了。需要虚拟 Mac 的，见它的 config.issues 和 runtime（按设置可能已经改用虚拟 Mac）
    case added(Box)
    /// 安装包里只有驱动、插件这类系统组件，要放进虚拟 Mac 安装（见 VirtualMacOffer）
    case needsVirtualMac(file: URL, message: String)
    case failed(file: URL, reason: String)
    /// MacBox 正在退出，或者另一个 MacBox 管理着盒子：没有添加
    case skipped(URL)
}

/// 这些盒子由谁管理（见 EngineLock）
enum Ownership: Equatable {
    case thisProcess
    /// 另一个 MacBox 拿着引擎锁：这个进程什么都不碰。读不出是谁时为 nil
    case otherProcess(EngineLock.Holder?)
}

@Observable
final class BoxStore {
    static let shared = BoxStore()

    private(set) var boxes: [Box] = []
    private(set) var brokenBoxes: [BrokenBox] = []
    var selection: UUID?
    /// 添加应用的进度（几次添加同时进行时显示最新的一条），全部结束才清空
    private(set) var importStatus: String?
    var importError: String?
    /// 正在显示的兼容性询问。已经移出队列，不再并入新的理由：显示着的内容和用户回答的、记下的是同一份
    private(set) var prompt: CompatibilityPrompt?
    /// 排队等着显示的兼容性询问
    private(set) var prompts: [CompatibilityPrompt] = []
    /// 排队的“放进虚拟 Mac”建议，一次显示一条
    private(set) var virtualMacOffers: [VirtualMacOffer] = []
    /// 排队的其他提示，一次显示一条
    private(set) var alerts: [StoreAlert] = []
    var destination: Destination = .allApps
    /// 由 App 场景消费：打开对应窗口
    var windowRequest: WindowRequest?
    /// start() 时决定，之后不再改变
    private(set) var ownership = Ownership.thisProcess
    var isManagedElsewhere: Bool { ownership != .thisProcess }

    /// MacBox 正在退出：不再打开应用、不再开始添加（见 quitAll）。主窗口据此显示“正在退出 MacBox…”、停用打开和添加
    private(set) var isTerminating = false
    /// 这次退出 MacBox 时请求过退出的盒子：请求时的会话（启动期间请求的为 nil，启动后由盒子转达）和时间。
    /// 每次运行只请求一次（重复请求会让在问“是否存储”的 App 再问一次），从各自请求时起等满 patience 才算不肯退出
    @ObservationIgnored private var quitRequests: [ObjectIdentifier: (session: ObjectIdentifier?, at: ContinuousClock.Instant)] = [:]
    /// 因为正在退出 MacBox 而没有添加的文件：取消退出时告诉用户
    @ObservationIgnored private var skippedImports: [URL] = []
    /// 正在进行的添加（一次添加多个文件算一次）。退出 MacBox 前要等它们做完，否则留下半个盒子
    @ObservationIgnored private(set) var activeImports = 0
    @ObservationIgnored private var started = false
    /// 上次异常退出的收尾；启动应用、导入之前都要等它完成
    @ObservationIgnored private var recovery: Task<Void, Never>?
    @ObservationIgnored private var volumeWatchers: [Task<Void, Never>] = []
    /// 守卫结束沙盒外的主程序后，在隔离中重新打开的时间（每个盒子最近一分钟的）
    @ObservationIgnored private var relaunches: [UUID: [Date]] = [:]
    /// 拿到的引擎锁，一直持有到进程结束（锁文件打不开时为 nil，照旧管理盒子）
    @ObservationIgnored private var engineLock: EngineLock?
    /// 引擎锁所在的目录，nil 时是 AppPaths.root（测试时换成别处：同一个测试进程里的锁总是拿得到）
    @ObservationIgnored private let lockDirectory: URL?

    /// 不做任何事；拿锁、读取盒子、启动守卫等都在 start() 里
    init(lockDirectory: URL? = nil) {
        self.lockDirectory = lockDirectory
    }

    /// 拿引擎锁，读取盒子、收尾上次异常退出、启动守卫。可重复调用，只有第一次生效。
    /// 锁在另一个 MacBox 手里时什么都不碰：这里的收尾和守卫会结束它正在运行的应用、收回它正借出的设置（见 EngineLock）
    func start() {
        guard !started else { return }
        started = true
        do {
            switch try EngineLock.acquire(in: lockDirectory ?? AppPaths.root) {
            case .acquired(let lock):
                engineLock = lock
            case .heldByOther(let holder):
                ownership = .otherProcess(holder)
                return
            }
        } catch {
            // 锁文件建不了、打不开（数据目录的权限不对等）：照旧启动，和没有锁的旧版一样，不因此让 MacBox 用不了
            NSLog("MacBox: 无法使用引擎锁：\(error.localizedDescription)")
        }
        reload()
        // 这时还没有打开过任何应用，盒子里还在运行的程序都是上次 MacBox 运行时留下的（MacBox 崩溃、被强制退出）。
        // 守卫照样结束它们，但不当作逃逸：它们本来就在沙盒里，不该记成“在沙盒外启动程序”，也不该被当成
        // “有人直接打开了盒子里的 App”而在隔离中重新打开。收尾时也会先结束它们（见 recoverInterruptedSessions）
        EscapeGuard.shared.start(preexisting: EscapeGuard.boxProcessesNow()) { [weak self] escape in self?.handleEscape(escape) }
        recovery = Task { await recoverInterruptedSessions() }
        // 有卷挂载/卸载时立即更新守卫（安装器挂载 dmg 后常常马上从卷上启动 App）
        let center = NSWorkspace.shared.notificationCenter
        volumeWatchers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map { name in
            Task.detached {
                for await _ in center.notifications(named: name) { await EscapeGuard.refreshVolumes() }
            }
        }
        Task { await EscapeGuard.refreshVolumes() }
    }

    /// 测试用：停止守卫和卷的监视（MacBox 自己从不停止）
    func stop() {
        EscapeGuard.shared.stop()
        volumeWatchers.forEach { $0.cancel() }
        volumeWatchers = []
    }

    /// 等待启动时的收尾完成
    func ready() async {
        start()
        await recovery?.value
    }

    private func reload() {
        _ = try? AppPaths.ensure(AppPaths.boxes)
        var loaded: [Box] = []
        var broken: [BrokenBox] = []
        for url in FileOps.contents(of: AppPaths.boxes) where url.pathExtension == "box" {
            let paths = BoxPaths(url: url)
            do {
                let box = Box(paths: paths, config: try paths.loadConfig())
                box.store = self
                loaded.append(box)
            } catch {
                let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID()
                broken.append(BrokenBox(id: id, url: url, message: Self.describeLoadError(error)))
            }
        }
        boxes = loaded.sorted { $0.config.createdAt < $1.config.createdAt }
        brokenBoxes = broken
        // 启动器被删掉、被覆盖或者是旧写法的时补上、重写，没有主人的清掉（读不出的盒子也算主人）
        let keep = Set(boxes.map(\.id) + brokenBoxes.map(\.id))
        let wanted = boxes.filter(\.config.wantsLauncher)
        Task {
            await Launcher.shared.removeOrphans(keeping: keep)
            for box in wanted where await Launcher.shared.needsInstall(for: box.id) {
                box.syncLauncher()
            }
        }
    }

    /// 启动时收不回偏好设置的提示。一个应用时不用复数
    static func unreturnedMessage(_ names: [String]) -> String {
        if names.count == 1 {
            return L("MacBox 上次没有正常退出，\(chineseList(names))借出的偏好设置没能收回，这台 Mac 上这个应用的设置暂时还是盒子里的内容。详情见它的详情面板；下次打开它或重新打开 MacBox 时会再试。",
                     "MacBox didn’t quit normally last time, and the preferences lent to \(englishList(names)) couldn’t be returned, so this Mac’s settings for it are still the box’s for now. See the app’s details. MacBox will try again the next time you open it or MacBox.")
        }
        return L("MacBox 上次没有正常退出，\(chineseList(names))借出的偏好设置没能收回，这台 Mac 上这些应用的设置暂时还是盒子里的内容。详情见各应用的详情面板；下次打开它们或重新打开 MacBox 时会再试。",
                 "MacBox didn’t quit normally last time, and the preferences lent to \(englishList(names)) couldn’t be returned, so this Mac’s settings for these apps are still the boxes’ for now. See each app’s details. MacBox will try again the next time you open them or MacBox.")
    }

    private static func describeLoadError(_ error: Error) -> String {
        if (error as? CocoaError)?.code == .fileReadNoSuchFile { return L("缺少配置文件 box.json", "The configuration file box.json is missing") }
        if error is DecodingError {
            return L("配置文件 box.json 格式无法识别，可能来自更新版本的 MacBox 或已损坏",
                     "The configuration file box.json isn’t in a recognized format. It may be from a newer version of MacBox, or damaged.")
        }
        return L("无法读取配置文件 box.json：\(error.localizedDescription)",
                 "Couldn’t read the configuration file box.json: \(error.localizedDescription)")
    }

    func box(id: UUID) -> Box? { boxes.first { $0.id == id } }

    /// 同一个应用装了多份（比如两个网盘账号）时依次叫「夸克网盘」「夸克网盘 2」，和聚焦里的启动器同名；
    /// 否则卡片、提示（“「夸克网盘」正在运行”）里分不清是哪一个
    func uniqueName(_ name: String, excluding box: Box? = nil) -> String {
        let taken = Set(boxes.filter { $0 !== box }.map(\.config.name))
        var candidate = name, index = 2
        while taken.contains(candidate) {
            candidate = "\(name) \(index)"
            index += 1
        }
        return candidate
    }

    // MARK: - 启动时的收尾

    /// 上次 MacBox 异常退出（崩溃、被强制退出、停电）时可能留下：还在运行的盒子程序、借出去没收回的偏好设置、
    /// 做到一半的还原和替换、导入到一半的盒子、还挂着的映像、钥匙串搜索列表里的盒子钥匙串、没上锁的 App。
    /// 依次收拾好，之后才允许打开应用、添加应用（它们都先等 ready()）
    private func recoverInterruptedSessions() async {
        let boxes = boxes
        let root = AppPaths.boxes
        // 1. 先结束遗留的程序，不论有没有没收回的偏好设置：它们已不受管理，留着还会接着往刚恢复的本机设置里写
        await Background.run {
            for _ in 0..<20 {
                let leftovers = EscapeGuard.boxProcessesNow()
                if leftovers.isEmpty { break }
                for pid in leftovers { kill(pid, SIGKILL) }
                usleep(100_000)
            }
        }
        // 2. 替换做到一半的改回原件、删掉残骸；还原点、安装器接手的临时目录，导入到一半的盒子都删掉
        for box in boxes {
            let paths = box.paths
            do {
                try await Background.run {
                    try FileOps.recoverReplacements(in: paths.url, items: paths.replaceableItems)
                    try FileOps.removeTree(paths.restorePointStaging)
                    try FileOps.removeTree(paths.appStaging)
                }
            } catch {
                box.lastError = L("上次没有做完的还原、清除数据没能收拾好：\(error.localizedDescription)",
                                  "Couldn’t clean up a restore or data clearing that was interrupted last time: \(error.localizedDescription)")
            }
        }
        await Background.run {
            for url in FileOps.contents(of: root) where url.pathExtension == BoxPaths.importingSuffix {
                try? FileOps.removeTree(url)
            }
        }
        // 3. 偏好设置。收不回的告诉用户是哪个应用：这时本机这个应用的设置还是盒子里的内容
        var unreturned: [String] = []
        for box in boxes {
            let lease = PreferenceLease(box: box.paths, prefixes: box.config.preferencePrefixes)
            guard lease.isOutstanding else { continue }
            do { try await lease.checkOut() } catch {
                unreturned.append(box.config.name)
                box.lastError = L("无法收回上次运行留下的偏好设置，这台 Mac 上这个应用的设置暂时还是盒子里的内容。下次打开它或重新打开 MacBox 时会再试。原因：\(error.localizedDescription)",
                                  "Couldn’t return the preferences left over from the last session, so this Mac’s settings for the app are still the box’s for now. MacBox will try again the next time you open the app or MacBox. \(error.localizedDescription)")
            }
        }
        if !unreturned.isEmpty {
            alerts.append(StoreAlert(title: L("无法收回偏好设置", "Couldn’t Return Preferences"), message: Self.unreturnedMessage(unreturned)))
        }
        // 4. 做到一半的还原、清除数据（崩溃，或者做到一半失败）重做一遍。设置没收回的这里不做：两者都会整个替换 Prefs，
        // 连同借出的日志；标记留着，打开应用前会先收回设置再做完（见 Box.open）
        for box in boxes {
            let paths = box.paths
            guard let work = Box.unfinishedWork(paths),
                  !PreferenceLease(box: paths, prefixes: box.config.preferencePrefixes).isOutstanding else { continue }
            do {
                try await Background.run { try Box.redo(work, paths) }
                box.notice = work.redoneNotice
            } catch {
                box.lastError = error is Box.PartialRestore ? error.localizedDescription : work.failedMessage(error.localizedDescription)
            }
        }
        // 5. 盒子里的映像
        for image in await DiskImage.attached(fromImagesUnder: FileOps.realPath(root)) {
            for device in image.devices.prefix(1) { await DiskImage.detach(device) }
        }
        // 6. 在 create-keychain 和移出搜索列表之间崩溃、旧版的创建竞争，都会把盒子钥匙串留在你的搜索列表里
        await BoxKeychain.removeStaleSearchListEntries(under: root)
        // 7. App 平时上锁（见 AppLock）：旧版 MacBox 装的 App 从没锁过，运行中崩溃时也没来得及锁上
        for box in boxes {
            let paths = box.paths, app = box.appURL
            do {
                try await Background.run {
                    try IsolatedSession.checkLayout(paths, app: app) // App 文件夹被换成链接时不顺着它去改别处
                    try AppLock.lock(app)
                }
            } catch {
                NSLog("MacBox: 无法锁上「\(box.config.name)」：\(error.localizedDescription)")
            }
        }
        // 8. 撤销系统对盒子里 App 的登记（旧版读图标时会登记，访达、聚焦、App 自己启动包里的辅助 App 也可能登记），
        // 连同包里嵌套的 App 和已经删掉的 App.new、App.old、盒子里的：见 AppRegistration。不影响打开，不必等
        Task.detached { await AppRegistration.unregisterAll(under: root) }
    }

    // MARK: - 导入

    /// 添加应用，返回每个文件的结果。界面发起的，进度、出错、“放进虚拟 Mac”的建议、兼容性询问都显示在界面上，
    /// 并选中添加好的；命令行发起的不动界面，进度交给 onProgress
    @discardableResult
    func importItems(_ urls: [URL], from origin: Origin = .interface,
                     onProgress: ((URL, ImportStage) -> Void)? = nil) async -> [ImportOutcome] {
        await ready()
        // 打开请求由 App 转给管理盒子的那个 MacBox
        guard !isManagedElsewhere else { return urls.map(ImportOutcome.skipped) }
        let interface = origin == .interface
        guard !isTerminating else {
            if interface { skippedImports += urls }
            return urls.map(ImportOutcome.skipped)
        }
        activeImports += 1
        defer {
            activeImports -= 1
            if activeImports == 0 { importStatus = nil } // 同时进行的其他添加还没做完时，进度卡片留着
        }
        var outcomes: [ImportOutcome] = []
        for (index, url) in urls.enumerated() {
            guard !isTerminating else {
                if interface { skippedImports += urls[index...] }
                outcomes += urls[index...].map(ImportOutcome.skipped)
                break
            }
            let progress = { (stage: ImportStage) in
                if interface { self.importStatus = stage.text(for: url) }
                onProgress?(url, stage)
            }
            progress(.reading)
            do {
                // 先看类型再复制：不支持的大文件、文件夹不必整个复制进来才报错
                try PackageExtractor.checkSupported(url)
                let box = try await makeBox(from: url, progress: progress)
                if interface { selection = box.id }
                outcomes.append(.added(box))
                await afterImport(box, origin: origin)
            } catch let error as PackageExtractor.NeedsVirtualMac {
                // 只是报错的话，用户还得自己去找虚拟 Mac 的「文件交换」：直接提供“放进虚拟 Mac”
                if interface { virtualMacOffers.append(VirtualMacOffer(file: url, message: error.message)) }
                outcomes.append(.needsVirtualMac(file: url, message: error.message))
            } catch {
                if interface {
                    let message = L("无法添加「\(url.lastPathComponent)」：\(error.localizedDescription)",
                                    "Couldn’t add “\(url.lastPathComponent)”: \(error.localizedDescription)")
                    // 一次添加多个、几次添加同时进行时，每个失败的都要列出来
                    importError = importError.map { "\($0)\n\n\(message)" } ?? message
                }
                outcomes.append(.failed(file: url, reason: error.localizedDescription))
            }
        }
        return outcomes
    }

    private func makeBox(from url: URL, progress: (ImportStage) -> Void) async throws -> Box {
        let id = UUID()
        // 先在导入用的名字下建好，box.json 写好、钥匙串准备好之后才改成正式的名字（见 BoxPaths.importing）
        let paths = BoxPaths.importing(id: id)
        let final = BoxPaths.new(id: id)
        let config: BoxConfig
        do {
            try AppPaths.ensure(paths.sourceDirectory)
            let source = paths.sourceDirectory.appending(path: url.lastPathComponent)
            // 来自其他卷（外接硬盘、网络位置）时是真正的复制，可能很慢
            try await Background.run { try FileOps.clone(url, to: source) }

            progress(.extracting)
            let extracted = try await PackageExtractor.extractApp(from: source, into: paths.appDirectory)
            let info = try AppInspector.info(of: extracted.app)

            progress(.checking)
            var issues = extracted.issues + (await AppInspector.scan(extracted.app))
            issues.insert(await AppInspector.verifyAndTrust(extracted.app), at: 0)
            // 借出范围：App 的标识符（能放宽时放宽到同系列），加上包里同厂商的登录项、辅助程序（要读本机各 App 的 Info.plist）
            let prefixes = await Background.run { AppInspector.preferencePrefixes(for: extracted.app, identifier: info.bundleIdentifier) }
            var made = BoxConfig(id: id, name: uniqueName(info.name), bundleIdentifier: info.bundleIdentifier,
                                 version: info.version, appFolderName: extracted.app.lastPathComponent,
                                 sourceName: source.lastPathComponent)
            made.issues = issues
            made.isInstaller = AppInspector.looksLikeInstaller(info)
            made.preferencePrefixes = prefixes
            made.showInLaunchpad = UserDefaults.standard.object(forKey: "defaultShowInLaunchpad") as? Bool ?? true
            try paths.save(made)

            progress(.preparingKeychain)
            try await BoxKeychain.prepare(paths)
            try await Background.run {
                // 锁上之后才算装好（见 AppLock）：MacBox 没在运行时，程序坞、聚焦都启动不了它
                try AppLock.lock(extracted.app)
                try FileManager.default.moveItem(at: paths.url, to: final.url)
            }
            config = made
        } catch {
            let partial = paths.url
            await Background.run { try? FileOps.removeTree(partial) }
            throw error
        }
        let box = Box(paths: final, config: config)
        box.store = self
        boxes.append(box)
        await box.syncLauncher().value
        // 检查、读取 App 时系统可能把它登记进了 LaunchServices（见 recoverInterruptedSessions）
        let app = box.appURL
        Task.detached { await AppRegistration.unregister(app) }
        return box
    }

    private func afterImport(_ box: Box, origin: Origin) async {
        // 拖进来的就是安装器：像在访达里双击一样直接运行它
        if reviewCompatibility(of: box, origin: origin), box.config.isInstaller { await box.open(from: origin) }
    }

    /// 刚添加、安装器刚完成安装：静态检查发现需要虚拟 Mac 的，按设置询问或者改用虚拟 Mac（见 suggestVirtualMac）。
    /// 返回 true 表示没有这类问题，可以直接在本机隔离中打开
    @discardableResult
    func reviewCompatibility(of box: Box, origin: Origin = .interface) -> Bool {
        let blocking = box.config.issues.filter { $0.severity == .needsVirtualMac }
        guard !blocking.isEmpty else { return true }
        suggestVirtualMac(for: box, reasons: blocking.map {
            L("\($0.localizedTitle)：\($0.localizedDetail)", "\($0.localizedTitle): \($0.localizedDetail)")
        }, origin: origin)
        return false
    }

    // MARK: - 兼容性

    /// 建议改用虚拟 Mac。按设置排进询问队列（一次添加多个时每个都要问到，不能后一个顶掉前一个；
    /// 同一个盒子还在排队的并成一条，正在显示的不动、另排一条），或者直接改用。blocks 是引起建议的运行时拦截。
    /// 命令行发起的不问：理由在盒子的 config.issues、运行报告的拦截记录里，由命令行说给用户；按设置自动改用的照样改用
    func suggestVirtualMac(for box: Box, reasons: [String], blocks: [String] = [], origin: Origin = .interface) {
        guard box.config.runtime == .isolated else { return }
        switch CompatibilityPolicy.current {
        case .ask:
            guard origin == .interface else { return }
            // 正在显示的那条已经说过的不再说
            let shown = prompt?.boxID == box.id ? prompt : nil
            let reasons = reasons.filter { !(shown?.reasons.contains($0) ?? false) }
            let blocks = blocks.filter { !(shown?.blocks.contains($0) ?? false) }
            guard !reasons.isEmpty || !blocks.isEmpty else { return }
            if let index = prompts.firstIndex(where: { $0.boxID == box.id }) {
                prompts[index].reasons += reasons.filter { !prompts[index].reasons.contains($0) }
                prompts[index].blocks += blocks.filter { !prompts[index].blocks.contains($0) }
            } else {
                prompts.append(CompatibilityPrompt(boxID: box.id, appName: box.config.name, reasons: reasons, blocks: blocks))
            }
            if prompt == nil { prompt = prompts.removeFirst() }
        case .switchAutomatically:
            box.config.runtime = .virtualMac
            box.notice = L("检测到兼容性问题，已按设置改用虚拟 Mac 运行。",
                           "Compatibility issues were found. Switched to Virtual Mac as set.")
        }
    }

    /// 用户选了「继续使用本机隔离」：记下这次的拦截，同样的拦截以后不再问（询问本身由 dismissPrompt 移出）
    func keepNativeIsolation(_ prompt: CompatibilityPrompt) {
        guard let box = box(id: prompt.boxID), !prompt.blocks.isEmpty else { return }
        let acknowledged = box.config.acknowledgedBlocks ?? []
        box.config.acknowledgedBlocks = acknowledged + prompt.blocks.filter { !acknowledged.contains($0) }
    }

    /// 询问已经回答（id 是显示着的那条的，不是的不做任何事：同一次关闭里 SwiftUI 可能再置一次 false）。
    /// 下一条稍后再显示：关掉一个提示的同一刻又要显示一个，SwiftUI 可能显示不出来
    func dismissPrompt(id: UUID) {
        guard prompt?.id == id else { return }
        prompt = nil
        Task {
            if prompt == nil, !prompts.isEmpty { prompt = prompts.removeFirst() }
        }
    }

    func dismissVirtualMacOffer() {
        if !virtualMacOffers.isEmpty { virtualMacOffers.removeFirst() }
    }

    func dismissAlert() {
        if !alerts.isEmpty { alerts.removeFirst() }
    }

    func openInVirtualMac(_ box: Box) async {
        let vm = VirtualMac.shared
        guard vm.config.installed else {
            box.notice = L("需要先在「虚拟 Mac」页完成一次性设置，之后这个应用就会在虚拟 Mac 中运行。",
                           "Finish the one-time setup on the “Virtual Mac” page first. After that, this app will run in Virtual Mac.")
            // 接下来显示的是虚拟 Mac 页，说明也要放在那里，否则只是突然换了一页
            vm.notice = L("「\(box.config.name)」设为在虚拟 Mac 中运行，需要先完成下面的一次性设置。",
                          "“\(box.config.name)” is set to run in Virtual Mac. Finish the one-time setup below first.")
            show(.virtualMac)
            return
        }
        await vm.sendToGuest([box.paths.source(box.config) ?? box.appURL])
        showVirtualMacWindow()
        if vm.status == .stopped { await vm.start() }
    }

    /// 把只有系统组件的安装包放进虚拟 Mac（见 VirtualMacOffer）
    func sendToVirtualMac(_ offer: VirtualMacOffer) async {
        let vm = VirtualMac.shared
        let name = offer.file.lastPathComponent
        guard vm.config.installed else {
            vm.notice = L("要在虚拟 Mac 里安装「\(name)」，先完成下面的一次性设置，然后在「文件交换」里点「放入文件…」选择它。",
                          "To install “\(name)” in the Virtual Mac, finish the one-time setup below, then choose it with “Add Files…” under “File Exchange”.")
            show(.virtualMac)
            return
        }
        await vm.sendToGuest([offer.file])
        showVirtualMacWindow()
        if vm.status == .stopped { await vm.start() }
    }

    /// 打开虚拟 Mac 的窗口并切到前台（从聚焦打开时 MacBox 可能在后台）
    private func showVirtualMacWindow() {
        NSApp?.activate()
        windowRequest = WindowRequest(window: .virtualMac)
    }

    /// 需要用户看到的情况（打不开等）：切到应用页并选中它。从聚焦打开时主窗口可能关着
    func reveal(_ box: Box) {
        selection = box.id
        show(.allApps)
    }

    /// 打开主窗口并切到指定页面
    func show(_ destination: Destination) {
        self.destination = destination
        NSApp?.activate() // 测试进程里没有 NSApp
        windowRequest = WindowRequest(window: .library)
    }

    // MARK: - 删除

    /// 删除盒子（移到废纸篓）。先收回上次没收回的偏好设置，收不回就不删：借出的日志和本机设置的备份在盒子里，
    /// 跟着移走的话本机这个应用原来的设置就再也恢复不了。返回盒子在废纸篓里的位置
    @discardableResult
    func delete(_ box: Box) async throws -> URL? {
        guard !box.isRunning else { throw MacBoxError(L("请先退出「\(box.config.name)」", "Quit “\(box.config.name)” first")) }
        guard !box.isBusy else { throw MacBoxError(L("「\(box.config.name)」正在处理其他操作，请稍候",
                                                         "“\(box.config.name)” is busy with another operation. Try again in a moment.")) }
        let paths = box.paths, app = box.appURL
        let trashed = try await box.performMaintenance {
            await AppRegistration.unregister(app) // 不在登记里留下指向废纸篓的 App（文件夹移走后就撤销不了包里面的了）
            return try await Background.run { try Self.moveToTrash(paths.url) }
        }
        box.retire()
        boxes.removeAll { $0.id == box.id }
        // 正在显示的询问不动：它的按钮对已删除的盒子什么也不做，关掉时按 id 移出（见 dismissPrompt）
        prompts.removeAll { $0.boxID == box.id }
        if selection == box.id { selection = nil }
        return trashed
    }

    /// 把读不出的盒子移到废纸篓（需要时可以从废纸篓找回）
    func deleteBroken(_ broken: BrokenBox) throws {
        try Self.moveToTrash(broken.url)
        brokenBoxes.removeAll { $0.id == broken.id }
        Task { await Launcher.shared.remove(boxID: broken.id) }
    }

    /// 移到废纸篓，返回在废纸篓里的位置。数据放在别处（MACBOX_DATA_ROOT，测试）时移到那里的 Trash 文件夹：
    /// 不往你真正的废纸篓里放东西，那里的东西测试读不了也清不掉（隐私保护）
    @discardableResult
    nonisolated static func moveToTrash(_ url: URL) throws -> URL? {
        guard AppPaths.override != nil else {
            var trashed: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
            return trashed as URL?
        }
        let trash = try AppPaths.ensure(AppPaths.root.appending(path: "Trash", directoryHint: .isDirectory))
        let destination = trash.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    // MARK: - 外部事件

    /// macbox://open/<id>（聚焦里的启动器）。打不开时要说明：从聚焦打开时 MacBox 的窗口多半关着，
    /// 什么也不说的话用户只会觉得“点了没反应”
    func handle(_ url: URL) {
        start()
        guard !isManagedElsewhere else { return } // 没读盒子，不能说“应用已经不在了”
        guard url.scheme == "macbox", url.host() == "open", let id = UUID(uuidString: url.lastPathComponent) else { return }
        if let box = box(id: id) {
            Task { await box.open() }
            return
        }
        let message = if let broken = brokenBoxes.first(where: { $0.id == id }) {
            // 读取失败的说明有的带句号、有的不带（系统的错误信息自己带），统一去掉再加
            L("这个启动器对应的应用无法读取：\(Self.withoutFinalPeriod(broken.message))。可以在「全部应用」里查看或删除它。",
              "The app for this launcher can’t be read: \(Self.withoutFinalPeriod(broken.message)). You can view or delete it in “All Apps”.")
        } else {
            L("这个启动器对应的应用已经不在 MacBox 里了。", "The app for this launcher is no longer in MacBox.")
        }
        alerts.append(StoreAlert(title: L("无法打开", "Couldn’t Open App"), message: message))
        show(.allApps)
    }

    /// 守卫结束了一个沙盒外的进程：记录下来；如果是盒子里 App 的主程序（有人从程序坞、访达直接打开了它，
    /// 或者 App 经由系统重新启动了自己），改为在隔离中打开
    func handleEscape(_ escape: EscapeGuard.Escape) {
        guard let box = boxes.first(where: { escape.owner.hasPrefix(FileOps.realPath($0.paths.url) + "/") }) else { return }
        let event = BlockEvent(kind: .escapedLaunch, target: escape.path)
        let mainExecutable = (try? AppInspector.info(of: box.appURL)).map { FileOps.realPath($0.executable) }
        guard escape.path == mainExecutable, !isTerminating else {
            box.record(event)
            return
        }
        switch box.activity {
        case .idle:
            guard mayRelaunch(box) else {
                box.record(event)
                return
            }
            noteRelaunch(box)
            // 新的运行会清空拦截记录，所以等它开始后再记
            Task {
                await box.open()
                box.record(event)
            }
        case .running(let session) where !session.mainHasExited:
            // 已经在隔离中运行，又被直接打开了一次（比如在访达里双击）：切过去就好
            session.activate()
            box.record(event)
        default:
            // “重启以生效”、更新后重启：主程序退出、辅助程序还撑着这次运行时，新实例经由系统启动，被守卫结束。
            // 收尾、维护时也一样：这次结束后再在隔离中打开
            box.relaunchWhenIdle(event)
            box.session?.activate()
        }
    }

    /// 在隔离中重新打开的频率限制：两次之间至少 3 秒，一分钟最多 3 次，免得一个反复重启自己的 App 一直被拉起来
    func mayRelaunch(_ box: Box) -> Bool {
        let recent = (relaunches[box.id] ?? []).filter { Date().timeIntervalSince($0) < 60 }
        return recent.count < 3 && recent.allSatisfy { Date().timeIntervalSince($0) > 3 }
    }

    func noteRelaunch(_ box: Box) {
        relaunches[box.id] = (relaunches[box.id] ?? []).filter { Date().timeIntervalSince($0) < 60 } + [Date()]
    }

    var runningBoxes: [Box] { boxes.filter(\.isRunning) }
    /// 运行生命周期还没结束的（含启动中、收尾中）
    var liveBoxes: [Box] { boxes.filter(\.isLive) }

    // MARK: - 退出 MacBox

    /// 退出 MacBox 前要等的事：运行中的应用（含启动、收尾）、维护操作、添加应用
    var hasPendingWork: Bool {
        !liveBoxes.isEmpty || boxes.contains { $0.activity == .maintenance } || activeImports > 0
    }

    /// 退出 MacBox 前：请所有应用退出（等待期间才开始运行的也一样），等它们收尾完，也等进行中的维护、添加应用做完。
    /// 应用可能拒绝退出（在问要不要存储、你点了取消、没有响应）：从请求它退出时起超过 patience 还在运行的，返回它们，
    /// 由调用方问用户强制退出还是取消退出——绝不擅自强制结束，没存的内容会丢。
    /// 收尾、维护、添加都是本地的磁盘操作，不设时限：打断它们才会留下半截的数据
    func quitAll(patience: Duration = .seconds(10)) async -> [Box] {
        if !isTerminating { quitRequests = [:] } // 新的一次退出：之前取消掉的那次请求过的不算数
        isTerminating = true
        while true {
            for box in liveBoxes {
                let key = ObjectIdentifier(box)
                let request = quitRequests[key]
                if let session = box.session.map(ObjectIdentifier.init) {
                    switch request?.session {
                    case .some(let asked) where asked == session:
                        break // 已经请求过
                    case .none where request != nil:
                        // 启动期间请求过，启动时盒子已经转达（见 Box.runIsolated）：不再请求，从现在开始计时
                        quitRequests[key] = (session, .now)
                    default:
                        box.quit()
                        quitRequests[key] = (session, .now)
                    }
                } else if box.activity == .launching, request == nil {
                    box.quit() // 启动后立即转达
                    quitRequests[key] = (nil, .now)
                }
            }
            if !hasPendingWork { return [] }
            let now = ContinuousClock.now
            let refusing = runningBoxes.filter { box in
                guard let request = quitRequests[ObjectIdentifier(box)], let session = box.session,
                      request.session == ObjectIdentifier(session) else { return false }
                // 强制退出过的，进程结束、收尾要一点时间：从强制退出时重新计时，不马上又问一遍
                return now - max(request.at, box.forceQuitAt ?? request.at) >= patience
            }
            if !refusing.isEmpty { return refusing }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// 用户取消了退出 MacBox。因为正在退出而没有添加的文件，告诉用户
    func cancelQuit() {
        isTerminating = false
        quitRequests = [:]
        guard !skippedImports.isEmpty else { return }
        let names = skippedImports.map(\.lastPathComponent)
        skippedImports = []
        let message = L("正在退出 MacBox 时，\(Self.chineseList(names))没有添加。需要的话请重新添加。",
                        "\(Self.englishList(names)) \(names.count == 1 ? "wasn’t" : "weren’t") added because MacBox was quitting. Add \(names.count == 1 ? "it" : "them") again if you still need \(names.count == 1 ? "it" : "them").")
        importError = importError.map { "\($0)\n\n\(message)" } ?? message
    }

    // MARK: - 文字

    static func withoutFinalPeriod(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, "。.".contains(last) { text.removeLast() }
        return text
    }

    static func chineseList(_ names: [String]) -> String { names.map { "「\($0)」" }.joined(separator: "、") }
    static func englishList(_ names: [String]) -> String {
        let quoted = names.map { "“\($0)”" }
        guard quoted.count > 1 else { return quoted.first ?? "" }
        return quoted.dropLast().joined(separator: ", ") + " and " + quoted.last!
    }
}
