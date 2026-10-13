import AppKit
import Foundation
import Observation

/// 兼容性问题出现时的处理方式（设置 › 通用）
enum CompatibilityPolicy: String, CaseIterable, Identifiable {
    case ask, switchAutomatically
    var id: String { rawValue }
    var title: String { self == .ask ? "询问我" : "自动改用虚拟 Mac" }
    static let key = "compatibilityPolicy"
    static var current: CompatibilityPolicy {
        CompatibilityPolicy(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .ask
    }
}

/// 主窗口侧边栏的页面
enum Destination: Hashable {
    case allApps, running, virtualMac, settings
}

struct CompatibilityPrompt: Identifiable {
    let id = UUID()
    let boxID: UUID
    let appName: String
    let reasons: [String]
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

@Observable
final class BoxStore {
    static let shared = BoxStore()

    private(set) var boxes: [Box] = []
    private(set) var brokenBoxes: [BrokenBox] = []
    var selection: UUID?
    private(set) var importStatus: String?
    var importError: String?
    var prompt: CompatibilityPrompt?
    var destination: Destination = .allApps
    /// 由 App 场景消费：打开对应窗口
    var windowRequest: WindowRequest?

    /// MacBox 正在退出
    @ObservationIgnored private(set) var isTerminating = false
    @ObservationIgnored private var started = false
    /// 上次异常退出的收尾；启动应用、导入之前都要等它完成
    @ObservationIgnored private var recovery: Task<Void, Never>?
    @ObservationIgnored private var volumeWatchers: [Task<Void, Never>] = []
    @ObservationIgnored private var lastRelaunch: [UUID: Date] = [:]

    /// 不做任何事；读取盒子、启动守卫等都在 start() 里
    init() {}

    /// 读取盒子、收尾上次异常退出、启动守卫。可重复调用，只有第一次生效
    func start() {
        guard !started else { return }
        started = true
        reload()
        recovery = Task { await recoverInterruptedSessions() }
        EscapeGuard.shared.start { [weak self] escape in self?.handleEscape(escape) }
        // 有卷挂载/卸载时立即更新守卫（安装器挂载 dmg 后常常马上从卷上启动 App）
        let center = NSWorkspace.shared.notificationCenter
        volumeWatchers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map { name in
            Task.detached {
                for await _ in center.notifications(named: name) { await EscapeGuard.refreshVolumes() }
            }
        }
        Task { await EscapeGuard.refreshVolumes() }
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
        // 启动器被删掉或被覆盖时补回来，没有主人的清掉（读不出的盒子也算主人）
        let keep = Set(boxes.map(\.id) + brokenBoxes.map(\.id))
        let wanted = boxes.filter { $0.config.showInLaunchpad && !$0.config.isInstaller }
        Task {
            await Launcher.shared.removeOrphans(keeping: keep)
            for box in wanted where !(await Launcher.shared.hasLauncher(for: box.id)) {
                box.syncLauncher()
            }
        }
    }

    private static func describeLoadError(_ error: Error) -> String {
        if (error as? CocoaError)?.code == .fileReadNoSuchFile { return "缺少配置文件 box.json" }
        if error is DecodingError { return "配置文件 box.json 格式无法识别，可能来自更新版本的 MacBox 或已损坏" }
        return "无法读取配置文件 box.json：\(error.localizedDescription)"
    }

    func box(id: UUID) -> Box? { boxes.first { $0.id == id } }

    /// 上次 MacBox 异常退出时，可能有借出去的偏好设置没收回、盒子里的映像还挂着、
    /// 盒子里的程序还在运行（已不受管理，守卫也会结束它们）。先结束程序再收回设置，
    /// 否则它们会继续往刚恢复的本机设置里写
    private func recoverInterruptedSessions() async {
        let leases = boxes.map { PreferenceLease(box: $0.paths, prefixes: $0.config.preferencePrefixes) }
            .filter(\.isOutstanding)
        if !leases.isEmpty {
            for pid in await ProcessTable.pids(under: FileOps.realPath(AppPaths.boxes) + "/") { kill(pid, SIGKILL) }
        }
        for lease in leases {
            do { try await lease.checkOut() } catch {
                importError = "无法恢复上次运行留下的偏好设置：\(error.localizedDescription)"
            }
        }
        for image in await DiskImage.attached(fromImagesUnder: FileOps.realPath(AppPaths.boxes)) {
            for device in image.devices.prefix(1) { await DiskImage.detach(device) }
        }
    }

    // MARK: - 导入

    func importItems(_ urls: [URL]) async {
        await ready()
        for url in urls {
            importStatus = "正在读取「\(url.lastPathComponent)」…"
            do {
                let box = try await makeBox(from: url)
                selection = box.id
                importStatus = nil
                await afterImport(box)
            } catch {
                importError = "无法添加「\(url.lastPathComponent)」：\(error.localizedDescription)"
            }
        }
        importStatus = nil
    }

    private func makeBox(from url: URL) async throws -> Box {
        let id = UUID()
        let paths = BoxPaths.new(id: id)
        try AppPaths.ensure(paths.sourceDirectory)
        do {
            let source = paths.sourceDirectory.appending(path: url.lastPathComponent)
            // 来自其他卷（外接硬盘、网络位置）时是真正的复制，可能很慢
            try await Background.run { try FileOps.clone(url, to: source) }

            importStatus = "正在取出 App…"
            let extracted = try await PackageExtractor.extractApp(from: source, into: paths.appDirectory)
            let info = try AppInspector.info(of: extracted.app)

            importStatus = "正在检查兼容性…"
            var issues = extracted.issues + (await AppInspector.scan(extracted.app))
            issues.insert(await AppInspector.verifyAndTrust(extracted.app), at: 0)
            var config = BoxConfig(id: id, name: info.name, bundleIdentifier: info.bundleIdentifier,
                                   version: info.version, appFolderName: extracted.app.lastPathComponent,
                                   sourceName: source.lastPathComponent)
            config.issues = issues
            config.isInstaller = AppInspector.looksLikeInstaller(info)
            config.preferencePrefixes = [AppInspector.preferencePrefix(for: info.bundleIdentifier)]
            config.showInLaunchpad = UserDefaults.standard.object(forKey: "defaultShowInLaunchpad") as? Bool ?? true
            try paths.save(config)

            importStatus = "正在准备独立的钥匙串…"
            try await BoxKeychain.prepare(paths)

            let box = Box(paths: paths, config: config)
            box.store = self
            boxes.append(box)
            await box.syncLauncher().value
            return box
        } catch {
            let boxURL = paths.url
            await Background.run { try? FileManager.default.removeItem(at: boxURL) }
            throw error
        }
    }

    private func afterImport(_ box: Box) async {
        let blocking = box.config.issues.filter { $0.severity == .needsVirtualMac }
        if !blocking.isEmpty {
            suggestVirtualMac(for: box, reasons: blocking.map { "\($0.title)：\($0.detail)" })
            return
        }
        // 拖进来的就是安装器：像在访达里双击一样直接运行它
        if box.config.isInstaller { await box.open() }
    }

    // MARK: - 兼容性

    func suggestVirtualMac(for box: Box, reasons: [String]) {
        guard box.config.runtime == .isolated else { return }
        switch CompatibilityPolicy.current {
        case .ask:
            prompt = CompatibilityPrompt(boxID: box.id, appName: box.config.name, reasons: reasons)
        case .switchAutomatically:
            box.config.runtime = .virtualMac
            box.notice = "检测到兼容性问题，已按设置改用虚拟 Mac 运行。"
        }
    }

    func openInVirtualMac(_ box: Box) async {
        let vm = VirtualMac.shared
        guard vm.config.installed else {
            box.notice = "需要先在「虚拟 Mac」页完成一次性设置，之后这个应用就会在虚拟 Mac 中运行。"
            show(.virtualMac)
            return
        }
        vm.sendToGuest([box.paths.source(box.config) ?? box.appURL])
        windowRequest = WindowRequest(window: .virtualMac)
        if vm.status == .stopped { await vm.start() }
    }

    /// 打开主窗口并切到指定页面
    func show(_ destination: Destination) {
        self.destination = destination
        NSApp.activate()
        windowRequest = WindowRequest(window: .library)
    }

    // MARK: - 删除

    func delete(_ box: Box) throws {
        guard !box.isRunning else { throw MacBoxError("请先退出「\(box.config.name)」") }
        guard !box.isBusy else { throw MacBoxError("「\(box.config.name)」正在处理其他操作，请稍候") }
        try FileManager.default.trashItem(at: box.paths.url, resultingItemURL: nil)
        box.retire()
        boxes.removeAll { $0.id == box.id }
        if selection == box.id { selection = nil }
    }

    /// 把读不出的盒子移到废纸篓（需要时可以从废纸篓找回）
    func deleteBroken(_ broken: BrokenBox) throws {
        try FileManager.default.trashItem(at: broken.url, resultingItemURL: nil)
        brokenBoxes.removeAll { $0.id == broken.id }
        Task { await Launcher.shared.remove(boxID: broken.id) }
    }

    // MARK: - 外部事件

    /// macbox://open/<id>（启动台里的启动器）
    func handle(_ url: URL) {
        start()
        guard url.scheme == "macbox", url.host() == "open",
              let id = UUID(uuidString: url.lastPathComponent), let box = box(id: id) else { return }
        Task { await box.open() }
    }

    /// 守卫结束了一个沙盒外的进程：记录下来；如果是有人直接打开了盒子里的 App，改为在隔离中打开
    private func handleEscape(_ escape: EscapeGuard.Escape) {
        guard let box = boxes.first(where: { escape.owner.hasPrefix(FileOps.realPath($0.paths.url) + "/") }) else { return }
        let event = BlockEvent(kind: .escapedLaunch, target: escape.path)
        let mainExecutable = (try? AppInspector.info(of: box.appURL)).map { FileOps.realPath($0.executable) }
        if escape.path == mainExecutable, !box.isRunning, !isTerminating,
           Date().timeIntervalSince(lastRelaunch[box.id] ?? .distantPast) > 3 {
            lastRelaunch[box.id] = Date()
            // 新的运行会清空拦截记录，所以等它开始后再记
            Task {
                await box.open()
                box.record(event)
            }
        } else {
            box.record(event)
        }
    }

    var runningBoxes: [Box] { boxes.filter(\.isRunning) }
    /// 运行生命周期还没结束的（含启动中、收尾中）
    var liveBoxes: [Box] { boxes.filter(\.isLive) }

    /// 退出 MacBox 前让所有应用退出并完成收尾（最多等 10 秒）
    func quitAll() async {
        isTerminating = true
        for box in liveBoxes { box.quit() }
        // 等所有应用退出并完成收尾（收回偏好设置等），最多 10 秒
        let allQuit = Observations { self.liveBoxes.isEmpty }
        await withTaskGroup { group in
            group.addTask { for await empty in allQuit where empty { return } }
            group.addTask { try? await Task.sleep(for: .seconds(10)) }
            await group.next()
            group.cancelAll()
        }
    }
}
